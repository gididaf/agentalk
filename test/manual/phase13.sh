#!/usr/bin/env bash
# Phase 13 manual QA — the abuse surface a public browser page introduces.
#
# What changed: until now every client was an agent holding a token pasted by a
# human, and `join` was unauthenticated but effectively unreachable. /c/:id now
# renders a chat page, so join is one tap away for anyone who gets the link.
#
# Checks:
#  - joins are rate-limited per IP, with Retry-After
#  - polling is NOT rate-limited under that same pressure (throttling a 50s
#    long-poll would break the transport, not protect it)
#  - names containing control characters are rejected at the bridge
#  - ordinary names still join
#  - /metrics exposes the join-rejection counter

set -u

PORT=3006
BRIDGE="http://localhost:$PORT"
BRIDGE_LOG="/tmp/agentalk-phase13-bridge.log"
PIDFILE="/tmp/agentalk-phase13.pid"
PASS=0
FAIL=0

color()  { printf "\033[%sm%s\033[0m" "$1" "$2"; }
green()  { color "32" "$1"; }
red()    { color "31" "$1"; }
yellow() { color "33" "$1"; }
ok()   { echo "  $(green PASS) — $1"; PASS=$((PASS+1)); }
bad()  { echo "  $(red FAIL) — $1"; FAIL=$((FAIL+1)); }
step() { echo; echo "$(yellow "▸ $1")"; }

need() { command -v "$1" >/dev/null || { echo "missing command: $1"; exit 1; }; }
need curl
need jq

cleanup() {
  if [[ -f "$PIDFILE" ]]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
}
trap cleanup EXIT
cd "$(dirname "$0")/../.." || exit 1
: > "$BRIDGE_LOG"

step "0. boot a private bridge with a low join allowance"
PORT=$PORT \
  RL_CHANNELS_PER_HOUR=1000 RL_MESSAGES_PER_HOUR=10000 \
  RL_CONCURRENT_CHANNELS_PER_IP=1000 RL_JOINS_PER_HOUR=10 \
  CH_POLL_TIMEOUT_MS=1000 CH_MAX_PARTICIPANTS=200 \
  npx tsx src/bridge/index.ts >>"$BRIDGE_LOG" 2>&1 &
echo $! > "$PIDFILE"
for _ in $(seq 1 40); do curl -fsS "$BRIDGE/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fsS "$BRIDGE/health" >/dev/null || { echo "bridge failed to boot"; exit 1; }
ok "bridge up on $PORT (RL_JOINS_PER_HOUR=10)"

CREATE=$(curl -fsS -X POST "$BRIDGE/channels")
CH=$(printf '%s' "$CREATE" | jq -r '.channel_id')
TK=$(printf '%s' "$CREATE" | jq -r '.token')

join_as() { # join_as <name> -> http status
  curl -s -o /tmp/agentalk-p13-join.json -w '%{'"http_code"'}' \
    -X POST "$BRIDGE/channels/$CH/join" -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$TK" --arg n "$1" '{token:$t, name:$n}')"
}

step "1. a normal join works"
code=$(join_as "Dana")
[ "$code" = "200" ] && ok "first join returns 200" || bad "first join returned $code"
PID=$(jq -r '.participant_id' < /tmp/agentalk-p13-join.json)

step "2. names with control characters are rejected"
# Sent as proper JSON \uXXXX escapes, NOT raw bytes. That distinction is the
# whole point: a raw newline inside a JSON string is malformed JSON and dies in
# the parser, so testing that form proves nothing about our own validation. The
# escaped form is well-formed JSON that decodes to a real control character, and
# it is the only form an attacker would actually send.
for spec in 'newline:\u000a' 'carriage:\u000d' 'null:\u0000' 'tab:\u0009' 'escape:\u001b' 'delete:\u007f'; do
  label="${spec%%:*}"; esc="${spec#*:}"
  body=$(printf '{"token":"%s","name":"ev%sil"}' "$TK" "$esc")
  code=$(curl -s -o /tmp/agentalk-p13-bad.json -w '%{'"http_code"'}' \
    -X POST "$BRIDGE/channels/$CH/join" -H 'content-type: application/json' --data-binary "$body")
  err=$(jq -r '.error // ""' < /tmp/agentalk-p13-bad.json 2>/dev/null)
  if [ "$code" = "400" ] && [ "$err" = "invalid_name" ]; then
    ok "$label rejected by name validation (400 invalid_name)"
  elif [ "$code" = "400" ]; then
    bad "$label got 400 but as '$err' — the JSON parser caught it, not our validator"
  else
    bad "$label accepted with $code — a control char reached the roster"
  fi
done

# And an ordinary name is still fine.
code=$(join_as "Dana.2-b_c")
[ "$code" = "200" ] \
  && ok "an ordinary name with dots, dashes and underscores still joins" \
  || bad "a legitimate name was rejected with $code"

step "3. joins are rate-limited"
# 10/hour, 1 already spent above. Push well past it.
LAST=""
HIT=0
for n in $(seq 1 20); do
  LAST=$(join_as "flood$n")
  if [ "$LAST" = "429" ]; then HIT=$n; break; fi
done
[ "$HIT" -gt 0 ] \
  && ok "join flood hit 429 after $HIT attempts" \
  || bad "20 joins in a row never hit the limit"

RA=$(curl -s -D - -o /dev/null -X POST "$BRIDGE/channels/$CH/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TK" '{token:$t, name:"another"}')" \
  | awk -F': ' 'tolower($1)=="retry-after"{print $2}' | tr -d '\r\n')
[ -n "$RA" ] \
  && ok "429 carries Retry-After: $RA" \
  || bad "429 has no Retry-After header"

err=$(curl -s -X POST "$BRIDGE/channels/$CH/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TK" '{token:$t, name:"another"}')" | jq -r '.error // ""')
[ "$err" = "rate_limited" ] \
  && ok "429 body says rate_limited" \
  || bad "429 body error was '$err'"

step "4. polling still works under that same pressure"
# This is the assertion that matters: an over-eager limiter that also throttled
# poll would silently break every live conversation on the bridge.
code=$(curl -s -o /dev/null -w '%{'"http_code"'}' \
  "$BRIDGE/channels/$CH/poll?token=$TK&participant_id=$PID&since=0&")
[ "$code" = "200" ] && ok "poll returns 200 while joins are throttled" || bad "poll returned $code"

for n in 1 2 3 4 5; do
  code=$(curl -s -o /dev/null -w '%{'"http_code"'}' \
    "$BRIDGE/channels/$CH/poll?token=$TK&participant_id=$PID&since=0&")
  [ "$code" = "200" ] || { bad "poll #$n returned $code — polling got rate-limited"; break; }
  [ "$n" = "5" ] && ok "five consecutive polls all returned 200"
done

step "5. metrics expose the join rejections"
M=$(curl -fsS "$BRIDGE/metrics")
printf '%s' "$M" | grep -q 'agentalk_ratelimit_rejections_total{kind="joins"}' \
  && ok "metrics carry kind=\"joins\"" \
  || bad "metrics missing the joins rejection counter"
JN=$(printf '%s' "$M" | awk -F' ' '/kind="joins"/{print $2}')
[ -n "$JN" ] && [ "$JN" != "0" ] \
  && ok "join rejection counter advanced ($JN)" \
  || bad "join rejection counter is '$JN'"
for kind in channels messages concurrent_channels; do
  printf '%s' "$M" | grep -q "kind=\"$kind\"" \
    && ok "metrics still expose kind=\"$kind\"" \
    || bad "metrics lost kind=\"$kind\""
done

echo
echo "$(green "PASS: $PASS")   $( [ "$FAIL" -gt 0 ] && red "FAIL: $FAIL" || echo "FAIL: 0")"
[ "$FAIL" -eq 0 ] || exit 1

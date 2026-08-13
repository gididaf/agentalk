#!/usr/bin/env bash
# Phase 14 QA — does a REAL Claude pick the right kind of link?
#
# Every other script here drives the wire with curl. This one drives `claude -p`,
# because the thing being tested is a decision the model makes from prose:
#
#   "talk to my other agent"        -> the tuned AGENT share message, plain link
#   "send this to Dana about X"     -> the HUMAN message, link + &n=Dana + &t=X
#   "send this to someone about X"  -> the HUMAN message, link + &t=X and NO &n=
#
# That last one is the one worth having. A guessed name is worse than asking,
# because the recipient lands in a chat already addressed to the wrong person.
# No amount of curl can check whether the SDK's wording actually produces that
# restraint — only a real model reading the real page can.
#
# COSTS REAL TOKENS: three headless Claude sessions. Opt in explicitly:
#   RUN_REAL_CLAUDE=1 ./test/manual/phase14-real-claude.sh
#
# Runs each session in its own temp cwd with --dangerously-skip-permissions,
# which is what makes an unattended bootstrap possible. The cwd is disposable
# and the bridge is a private one on PORT below; nothing touches the repo.

set -u

if [ "${RUN_REAL_CLAUDE:-0}" != "1" ]; then
  echo "Skipped. This spends real tokens on three headless Claude sessions."
  echo "Run it with:  RUN_REAL_CLAUDE=1 $0"
  exit 0
fi

PORT=3007
BRIDGE="http://localhost:$PORT"
BRIDGE_LOG="/tmp/agentalk-phase14-bridge.log"
PIDFILE="/tmp/agentalk-phase14.pid"
TIMEOUT_S="${CLAUDE_TIMEOUT_S:-240}"
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
need claude

cleanup() {
  if [[ -f "$PIDFILE" ]]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
  pkill -f "channels/.*/poll?token=" 2>/dev/null || true
}
trap cleanup EXIT
cd "$(dirname "$0")/../.." || exit 1
: > "$BRIDGE_LOG"

step "0. boot a private bridge"
PORT=$PORT \
  RL_CHANNELS_PER_HOUR=1000 RL_MESSAGES_PER_HOUR=10000 \
  RL_CONCURRENT_CHANNELS_PER_IP=1000 RL_JOINS_PER_HOUR=1000 \
  CH_IDLE_TIMEOUT_MS=900000 CH_MAX_LIFETIME_MS=900000 \
  npx tsx src/bridge/index.ts >>"$BRIDGE_LOG" 2>&1 &
echo $! > "$PIDFILE"
for _ in $(seq 1 40); do curl -fsS "$BRIDGE/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fsS "$BRIDGE/health" >/dev/null || { echo "bridge failed to boot"; exit 1; }
ok "bridge up on $PORT"

# run_claude <label> <prompt> -> writes /tmp/agentalk-p14-<label>.out
run_claude() {
  local label="$1" prompt="$2"
  local dir="/tmp/agentalk-p14-$label"
  rm -rf "$dir"; mkdir -p "$dir"
  echo "    running claude -p ($label), up to ${TIMEOUT_S}s…"
  ( cd "$dir" && timeout "$TIMEOUT_S" claude -p "$prompt" \
      --dangerously-skip-permissions ) > "/tmp/agentalk-p14-$label.out" 2>&1
  echo "    exit=$? output=$(wc -c < "/tmp/agentalk-p14-$label.out" | tr -d ' ') bytes"
}

# The URL Claude actually handed the user. Take the LAST one: if it revises,
# the final line is what the user would copy.
url_from() { grep -oE 'http://localhost:'"$PORT"'/c/[^ )"'"'"'`]+' "$1" | tail -n 1; }

# ---------------------------------------------------------------------------
step "1. agent link — the existing path must not regress"
run_claude agent "Talk to my other agent at $BRIDGE. Just say hi for now."
OUT=/tmp/agentalk-p14-agent.out
AURL=$(url_from "$OUT")

[ -n "$AURL" ] && ok "produced a join URL" || bad "no URL in output"
printf '%s' "$AURL" | grep -q '#k=[0-9a-f]\{64\}' \
  && ok "URL carries a full 64-hex key" \
  || bad "key missing or short: $AURL"
grep -q 'curl this URL to start' "$OUT" \
  && ok "used the tuned AGENT share message" \
  || bad "agent share message not echoed verbatim"
printf '%s' "$AURL" | grep -q '&n=' \
  && bad "agent link wrongly personalised with &n=" \
  || ok "no &n= on an agent link"
grep -qi "I'm Claude, an AI assistant" "$OUT" \
  && bad "echoed the HUMAN message for an agent request" \
  || ok "did not use the human message"

# ---------------------------------------------------------------------------
step "2. human link, name known — should skip the name prompt"
run_claude named "Spawn an agentalk link at $BRIDGE for Dana. I need to ask her about a login bug where sessions drop on token refresh. She is a colleague, she will open it in her browser."
OUT=/tmp/agentalk-p14-named.out
NURL=$(url_from "$OUT")

[ -n "$NURL" ] && ok "produced a join URL" || bad "no URL in output"
printf '%s' "$NURL" | grep -q '#k=[0-9a-f]\{64\}' \
  && ok "URL carries a full 64-hex key" \
  || bad "key missing or short: $NURL"
grep -qiE "I'm Claude, an AI assistant|opens in your browser" "$OUT" \
  && ok "used the HUMAN share message" \
  || bad "did not use the human share message"
grep -q 'curl this URL to start' "$OUT" \
  && bad "also echoed the agent message (should be one or the other)" \
  || ok "did not echo the agent message"
printf '%s' "$NURL" | grep -qi '&n=dana' \
  && ok "personalised with &n=Dana" \
  || bad "no &n=Dana in the link: $NURL"
printf '%s' "$NURL" | grep -q '&t=' \
  && ok "carries a topic (&t=)" \
  || bad "no &t= in the link: $NURL"
grep -q '__TOPIC__' "$OUT" \
  && bad "left the literal __TOPIC__ placeholder in the message" \
  || ok "__TOPIC__ was substituted"
grep -q '__KEY__' "$OUT" \
  && bad "left the literal __KEY__ placeholder in the message" \
  || ok "__KEY__ was substituted"
# The key must stay first in the fragment or the joiner bootstrap sees junk.
printf '%s' "$NURL" | grep -q '#k=[0-9a-f]\{64\}&' \
  && ok "the key stays first in the fragment" \
  || bad "fragment order is wrong: $NURL"

# ---------------------------------------------------------------------------
step "3. human link, name NOT known — must NOT invent one"
run_claude anon "Spawn an agentalk link at $BRIDGE that I can post in my team channel, so whoever is around can help with a login bug where sessions drop on token refresh. I do not know who will pick it up."
OUT=/tmp/agentalk-p14-anon.out
XURL=$(url_from "$OUT")

[ -n "$XURL" ] && ok "produced a join URL" || bad "no URL in output"
grep -qiE "I'm Claude, an AI assistant|opens in your browser" "$OUT" \
  && ok "used the HUMAN share message" \
  || bad "did not use the human share message"
printf '%s' "$XURL" | grep -q '&n=' \
  && bad "invented a name: $XURL" \
  || ok "left &n= off when the name is unknown"
printf '%s' "$XURL" | grep -q '&t=' \
  && ok "still carries a topic (&t=)" \
  || bad "no &t= in the link: $XURL"

# ---------------------------------------------------------------------------
step "4. every produced link actually works"
# A link Claude formats wrongly is worse than no link, so parse each one the way
# the browser would and confirm the channel is real.
for pair in "agent:$AURL" "named:$NURL" "anon:$XURL"; do
  label="${pair%%:*}"; u="${pair#*:}"
  [ -z "$u" ] && { bad "$label: no URL to check"; continue; }
  # '#' cannot be the sed delimiter here: the pattern itself contains '#k='.
  cid=$(printf '%s' "$u" | sed -n 's|.*/c/\([0-9a-f]*\)?.*|\1|p')
  tok=$(printf '%s' "$u" | sed -n 's|.*[?&]token=\([0-9a-f]*\).*|\1|p')
  key=$(printf '%s' "$u" | sed -n 's|.*#k=\([0-9a-f]\{64\}\).*|\1|p')
  if [ -z "$cid" ] || [ -z "$tok" ] || [ -z "$key" ]; then
    bad "$label: could not parse id/token/key out of $u"
    continue
  fi
  code=$(curl -s -o /dev/null -w '%{'"http_code"'}' \
    -X POST "$BRIDGE/channels/$cid/join" -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$tok" --arg n "probe-$label" '{token:$t, name:$n}')")
  [ "$code" = "200" ] \
    && ok "$label: link parses and the channel accepts a join" \
    || bad "$label: joining that channel returned $code"
done

step "5. the SDK page each session read is the one we shipped"
grep -q 'HUMAN_JOINED' <(curl -fsS -H 'User-Agent: Claude-User' "$BRIDGE/llms.txt") \
  && ok "served SDK contains the HUMAN_JOINED row" \
  || bad "served SDK is stale"

echo
echo "$(green "PASS: $PASS")   $( [ "$FAIL" -gt 0 ] && red "FAIL: $FAIL" || echo "FAIL: 0")"
echo
echo "Transcripts kept for inspection:"
for l in agent named anon; do echo "  /tmp/agentalk-p14-$l.out"; done
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
# Phase 8 manual QA — hibernate / resume (bridge side).
#
# The bug this exists to prevent: a room used to be DESTROYED after
# idleTimeoutMs of no polling, and idle only ever fires when every participant
# stopped polling — i.e. a network drop or a sleeping laptop. 18 of the first 22
# rooms on production died this way, each one costing a manual re-handoff.
# A quiet room now goes to SLEEP instead: messages and roster dropped, id and
# token kept, revived by a re-join.
#
# Checks:
#  - going quiet hibernates rather than evicts (no tombstone, token still valid)
#  - poll/send/leave on a sleeping room return 404 + hibernating/rejoin flags
#  - the 404 body still carries `evicted_reason`, so a pre-hibernation loop.sh
#    exits cleanly instead of reporting the fatal `bad_request`
#  - re-joining wakes the room and messaging works again end to end
#  - hibernating releases the creator's concurrent-channel slot
#  - a room asleep past CH_HIBERNATE_MAX_MS is evicted for real, with a tombstone
#  - /health and /metrics expose the sleep/resume counters
#
# Spins up a private bridge on port 3002 with aggressive timings.

set -u

PORT=3002
BRIDGE="http://localhost:$PORT"
BRIDGE_LOG="/tmp/agentalk-phase8-bridge.log"
PIDFILE="/tmp/agentalk-phase8.pid"
PASS=0
FAIL=0

color()  { printf "\033[%sm%s\033[0m" "$1" "$2"; }
green()  { color "32" "$1"; }
red()    { color "31" "$1"; }
yellow() { color "33" "$1"; }

ok()   { echo "  $(green PASS) — $1"; PASS=$((PASS+1)); }
bad()  { echo "  $(red FAIL) — $1"; FAIL=$((FAIL+1)); }
step() { echo; echo "$(yellow "▸ $1")"; }

need() { command -v "$1" >/dev/null || { bad "missing command: $1"; exit 1; }; }
need curl
need jq

cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}
trap cleanup EXIT

boot() {
  cleanup
  sleep 0.3
  PORT=$PORT \
    RL_CHANNELS_PER_HOUR=100 \
    RL_MESSAGES_PER_HOUR=1000 \
    RL_CONCURRENT_CHANNELS_PER_IP="${RL_CONC:-100}" \
    CH_IDLE_TIMEOUT_MS="${IDLE_MS:-1500}" \
    CH_HIBERNATE_MAX_MS="${HIB_MS:-600000}" \
    CH_POLL_TIMEOUT_MS="${POLL_MS:-400}" \
    CH_MAX_LIFETIME_MS="${LIFE_MS:-600000}" \
    CH_SWEEP_INTERVAL_MS=300 \
    npx tsx src/bridge/index.ts >>"$BRIDGE_LOG" 2>&1 &
  echo $! > "$PIDFILE"
  for _ in $(seq 1 30); do curl -fsS "$BRIDGE/health" >/dev/null 2>&1 && return 0; sleep 0.2; done
  bad "bridge failed to boot on $PORT"; exit 1
}

# Create a channel and join one participant. Echoes: channel_id token participant_id
make_room() {
  local cr chid tok j pid
  cr=$(curl -fsS -X POST "$BRIDGE/channels")
  chid=$(printf '%s' "$cr" | jq -r '.channel_id')
  tok=$(printf '%s' "$cr" | jq -r '.token')
  j=$(curl -fsS -X POST "$BRIDGE/channels/$chid/join" -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$tok" --arg n "${1:-a}" '{token:$t, name:$n}')")
  pid=$(printf '%s' "$j" | jq -r '.participant_id')
  printf '%s %s %s' "$chid" "$tok" "$pid"
}

cd "$(dirname "$0")/../.." || exit 1
: > "$BRIDGE_LOG"

step "0. boot a private bridge on port $PORT (idle 1.5s)"
boot
ok "bridge up"

# ─────────────────────────────────────────────────────────────────────────────
step "1. going quiet hibernates instead of evicting"
read -r CHID TOK APID <<<"$(make_room a)"
sleep 2.5   # past idle (1.5s) + a sweep tick (0.3s)

HEALTH=$(curl -fsS "$BRIDGE/health")
[[ "$(printf '%s' "$HEALTH" | jq -r '.channels_hibernating')" = "1" ]] \
  && ok "health reports 1 hibernating channel" || bad "channels_hibernating != 1: $HEALTH"
[[ "$(printf '%s' "$HEALTH" | jq -r '.channels')" = "0" ]] \
  && ok "health no longer counts it as awake" || bad "awake channels != 0: $HEALTH"
[[ "$(printf '%s' "$HEALTH" | jq -r '.total_hibernations')" = "1" ]] \
  && ok "total_hibernations = 1" || bad "total_hibernations wrong: $HEALTH"
[[ "$(printf '%s' "$HEALTH" | jq -r '.evictions.evicted_idle')" = "0" ]] \
  && ok "nothing was evicted for idle (the old behaviour is gone)" \
  || bad "an idle eviction still happened: $HEALTH"

step "2. poll on a sleeping room: 404 + hibernating/rejoin flags"
POLLBODY=$(curl -sS "$BRIDGE/channels/$CHID/poll?token=$TOK&participant_id=$APID&since=0")
POLLCODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BRIDGE/channels/$CHID/poll?token=$TOK&participant_id=$APID&since=0")
[[ "$POLLCODE" = "404" ]] && ok "poll returns 404" || bad "poll returned $POLLCODE, expected 404"
[[ "$(printf '%s' "$POLLBODY" | jq -r '.hibernating')" = "true" ]] \
  && ok "body carries hibernating:true" || bad "no hibernating flag: $POLLBODY"
[[ "$(printf '%s' "$POLLBODY" | jq -r '.rejoin')" = "true" ]] \
  && ok "body carries rejoin:true (the forward path)" || bad "no rejoin flag: $POLLBODY"
[[ "$(printf '%s' "$POLLBODY" | jq -r '.error')" = "channel_hibernating" ]] \
  && ok "error is channel_hibernating, not participant_not_in_channel" \
  || bad "wrong error — a stale participant must not read as a client bug: $POLLBODY"

step "3. backward compatibility with pre-hibernation loop.sh"
# Old loops branch on HTTP status and read .evicted_reason; anything else makes
# them print the fatal `bad_request`. This must stay true until Phase 3 ships.
[[ "$(printf '%s' "$POLLBODY" | jq -r '.evicted_reason')" = "hibernating" ]] \
  && ok "evicted_reason present → old loop prints 'SYSTEM hibernating' and exits cleanly" \
  || bad "old loops would report bad_request: $POLLBODY"

step "4. send and leave agree with poll"
SENDCODE=$(curl -sS -o /tmp/agentalk-p8-send.json -w '%{http_code}' -X POST "$BRIDGE/channels/$CHID/send" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOK" --arg p "$APID" '{token:$t, participant_id:$p, text:"x"}')")
[[ "$SENDCODE" = "404" ]] && ok "send returns 404 too" || bad "send returned $SENDCODE"
[[ "$(jq -r '.hibernating' /tmp/agentalk-p8-send.json)" = "true" ]] \
  && ok "send body carries the same flags" || bad "send body lacks hibernating flag"
LEAVECODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BRIDGE/channels/$CHID/leave" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOK" --arg p "$APID" '{token:$t, participant_id:$p}')")
[[ "$LEAVECODE" = "404" ]] && ok "leave returns 404 too" || bad "leave returned $LEAVECODE"

step "5. re-joining wakes the room"
REJOIN=$(curl -sS -X POST "$BRIDGE/channels/$CHID/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOK" '{token:$t, name:"a"}')")
NEWPID=$(printf '%s' "$REJOIN" | jq -r '.participant_id // empty')
[[ -n "$NEWPID" ]] && ok "re-join with the SAME token succeeded" || bad "re-join failed: $REJOIN"
[[ "$NEWPID" != "$APID" ]] && ok "issued a fresh participant_id" || bad "participant_id was reused"
HEALTH=$(curl -fsS "$BRIDGE/health")
[[ "$(printf '%s' "$HEALTH" | jq -r '.total_resumes')" = "1" ]] \
  && ok "total_resumes = 1" || bad "total_resumes wrong: $HEALTH"
[[ "$(printf '%s' "$HEALTH" | jq -r '.channels_hibernating')" = "0" ]] \
  && ok "no longer counted as sleeping" || bad "still hibernating: $HEALTH"
[[ "$(printf '%s' "$HEALTH" | jq -r '.channels')" = "1" ]] \
  && ok "counted as awake again" || bad "not awake: $HEALTH"

step "6. the woken room actually works"
B=$(curl -fsS -X POST "$BRIDGE/channels/$CHID/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOK" '{token:$t, name:"b"}')")
BPID=$(printf '%s' "$B" | jq -r '.participant_id')
curl -fsS -X POST "$BRIDGE/channels/$CHID/send" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOK" --arg p "$BPID" '{token:$t, participant_id:$p, text:"after-wake"}')" >/dev/null
AFTER=$(curl -fsS "$BRIDGE/channels/$CHID/poll?token=$TOK&participant_id=$NEWPID&since=0")
printf '%s' "$AFTER" | jq -e '.messages[] | select(.type=="message" and .text=="after-wake")' >/dev/null \
  && ok "message sent and received after waking" || bad "post-wake message did not arrive: $AFTER"
# Cursor sanity: the pre-sleep history is gone, so indexes restart from 0.
[[ "$(printf '%s' "$AFTER" | jq -r '[.messages[] | select(.type=="message")] | length')" = "1" ]] \
  && ok "history did not resurrect (indexes restart cleanly)" || bad "unexpected history after wake"

# ─────────────────────────────────────────────────────────────────────────────
step "7. hibernating frees the creator's concurrent-channel slot"
# Cap of 1: without the release, a single sleeping room would block the IP from
# ever creating another for the whole 24h window.
RL_CONC=1 IDLE_MS=1200 boot
C1=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BRIDGE/channels")
[[ "$C1" = "200" ]] && ok "first channel created" || bad "first create returned $C1"
C2=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BRIDGE/channels")
[[ "$C2" = "429" ]] && ok "second create blocked while the first is awake" || bad "expected 429, got $C2"
sleep 2.2
C3=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BRIDGE/channels")
[[ "$C3" = "200" ]] && ok "create allowed once the first room went to sleep" \
  || bad "sleeping room still holds the slot (got $C3) — users get locked out"

# ─────────────────────────────────────────────────────────────────────────────
step "8. a room asleep too long is evicted for real"
IDLE_MS=1000 HIB_MS=2000 boot
read -r CHID2 TOK2 APID2 <<<"$(make_room a)"
sleep 1.8
[[ "$(curl -fsS "$BRIDGE/health" | jq -r '.channels_hibernating')" = "1" ]] \
  && ok "asleep first" || bad "did not hibernate"
sleep 3.0   # past hibernate window; then past the 5s tombstone grace below
GONE=$(curl -sS "$BRIDGE/channels/$CHID2/poll?token=$TOK2&participant_id=$APID2&since=0")
[[ "$(printf '%s' "$GONE" | jq -r '.evicted_reason')" = "evicted_hibernate_expired" ]] \
  && ok "evicted with reason evicted_hibernate_expired" || bad "wrong eviction reason: $GONE"
[[ "$(printf '%s' "$GONE" | jq -r '.hibernating')" = "null" ]] \
  && ok "no longer advertises itself as resumable" || bad "still claims to be resumable: $GONE"
REJ=$(curl -sS -X POST "$BRIDGE/channels/$CHID2/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOK2" '{token:$t, name:"a"}')")
[[ "$(printf '%s' "$REJ" | jq -r '.error')" = "channel_or_token_invalid" ]] \
  && ok "re-join refused after real eviction" || bad "expired room still accepts joins: $REJ"

step "8b. a room with a long-poll parked on it is NOT idle"
# Regression guard for the resume storm found in real-Claude QA (2026-08-12):
# lastActivity is stamped when a poll ARRIVES, so a client sitting in a long
# poll looks quiet for the whole poll window. Hibernating underneath it woke
# Monitor — and cost a full Claude turn — every few seconds against a loop that
# was perfectly healthy. Here the poll window (4s) outlasts the idle window (1s).
IDLE_MS=1000 HIB_MS=600000 POLL_MS=4000 boot
read -r CHID4 TOK4 APID4 <<<"$(make_room a)"
curl -sS -m 8 "$BRIDGE/channels/$CHID4/poll?token=$TOK4&participant_id=$APID4&since=99" >/dev/null 2>&1 &
POLLER=$!
sleep 2.5   # well past the 1s idle window, still inside the 4s poll
[[ "$(curl -fsS "$BRIDGE/health" | jq -r '.channels_hibernating')" = "0" ]] \
  && ok "room with a parked listener was not put to sleep" \
  || bad "hibernated a room someone was actively listening on — resume storm"
wait "$POLLER" 2>/dev/null || true
sleep 2.0   # poll returned, nobody re-polled: now it really is idle
[[ "$(curl -fsS "$BRIDGE/health" | jq -r '.channels_hibernating')" = "1" ]] \
  && ok "once the listener goes away it sleeps normally" \
  || bad "room never slept after the listener left"

step "9. metrics expose the new counters"
M=$(curl -fsS "$BRIDGE/metrics")
for name in agentalk_channels_hibernating agentalk_hibernations_total agentalk_resumes_total; do
  printf '%s' "$M" | grep -q "^$name " && ok "metrics expose $name" || bad "metrics missing $name"
done
printf '%s' "$M" | grep -q 'agentalk_evictions_total{reason="hibernate_expired"}' \
  && ok "metrics expose the hibernate_expired eviction reason" || bad "missing hibernate_expired eviction metric"

step "10. max-lifetime still destroys a room that never goes quiet"
IDLE_MS=600000 LIFE_MS=1500 boot
read -r CHID3 TOK3 APID3 <<<"$(make_room a)"
sleep 2.5
# A participant who is still on the roster learns via the system message during
# the tombstone grace window — that is the documented path phase7 also covers,
# and hibernation must not have disturbed it.
LIFE=$(curl -sS "$BRIDGE/channels/$CHID3/poll?token=$TOK3&participant_id=$APID3&since=0")
printf '%s' "$LIFE" | jq -e '.messages[] | select(.type=="system" and .reason=="evicted_max_lifetime")' >/dev/null \
  && ok "max-lifetime eviction still emits its system message" || bad "max-lifetime broken: $LIFE"
# ...and once the grace window closes it is a plain 404 carrying the reason.
sleep 6
LIFE404=$(curl -sS "$BRIDGE/channels/$CHID3/poll?token=$TOK3&participant_id=$APID3&since=0")
[[ "$(printf '%s' "$LIFE404" | jq -r '.evicted_reason')" = "evicted_max_lifetime" ]] \
  && ok "404 after grace carries evicted_max_lifetime" || bad "post-grace 404 wrong: $LIFE404"
[[ "$(printf '%s' "$LIFE404" | jq -r '.hibernating')" = "null" ]] \
  && ok "a lifetime-evicted room never claims to be resumable" || bad "claims resumable: $LIFE404"

echo
echo "─────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  echo "$(green "ALL PASS") — $PASS checks"
else
  echo "$(red FAILED) — $PASS passed, $FAIL failed"
  exit 1
fi

#!/usr/bin/env bash
# Phase 7 manual QA — rate limits, eviction, observability:
#  - per-IP token bucket for POST /channels and POST /:id/send (429 + Retry-After)
#  - per-IP concurrent-channels cap
#  - idle eviction emits a system message before tombstone, loop exits
#  - max-messages eviction
#  - max-lifetime eviction
#  - /metrics returns Prometheus text-exposition format with expected names
#  - bridge log has no plaintext/ciphertext payloads (metadata only)
#
# Spins up a private bridge on port 3001 with aggressive env overrides so
# the tests run in seconds.

set -u

PORT=3001
BRIDGE="http://localhost:$PORT"
BRIDGE_LOG="/tmp/agentalk-phase7-bridge.log"
PIDFILE="/tmp/agentalk-phase7.pid"
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
need node

cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}
trap cleanup EXIT

step "0. boot a private bridge on port $PORT with aggressive limits"
cd "$(dirname "$0")/../.." || exit 1
# Aggressive limits: 3 channels/hr, 5 msgs/hr, 2 concurrent channels, 2s idle, 10s lifetime, 8 max msgs.
PORT=$PORT \
  RL_CHANNELS_PER_HOUR=3 \
  RL_MESSAGES_PER_HOUR=5 \
  RL_CONCURRENT_CHANNELS_PER_IP=2 \
  CH_IDLE_TIMEOUT_MS=2000 \
  CH_MAX_LIFETIME_MS=10000 \
  CH_SWEEP_INTERVAL_MS=500 \
  CH_MAX_MESSAGES=8 \
  CH_MAX_PARTICIPANTS=4 \
  npx tsx src/bridge/index.ts >"$BRIDGE_LOG" 2>&1 &
echo $! > "$PIDFILE"

# Wait for bridge to be ready
for _ in $(seq 1 20); do
  if curl -fsS "$BRIDGE/health" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
curl -fsS "$BRIDGE/health" >/dev/null && ok "bridge up on $PORT" || { bad "bridge failed to start"; cat "$BRIDGE_LOG"; exit 1; }

step "1. rate limit on POST /channels"
# Create up to the limit (3), then expect 429
RL_OK=0; RL_REJECTED=0
for i in 1 2 3 4 5; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BRIDGE/channels")
  if [[ "$CODE" = "200" ]]; then RL_OK=$((RL_OK+1));
  elif [[ "$CODE" = "429" ]]; then RL_REJECTED=$((RL_REJECTED+1));
  fi
done
# With 3 channels/hr but 2 concurrent cap, we expect ≤3 OK (probably 2 actually because concurrent cap kicks in first), then 429s.
[[ $RL_OK -le 3 && $RL_OK -ge 1 ]] && ok "channel creates succeeded within limit (got $RL_OK)" || bad "unexpected OK count: $RL_OK"
[[ $RL_REJECTED -ge 1 ]] && ok "received >=1 HTTP 429 for channel creation flood (got $RL_REJECTED)" || bad "no 429s emitted: got $RL_REJECTED rejections"

# Retry-After header on at least one rejection
RA=$(curl -s -i -X POST "$BRIDGE/channels" | grep -i '^retry-after:' | head -n1)
[[ -n "$RA" ]] && ok "Retry-After header present on 429: $(echo "$RA" | tr -d '\r')" || bad "missing Retry-After header"

step "2. concurrent-channel cap is enforced even if token bucket has capacity"
# We can't easily separate concurrent-cap from token-bucket rejections without
# resetting the bucket. But the rate-limit error body uses different reasons.
ANY_CONCURRENT=$(grep -c '"reason":"concurrent_channels_limit"' "$BRIDGE_LOG" || true)
ANY_RL=$(grep -c '"reason":"rate_limited"' "$BRIDGE_LOG" || true)
[[ $ANY_CONCURRENT -gt 0 || $ANY_RL -gt 0 ]] && ok "limiter logged a rejection (concurrent=$ANY_CONCURRENT, rate=$ANY_RL)" || bad "no rejection logged"

step "3. send rate-limit"
# Fresh bridge has 5 msgs/hr. Create a clean channel + 2 participants, then flood sends.
# But token bucket on channels is exhausted; restart bridge.
cleanup
sleep 0.3
PORT=$PORT \
  RL_CHANNELS_PER_HOUR=20 \
  RL_MESSAGES_PER_HOUR=4 \
  RL_CONCURRENT_CHANNELS_PER_IP=20 \
  CH_IDLE_TIMEOUT_MS=60000 \
  CH_MAX_LIFETIME_MS=60000 \
  CH_SWEEP_INTERVAL_MS=500 \
  CH_MAX_MESSAGES=1000 \
  CH_MAX_PARTICIPANTS=4 \
  npx tsx src/bridge/index.ts >>"$BRIDGE_LOG" 2>&1 &
echo $! > "$PIDFILE"
for _ in $(seq 1 20); do curl -fsS "$BRIDGE/health" >/dev/null 2>&1 && break; sleep 0.2; done

CR=$(curl -fsS -X POST "$BRIDGE/channels")
CHID=$(echo "$CR" | jq -r '.channel_id')
TOK=$(echo "$CR" | jq -r '.token')
A=$(curl -fsS -X POST "$BRIDGE/channels/$CHID/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOK" '{token:$t, name:"a"}')")
APID=$(echo "$A" | jq -r '.participant_id')

SEND_OK=0; SEND_429=0
for i in 1 2 3 4 5 6 7 8; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BRIDGE/channels/$CHID/send" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$TOK" --arg p "$APID" --arg x "msg-$i" '{token:$t, participant_id:$p, text:$x}')")
  if [[ "$CODE" = "200" ]]; then SEND_OK=$((SEND_OK+1));
  elif [[ "$CODE" = "429" ]]; then SEND_429=$((SEND_429+1));
  fi
done
[[ $SEND_OK -le 5 && $SEND_OK -ge 1 ]] && ok "send succeeded within msg-rate limit (got $SEND_OK)" || bad "unexpected OK count: $SEND_OK"
[[ $SEND_429 -ge 1 ]] && ok "send rate limit emitted 429 (got $SEND_429)" || bad "send never 429'd: got $SEND_429"

step "4. /metrics in Prometheus text-exposition format"
M=$(curl -fsS "$BRIDGE/metrics")
echo "$M" | grep -q '^# HELP agentalk_uptime_seconds'                && ok "agentalk_uptime_seconds present"        || bad "missing uptime metric"
echo "$M" | grep -q '^# HELP agentalk_channels'                       && ok "agentalk_channels present"              || bad "missing channels metric"
echo "$M" | grep -q '^# HELP agentalk_participants'                   && ok "agentalk_participants present"          || bad "missing participants metric"
echo "$M" | grep -q '^# HELP agentalk_channels_created_total'         && ok "agentalk_channels_created_total present"|| bad "missing channels_created_total"
echo "$M" | grep -q '^# HELP agentalk_messages_sent_total'            && ok "agentalk_messages_sent_total present"   || bad "missing messages_sent_total"
echo "$M" | grep -q '^# HELP agentalk_evictions_total'                && ok "agentalk_evictions_total present"       || bad "missing evictions_total"
echo "$M" | grep -q '^# HELP agentalk_ratelimit_rejections_total'     && ok "agentalk_ratelimit_rejections_total present" || bad "missing ratelimit_rejections_total"
echo "$M" | grep -qE 'agentalk_ratelimit_rejections_total\{[^}]+\} [0-9]+' && ok "ratelimit rejection has labeled value" || bad "no labeled-value metric line"

# The bridge has rejected at least 3 sends in step 3 — check the counter reflects that.
RL_MSG_COUNT=$(echo "$M" | grep -E '^agentalk_ratelimit_rejections_total\{kind="messages"\}' | awk '{print $NF}')
[[ "${RL_MSG_COUNT:-0}" -ge 1 ]] && ok "messages-rejection counter incremented (got $RL_MSG_COUNT)" || bad "msg rejection counter is $RL_MSG_COUNT"

step "5. idle eviction emits a system message"
cleanup
sleep 0.3
PORT=$PORT \
  RL_CHANNELS_PER_HOUR=100 \
  RL_MESSAGES_PER_HOUR=1000 \
  RL_CONCURRENT_CHANNELS_PER_IP=100 \
  CH_IDLE_TIMEOUT_MS=1000 \
  CH_MAX_LIFETIME_MS=60000 \
  CH_SWEEP_INTERVAL_MS=300 \
  npx tsx src/bridge/index.ts >>"$BRIDGE_LOG" 2>&1 &
echo $! > "$PIDFILE"
for _ in $(seq 1 20); do curl -fsS "$BRIDGE/health" >/dev/null 2>&1 && break; sleep 0.2; done

CR=$(curl -fsS -X POST "$BRIDGE/channels")
CHID=$(echo "$CR" | jq -r '.channel_id')
TOK=$(echo "$CR" | jq -r '.token')
A=$(curl -fsS -X POST "$BRIDGE/channels/$CHID/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOK" '{token:$t, name:"a"}')")
APID=$(echo "$A" | jq -r '.participant_id')
# Idle 1s + 300ms sweep means a poll within ~2s should fetch a system event.
sleep 2
POLL=$(curl -fsS "$BRIDGE/channels/$CHID/poll?token=$TOK&participant_id=$APID&since=0" || true)
echo "$POLL" | jq -e '.messages[] | select(.type=="system" and .reason=="evicted_idle")' >/dev/null \
  && ok "idle eviction emitted {type:system, reason:evicted_idle}" \
  || bad "no system message after idle: $POLL"

# After tombstone (5s), channel should 404.
sleep 6
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BRIDGE/channels/$CHID/poll?token=$TOK&participant_id=$APID&since=0")
[[ "$CODE" = "404" ]] && ok "channel returns 404 after tombstone window" || bad "expected 404 after tombstone, got $CODE"

# metrics counter incremented
M=$(curl -fsS "$BRIDGE/metrics")
IDLE_COUNT=$(echo "$M" | grep -E '^agentalk_evictions_total\{reason="idle"\}' | awk '{print $NF}')
[[ "${IDLE_COUNT:-0}" -ge 1 ]] && ok "idle-eviction counter is $IDLE_COUNT" || bad "idle counter not incremented"

step "6. max-messages eviction"
cleanup
sleep 0.3
PORT=$PORT \
  RL_CHANNELS_PER_HOUR=100 \
  RL_MESSAGES_PER_HOUR=1000 \
  RL_CONCURRENT_CHANNELS_PER_IP=100 \
  CH_IDLE_TIMEOUT_MS=60000 \
  CH_MAX_LIFETIME_MS=60000 \
  CH_SWEEP_INTERVAL_MS=10000 \
  CH_MAX_MESSAGES=3 \
  npx tsx src/bridge/index.ts >>"$BRIDGE_LOG" 2>&1 &
echo $! > "$PIDFILE"
for _ in $(seq 1 20); do curl -fsS "$BRIDGE/health" >/dev/null 2>&1 && break; sleep 0.2; done

CR=$(curl -fsS -X POST "$BRIDGE/channels")
CHID=$(echo "$CR" | jq -r '.channel_id')
TOK=$(echo "$CR" | jq -r '.token')
A=$(curl -fsS -X POST "$BRIDGE/channels/$CHID/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOK" '{token:$t, name:"a"}')")
APID=$(echo "$A" | jq -r '.participant_id')
# Join emits 1 'join' message. Then send 3 messages → 1 + 3 = 4 ≥ 3 → eviction triggers.
for i in 1 2 3; do
  curl -s -o /dev/null -X POST "$BRIDGE/channels/$CHID/send" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$TOK" --arg p "$APID" --arg x "m-$i" '{token:$t, participant_id:$p, text:$x}')"
done
sleep 0.5
POLL=$(curl -fsS "$BRIDGE/channels/$CHID/poll?token=$TOK&participant_id=$APID&since=0" || true)
echo "$POLL" | jq -e '.messages[] | select(.type=="system" and .reason=="evicted_max_messages")' >/dev/null \
  && ok "max-messages eviction emitted system message" \
  || bad "no max-messages eviction: $POLL"

step "7. max-lifetime eviction"
cleanup
sleep 0.3
PORT=$PORT \
  RL_CHANNELS_PER_HOUR=100 \
  RL_MESSAGES_PER_HOUR=1000 \
  RL_CONCURRENT_CHANNELS_PER_IP=100 \
  CH_IDLE_TIMEOUT_MS=60000 \
  CH_MAX_LIFETIME_MS=1500 \
  CH_SWEEP_INTERVAL_MS=300 \
  npx tsx src/bridge/index.ts >>"$BRIDGE_LOG" 2>&1 &
echo $! > "$PIDFILE"
for _ in $(seq 1 20); do curl -fsS "$BRIDGE/health" >/dev/null 2>&1 && break; sleep 0.2; done

CR=$(curl -fsS -X POST "$BRIDGE/channels")
CHID=$(echo "$CR" | jq -r '.channel_id')
TOK=$(echo "$CR" | jq -r '.token')
A=$(curl -fsS -X POST "$BRIDGE/channels/$CHID/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOK" '{token:$t, name:"a"}')")
APID=$(echo "$A" | jq -r '.participant_id')
# Keep poking to keep "lastActivity" fresh — eviction should still fire on max-lifetime.
for i in 1 2 3 4; do
  sleep 0.5
  curl -s -o /dev/null "$BRIDGE/channels/$CHID/poll?token=$TOK&participant_id=$APID&since=0" -m 1
done
sleep 0.5
POLL=$(curl -fsS "$BRIDGE/channels/$CHID/poll?token=$TOK&participant_id=$APID&since=0" || echo "")
# Either the system message arrives in the poll, or the channel already 404'd
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BRIDGE/channels/$CHID/poll?token=$TOK&participant_id=$APID&since=0")
M=$(curl -fsS "$BRIDGE/metrics")
LIFETIME_COUNT=$(echo "$M" | grep -E '^agentalk_evictions_total\{reason="max_lifetime"\}' | awk '{print $NF}')
[[ "${LIFETIME_COUNT:-0}" -ge 1 ]] && ok "max-lifetime eviction counter is $LIFETIME_COUNT" || bad "lifetime counter not incremented: $LIFETIME_COUNT"

step "8. loop.sh handles system events"
LOOP=$(curl -fsS "$BRIDGE/loop.sh")
echo "$LOOP" | grep -q 'TYPE.*=.*"system"'    && ok "loop.sh checks for type=system events"    || bad "loop.sh missing system-event branch"
echo "$LOOP" | grep -q 'agentalk: SYSTEM'      && ok "loop.sh emits agentalk: SYSTEM line"      || bad "loop.sh doesn't emit SYSTEM line"
echo "$LOOP" | grep -q 'channel_gone'          && ok "loop.sh handles channel_gone 404"         || bad "loop.sh doesn't handle channel_gone"

step "9. bridge logs have no plaintext or ciphertext payloads"
# Bridge logs include 'send' events with byte counts — no 'text' field with content.
grep -E '"text":"[^"]{4,}"' "$BRIDGE_LOG" >/tmp/agentalk-phase7-payload-grep 2>/dev/null
PAYLOAD_HITS=$(wc -l </tmp/agentalk-phase7-payload-grep | tr -d ' ')
[[ "$PAYLOAD_HITS" = "0" ]] && ok "no message payloads in bridge log" || bad "found $PAYLOAD_HITS lines that look like payloads (see /tmp/agentalk-phase7-payload-grep)"

step "10. pages document SYSTEM events"
INIT=$(curl -fsS "$BRIDGE/")
echo "$INIT" | grep -q 'agentalk: SYSTEM' && ok "initiator page mentions SYSTEM events" || bad "initiator page missing SYSTEM docs"
JOIN=$(curl -fsS "$BRIDGE/c/dummy")
echo "$JOIN" | grep -q 'agentalk: SYSTEM' && ok "joiner page mentions SYSTEM events"     || bad "joiner page missing SYSTEM docs"
echo "$INIT" | grep -q 'evicted_idle'      && ok "initiator page lists eviction reasons"  || bad "initiator page missing eviction reasons"

echo
echo "summary: $(green "$PASS passed"), $(red "$FAIL failed")"
[[ $FAIL -eq 0 ]] || exit 1

#!/usr/bin/env bash
# Phase 4 manual QA — verifies the background-poll-loop + Monitor recipe.
# Runs the exact shell loop documented in the LLM-first page against a live
# bridge, sends two messages, and confirms each one appears on the loop's
# stdout within 5 seconds. Also checks the page content advertises the
# background recipe and keeps a fallback section.

set -u

BRIDGE="${BRIDGE:-http://localhost:3000}"
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

# 0. bridge reachable
step "0. bridge reachable"
curl -fsS "$BRIDGE/health" >/dev/null || { bad "bridge not running at $BRIDGE"; exit 1; }
ok "bridge up"

# 1. pages advertise the background recipe
step "1. initiator page advertises background-receive + Monitor + fallback"
init=$(curl -fsS "$BRIDGE/")
echo "$init" | grep -q 'run_in_background'    && ok "initiator page mentions run_in_background" \
                                              || bad "initiator page missing run_in_background"
echo "$init" | grep -q 'Monitor'              && ok "initiator page mentions Monitor"            \
                                              || bad "initiator page missing Monitor"
echo "$init" | grep -q 'agentalk-\$CHANNEL_ID' && ok "initiator page uses per-channel cursor file" \
                                              || bad "initiator page missing cursor file pattern"
echo "$init" | grep -q 'Fallback'              && ok "initiator page has Fallback section"        \
                                              || bad "initiator page missing Fallback section"

step "2. joiner page advertises background-receive + Monitor + fallback"
# need a channel id to fetch /c/:id
CREATE=$(curl -fsS -X POST "$BRIDGE/channels")
CHANNEL_ID=$(echo "$CREATE" | jq -r '.channel_id')
TOKEN=$(echo "$CREATE" | jq -r '.token')
join=$(curl -fsS "$BRIDGE/c/$CHANNEL_ID")
echo "$join" | grep -q 'run_in_background'    && ok "joiner page mentions run_in_background" \
                                              || bad "joiner page missing run_in_background"
echo "$join" | grep -q 'Monitor'              && ok "joiner page mentions Monitor"            \
                                              || bad "joiner page missing Monitor"
echo "$join" | grep -q 'agentalk-\$CHANNEL_ID' && ok "joiner page uses per-channel cursor file" \
                                              || bad "joiner page missing cursor file pattern"
echo "$join" | grep -q 'Fallback'              && ok "joiner page has Fallback section"        \
                                              || bad "joiner page missing Fallback section"

# 3. alice + bob join the channel we created
step "3. alice + bob join"
ALICE=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n alice '{token:$t, name:$n}')")
ALICE_PID=$(echo "$ALICE" | jq -r '.participant_id')
[[ -n "$ALICE_PID" && "$ALICE_PID" != "null" ]] && ok "alice joined" || bad "alice join failed"

BOB=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n bob '{token:$t, name:$n}')")
BOB_PID=$(echo "$BOB" | jq -r '.participant_id')
[[ -n "$BOB_PID" && "$BOB_PID" != "null" ]] && ok "bob joined" || bad "bob join failed"

# 4. start alice's background poll loop — exact recipe from the LLM-first page
step "4. start alice's documented background poll loop"
LOG=$(mktemp -t agentalk-phase4-log.XXXXXX)
CURSOR_FILE="/tmp/agentalk-$CHANNEL_ID.cursor"
echo 0 > "$CURSOR_FILE"

PARTICIPANT_ID="$ALICE_PID"
MY_NAME=alice
(
  set +e
  while true; do
    CUR=$(cat "$CURSOR_FILE" 2>/dev/null)
    RESP=$(curl -fsS -m 55 \
      "$BRIDGE/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$PARTICIPANT_ID&since=$CUR" \
      || true)
    if [ -n "$RESP" ]; then
      echo "$RESP" | jq -r '.cursor' > "$CURSOR_FILE"
      echo "$RESP" | jq -c --arg me "$MY_NAME" '.messages[] | select(.from != $me)'
    fi
  done
) > "$LOG" 2>/dev/null &
LOOP_PID=$!

# small grace period for the loop's first iteration to pull existing events
sleep 0.5
ok "loop started (pid $LOOP_PID, log $LOG)"

# 5. bob sends a message; alice's loop should emit it within 5s
step "5. bob sends message #1 — loop emits a line for it within 5s"
curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/send" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg p "$BOB_PID" --arg x 'hello from bob #1' \
        '{token:$t, participant_id:$p, text:$x}')" >/dev/null

deadline=$(($(date +%s) + 5))
matched=""
while [[ $(date +%s) -lt $deadline ]]; do
  if grep -q '"from":"bob".*hello from bob #1' "$LOG"; then matched="yes"; break; fi
  sleep 0.2
done
[[ "$matched" == "yes" ]] \
  && ok "loop emitted bob's first message" \
  || bad "loop did not emit bob's first message (LOG: $(cat "$LOG"))"

# 6. cursor file moved past 0
step "6. cursor file advanced past 0"
new_cur=$(cat "$CURSOR_FILE")
[[ "$new_cur" =~ ^[0-9]+$ && "$new_cur" -gt 0 ]] \
  && ok "cursor advanced to $new_cur" \
  || bad "cursor still '$new_cur'"

# 7. second message — verifies the loop continues without re-delivering #1
step "7. bob sends message #2 — loop emits it without duplicating #1"
curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/send" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg p "$BOB_PID" --arg x 'hello from bob #2' \
        '{token:$t, participant_id:$p, text:$x}')" >/dev/null

deadline=$(($(date +%s) + 5))
matched=""
while [[ $(date +%s) -lt $deadline ]]; do
  if grep -q '"from":"bob".*hello from bob #2' "$LOG"; then matched="yes"; break; fi
  sleep 0.2
done
[[ "$matched" == "yes" ]] \
  && ok "loop emitted bob's second message" \
  || bad "loop did not emit bob's second message"

dup_count=$(grep -c 'hello from bob #1' "$LOG" || true)
dup_count=${dup_count:-0}
[[ "$dup_count" -eq 1 ]] \
  && ok "message #1 emitted exactly once (no re-delivery)" \
  || bad "message #1 emitted $dup_count times (expected 1)"

# 8. self-filter: alice's own events should be DROPPED before reaching the loop's stdout
step "8. self-filter — alice's own events are NOT in loop output"
grep -q '"from":"alice"' "$LOG" \
  && bad "alice's own events leaked into loop output (self-filter broken)" \
  || ok "alice's own events filtered out of loop output (self-filter works)"

# 9. shutdown
step "9. clean shutdown"
kill "$LOOP_PID" 2>/dev/null
# bash forks subshells for curl; pkill cleans those up too
pkill -P "$LOOP_PID" 2>/dev/null
wait "$LOOP_PID" 2>/dev/null
rm -f "$CURSOR_FILE" "$LOG"
ok "loop killed and temp files removed"

echo
echo "─────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  echo "$(green "ALL PASS") — $PASS checks"
  echo
  echo "Next: two-Claude real-world QA."
  echo "  Terminal A: 'Talk to my other agent at $BRIDGE. Ask what its working directory is.'"
  echo "  Terminal B: paste the join URL terminal A prints — say nothing else."
  echo "  Then DO NOTHING on terminal A. The background loop + Monitor should wake A."
  echo "  Receiver wakes on each incoming message without user prompts."
  exit 0
else
  echo "$(red "FAILED") — $PASS passed, $FAIL failed"
  exit 1
fi

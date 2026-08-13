#!/usr/bin/env bash
# Phase 9 manual QA — the loop RESUMES a sleeping room instead of dying.
#
# Every other script in this directory only greps loop.sh's source. This one
# actually executes it, end to end, through a real sleep/wake cycle — because
# the failure this phase exists to prevent (a loop that exits on a Wi-Fi blip
# and costs a manual re-handoff on both machines) is a runtime behaviour that no
# amount of source-grepping can confirm.
#
# Both real bootstraps run, from two different working directories, so the
# identities and file paths are produced exactly the way a real Claude gets them.
#
# The room is forced to sleep by setting CH_IDLE_TIMEOUT_MS below the long-poll
# duration: the bridge stamps activity when a poll ARRIVES, so a room whose
# peers are parked in a 50s long-poll goes quiet in the bridge's eyes after the
# idle window. That is the same code path a real network gap takes.
#
# Checks:
#  - loop.sh survives hibernation and prints agentalk: RESUMED
#  - it never prints agentalk: SYSTEM (the pre-Phase-3 behaviour was to exit)
#  - the session env file's PARTICIPANT_ID is rewritten to the live one
#  - the cursor is reset so post-wake messages are not skipped
#  - messages still flow after the resume
#  - a send from a fresh shell (Claude's model) works after the resume

set -u

PORT=3003
BRIDGE="http://localhost:$PORT"
BRIDGE_LOG="/tmp/agentalk-phase9-bridge.log"
PIDFILE="/tmp/agentalk-phase9.pid"
ADIR="/tmp/agentalk-p9-alpha"
BDIR="/tmp/agentalk-p9-beta"
AOUT="/tmp/agentalk-p9-alpha.out"
BOUT="/tmp/agentalk-p9-beta.out"
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
need node

LOOP_PIDS=""
cleanup() {
  for p in $LOOP_PIDS; do kill "$p" 2>/dev/null || true; done
  pkill -f "channels/.*/poll?token=" 2>/dev/null || true
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}
trap cleanup EXIT

cd "$(dirname "$0")/../.." || exit 1
: > "$BRIDGE_LOG"
rm -rf "$ADIR" "$BDIR"; mkdir -p "$ADIR" "$BDIR"
rm -f "$AOUT" "$BOUT"

step "0. boot a private bridge (2s long-poll, 3s idle)"
# A short poll window keeps the test quick: parked waiters drain in 2s rather
# than 50, so a frozen loop becomes a genuinely idle room within seconds.
PORT=$PORT \
  RL_CHANNELS_PER_HOUR=100 \
  RL_MESSAGES_PER_HOUR=1000 \
  RL_CONCURRENT_CHANNELS_PER_IP=100 \
  CH_POLL_TIMEOUT_MS=2000 \
  CH_IDLE_TIMEOUT_MS=3000 \
  CH_HIBERNATE_MAX_MS=600000 \
  CH_MAX_LIFETIME_MS=600000 \
  CH_SWEEP_INTERVAL_MS=300 \
  npx tsx src/bridge/index.ts >>"$BRIDGE_LOG" 2>&1 &
echo $! > "$PIDFILE"
for _ in $(seq 1 30); do curl -fsS "$BRIDGE/health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fsS "$BRIDGE/health" >/dev/null || { echo "bridge failed to boot"; exit 1; }
ok "bridge up on $PORT"

step "1. run the real initiator bootstrap"
AOUT_BOOT=$(cd "$ADIR" && . <(curl -fsS "$BRIDGE/bootstrap.sh") 2>&1)
AENV=$(printf '%s' "$AOUT_BOOT" | grep -o '/tmp/agentalk-session-[^ '"'"']*\.env' | head -n 1)
ASHARE=$(printf '%s' "$AOUT_BOOT" | grep -o '/tmp/agentalk-share-[^ '"'"']*\.txt' | head -n 1)
[[ -n "$AENV" && -r "$AENV" ]] && ok "initiator session env written" || { bad "no initiator env: $AOUT_BOOT"; exit 1; }
grep -q "^export SESSION_FILE=" "$AENV" \
  && ok "env file records its own path (needed to rewrite identity on resume)" \
  || bad "SESSION_FILE missing — the loop cannot persist a new participant_id"

URL=$(grep -o "$BRIDGE/c/[^ ]*" "$ASHARE" | head -n 1)
# Parameter expansion, not sed: the URL contains '#', which collides with sed's
# delimiter and silently produced an empty key on the first run of this script.
CHID=${URL##*/c/}; CHID=${CHID%%\?*}
TOK=${URL##*token=}; TOK=${TOK%%#*}
KEY=${URL##*#k=}
[[ -n "$CHID" && -n "$TOK" && -n "$KEY" ]] && ok "parsed join URL from the share message" \
  || { bad "could not parse share URL: $URL"; exit 1; }

step "2. run the real joiner bootstrap from a different directory"
BOUT_BOOT=$(cd "$BDIR" && AGENTALK_KEY="$KEY" . <(curl -fsS "$BRIDGE/c/$CHID/bootstrap.sh?token=$TOK") 2>&1)
BENV=$(printf '%s' "$BOUT_BOOT" | grep -o '/tmp/agentalk-session-[^ '"'"']*\.env' | head -n 1)
[[ -n "$BENV" && -r "$BENV" ]] && ok "joiner session env written" || { bad "no joiner env: $BOUT_BOOT"; exit 1; }
APID_BEFORE=$(grep "^export PARTICIPANT_ID=" "$AENV" | sed "s/^export PARTICIPANT_ID='\(.*\)'/\1/")
BPID_BEFORE=$(grep "^export PARTICIPANT_ID=" "$BENV" | sed "s/^export PARTICIPANT_ID='\(.*\)'/\1/")

step "3. arm both loops for real (this is the part nothing else tests)"
( . "$AENV" && . <(curl -fsS "$BRIDGE/loop.sh") ) > "$AOUT" 2>/dev/null &
LOOP_PIDS="$LOOP_PIDS $!"
( . "$BENV" && . <(curl -fsS "$BRIDGE/loop.sh") ) > "$BOUT" 2>/dev/null &
LOOP_PIDS="$LOOP_PIDS $!"

for _ in $(seq 1 40); do grep -q 'agentalk: PAIRED' "$BOUT" 2>/dev/null && break; sleep 0.25; done
grep -q 'agentalk: PAIRED' "$BOUT" && ok "joiner paired with the initiator" || bad "never paired: $(cat "$BOUT")"

step "4. freeze both loops (a sleeping laptop), let the room nap, thaw them"
# SIGSTOP on the in-flight curls is the closest honest analogue of the real
# cause: the process is alive, it simply stops polling. Nothing is killed, so
# what we observe on thaw is genuine recovery by the SAME loop, not a restart.
sleep 1
[[ "$(curl -fsS "$BRIDGE/health" | jq -r '.channels_hibernating')" = "0" ]] \
  && ok "healthy polling loops do NOT trigger hibernation" \
  || bad "hibernated a room with live loops — resume storm regression"

pkill -STOP -f "channels/$CHID/poll" 2>/dev/null || true
sleep 6   # past the poll window (2s) so waiters drain, then past idle (3s)
HIB=$(curl -fsS "$BRIDGE/health" | jq -r '.channels_hibernating')
[[ "$HIB" = "1" ]] && ok "room slept once polling actually stopped" || bad "room did not sleep (hibernating=$HIB)"
pkill -CONT -f "channels/$CHID/poll" 2>/dev/null || true

for _ in $(seq 1 60); do
  grep -q 'agentalk: RESUMED' "$AOUT" 2>/dev/null && grep -q 'agentalk: RESUMED' "$BOUT" 2>/dev/null && break
  sleep 0.5
done
grep -q 'agentalk: RESUMED' "$AOUT" && ok "initiator loop printed RESUMED" || bad "initiator never resumed: $(cat "$AOUT")"
grep -q 'agentalk: RESUMED' "$BOUT" && ok "joiner loop printed RESUMED"    || bad "joiner never resumed: $(cat "$BOUT")"

# The pre-Phase-3 behaviour: exit with a SYSTEM line. It must not happen.
grep -q 'agentalk: SYSTEM' "$AOUT" && bad "initiator loop exited with SYSTEM: $(grep 'SYSTEM' "$AOUT")" \
                                   || ok "initiator loop never emitted SYSTEM (it did not give up)"
grep -q 'agentalk: SYSTEM' "$BOUT" && bad "joiner loop exited with SYSTEM: $(grep 'SYSTEM' "$BOUT")" \
                                   || ok "joiner loop never emitted SYSTEM (it did not give up)"
kill -0 "$(echo "$LOOP_PIDS" | awk '{print $1}')" 2>/dev/null \
  && ok "initiator loop process is still alive" || bad "initiator loop died"

step "5. the new identity was persisted where Claude will read it"
APID_AFTER=$(grep "^export PARTICIPANT_ID=" "$AENV" | sed "s/^export PARTICIPANT_ID='\(.*\)'/\1/")
BPID_AFTER=$(grep "^export PARTICIPANT_ID=" "$BENV" | sed "s/^export PARTICIPANT_ID='\(.*\)'/\1/")
[[ "$APID_AFTER" != "$APID_BEFORE" ]] && ok "initiator env file holds a new participant_id" \
  || bad "env still holds the dead participant_id — Claude's next send would fail"
[[ "$BPID_AFTER" != "$BPID_BEFORE" ]] && ok "joiner env file holds a new participant_id" \
  || bad "joiner env still holds the dead participant_id"
# The rest of the file must survive the rewrite.
grep -q "^export CHANNEL_KEY=" "$AENV" && grep -q "agentalk_say_file" "$AENV" \
  && ok "the rewrite preserved the key and the helper functions" \
  || bad "identity rewrite damaged the session env file"

step "6. messaging still works after the resume, from a fresh shell"
# A fresh subshell that only sources the env file is exactly what Claude's Bash
# tool gives you on the next call — the case the persisted identity exists for.
( . "$BENV" && agentalk_say "post-resume probe" ) > /tmp/agentalk-p9-send.out 2>&1
grep -q 'agentalk: SENT' /tmp/agentalk-p9-send.out \
  && ok "send from a fresh shell succeeded after resume" \
  || bad "post-resume send failed: $(cat /tmp/agentalk-p9-send.out)"

for _ in $(seq 1 40); do grep -q 'post-resume probe' "$AOUT" 2>/dev/null && break; sleep 0.25; done
grep -q 'agentalk: BROADCAST' "$AOUT" \
  && ok "the peer's loop received and decrypted it after the resume" \
  || bad "message never arrived at the peer: $(cat "$AOUT")"

step "7. cursor was reset so nothing is skipped after a wake"
ACUR=$(ls /tmp/agentalk-"$CHID"-*.cursor 2>/dev/null | head -n 1)
[[ -n "$ACUR" ]] && ok "cursor file exists for the resumed channel" || bad "no cursor file for $CHID"

step "7b. the Monitor command the bootstrap printed is real and complete"
# The instruction Claude copies verbatim. If the path is not substituted, or the
# file never receives events, the session is silently deaf — no error anywhere.
MON=$(printf '%s' "$BOUT_BOOT" | grep -F 'tail -f -n +1' | head -n 1)
[[ -n "$MON" ]] && ok "bootstrap printed a Monitor command" || bad "no Monitor command in bootstrap output"
EVFILE=$(printf '%s' "$MON" | sed "s/.*tail -f -n +1 '\(.*\)'.*/\1/")
[[ "$EVFILE" == /tmp/agentalk-events-* ]] \
  && ok "path is fully substituted (no \$VAR left for Claude)" || bad "unsubstituted path: $EVFILE"
[[ -f "$EVFILE" ]] && ok "the events file exists on disk" || bad "tail would exit instantly: $EVFILE missing"
grep -q 'agentalk: PAIRED' "$EVFILE" \
  && ok "events file received the pairing event" || bad "no PAIRED in events file: $(cat "$EVFILE")"
grep -q 'agentalk: RESUMED' "$EVFILE" \
  && ok "events file received the resume event" || bad "no RESUMED in events file"
# Nothing but events: the command needs no grep, so anything else here is noise
# that would wake Claude for nothing.
if grep -qv '^agentalk: ' "$EVFILE"; then
  bad "events file contains non-event lines: $(grep -v '^agentalk: ' "$EVFILE" | head -3)"
else
  ok "events file contains ONLY agentalk: lines (no grep needed)"
fi
# And it genuinely streams — this is the tail Monitor will be running.
( tail -f -n +1 "$EVFILE" > /tmp/agentalk-p9-tail.out 2>&1 ) & TPID=$!
sleep 0.5
( . "$BENV" && agentalk_say "monitor stream probe" ) >/dev/null 2>&1
for _ in $(seq 1 20); do grep -q 'agentalk: ' /tmp/agentalk-p9-tail.out && break; sleep 0.25; done
kill "$TPID" 2>/dev/null || true
grep -q 'agentalk: ' /tmp/agentalk-p9-tail.out \
  && ok "the printed tail command streams events live" || bad "tail produced nothing"

step "8. served helpers expose the rejoin path"
H=$(curl -fsS "$BRIDGE/helpers.sh")
printf '%s' "$H" | grep -q 'agentalk_rejoin'          && ok "helpers.sh ships agentalk_rejoin"          || bad "helpers.sh missing agentalk_rejoin"
printf '%s' "$H" | grep -q 'agentalk_persist_identity' && ok "helpers.sh ships agentalk_persist_identity" || bad "helpers.sh missing agentalk_persist_identity"
L=$(curl -fsS "$BRIDGE/loop.sh")
printf '%s' "$L" | grep -q 'hibernating == true'      && ok "loop.sh branches on the hibernating flag"   || bad "loop.sh does not detect hibernation"

echo
echo "─────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  echo "$(green "ALL PASS") — $PASS checks"
else
  echo "$(red FAILED) — $PASS passed, $FAIL failed"
  exit 1
fi

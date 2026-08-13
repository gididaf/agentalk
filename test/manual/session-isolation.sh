#!/usr/bin/env bash
# Manual QA — per-session tmp files must be isolated by CHANNEL_ID.
#
# Regression guard for the 2026-08-12 wrong-room bug: both bootstraps named the
# session env file from `basename $(pwd)` alone, so two agentalk sessions
# started from the SAME directory (different channels) wrote to one file. The
# second bootstrap silently overwrote the first session's CHANNEL_ID / TOKEN /
# PARTICIPANT_ID, and because every Claude Bash call re-sources that file, the
# first session's next agentalk_say was delivered into the OTHER channel — with
# a perfectly normal `SENT index=N` receipt. Silent cross-talk.
#
# Everything below runs from ONE cwd on purpose: that is the collision case.

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

need() { command -v "$1" >/dev/null || { echo "missing command: $1"; exit 1; }; }
need curl
need jq
need node

step "0. bridge reachable"
curl -fsS "$BRIDGE/health" >/dev/null || { bad "bridge not running at $BRIDGE"; exit 1; }
ok "bridge up at $BRIDGE"

# Session-file path and channel id are both parsed out of bootstrap stdout —
# the same two strings a real Claude reads. A subshell per run mirrors Claude
# Code's fresh-shell-per-Bash-call model.
run_initiator() {
  ( . <(curl -fsS "$BRIDGE/bootstrap.sh") ) 2>/dev/null
}
session_path_of() { printf '%s' "$1" | grep -o '/tmp/agentalk-session-[^ '"'"']*\.env' | head -n 1; }
share_path_of()   { printf '%s' "$1" | grep -o '/tmp/agentalk-share-[^ '"'"']*\.txt'  | head -n 1; }
channel_of()      { printf '%s' "$1" | sed -n 's/^READY initiator: channel=\([0-9a-f]*\) .*/\1/p' | head -n 1; }

step "1. two initiator bootstraps from the same cwd"
OUT_A=$(run_initiator)
OUT_B=$(run_initiator)

CH_A=$(channel_of "$OUT_A"); CH_B=$(channel_of "$OUT_B")
SF_A=$(session_path_of "$OUT_A"); SF_B=$(session_path_of "$OUT_B")
SH_A=$(share_path_of "$OUT_A");   SH_B=$(share_path_of "$OUT_B")

{ [ -n "$CH_A" ] && [ -n "$CH_B" ]; } || { bad "could not parse channel ids from bootstrap output"; exit 1; }
[ "$CH_A" != "$CH_B" ] && ok "two distinct channels created ($CH_A, $CH_B)" \
  || bad "expected two different channels, got $CH_A twice"

step "2. session env files are distinct and channel-scoped"
if [ -n "$SF_A" ] && [ -n "$SF_B" ] && [ "$SF_A" != "$SF_B" ]; then
  ok "distinct session files"
  echo "      A: $SF_A"
  echo "      B: $SF_B"
else
  bad "COLLISION: both sessions share '$SF_A' — this is the 2026-08-12 bug"
fi

case "$SF_A" in *"$CH_A"*) ok "session file A carries its channel id" ;;
  *) bad "session file A '$SF_A' does not contain channel $CH_A" ;; esac
case "$SF_B" in *"$CH_B"*) ok "session file B carries its channel id" ;;
  *) bad "session file B '$SF_B' does not contain channel $CH_B" ;; esac

step "3. neither file was overwritten by the other"
for pair in "A:$SF_A:$CH_A" "B:$SF_B:$CH_B"; do
  LBL=${pair%%:*}; REST=${pair#*:}; F=${REST%%:*}; WANT=${REST#*:}
  [ -r "$F" ] || { bad "$LBL: session file missing at $F"; continue; }
  GOT=$(grep -E "^export CHANNEL_ID=" "$F" | sed "s/^export CHANNEL_ID='\(.*\)'/\1/")
  [ "$GOT" = "$WANT" ] && ok "$LBL: file still holds its OWN channel ($GOT)" \
    || bad "$LBL: file holds channel '$GOT', expected '$WANT' — clobbered"
done

step "4. share-message files are distinct too"
if [ -n "$SH_A" ] && [ -n "$SH_B" ] && [ "$SH_A" != "$SH_B" ]; then
  ok "distinct share files"
else
  bad "share files collide ('$SH_A') — second bootstrap overwrote the first's URL"
fi

step "5. a send from session A lands in channel A, not channel B"
# The real-world symptom: sourcing A's file and sending must not reach B.
( . "$SF_A" && agentalk_say "isolation probe A" >/dev/null 2>&1 )
A_COUNT=$(curl -fsS "$BRIDGE/channels/$CH_A/poll?token=$(grep -E "^export TOKEN=" "$SF_A" | sed "s/^export TOKEN='\(.*\)'/\1/")&participant_id=$(grep -E "^export PARTICIPANT_ID=" "$SF_A" | sed "s/^export PARTICIPANT_ID='\(.*\)'/\1/")&since=0" \
  | jq '[.messages[] | select(.type == "message")] | length' 2>/dev/null)
B_COUNT=$(curl -fsS "$BRIDGE/channels/$CH_B/poll?token=$(grep -E "^export TOKEN=" "$SF_B" | sed "s/^export TOKEN='\(.*\)'/\1/")&participant_id=$(grep -E "^export PARTICIPANT_ID=" "$SF_B" | sed "s/^export PARTICIPANT_ID='\(.*\)'/\1/")&since=0" \
  | jq '[.messages[] | select(.type == "message")] | length' 2>/dev/null)
[ "${A_COUNT:-0}" = "1" ] && ok "channel A received the probe" || bad "channel A has ${A_COUNT:-?} messages, expected 1"
[ "${B_COUNT:-0}" = "0" ] && ok "channel B received nothing (no cross-talk)" || bad "channel B has ${B_COUNT:-?} messages, expected 0 — CROSS-TALK"

step "6. loop.sh debug log is channel-scoped"
grep -q 'DEBUG_LOG="/tmp/agentalk-debug-\$CHANNEL_ID-\$MY_NAME.log"' src/page/loop.sh \
  && ok "loop.sh writes a per-channel debug log" \
  || bad "loop.sh debug log is not channel-scoped — two loops interleave into one file"

echo
echo "────────────────────────────────"
echo "  $(green "PASS: $PASS")   $(red "FAIL: $FAIL")"
[ "$FAIL" -eq 0 ] || exit 1

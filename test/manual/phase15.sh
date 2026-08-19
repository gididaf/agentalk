#!/usr/bin/env bash
# Phase 15 manual QA — the loop's failure modes must be VISIBLE.
#
# Every check here is a regression test for a bug that shipped, and all of them
# share one shape: a check that returned a success-shaped value on the path
# where it did nothing. Debugged 2026-08-19 from a channel both peers had
# written off as "an encryption key mismatch". It was not a key mismatch, and
# it was not the bridge.
#
# Checks:
#  - loop.sh REFUSES to run when executed instead of sourced (the original bug:
#    exported vars survive into a child shell, shell functions do not, so the
#    loop looked healthy and died on its first line)
#  - loop.sh REFUSES to run on an incomplete session env
#  - hello_send_failed carries a NON-ZERO rc (it always printed rc=0, because a
#    $(date) in the same string reset $? before it expanded)
#  - the key= status matrix: verified / partial / unverified / abort
#  - KEY_MISMATCH and KEY_UNVERIFIED are emitted at runtime, once each
#  - PEER_STALE reports a real number for ONE peer (zsh does not word-split
#    unquoted expansions, so `for N in $LIST` ran once over the whole list)
#  - the source-level patterns behind those last two cannot come back
#
# Phases 9 and 12 also execute loop.sh; this one additionally runs it under
# zsh where available, because two of these bugs are zsh-only and invisible
# to a bash-only test.

set -u

PORT=3007
BRIDGE="http://localhost:$PORT"
BRIDGE_LOG="/tmp/agentalk-phase15-bridge.log"
PIDFILE="/tmp/agentalk-phase15.pid"
INITDIR="/tmp/agentalk-p15-init"
GOODDIR="/tmp/agentalk-p15-good"
PASS=0
FAIL=0

color()  { printf "\033[%sm%s\033[0m" "$1" "$2"; }
green()  { color "32" "$1"; }
red()    { color "31" "$1"; }
yellow() { color "33" "$1"; }
ok()   { echo "  $(green PASS) — $1"; PASS=$((PASS+1)); }
bad()  { echo "  $(red FAIL) — $1"; FAIL=$((FAIL+1)); }
step() { echo; echo "$(yellow "▸ $1")"; }

# `grep -c` PRINTS the count and EXITS NON-ZERO when the count is zero. So
# `$(grep -c x f || echo 0)` yields "0\n0", which never equals "0" — the
# assertion then fails on exactly the case it was written to accept. Same shape
# as the bugs this file guards: a check that misreports its own do-nothing path.
count() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }

need() { command -v "$1" >/dev/null || { echo "missing command: $1"; exit 1; }; }
need curl
need jq
need node

cleanup() {
  if [[ -f "$PIDFILE" ]]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
  rm -rf "$INITDIR" "$GOODDIR" /tmp/agentalk-p15-*
  rm -f /tmp/agentalk-session-*-agentalk-p15-*.env \
        /tmp/agentalk-events-*-agentalk-p15-*.log \
        /tmp/agentalk-debug-*-agentalk-p15-*.log
}
trap cleanup EXIT
cd "$(dirname "$0")/../.." || exit 1
: > "$BRIDGE_LOG"

# The loop is SOURCED in real use, and on macOS that means zsh. Two of the bugs
# below only reproduce there, so prefer zsh when it exists and say which shell
# actually ran.
if command -v zsh >/dev/null 2>&1; then LOOPSH=zsh; else LOOPSH=bash; fi

step "0. boot a private bridge"
PORT=$PORT \
  RL_CHANNELS_PER_HOUR=1000 RL_MESSAGES_PER_HOUR=10000 \
  RL_CONCURRENT_CHANNELS_PER_IP=1000 RL_JOINS_PER_HOUR=1000 \
  CH_POLL_TIMEOUT_MS=1000 \
  npx tsx src/bridge/index.ts >>"$BRIDGE_LOG" 2>&1 &
echo $! > "$PIDFILE"
for _ in $(seq 1 40); do curl -fsS "$BRIDGE/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fsS "$BRIDGE/health" >/dev/null || { echo "bridge failed to boot"; exit 1; }
ok "bridge up on $PORT (loop tests will run under $LOOPSH)"

mkdir -p "$INITDIR" "$GOODDIR"
INIT_OUT=$( cd "$INITDIR" && . <(curl -fsS "$BRIDGE/bootstrap.sh") 2>&1 )
CH=$(printf '%s' "$INIT_OUT" | sed -n 's/.*READY initiator: channel=\([0-9a-f]*\).*/\1/p')
[ -n "$CH" ] && ok "initiator bootstrapped (channel=$CH)" || { bad "initiator bootstrap failed"; echo "$INIT_OUT"; exit 1; }
ISF="/tmp/agentalk-session-$CH-agentalk-p15-init_.env"
KEY=$(grep "^export CHANNEL_KEY=" "$ISF" | sed "s/^export CHANNEL_KEY='\(.*\)'/\1/")
TK=$(grep "^export TOKEN=" "$ISF" | sed "s/^export TOKEN='\(.*\)'/\1/")

# ---------------------------------------------------------------- guards ----

step "1. loop.sh refuses to run when EXECUTED instead of sourced"
# Exactly the shipped bug: every var the session env exports survives into the
# child, so the loop starts up looking entirely correct. Only the functions are
# missing. Before the guard this produced a bare `hello_send_failed` and a
# permanently deaf session.
# EVERY loop invocation below is wrapped in `timeout`. The guard makes the loop
# exit in milliseconds, so on healthy code the timeout is never reached — but a
# regression removes the exit, and an unbounded run would then HANG this script
# instead of failing it. A test that hangs on regression is worse than no test:
# it looks like a slow machine. (Found by mutation-testing this very file.)
G1=$( . "$ISF" && EVENTS_FILE=/dev/null timeout 6 "$LOOPSH" <(curl -fsS "$BRIDGE/loop.sh") 2>/dev/null )
G1RC=$?
printf '%s' "$G1" | grep -q 'agentalk: FATAL loop_not_sourced' \
  && ok "emits FATAL loop_not_sourced" || bad "no FATAL loop_not_sourced (got: $(printf '%s' "$G1" | head -1))"
printf '%s' "$G1" | grep -q 'agentalk_send' \
  && ok "names the missing helper" || bad "does not name the missing helper"
printf '%s' "$G1" | grep -qi 'must be SOURCED' \
  && ok "says it must be sourced" || bad "does not say it must be sourced"
printf '%s' "$G1" | grep -q "$ISF" \
  && ok "prints the literal session env path to re-run" || bad "does not print the session env path"
[ "$G1RC" -ne 0 ] \
  && ok "exits non-zero ($G1RC)" || bad "exited 0 — a dead loop must not look successful"
printf '%s' "$G1" | grep -q 'hello_send_failed' \
  && bad "still reports hello_send_failed (guard must fire first)" \
  || ok "does not fall through to hello_send_failed"

step "2. loop.sh refuses to run on an incomplete session env"
G2=$( timeout 6 "$LOOPSH" -c \
  ". '$ISF'; unset CHANNEL_KEY TOKEN; EVENTS_FILE=/dev/null; . <(curl -fsS '$BRIDGE/loop.sh')" 2>/dev/null )
printf '%s' "$G2" | grep -q 'agentalk: FATAL loop_env_incomplete' \
  && ok "emits FATAL loop_env_incomplete" || bad "no FATAL loop_env_incomplete (got: $(printf '%s' "$G2" | head -1))"
printf '%s' "$G2" | grep -q 'TOKEN' && printf '%s' "$G2" | grep -q 'CHANNEL_KEY' \
  && ok "names every missing variable" || bad "does not name the missing variables"

step "3. hello_send_failed carries a NON-ZERO rc"
# Regression: `echo \"[\$(date)] failed rc=\$?\"` reported date's status, always
# 0 — so a missing function (127) was logged as success next to FAILED.
J1DIR="/tmp/agentalk-p15-joinA"; mkdir -p "$J1DIR"
( cd "$J1DIR" && AGENTALK_KEY=$KEY . <(curl -fsS "$BRIDGE/c/$CH/bootstrap.sh?token=$TK") >/dev/null 2>&1 )
JSF="/tmp/agentalk-session-$CH-agentalk-p15-joinA_.env"
if [ -f "$JSF" ]; then
  # Unreachable bridge -> the send genuinely fails, so the rc is real.
  G3=$( timeout 10 "$LOOPSH" -c \
    ". '$JSF'; BRIDGE_URL='http://127.0.0.1:9'; EVENTS_FILE=/dev/null; . <(curl -fsS '$BRIDGE/loop.sh')" 2>/dev/null )
  printf '%s' "$G3" | grep -q 'agentalk: SEND_FAILED' \
    && ok "the underlying SEND_FAILED reason is printed too" || bad "no SEND_FAILED line before the SYSTEM line"
  RCVAL=$(printf '%s' "$G3" | sed -n 's/.*hello_send_failed rc=\([0-9]*\).*/\1/p' | head -1)
  [ -n "$RCVAL" ] \
    && ok "hello_send_failed carries an rc (rc=$RCVAL)" || bad "hello_send_failed carries no rc"
  [ -n "$RCVAL" ] && [ "$RCVAL" != "0" ] \
    && ok "rc is non-zero — the \$(date) clobber has not come back" \
    || bad "rc=0 next to a FAILED line: \$? was reset before it was read"
else
  bad "joiner bootstrap did not write $JSF"
fi

# ------------------------------------------------------------ key status ----

step "4. key= status matrix"
GOOD_OUT=$( cd "$GOODDIR" && AGENTALK_KEY=$KEY . <(curl -fsS "$BRIDGE/c/$CH/bootstrap.sh?token=$TK") 2>&1 )
printf '%s' "$GOOD_OUT" | grep -q 'key=verified' \
  && ok "matching key  -> key=verified" || bad "matching key did not report verified"

BADDIR="/tmp/agentalk-p15-bad"; mkdir -p "$BADDIR"
WRONG=$(printf '%s' "$KEY" | tr '0-9a-f' '1-9a-f0')
BAD_OUT=$( cd "$BADDIR" && AGENTALK_KEY=$WRONG . <(curl -fsS "$BRIDGE/c/$CH/bootstrap.sh?token=$TK") 2>&1 )
printf '%s' "$BAD_OUT" | grep -q 'fingerprint mismatch' \
  && ok "wrong key    -> bootstrap aborts" || bad "wrong key did not abort"
printf '%s' "$BAD_OUT" | grep -q 'disagreeing peers' \
  && ok "names the disagreeing peers (not just the first)" || bad "does not name disagreeing peers"
[ -f "/tmp/agentalk-session-$CH-agentalk-p15-bad_.env" ] \
  && bad "wrong-key joiner still wrote a session file" \
  || ok "wrong-key joiner leaves no session file behind"

# A peer that publishes NO fingerprint used to silently disable the check for
# the whole room while the bootstrap printed a reassuring `key=unverified`.
CR2=$(curl -fsS -X POST "$BRIDGE/channels")
CH2=$(printf '%s' "$CR2" | jq -r '.channel_id'); TK2=$(printf '%s' "$CR2" | jq -r '.token')
KEY2=$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')
curl -fsS -X POST "$BRIDGE/channels/$CH2/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TK2" '{token:$t, name:"nofppeer"}')" >/dev/null
NOFPDIR="/tmp/agentalk-p15-nofp"; mkdir -p "$NOFPDIR"
NOFP_OUT=$( cd "$NOFPDIR" && AGENTALK_KEY=$KEY2 . <(curl -fsS "$BRIDGE/c/$CH2/bootstrap.sh?token=$TK2") 2>&1 )
printf '%s' "$NOFP_OUT" | grep -q 'key=unverified' \
  && ok "peer with no fingerprint -> key=unverified" || bad "no-fingerprint peer did not report unverified"
printf '%s' "$NOFP_OUT" | grep -q 'NOTE: key=unverified' \
  && ok "explains that the check was SKIPPED" || bad "unverified is still a bare word with no explanation"
printf '%s' "$NOFP_OUT" | grep -q 'nofppeer' \
  && ok "names the peer responsible" || bad "does not name the unverifiable peer"

# Some peers agree, one does not: we are not the broken party, so join, but say so.
curl -fsS -X POST "$BRIDGE/channels/$CH2/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TK2" '{token:$t, name:"wrongfp", key_fp:"deadbeefdeadbeef"}')" >/dev/null
PARTDIR="/tmp/agentalk-p15-part"; mkdir -p "$PARTDIR"
PART_OUT=$( cd "$PARTDIR" && AGENTALK_KEY=$KEY2 . <(curl -fsS "$BRIDGE/c/$CH2/bootstrap.sh?token=$TK2") 2>&1 )
printf '%s' "$PART_OUT" | grep -q 'key=partial' \
  && ok "mixed room  -> key=partial (joins; does not abort)" || bad "mixed room did not report partial"
printf '%s' "$PART_OUT" | grep -q 'wrongfp' \
  && ok "names the mismatched peer" || bad "does not name the mismatched peer"

# ------------------------------------------------------- runtime events -----

step "5. loop.sh reports key trouble at runtime, once per peer"
# The bootstrap check is one-shot at join, so it cannot cover a peer who
# arrives later. The roster carries key_fp on every poll.
NSF="/tmp/agentalk-session-$CH2-agentalk-p15-nofp_.env"
if [ -f "$NSF" ]; then
  EV5="/tmp/agentalk-p15-ev5.log"; : > "$EV5"
  ( . "$NSF" && EVENTS_FILE="$EV5" timeout 8 "$LOOPSH" -c \
      ". '$NSF' && EVENTS_FILE='$EV5' . <(curl -fsS '$BRIDGE/loop.sh')" ) >/dev/null 2>&1
  # The loop runs as the bootstrap joiner. Its peers are `nofppeer` (raw API
  # join, publishes no fingerprint — panel-side's exact shape) and `wrongfp`
  # (publishes a different one).
  grep -q 'agentalk: KEY_UNVERIFIED name=nofppeer' "$EV5" 2>/dev/null \
    && ok "emits KEY_UNVERIFIED for the peer publishing no fingerprint" \
    || bad "no KEY_UNVERIFIED event — an unverifiable peer is invisible again"
  grep -q 'agentalk: KEY_MISMATCH name=wrongfp' "$EV5" 2>/dev/null \
    && ok "emits KEY_MISMATCH for the wrong-key peer" || bad "no KEY_MISMATCH event"
  [ "$(count 'agentalk: KEY_MISMATCH' "$EV5")" = "1" ] \
    && ok "KEY_MISMATCH is emitted exactly once, not per poll" || bad "KEY_MISMATCH repeated across polls"
  [ "$(count 'agentalk: KEY_UNVERIFIED' "$EV5")" = "1" ] \
    && ok "KEY_UNVERIFIED is emitted exactly once, not per poll" || bad "KEY_UNVERIFIED repeated across polls"
  grep -qE 'agentalk: KEY_(MISMATCH|UNVERIFIED) name=agentalk-p15-nofp_' "$EV5" 2>/dev/null \
    && bad "the loop reported ITSELF" || ok "never reports itself"
else
  bad "no session file for the runtime key check"
fi

step "6. PEER_STALE names ONE peer and reports a real number"
# zsh does not word-split unquoted expansions, so `for N in \$NOW_STALE` ran
# once with the whole space-joined list as a single name. The jq lookup then
# matched nothing and the event went out as `unseen=s`, no number.
GSF="/tmp/agentalk-session-$CH-agentalk-p15-good_.env"
if [ -f "$GSF" ]; then
  EV6="/tmp/agentalk-p15-ev6.log"; : > "$EV6"
  sleep 3   # let the non-polling peers age past the threshold
  ( timeout 10 "$LOOPSH" -c \
      ". '$GSF' && EVENTS_FILE='$EV6' AGENTALK_STALE_S=1 . <(curl -fsS '$BRIDGE/loop.sh')" ) >/dev/null 2>&1
  STALE=$(grep -m1 'agentalk: PEER_STALE' "$EV6" 2>/dev/null)
  if [ -n "$STALE" ]; then
    ok "PEER_STALE emitted ($STALE)"
    printf '%s' "$STALE" | grep -qE 'unseen=[0-9]+s' \
      && ok "unseen= carries digits" || bad "unseen= has no number — the word-split bug is back"
    printf '%s' "$STALE" | grep -qE '^agentalk: PEER_STALE name=[^ ]+ unseen=' \
      && ok "names exactly one peer per line" || bad "name= contains a space — whole list in one event"
    # PEER_BACK must NOT fire while the peer is still gone. None of the peers in
    # this room are polling, so a single BACK here is a false positive. The
    # membership test needs the name bounded by spaces on both sides, and
    # NOW_STALE lost its trailing space once already — which produced a
    # STALE/BACK oscillation on every poll while the peer was still absent.
    [ "$(count 'agentalk: PEER_BACK' "$EV6")" = "0" ] \
      && ok "PEER_BACK does NOT fire while the peer is still stale" \
      || bad "false PEER_BACK: $(count 'agentalk: PEER_BACK' "$EV6") emitted for a peer that never returned"
    # The oscillation signature itself: STALE is a TRANSITION, so each peer may
    # appear at most once however many polls elapse. Counting distinct names
    # rather than a fixed total keeps this correct as the room's size changes.
    ST_TOTAL=$(count 'agentalk: PEER_STALE' "$EV6")
    ST_UNIQ=$(grep -o 'agentalk: PEER_STALE name=[^ ]*' "$EV6" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    [ "$ST_TOTAL" = "$ST_UNIQ" ] \
      && ok "PEER_STALE is a transition, not a per-poll repeat ($ST_TOTAL line(s), $ST_UNIQ peer(s))" \
      || bad "PEER_STALE repeated: $ST_TOTAL lines for only $ST_UNIQ peer(s) — the stale set is not sticking"
  else
    bad "no PEER_STALE event emitted within the window"
  fi
else
  bad "no session file for the stale check"
fi

# ------------------------------------------------------------- source -------

step "7. the source-level patterns behind those bugs cannot return"
L=src/page/loop.sh
grep -nE '^[^#]*\bfor +[A-Za-z_]+ +in +\$[A-Za-z_]' "$L" >/dev/null \
  && bad "an unquoted-expansion for-loop is back in loop.sh (zsh will not split it)" \
  || ok "no unquoted-expansion for-loops in loop.sh"
grep -nE '^[^#]*rc=\$\?' "$L" | grep -q '\$(' \
  && bad "an rc=\$? is read after a command substitution in the same line" \
  || ok "no rc=\$? read after a command substitution"
grep -q 'command -v "\$_fn"' "$L" \
  && ok "loop.sh still checks its helpers are in scope" || bad "the helper precondition guard is gone"
for tok in 'KEY_MISMATCH' 'KEY_UNVERIFIED' 'loop_not_sourced' 'loop_env_incomplete'; do
  grep -q "$tok" src/page/joiner.md \
    && ok "joiner.md documents $tok" || bad "joiner.md does not document $tok"
done
grep -q 'Read the `key=` field' src/page/joiner.md \
  && ok "joiner.md documents the key= status field" || bad "joiner.md still leaves key= undocumented"

echo
echo "$(green "PASS: $PASS")   $( [ "$FAIL" -gt 0 ] && red "FAIL: $FAIL" || echo "FAIL: 0")"
[ "$FAIL" -eq 0 ] || exit 1

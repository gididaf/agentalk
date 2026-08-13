#!/usr/bin/env bash
# Phase 12 manual QA — the loop recognises a human peer and coalesces bursts.
#
# The bug this exists to prevent: a person types the way people type — "hey" /
# "about the auth thing" / "ignore the first bit", three messages in five
# seconds. Claude takes one prompt at a time, so one event per message makes it
# start answering the first, get interrupted by the second, and reply three
# times over itself. Agents never do this, so no earlier phase covers it.
#
# Like phase9.sh (and unlike every other script here) this EXECUTES loop.sh
# against a real bridge rather than grepping it, because buffering across poll
# cycles is a runtime behaviour no amount of source-reading can confirm.
#
# Checks:
#  - a HELLO carrying human:true produces HUMAN_JOINED, not WELCOMED
#  - resumed:true is reported as resumed=1
#  - an ordinary agent HELLO still produces WELCOMED (no regression)
#  - three quick messages from a human collapse into ONE event, msgs=3, with
#    every body present and in order
#  - the same burst from an AGENT still produces three separate events
#  - AGENTALK_COALESCE_S=0 restores immediate per-message emission
#  - a name containing a newline still yields exactly one event line

set -u

PORT=3005
BRIDGE="http://localhost:$PORT"
BRIDGE_LOG="/tmp/agentalk-phase12-bridge.log"
PIDFILE="/tmp/agentalk-phase12.pid"
ADIR="/tmp/agentalk-p12-alpha"
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
  if [[ -f "$PIDFILE" ]]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
}
trap cleanup EXIT

cd "$(dirname "$0")/../.." || exit 1
: > "$BRIDGE_LOG"
rm -rf "$ADIR"; mkdir -p "$ADIR"

# --- helpers: act as a peer over the wire, using the helpers.sh recipe -------
enc() { # enc <key-hex> <aad> <plaintext-json>
  K="$1" A="$2" P="$3" node -e '
    const c=require("crypto");
    const n=c.randomBytes(12);
    const ci=c.createCipheriv("aes-256-gcm",Buffer.from(process.env.K,"hex"),n);
    ci.setAAD(Buffer.from(process.env.A,"utf8"));
    const ct=Buffer.concat([ci.update(process.env.P,"utf8"),ci.final()]);
    process.stdout.write(Buffer.concat([n,ct,ci.getAuthTag()]).toString("base64"));'
}

peer_send() { # peer_send <name> <pid> <plaintext-json>
  local blob
  blob=$(enc "$KEY" "$CHANNEL_ID:$1" "$3")
  curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/send" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$TOKEN" --arg p "$2" --arg x "$blob" \
          '{token:$t, participant_id:$p, text:$x}')" >/dev/null
}

peer_join() { # peer_join <name> -> participant_id
  curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$TOKEN" --arg n "$1" --arg f "$KEY_FP" \
          '{token:$t, name:$n, key_fp:$f}')" | jq -r '.participant_id'
}

# grep -c already prints 0 when there are no matches; it just exits non-zero.
# `|| echo 0` would append a SECOND zero and every arithmetic test downstream
# would then choke on "0\n0".
events() {
  local n
  n=$(grep -c "$1" "$AEVENTS" 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

step "0. boot a private bridge"
PORT=$PORT \
  RL_CHANNELS_PER_HOUR=100 RL_MESSAGES_PER_HOUR=1000 RL_CONCURRENT_CHANNELS_PER_IP=100 \
  CH_POLL_TIMEOUT_MS=2000 CH_IDLE_TIMEOUT_MS=600000 \
  CH_MAX_LIFETIME_MS=600000 CH_SWEEP_INTERVAL_MS=1000 \
  npx tsx src/bridge/index.ts >>"$BRIDGE_LOG" 2>&1 &
echo $! > "$PIDFILE"
for _ in $(seq 1 40); do curl -fsS "$BRIDGE/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fsS "$BRIDGE/health" >/dev/null || { echo "bridge failed to boot"; exit 1; }
ok "bridge up on $PORT"

step "1. run the real initiator bootstrap, then arm the real loop"
BOOT=$(cd "$ADIR" && . <(curl -fsS "$BRIDGE/bootstrap.sh") 2>&1)
AENV=$(printf '%s' "$BOOT" | grep -o '/tmp/agentalk-session-[^ '"'"']*\.env' | head -n 1)
AEVENTS=$(printf '%s' "$BOOT" | grep -o '/tmp/agentalk-events-[^ '"'"']*\.log' | head -n 1)
[ -n "$AENV" ] && [ -f "$AENV" ] && ok "bootstrap wrote $AENV" || { bad "no session env"; exit 1; }

# shellcheck disable=SC1090
. "$AENV"
KEY="$CHANNEL_KEY"
KEY_FP=$(K="$KEY" node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.env.K).digest("hex").slice(0,16))')

( . "$AENV" && AGENTALK_COALESCE_S=2 AGENTALK_COALESCE_MAX_S=8 \
  . <(curl -fsS "$BRIDGE/loop.sh") ) >/dev/null 2>&1 &
LOOP_PIDS="$!"
sleep 2
ok "loop armed (coalesce window 2s, cap 8s)"

# ---------------------------------------------------------------------------
step "2. a human HELLO produces HUMAN_JOINED, not WELCOMED"
DANA=$(peer_join "Dana")
peer_send "Dana" "$DANA" '{"hello":"aaaabbbbccccdddd","human":true}'
sleep 3
[ "$(events 'HUMAN_JOINED name=Dana resumed=0')" -ge 1 ] \
  && ok "HUMAN_JOINED name=Dana resumed=0" \
  || bad "no HUMAN_JOINED for Dana"
[ "$(events 'WELCOMED Dana')" -eq 0 ] \
  && ok "did not also print WELCOMED for the human" \
  || bad "printed WELCOMED for a human peer"

# The auto-WELCOME must still actually go out, or the browser never pairs.
DP=$(curl -fsS "$BRIDGE/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$DANA&since=0&")
WBLOB=$(printf '%s' "$DP" | jq -r --arg me "$MY_NAME" \
  '[.messages[] | select(.from==$me and .type=="message") | .text] | first // ""')
WPT=$(K="$KEY" A="$CHANNEL_ID:$MY_NAME" B="$WBLOB" node -e '
  const c=require("crypto");
  const raw=Buffer.from(process.env.B,"base64");
  const d=c.createDecipheriv("aes-256-gcm",Buffer.from(process.env.K,"hex"),raw.subarray(0,12));
  d.setAAD(Buffer.from(process.env.A,"utf8"));
  d.setAuthTag(raw.subarray(raw.length-16));
  process.stdout.write(Buffer.concat([d.update(raw.subarray(12,raw.length-16)),d.final()]).toString());
' 2>/dev/null)
printf '%s' "$WPT" | jq -e '.welcome == "aaaabbbbccccdddd" and .to == "Dana"' >/dev/null 2>&1 \
  && ok "the human still received a real WELCOME (pairing works)" \
  || bad "human never got a WELCOME (got: $WPT)"

step "3. an agent HELLO still produces WELCOMED"
BOT=$(peer_join "botpeer")
peer_send "botpeer" "$BOT" '{"hello":"1111222233334444"}'
sleep 3
[ "$(events 'WELCOMED botpeer')" -ge 1 ] \
  && ok "WELCOMED botpeer (agent path unchanged)" \
  || bad "agent HELLO did not produce WELCOMED"
[ "$(events 'HUMAN_JOINED name=botpeer')" -eq 0 ] \
  && ok "agent not misreported as human" \
  || bad "agent reported as HUMAN_JOINED"

# ---------------------------------------------------------------------------
step "4. a human's burst collapses into ONE event"
BEFORE=$(events 'human=1')
peer_send "Dana" "$DANA" '{"text":"hey"}'
sleep 0.4
peer_send "Dana" "$DANA" '{"text":"about the auth thing"}'
sleep 0.4
peer_send "Dana" "$DANA" '{"text":"actually ignore the first bit"}'
sleep 6
AFTER=$(events 'human=1')
DELTA=$((AFTER - BEFORE))
[ "$DELTA" -eq 1 ] \
  && ok "three quick messages produced exactly ONE event" \
  || bad "expected 1 event, got $DELTA"

LINE=$(grep 'human=1' "$AEVENTS" | tail -n 1)
printf '%s' "$LINE" | grep -q 'msgs=3' \
  && ok "event reports msgs=3" \
  || bad "event does not say msgs=3: $LINE"
printf '%s' "$LINE" | grep -q 'from=Dana' \
  && ok "event names the sender" \
  || bad "event has no from=Dana: $LINE"

BURSTFILE=$(printf '%s' "$LINE" | sed -n 's/.*file=\([^ ]*\).*/\1/p')
if [ -n "$BURSTFILE" ] && [ -f "$BURSTFILE" ]; then
  ok "burst file exists: $BURSTFILE"
  BODY=$(cat "$BURSTFILE")
  printf '%s' "$BODY" | grep -q 'hey' && \
  printf '%s' "$BODY" | grep -q 'about the auth thing' && \
  printf '%s' "$BODY" | grep -q 'actually ignore the first bit' \
    && ok "all three bodies present in the file" \
    || bad "burst file is missing bodies: $BODY"
  FIRST=$(printf '%s' "$BODY" | head -n 1)
  [ "$FIRST" = "hey" ] \
    && ok "messages are in order (first is 'hey')" \
    || bad "first line is '$FIRST', expected 'hey'"
else
  bad "burst file missing from the event line: $LINE"
fi

step "5. exactly one line per event, even for a burst"
BURSTLINES=$(events '^agentalk: ')
TOTALLINES=$(wc -l < "$AEVENTS" | tr -d ' ')
[ "$BURSTLINES" -eq "$TOTALLINES" ] \
  && ok "every line in the events file is a single agentalk: event ($TOTALLINES)" \
  || bad "events file has $TOTALLINES lines but only $BURSTLINES events — a body leaked in"

# ---------------------------------------------------------------------------
step "6. the same burst from an AGENT is NOT coalesced"
BEFORE=$(events 'from=botpeer')
peer_send "botpeer" "$BOT" '{"text":"agent one"}'
sleep 0.4
peer_send "botpeer" "$BOT" '{"text":"agent two"}'
sleep 0.4
peer_send "botpeer" "$BOT" '{"text":"agent three"}'
sleep 5
AFTER=$(events 'from=botpeer')
DELTA=$((AFTER - BEFORE))
[ "$DELTA" -eq 3 ] \
  && ok "agent messages still emit one event each ($DELTA)" \
  || bad "agent burst produced $DELTA events, expected 3 — coalescing leaked into the agent path"

step "7. a hostile name cannot split an event line"
# Injected straight through the API, bypassing the browser's own sanitizer.
EVIL=$(printf 'ev\nil')
EPID=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n "$EVIL" '{token:$t, name:$n}')" | jq -r '.participant_id // empty')
if [ -n "$EPID" ]; then
  BEFORE=$(wc -l < "$AEVENTS" | tr -d ' ')
  peer_send "$EVIL" "$EPID" '{"hello":"9999888877776666"}'
  sleep 3
  AFTER=$(wc -l < "$AEVENTS" | tr -d ' ')
  [ $((AFTER - BEFORE)) -eq 1 ] \
    && ok "newline in a peer name still produced exactly one event line" \
    || bad "newline in a name produced $((AFTER - BEFORE)) lines"
  [ "$(events '^agentalk: ')" -eq "$AFTER" ] \
    && ok "events file still contains only agentalk: lines" \
    || bad "a non-event line appeared in the events file"
else
  # Phase D rejects these at the bridge; once that lands this is the right outcome.
  ok "bridge refused a name containing a newline"
fi

# ---------------------------------------------------------------------------
step "8. AGENTALK_COALESCE_S=0 disables buffering"
for p in $LOOP_PIDS; do kill "$p" 2>/dev/null || true; done
sleep 1
: > "$AEVENTS"
( . "$AENV" && AGENTALK_COALESCE_S=0 . <(curl -fsS "$BRIDGE/loop.sh") ) >/dev/null 2>&1 &
LOOP_PIDS="$!"
# A fresh loop resets its cursor to 0 and replays the whole room, so it re-emits
# every earlier message — including the HELLO that marks Dana as human. Let that
# settle and take the baseline AFTER it, or the count below measures history.
sleep 6
BEFORE=$(events 'human=1 msgs=1')
peer_send "Dana" "$DANA" '{"text":"one"}'
sleep 0.3
peer_send "Dana" "$DANA" '{"text":"two"}'
sleep 4
AFTER=$(events 'human=1 msgs=1')
DELTA=$((AFTER - BEFORE))
[ "$DELTA" -eq 2 ] \
  && ok "with coalescing off, each message is its own event ($DELTA)" \
  || bad "expected 2 immediate events, got $DELTA"
[ "$(events 'msgs=[2-9]')" -eq 0 ] \
  && ok "no burst event was produced with coalescing off" \
  || bad "a coalesced event appeared despite AGENTALK_COALESCE_S=0"

# ---------------------------------------------------------------------------
step "9. a departure is reported immediately"
# Restart with coalescing on so this exercises the normal path.
for pp in $LOOP_PIDS; do kill "$pp" 2>/dev/null || true; done
sleep 1
: > "$AEVENTS"
( . "$AENV" && AGENTALK_COALESCE_S=2 . <(curl -fsS "$BRIDGE/loop.sh") ) >/dev/null 2>&1 &
LOOP_PIDS="$!"
sleep 5

LEAVER=$(peer_join "Rivka")
peer_send "Rivka" "$LEAVER" '{"hello":"5555666677778888","human":true}'
sleep 3
[ "$(events 'HUMAN_JOINED name=Rivka')" -ge 1 ] \
  && ok "Rivka announced as a human" \
  || bad "Rivka not announced"

# Last words, then close the tab straight away. The burst must land BEFORE the
# departure notice, or Claude reads "they left" and then their question.
peer_send "Rivka" "$LEAVER" '{"text":"one more thing"}'
sleep 0.3
curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/leave" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg p "$LEAVER" '{token:$t, participant_id:$p}')" >/dev/null
sleep 4

[ "$(events 'PEER_LEFT name=Rivka human=1')" -ge 1 ] \
  && ok "PEER_LEFT reported, tagged human=1" \
  || bad "no PEER_LEFT for a human who closed the tab"

BURST_LINE=$(grep -n 'from=Rivka human=1 msgs' "$AEVENTS" | head -1 | cut -d: -f1)
LEFT_LINE=$(grep -n 'PEER_LEFT name=Rivka' "$AEVENTS" | head -1 | cut -d: -f1)
if [ -n "$BURST_LINE" ] && [ -n "$LEFT_LINE" ]; then
  [ "$BURST_LINE" -lt "$LEFT_LINE" ] \
    && ok "their last message is flushed before the departure notice" \
    || bad "PEER_LEFT (line $LEFT_LINE) came before their message (line $BURST_LINE)"
else
  bad "missing burst ($BURST_LINE) or leave ($LEFT_LINE) line"
fi

# An agent leaving is reported too, just without the human tag.
BOT2=$(peer_join "botleaver")
peer_send "botleaver" "$BOT2" '{"hello":"1212121212121212"}'
sleep 3
curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/leave" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg p "$BOT2" '{token:$t, participant_id:$p}')" >/dev/null
sleep 3
[ "$(events 'PEER_LEFT name=botleaver')" -ge 1 ] \
  && ok "an agent leaving is reported as well" \
  || bad "no PEER_LEFT for a departing agent"
[ "$(events 'PEER_LEFT name=botleaver human=1')" -eq 0 ] \
  && ok "an agent's departure is not tagged human=1" \
  || bad "agent departure wrongly tagged human=1"

# Still one line per event.
[ "$(events '^agentalk: ')" -eq "$(wc -l < "$AEVENTS" | tr -d ' ')" ] \
  && ok "events file still holds one agentalk: line per event" \
  || bad "a stray line appeared in the events file"

step "10. SDK pages document the new row without losing the old ones"
PAGE=$(curl -fsS -H 'User-Agent: Claude-User' "$BRIDGE/llms.txt")
JPAGE=$(curl -fsS "$BRIDGE/c/$CHANNEL_ID?token=$TOKEN")
for row in WELCOMED BROADCAST DM DECRYPT_FAIL PEER_STALE PEER_BACK PEER_LEFT RESUMED REJOIN_FAILED SYSTEM HUMAN_JOINED; do
  printf '%s' "$PAGE" | grep -q "$row" \
    && ok "initiator.md still documents $row" \
    || bad "initiator.md lost the $row row"
done
for row in WELCOMED BROADCAST DM HUMAN_JOINED PEER_LEFT; do
  printf '%s' "$JPAGE" | grep -q "$row" \
    && ok "joiner.md documents $row" \
    || bad "joiner.md lost the $row row"
done
for phrase in "plain language" "no jargon"; do
  printf '%s' "$PAGE" | grep -qi "$phrase" \
    && ok "initiator.md carries the human-etiquette phrase: $phrase" \
    || bad "initiator.md missing: $phrase"
done
printf '%s' "$PAGE" | grep -q '"human": true' \
  && ok "protocol reference documents the human envelope field" \
  || bad 'protocol reference does not mention "human": true'
printf '%s' "$PAGE" | grep -q 'share_message_human' \
  && ok "protocol reference documents share_message_human" \
  || bad "protocol reference does not mention share_message_human"
printf '%s' "$PAGE" | grep -q 'cursor' \
  && ok "protocol reference documents the join cursor" \
  || bad "protocol reference does not mention cursor"

echo
echo "$(green "PASS: $PASS")   $( [ "$FAIL" -gt 0 ] && red "FAIL: $FAIL" || echo "FAIL: 0")"
echo
echo "NOT covered here — this is the real acceptance test for this phase:"
echo "  Open a real claude session, have it mint a link, open that link in a"
echo "  browser, and confirm Claude sends a plain-language opener BY ITSELF and"
echo "  keeps writing that way for the whole thread. No script can check tone."
[ "$FAIL" -eq 0 ] || exit 1

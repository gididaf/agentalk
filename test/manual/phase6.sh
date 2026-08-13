#!/usr/bin/env bash
# Phase 6 manual QA — verifies the N-way + envelope + HELLO/WELCOME layer:
#  - initiator and joiner pages document the JSON envelope format
#    ({"text":...}, {"to":...,"text":...}, {"hello":...}, {"welcome":..."to":...})
#  - the pages document the HELLO/WELCOME arrival handshake (joiner-led)
#  - the pages document N-way rooms (3+ participants) and DM addressing
#  - a 3-participant scenario completes the handshake and routes both broadcast
#    and DM envelopes correctly through the bridge
#  - the bridge log contains zero plaintext for either the broadcast or DM body

set -u

BRIDGE="${BRIDGE:-http://localhost:3000}"

# The bridge UA-sniffs at `/`: a browser gets the Astro HTML landing page, an
# LLM user agent gets the markdown SDK (see LLM_UA in src/bridge/index.ts).
# curl's default UA is NOT an LLM UA, so any fetch of `/` here must send one —
# otherwise every SDK assertion below silently runs against the human page and
# fails for a reason that has nothing to do with the SDK. The opposite holds at
# /c/:id, where `Claude-User` gets the short WebFetch stub and plain curl gets
# the full joiner SDK — those fetches stay bare on purpose.
LLM_UA='User-Agent: Claude-User'
BRIDGE_LOG="${BRIDGE_LOG:-/tmp/agentalk-bridge.log}"
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

agentalk_encrypt() {
  K="$1" AAD="$2" PT="$3" node -e '
    const c = require("crypto");
    const key = Buffer.from(process.env.K, "hex");
    const aad = Buffer.from(process.env.AAD, "utf8");
    const nonce = c.randomBytes(12);
    const ci = c.createCipheriv("aes-256-gcm", key, nonce);
    ci.setAAD(aad);
    const ct = Buffer.concat([ci.update(process.env.PT, "utf8"), ci.final()]);
    process.stdout.write(Buffer.concat([nonce, ct, ci.getAuthTag()]).toString("base64"));
  '
}

agentalk_decrypt() {
  K="$1" AAD="$2" B="$3" node -e '
    const c = require("crypto");
    const key = Buffer.from(process.env.K, "hex");
    const aad = Buffer.from(process.env.AAD, "utf8");
    const buf = Buffer.from(process.env.B, "base64");
    const nonce = buf.subarray(0, 12);
    const tag = buf.subarray(buf.length - 16);
    const ct = buf.subarray(12, buf.length - 16);
    const dec = c.createDecipheriv("aes-256-gcm", key, nonce);
    dec.setAAD(aad);
    dec.setAuthTag(tag);
    process.stdout.write(Buffer.concat([dec.update(ct), dec.final()]).toString("utf8"));
  '
}

send_blob() {
  # $1=channel $2=token $3=participant_id $4=blob
  curl -fsS -X POST "$BRIDGE/channels/$1/send" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$2" --arg p "$3" --arg x "$4" '{token:$t, participant_id:$p, text:$x}')" >/dev/null
}

poll_until() {
  # $1=channel $2=token $3=participant_id $4=since  $5=jq filter that must match >=1 element  $6=timeout secs
  local ch="$1" tok="$2" pid="$3" since="$4" filter="$5" deadline=$(( $(date +%s) + ${6:-10} ))
  while [[ $(date +%s) -lt $deadline ]]; do
    local resp
    resp=$(curl -fsS -m 4 \
      "$BRIDGE/channels/$ch/poll?token=$tok&participant_id=$pid&since=$since" 2>/dev/null || true)
    if [[ -n "$resp" ]]; then
      local hit
      hit=$(echo "$resp" | jq -c "$filter" 2>/dev/null)
      if [[ -n "$hit" ]]; then
        echo "$resp"
        return 0
      fi
      since=$(echo "$resp" | jq -r '.cursor')
    fi
  done
  return 1
}

# 0. bridge reachable
step "0. bridge reachable"
curl -fsS "$BRIDGE/health" >/dev/null || { bad "bridge not running at $BRIDGE"; exit 1; }
ok "bridge up"

# 1. initiator page documents envelope + rooms + welcome dispatch
step "1. initiator page documents N-way rooms + envelope + welcome-on-HELLO"
init=$(curl -fsS -H "$LLM_UA" "$BRIDGE/")
echo "$init" | grep -Eq 'room|group'                                  && ok "initiator page mentions rooms/groups"                  || bad "no rooms/groups language"
echo "$init" | grep -qF 'agentalk_say'  && ok "initiator page documents agentalk_say (broadcast)"        || bad "initiator page missing agentalk_say"
echo "$init" | grep -qF 'agentalk_dm'   && ok "initiator page documents agentalk_dm (DM addressing)"     || bad "initiator page missing agentalk_dm"
echo "$init" | grep -qiF 'hand-build'   && ok "initiator page forbids hand-built envelopes"              || bad "initiator page no longer forbids hand-built envelopes"
echo "$init" | grep -Eq 'broadcast'                                   && ok "initiator page mentions broadcast"                     || bad "missing broadcast language"
echo "$init" | grep -Eq '\bDM\b|direct message'                       && ok "initiator page mentions DM / direct message"           || bad "missing DM/direct-message language"
echo "$init" | grep -Eqv '^\s*\$\s*Send PING'                         && ok "initiator no longer pre-sends PING (Phase 5 behavior gone)" || bad "PING-pre-send still in initiator page"
echo "$init" | grep -q 'hello' | head -n1 >/dev/null

# 2. joiner page documents envelope + HELLO + collect WELCOMEs
step "2. joiner page documents HELLO + collect-WELCOMEs + envelope"
CREATE=$(curl -fsS -X POST "$BRIDGE/channels")
CHANNEL_ID=$(echo "$CREATE" | jq -r '.channel_id')
TOKEN=$(echo "$CREATE" | jq -r '.token')
join=$(curl -fsS "$BRIDGE/c/$CHANNEL_ID")
echo "$join" | grep -Eq 'room|group'                                  && ok "joiner page mentions rooms/groups"                  || bad "no rooms/groups language"
echo "$join" | grep -qF 'agentalk_say'  && ok "joiner page documents agentalk_say (broadcast)"        || bad "joiner page missing agentalk_say"
echo "$join" | grep -qF 'agentalk_dm'   && ok "joiner page documents agentalk_dm (DM addressing)"     || bad "joiner page missing agentalk_dm"
echo "$join" | grep -qiF 'hand-build'   && ok "joiner page forbids hand-built envelopes"              || bad "joiner page no longer forbids hand-built envelopes"
echo "$join" | grep -qF 'others='     && ok "joiner page points at the bootstrap others= list"     || bad "joiner page missing others= instruction"
echo "$join" | grep -Eq 'broadcast'                                   && ok "joiner page mentions broadcast"                     || bad "missing broadcast language"
echo "$join" | grep -Eq '\bDM\b|direct message'                       && ok "joiner page mentions DM / direct message"           || bad "missing DM/direct-message language"

# 3. 3-participant E2E: alice (initiator) + bob + carol, full handshake
# 2b. The wire envelope moved off the pages and into the served scripts.
step "2b. envelope format lives in helpers.sh + loop.sh"
helpersh=$(curl -fsS "$BRIDGE/helpers.sh")
loopsh=$(curl -fsS "$BRIDGE/loop.sh")
printf '%s' "$helpersh" | grep -qF 'text:$t' && ok "helpers.sh builds the {text} broadcast envelope"  || bad "helpers.sh lost the text envelope"
printf '%s' "$helpersh" | grep -qF 'to:$n'   && ok "helpers.sh builds the {to,text} DM envelope"      || bad "helpers.sh lost the to envelope"
printf '%s' "$loopsh"   | grep -qF 'hello:$c'   && ok "loop.sh builds the {hello} arrival envelope"   || bad "loop.sh lost the hello envelope"
printf '%s' "$loopsh"   | grep -qF 'welcome:$c' && ok "loop.sh builds the {welcome} reply envelope"   || bad "loop.sh lost the welcome envelope"

step "3. 3-participant handshake — alice + bob + carol"
CHANNEL_KEY=$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')

ALICE=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n alice '{token:$t, name:$n}')")
ALICE_PID=$(echo "$ALICE" | jq -r '.participant_id')
ALICE_PEERS=$(echo "$ALICE" | jq -c '.participants')
[[ "$ALICE_PEERS" == '["alice"]' ]] && ok "alice joined; participants=[alice]" || bad "alice join participants list wrong: $ALICE_PEERS"

BOB=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n bob '{token:$t, name:$n}')")
BOB_PID=$(echo "$BOB" | jq -r '.participant_id')
BOB_OTHERS=$(echo "$BOB" | jq -r --arg me bob '.participants[] | select(. != $me)' | tr '\n' ',' | sed 's/,$//')
[[ "$BOB_OTHERS" == "alice" ]] && ok "bob joined; OTHERS=alice" || bad "bob OTHERS wrong: '$BOB_OTHERS'"

# Bob sends HELLO with a random challenge
CHALL_B=$(node -e 'console.log(require("crypto").randomBytes(8).toString("hex"))')
BOB_HELLO_PT=$(jq -nc --arg c "$CHALL_B" '{hello:$c}')
BOB_HELLO_BLOB=$(agentalk_encrypt "$CHANNEL_KEY" "$CHANNEL_ID:bob" "$BOB_HELLO_PT")
send_blob "$CHANNEL_ID" "$TOKEN" "$BOB_PID" "$BOB_HELLO_BLOB"
ok "bob sent HELLO (encrypted, chall=${CHALL_B:0:8}…)"

# Alice receives bob's HELLO and replies WELCOME
ALICE_POLL=$(poll_until "$CHANNEL_ID" "$TOKEN" "$ALICE_PID" 0 \
  '.messages[] | select(.type=="message" and .from=="bob")' 10) \
  && ok "alice received bob's HELLO blob" \
  || { bad "alice never saw bob's HELLO"; exit 1; }
BOB_BLOB=$(echo "$ALICE_POLL" | jq -r '.messages[] | select(.type=="message" and .from=="bob") | .text' | head -n1)
BOB_HELLO_PT_DEC=$(agentalk_decrypt "$CHANNEL_KEY" "$CHANNEL_ID:bob" "$BOB_BLOB")
[[ "$BOB_HELLO_PT_DEC" == "$BOB_HELLO_PT" ]] && ok "alice decrypted bob's HELLO envelope" || bad "alice's decrypt of HELLO didn't match"

DECODED_CHALL=$(echo "$BOB_HELLO_PT_DEC" | jq -r '.hello')
[[ "$DECODED_CHALL" == "$CHALL_B" ]] && ok "bob's HELLO carries the right challenge" || bad "challenge mismatch in HELLO"

ALICE_WELCOME_PT=$(jq -nc --arg c "$CHALL_B" --arg to bob '{welcome:$c, to:$to}')
ALICE_WELCOME_BLOB=$(agentalk_encrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$ALICE_WELCOME_PT")
send_blob "$CHANNEL_ID" "$TOKEN" "$ALICE_PID" "$ALICE_WELCOME_BLOB"
ok "alice sent WELCOME → bob (chall=${CHALL_B:0:8}…)"

# Bob receives alice's WELCOME, verifies
BOB_POLL=$(poll_until "$CHANNEL_ID" "$TOKEN" "$BOB_PID" 0 \
  '.messages[] | select(.type=="message" and .from=="alice")' 10) \
  && ok "bob received alice's WELCOME blob" \
  || { bad "bob never saw alice's WELCOME"; exit 1; }
ALICE_WELC_BLOB=$(echo "$BOB_POLL" | jq -r '.messages[] | select(.type=="message" and .from=="alice") | .text' | head -n1)
ALICE_WELC_PT=$(agentalk_decrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$ALICE_WELC_BLOB")
WELC_CHALL=$(echo "$ALICE_WELC_PT" | jq -r '.welcome')
WELC_TO=$(echo "$ALICE_WELC_PT"    | jq -r '.to')
[[ "$WELC_CHALL" == "$CHALL_B" && "$WELC_TO" == bob ]] \
  && ok "bob verified WELCOME (chall + to)" \
  || bad "bob's WELCOME verification failed (chall=$WELC_CHALL to=$WELC_TO)"

# Carol joins — should see alice+bob in participants
CAROL=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n carol '{token:$t, name:$n}')")
CAROL_PID=$(echo "$CAROL" | jq -r '.participant_id')
CAROL_OTHERS=$(echo "$CAROL" | jq -r --arg me carol '.participants[] | select(. != $me)' | sort | tr '\n' ',' | sed 's/,$//')
[[ "$CAROL_OTHERS" == "alice,bob" ]] && ok "carol joined; OTHERS=alice,bob (room size now 3)" || bad "carol OTHERS wrong: '$CAROL_OTHERS'"

# Carol's HELLO
CHALL_C=$(node -e 'console.log(require("crypto").randomBytes(8).toString("hex"))')
CAROL_HELLO_PT=$(jq -nc --arg c "$CHALL_C" '{hello:$c}')
CAROL_HELLO_BLOB=$(agentalk_encrypt "$CHANNEL_KEY" "$CHANNEL_ID:carol" "$CAROL_HELLO_PT")
send_blob "$CHANNEL_ID" "$TOKEN" "$CAROL_PID" "$CAROL_HELLO_BLOB"
ok "carol sent HELLO"

# Alice + Bob each see carol's HELLO and reply WELCOME
for who in alice bob; do
  pid_var="${who^^}_PID"; PID="${!pid_var}"
  POLL=$(poll_until "$CHANNEL_ID" "$TOKEN" "$PID" 0 \
    '.messages[] | select(.type=="message" and .from=="carol")' 10) \
    && ok "$who received carol's HELLO" \
    || { bad "$who never saw carol's HELLO"; exit 1; }
  CAROL_BLOB=$(echo "$POLL" | jq -r '.messages[] | select(.type=="message" and .from=="carol") | .text' | head -n1)
  CAROL_HELLO_DEC=$(agentalk_decrypt "$CHANNEL_KEY" "$CHANNEL_ID:carol" "$CAROL_BLOB")
  DEC_CHALL=$(echo "$CAROL_HELLO_DEC" | jq -r '.hello')
  [[ "$DEC_CHALL" == "$CHALL_C" ]] && ok "$who decrypted carol's HELLO challenge" || bad "$who couldn't decrypt carol's HELLO"

  WELC_PT=$(jq -nc --arg c "$CHALL_C" --arg to carol '{welcome:$c, to:$to}')
  WELC_BLOB=$(agentalk_encrypt "$CHANNEL_KEY" "$CHANNEL_ID:$who" "$WELC_PT")
  send_blob "$CHANNEL_ID" "$TOKEN" "$PID" "$WELC_BLOB"
  ok "$who sent WELCOME → carol"
done

# Carol verifies both WELCOMEs match her challenge + are addressed to her
CAROL_POLL=$(curl -fsS -m 5 "$BRIDGE/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$CAROL_PID&since=0")
VERIFIED=""
for who in alice bob; do
  BLOB=$(echo "$CAROL_POLL" | jq -r --arg w "$who" '.messages[] | select(.type=="message" and .from==$w) | .text' | tail -n1)
  PT=$(agentalk_decrypt "$CHANNEL_KEY" "$CHANNEL_ID:$who" "$BLOB" 2>/dev/null || true)
  CH=$(echo "$PT" | jq -r '.welcome' 2>/dev/null)
  TO=$(echo "$PT" | jq -r '.to'      2>/dev/null)
  if [[ "$CH" == "$CHALL_C" && "$TO" == "carol" ]]; then
    VERIFIED="$VERIFIED,$who"
  fi
done
VERIFIED="${VERIFIED#,}"
[[ "$VERIFIED" == "alice,bob" ]] && ok "carol fully paired with alice+bob via WELCOME checks" || bad "carol pairing incomplete: '$VERIFIED'"

# 4. Broadcast envelope — alice sends {"text": ...} ; bob+carol both decrypt and see same text
step "4. broadcast envelope routes to every participant"
BROADCAST_TEXT="phase6-canary-broadcast-$(date +%s%N)"
BROADCAST_PT=$(jq -nc --arg t "$BROADCAST_TEXT" '{text:$t}')
BROADCAST_BLOB=$(agentalk_encrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$BROADCAST_PT")
send_blob "$CHANNEL_ID" "$TOKEN" "$ALICE_PID" "$BROADCAST_BLOB"

for who in bob carol; do
  pid_var="${who^^}_PID"; PID="${!pid_var}"
  RECV=$(poll_until "$CHANNEL_ID" "$TOKEN" "$PID" 0 \
    ".messages[] | select(.from==\"alice\" and .text==\"$BROADCAST_BLOB\")" 5)
  if [[ -n "$RECV" ]]; then
    PT=$(agentalk_decrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$BROADCAST_BLOB")
    GOT_TEXT=$(echo "$PT" | jq -r '.text')
    GOT_TO=$(echo "$PT"   | jq -r '.to // ""')
    if [[ "$GOT_TEXT" == "$BROADCAST_TEXT" && -z "$GOT_TO" ]]; then
      ok "$who sees broadcast (text matches, no 'to' field)"
    else
      bad "$who broadcast envelope malformed: text='$GOT_TEXT' to='$GOT_TO'"
    fi
  else
    bad "$who did not receive broadcast"
  fi
done

# 5. DM envelope — alice sends {"to":"bob","text":...} ; both decrypt OK ; carol drops, bob acts
step "5. DM envelope — both peers decrypt the same blob; only the addressee acts"
DM_TEXT="phase6-canary-dm-$(date +%s%N)"
DM_PT=$(jq -nc --arg n bob --arg t "$DM_TEXT" '{to:$n, text:$t}')
DM_BLOB=$(agentalk_encrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$DM_PT")
send_blob "$CHANNEL_ID" "$TOKEN" "$ALICE_PID" "$DM_BLOB"

for who in bob carol; do
  pid_var="${who^^}_PID"; PID="${!pid_var}"
  RECV=$(poll_until "$CHANNEL_ID" "$TOKEN" "$PID" 0 \
    ".messages[] | select(.from==\"alice\" and .text==\"$DM_BLOB\")" 5)
  if [[ -n "$RECV" ]]; then
    PT=$(agentalk_decrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$DM_BLOB")
    GOT_TO=$(echo "$PT" | jq -r '.to')
    GOT_TX=$(echo "$PT" | jq -r '.text')
    if [[ "$GOT_TO" == "bob" && "$GOT_TX" == "$DM_TEXT" ]]; then
      if [[ "$who" == "bob" ]]; then
        ok "$who received DM and the to-field correctly names them as addressee"
      else
        ok "$who received DM (decrypts cleanly) but to=bob ≠ $who → would drop client-side"
      fi
    else
      bad "$who DM envelope malformed: to='$GOT_TO' text='$GOT_TX'"
    fi
  else
    bad "$who did not receive the DM blob"
  fi
done

# 6. bridge log contains zero plaintext for broadcast or DM
step "6. bridge log contains zero plaintext for broadcast or DM bodies"
if [[ -r "$BRIDGE_LOG" ]]; then
  leaked=""
  grep -q "$BROADCAST_TEXT" "$BRIDGE_LOG" && leaked="$leaked broadcast"
  grep -q "$DM_TEXT"        "$BRIDGE_LOG" && leaked="$leaked dm"
  if [[ -z "$leaked" ]]; then
    ok "neither broadcast nor DM plaintext appears in bridge log"
  else
    bad "bridge log contains plaintext for:$leaked"
  fi
else
  echo "    (bridge log not at $BRIDGE_LOG — skipping log scan)"
  ok "log scan skipped (log file not readable from this script)"
fi

# 7. bridge stats reflect 3 participants in this channel
step "7. bridge /health stats reflect the 3-participant room"
HEALTH=$(curl -fsS "$BRIDGE/health")
TP=$(echo "$HEALTH" | jq -r '.total_participants')
[[ "$TP" =~ ^[0-9]+$ && "$TP" -ge 3 ]] \
  && ok "total_participants=$TP includes this 3-person room" \
  || bad "total_participants=$TP doesn't reach 3 — N-way join broken?"

echo
echo "─────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  echo "$(green "ALL PASS") — $PASS checks"
  echo
  echo "Next: real three-Claude QA."
  echo "  Terminal A: 'Ask my other agents what their hostnames are. curl $BRIDGE/llms.txt to start.'"
  echo "  Terminals B and C: paste the same fenced URL from terminal A."
  echo "  All three should report 'paired' after their HELLO/WELCOME exchanges."
  echo "  Then test DM: tell A 'just ask bob (no one else) what time it is'."
  exit 0
else
  echo "$(red "FAILED") — $PASS passed, $FAIL failed"
  exit 1
fi

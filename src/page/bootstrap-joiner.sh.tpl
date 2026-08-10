# agentalk joiner bootstrap. Source this in one Bash call, supplying the
# channel key from the URL fragment (`#k=<hex>`) via the AGENTALK_KEY env var:
#   AGENTALK_KEY=<hex> . <(curl -fsS '{{BRIDGE_URL}}/c/{{CHANNEL_ID}}/bootstrap.sh?token={{TOKEN}}')

_agentalk_fail() { echo "ERROR: agentalk bootstrap (joiner): $1" >&2; return 1; }

for _dep in jq node curl; do
  command -v "$_dep" >/dev/null 2>&1 || { _agentalk_fail "missing dependency: $_dep"; return 1; }
done
unset _dep

[ -n "${AGENTALK_KEY:-}" ] \
  || { _agentalk_fail "AGENTALK_KEY env var not set; extract the '#k=' fragment from the URL your user pasted, then prefix this command with AGENTALK_KEY=<that_hex>"; return 1; }

AGENTALK_BRIDGE_URL='{{BRIDGE_URL}}'
AGENTALK_CHANNEL_ID='{{CHANNEL_ID}}'
AGENTALK_TOKEN='{{TOKEN}}'

AGENTALK_MY_NAME=$(basename "$(pwd)" | tr -c 'a-zA-Z0-9._-' '_' | head -c 60)
[ -z "$AGENTALK_MY_NAME" ] && AGENTALK_MY_NAME=joiner
AGENTALK_SESSION_FILE="/tmp/agentalk-session-$AGENTALK_MY_NAME.env"

AGENTALK_CHALL=$(node -e 'console.log(require("crypto").randomBytes(8).toString("hex"))') \
  || { _agentalk_fail "challenge generation failed"; return 1; }

# Fingerprint of the key we extracted from '#k='. Sent at join; compared below
# against the roster so a truncated or mis-relayed fragment is caught HERE,
# with a clear error, instead of surfacing later as DECRYPT_FAIL on both sides.
AGENTALK_KEY_FP=$(K="$AGENTALK_KEY" node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.env.K).digest("hex").slice(0,16))') \
  || { _agentalk_fail "key fingerprint computation failed"; return 1; }

# Join with name-collision retry.
AGENTALK_JOIN_NAME="$AGENTALK_MY_NAME"
AGENTALK_JOIN_TRIES=0
while :; do
  AGENTALK_JOIN_BODY=$(jq -nc --arg t "$AGENTALK_TOKEN" --arg n "$AGENTALK_JOIN_NAME" --arg f "$AGENTALK_KEY_FP" '{token:$t, name:$n, key_fp:$f}')
  # No -f: it discards 4xx bodies, which made the name_taken retry below dead
  # code (the .error parse never saw the reason) and turned every join
  # rejection into a misleading "channel may be gone". The body is JSON in
  # both success and failure; .error tells them apart.
  AGENTALK_JOIN=$(curl -sS -X POST "$AGENTALK_BRIDGE_URL/channels/$AGENTALK_CHANNEL_ID/join" \
    -H 'content-type: application/json' -d "$AGENTALK_JOIN_BODY" 2>/dev/null)
  [ -n "$AGENTALK_JOIN" ] \
    || { _agentalk_fail "join request failed (network unreachable or bridge down)"; return 1; }
  AGENTALK_JOIN_ERR=$(printf '%s' "$AGENTALK_JOIN" | jq -r '.error // empty')
  if [ "$AGENTALK_JOIN_ERR" = "channel_or_token_invalid" ]; then
    AGENTALK_GONE=$(printf '%s' "$AGENTALK_JOIN" | jq -r '.evicted_reason // empty')
    _agentalk_fail "channel gone${AGENTALK_GONE:+ (evicted: $AGENTALK_GONE)} — ask the initiator for a fresh URL"
    return 1
  fi
  if [ "$AGENTALK_JOIN_ERR" = "name_taken" ]; then
    AGENTALK_JOIN_TRIES=$((AGENTALK_JOIN_TRIES + 1))
    if [ "$AGENTALK_JOIN_TRIES" -ge 8 ]; then
      _agentalk_fail "name $AGENTALK_MY_NAME (and 7 numbered suffixes) all taken"; return 1
    fi
    AGENTALK_JOIN_NAME="$AGENTALK_MY_NAME-$AGENTALK_JOIN_TRIES"
    continue
  fi
  if [ -n "$AGENTALK_JOIN_ERR" ]; then
    _agentalk_fail "join failed: $AGENTALK_JOIN_ERR"; return 1
  fi
  break
done
AGENTALK_MY_NAME="$AGENTALK_JOIN_NAME"
AGENTALK_PARTICIPANT_ID=$(printf '%s' "$AGENTALK_JOIN" | jq -r '.participant_id // empty')
AGENTALK_OTHERS=$(printf '%s' "$AGENTALK_JOIN" \
  | jq -r --arg me "$AGENTALK_MY_NAME" '.participants[] | select(. != $me)' \
  | tr '\n' ' ')
[ -n "$AGENTALK_PARTICIPANT_ID" ] \
  || { _agentalk_fail "join response missing participant_id"; return 1; }

# Key-fingerprint check: compare ours against the earliest other participant
# that published one (roster is join-ordered, so that is the initiator — the
# party that minted the key). Mismatch means our '#k=' fragment is not their
# key: nothing we send could ever decrypt, so leave and fail loudly NOW.
# Empty (old bridge or no fp published) skips the check — never a false abort.
AGENTALK_PEER_FP=$(printf '%s' "$AGENTALK_JOIN" \
  | jq -r --arg me "$AGENTALK_MY_NAME" \
    '.roster // [] | map(select(.name != $me and .key_fp != null)) | .[0].key_fp // empty')
if [ -n "$AGENTALK_PEER_FP" ] && [ "$AGENTALK_PEER_FP" != "$AGENTALK_KEY_FP" ]; then
  curl -fsS -X POST "$AGENTALK_BRIDGE_URL/channels/$AGENTALK_CHANNEL_ID/leave" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$AGENTALK_TOKEN" --arg p "$AGENTALK_PARTICIPANT_ID" '{token:$t, participant_id:$p}')" \
    >/dev/null 2>&1
  _agentalk_fail "encryption key fingerprint mismatch (yours=$AGENTALK_KEY_FP, channel's=$AGENTALK_PEER_FP). The '#k=' fragment you extracted is not the channel key — it was truncated or altered in relay. Ask your user to re-paste the FULL URL from the initiator (everything after '#k=' matters), then re-run this bootstrap with the new AGENTALK_KEY."
  return 1
fi

cat > "$AGENTALK_SESSION_FILE" <<EOF
export BRIDGE_URL='$AGENTALK_BRIDGE_URL'
export CHANNEL_ID='$AGENTALK_CHANNEL_ID'
export TOKEN='$AGENTALK_TOKEN'
export PARTICIPANT_ID='$AGENTALK_PARTICIPANT_ID'
export MY_NAME='$AGENTALK_MY_NAME'
export CHANNEL_KEY='$AGENTALK_KEY'
export MY_CHALL='$AGENTALK_CHALL'
EOF
curl -fsS "$AGENTALK_BRIDGE_URL/helpers.sh" >> "$AGENTALK_SESSION_FILE" \
  || { _agentalk_fail "fetching /helpers.sh failed"; return 1; }

. "$AGENTALK_SESSION_FILE"

if [ -n "$AGENTALK_PEER_FP" ]; then AGENTALK_KEY_STATUS=verified; else AGENTALK_KEY_STATUS=unverified; fi
echo "READY joiner: channel=$AGENTALK_CHANNEL_ID name=$AGENTALK_MY_NAME others=$AGENTALK_OTHERS key=$AGENTALK_KEY_STATUS"
echo ""
echo "Do both NEXTs below, in order, in this turn — do NOT stop before NEXT 2."
echo ""
echo "NEXT 1 — arm the poll loop in a SEPARATE Bash call with run_in_background=true."
echo "Run exactly this (paths are already substituted; do NOT use \$AGENTALK_SESSION_FILE):"
echo ""
echo "  . '$AGENTALK_SESSION_FILE' && . <(curl -fsS '$AGENTALK_BRIDGE_URL/loop.sh')"
echo ""
echo "The loop will auto-send your HELLO (MY_CHALL is set in the session env)."
echo ""
echo "NEXT 2 — IMMEDIATELY after NEXT 1, call the Monitor tool on NEXT 1's bash_id."
echo "Monitor parameters: bash_id=<from NEXT 1's tool result>, pattern='agentalk:'"
echo "Without Monitor armed you will NOT wake when the loop reports PAIRED or incoming messages — this is the single most-missed step."
echo ""
echo "RULES (apply to EVERY Bash call you make from here on — the SDK has more detail):"
echo "  - Start each Bash with:  . '$AGENTALK_SESSION_FILE' &&"
echo "    Claude Code's Bash tool spawns a fresh shell per call; helpers are unloaded otherwise."
echo "  - For multi-paragraph or shell-special content (apostrophes, brackets, globs, \$),"
echo "    write to a file first, then send via:  agentalk_say_file <path>   (or agentalk_dm_file <name> <path>)"
echo "  - On every incoming 'agentalk: BROADCAST|DM …' line, Read the file= path for the full body — never act on the preview alone."
echo "  - Never WebFetch agentalk URLs — always curl. WebFetch summarizes and drops code."

unset _agentalk_fail

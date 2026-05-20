# agentalk initiator bootstrap. Source this in one Bash call:
#   . <(curl -fsS {{BRIDGE_URL}}/bootstrap.sh)
# Sets up: channel + key + session env file + helpers. Exports
# $AGENTALK_SHARE_MSG for you to echo back to your user verbatim.

_agentalk_fail() { echo "ERROR: agentalk bootstrap (initiator): $1" >&2; return 1; }

for _dep in jq node curl; do
  command -v "$_dep" >/dev/null 2>&1 || { _agentalk_fail "missing dependency: $_dep"; return 1; }
done
unset _dep

AGENTALK_BRIDGE_URL='{{BRIDGE_URL}}'
AGENTALK_MY_NAME=$(basename "$(pwd)" | tr -c 'a-zA-Z0-9._-' '_' | head -c 60)
[ -z "$AGENTALK_MY_NAME" ] && AGENTALK_MY_NAME=initiator
AGENTALK_SESSION_FILE="/tmp/agentalk-session-$AGENTALK_MY_NAME.env"

AGENTALK_KEY=$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))') \
  || { _agentalk_fail "channel key generation failed"; return 1; }

AGENTALK_CREATE=$(curl -fsS -X POST "$AGENTALK_BRIDGE_URL/channels") \
  || { _agentalk_fail "POST /channels failed"; return 1; }

AGENTALK_CHANNEL_ID=$(printf '%s' "$AGENTALK_CREATE" | jq -r '.channel_id // empty')
AGENTALK_TOKEN=$(printf '%s' "$AGENTALK_CREATE" | jq -r '.token // empty')
AGENTALK_SHARE_TEMPLATE=$(printf '%s' "$AGENTALK_CREATE" | jq -r '.share_message // empty')
{ [ -n "$AGENTALK_CHANNEL_ID" ] && [ -n "$AGENTALK_TOKEN" ] && [ -n "$AGENTALK_SHARE_TEMPLATE" ]; } \
  || { _agentalk_fail "CREATE response missing channel_id, token, or share_message"; return 1; }

AGENTALK_JOIN_BODY=$(jq -nc --arg t "$AGENTALK_TOKEN" --arg n "$AGENTALK_MY_NAME" '{token:$t, name:$n}')
AGENTALK_JOIN=$(curl -fsS -X POST "$AGENTALK_BRIDGE_URL/channels/$AGENTALK_CHANNEL_ID/join" \
  -H 'content-type: application/json' -d "$AGENTALK_JOIN_BODY") \
  || { _agentalk_fail "join failed"; return 1; }
AGENTALK_PARTICIPANT_ID=$(printf '%s' "$AGENTALK_JOIN" | jq -r '.participant_id // empty')
[ -n "$AGENTALK_PARTICIPANT_ID" ] \
  || { _agentalk_fail "join response missing participant_id"; return 1; }

# Write the session env file. Single-quoted values inside an unquoted heredoc
# means the outer shell expands the variables once, the file holds literal
# single-quoted strings — safe to re-source. All values are bridge-generated
# hex / sanitized basename / fixed URL — none can contain a literal single
# quote.
cat > "$AGENTALK_SESSION_FILE" <<EOF
export BRIDGE_URL='$AGENTALK_BRIDGE_URL'
export CHANNEL_ID='$AGENTALK_CHANNEL_ID'
export TOKEN='$AGENTALK_TOKEN'
export PARTICIPANT_ID='$AGENTALK_PARTICIPANT_ID'
export MY_NAME='$AGENTALK_MY_NAME'
export CHANNEL_KEY='$AGENTALK_KEY'
EOF
curl -fsS "$AGENTALK_BRIDGE_URL/helpers.sh" >> "$AGENTALK_SESSION_FILE" \
  || { _agentalk_fail "fetching /helpers.sh failed"; return 1; }

# Substitute the real key into the bridge-rendered share message and write it
# to a file. Env-var exports do NOT survive Claude Code's Bash tool calls
# (each call spawns a fresh shell), so the share message must live on disk
# for the next call to read it.
AGENTALK_SHARE_FILE="/tmp/agentalk-share-$AGENTALK_MY_NAME.txt"
printf '%s' "${AGENTALK_SHARE_TEMPLATE//__KEY__/$AGENTALK_KEY}" > "$AGENTALK_SHARE_FILE"

# Source helpers into the current shell so a caller that stays in this shell
# can immediately use agentalk_say / agentalk_dm / agentalk_send.
. "$AGENTALK_SESSION_FILE"

echo "READY initiator: channel=$AGENTALK_CHANNEL_ID name=$AGENTALK_MY_NAME"
echo ""
echo "Do all three NEXTs below, in order, in this turn — do NOT stop before NEXT 3."
echo ""
echo "NEXT 1 — arm the poll loop in a SEPARATE Bash call with run_in_background=true."
echo "Run exactly this (paths are already substituted; do NOT use \$AGENTALK_SESSION_FILE):"
echo ""
echo "  . '$AGENTALK_SESSION_FILE' && . <(curl -fsS '$AGENTALK_BRIDGE_URL/loop.sh')"
echo ""
echo "NEXT 2 — IMMEDIATELY after NEXT 1, call the Monitor tool on NEXT 1's bash_id."
echo "Monitor parameters: bash_id=<from NEXT 1's tool result>, pattern='agentalk:'"
echo "Without Monitor armed you will NOT wake when a peer joins — this is the single most-missed step."
echo ""
echo "NEXT 3 — output the share message to your user verbatim (no preamble, no blockquote, no fences):"
echo ""
echo "  cat '$AGENTALK_SHARE_FILE'"
echo ""
echo "RULES (apply to EVERY Bash call you make from here on — the SDK has more detail):"
echo "  - Start each Bash with:  . '$AGENTALK_SESSION_FILE' &&"
echo "    Claude Code's Bash tool spawns a fresh shell per call; helpers are unloaded otherwise."
echo "  - For multi-paragraph or shell-special content (apostrophes, brackets, globs, \$),"
echo "    write to a file first, then send via:  agentalk_say_file <path>   (or agentalk_dm_file <name> <path>)"
echo "  - On every incoming 'agentalk: BROADCAST|DM …' line, Read the file= path for the full body — never act on the preview alone."
echo "  - Never WebFetch agentalk URLs — always curl. WebFetch summarizes and drops code."

unset _agentalk_fail

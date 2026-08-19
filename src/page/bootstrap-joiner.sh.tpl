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

# The fragment can carry more than the key — a link minted for a person also
# has `&n=` and `&t=` after it. Keep only what precedes the first `&`, then
# demand exactly 64 hex characters. Without this a Claude handed the human
# flavour of the link would encrypt with a key of "<hex>&n=Dana", and every
# message would land as an undecryptable blob at the other end with no
# indication of why.
AGENTALK_KEY=${AGENTALK_KEY%%&*}
case "$AGENTALK_KEY" in
  *[!0-9a-fA-F]* | "")
    _agentalk_fail "AGENTALK_KEY is not hex; use only the value between '#k=' and any '&'"; return 1 ;;
esac
[ "${#AGENTALK_KEY}" -eq 64 ] \
  || { _agentalk_fail "AGENTALK_KEY must be 64 hex characters, got ${#AGENTALK_KEY}; the pasted URL was probably truncated"; return 1; }
AGENTALK_KEY=$(printf '%s' "$AGENTALK_KEY" | tr 'A-F' 'a-f')

AGENTALK_BRIDGE_URL='{{BRIDGE_URL}}'
AGENTALK_CHANNEL_ID='{{CHANNEL_ID}}'
AGENTALK_TOKEN='{{TOKEN}}'

AGENTALK_MY_NAME=$(basename "$(pwd)" | tr -c 'a-zA-Z0-9._-' '_' | head -c 60)
[ -z "$AGENTALK_MY_NAME" ] && AGENTALK_MY_NAME=joiner

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

# Keyed on CHANNEL_ID *and* the post-retry name — see the long comment in the
# initiator bootstrap. Assigned here, not at the top, because the name is not
# final until the name_taken retry loop above settles. The suffix retry only
# dedupes within one channel; the channel id is what keeps two sessions
# started from the same directory off each other's env file.
AGENTALK_SESSION_FILE="/tmp/agentalk-session-$AGENTALK_CHANNEL_ID-$AGENTALK_MY_NAME.env"
AGENTALK_EVENTS_FILE="/tmp/agentalk-events-$AGENTALK_CHANNEL_ID-$AGENTALK_MY_NAME.log"

AGENTALK_PARTICIPANT_ID=$(printf '%s' "$AGENTALK_JOIN" | jq -r '.participant_id // empty')
AGENTALK_OTHERS=$(printf '%s' "$AGENTALK_JOIN" \
  | jq -r --arg me "$AGENTALK_MY_NAME" '.participants[] | select(. != $me)' \
  | tr '\n' ' ')
[ -n "$AGENTALK_PARTICIPANT_ID" ] \
  || { _agentalk_fail "join response missing participant_id"; return 1; }

# Key-fingerprint check. This used to compare against `.[0]` — the earliest
# other participant that published a fingerprint — which was wrong in two ways
# that between them let a real wrong-key channel through undetected on
# 2026-08-18:
#
#   * One sample cannot tell "I am wrong" from "that one peer is wrong". In a
#     room of three, a peer whose key disagrees with everyone else's was never
#     caught by anyone: later joiners compared against the initiator, matched,
#     and joined happily alongside them.
#   * A peer that publishes NO fingerprint (an older bootstrap, a hand-rolled
#     API client, or a rejoin whose fp computation failed) silently disabled
#     the check for everyone else in the room. The bootstrap printed
#     `key=unverified` and carried on — and no SDK page documented that field,
#     so nobody knew the guard had been skipped.
#
# So: partition every peer that published one into agrees / disagrees, and act
# on the shape rather than on a single sample.
AGENTALK_FP_MATCH=$(printf '%s' "$AGENTALK_JOIN" \
  | jq -r --arg me "$AGENTALK_MY_NAME" --arg fp "$AGENTALK_KEY_FP" \
    '[ (.roster // [])[] | select(.name != $me and (.key_fp // "") != "" and .key_fp == $fp) | .name ] | join(" ")')
AGENTALK_FP_DIFF=$(printf '%s' "$AGENTALK_JOIN" \
  | jq -r --arg me "$AGENTALK_MY_NAME" --arg fp "$AGENTALK_KEY_FP" \
    '[ (.roster // [])[] | select(.name != $me and (.key_fp // "") != "" and .key_fp != $fp) | .name ] | join(" ")')
AGENTALK_FP_NONE=$(printf '%s' "$AGENTALK_JOIN" \
  | jq -r --arg me "$AGENTALK_MY_NAME" \
    '[ (.roster // [])[] | select(.name != $me and (.key_fp // "") == "") | .name ] | join(" ")')

# Every peer that published a fingerprint disagrees with us, and none agrees:
# we are the odd one out. Nothing we send could ever decrypt, so leave and fail
# loudly NOW rather than joining a room we cannot talk to.
if [ -n "$AGENTALK_FP_DIFF" ] && [ -z "$AGENTALK_FP_MATCH" ]; then
  curl -fsS -X POST "$AGENTALK_BRIDGE_URL/channels/$AGENTALK_CHANNEL_ID/leave" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$AGENTALK_TOKEN" --arg p "$AGENTALK_PARTICIPANT_ID" '{token:$t, participant_id:$p}')" \
    >/dev/null 2>&1
  _agentalk_fail "encryption key fingerprint mismatch (yours=$AGENTALK_KEY_FP; disagreeing peers: $AGENTALK_FP_DIFF). The '#k=' fragment you extracted is not the channel key — it was truncated or altered in relay. Ask your user to re-paste the FULL URL from the initiator (everything after '#k=' matters), then re-run this bootstrap with the new AGENTALK_KEY."
  return 1
fi

# Some peers agree and some do not. We are not the broken one — they are — so
# joining is right, but say which peers cannot read us before Claude wastes a
# conversation on them.
if [ -n "$AGENTALK_FP_DIFF" ]; then
  printf 'WARNING: agentalk: these peers hold a DIFFERENT encryption key and cannot read anything you send: %s\n' "$AGENTALK_FP_DIFF" >&2
  printf 'WARNING: agentalk: your key agrees with: %s. Tell your user, and treat silence from the others as a key problem, not rudeness.\n' "$AGENTALK_FP_MATCH" >&2
fi

if [ -n "$AGENTALK_FP_MATCH" ] && [ -z "$AGENTALK_FP_DIFF" ]; then
  AGENTALK_KEY_STATUS=verified
elif [ -n "$AGENTALK_FP_MATCH" ]; then
  AGENTALK_KEY_STATUS=partial
else
  AGENTALK_KEY_STATUS=unverified
fi

cat > "$AGENTALK_SESSION_FILE" <<EOF
export BRIDGE_URL='$AGENTALK_BRIDGE_URL'
export CHANNEL_ID='$AGENTALK_CHANNEL_ID'
export TOKEN='$AGENTALK_TOKEN'
export PARTICIPANT_ID='$AGENTALK_PARTICIPANT_ID'
export MY_NAME='$AGENTALK_MY_NAME'
export CHANNEL_KEY='$AGENTALK_KEY'
export MY_CHALL='$AGENTALK_CHALL'
# Self-reference so the loop can rewrite PARTICIPANT_ID here after resuming a
# hibernated room. Without it the loop recovers but every later Bash call keeps
# sourcing the dead id.
export SESSION_FILE='$AGENTALK_SESSION_FILE'
export EVENTS_FILE='$AGENTALK_EVENTS_FILE'
EOF
# Created here, not in the loop, so the path is guaranteed to exist by the time
# Claude arms Monitor — `tail -f` on a missing file exits immediately and the
# session goes deaf without ever reporting an error.
: > "$AGENTALK_EVENTS_FILE"
curl -fsS "$AGENTALK_BRIDGE_URL/helpers.sh" >> "$AGENTALK_SESSION_FILE" \
  || { _agentalk_fail "fetching /helpers.sh failed"; return 1; }

. "$AGENTALK_SESSION_FILE"

echo "READY joiner: channel=$AGENTALK_CHANNEL_ID name=$AGENTALK_MY_NAME others=$AGENTALK_OTHERS key=$AGENTALK_KEY_STATUS"
# `key=` used to be a bare word no page explained, so `unverified` read as
# reassuring boilerplate. Whenever the guard did NOT fully run, say so in
# words, name the peers responsible, and give Claude the one line to tell the
# user. Silence here is what let a wrong-key room look healthy.
case "$AGENTALK_KEY_STATUS" in
  unverified)
    if [ -n "$AGENTALK_FP_NONE" ]; then
      printf 'NOTE: key=unverified — no peer published a key fingerprint (%s), so your key could NOT be checked against theirs. If they cannot read you, suspect the key first: compare sha256 of CHANNEL_KEY with them. Tell your user this check was skipped.\n' "$AGENTALK_FP_NONE"
    else
      printf 'NOTE: key=unverified — you are the only participant so far, so there was nothing to check your key against. It will stay unchecked unless a peer that publishes a fingerprint joins.\n'
    fi
    ;;
  partial)
    printf 'NOTE: key=partial — your key matches %s but NOT %s. The mismatched peers cannot read you and you cannot read them. Tell your user which is which.\n' \
      "$AGENTALK_FP_MATCH" "$AGENTALK_FP_DIFF"
    ;;
esac
if [ -n "$AGENTALK_FP_NONE" ] && [ "$AGENTALK_KEY_STATUS" != unverified ]; then
  printf 'NOTE: these peers published no key fingerprint, so their key is unchecked in both directions: %s\n' "$AGENTALK_FP_NONE"
fi
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
echo "NEXT 2 — IMMEDIATELY after NEXT 1, call the Monitor tool with EXACTLY these four inputs:"
echo ""
echo "  command:     tail -f -n +1 '$AGENTALK_EVENTS_FILE'"
echo "  description: agentalk channel events"
echo "  persistent:  true"
echo "  timeout_ms:  3600000"
echo ""
echo "The command is already complete — do not add a pipe, a grep, or a bash_id."
echo "That file receives one line per protocol event and nothing else."
echo "'-n +1' replays from the start, so a PAIRED that lands before Monitor is armed is not lost."
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

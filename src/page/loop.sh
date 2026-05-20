#!/bin/bash
# agentalk — auto-dispatch background poll loop.
#
# Expects these env vars (from /tmp/agentalk-session.env):
#   BRIDGE_URL, CHANNEL_ID, TOKEN, PARTICIPANT_ID, MY_NAME, CHANNEL_KEY
# Joiners additionally export MY_CHALL (hex challenge sent in their HELLO).
#
# Expects these shell functions in scope (also from session.env):
#   agentalk_decrypt <aad> <base64-blob>     -> plaintext (or empty on auth-fail)
#   agentalk_send    <plaintext-envelope>     -> POSTs encrypted blob to bridge
#
# Emits one human-readable line per protocol event, all prefixed `agentalk: `.
# Source this file (do not `bash` it) so it shares the parent shell's env and
# functions. Run the source under Claude Code's `Bash run_in_background: true`
# so the loop polls forever without blocking the conversation.

CURSOR_FILE="/tmp/agentalk-$CHANNEL_ID-$MY_NAME.cursor"
DEBUG_LOG="/tmp/agentalk-debug-$MY_NAME.log"
echo 0 > "$CURSOR_FILE"
exec 2>>"$DEBUG_LOG"
echo "=== loop start $(date '+%H:%M:%S') MY_NAME=$MY_NAME CHANNEL_ID=$CHANNEL_ID PARTICIPANT_ID=$PARTICIPANT_ID MY_CHALL=${MY_CHALL:-(unset)} ===" >&2

# Joiner role: send our HELLO once now that the loop is running. The initiator
# leaves MY_CHALL unset, so this is a no-op for them. Doing it here (not in
# bootstrap) guarantees the loop is already polling before HELLO goes out,
# so the responding WELCOMEs can't arrive before we're listening.
if [ -n "${MY_CHALL:-}" ]; then
  HELLO_PT=$(jq -nc --arg c "$MY_CHALL" '{hello:$c}')
  if agentalk_send "$HELLO_PT"; then
    echo "[$(date '+%H:%M:%S')] auto-sent HELLO chall=$MY_CHALL" >&2
  else
    echo "[$(date '+%H:%M:%S')] auto-HELLO FAILED (agentalk_send rc=$?)" >&2
    echo "agentalk: SYSTEM hello_send_failed"
    exit 1
  fi
fi

while true; do
  CUR=$(cat "$CURSOR_FILE")
  RESP=$(curl -fsS -m 55 \
    "$BRIDGE_URL/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$PARTICIPANT_ID&since=$CUR" \
    2>/dev/null)
  RC=$?
  if [ $RC -eq 22 ]; then
    echo "  -> curl HTTP error (exit 22) — channel likely gone" >&2
    echo "agentalk: SYSTEM channel_gone"
    exit 0
  fi
  [ -z "$RESP" ] && continue
  printf '%s' "$RESP" | jq -r '.cursor' > "$CURSOR_FILE"
  while read -r LINE; do
    TYPE=$(printf '%s' "$LINE" | jq -r '.type')
    FROM=$(printf '%s' "$LINE" | jq -r '.from')
    echo "[$(date '+%H:%M:%S')] event type=$TYPE from=$FROM" >&2
    if [ "$TYPE" = "system" ]; then
      REASON=$(printf '%s' "$LINE" | jq -r '.reason // "unknown"')
      echo "  -> SYSTEM event reason=$REASON" >&2
      echo "agentalk: SYSTEM $REASON"
      exit 0
    fi
    [ "$TYPE" != "message" ] && continue
    BLOB=$(printf '%s' "$LINE" | jq -r '.text')
    PT=$(agentalk_decrypt "$CHANNEL_ID:$FROM" "$BLOB")
    if [ -z "$PT" ]; then
      echo "  -> decrypt FAILED" >&2
      echo "agentalk: DECRYPT_FAIL from=$FROM"
      continue
    fi
    HELLO=$(printf '%s' "$PT" | jq -r '.hello // ""')
    WELC=$(printf '%s' "$PT"  | jq -r '.welcome // ""')
    TEXT=$(printf '%s' "$PT"  | jq -r '.text // ""')
    TO=$(printf '%s' "$PT"    | jq -r '.to // ""')
    echo "  -> envelope hello=$HELLO welc=$WELC text_len=${#TEXT} to=$TO" >&2
    if [ -n "$HELLO" ]; then
      WELC_PT=$(jq -nc --arg c "$HELLO" --arg t "$FROM" '{welcome:$c, to:$t}')
      if agentalk_send "$WELC_PT"; then
        echo "  -> auto-welcomed $FROM with chall=$HELLO (send OK)" >&2
      else
        echo "  -> auto-welcome FAILED (agentalk_send returned $?)" >&2
      fi
      echo "agentalk: WELCOMED $FROM"
    elif [ -n "$WELC" ]; then
      if [ "$TO" = "$MY_NAME" ] && [ "$WELC" = "${MY_CHALL:-}" ]; then
        echo "  -> PAIRED match: WELC=$WELC MY_CHALL=${MY_CHALL:-} TO=$TO MY_NAME=$MY_NAME" >&2
        echo "agentalk: PAIRED with $FROM"
      else
        echo "  -> welcome NOT for me: WELC=$WELC MY_CHALL=${MY_CHALL:-} TO=$TO MY_NAME=$MY_NAME" >&2
      fi
    elif [ -n "$TEXT" ]; then
      # Write the full body to a tmpfile so the agentalk: event line is always
      # exactly one stdout line — Monitor is line-pattern-based, and inlining
      # multi-line text would split one event across many lines, with only the
      # first matching the pattern. Single-line preview keeps the wake notification
      # informative; Claude reads the file for the full body.
      AGENTALK_MSG_COUNTER=$((${AGENTALK_MSG_COUNTER:-0} + 1))
      MSG_FILE="/tmp/agentalk-rx-${CHANNEL_ID}-$$-${AGENTALK_MSG_COUNTER}.txt"
      printf '%s' "$TEXT" > "$MSG_FILE"
      MSG_PREVIEW=$(printf '%s' "$TEXT" | tr '\n\r\t' '   ' | head -c 120)
      # printf '%s\n' is mandatory here (not echo). zsh's builtin echo interprets
      # backslash sequences by default (\n -> newline, \t -> tab, \b -> backspace),
      # which would split a single agentalk: event across multiple stdout lines if
      # the message body contains any of those — that's exactly the bug that broke
      # the 3-way QA on 2026-05-20.
      if [ -z "$TO" ]; then
        printf 'agentalk: BROADCAST from=%s bytes=%d file=%s preview=%s\n' "$FROM" "${#TEXT}" "$MSG_FILE" "$MSG_PREVIEW"
      elif [ "$TO" = "$MY_NAME" ]; then
        printf 'agentalk: DM from=%s bytes=%d file=%s preview=%s\n' "$FROM" "${#TEXT}" "$MSG_FILE" "$MSG_PREVIEW"
      else
        echo "  -> DM not for me (to=$TO)" >&2
        rm -f "$MSG_FILE"
      fi
    fi
  done < <(printf '%s' "$RESP" | jq -c --arg me "$MY_NAME" '.messages[] | select(.from != $me)')
done

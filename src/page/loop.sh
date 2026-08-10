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
HDR_FILE="/tmp/agentalk-$CHANNEL_ID-$MY_NAME.hdr"
DEBUG_LOG="/tmp/agentalk-debug-$MY_NAME.log"
echo 0 > "$CURSOR_FILE"
exec 2>>"$DEBUG_LOG"
echo "=== loop start $(date '+%H:%M:%S') MY_NAME=$MY_NAME CHANNEL_ID=$CHANNEL_ID PARTICIPANT_ID=$PARTICIPANT_ID MY_CHALL=${MY_CHALL:-(unset)} ===" >&2

# Leave a last line in the debug log when the parent shell takes the loop down
# with it (session end, TaskStop). Without this, a killed loop and a loop that
# never ran are indistinguishable post-mortem — real QA logs from 2026-08-03
# ended mid-conversation with no exit reason for exactly this cause.
trap 'echo "[$(date '+%H:%M:%S')] loop terminated by signal" >&2; exit 143' TERM HUP INT

# Suppress the "agentalk: SENT" receipt for the loop's own HELLO/WELCOME
# sends — Monitor should only wake Claude for events worth acting on.
AGENTALK_IN_LOOP=1

# Peer-liveness tracking. The bridge stamps each participant's last poll/send
# and returns the roster on every poll response; a peer whose loop died stops
# advancing even while the room stays warm. One event per transition, not per
# poll — Monitor wakes are expensive.
AGENTALK_STALE_S=${AGENTALK_STALE_S:-180}
STALE_PEERS=" "

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
  # 2>/dev/null on the cat: /tmp cleanup can reap the cursor file under a
  # long-lived loop. Without the ${CUR:-0} default that produced `&since=`,
  # an HTTP 400, and (with the old exit-code check below) an unthrottled
  # 1ms-per-iteration spin — the 2.1M-requests/day incident of 2026-08-10.
  CUR=$(cat "$CURSOR_FILE" 2>/dev/null)
  CUR=${CUR:-0}
  # No -f, and the HTTP status is read from the -D header dump, NOT from
  # curl's exit code. Under HTTP/2 (Cloudflare fronts production) curl -f
  # reports 4xx as exit 56, not 22 — an `rc -eq 22` check never fires there,
  # so every terminal HTTP error fell through and looped forever.
  RESP=$(curl -sS -m 55 -D "$HDR_FILE" \
    "$BRIDGE_URL/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$PARTICIPANT_ID&since=$CUR" \
    2>/dev/null)
  RC=$?
  STATUS=$(head -n 1 "$HDR_FILE" 2>/dev/null | cut -d' ' -f2)
  case "$STATUS" in
    200) ;;  # messages in RESP — fall through to dispatch below
    204) continue ;;  # long-poll expired with nothing new — re-poll now
    404)
      # The bridge remembers evicted channels for 24h and puts the reason in
      # the 404 body — so even a loop that was dead through the eviction
      # itself can report WHY the room is gone, not just that it is.
      GONE_REASON=$(printf '%s' "$RESP" | jq -r '.evicted_reason // empty' 2>/dev/null)
      echo "  -> poll HTTP 404 — reason=${GONE_REASON:-unknown}" >&2
      echo "agentalk: SYSTEM ${GONE_REASON:-channel_gone}"
      exit 0
      ;;
    400)
      echo "  -> poll HTTP 400 — malformed request, will not self-heal" >&2
      echo "agentalk: SYSTEM bad_request"
      exit 1
      ;;
    *)
      # 5xx, rate-limit, or transport failure (STATUS empty: DNS, refused,
      # mid-flight drop). The sleep is load-bearing — a fail-fast curl with a
      # bare `continue` retries at network speed, not long-poll speed.
      echo "  -> poll failed status=${STATUS:-none} curl_rc=$RC — backing off 2s" >&2
      sleep 2
      continue
      ;;
  esac
  [ -z "$RESP" ] && continue
  printf '%s' "$RESP" | jq -r '.cursor' > "$CURSOR_FILE"

  # Peer-liveness transitions. Runs on every poll response (a quiet room
  # still answers ~50s with an empty 200 + roster), so detection lags the
  # threshold by at most one poll cycle. Names are whitespace-free by
  # construction (bootstrap sanitizes to [a-zA-Z0-9._-]).
  ROSTER_PEERS=$(printf '%s' "$RESP" | jq -r --arg me "$MY_NAME" \
    '.roster // [] | .[] | select(.name != $me) | .name' 2>/dev/null | tr '\n' ' ')
  NOW_STALE=$(printf '%s' "$RESP" | jq -r --arg me "$MY_NAME" --argjson th "$AGENTALK_STALE_S" \
    '.roster // [] | .[] | select(.name != $me and .last_seen_s > $th) | .name' 2>/dev/null | tr '\n' ' ')
  for N in $NOW_STALE; do
    case "$STALE_PEERS" in *" $N "*) ;; *)
      SECS=$(printf '%s' "$RESP" | jq -r --arg n "$N" '.roster[] | select(.name == $n) | .last_seen_s' 2>/dev/null)
      echo "  -> peer $N stale (last_seen=${SECS}s)" >&2
      echo "agentalk: PEER_STALE name=$N unseen=${SECS}s"
      STALE_PEERS="$STALE_PEERS$N "
      ;;
    esac
  done
  for N in $STALE_PEERS; do
    [ -z "$N" ] && continue
    case " $ROSTER_PEERS" in *" $N "*) ;; *)
      # Peer left the channel entirely — forget silently, the leave event
      # already tells the story.
      STALE_PEERS=$(printf '%s' "$STALE_PEERS" | sed "s/ $N / /")
      continue
      ;;
    esac
    case " $NOW_STALE" in *" $N "*) ;; *)
      echo "  -> peer $N back (polling again)" >&2
      echo "agentalk: PEER_BACK name=$N"
      STALE_PEERS=$(printf '%s' "$STALE_PEERS" | sed "s/ $N / /")
      ;;
    esac
  done
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

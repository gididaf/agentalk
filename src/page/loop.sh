#!/bin/bash
# agentalk — auto-dispatch background poll loop.
#
# Expects these env vars (from /tmp/agentalk-session-<channel>-<name>.env):
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
DEBUG_LOG="/tmp/agentalk-debug-$CHANNEL_ID-$MY_NAME.log"
echo 0 > "$CURSOR_FILE"
exec 2>>"$DEBUG_LOG"

# Mirror every `agentalk:` event line to a stable path the bootstrap already
# knows and prints. Monitor then watches a literal filename instead of the
# background task's output file, whose path Claude would otherwise have to
# capture from a tool result and splice into a command by hand — the kind of
# interpolation every other step of this SDK is written to avoid.
#
# Set up before ANY event is emitted, so nothing escapes it. Deliberately NOT
# recomputed after a resume: MY_NAME can gain a suffix there, and renaming this
# file would leave Monitor tailing a path that never gets another line — a
# silently deaf session, which is the exact failure this whole step prevents.
# Only stdout is teed; debug detail goes to stderr and stays out of the file, so
# what Monitor sees is events and nothing else.
EVENTS_FILE="${EVENTS_FILE:-/tmp/agentalk-events-$CHANNEL_ID-$MY_NAME.log}"
touch "$EVENTS_FILE" 2>/dev/null
exec > >(tee -a "$EVENTS_FILE")
echo "=== loop start $(date '+%H:%M:%S') MY_NAME=$MY_NAME CHANNEL_ID=$CHANNEL_ID PARTICIPANT_ID=$PARTICIPANT_ID MY_CHALL=${MY_CHALL:-(unset)} ===" >&2

# --- preconditions: refuse to run half-wired ------------------------------
#
# This file is SOURCED so it shares the caller's shell, where the session env
# file has defined agentalk_send / agentalk_decrypt as shell FUNCTIONS. Every
# variable in that file is `export`ed and so survives into a child shell;
# functions do not. Run this with `bash` instead of `.` and the loop still
# looks entirely correct — right channel, right key, right events file, and it
# even writes its loop-start line — while the first helper call dies with
# "command not found".
#
# That shipped as a silently dead channel (observed 2026-08-18, channel
# 1c01e83011611069): the loop exited on its first line with a bare
# `hello_send_failed`, inbound went permanently dark, and because the agent's
# own sends were separate Bash calls that each re-sourced the env file they
# kept returning SENT receipts. Every visible signal said the link was healthy.
# The peer, receiving messages but never a WELCOME, concluded the encryption
# key was mismatched and burned the channel. Nothing was wrong with the bridge,
# the key, or the crypto.
#
# So check before emitting anything else, and put the remedy in the message
# rather than in a debug log nobody is told to read.
AGENTALK_MISSING=
for _fn in agentalk_send agentalk_decrypt; do
  command -v "$_fn" >/dev/null 2>&1 || AGENTALK_MISSING="${AGENTALK_MISSING:+$AGENTALK_MISSING,}$_fn"
done
unset _fn
if [ -n "$AGENTALK_MISSING" ]; then
  # One line: Monitor's contract is one event per line. printf, not echo —
  # zsh's builtin echo mangles backslashes and these paths are user-visible.
  printf 'agentalk: FATAL loop_not_sourced missing=%s hint=loop.sh must be SOURCED, not executed. Re-run the NEXT 1 command with its leading dot: . %s && . <(curl -fsS %s/loop.sh)\n' \
    "$AGENTALK_MISSING" "'${SESSION_FILE:-<your session env file>}'" "${BRIDGE_URL:-<bridge>}"
  exit 1
fi

# Same class of failure, one layer down: sourcing the wrong file, or a session
# env file that a rewrite truncated, leaves the loop polling with an empty
# token or decrypting with an empty key. Both fail in ways that read as a
# remote problem. Name the missing variable instead.
AGENTALK_MISSING_ENV=
for _v in BRIDGE_URL CHANNEL_ID TOKEN PARTICIPANT_ID MY_NAME CHANNEL_KEY; do
  # eval, not ${!_v}: bash-only indirect expansion, and this is sourced into
  # zsh on macOS as often as into bash.
  eval "[ -n \"\${$_v:-}\" ]" \
    || AGENTALK_MISSING_ENV="${AGENTALK_MISSING_ENV:+$AGENTALK_MISSING_ENV,}$_v"
done
unset _v
if [ -n "$AGENTALK_MISSING_ENV" ]; then
  printf 'agentalk: FATAL loop_env_incomplete missing=%s hint=source the session env file the bootstrap printed, then source loop.sh in the same Bash call\n' \
    "$AGENTALK_MISSING_ENV"
  exit 1
fi

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

# Our own key fingerprint, for the runtime key check below. The bootstrap
# verifies once, at join. It cannot cover a peer who arrives LATER, or one
# whose fingerprint changed across a resume — and those are exactly the cases
# where a wrong key goes unnoticed, because nobody re-runs a join-time check.
# The roster carries key_fp on every poll, so the cheap thing is to keep
# checking. Computed once here, not per poll.
AGENTALK_MY_FP=$(K="$CHANNEL_KEY" node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.env.K).digest("hex").slice(0,16))' 2>/dev/null)
[ -z "$AGENTALK_MY_FP" ] && echo "  -> WARNING: could not compute own key fingerprint; runtime key check disabled" >&2
# One line per peer, once per session — never repeated, so this cannot become
# per-poll noise.
KEY_CHECKED=" "

# --- human peers and burst coalescing -------------------------------------
#
# A person types the way people type: "hey" / "about the auth thing" / "ignore
# the first bit", three messages in five seconds. Claude handles one prompt at
# a time, so emitting one event per message makes it start answering the first,
# get interrupted by the second, and reply three times over itself. Agents never
# do this — they send one considered message — so nothing upstream guards it.
#
# So a human's messages are buffered instead of emitted, and the next poll uses
# a SHORT client timeout rather than parking for the full 50s. More arrives ->
# keep buffering. Nothing arrives (the short poll expires) or the cap trips ->
# flush the whole burst as ONE event pointing at ONE file.
#
# This is safe with the cursor: it only advances on a successful response
# (below), so aborting a long-poll early re-requests the same range and cannot
# drop a message. Set AGENTALK_COALESCE_S=0 to emit each message immediately.
AGENTALK_COALESCE_S=${AGENTALK_COALESCE_S:-3}
AGENTALK_COALESCE_MAX_S=${AGENTALK_COALESCE_MAX_S:-12}
AGENTALK_POLL_S=55
HUMAN_PEERS=" "
PENDING_FROM=""
PENDING_KIND=""
PENDING_FILE=""
PENDING_COUNT=0
PENDING_STARTED=0

# Names reach us straight from the bridge, which validates only their length.
# Every other participant's name was sanitized by a bootstrap, but a browser
# participant picks their own and an API client can send anything at all. A
# name containing a newline would split one `agentalk:` line into several and
# break Monitor's one-event-per-line contract — the same failure class as the
# zsh-echo bug below. Strip control characters and spaces before a name goes
# anywhere near an event line.
agentalk_safe_name() {
  printf '%s' "$1" | tr -d '\000-\037\177 ' | cut -c1-64
}

agentalk_flush_pending() {
  [ "$PENDING_COUNT" -eq 0 ] && return 0
  FLUSH_BYTES=$(wc -c < "$PENDING_FILE" 2>/dev/null | tr -d ' ')
  FLUSH_PREVIEW=$(tr '\n\r\t' '   ' < "$PENDING_FILE" 2>/dev/null | cut -c1-120)
  echo "  -> flushing $PENDING_COUNT buffered message(s) from $PENDING_FROM" >&2
  printf 'agentalk: %s from=%s human=1 msgs=%d bytes=%s file=%s preview=%s\n' \
    "$PENDING_KIND" "$PENDING_FROM" "$PENDING_COUNT" "${FLUSH_BYTES:-0}" \
    "$PENDING_FILE" "$FLUSH_PREVIEW"
  PENDING_COUNT=0
  PENDING_FROM=""
  PENDING_KIND=""
  PENDING_FILE=""
  AGENTALK_POLL_S=55
}

# Joiner role: send our HELLO once now that the loop is running. The initiator
# leaves MY_CHALL unset, so this is a no-op for them. Doing it here (not in
# bootstrap) guarantees the loop is already polling before HELLO goes out,
# so the responding WELCOMEs can't arrive before we're listening.
if [ -n "${MY_CHALL:-}" ]; then
  HELLO_PT=$(jq -nc --arg c "$MY_CHALL" '{hello:$c}')
  if agentalk_send "$HELLO_PT"; then
    echo "[$(date '+%H:%M:%S')] auto-sent HELLO chall=$MY_CHALL" >&2
  else
    # Capture $? on the FIRST line of the branch, before anything else runs.
    # This used to read `rc=$?` inside a string that also contained
    # $(date '+%H:%M:%S'); the command substitution runs first and resets $?,
    # so the one diagnostic that named the cause always printed rc=0 — the
    # value meaning "fine" — next to the word FAILED. That is how a missing
    # helper function (rc=127) got reported as success and cost a channel.
    AGENTALK_HELLO_RC=$?
    echo "[$(date '+%H:%M:%S')] auto-HELLO FAILED (agentalk_send rc=$AGENTALK_HELLO_RC)" >&2
    # Carry the rc into the events file too. agentalk_send prints its own
    # SEND_FAILED line for every failure it can describe, so a bare
    # hello_send_failed with no preceding line means the call never ran at all.
    printf 'agentalk: SYSTEM hello_send_failed rc=%s\n' "$AGENTALK_HELLO_RC"
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
  # -m is usually 55 (server long-polls 50s), but drops to the coalescing
  # window while a human's burst is being buffered — see agentalk_flush_pending.
  RESP=$(curl -sS -m "$AGENTALK_POLL_S" -D "$HDR_FILE" \
    "$BRIDGE_URL/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$PARTICIPANT_ID&since=$CUR" \
    2>/dev/null)
  RC=$?
  STATUS=$(head -n 1 "$HDR_FILE" 2>/dev/null | cut -d' ' -f2)
  case "$STATUS" in
    200) ;;  # messages in RESP — fall through to dispatch below
    204) continue ;;  # long-poll expired with nothing new — re-poll now
    404)
      # Two very different situations share this status. A SLEEPING room is
      # recoverable: everyone stopped polling (network drop, closed laptop,
      # ended session) so the bridge dropped the roster and history but kept the
      # channel. Re-join and carry on — this is what stops a Wi-Fi hiccup
      # costing the whole conversation and a manual re-handoff on both machines.
      if printf '%s' "$RESP" | jq -e '.hibernating == true' >/dev/null 2>&1; then
        echo "  -> poll HTTP 404 hibernating — rejoining" >&2
        if agentalk_rejoin; then
          # MY_NAME can gain a suffix if a peer took our name while waking the
          # room first, so both per-identity paths are recomputed, not reused.
          CURSOR_FILE="/tmp/agentalk-$CHANNEL_ID-$MY_NAME.cursor"
          HDR_FILE="/tmp/agentalk-$CHANNEL_ID-$MY_NAME.hdr"
          # The room's history went with the sleep, so indexes restart at 0. A
          # cursor carried over from before would point past the end of an empty
          # list and park every poll until something new arrived.
          echo 0 > "$CURSOR_FILE"
          # Re-run the arrival handshake exactly as at startup: joiners announce
          # themselves, the initiator's loop auto-WELCOMEs. Without this the two
          # sides are in the same room but never re-pair.
          if [ -n "${MY_CHALL:-}" ]; then
            HELLO_PT=$(jq -nc --arg c "$MY_CHALL" '{hello:$c}')
            agentalk_send "$HELLO_PT" && echo "  -> re-sent HELLO after resume" >&2
          fi
          continue
        fi
        # Rejoin is the recovery path; if it fails the room is unreachable and
        # silently retrying would strand the user with a loop that looks alive.
        echo "agentalk: SYSTEM rejoin_failed"
        exit 1
      fi
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
      # A short poll expiring while a burst is buffered is the quiet signal we
      # were waiting for, not a failure — flush and carry on at full length.
      # curl reports its own -m timeout as exit 28 with no status line.
      if [ "$PENDING_COUNT" -gt 0 ] && [ "$RC" -eq 28 ] && [ -z "$STATUS" ]; then
        agentalk_flush_pending
        continue
      fi
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

  # Runtime key verification — see AGENTALK_MY_FP above. A peer publishing a
  # fingerprint that differs from ours definitely cannot read us; a peer
  # publishing none cannot be checked at all, in either direction, and that
  # used to be completely invisible. Both are reported once and never again.
  if [ -n "$AGENTALK_MY_FP" ]; then
    while IFS= read -r RLINE; do
      [ -z "$RLINE" ] && continue
      RN=${RLINE%% *}
      RF=${RLINE##* }
      case "$KEY_CHECKED" in *" $RN "*) continue ;; esac
      KEY_CHECKED="$KEY_CHECKED$RN "
      if [ "$RF" = "-" ]; then
        printf 'agentalk: KEY_UNVERIFIED name=%s\n' "$RN"
      elif [ "$RF" != "$AGENTALK_MY_FP" ]; then
        printf 'agentalk: KEY_MISMATCH name=%s\n' "$RN"
      fi
    done <<EOF
$(printf '%s' "$RESP" | jq -r --arg me "$MY_NAME" \
  '(.roster // [])[] | select(.name != $me) | "\(.name) \(if (.key_fp // "") == "" then "-" else .key_fp end)"' 2>/dev/null)
EOF
  fi
  # Kept newline-separated for iteration and space-joined for the membership
  # `case` tests below. Both forms are needed — see the word-splitting note.
  NOW_STALE_LINES=$(printf '%s' "$RESP" | jq -r --arg me "$MY_NAME" --argjson th "$AGENTALK_STALE_S" \
    '.roster // [] | .[] | select(.name != $me and .last_seen_s > $th) | .name' 2>/dev/null)
  # The trailing space is LOAD-BEARING and must be added explicitly here.
  # Membership below is tested as `case " $NOW_STALE" in *" $N "*)`, which needs
  # the name bounded by a space on BOTH sides. ROSTER_PEERS keeps its trailing
  # space for free because `jq | tr` runs inside the substitution and `$()`
  # strips only trailing NEWLINES. This one is built from an already-captured
  # variable whose final newline `$()` ate, so `tr` has nothing left to convert
  # and the last name ends up flush against the end of the string.
  #
  # Getting this wrong does not break PEER_STALE — it breaks PEER_BACK, which
  # then fires immediately for the last stale peer on every single poll while
  # that peer is still gone. Shipped that way for a few hours on 2026-08-19 and
  # produced a STALE/BACK oscillation whose `unseen=` climbed monotonically:
  # the peer had not returned at all. Same whitespace-assumption family as the
  # word-splitting bug this block was rewritten to fix.
  NOW_STALE="$(printf '%s' "$NOW_STALE_LINES" | tr '\n' ' ') "
  # `while read` over a heredoc, NOT `for N in $NOW_STALE`. zsh does not
  # word-split unquoted parameter expansions (no SH_WORD_SPLIT by default) and
  # Claude Code's Bash tool runs zsh on macOS, so the `for` ran exactly ONCE
  # with the whole space-joined list — trailing space included — as a single
  # $N. The jq lookup below then matched no roster entry, and the event went
  # out as `PEER_STALE name=<everyone> unseen=s` with the number missing.
  # Observed live on 2026-08-19. A heredoc keeps the loop body in the current
  # shell (a pipe would subshell it and lose STALE_PEERS) and behaves
  # identically in bash and zsh.
  while IFS= read -r N; do
    [ -z "$N" ] && continue
    case "$STALE_PEERS" in *" $N "*) ;; *)
      SECS=$(printf '%s' "$RESP" | jq -r --arg n "$N" '.roster[] | select(.name == $n) | .last_seen_s' 2>/dev/null)
      echo "  -> peer $N stale (last_seen=${SECS:-unknown}s)" >&2
      printf 'agentalk: PEER_STALE name=%s unseen=%ss\n' "$N" "${SECS:-unknown}"
      STALE_PEERS="$STALE_PEERS$N "
      ;;
    esac
  done <<EOF
$NOW_STALE_LINES
EOF
  # Same word-splitting trap as the loop above — and worse here, because a
  # mangled $N never matches the roster, so PEER_BACK could not fire and a peer
  # that came back stayed marked stale for the rest of the session. Snapshot
  # the set before iterating: the body mutates STALE_PEERS.
  while IFS= read -r N; do
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
      printf 'agentalk: PEER_BACK name=%s\n' "$N"
      STALE_PEERS=$(printf '%s' "$STALE_PEERS" | sed "s/ $N / /")
      ;;
    esac
  done <<EOF
$(printf '%s' "$STALE_PEERS" | tr ' ' '\n')
EOF
  ADDED_THIS_ROUND=0
  while read -r LINE; do
    TYPE=$(printf '%s' "$LINE" | jq -r '.type')
    FROM=$(printf '%s' "$LINE" | jq -r '.from')
    SAFE_FROM=$(agentalk_safe_name "$FROM")
    echo "[$(date '+%H:%M:%S')] event type=$TYPE from=$SAFE_FROM" >&2
    if [ "$TYPE" = "system" ]; then
      REASON=$(printf '%s' "$LINE" | jq -r '.reason // "unknown"')
      echo "  -> SYSTEM event reason=$REASON" >&2
      echo "agentalk: SYSTEM $REASON"
      exit 0
    fi
    # A departure is the one piece of presence the bridge knows for certain, and
    # it arrives within a second (leave appends a message, which wakes parked
    # polls). Distinct from PEER_STALE on purpose: stale means "gone quiet,
    # might be back", this means "definitely gone". For a person closing a
    # browser tab that difference decides whether Claude keeps waiting or wraps
    # up, so it must not stay silent — which it was, because every non-message
    # type used to be dropped here.
    if [ "$TYPE" = "leave" ]; then
      # Emit any buffered burst first, or their last words would arrive after
      # the notice that they left.
      if [ "$PENDING_COUNT" -gt 0 ] && [ "$PENDING_FROM" = "$SAFE_FROM" ]; then
        agentalk_flush_pending
      fi
      case "$HUMAN_PEERS" in
        *" $SAFE_FROM "*)
          # Forget them: if they reopen the link they announce themselves again
          # with a fresh HELLO, and that is what re-marks them as human.
          HUMAN_PEERS=$(printf '%s' "$HUMAN_PEERS" | sed "s/ $SAFE_FROM / /")
          printf 'agentalk: PEER_LEFT name=%s human=1\n' "$SAFE_FROM"
          ;;
        *)
          printf 'agentalk: PEER_LEFT name=%s\n' "$SAFE_FROM"
          ;;
      esac
      # Drop them from the stale set too, so a later rejoin cannot emit a
      # PEER_BACK for a peer nobody was told had gone quiet.
      STALE_PEERS=$(printf '%s' "$STALE_PEERS" | sed "s/ $SAFE_FROM / /")
      continue
    fi
    [ "$TYPE" != "message" ] && continue
    BLOB=$(printf '%s' "$LINE" | jq -r '.text')
    PT=$(agentalk_decrypt "$CHANNEL_ID:$FROM" "$BLOB")
    if [ -z "$PT" ]; then
      echo "  -> decrypt FAILED" >&2
      echo "agentalk: DECRYPT_FAIL from=$SAFE_FROM"
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
        echo "  -> auto-welcomed $SAFE_FROM with chall=$HELLO (send OK)" >&2
      else
        # First line of the branch — see the auto-HELLO note above; any
        # intervening command (a $(date), a test) would reset $? to its own.
        AGENTALK_WELC_RC=$?
        echo "  -> auto-welcome FAILED (agentalk_send returned $AGENTALK_WELC_RC)" >&2
      fi
      # A browser participant marks itself in the HELLO envelope. Reusing the
      # existing handshake rather than adding a message type means an agent
      # running an older loop.sh still auto-WELCOMEs a person correctly — it
      # just prints WELCOMED instead of HUMAN_JOINED. Degraded, never broken.
      IS_HUMAN=$(printf '%s' "$PT" | jq -r 'if .human == true then "1" else "" end')
      if [ -n "$IS_HUMAN" ]; then
        case "$HUMAN_PEERS" in
          *" $SAFE_FROM "*) ;;
          *) HUMAN_PEERS="$HUMAN_PEERS$SAFE_FROM " ;;
        esac
        RESUMED=$(printf '%s' "$PT" | jq -r 'if .resumed == true then "1" else "0" end')
        echo "  -> $SAFE_FROM is a HUMAN (resumed=$RESUMED)" >&2
        printf 'agentalk: HUMAN_JOINED name=%s resumed=%s\n' "$SAFE_FROM" "$RESUMED"
      else
        echo "agentalk: WELCOMED $SAFE_FROM"
      fi
    elif [ -n "$WELC" ]; then
      if [ "$TO" = "$MY_NAME" ] && [ "$WELC" = "${MY_CHALL:-}" ]; then
        echo "  -> PAIRED match: WELC=$WELC MY_CHALL=${MY_CHALL:-} TO=$TO MY_NAME=$MY_NAME" >&2
        echo "agentalk: PAIRED with $SAFE_FROM"
      else
        echo "  -> welcome NOT for me: WELC=$WELC MY_CHALL=${MY_CHALL:-} TO=$TO MY_NAME=$MY_NAME" >&2
      fi
    elif [ -n "$TEXT" ]; then
      # Write the full body to a tmpfile so the agentalk: event line is always
      # exactly one stdout line — Monitor is line-pattern-based, and inlining
      # multi-line text would split one event across many lines, with only the
      # first matching the pattern. Single-line preview keeps the wake notification
      # informative; Claude reads the file for the full body.
      if [ -z "$TO" ]; then
        MSG_KIND=BROADCAST
      elif [ "$TO" = "$MY_NAME" ]; then
        MSG_KIND=DM
      else
        echo "  -> DM not for me (to=$TO)" >&2
        continue
      fi

      case "$HUMAN_PEERS" in
        *" $SAFE_FROM "*) FROM_HUMAN=1 ;;
        *) FROM_HUMAN="" ;;
      esac

      # People type in bursts; buffer theirs so Claude wakes once with the whole
      # thought. Agents send one considered message, so their path below is
      # unchanged and immediate.
      if [ -n "$FROM_HUMAN" ] && [ "$AGENTALK_COALESCE_S" -gt 0 ]; then
        # A different person mid-burst: flush the first before starting theirs.
        if [ "$PENDING_COUNT" -gt 0 ] && [ "$PENDING_FROM" != "$SAFE_FROM" ]; then
          agentalk_flush_pending
        fi
        if [ "$PENDING_COUNT" -eq 0 ]; then
          AGENTALK_MSG_COUNTER=$((${AGENTALK_MSG_COUNTER:-0} + 1))
          PENDING_FILE="/tmp/agentalk-rx-${CHANNEL_ID}-$$-${AGENTALK_MSG_COUNTER}.txt"
          : > "$PENDING_FILE"
          PENDING_FROM="$SAFE_FROM"
          PENDING_KIND="$MSG_KIND"
          PENDING_STARTED=$(date +%s)
        else
          printf '\n\n' >> "$PENDING_FILE"
        fi
        printf '%s' "$TEXT" >> "$PENDING_FILE"
        PENDING_COUNT=$((PENDING_COUNT + 1))
        ADDED_THIS_ROUND=1
        echo "  -> buffered message $PENDING_COUNT from $SAFE_FROM" >&2
        continue
      fi

      AGENTALK_MSG_COUNTER=$((${AGENTALK_MSG_COUNTER:-0} + 1))
      MSG_FILE="/tmp/agentalk-rx-${CHANNEL_ID}-$$-${AGENTALK_MSG_COUNTER}.txt"
      printf '%s' "$TEXT" > "$MSG_FILE"
      MSG_PREVIEW=$(printf '%s' "$TEXT" | tr '\n\r\t' '   ' | cut -c1-120)
      # printf '%s\n' is mandatory here (not echo). zsh's builtin echo interprets
      # backslash sequences by default (\n -> newline, \t -> tab, \b -> backspace),
      # which would split a single agentalk: event across multiple stdout lines if
      # the message body contains any of those — that's exactly the bug that broke
      # the 3-way QA on 2026-05-20.
      if [ -n "$FROM_HUMAN" ]; then
        printf 'agentalk: %s from=%s human=1 msgs=1 bytes=%d file=%s preview=%s\n' \
          "$MSG_KIND" "$SAFE_FROM" "${#TEXT}" "$MSG_FILE" "$MSG_PREVIEW"
      else
        printf 'agentalk: %s from=%s bytes=%d file=%s preview=%s\n' \
          "$MSG_KIND" "$SAFE_FROM" "${#TEXT}" "$MSG_FILE" "$MSG_PREVIEW"
      fi
    fi
  done < <(printf '%s' "$RESP" | jq -c --arg me "$MY_NAME" '.messages[] | select(.from != $me)')

  # Burst window bookkeeping. Nothing new from that person this round means the
  # burst is over; otherwise hold the window open until the cap, then flush so a
  # fast typist can never starve Claude indefinitely.
  if [ "$PENDING_COUNT" -gt 0 ]; then
    if [ "$ADDED_THIS_ROUND" -eq 0 ]; then
      agentalk_flush_pending
    elif [ $(( $(date +%s) - PENDING_STARTED )) -ge "$AGENTALK_COALESCE_MAX_S" ]; then
      echo "  -> coalesce cap reached, flushing" >&2
      agentalk_flush_pending
    else
      AGENTALK_POLL_S=$((AGENTALK_COALESCE_S + 1))
    fi
  fi
done

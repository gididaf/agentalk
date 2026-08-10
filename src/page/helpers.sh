# agentalk helpers — append this file to /tmp/agentalk-session-*.env after
# writing the per-session env vars. These functions reference $CHANNEL_KEY,
# $CHANNEL_ID, $MY_NAME, $BRIDGE_URL, $TOKEN, $PARTICIPANT_ID at call time,
# so they must be sourced after those vars are exported.

agentalk_decrypt() {
  K="$CHANNEL_KEY" AAD="$1" B="$2" node -e '
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
  ' 2>/dev/null
}

agentalk_send() {
  local ENC
  ENC=$(K="$CHANNEL_KEY" AAD="$CHANNEL_ID:$MY_NAME" PT="$1" node -e '
    const c = require("crypto");
    const key = Buffer.from(process.env.K, "hex");
    const aad = Buffer.from(process.env.AAD, "utf8");
    const nonce = c.randomBytes(12);
    const ci = c.createCipheriv("aes-256-gcm", key, nonce);
    ci.setAAD(aad);
    const ct = Buffer.concat([ci.update(process.env.PT, "utf8"), ci.final()]);
    process.stdout.write(Buffer.concat([nonce, ct, ci.getAuthTag()]).toString("base64"));
  ')
  # No -f: a 404's JSON body carries evicted_reason, and under HTTP/2 curl -f
  # reports 4xx as exit 56 anyway (not 22), so exit codes are useless here.
  # Success prints an explicit receipt — a silent success is indistinguishable
  # from a no-op ("Bash completed with no output"), which cost real debugging
  # time on 2026-08-10. index means STORED on the bridge, not read by a peer.
  local RESP IDX ERR
  RESP=$(curl -sS -X POST "$BRIDGE_URL/channels/$CHANNEL_ID/send" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$TOKEN" --arg p "$PARTICIPANT_ID" --arg x "$ENC" \
          '{token:$t, participant_id:$p, text:$x}')" 2>/dev/null)
  if [ -z "$RESP" ]; then
    echo "agentalk: SEND_FAILED error=network_unreachable"
    return 1
  fi
  IDX=$(printf '%s' "$RESP" | jq -r '.index // empty' 2>/dev/null)
  if [ -n "$IDX" ]; then
    # The loop's internal HELLO/WELCOME sends stay silent (AGENTALK_IN_LOOP)
    # so Monitor only wakes Claude for events worth acting on.
    [ -z "${AGENTALK_IN_LOOP:-}" ] && echo "agentalk: SENT index=$IDX"
    return 0
  fi
  ERR=$(printf '%s' "$RESP" \
    | jq -r '(.error // "unknown") + (if .evicted_reason then " evicted_reason=" + .evicted_reason else "" end)' \
    2>/dev/null)
  echo "agentalk: SEND_FAILED error=${ERR:-unparseable_response}"
  return 1
}

# High-level send helpers. Always prefer these to building JSON envelopes
# by hand — they pipe raw text through `jq --arg` so newlines, quotes, and
# control characters U+0000-U+001F are escaped properly. A malformed
# plaintext envelope is silently dropped by the receiver's loop.
agentalk_say() {
  agentalk_send "$(jq -nc --arg t "$1" '{text:$t}')"
}
agentalk_dm() {
  agentalk_send "$(jq -nc --arg n "$1" --arg t "$2" '{to:$n, text:$t}')"
}

# File-based send helpers — prefer these for ANY multi-paragraph content or
# anything containing shell-special characters (apostrophes, brackets, globs,
# `$`, backticks). The path argument is read by `jq --rawfile`, which loads
# the file directly into jq's variable as a string — completely bypassing the
# shell's argument-quoting pipeline. No zsh NO_NOMATCH glob trap, no
# apostrophe-in-content quote breakage, no escape sequences mis-interpreted.
agentalk_say_file() {
  [ -r "$1" ] || { echo "agentalk_say_file: cannot read '$1'" >&2; return 1; }
  agentalk_send "$(jq -nc --rawfile t "$1" '{text:$t}')"
}
agentalk_dm_file() {
  [ -r "$2" ] || { echo "agentalk_dm_file: cannot read '$2'" >&2; return 1; }
  agentalk_send "$(jq -nc --arg n "$1" --rawfile t "$2" '{to:$n, text:$t}')"
}

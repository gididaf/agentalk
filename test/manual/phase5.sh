#!/usr/bin/env bash
# Phase 5 manual QA — verifies the E2EE layer end-to-end:
#  - the initiator and joiner pages document the encryption protocol
#  - the documented node -e helpers actually round-trip an AES-256-GCM message
#    through the live bridge
#  - the bridge log never contains the plaintext
#  - wrong-key / wrong-sender / tampered-ciphertext paths all fail loudly

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

# AES-256-GCM encrypt helper — same shape as the page's recipe.
agentalk_encrypt() {
  # $1 = hex key, $2 = AAD, $3 = plaintext
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
  # $1 = hex key, $2 = AAD, $3 = base64 blob
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

# 0. bridge reachable
step "0. bridge reachable"
curl -fsS "$BRIDGE/health" >/dev/null || { bad "bridge not running at $BRIDGE"; exit 1; }
ok "bridge up"

# 1. initiator page advertises encryption protocol
step "1. initiator page documents the encryption protocol"
init=$(curl -fsS -H "$LLM_UA" "$BRIDGE/")
echo "$init" | grep -q 'AES-256-GCM'        && ok "initiator page names AES-256-GCM"        || bad "missing AES-256-GCM mention"
echo "$init" | grep -q '#k='                && ok "initiator page shows #k= URL fragment"   || bad "missing #k= fragment"
# The crypto recipe and the invite wording used to be inline on this page.
# Both moved: encryption into helpers.sh, the invite into the bridge-rendered
# share_message. Asserted below in 1b/1c, where they now actually ship.
echo "$init" | grep -qi 'do not rewrite'    && ok "initiator page forbids rewriting the tuned share message" \
                                            || bad "initiator page no longer protects the share message from rewriting"
echo "$init" | grep -Eq 'prompt-injection|browser link' && ok "initiator handoff explains the tightrope (injection vs browser vs follow-it)" \
                                              || bad "initiator handoff doesn't explain the failure modes"

# 2. joiner page advertises the same
step "2. joiner page documents the encryption protocol"
CREATE=$(curl -fsS -X POST "$BRIDGE/channels")
CHANNEL_ID=$(echo "$CREATE" | jq -r '.channel_id')
TOKEN=$(echo "$CREATE" | jq -r '.token')
join=$(curl -fsS "$BRIDGE/c/$CHANNEL_ID")
echo "$join" | grep -q 'AES-256-GCM'        && ok "joiner page names AES-256-GCM"        || bad "missing AES-256-GCM mention"
echo "$join" | grep -q '#k='                && ok "joiner page references #k= fragment"  || bad "missing #k= fragment"
echo "$join" | grep -qi 'extract'           && ok "joiner page tells you to extract the key from the URL" || bad "missing URL extraction instruction"

# 3. real round trip through the bridge
# 1b. The handoff phrasing is the single most failure-prone string in the whole
# project (3 known refusal modes). It is rendered server-side into
# share_message, so that is what has to be guarded — not the page prose.
step "1b. share_message carries the proven handoff phrasing"
SHARE=$(curl -fsS -X POST "$BRIDGE/channels" | jq -r '.share_message')
printf '%s' "$SHARE" | grep -qF 'Talk to my other Claude' \
  && ok "share_message uses the user-voiced invite" || bad "share_message lost 'Talk to my other Claude'"
printf '%s' "$SHARE" | grep -qF 'curl this URL to start' \
  && ok "share_message uses the proven 'curl this URL to start' template" || bad "share_message lost 'curl this URL to start'"
printf '%s' "$SHARE" | grep -Eq 'prompt-injection|browser link' \
  && ok "share_message explains why the wording matters" || bad "share_message no longer explains the tightrope"

# 1c. Claude writes no crypto and no poll loop any more; both are served.
step "1c. crypto + self-filter live in the served scripts"
helpersh=$(curl -fsS "$BRIDGE/helpers.sh")
loopsh=$(curl -fsS "$BRIDGE/loop.sh")
printf '%s' "$helpersh" | grep -qF 'createCipheriv'   && ok "helpers.sh encrypts via node createCipheriv"   || bad "helpers.sh lost createCipheriv"
printf '%s' "$helpersh" | grep -qF 'createDecipheriv' && ok "helpers.sh decrypts via node createDecipheriv" || bad "helpers.sh lost createDecipheriv"
printf '%s' "$loopsh"   | grep -qF 'select(.from != $me)' \
  && ok "loop.sh self-filters your own messages" || bad "loop.sh lost the self-filter"

step "3. real encrypt-send-poll-decrypt round trip through the bridge"
CHANNEL_KEY=$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')

ALICE=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n alice '{token:$t, name:$n}')")
ALICE_PID=$(echo "$ALICE" | jq -r '.participant_id')

BOB=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n bob '{token:$t, name:$n}')")
BOB_PID=$(echo "$BOB" | jq -r '.participant_id')

SECRET="canary-plaintext-$(date +%s%N)"
BLOB=$(agentalk_encrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$SECRET")
[[ -n "$BLOB" ]] && ok "encrypt produced a non-empty base64 blob" || bad "encrypt produced nothing"

curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/send" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg p "$ALICE_PID" --arg x "$BLOB" \
        '{token:$t, participant_id:$p, text:$x}')" >/dev/null
ok "alice sent encrypted blob through bridge"

POLL=$(curl -fsS -m 10 \
  "$BRIDGE/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$BOB_PID&since=0")
RECV_BLOB=$(echo "$POLL" | jq -r '.messages[] | select(.type=="message" and .from=="alice") | .text')
[[ -n "$RECV_BLOB" ]] && ok "bob received the ciphertext via poll" || bad "bob saw no ciphertext"

[[ "$RECV_BLOB" == "$BLOB" ]] && ok "bridge stored the blob byte-for-byte" \
                              || bad "bridge mangled the blob (sent ${#BLOB} chars, got ${#RECV_BLOB})"

DEC=$(agentalk_decrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$RECV_BLOB")
[[ "$DEC" == "$SECRET" ]] && ok "bob decrypted to the original plaintext" \
                          || bad "decrypted plaintext mismatch (expected '$SECRET', got '$DEC')"

# 4. bridge log contains zero plaintext
step "4. bridge log contains zero plaintext"
if [[ -r "$BRIDGE_LOG" ]]; then
  if grep -q "$SECRET" "$BRIDGE_LOG"; then
    bad "bridge log contains plaintext '$SECRET' — encryption layer is leaking"
  else
    ok "plaintext '$SECRET' not present in bridge log"
  fi
else
  echo "    (bridge log not at $BRIDGE_LOG — skipping log scan)"
  ok "log scan skipped (log file not readable from this script)"
fi

# 5. wrong-key path fails
step "5. wrong-key decrypt is rejected"
WRONG_KEY=$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')
if agentalk_decrypt "$WRONG_KEY" "$CHANNEL_ID:alice" "$RECV_BLOB" >/dev/null 2>&1; then
  bad "wrong-key decrypt SUCCEEDED — AES-GCM authentication is broken"
else
  ok "wrong-key decrypt rejected (auth tag mismatch)"
fi

# 6. impersonation attempt fails (sender-name AAD binding works)
step "6. AAD binding: relabeled-sender decrypt is rejected"
if agentalk_decrypt "$CHANNEL_KEY" "$CHANNEL_ID:bob" "$RECV_BLOB" >/dev/null 2>&1; then
  bad "decrypt SUCCEEDED with sender relabeled bob→alice — AAD binding broken"
else
  ok "relabeled-sender decrypt rejected (AAD mismatch)"
fi

# 7. tampered ciphertext rejected
step "7. tampered ciphertext is rejected"
TAMPERED=$(echo "$RECV_BLOB" | node -e '
  let s = ""; for await (const chunk of process.stdin) s += chunk;
  const b = Buffer.from(s.trim(), "base64");
  b[Math.floor(b.length / 2)] ^= 0x01;
  process.stdout.write(b.toString("base64"));
')
if agentalk_decrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$TAMPERED" >/dev/null 2>&1; then
  bad "tampered ciphertext decrypted — auth tag check is broken"
else
  ok "tampered ciphertext rejected (auth tag check fired)"
fi

# 8. fresh nonce per message — same plaintext encrypts to different ciphertext
step "8. nonce uniqueness — same plaintext yields different ciphertext each time"
B1=$(agentalk_encrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$SECRET")
B2=$(agentalk_encrypt "$CHANNEL_KEY" "$CHANNEL_ID:alice" "$SECRET")
[[ "$B1" != "$B2" ]] && ok "two encryptions of same plaintext differ (random nonce confirmed)" \
                     || bad "nonce reuse — encryption is deterministic, GCM safety is gone"

echo
echo "─────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  echo "$(green "ALL PASS") — $PASS checks"
  echo
  echo "Next: handshake + n-way protocol checks live in phase6.sh; the encryption primitive is covered here."
  echo "  Run ./test/manual/phase6.sh for the HELLO/WELCOME + DM/broadcast envelope coverage."
  exit 0
else
  echo "$(red "FAILED") — $PASS passed, $FAIL failed"
  exit 1
fi

#!/usr/bin/env bash
# Phase 10 manual QA — browser routing at /c/:id, and the human share message.
#
# The bug this exists to prevent: /c/:id now serves THREE different bodies off
# one path (WebFetch stub / joiner SDK markdown / browser chat HTML). The
# canonical joiner path — a Claude curling the pasted URL — must be completely
# untouched by that. curl's default UA (`curl/8.x`) matches neither LLM_UA nor
# SEARCH_BOT_UA, so a naive "LLM UA gets markdown, everyone else gets HTML"
# sniff (which is what `/` does) would hand the chat page to every curling
# Claude and silently break joining. Hence the inverted rule: default markdown,
# browsers opt in via `Accept: text/html`.
#
# Checks:
#  - the full UA/Accept matrix at /c/:id, including three real browser UAs
#  - `vary` names both User-Agent and Accept on EVERY branch (a CDN without it
#    would hand one client another's body)
#  - the HTML branch is no-store and never `public` — it embeds ?token=
#  - the tuned agent share_message did not gain or lose a single word
#  - share_message_human exists, is distinct, and carries both sentinels
#  - join returns `cursor`, so a browser can start clean instead of pulling the
#    room's backlog down onto someone else's laptop
#  - a real `npm run build` copies chat.html into dist/page/ (a forgotten entry
#    in package.json's cp list is a production 500, not a test failure)

set -u

BRIDGE="${BRIDGE:-http://localhost:3000}"

CHROME_UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
SAFARI_IOS_UA='Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1'
FIREFOX_UA='Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 Firefox/133.0'
BROWSER_ACCEPT='text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'

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

# header value for a given name, lowercased, CR stripped
hdr() { awk -v k="$1" -F': ' 'tolower($1)==k{print tolower($2)}' | tr -d '\r\n'; }
# Same, but preserving case — a base64 CSP hash is case-sensitive.
hdrRaw() { awk -v k="$1" -F': ' 'tolower($1)==k{print $2}' | tr -d '\r\n'; }

step "0. bridge reachable"
curl -fsS "$BRIDGE/health" >/dev/null || { bad "bridge not running at $BRIDGE"; exit 1; }
ok "bridge up"

step "1. create a channel"
CREATE=$(curl -fsS -X POST "$BRIDGE/channels") || { bad "POST /channels failed"; exit 1; }
CHANNEL_ID=$(printf '%s' "$CREATE" | jq -r '.channel_id')
TOKEN=$(printf '%s' "$CREATE" | jq -r '.token')
[ -n "$CHANNEL_ID" ] && [ -n "$TOKEN" ] && ok "channel $CHANNEL_ID" || { bad "no channel"; exit 1; }
JOIN_PATH="/c/$CHANNEL_ID?token=$TOKEN"

# ---------------------------------------------------------------------------
step "2. content-type matrix at /c/:id"

ct=$(curl -sI "$BRIDGE$JOIN_PATH" | hdr content-type)
[[ "$ct" == text/markdown* ]] \
  && ok "bare curl → markdown (the canonical joiner path)" \
  || bad "bare curl expected markdown, got '$ct'"

ct=$(curl -sI -H 'User-Agent: Claude-User' "$BRIDGE$JOIN_PATH" | hdr content-type)
[[ "$ct" == text/markdown* ]] \
  && ok "Claude-User → markdown (WebFetch stub)" \
  || bad "Claude-User expected markdown, got '$ct'"

body=$(curl -sS -H 'User-Agent: Claude-User' "$BRIDGE$JOIN_PATH")
printf '%s' "$body" | grep -qi 'curl' \
  && ok "WebFetch stub still says to use curl" \
  || bad "WebFetch stub no longer mentions curl"

ct=$(curl -sI -H 'User-Agent: python-requests/2.32.3' "$BRIDGE$JOIN_PATH" | hdr content-type)
[[ "$ct" == text/markdown* ]] \
  && ok "unknown non-browser UA → markdown" \
  || bad "python-requests expected markdown, got '$ct'"

ct=$(curl -sI -H 'User-Agent;' "$BRIDGE$JOIN_PATH" | hdr content-type)
[[ "$ct" == text/markdown* ]] \
  && ok "empty UA → markdown" \
  || bad "empty UA expected markdown, got '$ct'"

# An LLM UA that also sends a browser Accept must STILL get markdown — this is
# the assertion that would catch someone "simplifying" the rule to Accept-only.
ct=$(curl -sI -H 'User-Agent: claude-cli/1.0' -H "Accept: $BROWSER_ACCEPT" "$BRIDGE$JOIN_PATH" | hdr content-type)
[[ "$ct" == text/markdown* ]] \
  && ok "LLM UA + text/html Accept → markdown (LLM check wins)" \
  || bad "claude-cli with browser Accept expected markdown, got '$ct'"

for pair in "chrome:$CHROME_UA" "safari-ios:$SAFARI_IOS_UA" "firefox:$FIREFOX_UA"; do
  label="${pair%%:*}"; ua="${pair#*:}"
  ct=$(curl -sI -H "User-Agent: $ua" -H "Accept: $BROWSER_ACCEPT" "$BRIDGE$JOIN_PATH" | hdr content-type)
  [[ "$ct" == text/html* ]] \
    && ok "$label → text/html (chat UI)" \
    || bad "$label expected text/html, got '$ct'"
done

# ---------------------------------------------------------------------------
step "3. no accidental second markdown branch"
a=$(curl -sS "$BRIDGE$JOIN_PATH")
b=$(curl -sS -H 'User-Agent: python-requests/2.32.3' "$BRIDGE$JOIN_PATH")
[ "$a" = "$b" ] \
  && ok "bare curl and python-requests get byte-identical markdown" \
  || bad "markdown body differs between two non-browser UAs"

# ---------------------------------------------------------------------------
step "4. vary + cache headers"

check_vary() {
  local label="$1"; shift
  local v
  v=$(curl -sI "$@" "$BRIDGE$JOIN_PATH" | hdr vary)
  if [[ "$v" == *user-agent* && "$v" == *accept* ]]; then
    ok "$label branch: vary names User-Agent and Accept"
  else
    bad "$label branch: vary is '$v' (need both User-Agent and Accept)"
  fi
}
check_vary "bare"
check_vary "webfetch" -H 'User-Agent: Claude-User'
check_vary "browser"  -H "User-Agent: $CHROME_UA" -H "Accept: $BROWSER_ACCEPT"

cc=$(curl -sI -H "User-Agent: $CHROME_UA" -H "Accept: $BROWSER_ACCEPT" "$BRIDGE$JOIN_PATH" | hdr cache-control)
[[ "$cc" == *no-store* && "$cc" != *public* ]] \
  && ok "chat page is no-store and not public (it embeds ?token=)" \
  || bad "chat page cache-control is '$cc'"

rp=$(curl -sI -H "User-Agent: $CHROME_UA" -H "Accept: $BROWSER_ACCEPT" "$BRIDGE$JOIN_PATH" | hdr referrer-policy)
[[ "$rp" == *no-referrer* ]] \
  && ok "referrer-policy: no-referrer (?token= must not leak via Referer)" \
  || bad "referrer-policy is '$rp'"

csp=$(curl -sI -H "User-Agent: $CHROME_UA" -H "Accept: $BROWSER_ACCEPT" "$BRIDGE$JOIN_PATH" | hdrRaw content-security-policy)
# HASH, not nonce, and the difference is load-bearing. Cloudflare's automatic
# Web Analytics injection reads the response's CSP nonce and copies it onto the
# <script> it injects — so a nonce-based script-src ends up authorising a
# third-party script inside the one page that holds decrypted messages and can
# read the E2E key out of location.hash. Observed live on agentalk.dev
# 2026-08-16. A hash cannot be copied, and an injected external script has no
# hash at all.
[[ "$csp" == *"sha256-"* ]] \
  && ok "CSP pins the inline script by hash" \
  || bad "CSP has no sha256- hash: '$csp'"
[[ "$csp" != *"nonce-"* ]] \
  && ok "CSP uses no nonce (an intermediary can copy one)" \
  || bad "CSP still uses a nonce: '$csp'"
[[ "$csp" != *"unsafe-inline"* ]] \
  && ok "CSP has no unsafe-inline" \
  || bad "CSP allows unsafe-inline: '$csp'"
[[ "$csp" == *"default-src 'none'"* ]] \
  && ok "CSP defaults to none" \
  || bad "CSP does not default to none: '$csp'"

# The hash must match the bytes actually served, or the page silently will not run.
curl -sS -H "User-Agent: $CHROME_UA" -H "Accept: $BROWSER_ACCEPT" "$BRIDGE$JOIN_PATH" > /tmp/agentalk-p10-page.html
REALHASH=$(node -e '
  const fs=require("fs"),c=require("crypto");
  const h=fs.readFileSync("/tmp/agentalk-p10-page.html","utf8");
  const m=/<script>([\s\S]*?)<\/script>/.exec(h);
  process.stdout.write(m ? "sha256-"+c.createHash("sha256").update(m[1],"utf8").digest("base64") : "NOSCRIPT");')
[[ "$csp" == *"$REALHASH"* ]] \
  && ok "the CSP hash matches the script actually served" \
  || bad "CSP hash does not match served script ($REALHASH)"

grep -q 'nonce=' /tmp/agentalk-p10-page.html \
  && bad "the served page still carries a nonce attribute" \
  || ok "no nonce attributes in the page"

# ---------------------------------------------------------------------------
step "5. malformed link with a browser UA"
code=$(curl -s -o /dev/null -w '%{'"http_code"'}' \
  -H "User-Agent: $CHROME_UA" -H "Accept: $BROWSER_ACCEPT" \
  "$BRIDGE/c/not-hex-at-all?token=$TOKEN")
[ "$code" = "400" ] \
  && ok "non-hex channel id → 400" \
  || bad "non-hex channel id returned $code, expected 400"

code=$(curl -s -o /dev/null -w '%{'"http_code"'}' \
  -H "User-Agent: $CHROME_UA" -H "Accept: $BROWSER_ACCEPT" \
  "$BRIDGE/c/$CHANNEL_ID?token=../../etc/passwd")
[ "$code" = "400" ] \
  && ok "non-hex token → 400" \
  || bad "non-hex token returned $code, expected 400"

body=$(curl -sS -H "User-Agent: $CHROME_UA" -H "Accept: $BROWSER_ACCEPT" "$BRIDGE/c/nothex?token=$TOKEN")
printf '%s' "$body" | grep -qi "link" \
  && ok "400 body is a readable error page, not a stack trace" \
  || bad "400 body does not look like the error page"

# ---------------------------------------------------------------------------
step "6. the tuned agent share_message is untouched"
SM=$(printf '%s' "$CREATE" | jq -r '.share_message')
for phrase in "Talk to my other Claude" "curl this URL to start" "prompt-injection"; do
  printf '%s' "$SM" | grep -qF "$phrase" \
    && ok "share_message still contains: $phrase" \
    || bad "share_message LOST tuned phrase: $phrase"
done
# Note: "browser" legitimately appears in the tuned text ("rather than a browser
# link"), so a keyword blocklist is the wrong tool here. Pin the whole string
# instead, with the per-channel URL normalised out.
#
# Every word of this message was tuned in real-Claude QA against receiving
# Claudes' prompt-injection filters; rewriting it has made peers refuse to join.
# If you are changing it ON PURPOSE, re-run the two-terminal handoff test with a
# real Claude on the receiving end, then update this hash.
SM_EXPECTED_SHA=1dcb7f8fdadce09e296e41a994f5744598b63f1d658b2c0e58210295ce3e6ace
SM_SHA=$(printf '%s' "$SM" \
  | sed -E 's|https?://[^ ]*/c/[a-f0-9]+\?token=[a-f0-9]+#k=__KEY__|<URL>|' \
  | shasum -a 256 | cut -d' ' -f1)
[ "$SM_SHA" = "$SM_EXPECTED_SHA" ] \
  && ok "share_message is byte-for-byte the tuned text" \
  || bad "share_message CHANGED (sha $SM_SHA) — see the comment above before updating the hash"

for phrase in "__TOPIC__" "Tap here" "nothing to install"; do
  printf '%s' "$SM" | grep -qF "$phrase" \
    && bad "share_message GAINED human-invite wording: $phrase" \
    || ok "share_message free of human wording: $phrase"
done

step "7. share_message_human"
SMH=$(printf '%s' "$CREATE" | jq -r '.share_message_human // empty')
[ -n "$SMH" ] && ok "share_message_human present" || { bad "share_message_human missing"; }
[ "$SMH" != "$SM" ] && ok "distinct from share_message" || bad "identical to share_message"

k=$(printf '%s' "$SMH" | grep -c '__KEY__')
[ "$k" = "1" ] && ok "__KEY__ sentinel appears exactly once" || bad "__KEY__ appears $k times"
t=$(printf '%s' "$SMH" | grep -c '__TOPIC__')
[ "$t" = "1" ] && ok "__TOPIC__ sentinel appears exactly once" || bad "__TOPIC__ appears $t times"

printf '%s' "$SMH" | grep -q 'curl' \
  && bad "human message mentions curl" \
  || ok "human message never mentions curl"

# Braces are reserved by Claude Code's Bash tool for placeholder substitution.
printf '%s' "$SMH" | grep -q '[{}]' \
  && bad "human message contains braces (collides with Bash placeholders)" \
  || ok "human message uses no braces"

url_a=$(printf '%s' "$SM"  | grep -o "$BRIDGE/c/[^ ]*" | head -1)
url_b=$(printf '%s' "$SMH" | grep -o "$BRIDGE/c/[^ ]*" | head -1)
[ -n "$url_a" ] && [ "$url_a" = "$url_b" ] \
  && ok "both messages carry the identical join URL" \
  || bad "join URLs differ: '$url_a' vs '$url_b'"

# ---------------------------------------------------------------------------
step "8. join returns a cursor (clean-slate for browser joiners)"
for i in 1 2 3; do
  curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg t "$TOKEN" --arg n "seed$i" '{token:$t, name:$n}')" >/dev/null
done
J=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n "late" '{token:$t, name:$n}')")
CUR=$(printf '%s' "$J" | jq -r '.cursor // "missing"')
[ "$CUR" != "missing" ] && ok "join response includes cursor" || bad "join response has no cursor"

# 3 seed joins + this one = 4 join messages; our own is already appended.
[ "$CUR" = "4" ] \
  && ok "cursor equals the message count at join time ($CUR)" \
  || bad "cursor is $CUR, expected 4"

P=$(printf '%s' "$J" | jq -r '.participant_id')
POLL=$(curl -fsS "$BRIDGE/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$P&since=$CUR&")
N=$(printf '%s' "$POLL" | jq -r '.messages | length')
[ "$N" = "0" ] \
  && ok "polling from that cursor returns no backlog" \
  || bad "polling from cursor returned $N backlog messages"

# ---------------------------------------------------------------------------
step "9. the joiner bootstrap survives a personalised link"
# A link minted for a PERSON ends in "#k=<hex>&n=Dana&t=...". If someone pastes
# that into a Claude instead, a naive fragment extraction hands the bootstrap
# "<hex>&n=Dana" as the key. Encryption would then succeed locally and every
# message would arrive at the peer as an undecryptable blob — the worst kind of
# failure, because both sides look healthy.
BS=$(curl -fsS "$BRIDGE/c/$CHANNEL_ID/bootstrap.sh?token=$TOKEN")
GOODKEY=$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')

out=$( (AGENTALK_KEY="$GOODKEY&n=Dana" . <(printf '%s' "$BS") ) 2>&1 )
printf '%s' "$out" | grep -q 'READY joiner' \
  && ok "key with a trailing &n= is trimmed and the join succeeds" \
  || bad "personalised-link key was rejected: $(printf '%s' "$out" | head -2)"

out=$( (AGENTALK_KEY="nothex$GOODKEY" . <(printf '%s' "$BS") ) 2>&1 )
printf '%s' "$out" | grep -qi 'not hex\|64 hex' \
  && ok "a non-hex key fails loudly instead of silently mis-encrypting" \
  || bad "non-hex key was accepted"

out=$( (AGENTALK_KEY="${GOODKEY:0:40}" . <(printf '%s' "$BS") ) 2>&1 )
printf '%s' "$out" | grep -q '64 hex' \
  && ok "a truncated key names the real problem" \
  || bad "truncated key did not report a length error"

step "10. build copies the chat templates into dist/page/"
if [ -f dist/page/chat.html ] && [ -f dist/page/chat-error.html ]; then
  ok "dist/page/chat.html and chat-error.html exist"
else
  bad "chat templates missing from dist/page/ — check the cp list in package.json's build script"
fi

echo
echo "$(green "PASS: $PASS")   $( [ "$FAIL" -gt 0 ] && red "FAIL: $FAIL" || echo "FAIL: 0")"
echo
echo "Not covered here (needs a real browser / real Claude):"
echo "  - whether Cloudflare honours vary: User-Agent in production"
echo "  - whether a real phone browser renders the page"
echo "  - whether share_message_human reads as friendly rather than as phishing"
[ "$FAIL" -eq 0 ] || exit 1

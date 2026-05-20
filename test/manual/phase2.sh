#!/usr/bin/env bash
# Phase 2 manual QA — verifies the LLM-first page is served, substitutes BRIDGE_URL,
# and that its own Bash snippets actually work when run verbatim.
# The "a real Claude reads it and acts" criterion you'll test by hand in Claude Code.

set -u

BRIDGE="${BRIDGE:-http://localhost:3000}"
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

# 0. bridge reachable
step "0. bridge reachable"
curl -fsS "$BRIDGE/health" >/dev/null || { bad "bridge not running at $BRIDGE"; exit 1; }
ok "bridge up"

# 1. / serves markdown
step "1. GET / serves text/markdown"
ct=$(curl -sI "$BRIDGE/" | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}' | tr -d '\r\n')
echo "    content-type: $ct"
[[ "$ct" == text/markdown* ]] && ok "content-type is markdown" || bad "expected text/markdown, got '$ct'"

# 2. /llms.txt serves the same content
step "2. /llms.txt mirrors /"
md1=$(curl -fsS "$BRIDGE/"          | md5)
md2=$(curl -fsS "$BRIDGE/llms.txt"  | md5)
[[ "$md1" == "$md2" ]] && ok "/ and /llms.txt identical" || bad "/ and /llms.txt differ"

# 3. no unresolved {{KEY}} template variables in the body
# (Only flag {{UPPERCASE_KEY}} shapes — legitimate prose may reference {{name}} as
# a literal example of placeholders to avoid in Bash commands.)
step "3. no unresolved {{KEY}} template variables"
unresolved=$(curl -fsS "$BRIDGE/" | grep -Eo '\{\{[A-Z_]+\}\}' | wc -l | tr -d ' ')
unresolved=${unresolved:-0}
[[ "$unresolved" -eq 0 ]] && ok "0 unresolved template variables" || bad "$unresolved unresolved template variable(s) found"

# 4. BRIDGE_URL substituted to the real host
step "4. real bridge URL substituted into body"
count=$(curl -fsS "$BRIDGE/" | grep -c "$BRIDGE")
[[ "$count" -gt 0 ]] && ok "found $count references to '$BRIDGE'" || bad "page does not reference '$BRIDGE'"

# 5. run the page's snippets verbatim
step "5. page's Bash snippets work end-to-end"
BRIDGE_URL="$BRIDGE"
CREATE=$(curl -fsS -X POST "$BRIDGE_URL/channels")
CHANNEL_ID=$(echo "$CREATE" | jq -r '.channel_id')
TOKEN=$(echo "$CREATE" | jq -r '.token')
[[ -n "$CHANNEL_ID" && "$CHANNEL_ID" != "null" ]] && ok "channel created: $CHANNEL_ID" || bad "channel create failed"

JOIN=$(curl -fsS -X POST "$BRIDGE_URL/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "{\"token\":\"$TOKEN\",\"name\":\"laptop\"}")
participant_id=$(echo "$JOIN" | jq -r '.participant_id')
[[ -n "$participant_id" && "$participant_id" != "null" ]] && ok "initiator joined as 'laptop'" || bad "join failed"

# 6. constructed join URL is well-formed
step "6. constructed join URL is well-formed"
JOIN_URL="$BRIDGE_URL/c/$CHANNEL_ID?token=$TOKEN"
echo "    $JOIN_URL"
parsed=$(node -e "try{const u=new URL(process.argv[1]); if(u.pathname.startsWith('/c/')&&u.searchParams.get('token')&&u.searchParams.get('token').length>=24){console.log('ok')}else{console.log('bad')}}catch(e){console.log('bad')}" "$JOIN_URL")
[[ "$parsed" == "ok" ]] && ok "URL parses and has /c/<id>?token=<long>" || bad "URL malformed"

# 7. 404 catch-all teaches Claude what to do (Fix A — POST /, GET /chat, etc.)
step "7. wrong-method / wrong-path 404 hints at the SDK"
hint_post=$(curl -s -X POST "$BRIDGE_URL/" -o /dev/stdout -w "" || true)
echo "$hint_post" | grep -q 'SDK page' && ok "POST / returns body that mentions 'SDK page'" \
                                       || bad "POST / 404 body doesn't mention 'SDK page'"
echo "$hint_post" | grep -q "GET .*/" && ok "POST / 404 body recommends GET / (or /llms.txt)" \
                                      || bad "POST / 404 body doesn't recommend a GET path"
echo "$hint_post" | grep -q 'llms.txt' && ok "POST / 404 body mentions /llms.txt convention" \
                                       || bad "POST / 404 body doesn't mention /llms.txt"

hint_probe=$(curl -s "$BRIDGE_URL/chat" -o /dev/stdout -w "" || true)
echo "$hint_probe" | grep -q 'SDK page' && ok "GET /chat (wrong path) also returns the SDK hint" \
                                        || bad "GET /chat 404 didn't return the hint body"

# 8. /loop.sh is served (the auto-dispatch loop the page tells Claude to curl + source)
step "8. /loop.sh is served with shell content-type"
loop_ct=$(curl -sI "$BRIDGE/loop.sh" | awk -F': ' 'tolower($1)=="content-type"{print tolower($2)}' | tr -d '\r\n')
echo "    content-type: $loop_ct"
[[ "$loop_ct" == text/plain* ]] && ok "/loop.sh content-type is text/plain" || bad "expected text/plain, got '$loop_ct'"
loop_body=$(curl -fsS "$BRIDGE/loop.sh")
echo "$loop_body" | grep -q 'agentalk: WELCOMED' && ok "/loop.sh emits 'agentalk: WELCOMED' lines" || bad "/loop.sh missing WELCOMED output"
echo "$loop_body" | grep -q 'agentalk: PAIRED'   && ok "/loop.sh emits 'agentalk: PAIRED' lines"   || bad "/loop.sh missing PAIRED output"
echo "$loop_body" | grep -q 'agentalk: BROADCAST' && ok "/loop.sh emits 'agentalk: BROADCAST' lines" || bad "/loop.sh missing BROADCAST output"

echo
echo "─────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  echo "$(green "ALL PASS") — $PASS checks"
  echo
  echo "Next: open a Claude Code session and tell it"
  echo "  \"Talk to another agent at $BRIDGE. Just say hi for now.\""
  echo "Watch it WebFetch /, run the snippets, and respond with a join URL."
  exit 0
else
  echo "$(red "FAILED") — $PASS passed, $FAIL failed"
  exit 1
fi

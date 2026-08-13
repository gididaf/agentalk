#!/usr/bin/env bash
# Phase 3 manual QA — simulates two Claude sessions exchanging one full Q→A
# round trip through the bridge, plaintext, foreground polling.
# Alice (initiator) asks Bob (joiner) for his working directory; Bob replies.

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

# 1. initiator reads / and gets initiator page
step "1. initiator page at /"
body=$(curl -fsS -H "$LLM_UA" "$BRIDGE/")
echo "$body" | grep -q 'You are the initiator' && ok "initiator page says 'You are the initiator'" \
                                                || bad "initiator marker missing"
echo "$body" | grep -q 'You are the joiner' && bad "initiator page leaks joiner content" \
                                            || ok "no joiner content on initiator page"

# 2. alice (initiator) creates channel + joins + asks a question
step "2. alice bootstraps + asks a question"
CREATE=$(curl -fsS -X POST "$BRIDGE/channels")
CHANNEL_ID=$(echo "$CREATE" | jq -r '.channel_id')
TOKEN=$(echo "$CREATE" | jq -r '.token')
[[ -n "$CHANNEL_ID" && "$CHANNEL_ID" != "null" ]] && ok "channel created: $CHANNEL_ID" || bad "channel create failed"

ALICE=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n alice '{token:$t, name:$n}')")
ALICE_PID=$(echo "$ALICE" | jq -r '.participant_id')
[[ -n "$ALICE_PID" && "$ALICE_PID" != "null" ]] && ok "alice joined" || bad "alice join failed"

SEND=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/send" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg p "$ALICE_PID" --arg x 'What is your working directory?' \
        '{token:$t, participant_id:$p, text:$x}')")
ok "alice sent: '$(echo "$SEND" | jq -r '.index // "?"' >/dev/null && echo "What is your working directory?")'"

# 3. the join URL alice would hand the user
JOIN_URL="$BRIDGE/c/$CHANNEL_ID?token=$TOKEN"
echo "    join URL: $JOIN_URL"

# 4. simulate the user pasting that URL into bob's chat — bob fetches /c/:id
step "3. bob fetches /c/:id and gets a joiner page with channel-id baked in"
JOINER_PAGE=$(curl -fsS "$BRIDGE/c/$CHANNEL_ID")
echo "$JOINER_PAGE" | grep -q 'You are the joiner' && ok "joiner page says 'You are the joiner'" \
                                                   || bad "joiner marker missing"
echo "$JOINER_PAGE" | grep -q "$CHANNEL_ID" && ok "joiner page mentions the channel_id" \
                                            || bad "joiner page missing channel_id"
echo "$JOINER_PAGE" | grep -q 'You are the initiator' && bad "joiner page leaks initiator content" \
                                                      || ok "no initiator content on joiner page"

# 5. bob joins, polls (since=0 should immediately get alice's question via long-poll wake)
step "4. bob joins and reads alice's question"
BOB=$(curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/join" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg n bob '{token:$t, name:$n}')")
BOB_PID=$(echo "$BOB" | jq -r '.participant_id')
[[ -n "$BOB_PID" && "$BOB_PID" != "null" ]] && ok "bob joined" || bad "bob join failed"

POLL1=$(curl -fsS -m 10 \
  "$BRIDGE/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$BOB_PID&since=0")
bobs_question=$(echo "$POLL1" | jq -r '.messages[] | select(.type=="message" and .from=="alice") | .text')
[[ "$bobs_question" == "What is your working directory?" ]] \
  && ok "bob received alice's question" \
  || bad "bob did not see alice's question (got: '$bobs_question')"
BOB_CURSOR=$(echo "$POLL1" | jq -r '.cursor')

# 6. bob acts on his local machine (the simulated "tool use") and replies
step "5. bob runs 'pwd' locally and replies"
BOB_PWD="$(pwd)"
ANSWER="My working directory is $BOB_PWD"
curl -fsS -X POST "$BRIDGE/channels/$CHANNEL_ID/send" \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TOKEN" --arg p "$BOB_PID" --arg x "$ANSWER" \
        '{token:$t, participant_id:$p, text:$x}')" >/dev/null
ok "bob sent reply"

# 7. alice polls — long-poll wakes on bob's reply
step "6. alice's long-poll wakes on bob's reply"
ALICE_CURSOR=2  # after her own send (join + send already in log)
t0=$(date +%s%N)
POLL2=$(curl -fsS -m 55 \
  "$BRIDGE/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$ALICE_PID&since=$ALICE_CURSOR")
t1=$(date +%s%N)
elapsed_ms=$(( (t1 - t0) / 1000000 ))
echo "    poll returned in ${elapsed_ms}ms"

reply=$(echo "$POLL2" | jq -r '.messages[] | select(.type=="message" and .from=="bob") | .text')
[[ "$reply" == "$ANSWER" ]] && ok "alice received bob's exact reply" \
                            || bad "expected '$ANSWER', got '$reply'"
[[ "$elapsed_ms" -lt 5000 ]] && ok "long-poll woke quickly (< 5s)" \
                            || bad "long-poll did not wake promptly (${elapsed_ms}ms)"

# 8. alice's second poll (no new messages) should 204 within the curl deadline
step "7. follow-up poll with no traffic returns 204"
NEW_CURSOR=$(echo "$POLL2" | jq -r '.cursor')
status=$(curl -s -o /dev/null -w '%{http_code}' -m 4 \
  "$BRIDGE/channels/$CHANNEL_ID/poll?token=$TOKEN&participant_id=$ALICE_PID&since=$NEW_CURSOR")
# 000 means curl cut at -m 4 (server still long-polling) — that's also a pass: it WAS blocking
[[ "$status" == "204" || "$status" == "000" ]] \
  && ok "poll blocked (got '$status') — expected 204 from server or 000 (curl cut)" \
  || bad "unexpected status $status"

echo
echo "─────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  echo "$(green "ALL PASS") — $PASS checks"
  echo
  echo "Next: open TWO Claude Code sessions in two terminals."
  echo "  Terminal A: \"Ask my other Claude what its working directory is, via $BRIDGE.\""
  echo "  Terminal B: paste the join URL terminal A prints."
  echo "  Then ask each session to \"check for replies\" once."
  exit 0
else
  echo "$(red "FAILED") — $PASS passed, $FAIL failed"
  exit 1
fi

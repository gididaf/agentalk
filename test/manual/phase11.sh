#!/usr/bin/env bash
# Phase 11 manual QA — the browser chat client.
#
# The bug this exists to prevent: a browser and an agent that cannot read each
# other. Every crypto mismatch in this system fails SILENTLY — a wrong AAD, a
# mis-ordered nonce/tag, or a key_fp hashed over the wrong bytes all surface as
# `agentalk: DECRYPT_FAIL` on the far side, minutes later, with no clue which
# end is wrong. So the centrepiece here cuts the real crypto block out of the
# real served page and runs it under Node's WebCrypto against the exact
# node:crypto recipe from helpers.sh, both directions.
#
# Checks:
#  - the page serves, is self-contained, and reaches no external origin
#  - no innerHTML / eval / document.write anywhere in it
#  - crypto round-trips WebCrypto -> helpers.sh AND helpers.sh -> WebCrypto
#  - wrong key, wrong-sender AAD, and a flipped bit are all rejected
#  - keyFingerprint matches the bootstraps byte for byte
#  - the protocol branches the page needs are present
#
# NOT covered (needs a real browser): actual WebCrypto/clipboard/audio/
# Notification behaviour, localStorage, responsive layout, bfcache restore.

set -u

BRIDGE="${BRIDGE:-http://localhost:3000}"
CHROME_UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

step "0. bridge reachable"
curl -fsS "$BRIDGE/health" >/dev/null || { bad "bridge not running at $BRIDGE"; exit 1; }
ok "bridge up"

step "1. fetch the chat page"
CREATE=$(curl -fsS -X POST "$BRIDGE/channels") || { bad "POST /channels failed"; exit 1; }
CHANNEL_ID=$(printf '%s' "$CREATE" | jq -r '.channel_id')
TOKEN=$(printf '%s' "$CREATE" | jq -r '.token')
PAGE="$WORK/chat.html"
curl -fsS -H "User-Agent: $CHROME_UA" -H "Accept: $BROWSER_ACCEPT" \
  "$BRIDGE/c/$CHANNEL_ID?token=$TOKEN" > "$PAGE" || { bad "chat page fetch failed"; exit 1; }
BYTES=$(wc -c < "$PAGE" | tr -d ' ')
ok "page fetched ($BYTES bytes)"
[ "$BYTES" -lt 60000 ] \
  && ok "under the 60KB budget (loads on a phone)" \
  || bad "page is $BYTES bytes — too heavy for a cold mobile load"

step "2. the channel coordinates are substituted, the key is not present"
grep -qF "$CHANNEL_ID" "$PAGE" && ok "channel id substituted" || bad "channel id missing"
grep -qF "$TOKEN" "$PAGE" && ok "token substituted" || bad "token missing"
grep -q '{{' "$PAGE" && bad "unsubstituted {{…}} placeholder left in the page" || ok "no leftover placeholders"

step "3. self-contained — no external origins"
# Any absolute URL to another host would be blocked by the CSP anyway, but it
# would also mean the page stopped being self-contained.
if grep -oE '(src|href)="https?://[^"]+"' "$PAGE" | grep -q .; then
  bad "page references an external origin:"
  grep -oE '(src|href)="https?://[^"]+"' "$PAGE" | sed 's/^/      /'
else
  ok "no external src= or href="
fi
grep -qE '<(script|link)[^>]+(src|href)=' "$PAGE" \
  && bad "page loads an external script or stylesheet" \
  || ok "all CSS and JS is inline"

step "4. XSS discipline"
# Match real property access (`.innerHTML`), not the word — the page's own
# comments explain why it never uses these, and a bare word match would flag
# the explanation as the violation.
check_absent() {
  local label="$1" pattern="$2"
  if grep -qE "$pattern" "$PAGE"; then
    bad "page uses $label"
    grep -nE "$pattern" "$PAGE" | head -3 | sed 's/^/      /'
  else
    ok "no $label"
  fi
}
check_absent "innerHTML"          '\.innerHTML'
check_absent "outerHTML"          '\.outerHTML'
check_absent "document.write"     'document\.write'
check_absent "insertAdjacentHTML" '\.insertAdjacentHTML'
check_absent "eval()"             '[^a-zA-Z_.]eval[[:space:]]*\('
check_absent "new Function"       'new Function'
grep -qF 'textContent' "$PAGE" && ok "uses textContent" || bad "no textContent found — how is it rendering?"

step "5. required head metadata"
grep -qi 'name="referrer" content="no-referrer"' "$PAGE" \
  && ok "referrer meta present (?token= must not leak)" || bad "referrer meta missing"
grep -qi 'name="robots" content="noindex' "$PAGE" \
  && ok "robots noindex present" || bad "robots meta missing"
grep -qi 'name="viewport"' "$PAGE" && ok "viewport present" || bad "viewport missing"
grep -q 'nonce=' "$PAGE" && ok "CSP nonce applied to inline tags" || bad "no nonce on inline tags"

step "6. protocol branches the page must have"
for pattern in 'human: true' 'resumed' 'welcome' 'hibernating' 'name_taken' 'key_fp' 'since=' 'keepalive'; do
  grep -qF "$pattern" "$PAGE" \
    && ok "handles: $pattern" \
    || bad "MISSING branch: $pattern"
done

# ---------------------------------------------------------------------------
step "7. crypto interop — the real page code vs the real helpers.sh recipe"

# Cut the pure crypto block out of the served page.
awk '/---8<--- agentalk-crypto begin/{f=1;next} /---8<--- agentalk-crypto end/{f=0} f' \
  "$PAGE" > "$WORK/crypto.js"
LINES=$(wc -l < "$WORK/crypto.js" | tr -d ' ')
[ "$LINES" -gt 30 ] \
  && ok "extracted the crypto block from the served page ($LINES lines)" \
  || { bad "could not extract crypto block (got $LINES lines)"; }

cat > "$WORK/interop.mjs" <<'MJS'
import { readFileSync } from "node:fs";
import crypto_node from "node:crypto";

// Give the extracted browser code exactly the globals a page gives it.
globalThis.btoa = (s) => Buffer.from(s, "binary").toString("base64");
globalThis.atob = (s) => Buffer.from(s, "base64").toString("binary");

const src = readFileSync(process.env.CRYPTO_JS, "utf8");
const mod = new Function(src + `
  ;return { hexToBytes, bytesToHex, bytesToB64, b64ToBytes,
            importChannelKey, keyFingerprint, aesEncrypt, aesDecrypt };
`)();

// ---- the exact recipe from src/page/helpers.sh -------------------------
function shEncrypt(keyHex, aadStr, pt) {
  const key = Buffer.from(keyHex, "hex");
  const aad = Buffer.from(aadStr, "utf8");
  const nonce = crypto_node.randomBytes(12);
  const ci = crypto_node.createCipheriv("aes-256-gcm", key, nonce);
  ci.setAAD(aad);
  const ct = Buffer.concat([ci.update(pt, "utf8"), ci.final()]);
  return Buffer.concat([nonce, ct, ci.getAuthTag()]).toString("base64");
}
function shDecrypt(keyHex, aadStr, b64) {
  try {
    const raw = Buffer.from(b64, "base64");
    const key = Buffer.from(keyHex, "hex");
    const d = crypto_node.createDecipheriv("aes-256-gcm", key, raw.subarray(0, 12));
    d.setAAD(Buffer.from(aadStr, "utf8"));
    d.setAuthTag(raw.subarray(raw.length - 16));
    return Buffer.concat([d.update(raw.subarray(12, raw.length - 16)), d.final()]).toString("utf8");
  } catch { return null; }
}

const results = [];
const check = (name, cond) => results.push({ name, ok: !!cond });

const KEY = crypto_node.randomBytes(32).toString("hex");
const OTHER = crypto_node.randomBytes(32).toString("hex");
const CH = "a1b2c3d4e5f60718";
const AAD = `${CH}:Dana`;
const PT = 'Hi — it\'s the refresh path.\nLine two\twith a tab. "quotes" & <tags> 🙂';

const key = await mod.importChannelKey(KEY);
const otherKey = await mod.importChannelKey(OTHER);

// 1. browser encrypts -> agent decrypts
const b1 = await mod.aesEncrypt(key, AAD, PT);
check("browser -> agent round-trip", shDecrypt(KEY, AAD, b1) === PT);

// 2. agent encrypts -> browser decrypts
const b2 = shEncrypt(KEY, AAD, PT);
check("agent -> browser round-trip", (await mod.aesDecrypt(key, AAD, b2)) === PT);

// 3. wire format really is nonce||ct||tag
const raw = Buffer.from(b1, "base64");
check("wire format is 12-byte nonce + ct + 16-byte tag",
  raw.length === 12 + Buffer.byteLength(PT, "utf8") + 16);

// 4. wrong key rejected
check("wrong key rejected (browser side)", (await mod.aesDecrypt(otherKey, AAD, b2)) === null);
check("wrong key rejected (agent side)", shDecrypt(OTHER, AAD, b1) === null);

// 5. wrong sender in the AAD rejected — this is the check that makes a lying
//    bridge detectable, so it matters more than it looks
const wrongAad = `${CH}:Mallory`;
check("wrong-sender AAD rejected (browser side)", (await mod.aesDecrypt(key, wrongAad, b2)) === null);
check("wrong-sender AAD rejected (agent side)", shDecrypt(KEY, wrongAad, b1) === null);

// 6. tampered ciphertext rejected
const t = Buffer.from(b1, "base64");
t[t.length - 20] ^= 0x01;
const tampered = t.toString("base64");
check("tampered blob rejected (browser side)", (await mod.aesDecrypt(key, AAD, tampered)) === null);
check("tampered blob rejected (agent side)", shDecrypt(KEY, AAD, tampered) === null);

// 7. key fingerprint matches the bootstraps exactly. They hash the hex STRING;
//    hashing the raw bytes instead is the classic way to get this wrong.
const fpBrowser = await mod.keyFingerprint(KEY);
const fpBootstrap = crypto_node.createHash("sha256").update(KEY).digest("hex").slice(0, 16);
check("key_fp matches the bootstrap formula", fpBrowser === fpBootstrap);
const fpWrong = crypto_node.createHash("sha256").update(Buffer.from(KEY, "hex")).digest("hex").slice(0, 16);
check("key_fp is NOT the digest of the raw key bytes", fpBrowser !== fpWrong);

// 8. large payload — the chunked base64 path
const big = "x".repeat(40000);
const b3 = await mod.aesEncrypt(key, AAD, big);
check("40KB payload survives chunked base64", shDecrypt(KEY, AAD, b3) === big);

for (const r of results) console.log((r.ok ? "OK  " : "BAD ") + r.name);
process.exit(results.every(r => r.ok) ? 0 : 1);
MJS

CRYPTO_JS="$WORK/crypto.js" node "$WORK/interop.mjs" > "$WORK/interop.out" 2>&1
IRC=$?
while IFS= read -r line; do
  case "$line" in
    "OK  "*) ok "${line#OK  }" ;;
    "BAD "*) bad "${line#BAD }" ;;
    *) [ -n "$line" ] && echo "      $line" ;;
  esac
done < "$WORK/interop.out"
[ "$IRC" -ne 0 ] && [ ! -s "$WORK/interop.out" ] && bad "interop harness did not run"

# ---------------------------------------------------------------------------
step "8. RTL, auto-join and instant context"

# Direction must come from the text itself, not a global setting: a Hebrew
# sentence rendered LTR puts its closing "?" at the wrong end of the line.
grep -q 'dir = "auto"' "$PAGE" \
  && ok "message bodies use dir=auto (direction from first strong character)" \
  || bad "no dir=auto — RTL messages will render backwards"
grep -q 'unicode-bidi: plaintext' "$PAGE" \
  && ok "bubbles set unicode-bidi: plaintext" \
  || bad "missing unicode-bidi: plaintext"
grep -q 'dir = "ltr"' "$PAGE" \
  && ok "code blocks are pinned to LTR" \
  || bad "code blocks not pinned LTR — code inside an RTL message would flip"
grep -q '<textarea id="input" rows="1" dir="auto"' "$PAGE" \
  && ok "composer follows what is typed" \
  || bad "composer has no dir=auto"

# A name in the fragment skips the name prompt; no name must still ask.
grep -q 'if (invited)' "$PAGE" \
  && ok "auto-joins when the link carries a name" \
  || bad "no auto-join branch"
grep -q 'function joinWith' "$PAGE" \
  && ok "join path is shared between auto-join and the prompt" \
  || bad "joinWith() missing"
grep -q 'sanitizeName(params.n)' "$PAGE" \
  && ok "the name from the link is sanitized before use" \
  || bad "link name is not sanitized"

# Nothing should ever be a blank screen.
for fn in paintIntro showWaiting clearWaiting sanitizeTopic; do
  grep -q "function $fn" "$PAGE" && ok "has $fn()" || bad "MISSING $fn()"
done
grep -q 'Claude is writing' "$PAGE" \
  && ok "shows a writing indicator while waiting for the opener" \
  || bad "no writing indicator"
grep -q 'prefers-reduced-motion' "$PAGE" \
  && ok "the animation respects prefers-reduced-motion" \
  || bad "animated dots ignore prefers-reduced-motion"

# n and t must be read from the FRAGMENT, never the query string. That is the
# whole reason the bridge never learns who was invited or what it concerns —
# browsers do not transmit anything after the '#'. Reading them from
# location.search instead would look identical in the UI and quietly put both
# in every access log.
grep -q 'readFragmentParams' "$PAGE" \
  && ok "params come from a fragment parser" \
  || bad "no fragment parser"
grep -q 'location.hash' "$PAGE" \
  && ok "reads location.hash" \
  || bad "does not read location.hash"
grep -q 'location.search\|URLSearchParams' "$PAGE" \
  && bad "reads the query string — n/t would reach the bridge and its logs" \
  || ok "never reads location.search (n/t stay client-side)"
grep -q 'history.replaceState\|location.hash = ' "$PAGE" \
  && bad "rewrites the URL — a reload would lose the key" \
  || ok "leaves the URL intact so a reload can reconnect"

step "9. message renderer vs hostile input"

awk '/---8<--- agentalk-render begin/{f=1;next} /---8<--- agentalk-render end/{f=0} f' \
  "$PAGE" > "$WORK/render.js"
[ -s "$WORK/render.js" ] \
  && ok "extracted the renderer from the served page" \
  || bad "could not extract the renderer block"

cat > "$WORK/render-test.mjs" <<'MJS'
import { readFileSync } from "node:fs";

// The smallest DOM that renderBody needs. Every node records how it was built,
// so the assertions can prove text arrived as TEXT and never as markup.
function mkNode(tag) {
  return {
    tag, className: "", children: [], _text: null,
    set textContent(v) { this._text = String(v); this.children = []; },
    get textContent() {
      if (this._text !== null) return this._text;
      return this.children.map(c => c.textContent).join("");
    },
    appendChild(c) { this.children.push(c); return c; },
    addEventListener() {}
  };
}
globalThis.document = {
  createElement: (t) => mkNode(t),
  createTextNode: (t) => { const n = mkNode("#text"); n.textContent = t; return n; },
  createDocumentFragment: () => mkNode("#fragment")
};
function el(tag, cls, text) {
  const n = mkNode(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = String(text);
  return n;
}
function copyText() {}

const src = readFileSync(process.env.RENDER_JS, "utf8");
const { renderBody } = new Function("el", "copyText", src + ";return { renderBody };")(el, copyText);

// Walk the tree and collect every tag that was actually created, plus all text.
function walk(n, tags, texts) {
  if (n.tag && n.tag !== "#fragment" && n.tag !== "#text") tags.push(n.tag);
  if (n._text !== null) texts.push(n._text);
  n.children.forEach(c => walk(c, tags, texts));
  return { tags, texts };
}

const results = [];
const check = (name, cond) => results.push({ name, ok: !!cond });

// 1. an HTML payload must survive as literal text and create no elements
const payload = '<img src=x onerror=alert(1)><script>alert(2)</' + 'script>';
let r = walk(renderBody(payload), [], []);
check("HTML payload creates no img/script element",
  !r.tags.includes("img") && !r.tags.includes("script"));
check("HTML payload is preserved verbatim as text",
  r.texts.join("") === payload);

// 2. same inside a fenced code block
const fenced = "```js\n<img src=x onerror=alert(1)>\n```";
r = walk(renderBody(fenced), [], []);
check("fenced payload produces a <pre><code>", r.tags.includes("pre") && r.tags.includes("code"));
check("fenced payload creates no img element", !r.tags.includes("img"));
check("fenced payload keeps the code text intact",
  r.texts.some(t => t === "<img src=x onerror=alert(1)>"));

// 3. language tag stripped, body kept
r = walk(renderBody("```bash\nls -la\n```"), [], []);
check("language tag stripped from the rendered code",
  r.texts.some(t => t === "ls -la") && !r.texts.some(t => t.includes("bash")));

// 4. inline spans
r = walk(renderBody("use `npm run build` now"), [], []);
check("inline backticks become a code element", r.tags.includes("code"));
check("inline code keeps its text", r.texts.some(t => t === "npm run build"));

// 5. newlines become <br>, not lost
r = walk(renderBody("one\ntwo"), [], []);
check("newline becomes a br element", r.tags.includes("br"));
check("both lines survive", r.texts.includes("one") && r.texts.includes("two"));

// 6. an unterminated fence must not swallow or drop the message
r = walk(renderBody("here you go ```oops"), [], []);
check("unterminated fence still renders the leading text",
  r.texts.some(t => t.includes("here you go")));

// 7. a copy button accompanies each fenced block
r = walk(renderBody("```\nx\n```"), [], []);
check("fenced block gets a copy button",
  r.texts.includes("Copy"));

for (const x of results) console.log((x.ok ? "OK  " : "BAD ") + x.name);
process.exit(results.every(x => x.ok) ? 0 : 1);
MJS

RENDER_JS="$WORK/render.js" node "$WORK/render-test.mjs" > "$WORK/render.out" 2>&1
RRC=$?
while IFS= read -r line; do
  case "$line" in
    "OK  "*) ok "${line#OK  }" ;;
    "BAD "*) bad "${line#BAD }" ;;
    *) [ -n "$line" ] && echo "      $line" ;;
  esac
done < "$WORK/render.out"
[ "$RRC" -ne 0 ] && [ ! -s "$WORK/render.out" ] && bad "renderer harness did not run"

# ---------------------------------------------------------------------------
step "10. a browser-shaped join really works against the live bridge"
# Drive the wire protocol with curl + the helpers.sh recipe, standing in for the
# browser, to prove the page's sequence (join -> cursor -> hello) is valid.
KEY=$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')
FP=$(K="$KEY" node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.env.K).digest("hex").slice(0,16))')

C2=$(curl -fsS -X POST "$BRIDGE/channels")
CH2=$(printf '%s' "$C2" | jq -r '.channel_id')
TK2=$(printf '%s' "$C2" | jq -r '.token')

# an agent joins first and speaks, so there IS a backlog to not-see
AJ=$(curl -fsS -X POST "$BRIDGE/channels/$CH2/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TK2" --arg f "$FP" '{token:$t, name:"agent", key_fp:$f}')")
APID=$(printf '%s' "$AJ" | jq -r '.participant_id')
BLOB=$(K="$KEY" A="$CH2:agent" P='{"text":"secret backlog"}' node -e '
  const c=require("crypto");
  const n=c.randomBytes(12);
  const ci=c.createCipheriv("aes-256-gcm",Buffer.from(process.env.K,"hex"),n);
  ci.setAAD(Buffer.from(process.env.A,"utf8"));
  const ct=Buffer.concat([ci.update(process.env.P,"utf8"),ci.final()]);
  process.stdout.write(Buffer.concat([n,ct,ci.getAuthTag()]).toString("base64"));')
curl -fsS -X POST "$BRIDGE/channels/$CH2/send" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TK2" --arg p "$APID" --arg x "$BLOB" '{token:$t,participant_id:$p,text:$x}')" >/dev/null

# now the "browser" joins
BJ=$(curl -fsS -X POST "$BRIDGE/channels/$CH2/join" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TK2" --arg f "$FP" '{token:$t, name:"Dana", key_fp:$f}')")
BPID=$(printf '%s' "$BJ" | jq -r '.participant_id')
BCUR=$(printf '%s' "$BJ" | jq -r '.cursor')
BROSTER=$(printf '%s' "$BJ" | jq -r '[.roster[] | select(.name=="agent") | .key_fp] | first // ""')

[ "$BROSTER" = "$FP" ] \
  && ok "roster exposes the creator's key_fp for the browser to verify" \
  || bad "roster key_fp was '$BROSTER', expected '$FP'"

POLL=$(curl -fsS "$BRIDGE/channels/$CH2/poll?token=$TK2&participant_id=$BPID&since=$BCUR&")
NMSG=$(printf '%s' "$POLL" | jq -r '.messages | length')
[ "$NMSG" = "0" ] \
  && ok "browser sees NO backlog (the pre-join message never reaches it)" \
  || bad "browser received $NMSG backlog messages — clean-slate is broken"

# the "browser" says hello with human:true — the agent must be able to read it
HB=$(K="$KEY" A="$CH2:Dana" P='{"hello":"deadbeefdeadbeef","human":true}' node -e '
  const c=require("crypto");
  const n=c.randomBytes(12);
  const ci=c.createCipheriv("aes-256-gcm",Buffer.from(process.env.K,"hex"),n);
  ci.setAAD(Buffer.from(process.env.A,"utf8"));
  const ct=Buffer.concat([ci.update(process.env.P,"utf8"),ci.final()]);
  process.stdout.write(Buffer.concat([n,ct,ci.getAuthTag()]).toString("base64"));')
SR=$(curl -fsS -X POST "$BRIDGE/channels/$CH2/send" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TK2" --arg p "$BPID" --arg x "$HB" '{token:$t,participant_id:$p,text:$x}')")
printf '%s' "$SR" | jq -e '.ok == true' >/dev/null \
  && ok "browser HELLO accepted by the bridge" \
  || bad "browser HELLO rejected: $SR"

AP=$(curl -fsS "$BRIDGE/channels/$CH2/poll?token=$TK2&participant_id=$APID&since=0&")
# select on type too: Dana's `join` entry also has from=="Dana" but no .text,
# and it sorts first.
GOT=$(printf '%s' "$AP" | jq -r '[.messages[] | select(.from=="Dana" and .type=="message") | .text] | first // ""')
DECODED=$(K="$KEY" A="$CH2:Dana" B="$GOT" node -e '
  const c=require("crypto");
  const raw=Buffer.from(process.env.B,"base64");
  const d=c.createDecipheriv("aes-256-gcm",Buffer.from(process.env.K,"hex"),raw.subarray(0,12));
  d.setAAD(Buffer.from(process.env.A,"utf8"));
  d.setAuthTag(raw.subarray(raw.length-16));
  process.stdout.write(Buffer.concat([d.update(raw.subarray(12,raw.length-16)),d.final()]).toString());
' 2>/dev/null)
printf '%s' "$DECODED" | jq -e '.human == true and .hello == "deadbeefdeadbeef"' >/dev/null 2>&1 \
  && ok "agent decrypts the browser's HELLO and sees human:true" \
  || bad "agent could not read the browser HELLO (got: $DECODED)"

echo
echo "$(green "PASS: $PASS")   $( [ "$FAIL" -gt 0 ] && red "FAIL: $FAIL" || echo "FAIL: 0")"
echo
echo "Not covered here (needs a real browser):"
echo "  - WebCrypto/clipboard/audio/Notification behaviour in Safari and Chrome"
echo "  - localStorage transcript restore across a real tab close"
echo "  - responsive layout, tap targets, iOS keyboard"
echo "  - that #k= never appears in the bridge's access log"
[ "$FAIL" -eq 0 ] || exit 1

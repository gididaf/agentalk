import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));

function load(name: string): string {
  return readFileSync(join(here, name), "utf8");
}

function fill(template: string, vars: Record<string, string>): string {
  let out = template;
  for (const [k, v] of Object.entries(vars)) {
    out = out.replaceAll(`{{${k}}}`, v);
  }
  return out;
}

const HEX_RE = /^[a-f0-9]+$/i;

export function renderInitiator(bridgeUrl: string): string {
  return fill(load("initiator.md"), {
    BRIDGE_URL: bridgeUrl,
    PROTOCOL_REFERENCE: load("protocol.md"),
  });
}

export function renderJoiner(bridgeUrl: string, channelId: string, token: string): string {
  // Token is hex-validated by the caller before reaching here; an invalid
  // token is rendered as the literal string `<token-from-pasted-URL>` so the
  // page still reads cleanly when curled without ?token=. The bootstrap
  // command on the page will not work in that case; Claude will see the
  // placeholder and ask the user to re-paste.
  const tokenSlot = HEX_RE.test(token) ? token : "<token-from-pasted-URL>";
  return fill(load("joiner.md"), {
    BRIDGE_URL: bridgeUrl,
    CHANNEL_ID: channelId,
    TOKEN: tokenSlot,
    PROTOCOL_REFERENCE: load("protocol.md"),
  });
}

// Served to WebFetch User-Agents hitting /c/:id. The full SDK page is ~150
// lines and WebFetch summarizes it — past QA caught a Claude losing the
// substituted bootstrap command in the summary, then having to recover by
// curl-ing the page anyway. This stub short-circuits that: serve only a
// "use curl" redirect so WebFetch returns ~10 lines that can't be summarized
// into the wrong action. The full SDK remains available to curl, since
// curl's default User-Agent does not match the WebFetch pattern.
export function renderJoinerWebFetchStub(
  bridgeUrl: string,
  channelId: string,
  token: string,
): string {
  const idSlot = HEX_RE.test(channelId) ? channelId : "<channel-id>";
  const tokenSlot = HEX_RE.test(token) ? token : "<token>";
  return `# agentalk joiner — switch to curl

You fetched this page with **WebFetch**, which summarizes content and may silently drop the bootstrap command you need. The agentalk SDK is shell-script-heavy; summaries lose it.

**Do this instead, in a single Bash call:**

\`\`\`
curl -fsS '${bridgeUrl}/c/${idSlot}?token=${tokenSlot}' -o /tmp/agentalk-sdk.md
\`\`\`

Then \`Read\` the file at \`/tmp/agentalk-sdk.md\`. The full SDK is ~150 lines of step-by-step instructions for joining channel \`${idSlot}\` as a peer.

(There is no shortcut — even reading this stub doesn't give you the bootstrap command, because it is per-channel and the SDK page has the substitution baked in. Run the curl above.)
`;
}

export function renderLoopScript(): string {
  return load("loop.sh");
}

// The /agentalk skill body, served verbatim to the installer (which writes it
// to ~/.claude/skills/agentalk/SKILL.md) and to humans who want to inspect it
// before trusting the one-liner. No substitution — it references agentalk.dev
// directly and is bridge-host-agnostic beyond that.
export function renderSkill(): string {
  return load("skill.md");
}

// The `curl -fsSL <bridge>/skill.sh | sh` installer. Only substitution is the
// bridge URL it fetches skill.md from, so a self-hosted instance installs its
// own skill copy rather than agentalk.dev's.
export function renderSkillInstall(bridgeUrl: string): string {
  return fill(load("skill-install.sh.tpl"), {
    BRIDGE_URL: bridgeUrl,
  });
}

export function renderHelpersScript(): string {
  return load("helpers.sh");
}

// The human-facing site is built by Astro from `site/` (see site/src/pages/).
// In dev (tsx running src/) `here` is `src/page/`, so the build output sits at
// `../../site/dist/`. In production (compiled JS) `here` is `dist/page/`,
// and the build script copies the Astro output into `dist/site/`, i.e. `../site/`.
// LLM UAs continue to receive the markdown SDK from initiator.md; only browsers and
// search bots hit these static-asset code paths.
const SITE_DIST_CANDIDATES = [
  join(here, "..", "..", "site", "dist"),
  join(here, "..", "site"),
];

export function renderLanding(): string {
  return loadSiteAsset("index.html").toString("utf8");
}

export function loadSiteAsset(relPath: string): Buffer {
  for (const root of SITE_DIST_CANDIDATES) {
    try {
      return readFileSync(join(root, relPath));
    } catch {
      // try next
    }
  }
  throw new Error(
    `agentalk static site asset '${relPath}' not built. Run \`npm --prefix site run build\` (dev) or \`npm run build\` (full).`,
  );
}

export function renderInitiatorBootstrap(bridgeUrl: string): string {
  return fill(load("bootstrap-initiator.sh.tpl"), {
    BRIDGE_URL: bridgeUrl,
  });
}

// The browser chat client, served at /c/:id to User-Agents that ask for HTML.
//
// Returns null if channelId or token are not hex — caller should 400. Same
// reasoning as the bootstrap below, one layer over: these are interpolated
// literally into a script body, and here that body is JavaScript in an HTML
// document, so non-hex would be script injection.
//
// Deliberately takes NO bridge URL. bridgeBase() is derived from the
// client-controlled Host / X-Forwarded-Proto headers; that is harmless inside
// markdown but is a reflected-XSS primitive inside HTML. The page is served
// same-origin by this very bridge, so it uses relative URLs and the whole
// class of bug disappears.
export function renderChat(channelId: string, token: string): string | null {
  if (!HEX_RE.test(channelId) || !HEX_RE.test(token)) return null;
  return fill(load("chat.html"), {
    CHANNEL_ID: channelId,
    TOKEN: token,
  });
}

// SHA-256 of the page's inline <script> and <style> bodies, for a hash-based CSP.
//
// A nonce would be the obvious choice and is the wrong one here: Cloudflare's
// automatic Web Analytics injection reads the nonce out of the response and
// copies it onto the <script> tag it inserts, so a nonce-based script-src ends
// up authorising exactly the third-party script we need to keep out of a page
// holding decrypted messages and the E2E key. A hash cannot be copied — an
// injected external script has no hash at all, so it simply does not run.
//
// This is why the config lives on <body data-…> instead of being substituted
// into the script: the script body must be byte-identical every request for a
// fixed hash to hold. Computed once, at first use.
let chatCspHashes: { script: string; style: string } | null = null;

function sha256b64(s: string): string {
  return createHash("sha256").update(s, "utf8").digest("base64");
}

export function chatCsp(): { script: string; style: string } {
  if (chatCspHashes) return chatCspHashes;
  const html = load("chat.html");
  const script = /<script>([\s\S]*?)<\/script>/.exec(html);
  const style = /<style>([\s\S]*?)<\/style>/.exec(html);
  if (!script || !style) {
    throw new Error(
      "chat.html: expected one bare <script> and one bare <style> block to hash for the CSP",
    );
  }
  chatCspHashes = {
    script: `sha256-${sha256b64(script[1])}`,
    style: `sha256-${sha256b64(style[1])}`,
  };
  return chatCspHashes;
}

// Shown when someone opens a /c/... link in a browser but the id or token is
// malformed — usually a URL that got truncated by a messaging app.
export function renderChatLinkError(): string {
  return load("chat-error.html");
}

// Returns null if channelId or token are not hex — caller should 400.
// Hex validation is load-bearing: both values are interpolated literally
// into the shell script body, so non-hex would be shell injection.
export function renderJoinerBootstrap(
  bridgeUrl: string,
  channelId: string,
  token: string,
): string | null {
  if (!HEX_RE.test(channelId) || !HEX_RE.test(token)) return null;
  return fill(load("bootstrap-joiner.sh.tpl"), {
    BRIDGE_URL: bridgeUrl,
    CHANNEL_ID: channelId,
    TOKEN: token,
  });
}

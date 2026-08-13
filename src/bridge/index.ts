import { serve } from "@hono/node-server";
import { Hono } from "hono";
import type { Context } from "hono";
import { ChannelStore } from "./channels.js";
import { RateLimiter, loadConfig as loadRateLimitConfig } from "./rate-limit.js";
import { renderMetrics } from "./metrics.js";
import { randomBytes } from "node:crypto";
import {
  loadSiteAsset,
  renderChat,
  renderChatLinkError,
  renderHelpersScript,
  renderInitiator,
  renderInitiatorBootstrap,
  renderJoiner,
  renderJoinerBootstrap,
  renderJoinerWebFetchStub,
  renderLanding,
  renderLoopScript,
  renderSkill,
  renderSkillInstall,
} from "../page/render.js";

const store = new ChannelStore();
const rateLimiter = new RateLimiter(loadRateLimitConfig());
const startedAt = Date.now();
store.onEviction((channelId, creatorIp, reason) => {
  rateLimiter.releaseChannel(creatorIp, channelId);
  log("channel_evicted", { channel_id: channelId, reason });
});
// Sleeping rooms give their concurrent-channel slot back — see HibernationListener
// in channels.ts for why waking does not take one again.
store.onHibernation((channelId, creatorIp) => {
  rateLimiter.releaseChannel(creatorIp, channelId);
  log("channel_hibernated", { channel_id: channelId });
});
store.startSweep();
const app = new Hono();

function clientIp(c: Context): string {
  const fwd = c.req.header("x-forwarded-for");
  if (fwd) return fwd.split(",")[0].trim();
  return c.req.header("x-real-ip") ?? "local";
}

function log(event: string, data: Record<string, unknown> = {}) {
  console.log(JSON.stringify({ ts: new Date().toISOString(), event, ...data }));
}

function bridgeBase(c: Context): string {
  const proto = c.req.header("x-forwarded-proto");
  const host = c.req.header("host");
  if (proto && host) return `${proto}://${host}`;
  return new URL(c.req.url).origin;
}

app.use("*", async (c, next) => {
  const start = Date.now();
  await next();
  log("http", {
    method: c.req.method,
    path: c.req.path,
    status: c.res.status,
    ms: Date.now() - start,
    ip: clientIp(c),
  });
});

const markdownHeaders = {
  "content-type": "text/markdown; charset=utf-8",
  "cache-control": "no-store",
} as const;

// User-Agents that should land directly on the SDK when they hit `/` —
// the bare-URL invocation ("talk to my Claude at agentalk.dev") then
// completes in one fetch instead of two. The canonical pattern remains
// curl https://agentalk.dev/llms.txt, so this is purely a UX fallback.
const LLM_UA = /\b(Claude-User|claude-cli|Anthropic|GPT|ChatGPT|OpenAI|Gemini|Bard|PerplexityBot)\b/i;
// Indexers must always see the HTML landing, regardless of any LLM keyword in their UA.
const SEARCH_BOT_UA = /\b(Googlebot|Bingbot|DuckDuckBot|Slurp|YandexBot|Baiduspider|facebookexternalhit|Twitterbot|LinkedInBot|Applebot)\b/i;
// Claude Code's WebFetch tool sends a recognizable UA. We serve it a short
// "switch to curl" stub at /c/:id, because the joiner SDK has a per-channel
// bootstrap command that WebFetch's summarization step has been observed to
// drop. curl's default UA does not match, so the full SDK still serves to
// the canonical path.
const WEBFETCH_UA = /\bClaude-User\b/i;

function shouldServeSdkAtRoot(ua: string): boolean {
  if (!ua) return false;
  if (SEARCH_BOT_UA.test(ua)) return false;
  return LLM_UA.test(ua);
}

// /c/:id serves three different bodies, so it needs its own rule — and it is
// the INVERSE of the one at `/`. There, an LLM UA opts in to markdown and
// everything else gets HTML. Here the default must stay markdown: curl's UA
// (`curl/8.x`) matches none of the patterns above, and the joiner SDK reaching
// a curling Claude is the canonical path this whole project depends on
// (asserted in test/manual/phase2.sh). So browsers opt IN to the chat UI and
// every unknown client keeps the pre-existing behaviour.
//
// The test is `Accept`, not a browser-UA regex: Claude-User's real UA string
// contains `Mozilla/5.0`, so a /Mozilla|Chrome|Safari/ pattern would be correct
// only by branch ordering, and would rot as new browsers ship. Asking for
// text/html is what actually distinguishes a browser from curl's `*/*`.
function shouldServeChatUi(ua: string, accept: string): boolean {
  if (LLM_UA.test(ua) || SEARCH_BOT_UA.test(ua)) return false;
  return accept.includes("text/html");
}

const initiatorHandler = (c: Context) =>
  c.body(renderInitiator(bridgeBase(c)), 200, markdownHeaders);

const joinerHandler = (c: Context) => {
  const id = c.req.param("id") ?? "";
  const token = c.req.query("token") ?? "";
  const ua = c.req.header("user-agent") ?? "";
  const accept = c.req.header("accept") ?? "";
  // Three UA-conditional bodies live at this path, so every branch below must
  // carry `vary` or a CDN will hand one client another's body. Accept is in the
  // key too, since that is what the chat branch actually switches on.
  const joinerVary = "User-Agent, Accept";
  if (WEBFETCH_UA.test(ua)) {
    return c.body(renderJoinerWebFetchStub(bridgeBase(c), id, token), 200, {
      "content-type": "text/markdown; charset=utf-8",
      "cache-control": "no-store",
      vary: joinerVary,
    });
  }
  if (shouldServeChatUi(ua, accept)) {
    const nonce = randomBytes(16).toString("base64");
    const page = renderChat(id, token, nonce);
    // renderChat returns null when the id or token is not hex. Both are
    // interpolated into the page body, so this is the same load-bearing
    // validation that guards the bootstrap route — see render.ts.
    if (page === null) {
      return c.body(renderChatLinkError(), 400, {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        vary: joinerVary,
      });
    }
    return c.body(page, 200, {
      "content-type": "text/html; charset=utf-8",
      // Never `public` like the landing page: this body embeds the channel
      // token, so a shared cache holding it would be handing out credentials.
      "cache-control": "no-store",
      vary: joinerVary,
      // The URL carries ?token=, so it must never ride along in a Referer.
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      // The page renders peer-controlled names and message bodies. Those all
      // go through textContent, so this is the second line of defence, not the
      // first — but a nonce means even a successful injection cannot execute.
      // connect-src 'self' is what lets it reach /channels/*; img-src 'none'
      // and the absent default-src fallback keep it from phoning anywhere else.
      "content-security-policy": [
        "default-src 'none'",
        `script-src 'nonce-${nonce}'`,
        `style-src 'nonce-${nonce}'`,
        "connect-src 'self'",
        "img-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'",
      ].join("; "),
    });
  }
  return c.body(renderJoiner(bridgeBase(c), id, token), 200, {
    ...markdownHeaders,
    vary: joinerVary,
  });
};

app.get("/", (c) => {
  const ua = c.req.header("user-agent") ?? "";
  if (shouldServeSdkAtRoot(ua)) {
    return c.body(renderInitiator(bridgeBase(c)), 200, {
      "content-type": "text/markdown; charset=utf-8",
      "cache-control": "no-store",
      vary: "User-Agent",
    });
  }
  return c.body(renderLanding(), 200, {
    "content-type": "text/html; charset=utf-8",
    // public (not private): same body for every browser/crawler UA. The Vary
    // header lets Cloudflare cache a separate copy for the LLM (Claude-User)
    // UA class without poisoning either. Public caching improves TTFB/LCP for
    // cold visitors → Core Web Vitals win.
    "cache-control": "public, max-age=300",
    vary: "User-Agent",
  });
});
app.get("/llms.txt", initiatorHandler);
app.get("/c/:id", joinerHandler);

// Static assets built by Astro into site/dist/. These are public — same body
// for every UA — so no Vary header. Robots and sitemap must be byte-stable for
// search engines, so cache aggressively at the CDN.
const STATIC_ASSETS: Record<string, { contentType: string; cacheControl: string }> = {
  "/robots.txt": { contentType: "text/plain; charset=utf-8", cacheControl: "public, max-age=3600" },
  "/favicon.svg": { contentType: "image/svg+xml", cacheControl: "public, max-age=86400" },
  "/favicon-32.png": { contentType: "image/png", cacheControl: "public, max-age=86400" },
  "/apple-touch-icon.png": { contentType: "image/png", cacheControl: "public, max-age=86400" },
  "/logo.svg": { contentType: "image/svg+xml", cacheControl: "public, max-age=86400" },
  "/og.png": { contentType: "image/png", cacheControl: "public, max-age=86400" },
};

for (const [path, meta] of Object.entries(STATIC_ASSETS)) {
  app.get(path, (c) => {
    try {
      const buf = loadSiteAsset(path.slice(1));
      // Hono expects Uint8Array<ArrayBuffer>; Buffer.buffer is ArrayBufferLike.
      // Copy into a fresh Uint8Array to satisfy the type.
      const body = new Uint8Array(buf);
      return c.body(body, 200, {
        "content-type": meta.contentType,
        "cache-control": meta.cacheControl,
      });
    } catch {
      return c.notFound();
    }
  });
}

// The human-facing site is a single page served at / (see the UA-sniffed
// handler above). Former content pages (/docs, /vs/*, /use-cases/*, …) were
// removed 2026-08-10 — they now 404 into the notFound() hint below.

app.get("/loop.sh", (c) =>
  c.body(renderLoopScript(), 200, {
    "content-type": "text/plain; charset=utf-8",
    "cache-control": "no-store",
  }),
);

app.get("/helpers.sh", (c) =>
  c.body(renderHelpersScript(), 200, {
    "content-type": "text/plain; charset=utf-8",
    "cache-control": "no-store",
  }),
);

// Optional /agentalk skill. `skill.sh` is the `curl … | sh` installer; it
// fetches `skill.md` (the SKILL.md body) and writes it under
// ~/.claude/skills/agentalk/. Both are public and UA-agnostic — a human
// inspecting skill.md gets the same bytes the installer writes.
app.get("/skill.sh", (c) =>
  c.body(renderSkillInstall(bridgeBase(c)), 200, {
    "content-type": "text/plain; charset=utf-8",
    "cache-control": "no-store",
  }),
);

app.get("/skill.md", (c) =>
  c.body(renderSkill(), 200, {
    "content-type": "text/markdown; charset=utf-8",
    "cache-control": "no-store",
  }),
);

app.get("/bootstrap.sh", (c) =>
  c.body(renderInitiatorBootstrap(bridgeBase(c)), 200, {
    "content-type": "text/plain; charset=utf-8",
    "cache-control": "no-store",
  }),
);

app.get("/c/:id/bootstrap.sh", (c) => {
  const id = c.req.param("id") ?? "";
  const token = c.req.query("token") ?? "";
  const body = renderJoinerBootstrap(bridgeBase(c), id, token);
  if (!body) {
    return c.json({ error: "invalid_channel_or_token" }, 400);
  }
  return c.body(body, 200, {
    "content-type": "text/plain; charset=utf-8",
    "cache-control": "no-store",
  });
});

app.get("/health", (c) => c.json({ ok: true, ...store.stats() }));

app.get("/metrics", (c) =>
  c.body(renderMetrics(store, rateLimiter, startedAt), 200, {
    "content-type": "text/plain; version=0.0.4; charset=utf-8",
    "cache-control": "no-store",
  }),
);

app.notFound((c) => {
  const ua = c.req.header("user-agent") ?? "";
  const isHumanBrowser = !LLM_UA.test(ua) || SEARCH_BOT_UA.test(ua);
  // Humans and crawlers get the styled HTML 404 from the Astro build so they
  // still have a Nav, footer, and links to popular destinations. LLM agents
  // (Claude Code, etc.) keep getting the markdown hint, which is shorter and
  // tells them how to recover by fetching /llms.txt.
  if (isHumanBrowser) {
    try {
      const buf = loadSiteAsset("404.html");
      return c.body(buf.toString("utf8"), 404, {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        vary: "User-Agent",
      });
    } catch {
      // Fall through to markdown if the static 404 page is missing.
    }
  }
  const base = bridgeBase(c);
  const body = `# agentalk — not found

You called \`${c.req.method} ${c.req.path}\`, which is not a route on this server.

**agentalk is an LLM-first agent-to-agent HTTP bridge.** If a user told you to "talk to another agent" via this URL, do this:

- \`GET ${base}/llms.txt\` — read the SDK page (markdown). It explains the entire protocol step by step.
- \`GET ${base}/health\` — liveness + stats.

\`GET ${base}/\` is a human-facing landing page (HTML); the LLM protocol lives at \`/llms.txt\` only.

There is **no chat-style \`POST /\` endpoint**. All operations are described in the SDK page — fetch it first.
`;
  return c.body(body, 404, {
    "content-type": "text/markdown; charset=utf-8",
    "cache-control": "no-store",
    vary: "User-Agent",
  });
});

app.post("/channels", (c) => {
  const ip = clientIp(c);
  const decision = rateLimiter.checkCreateChannel(ip);
  if (!decision.allowed) {
    log("ratelimit_reject", { endpoint: "channels", ip, reason: decision.reason });
    c.header("Retry-After", String(decision.retryAfterSec));
    return c.json({ error: decision.reason, retry_after_sec: decision.retryAfterSec }, 429);
  }
  const { channel_id, token } = store.createChannel(ip);
  rateLimiter.registerChannel(ip, channel_id);
  const base = bridgeBase(c);
  log("channel_created", { channel_id });
  const shareUrl = `${base}/c/${channel_id}?token=${token}#k=__KEY__`;
  const shareMessage = `Channel ready. Paste the two lines below into your other Claude's chat. The verb "curl" tells them the URL is fetchable rather than a browser link; "to start" keeps it open-ended (no "follow it" — that re-triggers prompt-injection caution). Same URL works for one peer or several.

Talk to my other Claude — curl this URL to start:
${shareUrl}

(Background poll is armed; I'll wake automatically once a peer joins and completes the handshake.)`;
  // The same URL, worded for a PERSON who will open it in a browser rather than
  // an agent who will curl it. Kept as a separate field, never folded into
  // share_message: that wording was tuned against real receiving Claudes'
  // prompt-injection filters and editing it has broken joins before.
  //
  // __TOPIC__ is substituted by Claude, __KEY__ by the initiator bootstrap.
  // Underscore sentinels, not braces — Claude Code's Bash tool reserves {…}
  // for its own placeholder substitution.
  // Every line here is addressed to the RECIPIENT and gets forwarded as-is.
  // Instructions for Claude live in the SDK page and the bootstrap's NEXT 3,
  // never in this string — anything in here ends up in the coworker's inbox.
  const shareMessageHuman = `Hi — I'm Claude, an AI assistant, and I'm helping with __TOPIC__. Could I ask you a quick question about it?

Tap here to chat with me directly. It opens in your browser and there's nothing to install:
${shareUrl}

The conversation is end-to-end encrypted and disappears once everyone closes it.`;
  return c.json({
    channel_id,
    token,
    api_join_url: `${base}/channels/${channel_id}/join`,
    api_poll_url: `${base}/channels/${channel_id}/poll`,
    api_send_url: `${base}/channels/${channel_id}/send`,
    share_message: shareMessage,
    share_message_human: shareMessageHuman,
  });
});

// A 404 on a channel that was evicted (rather than never existing / wrong
// token) carries the reason. Without this, the eviction notice is delivered
// only as a channel message — readable only by a live poll loop, i.e. by the
// exact component whose death usually caused the eviction. Self-concealing
// failures cost hours of diagnosis in the 2026-08-10 incident.
function channelGoneBody(id: string, error: string) {
  const t = store.tombstoneOf(id);
  if (!t) return { error };
  return {
    error,
    evicted_reason: t.reason,
    evicted_s_ago: Math.max(0, Math.round((Date.now() - t.at) / 1000)),
  };
}

// A sleeping room is NOT gone, but it has to look survivable to a client that
// predates hibernation. Hence 404 (the status every existing loop already treats
// as terminal-but-clean) carrying `evicted_reason: "hibernating"`, which those
// loops print as `agentalk: SYSTEM hibernating` before exiting tidily — strictly
// better than the `bad_request` they would otherwise report. The `hibernating`
// and `rejoin` flags are the forward path: a loop that understands them re-joins
// with the same token instead of exiting. Until that ships, this is a clean stop,
// not a recovery.
function hibernatingBody(error: string) {
  return {
    error,
    hibernating: true,
    rejoin: true,
    evicted_reason: "hibernating",
  };
}

// Every channel route funnels its store error through here so the hibernating
// case can never be missed on one endpoint and handled on another.
function channelErrorStatus(id: string, error: string) {
  if (error === "channel_hibernating") return [hibernatingBody(error), 404] as const;
  if (error === "channel_or_token_invalid") return [channelGoneBody(id, error), 404] as const;
  return [{ error }, 400] as const;
}

app.post("/channels/:id/join", async (c) => {
  const joinIp = clientIp(c);
  const joinDecision = rateLimiter.checkJoin(joinIp);
  if (!joinDecision.allowed) {
    log("ratelimit_reject", { endpoint: "join", ip: joinIp, reason: joinDecision.reason });
    c.header("Retry-After", String(joinDecision.retryAfterSec));
    return c.json({ error: joinDecision.reason, retry_after_sec: joinDecision.retryAfterSec }, 429);
  }
  const id = c.req.param("id");
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }
  const { token, name, key_fp } = (body ?? {}) as {
    token?: string;
    name?: string;
    key_fp?: unknown;
  };
  if (!token || !name) return c.json({ error: "missing_token_or_name" }, 400);
  const result = store.join(id, token, name, key_fp);
  if ("error" in result) {
    log("join_failed", { channel_id: id, reason: result.error });
    const [errBody, errStatus] = channelErrorStatus(id, result.error);
    return c.json(errBody, errStatus);
  }
  log("join", { channel_id: id, name });
  return c.json(result);
});

app.post("/channels/:id/send", async (c) => {
  const id = c.req.param("id");
  const ip = clientIp(c);
  const decision = rateLimiter.checkSend(ip);
  if (!decision.allowed) {
    log("ratelimit_reject", { endpoint: "send", ip, reason: decision.reason });
    c.header("Retry-After", String(decision.retryAfterSec));
    return c.json({ error: decision.reason, retry_after_sec: decision.retryAfterSec }, 429);
  }
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }
  const { token, participant_id, text } = (body ?? {}) as {
    token?: string;
    participant_id?: string;
    text?: string;
  };
  if (!token || !participant_id || text === undefined) {
    return c.json({ error: "missing_token_participant_id_or_text" }, 400);
  }
  const result = store.send(id, token, participant_id, text);
  if ("error" in result) {
    log("send_failed", { channel_id: id, reason: result.error });
    const [errBody, errStatus] = channelErrorStatus(id, result.error);
    return c.json(errBody, errStatus);
  }
  log("send", { channel_id: id, participant_id, bytes: text.length });
  return c.json(result);
});

app.get("/channels/:id/poll", async (c) => {
  const id = c.req.param("id");
  const token = c.req.query("token");
  const participantId = c.req.query("participant_id");
  // `??` only defaults an ABSENT param — `&since=` arrives as the empty
  // string and survived to parseInt("") -> NaN -> 400. Clients whose cursor
  // file was reaped by /tmp cleanup send exactly that shape, and pre-fix
  // loop.sh vintages spin unthrottled on the 400 (2026-08-10 incident, 2.1M
  // req/day). `||` treats "" as missing, so they get a full replay instead.
  const sinceRaw = c.req.query("since") || "0";
  const since = Number.parseInt(sinceRaw, 10);
  if (!token || !participantId || Number.isNaN(since) || since < 0) {
    return c.json({ error: "missing_or_invalid_query" }, 400);
  }
  const result = await store.poll(id, token, participantId, since);
  if ("error" in result) {
    const [errBody, errStatus] = channelErrorStatus(id, result.error);
    return c.json(errBody, errStatus);
  }
  c.header("cache-control", "no-store");
  // Always 200 with a body — an empty long-poll used to return a bare 204,
  // but the roster (per-participant last_seen_s) must reach clients even
  // when the room is quiet: a silent room is precisely when "is my peer
  // still there?" needs answering. Roster is computed AFTER the long-poll
  // resolves so last_seen_s is fresh, not 50s stale. Old loops tolerate
  // this: they read .cursor/.messages and ignore unknown fields.
  return c.json({ ...result, roster: store.roster(id, token) });
});

app.post("/channels/:id/leave", async (c) => {
  const id = c.req.param("id");
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }
  const { token, participant_id } = (body ?? {}) as {
    token?: string;
    participant_id?: string;
  };
  if (!token || !participant_id) {
    return c.json({ error: "missing_token_or_participant_id" }, 400);
  }
  const result = store.leave(id, token, participant_id);
  if ("error" in result) {
    const [errBody, errStatus] = channelErrorStatus(id, result.error);
    return c.json(errBody, errStatus);
  }
  log("leave", { channel_id: id, participant_id });
  return c.json(result);
});

const port = Number(process.env.PORT ?? 3000);
serve({ fetch: app.fetch, port });
log("listening", { port });

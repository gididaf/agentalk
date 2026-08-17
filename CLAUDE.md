# CLAUDE.md — instructions for AI assistants working on agentalk

You are working on **agentalk**, an LLM-first HTTP bridge that lets two or more Claude Code sessions on different machines converse autonomously. Live instance: <https://agentalk.dev>. Public README has the user-facing story; this file is for *you*.

## Three surfaces — keep them separate

The repo has **three distinct surfaces** and they have very different change rules:

1. **LLM-facing surface (`src/page/`)** — this is the load-bearing, tuned-against-real-Claude part. Every word was tested against real Claude Code sessions. Re-run the manual QA after editing; phrasing changes routinely change Claude behavior. **Do not rewrite for prose elegance.**

   - `src/page/initiator.md` and `src/page/joiner.md` — SDK pages, served as markdown to LLM UAs.
   - `src/page/bootstrap-initiator.sh.tpl` and `src/page/bootstrap-joiner.sh.tpl` — one-shell-call bootstraps. The `NEXT` lines and `RULES` blocks they print are the *only* instructions some Claudes will read.
   - `src/page/loop.sh` — the background poll loop, sourced (not exec'd) by Claude. Receiver-side dispatch happens here.
   - `src/page/helpers.sh` — `agentalk_send` / `agentalk_say` / `agentalk_dm` / `agentalk_say_file` / `agentalk_dm_file`. Appended to the session env file at bootstrap time.
   - `src/page/protocol.md` — wire-protocol reference, appended to both SDK pages.
   - `src/page/skill.md` and `src/page/skill-install.sh.tpl` — the optional `/agentalk` skill and its one-line web installer. The skill is standing authorization that stops Claude nagging before every send on the user's own bridge; the installer (`curl -fsSL <bridge>/skill.sh | sh`) writes it to `~/.claude/skills/agentalk/SKILL.md` (hot-loads mid-session). `skill.md` is tuned Claude-facing prose — curl QA can't test whether it actually calms the model; that needs a real session.

2. **Browser chat surface (`src/page/chat.html`)** — the page a *person* gets when they open a join link in a browser, so a coworker can talk to a Claude session with no install. One self-contained file: inline CSS, inline JS, zero external requests, no build step, no Astro. It reimplements the wire protocol in WebCrypto, so it must stay byte-compatible with `helpers.sh` — `test/manual/phase11.sh` extracts the crypto block from the *served page* and runs it against the real `helpers.sh` recipe in both directions. Three standing rules: **every peer-controlled string renders via `textContent`** (names are not sanitized server-side); **no `BRIDGE_URL` is interpolated into it** — `bridgeBase()` is Host-header-derived, which is harmless in markdown and a reflected-XSS primitive in HTML, so the page uses relative URLs only; and **nothing per-request may be substituted into the inline `<script>`**. That last one is why the channel id and token ride on `<body data-channel data-token>` and are read back out at runtime: the CSP pins the script by SHA-256 (see gotcha 9 and `chatCsp()` in `render.ts`), so its body has to be byte-identical on every request or the digest stops matching and the whole page goes dead. Hash, not nonce, because Cloudflare's Web Analytics injection copies a response's nonce onto the script it inserts — it cannot forge a hash.

3. **Human-facing surface (`site/`)** — a SINGLE minimal Astro page (`site/src/pages/index.astro`, self-contained, inline CSS). The 12-page SEO marketing site was deliberately removed 2026-08-10 (user abandoned SEO and pulled the site from Search Console). Keep it one page and short; don't rebuild content pages, sitemaps, or SEO meta without an explicit ask.

The TypeScript in `src/bridge/` is comparatively boring HTTP plumbing — it UA-sniffs at `/` (serves SDK to LLMs, Astro HTML to humans) and serves the static site routes from `dist/site/`.

`/c/:id` sniffs too, but by the **inverse** rule, and the difference is load-bearing. At `/` an LLM UA opts in to markdown and everything else gets HTML. At `/c/:id` the default must stay markdown, because `curl`'s UA (`curl/8.x`) matches none of the LLM patterns and a curling Claude fetching the joiner SDK is the canonical join path (asserted in `test/manual/phase2.sh`). So browsers opt IN, via `Accept: text/html`, and every unknown client keeps the old behaviour. The test is `Accept` and not a browser-UA regex on purpose: `Claude-User`'s real UA string contains `Mozilla/5.0`.

## Stack

- **Runtime:** Node 22 + Hono.
- **Static site:** Astro 5 in `site/`. Build output served by Hono from `dist/site/` to non-LLM UAs. (`@astrojs/sitemap` is still in `site/package.json` but is no longer wired into `astro.config.mjs` — it went with the marketing site on 2026-08-10. Vestigial, not load-bearing.)
- **Crypto:** AES-256-GCM (Node's `crypto` module), key transported in URL fragment (`#k=…`), bridge never sees it. AAD = `channel_id:sender_name`.
- **Transport:** HTTPS + JSON. Long-poll up to 50 s (Cloudflare's origin timeout is 100 s).
- **Deploy:** Caddy + Let's Encrypt + systemd on Ubuntu. See `deploy/`.

## Build / dev / test

```bash
npm run dev         # Astro build (site once) + tsx watch with relaxed rate limits
npm run build       # Astro build → tsc → copy LLM SDK assets to dist/page/ → copy site/dist to dist/site
npm run site:dev    # Astro dev server only (port 4321) — for iterating on the marketing site
npm run site:build  # Astro build only (writes site/dist/)
npm run typecheck   # tsc --noEmit
```

`npm run dev` builds the site once at startup, then watches `src/`. If you're iterating on `site/`, run `npm run site:dev` in a second terminal.

Manual QA, one script per build phase. **Re-run the relevant one after any SDK/loop/bootstrap change:**

```bash
./test/manual/phase1.sh  # endpoints + long-poll
./test/manual/phase2.sh  # LLM-first page + 404 + /loop.sh
./test/manual/phase3.sh  # two-actor Q→A round trip
./test/manual/phase4.sh  # background-loop + cursor persistence
./test/manual/phase5.sh  # AES-GCM round trip + wrong-key/AAD/tamper rejection
./test/manual/phase6.sh  # 3-Claude room + HELLO/WELCOME + broadcast vs DM
./test/manual/phase7.sh  # rate limits + eviction + metrics
./test/manual/phase8.sh  # hibernate / resume (bridge side)
./test/manual/phase9.sh  # loop.sh survives a sleep/wake cycle (executes the loop)
./test/manual/phase10.sh # browser routing at /c/:id + share_message_human
./test/manual/phase11.sh # chat page: WebCrypto<->helpers.sh interop, renderer vs XSS, CSP cannot run an injected script
./test/manual/phase12.sh # HUMAN_JOINED + burst coalescing (executes the loop)
./test/manual/phase13.sh # join rate limit + control-char names
./test/manual/session-isolation.sh  # two sessions from one cwd must not cross-talk
```

Phases 1-8, 10, 11 and 13 are curl-driven. Phases 9 and 12 actually *execute* `loop.sh` against a live bridge, because they test runtime behaviour (sleep/wake, burst buffering) that no amount of source-grepping can confirm.

One script drives a real model:

```bash
RUN_REAL_CLAUDE=1 ./test/manual/phase14-real-claude.sh  # link-type decision, via claude -p
```

It spends real tokens, so it is opt-in behind that env var. It checks the decisions the SDK's *prose* is supposed to produce: agent link vs human link, and — the one worth having — that Claude does **not** invent a name when the user never gave one.

Everything else about phrasing still needs a human in the loop. A script can check that Claude picked the right file and appended the right params; it cannot check whether the opener it writes to a stranger is actually jargon-free, or whether it stays that way by the third message.

## Gotchas that burned time, please don't re-burn

1. **zsh's builtin `echo` interprets backslash escapes by default.** Claude Code's Bash tool runs zsh on macOS. `echo "$PT" | jq` corrupts any JSON envelope containing `\n` escape sequences because `\n` becomes a literal newline. **Always use `printf '%s' "$VAR" | …`** in receiver paths. `loop.sh` has this fix; do not regress it. See the comment block around line 99.

2. **Claude Code's Bash tool spawns a fresh shell per call.** Env vars and shell functions defined in one Bash call are gone in the next. The pattern is: persist state to `/tmp/agentalk-session-<channel_id>-<name>.env` and source it at the start of every subsequent Bash call. The bootstrap scripts print the literal file path so Claude doesn't have to interpolate `$AGENTALK_SESSION_FILE`. **The `<channel_id>` half is load-bearing**: `<name>` is the basename of the cwd, so two agentalk sessions started from the same directory collided on one env file and the second silently redirected the first's sends into the wrong channel (observed live 2026-08-12). All per-session tmp files — `session`, `share`, `cursor`, `hdr`, `debug` — are channel-scoped for this reason.

3. **A new template under `src/page/` must be added to the `cp` list in `package.json`'s `build` script.** `render.ts` loads templates from beside the *compiled* JS (`dist/page/`), so a file that exists in `src/` but was never copied throws at request time — a production 500 on a route that works perfectly in dev. `test/manual/phase10.sh` runs a real build and asserts the chat templates landed.

4. **Don't put `{name}` or `{{name}}` patterns in Bash commands** Claude executes. Claude Code's Bash tool reserves `{…}` for its own placeholder substitution. `curl -w '%{http_code}'` is a real footgun.

5. **HEX validation on `:id` and `?token=` is load-bearing.** Both values are interpolated literally into shell script bodies served from `/c/:id/bootstrap.sh`. The `HEX_RE` check in `src/page/render.ts` prevents shell injection. Don't disable it.

6. **`vary: User-Agent` on UA-conditional responses.** Browser and `Claude-User` (WebFetch) get different bodies at `/`, `/c/:id`, and any 404 (HTML page for humans, markdown SDK hint for agents). Without `vary` headers, any CDN cache would serve the wrong body to the wrong client.

7. **Auto-HELLO trigger is `$MY_CHALL` being set.** Joiner bootstrap sets it; initiator bootstrap doesn't. `loop.sh` checks once at startup. Don't move the HELLO send back into bootstrap — past QA caught race conditions where WELCOMEs arrived before the receiver was polling.

8. **The handoff phrase matters.** "Talk to my other Claude — curl this URL to start: …" passes Claude Code's prompt-injection filter. Variants like "follow this URL" or naked URL paste have failed in past QA. The bridge ships this exact phrasing in the `share_message` body — don't rewrite it without testing both ends.

9. **The chat page's CSP hash must be computed the way a *browser* parses the page, not the way a regex scans the file.** `chat.html` contains prose *about* `<script>` tags — the comment above the real one explains the nonce-vs-hash rationale and includes the literal string. A plain `/<script>([\s\S]*?)<\/script>/` on the raw file therefore opens inside that comment and hashes comment text plus the script body. `chatCsp()` strips HTML comments first, and throws if a hashed body still contains markup. This shipped once (a5734af) and took down the entire browser surface in production: Chrome refused the inline script, the page rendered but the join button did nothing, and `/health` looked perfectly healthy. **A server that hashes its own output cannot self-check** — the header agreed with the file it came from, and `phase10.sh` reproduced the same regex, so both were consistently wrong and QA was green. The check now models the consumer; keep it that way.

## Adding a feature — the process this project uses

1. **Verify assumptions first.** List every assumption the change rests on; use `AskUserQuestion` for the load-bearing ones. The user explicitly values this — past sessions burned on assumptions that should have been confirmed.
2. **Research prior art** before proposing a new endpoint or sub-tool. Web-search what exists. The bar is "is this materially different from what already exists?"
3. **Phased delivery, manual QA gate between each.** No big-bang. Stop after each phase and let the user verify before continuing.
4. **Don't push to GitHub or deploy to the VM unprompted.** Both are explicit-instruction-only. Local edits + build are fine.
5. **`git commit` only when the user asks.** Even for "obvious" cleanup.

## Deploy

The dev VM details are in your auto-memory under `project_agentalk` — fetch them with the memory system, not from this file.

The deploy pattern (verified 2026-05-25):

```bash
rsync -avz \
  --exclude='node_modules' --exclude='dist' --exclude='.astro' --exclude='.DS_Store' \
  src site package.json package-lock.json tsconfig.json \
  root@<VM>:/opt/agentalk/
ssh root@<VM> "chown -R agentalk:agentalk /opt/agentalk && \
  sudo -u agentalk -H bash -c 'cd /opt/agentalk && \
    npm ci && npm --prefix site ci && npm run build' && \
  systemctl restart agentalk"
```

Notes:
- `src` and `site` go *without* trailing slashes (a trailing slash flattens the directory contents into `/opt/agentalk/` and breaks `tsconfig.json`'s `rootDir`).
- `--exclude='node_modules'` is load-bearing — `site/node_modules` is ~157 MB and the VM reinstalls fresh.
- The chown matters because rsync over root SSH leaves root-owned files; agentalk needs write access to create `dist/`.
- systemd runs `node /opt/agentalk/dist/bridge/index.js` — so the build is required before restart. If the build fails, *don't* restart; the existing `dist/` keeps the old code working.
- **A restart destroys every room, live *and* hibernating** — they are in-memory. The user's rule is to take the deploy window when `/health` shows the channel count is low or zero, and `/health` is the only visibility there is (aggregate counts; no endpoint enumerates channel ids, by design).
- **Caddy's `header` directive replaces, it does not merge.** Production once carried a blanket CSP that silently wiped the per-route headers the bridge sets, including the chat page's. It is now scoped with `@notchat not path /c/*` in `deploy/Caddyfile`. If the app's response headers ever appear to vanish, check the VM's Caddyfile against the repo copy before suspecting the bridge.

Bridge runs as the `agentalk` user. Systemd unit at `/etc/systemd/system/agentalk.service`. Env at `/etc/agentalk/env`. Caddy fronts it with Let's Encrypt; Cloudflare proxy in front of that in Full (strict) mode.

(The old `PUBLIC_GA4_MEASUREMENT_ID` / `PUBLIC_GSC_VERIFY` / `PUBLIC_BING_VERIFY` build-time env vars are obsolete — the layout that consumed them was deleted with the marketing site on 2026-08-10.)

When removing files under `src/` or `site/`, rsync with `--delete` — stale sources on the VM otherwise resurrect deleted pages at build time.

## Key files at a glance

```
src/bridge/index.ts          Hono routes, UA sniffing, rate-limit wiring
src/bridge/channels.ts       In-memory channel state, hibernate/resume, eviction, long-poll waiters
src/bridge/rate-limit.ts     Per-IP token bucket
src/bridge/metrics.ts        Prometheus /metrics
src/page/render.ts           Markdown/shell template substitution + HEX validation
src/page/initiator.md        SDK page for the channel creator
src/page/joiner.md           SDK page for joiners (served at /c/:id)
src/page/bootstrap-*.sh.tpl  One-call bootstraps (initiator + joiner)
src/page/loop.sh             Sourced poll loop with auto-handshake + dispatch
src/page/helpers.sh          Send helpers (appended to session env file)
src/page/protocol.md         Wire-protocol reference (appended to SDK pages)
src/page/skill.md            Optional /agentalk skill body (served at /skill.md, written to ~/.claude/skills/agentalk/SKILL.md)
src/page/skill-install.sh.tpl  One-line skill installer (served at /skill.sh)
src/page/chat.html           Browser chat client for HUMAN participants (served at /c/:id to
                             browsers). Self-contained: inline CSS+JS, no build step, no
                             external requests. MUST be in package.json's build cp list.
src/page/chat-error.html     Shown when a /c/... link reaches a browser malformed
site/                        Astro site — ONE page only (index.astro, self-contained)
site/astro.config.mjs        Astro config — no sitemap; HTML compression
site/src/pages/index.astro   The entire human-facing site
site/public/                 Static assets (logo.svg, favicon.svg, og.png, robots.txt, apple-touch-icon.png)
test/manual/phase*.sh        Curl-driven QA, one per build phase
deploy/{Caddyfile,install.sh,agentalk.service,env.example}
```

## When in doubt

- Read the existing `src/page/initiator.md` and `src/page/joiner.md` end to end. They are the spec.
- Talk to the live bridge at `https://agentalk.dev/health` and `https://agentalk.dev/llms.txt` to see current production state.
- The original 8-phase plan + 8c-fix design notes live in the user's `~/.claude/plans/` directory and in auto-memory.

## Last Synced Commit

`995a9ba5fc504fc3aea400f8e3adea71ce025ac4` — 2026-08-17

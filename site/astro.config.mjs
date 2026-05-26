import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

// trailingSlash: "never" makes Astro emit canonical, og:url, and sitemap entries
// without trailing slashes — matching what the Hono bridge actually serves
// (its HTML_PAGES allowlist registers only the no-slash form). build.format
// stays at the default "directory", so files on disk are still <path>/index.html
// for the bridge's loadSiteAsset() to pick up.
const SITEMAP_LASTMOD = "2026-05-25";

export default defineConfig({
  site: "https://agentalk.dev",
  trailingSlash: "never",
  integrations: [
    sitemap({
      serialize(item) {
        item.lastmod = SITEMAP_LASTMOD;
        return item;
      },
    }),
  ],
  build: {
    inlineStylesheets: "always",
  },
  compressHTML: true,
});

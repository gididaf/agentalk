import { defineConfig } from "astro/config";

// Single-page site, no SEO ambitions — no sitemap. build.format stays at the
// default "directory" so the bridge's loadSiteAsset() finds index.html.
export default defineConfig({
  site: "https://agentalk.dev",
  trailingSlash: "never",
  build: {
    inlineStylesheets: "always",
  },
  compressHTML: true,
});

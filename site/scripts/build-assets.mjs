#!/usr/bin/env node
// Generate raster brand assets from SVG sources.
// Output is committed to site/public/ so production builds don't depend on sharp.
// Run: `node site/scripts/build-assets.mjs` from repo root (or inside site/).

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import sharp from "sharp";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "..");

async function svgToPng(svgPath, outPath, width, height) {
  const svg = readFileSync(resolve(repo, svgPath));
  const buf = await sharp(svg, { density: 300 })
    .resize(width, height, { fit: "cover" })
    .png({ compressionLevel: 9 })
    .toBuffer();
  writeFileSync(resolve(repo, outPath), buf);
  console.log(`✓ ${outPath} (${width}x${height}, ${buf.byteLength} bytes)`);
}

await svgToPng("scripts/og.svg", "public/og.png", 1200, 630);
await svgToPng("public/favicon.svg", "public/apple-touch-icon.png", 180, 180);
await svgToPng("public/favicon.svg", "public/favicon-32.png", 32, 32);

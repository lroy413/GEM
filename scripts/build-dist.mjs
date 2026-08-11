// Stage the deployable asset set into dist/ for `wrangler deploy`.
//
// This mirrors build.py deliberately rather than shelling out to it: the
// Cloudflare build image is guaranteed to have Node, not Python, and the
// transform is small enough that a second copy is cheaper than a dependency.
// If you change the <head> in build.py, change it here too — the check at the
// bottom of this file will tell you when they have drifted.
//
// Nothing here reads the committed index.html. CI rebuilds it from
// gem-artifact.html so a stale commit can never reach production.

import { createHash } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DIST = join(ROOT, "dist");

const HEAD = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="description" content="Wedding and event planning for Glimmer Events Management.">
<meta name="theme-color" content="#F2DFE1">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="apple-mobile-web-app-title" content="GEM">
<meta name="format-detection" content="telephone=no">
<meta name="gem-build" content="__BUILD__">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" href="/icons/icon-192.png" sizes="192x192" type="image/png">
<link rel="apple-touch-icon" href="/icons/icon-180.png">
<title>GEM · Glimmer Events Management</title>
</head>
<body>
`;
const FOOT = `
</body>
</html>
`;

/* The eight files that get deployed. _headers and download.html are excluded
   on purpose — see the note in deploy.py; shipping them would change the live
   cache-control and security headers. Keep this list and ASSETS in deploy.py
   in step. */
const COPY = {
  "sw.js": "deploy/sw.js",
  "manifest.webmanifest": "deploy/manifest.webmanifest",
  "offline.html": "deploy/offline.html",
  "icons/icon-180.png": "deploy/icons/icon-180.png",
  "icons/icon-192.png": "deploy/icons/icon-192.png",
  "icons/icon-512.png": "deploy/icons/icon-512.png",
  "icons/icon-maskable-512.png": "deploy/icons/icon-maskable-512.png",
};

const sha = (b) => createHash("sha256").update(b).digest("hex");

rmSync(DIST, { recursive: true, force: true });
mkdirSync(join(DIST, "icons"), { recursive: true });

// 1 · index.html, rebuilt from the artifact exactly as build.py does.
const rawSrc = readFileSync(join(ROOT, "gem-artifact.html"));
let src = rawSrc.toString("utf8");
src = src.replace(/^\s*<title>[\s\S]*?<\/title>\s*/, ""); // the wrapper supplies one
// Build stamp, derived from the source artifact so this and build.py agree
// without either needing to know what the other produced. Surfaced in
// Settings so "am I on the newest build?" is answerable inside the app.
const build = sha(rawSrc).slice(0, 12);
const html = HEAD.replace("__BUILD__", build) + src + FOOT;
writeFileSync(join(DIST, "index.html"), html, "utf8");

// The charset must land in the first bytes or the browser decodes as Latin-1
// and every · and ✦ in the UI turns to mojibake.
const head200 = Buffer.from(html, "utf8").subarray(0, 200).toString("utf8");
if (!head200.includes('charset="utf-8"')) {
  throw new Error("charset must appear in the first 200 bytes of index.html");
}

let total = Buffer.byteLength(html, "utf8");
console.log(`  index.html                  ${String(total).padStart(8)} B  sha256 ${sha(html).slice(0, 12)}`);

// 2 · everything else, copied verbatim.
for (const [arc, rel] of Object.entries(COPY)) {
  const from = join(ROOT, rel);
  cpSync(from, join(DIST, arc));
  const n = statSync(from).size;
  total += n;
  console.log(`  ${arc.padEnd(28)}${String(n).padStart(8)} B`);
}
console.log(`\n  dist/ ready — ${Object.keys(COPY).length + 1} files, ${(total / 1024).toFixed(1)} KB`);

// 3 · warn if the committed index.html has drifted from its source. CI deploys
// what it just built, so this is a heads-up rather than a failure.
try {
  const committed = readFileSync(join(ROOT, "index.html"), "utf8");
  if (committed !== html) {
    console.log("\n  note: committed index.html differs from this build —");
    console.log("        run `python3 build.py` and commit it to keep them in step.");
  }
} catch { /* not present; nothing to compare */ }

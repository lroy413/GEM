// Stage the deployable asset set into dist/ for `wrangler deploy`.
//
// This mirrors build.py deliberately rather than shelling out to it: the
// Cloudflare build image is guaranteed to have Node, not Python. The TRANSFORM
// is duplicated; the <head> is not. It used to be, kept in step by hand with a
// console note at the bottom of this file if the two drifted — and that is
// precisely what went wrong: build.py's head was corrected, this copy was not,
// and the deploy went out carrying the right build stamp and the previous
// status-bar colour. The note scrolled past in a CI log nobody reads. build.py
// owns the head now and this file parses it out; reading a Python file as text
// needs no Python.
//
// Nothing here reads the committed index.html. CI rebuilds it from
// gem-artifact.html so a stale commit can never reach production.

import { createHash } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DIST = join(ROOT, "dist");

/* Lifted from build.py's own template literals, so there is exactly one
   definition of the wrapper and it cannot drift again. */
const buildPy = readFileSync(join(ROOT, "build.py"), "utf8");
const lift = (name) => {
  const m = buildPy.match(new RegExp('^' + name + ' = """([\\s\\S]*?)"""$', "m"));
  if (!m) throw new Error(`could not find the ${name} template in build.py`);
  return m[1];
};
const HEAD = lift("HEAD");
const FOOT = lift("FOOT");

/* The two things the wrapper exists to guarantee. A silently malformed head is
   how the last one got out, so these throw rather than warn. */
if (!HEAD.includes('charset="utf-8"')) {
  throw new Error("build.py's HEAD no longer declares a charset");
}
if (!HEAD.includes("__BUILD__")) {
  throw new Error("build.py's HEAD no longer carries the __BUILD__ stamp");
}

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

#!/usr/bin/env python3
"""Wrap the artifact body in a complete HTML document for deployment.

The artifact host supplies its own <head>, so gem-artifact.html deliberately
has none. A file served or opened without a charset declaration gets decoded
as Latin-1, which is what turns "·" into "Â·" and "✦" into "âœ¦". A runtime
<meta> cannot fix it — by the time script runs, the bytes are already decoded.

Usage:  python3 build.py
Output: deploy/index.html
"""
import hashlib
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "gem-artifact.html"          # head-less artifact body
OUT = ROOT / "index.html"                 # the file you actually deploy

HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="description" content="Wedding and event planning for Glimmer Events Management.">
<meta name="theme-color" content="#FBF4F4">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="GEM">
<meta name="format-detection" content="telephone=no">
<meta name="gem-build" content="__BUILD__">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" href="/icons/icon-192.png" sizes="192x192" type="image/png">
<link rel="apple-touch-icon" href="/icons/icon-180.png">
<title>GEM · Glimmer Events Management</title>
</head>
<body>
"""

FOOT = """
</body>
</html>
"""


def main() -> None:
    raw_src = SRC.read_bytes()
    src = raw_src.decode("utf-8")

    # The artifact starts with its own <title>; the wrapper supplies one.
    src = re.sub(r"^\s*<title>.*?</title>\s*", "", src, count=1, flags=re.S)

    # A build stamp, so "am I looking at the newest version?" is answerable
    # from inside the app instead of by hashing files. Derived from the source
    # artifact, so build.py and scripts/build-dist.mjs agree without either
    # having to know what the other produced.
    build = hashlib.sha256(raw_src).hexdigest()[:12]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(HEAD.replace("__BUILD__", build) + src + FOOT, encoding="utf-8")

    raw = OUT.read_bytes()
    assert raw.decode("utf-8"), "output is not valid UTF-8"
    head = raw[:200].decode("utf-8", "replace")
    assert 'charset="utf-8"' in head, "charset must appear in the first bytes"

    non_ascii = sum(1 for ch in OUT.read_text(encoding="utf-8") if ord(ch) > 127)
    print(f"wrote {OUT.relative_to(ROOT)}  ({len(raw):,} bytes)  build {build}")
    print(f"  charset declared in first {head.index('charset')} bytes ✓")
    print(f"  {non_ascii:,} non-ASCII characters — all safe once charset is declared")


if __name__ == "__main__":
    main()

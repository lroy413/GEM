#!/usr/bin/env python3
"""GEM deploy — push the built app to the `gemevents` Cloudflare Worker.

  export CLOUDFLARE_API_TOKEN=...        # "Edit Cloudflare Workers" template
  python3 deploy.py                      # build, upload, deploy, verify
  python3 deploy.py --dry-run            # manifest + what would upload, no writes

`gemevents` is an assets-only Worker: there is no user script, Cloudflare serves
the files directly and falls back to index.html for unknown paths (the app is a
single page and does its own routing). Deploying therefore means uploading the
asset set and pointing a new script version at it.

Stdlib only — this machine has no node, no wrangler and no docker.

The asset hash is the one Cloudflare's own tooling uses:
sha256(base64(contents) + extension-without-dot), hex, first 32 characters.
Files whose hash is already in the account's asset store are never re-sent, so
a normal deploy uploads index.html alone.
"""

import argparse
import base64
import hashlib
import json
import mimetypes
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.abspath(__file__))
ACCOUNT_ID = "bede02f9ab41bc90bae308430bccdea1"
SCRIPT_NAME = "gemevents"
SITE = "https://gemevents.app"
API = "https://api.cloudflare.com/client/v4"

# The compatibility date already on the deployed Worker. Bumping it changes
# runtime behaviour, so it is pinned here rather than set to "today".
COMPATIBILITY_DATE = "2026-08-05"

# Mirrors what is live: /foo.html redirects to /foo, and anything unmatched
# serves index.html so the app can route it.
ASSET_CONFIG = {
    "html_handling": "auto-trailing-slash",
    "not_found_handling": "single-page-application",
}

# Asset path → file on disk. `_headers` and `download.html` are deliberately
# absent: neither is deployed today, and adding them would change live
# behaviour (cache-control and security headers) under cover of a routine push.
ASSETS = {
    "/index.html": "index.html",
    "/sw.js": "deploy/sw.js",
    "/manifest.webmanifest": "deploy/manifest.webmanifest",
    "/offline.html": "deploy/offline.html",
    "/icons/icon-180.png": "deploy/icons/icon-180.png",
    "/icons/icon-192.png": "deploy/icons/icon-192.png",
    "/icons/icon-512.png": "deploy/icons/icon-512.png",
    "/icons/icon-maskable-512.png": "deploy/icons/icon-maskable-512.png",
}


def die(msg):
    print("\n✗ " + msg, file=sys.stderr)
    sys.exit(1)


KEYCHAIN_SERVICE = "gem-cloudflare-deploy"


def keychain_token():
    """Read the deploy token from the macOS login keychain, if it is there.

    The environment alone meant the token died with the terminal window it was
    exported in, so a deploy could only ever happen at the machine, in that one
    session. The keychain keeps it available without leaving a secret sitting
    in a dotfile in plain text, and macOS gates access to it.
    """
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    v = (out.stdout or "").strip()
    return v or None


def token():
    for k in ("CLOUDFLARE_API_TOKEN", "CF_API_TOKEN"):
        v = os.environ.get(k)
        if v:
            return v.strip()
    v = keychain_token()
    if v:
        return v
    die(
        "No API token.\n"
        "  Create one at https://dash.cloudflare.com/profile/api-tokens using the\n"
        "  \"Edit Cloudflare Workers\" template (Account > Workers Scripts > Edit is\n"
        "  the only permission this script needs), then EITHER:\n"
        "\n"
        "    export CLOUDFLARE_API_TOKEN=...          # this shell only\n"
        "\n"
        "  or store it once so any later run — including one driven remotely —\n"
        "  can find it:\n"
        "\n"
        "    security add-generic-password -U -s %s \\\n"
        "      -a \"$USER\" -w    # paste the token when prompted\n"
        "\n"
        "  The token is never written to disk by this script." % KEYCHAIN_SERVICE
    )


def api(method, path, body=None, content_type="application/json",
        bearer=None, raw=False, expect_json=True):
    url = path if path.startswith("http") else API + path
    data = body
    if body is not None and not raw:
        data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + (bearer or token()))
    if body is not None:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            payload = r.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:900]
        die("%s %s → HTTP %s\n%s" % (method, path, e.code, detail))
    if not expect_json:
        return payload
    out = json.loads(payload)
    if not out.get("success", False):
        die("%s %s → %s" % (method, path, json.dumps(out.get("errors"), indent=2)))
    return out["result"]


def asset_hash(data, filename):
    ext = os.path.splitext(filename)[1][1:]
    return hashlib.sha256(
        (base64.b64encode(data).decode() + ext).encode()
    ).hexdigest()[:32]


def build_manifest():
    manifest, blobs = {}, {}
    for asset_path, rel in ASSETS.items():
        full = os.path.join(ROOT, rel)
        if not os.path.exists(full):
            die("missing asset: %s" % rel)
        data = open(full, "rb").read()
        h = asset_hash(data, rel)
        manifest[asset_path] = {"hash": h, "size": len(data)}
        blobs[h] = (asset_path, data)
    return manifest, blobs


def multipart(parts):
    """parts: list of (name, filename, content_type, bytes-or-str body)."""
    boundary = "----GEM" + uuid.uuid4().hex
    out = bytearray()
    for name, filename, ctype, payload in parts:
        out += ("--%s\r\n" % boundary).encode()
        disp = 'form-data; name="%s"' % name
        if filename:
            disp += '; filename="%s"' % filename
        out += ("Content-Disposition: %s\r\n" % disp).encode()
        out += ("Content-Type: %s\r\n\r\n" % ctype).encode()
        out += payload if isinstance(payload, bytes) else payload.encode()
        out += b"\r\n"
    out += ("--%s--\r\n" % boundary).encode()
    return bytes(out), "multipart/form-data; boundary=" + boundary


def upload_assets(manifest, blobs):
    print("· opening upload session")
    session = api(
        "POST",
        "/accounts/%s/workers/scripts/%s/assets-upload-session" % (ACCOUNT_ID, SCRIPT_NAME),
        {"manifest": manifest},
    )
    buckets = session.get("buckets") or []
    jwt = session.get("jwt")
    missing = [h for b in buckets for h in b]

    if not missing:
        # Every file is already in the store — nothing to send, and the session
        # token doubles as the completion token.
        print("· all %d assets already uploaded" % len(manifest))
        return jwt

    print("· %d of %d assets need uploading:" % (len(missing), len(manifest)))
    for h in missing:
        path, data = blobs[h]
        print("    %-30s %8.1f KB" % (path, len(data) / 1024.0))

    completion = None
    for i, bucket in enumerate(buckets, 1):
        parts = []
        for h in bucket:
            path, data = blobs[h]
            ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
            parts.append((h, h, ctype, base64.b64encode(data)))
        body, ctype = multipart(parts)
        print("· uploading bucket %d/%d (%.1f KB)" % (i, len(buckets), len(body) / 1024.0))
        result = api(
            "POST",
            "/accounts/%s/workers/assets/upload?base64=true" % ACCOUNT_ID,
            body, content_type=ctype, bearer=jwt, raw=True,
        )
        # Only the final bucket comes back with the completion token.
        if isinstance(result, dict) and result.get("jwt"):
            completion = result["jwt"]

    if not completion:
        die("uploads finished but Cloudflare returned no completion token")
    return completion


def deploy(completion_jwt):
    metadata = {
        "assets": {"jwt": completion_jwt, "config": ASSET_CONFIG},
        "compatibility_date": COMPATIBILITY_DATE,
        "bindings": [],
    }
    body, ctype = multipart([("metadata", None, "application/json", json.dumps(metadata))])
    print("· deploying new version")
    result = api(
        "PUT",
        "/accounts/%s/workers/scripts/%s" % (ACCOUNT_ID, SCRIPT_NAME),
        body, content_type=ctype, raw=True,
    )
    return result


CF_BEACON = re.compile(
    rb'<script[^>]*(?:cloudflareinsights\.com|data-cf-beacon)[^>]*>\s*</script>\s*')


def strip_injected(body):
    """Remove anything Cloudflare adds to the HTML on the way out.

    Web Analytics injects a beacon <script> into HTML responses. It is not in
    the uploaded asset, so a byte comparison against the local build fails on
    it — and fails identically at every edge, which reads exactly like a stuck
    rollout rather than a false alarm. Belt and braces alongside the neutral
    user agent: if Cloudflare changes when it injects, the check still holds.
    """
    return CF_BEACON.sub(b'', body)


def verify(local_index, rounds=3, tries=40, delay=6):
    """Edges disagree for a minute or two after a push, so require several
    consecutive fetches to agree before calling it done."""
    want = hashlib.sha256(local_index).hexdigest()
    print("· verifying %s (want sha256 %s…)" % (SITE, want[:12]))
    streak = 0
    for attempt in range(1, tries + 1):
        err = None
        try:
            req = urllib.request.Request(SITE + "/?cachebust=%d" % time.time())
            req.add_header("Cache-Control", "no-cache")
            # Threading a needle between two Cloudflare behaviours:
            #   · the default Python-urllib agent is answered with a 403 by bot
            #     protection, so the site looks permanently broken;
            #   · an agent that looks like a real browser gets the Web
            #     Analytics beacon injected into the HTML, so the bytes never
            #     match the file that was uploaded.
            # A plain named agent is neither, and comes back untouched.
            req.add_header("User-Agent", "GEM-deploy/1.0 (+https://gemevents.app)")
            with urllib.request.urlopen(req, timeout=30) as r:
                got = hashlib.sha256(strip_injected(r.read())).hexdigest()
        except Exception as e:  # noqa: BLE001 — any failure just means "not yet"
            got, err = None, str(e)
        if got == want:
            streak += 1
            print("    match %d/%d" % (streak, rounds))
            if streak >= rounds:
                return True
        else:
            if streak:
                print("    edge disagreed, restarting the streak")
            streak = 0
            # Print the whole error. Truncating it once turned a plain 403 into
            # an unreadable "error: http".
            print("    attempt %d: %s" % (attempt, err or ("sha256 " + got[:12])))
        time.sleep(delay)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="show the manifest and what would upload, write nothing")
    ap.add_argument("--skip-build", action="store_true",
                    help="use index.html as it stands instead of rebuilding")
    args = ap.parse_args()

    if not args.skip_build:
        print("· building index.html from gem-artifact.html")
        subprocess.check_call([sys.executable, os.path.join(ROOT, "build.py")], cwd=ROOT)

    manifest, blobs = build_manifest()
    total = sum(v["size"] for v in manifest.values())
    print("· %d assets, %.1f KB total" % (len(manifest), total / 1024.0))

    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        session = api(
            "POST",
            "/accounts/%s/workers/scripts/%s/assets-upload-session" % (ACCOUNT_ID, SCRIPT_NAME),
            {"manifest": manifest},
        )
        missing = [h for b in (session.get("buckets") or []) for h in b]
        print("· would upload: %s" % ([blobs[h][0] for h in missing] or "nothing"))
        print("\n(dry run — no version was created)")
        return

    completion = upload_assets(manifest, blobs)
    deploy(completion)

    local_index = open(os.path.join(ROOT, "index.html"), "rb").read()
    if verify(local_index):
        print("\n✓ deployed — %s is serving this build" % SITE)
    else:
        print("\n! deployed, but %s has not settled on the new build yet." % SITE)
        print("  Cloudflare edges can lag a few minutes. Re-run the check with:")
        print("    python3 deploy.py --skip-build --dry-run   # confirms hashes")
        sys.exit(2)


if __name__ == "__main__":
    main()

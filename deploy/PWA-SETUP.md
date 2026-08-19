# GEM · Getting gemevents.app live and installable

What you need to do, in order. Everything here is on your side — I've written the files.

---

## 1. Files to deploy

```
/index.html                  ← the app (rename gem-artifact.html)
/sw.js                       ← service worker (must sit at the ROOT)
/manifest.webmanifest
/offline.html
/icons/icon-192.png
/icons/icon-512.png
/icons/icon-maskable-512.png
```

**`sw.js` must be served from the root.** A worker at `/assets/sw.js` can only control `/assets/*`, so the app would never go offline.

### The icons

**The four PNGs in `deploy/icons/` are the real ones — don't regenerate them.**
The app can draw its own at runtime, but that path is a fallback for the artifact
host, which owns `<head>` and serves no files. On `gemevents.app` the committed
files are what ship.

Two rules they already follow, worth knowing before anyone replaces them:

- **Every icon is fully opaque.** iOS composites `apple-touch-icon` transparency
  against black, so a rounded-square icon on a transparent background arrives on
  the home screen with black corners. All four were flattened onto `#FAF2F3`.
- **`icon-180.png` is full-bleed**, cut from the same artwork as the maskable.
  iOS applies its own rounded mask, so it wants a plain square and will round it
  for you. `icon-maskable-512.png` is full-bleed for the same reason on Android,
  which crops to a circle — the wordmark sits well inside that safe area.

---

## 2. Hosting

Any static host works. Cloudflare Pages is the easiest with a `.app` domain:

1. Cloudflare dashboard → **Workers & Pages → Create → Pages → Upload assets**
2. Drag the files above in, deploy
3. **Custom domains → Set up a domain →** `gemevents.app`
4. If the domain is registered elsewhere, point its nameservers at Cloudflare

**`.app` is on the HSTS preload list — HTTPS is mandatory, not optional.** That's actually convenient: service workers require HTTPS anyway, so you can't accidentally deploy a non-working configuration.

### Headers — already handled, nothing to add

This deploys as an **assets-only Worker** (`wrangler.jsonc` → `assets.directory`),
not Cloudflare Pages, so the `_headers` file in this folder is **not deployed**
and is kept only as a reference for another host. `_headers` is a Pages/Netlify
convention.

Cloudflare's own defaults already give the behaviour that file was written to
force. Checked against production:

```
/sw.js  →  content-type: text/javascript
           cache-control: public, max-age=0, must-revalidate
```

`must-revalidate` is what matters: the worker is re-checked on every load, so
nobody gets stranded on an old build. The same applies to `/` and the manifest.

---

## 3. Supabase, when you're ready

1. Create the project, then run the numbered migrations from `/supabase` **in
   order** in the SQL Editor. There are 16 now, not 5 — see `supabase/MIGRATION.md`
   for what each one does, and `NEXT.md` for which are already run against the
   live project.
2. **Authentication → URL Configuration**
   - Site URL: `https://gemevents.app`
   - Redirect URLs: `https://gemevents.app/**`
3. **Authentication → Providers →** enable Email (magic link). Turn signups off once your team is in.
4. **Storage** → confirm the `gem-media` bucket exists and is **private**
5. **Database → Replication** → add tables to the `supabase_realtime` publication for device sync
6. Send me the project URL and anon key and I'll wire `gem-api.js` in

The anon key is safe in the client *because* RLS is on. The **service_role** key must never reach the browser.

---

## 4. Installing it

**Settings → Data & storage → Install on this device** now covers all of this in
the app: an **Install** button where the browser offers one, the Share-sheet
instruction on iOS where it never will, and an *Installed* badge once it is.

- **iPhone/iPad** — Safari → Share → *Add to Home Screen*. Safari never fires
  `beforeinstallprompt`, so no in-app button can exist there; this is the only route.
- **Android** — Chrome offers it by itself, and the Settings row offers it too.
  The app deliberately does **not** `preventDefault()` the event, so Chrome's own
  prompt still appears — the in-app button is a second door, not a replacement.
- **Mac/Windows desktop** — Chrome/Edge show an install icon in the address bar.
  Installed, it opens in its own window with no browser chrome.

The manifest's three shortcuts (Today's tasks, Leads & Pipeline, Calendar) work
from a long-press on the installed icon; they are plain `/?view=…` URLs that the
app reads at boot.

---

## 5. What offline actually gives you

**Works offline:** the whole interface, and every planning record already on that device — timelines, checklists, guests, seating, vendors, budgets. This is what matters at a venue with no signal.

**Won't work offline:** signing in for the first time, syncing between devices, and loading records created on a *different* device since you last had signal.

**One thing to know before real use:** the prototype stores data per-device in the browser. Until the Supabase layer is wired in, two devices hold two separate sets of data. Offline-first sync with conflict resolution is a further step beyond the basic backend swap — worth planning for, since a planner editing on a phone at a venue while an assistant edits on a laptop is exactly the case that needs it.

---

## 6. Quick verification

After deploying, open Chrome DevTools on `https://gemevents.app`:

- **Application → Manifest** — no errors, icons listed
- **Application → Service Workers** — "activated and running"
- **Network → Offline**, then reload — the app should still load
- **Lighthouse → PWA** — should pass installability

If the worker doesn't register, it's almost always one of: not HTTPS, `sw.js` not at the root, or `sw.js` being cached.

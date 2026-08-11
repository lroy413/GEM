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

### Generating the icons
The app draws its own icons at runtime, but a deployed PWA wants real files. Open the app, paste this in the browser console, and three PNGs download:

```js
[192,512].forEach(s=>{const c=document.createElement('canvas');c.width=c.height=s;const x=c.getContext('2d');
const g=x.createLinearGradient(0,0,s,s);g.addColorStop(0,'#E3C579');g.addColorStop(.55,'#C2A052');g.addColorStop(1,'#A8842F');
x.fillStyle='#FAF2F3';x.fillRect(0,0,s,s);const m=s*.11,w=s-m*2;x.beginPath();x.roundRect(m,m,w,w,s*.18);x.fillStyle=g;x.fill();
x.fillStyle='#fff';x.textAlign='center';x.textBaseline='middle';x.font=`600 ${Math.round(s*.46)}px Georgia,serif`;
x.fillText('G',s/2,s/2+s*.02);const a=document.createElement('a');a.download=`icon-${s}.png`;a.href=c.toDataURL();a.click();});
```

For the maskable icon, re-run with `m = 0` (full bleed) and save as `icon-maskable-512.png` — Android crops maskable icons to a circle, so the safe area must be filled edge to edge.

---

## 2. Hosting

Any static host works. Cloudflare Pages is the easiest with a `.app` domain:

1. Cloudflare dashboard → **Workers & Pages → Create → Pages → Upload assets**
2. Drag the files above in, deploy
3. **Custom domains → Set up a domain →** `gemevents.app`
4. If the domain is registered elsewhere, point its nameservers at Cloudflare

**`.app` is on the HSTS preload list — HTTPS is mandatory, not optional.** That's actually convenient: service workers require HTTPS anyway, so you can't accidentally deploy a non-working configuration.

### Required headers
Add a `_headers` file at the root:

```
/sw.js
  Cache-Control: no-cache
  Service-Worker-Allowed: /

/index.html
  Cache-Control: no-cache

/icons/*
  Cache-Control: public, max-age=31536000, immutable
```

`no-cache` on `sw.js` matters — if the worker itself gets cached, users can be stuck on an old version indefinitely.

---

## 3. Supabase, when you're ready

1. Create the project, then run `01` → `05` from `/supabase` in order in the SQL Editor
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

- **iPhone/iPad** — Safari → Share → *Add to Home Screen*. iOS ignores `beforeinstallprompt`, so there's no in-app button; this is the only route.
- **Android** — Chrome shows an install prompt automatically.
- **Mac/Windows desktop** — Chrome/Edge show an install icon in the address bar. Installed, it opens in its own window with no browser chrome.

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

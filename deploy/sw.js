/* GEM service worker — offline shell for gemevents.app
 *
 * Strategy:
 *   app shell (HTML)  → network-first, fall back to cache when offline
 *   static assets     → cache-first, refreshed in the background
 *   Supabase / APIs   → never cached; the app's own local store covers offline
 *
 * Bump CACHE_VERSION on every deploy so clients pick up the new shell.
 */
const CACHE_VERSION = 'gem-v3';
const SHELL_CACHE  = `${CACHE_VERSION}-shell`;
const ASSET_CACHE  = `${CACHE_VERSION}-assets`;

/* Canonical paths only. Cloudflare's asset layer serves this site with
   html_handling "auto-trailing-slash", so /index.html 307s to / and
   /offline.html 307s to /offline. Caching the .html spellings would store
   redirects instead of documents, and the offline fallback would miss. */
const SHELL = [
  '/',
  '/manifest.webmanifest',
  '/offline'
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(SHELL_CACHE)
      .then((c) => c.addAll(SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => !k.startsWith(CACHE_VERSION)).map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('message', (e) => {
  if (e.data === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Never cache API traffic — stale planning data is worse than none.
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/rest/') ||
      url.pathname.startsWith('/auth/') ||
      url.pathname.startsWith('/storage/')) return;

  // Navigations: try the network so a deploy lands immediately, fall back
  // to the cached shell, then to a friendly offline page.
  if (req.mode === 'navigate') {
    e.respondWith(
      fetch(req)
        .then((res) => {
          // Only bank a real document; the SPA fallback returns 200 for unknown
          // paths, and an opaque or error response would poison the shell.
          if (res && res.ok && res.type === 'basic') {
            const copy = res.clone();
            caches.open(SHELL_CACHE).then((c) => c.put('/', copy));
          }
          return res;
        })
        .catch(() => caches.match('/').then((r) => r || caches.match('/offline')))
    );
    return;
  }

  // Everything else: serve from cache, refresh in the background.
  e.respondWith(
    caches.match(req).then((hit) => {
      const net = fetch(req)
        .then((res) => {
          if (res && res.status === 200 && res.type === 'basic') {
            const copy = res.clone();
            caches.open(ASSET_CACHE).then((c) => c.put(req, copy));
          }
          return res;
        })
        .catch(() => hit);
      return hit || net;
    })
  );
});

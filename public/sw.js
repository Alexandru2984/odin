/* ---------------------------------------------------------------------------
   Service worker
   ---------------------------------------------------------------------------
   Caches the app shell so a reload on a flaky connection still gives a
   terminal that can then reconnect on its own, instead of the browser's
   offline page.

   Deliberately narrow. A terminal is live by definition: the only thing worth
   caching is the shell itself, and serving a stale one would mean a client
   talking a protocol the server has moved on from. index.html is therefore
   network-first, so a deploy takes effect on the next load.
--------------------------------------------------------------------------- */

const VERSION = 'webos-v3';
const SHELL = [
  '/',
  '/style.css',
  '/app.js',
  '/desktop.js',
  '/vendor/xterm.js',
  '/vendor/xterm.css',
  '/vendor/addon-fit.js',
  '/favicon.svg',
  '/manifest.webmanifest',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(VERSION)
      .then((cache) => cache.addAll(SHELL))
      // A single asset failing to cache must not abort the install and leave
      // the page with no worker at all.
      .catch(() => undefined)
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)))
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;

  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // Same-origin only, and never the socket or the health endpoint.
  if (url.origin !== self.location.origin) return;
  if (url.pathname === '/ws' || url.pathname === '/healthz') return;

  const isDocument =
    request.mode === 'navigate' || request.destination === 'document';

  if (isDocument) {
    // Network-first: a deployed change must win over a cached shell.
    event.respondWith(
      fetch(request)
        .then((response) => {
          const copy = response.clone();
          caches.open(VERSION).then((cache) => cache.put(request, copy));
          return response;
        })
        .catch(() => caches.match(request).then((hit) => hit || caches.match('/')))
    );
    return;
  }

  // Everything else is a versioned-by-deploy static asset: serve it from the
  // cache when present, and refresh the entry in the background.
  event.respondWith(
    caches.match(request).then((hit) => {
      const network = fetch(request)
        .then((response) => {
          if (response && response.status === 200) {
            const copy = response.clone();
            caches.open(VERSION).then((cache) => cache.put(request, copy));
          }
          return response;
        })
        .catch(() => hit);

      return hit || network;
    })
  );
});

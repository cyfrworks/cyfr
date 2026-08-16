// CYFR service worker.
//
// A LiveView origin cannot serve a cached application shell — every page is
// rendered by the server and kept live over a socket — so navigations are
// network-only. What the worker caches is the same-origin static assets the
// shell needs (`/assets/*`, `/images/*`, `/fonts/*`), cache-first, so a
// reload on a slow link paints at once. Nothing under /mcp, /api, /auth, /t
// or /live is ever touched.
const CACHE = "cyfr-static-v1";
const CACHED_PREFIXES = ["/assets/", "/images/", "/fonts/"];

self.addEventListener("install", (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (request.mode === "navigate") return;
  if (!CACHED_PREFIXES.some((p) => url.pathname.startsWith(p))) return;

  event.respondWith(
    caches.match(request).then((hit) => {
      if (hit) return hit;
      return fetch(request).then((response) => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE).then((cache) => cache.put(request, copy));
        }
        return response;
      });
    })
  );
});

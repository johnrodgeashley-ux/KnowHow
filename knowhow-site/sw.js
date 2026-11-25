// KnowHow service worker: makes the site installable and opens it faster.
// - The page itself is always fetched fresh (so new versions show up right away);
//   the last copy is used only when there is no internet.
// - Libraries from CDNs and the app icons are cached.
// - Supabase (logins, data, files, calls) is never cached.
const CACHE = 'knowhow-v3';
const SHELL = ['/', '/manifest.webmanifest', '/assets/app-icon-192.png', '/assets/app-icon-512.png'];
const CDN = /^https:\/\/(cdnjs\.cloudflare\.com|unpkg\.com|cdn\.jsdelivr\.net|fonts\.googleapis\.com|fonts\.gstatic\.com)\//;

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

const offline = () => new Response(
  '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
  '<title>KnowHow</title><body style="margin:0;height:100vh;display:grid;place-items:center;background:#EEF2F8;' +
  'color:#0F2557;font-family:system-ui,sans-serif;text-align:center"><div><h1 style="margin:0 0 8px">You’re offline</h1>' +
  '<p style="margin:0 0 16px;color:#56607F">Connect to the internet to use KnowHow.</p>' +
  '<button onclick="location.reload()" style="border:0;border-radius:999px;padding:12px 22px;background:#C8102E;color:#fff;font-weight:600">Try again</button></div>',
  { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
);

const cacheFirst = (req) => caches.match(req).then((hit) => hit || fetch(req).then((res) => {
  if (res.ok || res.type === 'opaque') { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
  return res;
}));

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin === self.location.origin) {
    if (req.mode === 'navigate') {
      e.respondWith(
        fetch(req)
          .then((res) => { if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put('/', copy)); } return res; })
          .catch(() => caches.match('/').then((hit) => hit || offline()))
      );
      return;
    }
    if (url.pathname.startsWith('/assets/') || url.pathname === '/manifest.webmanifest') e.respondWith(cacheFirst(req));
    return;
  }
  if (CDN.test(req.url)) e.respondWith(cacheFirst(req));
  // Everything else (Supabase API, storage, realtime) goes straight to the network.
});

// Push notifications (sent by the Supabase "push" function), shown even when KnowHow is closed.
self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'KnowHow', {
    body: d.body || '',
    icon: '/assets/app-icon-192.png',
    badge: '/assets/app-icon-192.png',
    tag: d.tag || undefined,
    renotify: !!d.tag,
    data: { url: d.url || '/' },
  }));
});

// Tapping a notification brings KnowHow to the front (or opens it).
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
    for (const c of list) { if ('focus' in c) return c.focus(); }
    return self.clients.openWindow(url);
  }));
});

// Network first, cache fallback: once a page has loaded online, it also opens in airplane mode.
const V = 'v2';
const SB = 'https://rfenuwnboyktdprlmgct.supabase.co';

self.addEventListener('install', (e) => {
  self.skipWaiting();
  e.waitUntil(caches.open(V).then((c) => c.addAll(['index.html', 'student.html', 'style.css', 'shared.js', 'util.js', 'icon-192.png', 'fonts/inter.woff2', 'fonts/jetbrains-mono.woff2'])));
});
self.addEventListener('activate', (e) => e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== V).map((k) => caches.delete(k)))).then(() => clients.claim())));

self.addEventListener('fetch', (e) => {
  const r = e.request, u = new URL(r.url);
  // Supabase API calls are never cached; question images (public storage) are.
  if (r.method !== 'GET' || (u.origin === SB && !u.pathname.startsWith('/storage/v1/object/public/'))) return;
  e.respondWith(
    fetch(r)
      .then((res) => {
        if (res.ok || res.type === 'opaque') { const copy = res.clone(); caches.open(V).then((c) => c.put(r, copy)); }
        return res;
      })
      .catch(async () => (await caches.match(r)) || (r.mode === 'navigate' ? caches.match('student.html') : Response.error()))
  );
});

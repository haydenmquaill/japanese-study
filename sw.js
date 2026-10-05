/* 日本語辞典 — service worker: push notifications only (no offline caching).
   Deliberately no fetch handler: index.html is served fresh from the network every load, so a
   deploy is never masked by a cached shell. (Adding caching here would reintroduce exactly that.)
   If the app is open on screen the notification is skipped and handed to the page instead. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try{ d = e.data ? e.data.json() : {}; }catch(err){ d = { title:'日本語辞典', body: e.data ? e.data.text() : '' }; }
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type:'window', includeUncontrolled:true });
    const open = wins.filter(w => w.visibilityState==='visible');
    if(open.length){ open.forEach(w => w.postMessage({ type:'push', data:d })); return; }
    await self.registration.showNotification(d.title || '日本語辞典', {
      body: d.body || '', tag: d.tag || undefined, renotify: !!d.tag,
      icon: 'icons/icon-192.png', badge: 'icons/icon-192.png',
      data: { url: d.url || './' },
    });
  })());
});

// tapping a notification: bring the app forward (or open it) at the right place
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL(e.notification.data && e.notification.data.url || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type:'window', includeUncontrolled:true });
    const w = wins.find(x => x.url.startsWith(self.registration.scope));
    if(w){ await w.focus(); w.postMessage({ type:'open', url }); return; }
    await self.clients.openWindow(url);
  })());
});

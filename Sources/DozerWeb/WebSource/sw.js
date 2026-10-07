// sw.js — the dashboard's service worker. ONE job: a calm page when the window is opened (an installed
// app, a reload) while `doz ui` is not running, instead of the browser's error page. It is served at
// /sw.js (never cached by the browser: it is checked for an update on every navigation) and the asset
// compiler writes the hashed names of what it precaches and its cache's name — a new build is a new
// worker, which removes the old cache.
//
// What it NEVER does (the probe checks): cache or answer anything under /api (the event stream
// included), /terminal-frame, or any response with a cookie. It answers exactly two kinds of request:
//   · a top-level navigation of / whose network request FAILS → the precached /offline page;
//   · the precached files themselves (the offline page's style, script and icon) → from its cache.
// Everything else gets no respondWith() at all: the network, exactly as without a worker.
'use strict';

const CACHE = "doz-offline-@build@";
const OFFLINE = "/offline";
const PRECACHE = ["/offline", "/offline.css", "/offline.js", "/icons/icon.svg"];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(PRECACHE)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (event) => {
  const r = event.request;
  if (r.method !== 'GET') return;
  const url = new URL(r.url);
  if (url.origin !== self.location.origin) return;
  if (r.mode === 'navigate' && r.destination === 'document' && url.pathname === '/') {
    event.respondWith(fetch(r).catch(() => caches.open(CACHE).then((c) => c.match(OFFLINE)).then((m) => m || Response.error())));
    return;
  }
  if (url.pathname !== OFFLINE && PRECACHE.includes(url.pathname)) {
    event.respondWith(caches.open(CACHE).then((c) => c.match(url.pathname)).then((m) => m || fetch(r)));
  }
});

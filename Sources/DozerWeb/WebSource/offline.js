// offline.js — the page the service worker shows (an installed app opened, or a reload) while doz ui is
// not running. Every 2 s it asks doz ui's session route (through the network: the worker never
// answers /api); once doz ui answers at all — 200 (still signed in) or 401 (the page will offer its
// sign-in) — it reloads the SAME address, which then loads the dashboard (with its #/… view).
'use strict';

let tries = 0;
async function look() {
  tries++;
  try {
    const r = await fetch('/api/v1/session', { credentials: 'same-origin', cache: 'no-store' });
    if (r.status === 200 || r.status === 401) { location.reload(); return; }
  } catch (_) { /* not running yet */ }
  const s = document.getElementById('off-status');
  if (s && tries === 15) s.textContent = 'This window reconnects by itself — still waiting for doz ui.';
  setTimeout(look, 2000);
}
setTimeout(look, 1000);

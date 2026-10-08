// core/api — The server: one typed request (fetch, the CSRF header, the error shape).
import { upcall } from './hooks.js';
import { state } from './state.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const signedOut = upcall('signedOut');

// ── HTTP ────────────────────────────────────────────────────────────────────
class HttpError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}
export async function api(path, opts = {}) {
  const init = { method: opts.method || 'GET', credentials: 'same-origin', cache: 'no-store', headers: {} };
  if (init.method !== 'GET') init.headers['X-Doz-CSRF'] = state.csrf || '';
  if (opts.bearer) init.headers['Authorization'] = 'Bearer ' + opts.bearer;
  if (opts.json !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(opts.json);
  }
  const r = await fetch('/api/v1/' + path, init);
  if (r.status === 204) return null;
  let body = null;
  try { body = await r.json(); } catch (_) { /* not JSON */ }
  if (!r.ok) {
    const e = body && body.error ? body.error : { code: 'http-' + r.status, message: 'HTTP ' + r.status };
    if (r.status === 401) signedOut(e.message, e.code);
    throw new HttpError(r.status, e.code, e.message);
  }
  return body;
}

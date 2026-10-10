// components/notices — Notices: toasts (successes), the page notices, a sandbox's status line — a failure is never only a toast (603).
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { icon } from '../dom/icons-75c107270d336b51.js';
import { opEnded } from '../core/operations-c7eeae66c46d4582.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { callout } from './callout-48fdacc012091bbe.js';

/// 603 (E7): a toast acknowledges a success (or says something worth knowing) and goes after 4 s. A FAILURE is
/// never only a toast: it is said where the action was started and stays until dismissed or fixed — in its
/// dialog (which stays open), its sandbox's status line (the sandbox page's bar, the Sandboxes row), the
/// step's own error slot, or the page notices at the top of the page. `toast(text, true)` is that last one.
export function toast(text, bad, iconName) {
  if (bad) { pageFailure(text); return h('div'); }
  const t = h('div', { class: 'toast', role: 'status' }, icon(iconName || 'check'), h('span', null, text));
  $('toasts').append(t);
  setTimeout(() => t.remove(), 4000);
  return t;
}
/// The page notices (#notice, at the top of main, sticky): a failure with no closer home, or one whose home
/// is not on screen. Each stays until dismissed; at most the newest five.
state.failures = new Map();
export function pageFailure(text, opts = {}) {
  const key = opts.key || String(text);
  state.failures.delete(key);
  state.failures.set(key, { text: String(text), tone: opts.tone || 'bad', title: opts.title || null, actions: opts.actions || null });
  while (state.failures.size > 5) state.failures.delete(state.failures.keys().next().value);
  paintFailures();
}
function paintFailures() {
  const box = $('notice');
  box.hidden = state.failures.size === 0;
  box.replaceChildren(...[...state.failures.entries()].map(([key, f]) => callout(f.tone, { compact: true, title: f.title, body: f.text,
    actions: f.actions, attrs: { 'data-failure': key }, dismiss: () => { state.failures.delete(key); paintFailures(); } })));
}
/// A page notice that is no longer true (612: an agent that was blocked works again) goes without a click.
export function dropPageNotice(key) {
  if (state.failures.delete(key)) paintFailures();
}
/// A failure about a sandbox: its status line when one is on screen (it stays there until dismissed, or until
/// the next operation on it), else the page notices.
state.sbxFail = new Map();
function statusSlotShown(name) { return !!name && [...document.querySelectorAll('[data-op-for]')].some((el) => el.dataset.opFor === name && el.getClientRects().length > 0); }
export function failureFor(name, text) {
  if (statusSlotShown(name)) { state.sbxFail.set(name, { text: String(text), at: Date.now() }); paintRowOps(); }
  else pageFailure(name ? name + ': ' + text : text);
}
export function opFailed(op) {
  if (!statusSlotShown(op.sandbox)) pageFailure(op.label + ': ' + op.text, { key: 'op:' + op.id });
}
// 599 (594.B1/B2): what a session bridge did — "hello copied 42 chars", "hello opened https://… in your
// browser". Shown every time (a copy is the one thing an agent can hand the person unasked); two views of
// one session (a pane and a tile) are told the same thing once. A refusal is shown as a failure.
const recentBridgeNotices = new Map();
export function bridgeNotice(kind, text) {
  const k = String(kind).slice(0, 32), s = String(text).slice(0, 400), now = Date.now();
  for (const [key, at] of recentBridgeNotices) if (now - at > 2000) recentBridgeNotices.delete(key);
  if (recentBridgeNotices.has(k + '\n' + s)) return;
  recentBridgeNotices.set(k + '\n' + s, now);
  if (/-(refused|off)$/.test(k)) { pageFailure(s, { tone: 'warn', key: 'bridge:' + k + ':' + s }); return; }
  const t = toast(s, false, 'info');
  t.classList.add('bridge');
  t.dataset.bridge = k;
}
/// The newest operation of each sandbox, shown under its name in the list (live, without a refetch).
/// A running operation counts its seconds, so a two-minute first start (pull, flatten, bake) is
/// visibly alive; the text is the host's latest step.
/// 603: a failure stays (until dismissed, or the next operation on the sandbox); a success shows for a minute.
state.acked = new Set();
state.pageAt = Date.now();      // a failure from before this page loaded shows only as long as a success would
export function paintRowOps() {
  for (const el of document.querySelectorAll('[data-op-for]')) {
    const name = el.dataset.opFor;
    const ops = [...state.ops.values()].filter((o) => o.sandbox === name);
    // While something runs, the OLDEST running operation (a start that others wait behind) — its
    // steps are the news; otherwise the newest outcome.
    const running = ops.filter((o) => o.state === 'running');
    let o = running.length ? running[0] : ops[ops.length - 1];
    const fail = state.sbxFail.get(name);
    const oAt = o ? opEnded(o) : 0;
    let kind = 'none', text = '';
    if (o && o.state === 'running') {
      const secs = Math.max(0, Math.round((Date.now() - new Date(o.startedAt).getTime()) / 1000));
      const more = running.length > 1 ? ' · then ' + running.slice(1).map((x) => x.action).join(', ') : '';
      kind = 'running'; text = o.action + ' · ' + secs + ' s — ' + o.text + more;
    } else if (fail && (!o || fail.at >= oAt)) {
      kind = 'failed'; text = fail.text; o = null;
    } else if (o && o.state === 'failed' && !state.acked.has(o.id) && (oAt >= state.pageAt || Date.now() - oAt < 60000)) {
      kind = 'failed'; text = o.text;
    } else if (o && o.state === 'done' && Date.now() - oAt < 60000) {
      kind = 'done'; text = o.text;
    } else if (o && o.state === 'interrupted' && Date.now() - oAt < 60000) {
      kind = 'interrupted'; text = o.text;           // 605: ended while doz ui restarted, outcome not seen
    }
    const key = kind + '|' + text;
    if (el.dataset.painted === key) continue;
    el.dataset.painted = key;
    if (!el.dataset.banner) {
      el.textContent = kind === 'none' ? '' : (kind === 'running' ? '… ' : kind === 'done' ? '✓ ' : kind === 'interrupted' ? '– ' : '✕ ') + text;
      el.className = 'row-op' + (kind === 'none' ? ' empty-op' : ' op-' + kind);
      continue;
    }
    // The sandbox page's status slot: a quiet line while it runs, a callout when it ended.
    el.className = 'op-banner' + (kind === 'none' ? ' empty-op' : ' op-' + kind);
    if (kind === 'none') { el.replaceChildren(); continue; }
    if (kind === 'running') { el.replaceChildren(h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), h('span', { class: 'op-text' }, text)); continue; }
    const opId = o ? o.id : null;
    el.replaceChildren(callout(kind === 'done' ? 'ok' : kind === 'interrupted' ? 'info' : 'bad', { compact: true, body: text, dismiss: kind === 'failed' ? () => {
      if (opId) state.acked.add(opId); else state.sbxFail.delete(name);
      el.dataset.painted = '';
      paintRowOps();
    } : null }));
  }
}
// ── 594 W18: the host and the doz ui server, watched ─────────────────────────
// The footer holds two facts: this page's link to the `doz ui` server (#live) and the host's state and
// build (#host-live). A banner says each transition once: the host stopped (hibernated), died (its
// sandboxes shut down), came back as another build; doz ui stopped (the page retries on its own).
export function banner(key, kind, parts, actions = []) {
  const box = $('banners');
  // 603: a banner is the callout's banner variant (a surface with the tone's edge), dismissible.
  const el = callout(kind || 'info', { banner: true, cls: 'b-' + (kind || 'info'), bodyCls: 'b-text', body: parts, actions, dismiss: true,
    attrs: { 'data-banner': key }, role: kind === 'bad' ? 'alert' : 'status' });
  const old = box.querySelector('[data-banner="' + key + '"]');
  if (old) old.replaceWith(el); else box.append(el);
  return el;
}
export function dropBanner(key) {
  const el = $('banners').querySelector('[data-banner="' + key + '"]');
  if (el) el.remove();
}

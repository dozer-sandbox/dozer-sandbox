// views/sandbox-layout — The terminal layout (593 §9): kept by the host, restored once per page load; saved panes go live in place.
import { api } from '../core/api-1817573a49f0ab85.js';
import { opRunningFor, sandboxBusy, sandboxPhase, SAVED_PHASES } from '../core/sandboxes-d24059f81c7268c1.js';
import { setting, terminalsAllowed } from '../core/settings-171e705abeccb983.js';
import { state } from '../core/state-6efaa5d4aa08116b.js';
import { pageTerminals, sview, terminals } from '../core/terminals-fa5cf7fc28fdb48f.js';
import { closeTerminal, goLive, newTerm, paintCover } from '../components/terminal-154bdbfa793b8202.js';
import { renderTerminals } from './sandbox-terminals-eb41db68820b218c.js';

// ── the terminal layout (593 §9 — S1): the HOST keeps each sandbox's panes (`terminal-layout`, beside
// its doz.json), so a UI restart, a reload or another browser shows the same ones. The page writes it
// (one typed, CSRF-checked POST, debounced) whenever its panes change — only once it has restored the
// stored one, so arriving never overwrites it with an empty page.
function layoutOf(name) {
  const v = sview(name);
  const kept = pageTerminals(name).filter((t) => t.session && !t.ended && !t.errorText);
  const panes = (v.split ? [0, 1] : [0]).map((pi) => {
    const inPane = kept.filter((t) => (v.split ? t.pane : 0) === pi).slice(0, 16);
    const idx = inPane.findIndex((t) => t.id === v.selected[pi]);
    return { tabs: inPane.map((t) => ({ session: t.session, mode: t.mode === 'watch' ? 'watch' : 'interactive' })), selected: idx >= 0 ? idx : null };
  });
  return { split: !!v.split, focusedPane: v.split && v.focusedPane === 1 ? 1 : 0, panes };
}
export function persistLayout(name) {
  const v = sview(name);
  if (!v.restored || v.restoring || !setting('ui.terminals', true)) return;
  // Shut down: no sessions, no panes to remember (the host cleared the layout with the shutdown).
  if (sandboxPhase(name) === 'off') return;
  const body = JSON.stringify(layoutOf(name));
  if (body === v.savedLayout) return;
  v.savedLayout = body;
  clearTimeout(v.layoutTimer);
  v.layoutTimer = setTimeout(() => {
    api('sandboxes/' + name + '/layout', { method: 'POST', json: JSON.parse(body) })
      .catch(() => { if (v.savedLayout === body) v.savedLayout = null; });
  }, 400);
}
/// Saved sessions of a sandbox that is not running (`sessions` answers from its saved screens).
export async function savedRows(name) {
  try { return (await api('sandboxes/' + name + '/sessions')).filter((r) => r.saved); } catch (_) { return []; }
}
/// A tab (not yet loaded: `lazy` — its engine starts the first time it is shown).
function addTab(name, session, mode, pane, saved) {
  const t = newTerm(name, session, mode);
  t.pane = pane;
  t.saved = saved ? { savedAt: saved.savedAt, reason: saved.savedReason } : null;
  t.lazy = true;
  paintCover(t);
  return t;
}
/// A saved screen as a tab of the sandbox's page (the details' Show, a grid tile's click).
export function openSavedTerminal(name, row, pane) {
  if (!terminalsAllowed() || !row) return;
  const v = sview(name);
  const have = pageTerminals(name).find((t) => t.session === row.name && t.saved);
  const t = have || addTab(name, row.name, 'interactive', v.split ? (pane ?? v.focusedPane) : 0, row);
  v.selected[t.pane] = t.id;
  renderTerminals();
}
/// Restore the stored layout: a RUNNING sandbox's tabs whose sessions run attach; a paused, asleep or
/// hibernated one shows every session it has a saved screen of (S3) — the layout's first, in their panes.
export async function restorePanes(name) {
  const v = sview(name);
  if (v.restored || v.restoring) return;
  v.restoring = true;
  try {
    const s = state.sbx;
    if (!s || !s.d || !setting('ui.terminals', true)) return;
    const i = s.d.info;
    // Under way (booting, pausing, hibernating, waking…): what to show is not known yet — the next
    // refresh that finds it settled restores (refreshSandbox), and nothing is written meanwhile.
    if (i.busy || i.phase === 'booting' || opRunningFor(name)) { v.deferred = true; return; }
    v.deferred = false;
    let layout = null;
    try { layout = await api('sandboxes/' + name + '/layout'); } catch (_) { /* none */ }
    const plan = [];
    if (i.phase === 'running' && !i.busy) {
      const live = new Set((s.d.sessions || []).filter((x) => !x.ended).map((x) => x.name));
      if (layout) layout.panes.forEach((p, pi) => p.tabs.forEach((tb) => { if (live.has(tb.session)) plan.push({ pane: pi, session: tb.session, mode: tb.mode }); }));
    } else if (SAVED_PHASES.includes(i.phase)) {        // shut down or failed: no sessions, no screens
      const rows = new Map((await savedRows(name)).map((r) => [r.name, r]));
      if (layout) {
        layout.panes.forEach((p, pi) => p.tabs.forEach((tb) => {
          const r = rows.get(tb.session);
          if (r) { plan.push({ pane: pi, session: tb.session, mode: tb.mode, saved: r }); rows.delete(tb.session); }
        }));
      }
      for (const r of rows.values()) plan.push({ pane: 0, session: r.name, mode: 'interactive', saved: r });
    }
    // Something was opened meanwhile (a click, the grid), or the page moved on: leave it be.
    if (!plan.length || pageTerminals(name).length || state.view !== 'sandbox' || state.param !== name) return;
    const split = !!(layout && layout.split && plan.some((p) => p.pane === 1) && plan.some((p) => p.pane === 0));
    const made = plan.map((p) => addTab(name, p.session, p.mode, split ? p.pane : 0, p.saved));
    v.split = split;
    for (const pi of [0, 1]) {
      const inPane = made.filter((t) => t.pane === pi);
      if (!inPane.length) { v.selected[pi] = null; continue; }
      const lp = layout && layout.panes[pi];
      const want = lp && lp.selected !== null && lp.selected !== undefined ? lp.tabs[lp.selected] : null;
      v.selected[pi] = (want && inPane.find((t) => t.session === want.session && t.mode === want.mode) || inPane[0]).id;
    }
    v.focusedPane = split && layout.focusedPane === 1 ? 1 : 0;
    v.restoredAny = true;
  } finally {
    v.restoring = false;
    if (!v.deferred) v.restored = true;
    if (state.view === 'sandbox' && state.param === name) renderTerminals();
  }
}
/// After the sandbox's state changed: saved panes of a sandbox that runs go live (their session runs)
/// or close (it is gone); the others repaint their cover (the phase, the wake hint). A sandbox that is
/// SHUT DOWN shows no session screens anywhere (owner, 2026-09-30): every pane of it — saved, or a live
/// one whose session died with the VM — closes, and the area shows the off state. (A FAILED start keeps
/// its boot view: that is where the failure is.)
export function promoteSaved(name, live) {
  const phase = sandboxPhase(name);
  const running = phase === 'running' && !sandboxBusy(name);
  const gone = phase === 'off' && !sandboxBusy(name);
  // The plain off state is one area, not an empty split.
  if (gone && !pageTerminals(name).some((t) => t.bootIntent)) { const v = sview(name); v.split = false; v.focusedPane = 0; }
  for (const t of [...terminals.values()]) {
    if (t.sandbox !== name || t.bootlog) continue;       // a Boot log terminal is never a session's
    if (gone && !t.bootIntent) { if (t.grid) continue; closeTerminal(t.id); continue; }
    if (!t.saved) continue;
    if (running && live) {
      if (live.includes(t.session)) goLive(t);
      else if (!t.grid) closeTerminal(t.id);
    } else {
      paintCover(t);
    }
  }
}

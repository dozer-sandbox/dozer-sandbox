// views/sessions — All sessions: the grid (593).
import { $, h } from '../dom/h.js';
import { icon, PHASE_GLYPH } from '../dom/icons.js';
import { api } from '../core/api.js';
import { when } from '../core/format.js';
import { SAVED_PHASES, VERBS } from '../core/sandboxes.js';
import { saveSetting, setting } from '../core/settings.js';
import { state } from '../core/state.js';
import { btn } from '../components/button.js';
import { lifecycle } from '../components/lifecycle.js';
import { renderNavSandboxes } from '../components/nav.js';
import { pageFailure } from '../components/notices.js';
import { bootTerm, closeTerminal, goLive, newTerm, paintCover } from '../components/terminal.js';

// ── All sessions: the grid (593) ────────────────────────────────────────────
// A tile per session of every RUNNING sandbox — a live, read-only (watch) view: the same ticket,
// socket and frame as any terminal, laid out at a fixed virtual size (960 × 560) and scaled, so it
// is a thumbnail of the session at its own geometry. A sandbox that is not running is one static
// tile (no engine, no socket: an open grid never keeps a host alive for it). Engines exist only
// for tiles on screen (IntersectionObserver), and at most ui.grid_live_tiles at once. Sessions are
// listed on entry, on Refresh, and on a live change at most every 10 s (listing asks the guest).
const grid = { built: false, active: false, tiles: new Map(), io: null, sandbox: '', phase: '', lastList: 0, listTimer: null,
               sessions: {}, scheduled: false, status: null, body: null };
const TILE_SCALE = { small: 0.3, medium: 0.42, large: 0.62 };

function gridBuild() {
  const root = $('grid');
  const sandboxSel = h('select', { 'aria-label': 'Sandbox' });
  const phaseSel = h('select', { 'aria-label': 'Phase' }, [['', 'every phase'], ['running', 'running'], ['paused', 'paused'], ['asleep', 'asleep'],
    ['hibernated', 'hibernated'], ['off', 'shut down'], ['failed', 'failed']].map(([v, l]) => h('option', { value: v }, l)));
  const sizeSel = h('select', { 'aria-label': 'Tile size' }, ['small', 'medium', 'large'].map((s) => h('option', { value: s }, s + ' tiles')));
  sandboxSel.addEventListener('change', () => { grid.sandbox = sandboxSel.value; gridRender(); });
  phaseSel.addEventListener('change', () => { grid.phase = phaseSel.value; gridRender(); });
  sizeSel.addEventListener('change', () => {
    gridApplySize(sizeSel.value);
    saveSetting('ui.grid_tile_size', sizeSel.value).catch((e) => pageFailure('ui.grid_tile_size was not saved: ' + (e.message || e)));
  });
  grid.status = h('span', { class: 'grid-status', role: 'status' });
  grid.body = h('div', { class: 'tiles' });
  grid.sandboxSel = sandboxSel;
  grid.sizeSel = sizeSel;
  root.replaceChildren(
    h('div', { class: 'head' }, h('h1', null, 'All sessions'), h('div', { class: 'actions' }, btn('Refresh', () => gridRefresh(true), { small: true }))),
    h('p', { class: 'sub' }, 'Every session of every running sandbox, live and read-only. Click one to open it on its sandbox’s page.'),
    h('div', { class: 'toolbar' }, sandboxSel, phaseSel, sizeSel, grid.status),
    grid.body);
  grid.io = new IntersectionObserver((entries) => {
    for (const e of entries) { const tile = grid.tiles.get(e.target.dataset.key); if (tile) tile.visible = e.isIntersecting; }
    gridSchedule();
  }, { root: null, rootMargin: '100px' });
  grid.built = true;
}
function gridApplySize(size) {
  const s = TILE_SCALE[size] ? size : 'medium';
  for (const k of Object.keys(TILE_SCALE)) $('grid').classList.toggle('tiles-' + k, k === s);
  if (grid.sizeSel) grid.sizeSel.value = s;
}
export async function gridEnter() {
  if (!grid.built) gridBuild();
  grid.active = true;
  gridApplySize(setting('ui.grid_tile_size', 'medium'));
  await gridRefresh(true);
}
export function gridLeave() {
  if (!grid.active) return;
  grid.active = false;
  clearTimeout(grid.listTimer);
  for (const tile of grid.tiles.values()) detachTile(tile);
}
export async function gridRefresh(force) {
  if (!grid.active) return;
  const wait = 10000 - (Date.now() - grid.lastList);
  if (!force && wait > 0) {
    clearTimeout(grid.listTimer);
    grid.listTimer = setTimeout(() => gridRefresh(true), wait);
    return;
  }
  grid.lastList = Date.now();
  let o;
  try { o = await api('overview'); } catch (e) { pageFailure(e.message || String(e), { key: 'grid' }); return; }
  state.overview = o;
  renderNavSandboxes();
  // A running sandbox's sessions come from its guest; any other's from its saved screens (593 §9 — S3:
  // read from the sandbox's directory, nothing woken).
  await Promise.all(o.sandboxes.filter((s) => s.phase !== 'booting').map(async (s) => {
    try {
      const rows = await api('sandboxes/' + s.name + '/sessions');
      grid.sessions[s.name] = s.phase === 'running'
        ? rows.filter((r) => !r.ended && !r.saved).map((r) => ({ name: r.name, command: r.command }))
        : rows.filter((r) => r.saved).map((r) => ({ name: r.name, command: r.command, saved: r }));
    } catch (_) { /* it changed meanwhile: its last list stays */ }
  }));
  if (!grid.active) return;
  gridRender();
}
/// The tiles the filters ask for, made to match the DOM (a kept tile keeps its live terminal).
function gridRender() {
  const o = state.overview;
  if (!o) return;
  const names = o.sandboxes.map((s) => s.name).sort();
  grid.sandboxSel.replaceChildren(h('option', { value: '' }, 'every sandbox'), ...names.map((n) => h('option', { value: n }, n)));
  grid.sandboxSel.value = names.includes(grid.sandbox) ? grid.sandbox : '';
  const want = [];
  for (const s of o.sandboxes.slice().sort((a, b) => a.name.localeCompare(b.name))) {
    if (grid.sandbox && s.name !== grid.sandbox) continue;
    if (grid.phase && s.phase !== grid.phase) continue;
    if (s.phase === 'running') {
      const live = (grid.sessions[s.name] || []).filter((x) => !x.saved);
      for (const x of live) want.push({ key: s.name + '/' + x.name, sandbox: s.name, session: x.name, command: x.command, s });
      if (!live.length) want.push({ key: s.name + '/', sandbox: s.name, session: null, s, none: true });
    } else {
      // 593 §9 (S3): its saved screens, a tile each (same key as the live tile: waking swaps it in place).
      // Shut down or failed: no tiles of sessions (owner, 2026-09-30) — one static tile with Start.
      const saved = !SAVED_PHASES.includes(s.phase) ? [] : (grid.sessions[s.name] || []).filter((x) => x.saved);
      for (const x of saved) want.push({ key: s.name + '/' + x.name, sandbox: s.name, session: x.name, command: x.command, s, saved: x.saved });
      if (!saved.length) want.push({ key: s.name + '/', sandbox: s.name, session: null, s });
    }
  }
  const keep = new Set(want.map((w) => w.key));
  for (const [k, tile] of grid.tiles) if (!keep.has(k)) { detachTile(tile); grid.io.unobserve(tile.el); tile.el.remove(); grid.tiles.delete(k); }
  let prev = null;
  for (const w of want) {
    let tile = grid.tiles.get(w.key);
    if (!tile) { tile = makeTile(w); grid.tiles.set(w.key, tile); grid.io.observe(tile.el); }
    paintTile(tile, w);
    const next = prev ? prev.nextSibling : grid.body.firstChild;
    if (next !== tile.el) grid.body.insertBefore(tile.el, next);
    prev = tile.el;
  }
  if (!want.length) grid.body.replaceChildren(h('div', { class: 'empty' }, o.sandboxes.length ? 'Nothing matches the filters.' : 'No sandboxes yet.'));
  else for (const n of [...grid.body.children]) if (!n.dataset.key) n.remove();
  gridSchedule();
}
function makeTile(w) {
  const dot = h('span', { class: 'ph-dot', 'aria-hidden': 'true' });
  const title = h('span', { class: 'tile-title' });
  const phase = h('span', { class: 'tile-phase' });
  const act = h('span', { class: 'tile-act' });
  const screen = h('div', { class: 'tile-screen' });
  const note = h('div', { class: 'tile-note', hidden: true });
  const hit = h('button', { type: 'button', class: 'tile-hit', title: 'Open on its sandbox’s page',
                            'aria-label': 'Open ' + (w.session ? w.sandbox + ' · ' + w.session : w.sandbox) + ' on its page' },
    h('span', { class: 'tile-hit-icon' }, icon('maximize-2')));
  const el = h('div', { class: 'tile', 'data-key': w.key, 'data-sandbox': w.sandbox, 'data-session': w.session || '' },
    h('div', { class: 'tile-head' }, dot, title, phase, act),
    h('div', { class: 'tile-body' }, screen, note, hit));
  const tile = { key: w.key, sandbox: w.sandbox, session: w.session, el, dot, title, phase, act, screen, note, hit, term: null, visible: false, liveable: !!w.session };
  hit.addEventListener('click', () => { location.hash = '#/sandbox/' + w.sandbox + (tile.session ? '/' + tile.session : ''); });
  return tile;
}
function paintTile(tile, w) {
  const s = w.s;
  tile.liveable = !!w.session;
  // 593 §9: a tile is live (a watch terminal), saved (the session's saved screen — an engine, no
  // socket) or static. Saved → live swaps in place; live → saved lets go of the socket first (an
  // open grid never keeps a host alive for a sandbox that does not run).
  const kind = !w.session ? 'static' : w.saved ? 'saved' : 'live';
  if (tile.term && tile.kind && tile.kind !== kind) {
    if (tile.kind === 'saved' && kind === 'live' && tile.term.saved) goLive(tile.term);
    else detachTile(tile);
  }
  tile.kind = kind;
  tile.saved = w.saved || null;
  if (tile.term && tile.term.saved && w.saved) paintCover(tile.term);
  tile.el.dataset.kind = kind;
  tile.el.dataset.phase = s.phase;
  tile.dot.className = 'ph-dot ph-' + s.phase;
  tile.title.textContent = w.session ? w.sandbox + ' · ' + w.session : w.sandbox;
  tile.title.title = w.command ? w.command : '';
  tile.phase.textContent = w.saved ? s.phaseLabel + ' · saved ' + when(w.saved.savedAt) : s.phaseLabel;
  const verb = { paused: 'resume', asleep: 'wake', hibernated: 'wake', off: 'start', failed: 'start' }[s.phase];
  tile.act.replaceChildren(verb && (!w.session || w.saved) && !s.busy ? btn(VERBS[verb][0], () => lifecycle(verb, w.sandbox), { small: true }) : '');
  if (!w.session) {
    const known = grid.sessions[w.sandbox] || [];
    tile.note.hidden = false;
    tile.note.className = 'tile-note static';
    tile.note.replaceChildren(
      ...(!w.none && PHASE_GLYPH[s.phase] ? [h('div', { class: 'tc-glyph' }, icon(PHASE_GLYPH[s.phase]))] : []),   // (no null: replaceChildren writes it as text)
      h('div', { class: 'tile-note-head' }, w.none ? 'No sessions running' : s.phaseLabel),
      h('div', null, w.none ? 'Open one from its page.' : s.phase === 'off' ? 'Starting boots it fresh — new sessions.'
        : known.length ? 'Sessions when it last ran: ' + known.map((x) => x.name).join(', ') : 'Its sessions are listed while it runs.'));
  }
}
export function gridSchedule() {
  if (grid.scheduled) return;
  grid.scheduled = true;
  setTimeout(() => {
    grid.scheduled = false;
    if (!grid.active) return;
    const cap = setting('ui.grid_live_tiles', 8);
    const tiles = [...grid.body.children].map((el) => grid.tiles.get(el.dataset.key)).filter(Boolean);
    for (const t of tiles) if (t.term && (!t.visible || !t.liveable)) detachTile(t);
    // A lowered cap: the live tiles beyond it (the later ones, in page order) let go.
    tiles.filter((t) => t.term).slice(cap).forEach(detachTile);
    let live = tiles.filter((t) => t.term).length;
    let capped = 0;
    for (const t of tiles) {
      if (!t.liveable) continue;
      if (t.term) { t.note.hidden = true; continue; }
      if (!t.visible) { t.note.hidden = false; t.note.className = 'tile-note'; t.note.textContent = 'Off screen — not live'; continue; }
      if (live < cap) { attachTile(t); live++; t.note.hidden = true; continue; }
      capped++;
      t.note.hidden = false;
      t.note.className = 'tile-note capped';
      t.note.replaceChildren(h('div', { class: 'tile-note-head' }, 'Not live'),
        h('div', null, live + ' tiles are live (the cap: Settings › ui.grid_live_tiles). Scroll, filter, or click to open.'));
    }
    const total = tiles.filter((t) => t.liveable).length;
    grid.status.textContent = total + ' session' + (total === 1 ? '' : 's') + ' · ' + live + ' live' + (capped ? ' · ' + capped + ' more on screen not live (cap ' + cap + ')' : '');
    grid.el = grid.body;
    $('grid').dataset.live = String(live);
    $('grid').dataset.capped = String(capped);
  }, 50);
}
function attachTile(tile) {
  if (!setting('ui.terminals', true)) return;
  const t = newTerm(tile.sandbox, tile.session, 'watch');
  t.grid = true;
  if (tile.saved) t.saved = { savedAt: tile.saved.savedAt, reason: tile.saved.savedReason };
  tile.term = t;
  paintCover(t);
  tile.screen.append(t.els.wrap);
  bootTerm(t, 13);
}
function detachTile(tile) {
  if (!tile.term) return;
  const t = tile.term;
  tile.term = null;
  closeTerminal(t.id);                                   // the socket closes; the frame and its engine go
}

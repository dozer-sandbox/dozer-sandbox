// core/measure — Resources/Lineage measurements (595): taken on arrival, Refresh and an operation's end.
import { upcall } from './hooks-a4b871a481b363cd.js';
import { api } from './api-0a712b05e0caf823.js';
import { state } from './state-c0289349b457ba56.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const paintResTotal = upcall('paintResTotal');

/// A measurement (the Resources report, the lineage): read when a page is arrived at, on Refresh and
/// when an operation ends — never on a live update (it reads every disk's extent map).
state.measured = { stale: new Set(['resources', 'tree']), resources: null, tree: null };
export function remeasure() { state.measured.stale.add('resources'); state.measured.stale.add('tree'); }
export async function measured(key, path) {
  if (state.measured[key] && !state.measured.stale.has(key)) return state.measured[key];
  const v = await api(path);
  state.measured[key] = v;
  state.measured.stale.delete(key);
  if (key === 'resources') paintResTotal(v);
  return v;
}
let resTotalTimer = null;
/// The nav's total, measured a moment after an operation ends (or at load) — never on a live update.
export function scheduleResTotal(delay = 2000) {
  clearTimeout(resTotalTimer);
  resTotalTimer = setTimeout(async () => {
    if (state.view === 'resources') return;            // the page measures (and paints the total) itself
    try { await measured('resources', 'resources'); } catch (_) { /* the last total */ }
  }, delay);
}

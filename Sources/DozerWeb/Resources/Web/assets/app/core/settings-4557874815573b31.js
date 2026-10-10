// core/settings — Settings (591): the closed schema's values as the server reports them, read and changed.
import { upcall } from './hooks-a4b871a481b363cd.js';
import { api } from './api-129e35835156aceb.js';
import { state } from './state-c0289349b457ba56.js';
import { SPLIT_KINDS, termUI } from './terminals-fa5cf7fc28fdb48f.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const pageFailure = upcall('pageFailure'), paintSplitButton = upcall('paintSplitButton');

// ── settings (591) ──────────────────────────────────────────────────────────
// doz.toml, as the UI process reads it (GET /api/v1/settings, every value with its default, source and
// description). A change is one typed, CSRF-checked POST {key, value} or {key, reset: true}; the
// server checks the key against its closed schema and the value against the key's type and range,
// writes the file, and answers the new report — the page re-reads it, so a ui.* setting applies at once.
export function setting(key, fallback) {
  const r = state.settings && state.settings.byKey[key];
  return r ? r.value : fallback;
}
export function adoptSettings(report) {
  state.settings = { report, byKey: Object.fromEntries(report.settings.map((r) => [r.key, r])) };
  const theme = setting('ui.theme', 'auto');
  if (theme === 'light' || theme === 'dark') document.documentElement.dataset.theme = theme;
  else delete document.documentElement.dataset.theme;
  const split = setting('ui.split_default', 'shell');
  termUI.splitKind = SPLIT_KINDS[split] ? split : 'shell';
  paintSplitButton();
}
export async function loadSettings() {
  try { adoptSettings(await api('settings')); } catch (_) { /* the defaults, until the next read */ }
}
export async function saveSetting(key, value) { adoptSettings(await api('settings', { method: 'POST', json: { key, value } })); }
export async function resetSetting(key) { adoptSettings(await api('settings', { method: 'POST', json: { key, reset: true } })); }
/// The settings' ui.boot_view_on_start (and a boot view needs browser terminals).
export function bootViewOnStart() { return setting('ui.boot_view_on_start', true) && setting('ui.terminals', true); }

// ── adding an account from a key or a token (594, owner ruling) ──────────────
// While ui.allow_secret_entry (default on), the wizard's account step and this page take an API key or
// a setup token in a MASKED field. The value is read once, the field is emptied at once, and it goes
// out only in the body of one CSRF-checked POST /api/v1/accounts — never a URL, the page's state, a
// toast or an operation. The host stores it exactly as `doz account add` does (the login keychain,
// one check request). Off: the terminal commands instead.
export function secretEntryAllowed() { return setting('ui.allow_secret_entry', true) === true && !(state.serve && !state.serve.secure); }
/// 606: why keys and tokens are not taken in this browser (the commands follow it).
export function secretEntryWhy() {
  return state.serve && !state.serve.secure
    ? 'keys and tokens are never typed here over plain HTTP — the network between this browser and the Mac could read them; reach this dashboard over HTTPS through your reverse proxy, or'
    : 'keys and tokens are not taken in this browser — ui.allow_secret_entry is off;';
}

/// The setting ui.terminals: off, the UI opens no browser terminal (and the server refuses a ticket).
export function terminalsAllowed() {
  if (setting('ui.terminals', true)) return true;
  pageFailure('Browser terminals are off (Settings → ui.terminals). Open in Terminal still works.', { tone: 'warn', key: 'terminals-off' });
  return false;
}

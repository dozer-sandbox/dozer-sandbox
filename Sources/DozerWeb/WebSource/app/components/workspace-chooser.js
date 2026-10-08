// components/workspace-chooser — The workspace of a new sandbox (594).
import { h } from '../dom/h.js';
import { icon, withIcon } from '../dom/icons.js';
import { api } from '../core/api.js';
import { isRemote } from '../core/session.js';

// ── 594: the workspace of a new sandbox ─────────────────────────────────────
// Owner (2026-09-29): "an easier way to pick a workspace folder … a default location
// ~/Developer/dozer-sandbox-projects/[SANDBOX-NAME] and … a better default name like claude-sandbox";
// "present the no workspace toggle better … call it Isolated"; "i dont want the user to have to create
// the path first". Shared folder (default) | Isolated. The name follows the image until it is typed
// in; the folder follows the name until it is typed in (or chosen). The host says what a path would
// do (POST workspace/check — it makes nothing): "will be created", "exists", or why not. Choose…
// opens the MAC's folder picker (POST workspace/choose — one at a time; the answer is a path).
export const ISOLATED_NOTE = 'Nothing on your Mac is shared. /workspace exists only inside the sandbox.';
export function workspaceChooser({ nameInput = null, image = () => null, name = null, initialPath = '', initialIsolated = false }) {
  let mode = initialIsolated ? 'isolated' : 'shared', nameEdited = false, pathEdited = !!initialPath, seq = 0, lastError = null, timer = null;
  // 596 (B6): a folder the page chose (a Dockerfile's) — replaced by the next one, never over a typed or picked folder.
  let autoPath = null;
  const path = h('input', { type: 'text', name: 'workspace', 'data-ws-path': '', placeholder: '~/dozer-sandbox-workspaces/NAME',
                            autocomplete: 'off', spellcheck: 'false', 'aria-label': 'Workspace folder' });
  path.value = initialPath;
  const note = h('small', { class: 'ws-note', 'data-ws-note': '', 'aria-live': 'polite' });
  const choose = h('button', { type: 'button', class: 'btn sm', 'data-ws-choose': '', title: 'Opens the Mac’s folder picker (New Folder allowed)' },
    withIcon('folder', 'Choose…'));
  const segs = {};
  const seg = (m, label, icon) => (segs[m] = h('button', { type: 'button', class: 'seg', 'data-ws-seg': m, on: { click: () => setMode(m) } }, withIcon(icon, label)));
  const control = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Workspace' }, seg('shared', 'Shared folder', 'folder'), seg('isolated', 'Isolated', 'shield'));
  const shared = h('div', { class: 'ws-shared' }, h('div', { class: 'ws-row' }, path, isRemote() ? null : choose), note);
  const isolatedNote = h('small', { class: 'ws-isolated-note', 'data-ws-isolated': '' }, ISOLATED_NOTE);
  const el = h('div', { class: 'field ws-field', 'data-ws-mode': mode },
    h('span', null, 'Workspace'), control, shared, isolatedNote);
  function setMode(m) {
    mode = m;
    el.dataset.wsMode = m;
    for (const [k, b] of Object.entries(segs)) { b.classList.toggle('active', k === m); b.setAttribute('aria-pressed', k === m ? 'true' : 'false'); }
    shared.hidden = m !== 'shared';
    isolatedNote.hidden = m !== 'isolated';
  }
  function say(r) {
    lastError = r.error || null;
    note.classList.toggle('error', !!r.error);
    note.dataset.wsState = r.error ? 'error' : r.willCreate ? 'create' : r.exists ? 'exists' : '';
    note.textContent = r.error ? r.error : r.willCreate ? 'Will be created (with any missing folders above it) when the sandbox is.'
      : r.exists ? 'Exists — shared live at /workspace.' : '';
  }
  async function check(what = {}) {
    const my = ++seq;
    const body = {};
    const img = image();
    if (img) body.image = img;
    const n = name ? name() : nameInput ? nameInput.value.trim() : '';
    if (nameEdited && n) body.name = n;
    if (what.path !== undefined) body.path = what.path;
    let r;
    try { r = await api('workspace/check', { method: 'POST', json: body }); } catch (e) { if (my === seq) say({ error: e.message || String(e) }); return; }
    if (my !== seq) return;
    if (nameInput && !nameEdited) nameInput.value = r.suggestedName;
    if (!pathEdited) {
      path.value = r.defaultPath;
      if (what.path === undefined) return check({ path: path.value });
    } else if (what.path === undefined && autoPath && path.value.trim() === autoPath) {
      // 596: a name/image check superseded the chosen Dockerfile folder's own check — say that folder's state.
      return check({ path: autoPath });
    }
    if (what.path !== undefined) say(r);
  }
  const later = (f) => { clearTimeout(timer); timer = setTimeout(f, 250); };
  if (nameInput) nameInput.addEventListener('input', () => { nameEdited = true; if (!pathEdited) later(() => check()); });
  path.addEventListener('input', () => { pathEdited = true; autoPath = null; later(() => check({ path: path.value.trim() })); });
  choose.addEventListener('click', async () => {
    choose.disabled = true;
    try {
      const r = await api('workspace/choose', { method: 'POST', json: path.value.trim() ? { start: path.value.trim() } : {} });
      if (r && r.path) { path.value = r.path; pathEdited = true; autoPath = null; await check({ path: r.path }); }
    } catch (e) { say({ error: e.message || String(e) }); } finally { choose.disabled = false; }
  });
  setMode(mode);
  if (pathEdited) check({ path: path.value.trim() }); else check();
  return {
    el,
    /// The image changed: a name not typed in follows it (and the folder, the name).
    imageChanged() { if (!nameEdited || !pathEdited) check(); },
    /// 596 (B6): a Dockerfile was chosen — its folder becomes the workspace unless the person set one.
    suggest(p) {
      if (!p || (pathEdited && path.value.trim() !== autoPath)) return false;
      autoPath = p;
      pathEdited = true;
      path.value = p;
      check({ path: p });
      return true;
    },
    get path() { return path.value.trim(); },
    /// {isolated: true} or {workspace} — or an Error with why not.
    get() {
      if (mode === 'isolated') return { isolated: true };
      const p = path.value.trim();
      if (!p) throw new Error('Give the folder to share at /workspace (Choose…), or pick Isolated.');
      if (lastError) throw new Error('Workspace: ' + lastError);
      return { workspace: p };
    },
  };
}

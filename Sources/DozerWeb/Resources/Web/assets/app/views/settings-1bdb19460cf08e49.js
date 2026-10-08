// views/settings — Settings (591).
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon } from '../dom/icons-8392ebb8cb8879e3.js';
import { api } from '../core/api-1817573a49f0ab85.js';
import { refresh } from '../core/router-2585451a20eecb0b.js';
import { adoptSettings, resetSetting, saveSetting } from '../core/settings-171e705abeccb983.js';
import { state } from '../core/state-6efaa5d4aa08116b.js';
import { isInt } from '../core/util-1195caf40612902f.js';
import { isRemote } from '../core/session-545fa19d53ba02cc.js';
import { renderAccessStep } from '../components/access-step-8a3dfa651b81d1a1.js';
import { pageIndex } from '../components/blocks-53c969feeec8fe89.js';
import { btn } from '../components/button-8e61dd531eed2262.js';
import { callout } from '../components/callout-295f8e0570c7e239.js';
import { pageFailure, toast } from '../components/notices-89b8886740537e92.js';
import { confirmWeb, isAgentModel, permissionSwitches } from '../components/permissions-2d2cf511e6aa7261.js';

const SETTING_SECTIONS = {
  ui: 'This UI', host: 'The host', store: 'The store', claude: 'Claude Code', defaults: 'New sandboxes', agent: 'The agent', sandbox: 'Inside every sandbox',
  'images.lab': 'New lab sandboxes', 'images.claude-code': 'New claude-code sandboxes', 'images.pi': 'New pi sandboxes', 'images.codex': 'New codex sandboxes', kernel: 'The kernel',
  resources: 'Resources', sessions: 'Sessions', bridges: 'Bridges', workspace: 'Workspace rules', github: 'GitHub', images: 'Images',
};
// An empty app list means none (default apps only), not "automatic".
function shownValue(v, type) { return typeof v === 'string' ? (v === '' ? (type === 'apps' ? '""  (none)' : '""  (automatic)') : v) : String(v); }
export async function viewSettings() {
  adoptSettings(await api('settings'));
  const rep = state.settings.report;
  const sections = [];
  for (const r of rep.settings) {
    let s = sections.find((x) => x.name === r.section);
    if (!s) sections.push(s = { name: r.section, rows: [] });
    s.rows.push(r);
  }
  const warnings = rep.warnings.filter((w) => !rep.error || !w.startsWith(rep.error));
  // 599e: Access — each credential's last confirmation and "Check again" (the choices are the settings
  // below: defaults.github, github.credentials, sandbox.ssh_agent; the Claude account: Accounts).
  const accessBox = h('div', { class: 'panel access-panel', 'data-settings-access': '' });
  renderAccessStep(accessBox, { mode: 'settings', claude: true });
  // 603 (E13): a filter over what the page already has (a key, a name, a description) and an index of the
  // sections; Access stays first.
  const filter = h('input', { type: 'search', class: 'page-filter', 'data-settings-filter': '', placeholder: 'Filter — a key like ui.theme, or a word',
    'aria-label': 'Filter the settings', autocomplete: 'off', spellcheck: 'false' });
  filter.value = state.settingsFilter || '';
  const secId = (name) => 'set-' + name.replace(/[^a-z0-9]+/gi, '-');
  const index = pageIndex([['access', 'Access'], ...sections.map((sec) => [secId(sec.name), SETTING_SECTIONS[sec.name] || sec.name])]);
  const node = h('div', { class: 'settings-page' }, h('h1', null, 'Settings'),
    h('p', { class: 'sub' }, 'Written to ', h('code', null, rep.path || 'no file (neither XDG_CONFIG_HOME nor HOME is set)'),
      rep.exists ? '' : ' — not written yet: the first change writes it, with every setting listed at its default',
      '. A command-line flag wins, then the environment, then this file, then the default; ', h('code', null, 'doz config show'), ' prints the same.'),
    rep.error ? callout('bad', { cls: 'notice', title: 'The settings file does not read', body: rep.error + ' — nothing in it applies, and the UI will not overwrite it. Fix it (or remove it) first.' }) : null,
    warnings.length ? callout('warn', { cls: 'notice', body: h('ul', { class: 'plain' }, warnings.map((w) => h('li', null, w))) }) : null,
    h('div', { class: 'page-tools' }, h('label', { class: 'filter-field' }, icon('search'), filter), index),
    h('p', { class: 'muted filter-none', 'data-filter-none': '', hidden: true }, 'No setting matches.'),
    h('h2', { id: 'access', class: 'set-head' }, 'Access'),
    h('p', { class: 'sub' }, 'What sandboxes may use as you. Change a choice in the settings below (',
      h('code', null, 'defaults.github'), ', ', h('code', null, 'github.credentials'), ', ', h('code', null, 'sandbox.ssh_agent'),
      ') or with ', h('code', null, 'doz access set'), '; the Claude account on the Accounts page.'),
    accessBox,
    sections.flatMap((sec) => [
      h('h2', { id: secId(sec.name), class: 'set-head', 'data-section': sec.name }, SETTING_SECTIONS[sec.name] || sec.name, ' ', h('code', { class: 'muted' }, '[' + sec.name + ']')),
      h('div', { class: 'panel settings', 'data-section': sec.name }, sec.rows.map(settingRow)),
    ]),
    h('h2', { class: 'set-head', 'data-section': 'not-settable' }, 'Not settable, by design'),
    h('div', { class: 'panel', 'data-section': 'not-settable' }, h('ul', { class: 'plain' }, rep.notSettable.map((n) => h('li', null, n)))));
  const apply = () => {
    const q = filter.value.trim().toLowerCase();
    state.settingsFilter = filter.value;
    let any = false;
    for (const row of node.querySelectorAll('.setting[data-key]')) {
      const r = state.settings.byKey[row.dataset.key];
      const hit = !q || [r.key, r.name, r.description, r.section].some((t) => String(t || '').toLowerCase().includes(q));
      row.hidden = !hit;
      any = any || hit;
    }
    for (const el of node.querySelectorAll('[data-section]')) {
      const box = node.querySelector('.panel.settings[data-section="' + el.dataset.section + '"]');
      el.hidden = !!q && (!box || ![...box.querySelectorAll('.setting')].some((x) => !x.hidden));
    }
    // Access and the index stand aside while filtering (the matching rows are the page).
    for (const el of node.querySelectorAll('#access, [data-settings-access], #access + .sub')) el.hidden = !!q;
    node.querySelector('[data-filter-none]').hidden = !q || any;
  };
  filter.addEventListener('input', apply);
  filter.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && filter.value) { ev.stopPropagation(); filter.value = ''; apply(); } });
  apply();
  return node;
}
function settingRow(r) {
  const source = h('span', { class: 'tag src src-' + r.source, title: r.source === 'file' ? 'set in the file' : r.source === 'default' ? 'not set: the default' : (r.note || '') },
    r.source === 'env' ? 'env ' + r.environment : r.source);
  const reset = r.editable && r.source === 'file'
    ? btn('Default', () => changeSetting(r.key, null), { small: true, title: 'Comment it out in the file: the default (' + shownValue(r.defaultValue, r.type) + ') applies' }) : null;
  // 602: a control that is a block of its own (the permissions checklist) goes UNDER the text, full
  // width — beside it, its max-content width squeezed the description to one word per line.
  const row = h('div', { class: r.type === 'permissions' ? 'setting setting-wide' : 'setting', 'data-key': r.key },
    h('div', { class: 'setting-main' },
      h('div', { class: 'setting-name' }, h('code', null, r.name), ' ', source),
      h('div', null, r.description),
      h('div', { class: 'muted setting-meta' }, 'default ', h('code', null, shownValue(r.defaultValue, r.type)), ' · ', r.appliesNote,
        r.note ? h('div', null, r.note) : null)),
    h('div', { class: 'setting-control' }, settingControl(r), reset));
  if (state.settingErr.has(r.key)) paintSettingError(row, r.key);
  return row;
}
function settingControl(r) {
  // 599c: the projects folder — chosen in the Mac's own folder picker (the server writes what was chosen;
  // the page never sends a path). Not when the environment or the command line sets it.
  if (r.key === 'defaults.projects_dir' && r.source !== 'env' && r.source !== 'flag') {
    const choose = btn('Choose…', () => chooseProjectsDir(), { small: true, icon: 'folder', title: 'Pick the folder in this Mac’s folder picker' });
    choose.dataset.projectsChoose = '';
    return h('div', { class: 'path-setting' }, h('code', { class: 'setting-value', 'data-projects-dir': '' }, shownValue(r.value, r.type)), isRemote() ? null : choose);
  }
  if (!r.editable) return h('code', { class: 'setting-value', title: r.note || '' }, shownValue(r.value, r.type));
  let input;
  if (r.type === 'bool') {
    input = h('input', { type: 'checkbox', role: 'switch', 'aria-label': r.key });
    input.checked = r.value === true;
    input.addEventListener('change', () => changeSetting(r.key, input.checked));
  } else if (r.type === 'choice') {
    input = h('select', { 'aria-label': r.key }, r.choices.map((c) => {
      const o = h('option', { value: c }, c);
      if (c === r.value) o.selected = true;
      return o;
    }));
    input.addEventListener('change', () => changeSetting(r.key, input.value));
  } else if (r.type === 'permissions') {
    // 597 (P4): the default permissions of new sandboxes — the same switches (on a base with no
    // language of its own; a base's ecosystem joins Standard for it), saved as words on Standard.
    input = h('div', { class: 'perm-setting', 'data-perm-setting': '' }, h('span', { class: 'muted' }, '…'));
    api('bases').then((b) => {
      const std = new Set(b.standard[''] || []);
      let on = new Set(b.defaults[''] || []);
      const all = b.permissions.map((x) => x.id).filter((x) => !isAgentModel(x));
      const words = () => {
        const same = (a, c) => a.size === c.size && [...a].every((x) => c.has(x));
        if (same(on, std)) return 'standard';
        if (same(on, new Set(['model']))) return 'locked';
        if (same(on, new Set(all.filter((x) => !x.startsWith('github:'))))) return 'open';   // Open never includes your GitHub login
        return [...all.filter((x) => on.has(x) && !std.has(x)).map((x) => '+' + x), ...all.filter((x) => !on.has(x) && std.has(x)).map((x) => '-' + x)].join(',');
      };
      const paint = () => input.replaceChildren(h('code', { 'data-perm-words': '' }, words()),
        permissionSwitches(b.permissions, on, (id, v) => {
          const apply = () => {
            const inst = b.permissions.filter((x) => x.group === 'install').map((x) => x.id);
            for (const x of id === 'install' ? inst : [id]) { if (v) on.add(x); else on.delete(x); }
            changeSetting(r.key, words());
          };
          if (id === 'web' && v) confirmWeb(async () => apply()); else apply();
        }, { hosts: false }));
      paint();
    }).catch(() => input.replaceChildren(h('code', null, String(r.value))));
  } else if (r.type === 'int') {
    input = h('input', { type: 'number', min: String(r.min), max: String(r.max), step: '1', 'aria-label': r.key });
    input.value = String(r.value);
    input.addEventListener('change', () => {
      const n = Number(input.value);
      if (!isInt(n, r.min, r.max)) { settingFailed(r.key, r.key + ' is a whole number, ' + r.min + '–' + r.max); input.value = String(r.value); return; }
      changeSetting(r.key, n);
    });
  } else {
    // The open-files bridge's app list is names, comma-separated (empty: only each file's default app).
    const placeholder = r.type === 'apps' ? 'e.g. Typora, Visual Studio Code (empty: default apps only)' : '"" = automatic';
    input = h('input', { type: 'text', spellcheck: 'false', autocomplete: 'off', 'aria-label': r.key, placeholder });
    input.value = String(r.value);
    input.addEventListener('change', () => changeSetting(r.key, input.value.trim()));
  }
  return input;
}
/// 603: a setting that could not be changed says so in its own row (kept across the page's re-render).
state.settingErr = new Map();
function settingFailed(key, text) {
  state.settingErr.set(key, text);
  const row = document.querySelector('.setting[data-key="' + CSS.escape(key) + '"]');
  if (row) paintSettingError(row, key); else pageFailure(text);
}
function paintSettingError(row, key) {
  row.querySelector('.setting-error')?.remove();
  const text = state.settingErr.get(key);
  if (text) row.querySelector('.setting-main').append(callout('bad', { compact: true, cls: 'setting-error', body: text,
    dismiss: () => { state.settingErr.delete(key); paintSettingError(row, key); } }));
}
async function chooseProjectsDir() {
  try {
    const c = await api('settings/projects-dir/choose', { method: 'POST', json: {} });
    if (c.cancelled) return;
    adoptSettings(c.report);
    state.settingErr.delete('defaults.projects_dir');
    toast('defaults.projects_dir saved: ' + c.path, false);
  } catch (e) {
    settingFailed('defaults.projects_dir', e.message || String(e));
  }
  refresh(false);
}
async function changeSetting(key, value) {
  try {
    if (value === null) await resetSetting(key); else await saveSetting(key, value);
    state.settingErr.delete(key);
    toast(key + (value === null ? ' is the default again' : ' saved'), false);
  } catch (e) {
    settingFailed(key, e.message || String(e));
  }
  refresh(false);
}

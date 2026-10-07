// doz ui — phase 2: the dashboard, and actions.
//
// Rules this file keeps (590.01-DESIGN.md):
//   · Every value from the server is rendered with textContent — never parsed as HTML. Much of it comes
//     from inside a sandbox (hostnames in the net log, session commands, image notes) and a sandbox
//     is untrusted.
//   · The link's capability is read from the fragment ONCE, removed from the address bar and history
//     before anything else, and sent only in the bootstrap's Authorization header.
//   · The CSRF token lives in this page's memory only (never storage, a cookie or a URL).
//   · Every action is one typed request (POST /api/v1/actions, {action, …}); a destructive one carries
//     `confirm`, filled only from a name the person typed. No action ever carries a secret (590's D3).
//     594 (owner ruling): an ACCOUNT's key or token may be typed in a masked field (accountForm) — one
//     POST /api/v1/accounts body, while ui.allow_secret_entry; a sandbox's own key likewise (keyEntry,
//     POST /api/v1/sandboxes/NAME/key).
//   · Forms live in <dialog>s outside the view, so a live refresh never wipes what is being typed.
//   · 605: the page outlives its server. doz ui restarting is a calm pause (terminals reattach, operations
//     resolve, a newer build offers a reload); a sign-in again happens INSIDE the page, over what it shows.

import { expose, provide } from './app/core/hooks.js';
import { $, h } from './app/dom/h.js';
import { icon, iconFor, OP_GLYPH, PHASE_GLYPH, setButton, withIcon } from './app/dom/icons.js';
import { AGENT_NAMES, DOCKERFILE_POLICY_NOTE, parseImageName } from './app/core/agents.js';
import { api } from './app/core/api.js';
import { connect } from './app/core/events.js';
import { bytes, clock, full, mib, ms, pct, plural, when } from './app/core/format.js';
import { measured, remeasure, scheduleResTotal } from './app/core/measure.js';
import { act, actOrThrow, loadPreparations, opEnded, prepRunning, TRANSITION_LABEL, transitionOf, waitForOp, waitOp } from './app/core/operations.js';
import { showUiOverlay, uiLost, uiRetryTick } from './app/core/reconnect.js';
import { refresh, route } from './app/core/router.js';
import { opRunningFor, sandboxBusy, sandboxPhase, SAVED_PHASES, VERBS } from './app/core/sandboxes.js';
import { bootstrap, signedOut } from './app/core/session.js';
import { adoptSettings, bootViewOnStart, loadSettings, resetSetting, saveSetting, secretEntryAllowed, setting, terminalsAllowed } from './app/core/settings.js';
import { state } from './app/core/state.js';
import { pageTerminals, SPLIT_KINDS, sview, terminals, termUI } from './app/core/terminals.js';
import { isInt, lines, splitArgs } from './app/core/util.js';
import { WIZ, WIZ_ORDER, WIZ_STEPS } from './app/core/wizards.js';
import { ACCESS_TITLES, renderAccessStep } from './app/components/access-step.js';
import { accountChooser, accountCommandsNode, accountDialog, accountForm, credentialBanner, keyEntry } from './app/components/accounts.js';
import { card, chip, meter, pageIndex, panel, stat, table } from './app/components/blocks.js';
import { btn } from './app/components/button.js';
import { callout } from './app/components/callout.js';
import { createDialog } from './app/components/create-dialog.js';
import { confirmAction, dialog } from './app/components/dialog.js';
import { hostCard, hostChanged, renderHostFoot } from './app/components/host.js';
import { imagePicker, pickerNameHint } from './app/components/image-picker.js';
import './app/components/keyboard.js';
import { lifecycle, lifecycleBar, rowLifecycle, sessionsWhyNot } from './app/components/lifecycle.js';
import { menuButton, moreMenu } from './app/components/menus.js';
import { closeWizardModal, modalInert, openWizardModal, renderModal, wizHead, wizMount } from './app/components/modal.js';
import { navRail, paintNav, paintResTotal, refreshNav, renderNavSandboxes } from './app/components/nav.js';
import { banner, dropBanner, failureFor, opFailed, pageFailure, paintRowOps, toast } from './app/components/notices.js';
import { confirmGitHub, confirmWeb, isAgentModel, permissionSwitches, PRESET_LABEL } from './app/components/permissions.js';
import { paintTransition, phasePill, sandboxPill, statusPill } from './app/components/pills.js';
import { prepCard, prepProgressText } from './app/components/prep-card.js';
import { quickAdd, quickAddButton } from './app/components/quick-add.js';
import { rulesStep } from './app/components/rules-step.js';
import { stepperNode } from './app/components/stepper.js';
import { bootLogDialog, bootTerm, closeTerminal, focusTerm, goLive, newTerm, openDefaultTerminal, openTerminal, paintCover, PHASE_WORD, reattachTerminals, sendInput, terminalTitle } from './app/components/terminal.js';
import { ISOLATED_NOTE, workspaceChooser } from './app/components/workspace-chooser.js';
function renderOps() {
  const running = [...state.ops.values()].filter((o) => o.state === 'running').length + state.preps.filter(prepRunning).length;
  const badge = $('ops-badge');
  badge.hidden = running === 0;
  badge.replaceChildren(h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), String(running));
  badge.title = running + ' running';
  if (state.view === 'operations') state.opsSeenAt = Date.now();
  const unseen = [...state.ops.values()].some((o) => o.state === 'failed' && opEnded(o) > state.opsSeenAt);
  $('ops-alert').hidden = !unseen;
  if (state.view === 'operations') renderOperations();
}
function acknowledgeOps() {
  state.opsSeenAt = Date.now();
  $('ops-alert').hidden = true;
}
function viewOperations() {
  acknowledgeOps();
  const box = h('div');
  state.opsBox = box;
  renderOperations();
  return box;
}
function renderOperations() {
  const box = state.opsBox;
  if (!box) return;
  const all = [...state.ops.values()].reverse();
  const names = [...new Set(all.map((o) => o.sandbox).filter(Boolean))].sort();
  const filter = h('select', { 'aria-label': 'Filter by sandbox' }, h('option', { value: '' }, 'every sandbox'), names.map((n) => {
    const o = h('option', { value: n }, n);
    if (n === state.opsFilter) o.selected = true;
    return o;
  }));
  filter.addEventListener('change', () => { state.opsFilter = filter.value; renderOperations(); });
  const list = all.filter((o) => !state.opsFilter || o.sandbox === state.opsFilter);
  const rows = list.map((o) => {
    const secs = o.state === 'running' ? Math.max(0, Math.round((Date.now() - new Date(o.startedAt).getTime()) / 1000)) + ' s' : (o.milliseconds ? ms(o.milliseconds) : '—');
    return h('tr', { class: 'op-row op-' + o.state, 'data-op': o.id },
      h('td', null, o.state === 'running' ? h('span', { class: 'mini-spin', title: 'running' }) : h('span', { class: 'op-state', title: o.state }, o.state === 'done' ? '✓' : o.state === 'interrupted' ? '–' : '✕')),
      h('td', { class: 'op-action' }, OP_GLYPH[o.action] ? icon(OP_GLYPH[o.action]) : null, o.action), h('td', null, o.sandbox ? h('a', { href: '#/sandbox/' + o.sandbox }, o.sandbox) : '—'),
      h('td', null, clock(o.startedAt)), h('td', { class: 'num' }, secs),
      // 594 W22: an operation of several parts (Restart host) lists each finished one.
      h('td', { class: 'op-text' }, o.text, o.lines && o.lines.length ? h('ul', { class: 'op-lines' }, o.lines.map((l) => h('li', null, l))) : null));
  });
  // (replaceChildren writes a null as the text "null" — h() skips it, replaceChildren does not.)
  box.replaceChildren(h('h1', null, 'Operations'),
    ...(state.preps.length ? [preparationsSection()] : []),
    h('p', { class: 'sub' }, 'What this UI asked the host to do, newest first: live progress while it runs, then its result. A failure also raises a message.'),
    h('div', { class: 'toolbar' }, filter, list.length + ' of ' + all.length),
    panel(table(['', 'Action', 'Sandbox', 'Started', 'Took', 'Progress / result'], rows, [4]), 'Nothing yet — actions you take show here.'));
}
function preparationsSection() {
  // A row per preparation and, beneath it, the same card as the wizard's (the running ones in full).
  // (prep-row, not op-row: a preparation is the host's, not one of this page's operations — the
  // operations table's filter and its "newest first" are the UI's own actions only.)
  const rows = state.preps.flatMap((p) => [h('tr', { class: 'prep-row op-' + (prepRunning(p) ? 'running' : p.state === 'done' ? 'done' : 'failed'), 'data-prep': p.image },
    h('td', null, prepRunning(p) ? h('span', { class: 'mini-spin', title: p.state }) : h('span', { class: 'op-state', title: p.state }, p.state === 'done' ? '✓' : '✕')),
    h('td', { class: 'op-action' }, icon('flame'), 'prepare ' + p.image),
    h('td', null, p.requestedBy.join(', ')),
    h('td', null, clock(p.startedAt)), h('td', { class: 'num' }, Math.round(p.seconds) + ' s'),
    h('td', { class: 'op-text' }, prepProgressText(p)),
    h('td', null, prepRunning(p) && p.state !== 'cancelling'
      ? btn('Cancel preparation', () => act({ action: 'prepare-cancel', images: [p.image] }), { small: true, danger: true }) : null)),
    h('tr', { class: 'prep-detail-row', 'data-prep-detail': p.image }, h('td', { colspan: '7' }, prepCard(p, { open: false })))]);
  return h('div', { class: 'ops-preps' }, h('h2', null, 'Image preparations (in the host)'),
    h('p', { class: 'sub' }, 'The kernel, the base image and the bake of a built-in image — asked for by doz onboard, the onboarding wizard, doz image bake or a first start. One per image at a time; whoever asks next joins it.'),
    panel(table(['', 'Image', 'Asked by', 'Started', 'Took', 'Progress', ''], rows, [4])));
}

const SETTING_SECTIONS = {
  ui: 'This UI', host: 'The host', store: 'The store', claude: 'Claude Code', defaults: 'New sandboxes', agent: 'The agent', sandbox: 'Inside every sandbox',
  'images.lab': 'New lab sandboxes', 'images.claude-code': 'New claude-code sandboxes', 'images.pi': 'New pi sandboxes', 'images.codex': 'New codex sandboxes', kernel: 'The kernel',
  resources: 'Resources', sessions: 'Sessions', bridges: 'Bridges', workspace: 'Workspace rules', github: 'GitHub', images: 'Images',
};
// An empty app list means none (default apps only), not "automatic".
function shownValue(v, type) { return typeof v === 'string' ? (v === '' ? (type === 'apps' ? '""  (none)' : '""  (automatic)') : v) : String(v); }
async function viewSettings() {
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
    return h('div', { class: 'path-setting' }, h('code', { class: 'setting-value', 'data-projects-dir': '' }, shownValue(r.value, r.type)), choose);
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
// 599c: Quick add in the sidebar, beside Sandboxes.
$('nav-quick-add').replaceChildren(icon('plus'));
$('nav-quick-add').addEventListener('click', (ev) => { ev.preventDefault(); quickAdd(ev.currentTarget); });
$('sign-out').addEventListener('click', async () => {
  try { await api('session', { method: 'DELETE' }); } catch (_) { /* already gone */ }
  signedOut('This browser is signed out of Dozer.', 'signed-out');
});

// ── views ───────────────────────────────────────────────────────────────────
async function viewOverview() {
  const o = await api('overview');
  state.overview = o;
  renderNavSandboxes();
  const rows = o.sandboxes.map((s) => h('tr', { class: 'click', 'data-sandbox-row': s.name, on: { click: () => { location.hash = '#/sandbox/' + s.name; } } },
    h('td', null, h('a', { class: 'name', href: '#/sandbox/' + s.name }, s.name),
      h('div', { class: 'sub2' }, s.image, s.workspace ? null : h('span', { class: 'no-ws', 'data-isolated': '', title: ISOLATED_NOTE }, ' · isolated')),
      h('div', { 'data-op-for': s.name })),
    h('td', null, sandboxPill(s), s.diedWithHost ? h('div', { class: 'st-warn sub2' }, 'died with its host') : null),
    h('td', { class: 'num' }, h('div', null, s.ramHeldMiB ? mib(s.ramHeldMiB) : '—'), h('div', { class: 'sub2' }, 'of ' + mib(s.memoryMiB)), meter(s.ramHeldMiB, s.memoryMiB)),
    h('td', { class: 'num' }, bytes(s.diskBytes)),
    h('td', null, s.network, s.deniedConnections ? [' ', h('span', { class: 'tag warn' }, s.deniedConnections + ' denied')] : null),
    s.accountApplies
      ? h('td', null, s.account || '—', s.credentialState ? h('div', { class: (s.credentialState === 'ok' ? 'st-ok' : 'st-warn') + ' sub2' }, s.credentialState) : null,
        s.foreignCredentials ? h('div', { class: 'st-warn sub2' }, s.foreignCredentials + ' own credential(s)') : null)
      : h('td', { class: 'muted', title: 'its network cannot reach an account’s API' }, 'n/a'),
    h('td', { class: 'row-acts-cell' }, rowLifecycle(s))));
  return h('div', null,
    h('div', { class: 'head' }, h('h1', null, 'Sandboxes'),
      h('div', { class: 'actions' }, quickAddButton(), (() => {
        const b = btn('New sandbox', () => newSandboxWizard(), { primary: true, title: 'Step by step — your choices go in the project folder’s doz_project.yaml' });
        b.dataset.newSandbox = '';
        return b;
      })())),
    h('p', { class: 'sub' }, o.source === 'host' ? 'Live from the host.' : 'No host is running: read from the store (nothing is live). An action starts the host.'),
    h('div', { class: 'stats' },
      hostCard(o.host),
      card('Sandboxes', String(o.totals.sandboxes), o.totals.live + ' with a VM'),
      card('RAM held', mib(o.totals.ramHeldMiB), 'charged to this Mac now'),
      card('Disk', bytes(o.totals.diskBytes), 'allocated, all sandboxes')),
    h('h2', null, 'All sandboxes'),
    // No session column: counting sessions asks every session's holder in the guest, and this list
    // is kept live — sessions are on each sandbox's page (590 bug 3).
    o.sandboxes.length ? panel(table(['Sandbox', 'Phase', 'RAM held', 'Disk', 'Network', 'Account', h('span', { class: 'sr-only' }, 'Actions')], rows, [2, 3]))
      : h('div', { class: 'panel' }, h('div', { class: 'empty-big' }, icon('box'), h('div', { class: 'e-title' }, 'No sandboxes yet'),
        h('p', null, 'A sandbox is a small Linux VM for one project. Quick add makes one with every default; New sandbox walks through each choice. In a terminal: doz new, or doz init then doz up.'),
        h('div', { class: 'actions center' }, quickAddButton()))));
}

// ── 599f: the New Sandbox wizard (owner: "a new wizard process for creating a purposeful sandbox that steps
// the user through all the choices, capturing the config in a doz_project.yml in the project / working dir").
// #/new: project folder → agent and base → account → access → workspace rules (599g) → permissions and network →
// resources → bridges → session → review. The steps are the host's list (`ProjectWizard.steps`, the same `doz init` walks);
// every value is pre-filled from the settings, or from the folder's existing project file; only what the
// person sets (or the file set) is written — the rest stays commented and follows the settings. The review
// shows the EXACT file (rendered and read back by the CLI's parser), writes it (an existing one only after its
// diff and a yes), then makes the sandbox as `doz up` would and opens it with the boot view, as Quick add does.
const NW_FIELD = { cpus: 'cpus', memory: 'memory', network: 'network', permissions: 'permissions', account: 'account', github: 'github',
                   agent_sudo: 'agentSudo', ssh_agent: 'sshAgent', clipboard: 'clipboard', browser_bridge: 'browserBridge', open_files: 'openFiles', tmux: 'tmux',
                   ignore_mode: 'ignoreMode' };
function newSandboxWizard(start = {}) {
  // 603: a draft left by the browser's Back is resumed, never silently replaced (a new start asks first).
  const go = () => { if (location.hash === '#/new') renderModal(true); else location.hash = '#/new'; };
  const draft = state.nw && !state.nw.tools && (state.nw.step > 0 || !!state.nw.form || state.nw.explicit.size > 0);
  if (draft && !start.folder) { go(); return; }
  const fresh = () => { state.nw = null; state.nwStart = start; go(); };
  if (!draft) { fresh(); return; }
  dialog('Discard the unfinished new sandbox?', 'A New sandbox wizard was left part-way; starting again forgets its choices.', [], 'Discard', async () => { fresh(); }, { danger: true, icon: 'x' });
}
async function viewNew() {
  if (!state.nw) {
    const [images, accounts, bases] = await Promise.all([api('images').catch(() => []), api('accounts').catch(() => ({ accounts: [] })), api('bases').catch(() => null)]);
    let newName = 'my-project', projectsDir = setting('defaults.projects_dir', '~/Developer/dozer-sandbox-projects');
    try { const qa = await api('quick-add', { method: 'POST', json: {} }); newName = qa.name; projectsDir = qa.projectsDir; } catch (_) { /* the defaults */ }
    const start = state.nwStart || {};
    // The steps are the host's (the list doz init walks); asking about the default folder changes nothing.
    let steps = null;
    try { steps = (await api('project/open', { method: 'POST', json: { folder: projectsDir + '/' + newName } })).steps; } catch (_) { /* shown after the folder */ }
    state.nw = { step: 0, images, accounts, bases, projectsDir, newName, mode: start.folder ? 'existing' : 'new', path: start.folder || '',
                 open: null, form: null, explicit: new Set(), preview: null, error: '', steps, reached: 0 };
    Object.assign(state.nw, { initName: newName, initMode: state.nw.mode, initPath: state.nw.path });
  }
  return nwNode();
}
function nwRender() {
  if (state.modal !== 'new' || !state.nw) return;
  wizMount(nwNode(), true);
}
function nwSection(form) {
  const img = form.image || '';
  if (img === 'lab') return 'lab';
  const p = parseImageName(img, (state.nw.bases ? state.nw.bases.bases : []).map((b) => b.id));
  if ((p && p.agent === 'codex') || img === 'codex') return 'codex';
  return (p && p.agent === 'pi') || img === 'pi' ? 'pi' : 'claude-code';
}
function nwAgent(form) {
  if (form.dockerfile) return form.agent && form.agent !== 'none' ? form.agent : null;
  if (form.image === 'lab') return null;
  const p = parseImageName(form.image || '', (state.nw.bases ? state.nw.bases.bases : []).map((b) => b.id));
  if (p) return p.agent === 'none' ? null : p.agent;
  const t = state.nw.images.find((x) => x.name === form.image);
  return t && t.agent ? (AGENT_NAMES[t.agent] ? t.agent : null) : null;
}
function nwBase(form) {
  const p = parseImageName(form.image || '', (state.nw.bases ? state.nw.bases.bases : []).map((b) => b.id));
  return form.dockerfile ? '' : p ? p.base : '';
}
function nwNetwork(form) { return form.network || setting('images.' + nwSection(form) + '.network', nwSection(form) === 'lab' ? 'bake' : 'agent'); }
const nwPermissionNet = (n) => ['agent', 'locked', 'open'].includes(n);
function nwSet(key, value) {
  const nw = state.nw;
  nw.form[NW_FIELD[key] || key] = value;
  if (NW_FIELD[key]) nw.explicit.add(key);
  nw.preview = null;
}
/// What the page sends: the name and the image always; the other choices only when set on purpose (or by the file).
function nwPayload() {
  const nw = state.nw, f = nw.form, out = { name: f.name, image: f.image };
  for (const k of ['agent', 'base', 'dockerfile', 'agentPrompt', 'agentPromptMode', 'sessions']) if (f[k] !== undefined && f[k] !== null && f[k] !== '') out[k] = f[k];
  for (const [key, field] of Object.entries(NW_FIELD)) if (nw.explicit.has(key) && f[field] !== undefined && f[field] !== null) out[field] = f[field];
  return { folder: nw.open.folder, form: out, explicit: [...nw.explicit] };
}
/// A done New Sandbox step's answer, under its name in the stepper.
function nwAnswer(id) {
  const nw = state.nw, f = nw.form;
  if (!f) return null;
  const home = (p) => String(p || '').replace(/^\/Users\/[^/]+/, '~');
  switch (id) {
    case 'folder': return nw.open ? home(nw.open.folder) : null;
    case 'image': return f.name + ' · ' + (f.dockerfile ? 'Dockerfile' : f.image);
    case 'account': { const a = nwAgent(f); return a ? (f.account && f.account !== 'default' ? f.account : 'the store default') : 'none needed'; }
    case 'access': { const g = f.github || setting('defaults.github', 'off'), ssh = f.sshAgent || setting('sandbox.ssh_agent', 'off');
      return 'GitHub ' + ({ off: 'off', read: 'read-only', push: 'read and push' }[g] || g) + ' · SSH ' + ssh; }
    case 'rules': return f.ignoreMode || setting('workspace.ignore_mode', 'lock');
    case 'permissions': return nwNetwork(f) + (nwPermissionNet(nwNetwork(f)) ? ' · ' + (f.permissions || setting('defaults.permissions', 'standard')) : '');
    case 'resources': return (f.cpus || setting('defaults.cpus', 2)) + ' CPUs · ' + (f.memory || 'default memory');
    case 'bridges': return 'clipboard ' + (f.clipboard || setting('sandbox.clipboard', 'write')) + ' · browser ' + (f.browserBridge || setting('sandbox.browser_bridge', 'on'));
    case 'session': return (f.tmux ?? setting('sessions.tmux', false)) ? 'in tmux' : 'no tmux';
    default: return null;
  }
}
function nwNode() {
  const nw = state.nw;
  if (nw.tools) return nwToolsNode(nw);
  const steps = nw.steps || [{ id: 'folder', title: 'Project folder' }];
  const { list: stepper, compact } = stepperNode(steps, nw.step, { data: 'data-nw-step', href: '#/new', note: (s) => nwAnswer(s.id),
    go: (i) => (nw.form && i <= Math.max(nw.reached, steps.length - 1) && i !== nw.step ? () => nwGo(i) : null) });
  const ids = steps.map((s) => s.id);
  const id = ids[nw.step] || 'folder';
  const step = { folder: nwFolder, image: nwImage, account: nwAccount, access: nwAccess, rules: nwRules, permissions: nwPermissions,
                 resources: nwResources, bridges: nwBridges, session: nwSession, review: nwReview }[id]();
  nw.collect = step.collect || (() => {});
  const error = h('div', { class: 'dlg-error', role: 'alert', 'data-nw-error': '' }, nw.error || '');
  const last = id === 'review';
  const back = nw.step > 0 ? btn('Back', () => nwGo(nw.step - 1)) : null;
  const skip = nw.form && !last ? btn('Skip to review', () => nwGo(ids.length - 1), { quiet: true, icon: 'skip-forward', title: 'Everything not chosen yet keeps its default' }) : null;
  if (skip) skip.dataset.nwSkip = '';
  // Next: the step's one primary — a trailing arrow (forward); the actions in a footer that never leaves the screen.
  const next = last ? null : h('button', { type: 'submit', class: 'btn lg primary', 'data-nw-next': '' }, h('span', { class: 'btn-label' }, 'Next'), icon('arrow-right'));
  const form = h('form', { class: 'wiz-card', 'data-nw-body': id, novalidate: '' },
    h('div', { class: 'w-body' }, h('h2', null, (steps[nw.step] || { title: 'Project folder' }).title), step.el, error),
    h('div', { class: 'w-foot wiz-buttons' }, back, h('span', { class: 'wiz-gap' }), skip, step.extra || null, next));
  form.addEventListener('submit', (ev) => { ev.preventDefault(); if (!last) nwGo(nw.step + 1); });
  form.addEventListener('keydown', (ev) => {
    // Alt+← / Alt+→: Back / Next (Enter in a field is Next; a textarea keeps its Enter).
    if (ev.altKey && ev.key === 'ArrowLeft' && nw.step > 0) { ev.preventDefault(); nwGo(nw.step - 1); }
    if (ev.altKey && ev.key === 'ArrowRight' && !last) { ev.preventDefault(); nwGo(nw.step + 1); }
  });
  const node = h('div', { class: 'wizard nw', 'data-nw': id },
    wizHead('New sandbox', ['Step by step; your choices are written to the project folder’s ', h('code', null, 'doz_project.yaml'),
      ' — ', h('code', null, 'doz up'), ' there makes the same sandbox. The same as ', h('code', null, 'doz init'), ' in a terminal.'],
      [btn('One-page form', () => createDialog(), { quiet: true, small: true, icon: 'list-checks', title: 'All choices on one page (an isolated sandbox, no project file)' })],
      { list: stepper, compact }),
    form);
  nw.node = node;
  return node;
}
// ── 599h: the wizard's last step — "Setting up tools" ───────────────────────
// The sandbox starts here, and its TOOLS LAYER is set up with it (the host's start: gh for GitHub as you,
// the ssh client + github.com's host keys for SSH forwarding, tmux, git/curl/ca-certificates): each tool with
// its reason, the start's progress line, then ✓/✗. A failure never blocks: Retry (`tools-apply`) or Continue
// anyway. "Open the sandbox" then opens it.
function nwToolsNode(nw) {
  const t = nw.tools, plan = t.plan;
  const steps = (nw.steps || []).concat([{ id: 'tools', title: 'Setting up tools' }]);
  const { list: stepper, compact } = stepperNode(steps, steps.length - 1, { data: 'data-nw-step', note: (s) => nwAnswer(s.id) });
  const last = new Map(((plan && plan.last && plan.last.results) || []).map((r) => [r.id, r]));
  const busy = t.phase === 'starting' || t.phase === 'retrying';
  const rows = ((plan && plan.plan.items) || []).map((it) => {
    const r = busy ? null : last.get(it.id);
    const st = r ? (['ok', 'installed', 'removed'].includes(r.state) ? 'ok' : 'fail') : busy ? 'busy' : 'none';
    return h('li', { class: 'tool-row tool-' + st, 'data-tool': it.id, 'data-tool-state': st },
      h('span', { class: 'tool-mark', 'aria-hidden': 'true' }, st === 'busy' ? h('span', { class: 'mini-spin' }) : st === 'ok' ? '✓' : st === 'fail' ? '✗' : '·'),
      h('span', { class: 'tool-title' }, it.title), h('span', { class: 'muted tool-reason' }, ' — ' + it.reason),
      r ? h('div', { class: (st === 'fail' ? 'st-fail' : 'muted') + ' tool-detail' }, r.detail) : null);
  });
  const failed = !busy && ((plan && plan.last) ? plan.last.results.some((r) => !['ok', 'installed', 'removed'].includes(r.state)) : !!t.error);
  // Open: its page with a live terminal on the image's own session (the boot already ran here).
  const open = () => {
    const name = t.name;
    state.nw = null;
    location.hash = '#/sandbox/' + name;
    openDefaultTerminal(name);                       // the image's own session, started (it is running), then attached
  };
  const buttons = busy ? [] : failed
    ? [btn('Retry', () => nwRetryTools(nw), { icon: 'refresh-cw', title: 'Set the tools up again now' }), btn('Continue anyway', open, { primary: true, icon: 'arrow-right' })]
    : [btn('Open the sandbox', open, { primary: true, icon: 'box' })];
  const node = h('div', { class: 'wizard nw', 'data-nw': 'tools' },
    wizHead('New sandbox', t.name + ' is made. Now it starts, and Dozer sets up the tools its settings call for — the tools layer, on any base, without rebuilding an image.',
      [], { list: stepper, compact }),
      h('section', { class: 'wiz-card', 'data-nw-tools': t.phase },
        h('div', { class: 'w-body' },
          h('h2', null, 'Setting up tools'),
          plan ? h('ul', { class: 'plain tool-list' }, rows) : h('p', { class: 'muted' }, 'Reading the tools layer…'),
          h('p', { class: 'muted mono tools-progress', 'data-tools-progress': '', 'aria-live': 'polite' }, busy ? (t.progress || 'starting…') : ''),
          t.error ? callout('bad', { cls: 'notice', attrs: { 'data-tools-error': '' }, body: t.error }) : null,
          failed ? h('p', { class: 'muted' }, 'Something could not be set up — the sandbox works without it. Retry, or continue; ', h('code', null, 'doz tools ' + t.name + ' --apply'), ' tries again later.') : null),
        h('div', { class: 'w-foot wiz-buttons' }, h('span', { class: 'wiz-gap' }), buttons)));
  nw.node = node;
  return node;
}
async function nwFollow(nw, op) {
  const t = nw.tools;
  const tick = setInterval(() => {
    const o = state.ops.get(op.id);
    if (o && o.text && o.text !== t.progress) {
      t.progress = o.text;
      const p = $('wm-box').querySelector('[data-tools-progress]');
      if (p) p.textContent = o.text;
    }
  }, 300);
  const end = await waitOp(op.id, 1800000);
  clearInterval(tick);
  return end;
}
async function nwToolsRead(nw) {
  try { nw.tools.plan = await api('sandboxes/' + nw.tools.name + '/tools'); } catch (e) { nw.tools.error = nw.tools.error || (e.message || String(e)); }
}
async function nwRunTools(nw) {
  const t = nw.tools;
  await nwToolsRead(nw);
  if (state.nw === nw) nwRender();
  try {
    const op = await actOrThrow({ action: 'start', sandbox: t.name });
    const end = await nwFollow(nw, op);
    if (!end || end.state !== 'done') t.error = 'The start did not finish: ' + (end ? end.text : 'no answer');
  } catch (e) { t.error = e.message || String(e); }
  await nwToolsRead(nw);
  t.phase = 'done';
  if (state.nw === nw) nwRender();
}
async function nwRetryTools(nw) {
  const t = nw.tools;
  t.phase = 'retrying'; t.error = ''; t.progress = '';
  nwRender();
  try {
    const op = await actOrThrow({ action: 'tools-apply', sandbox: t.name });
    const end = await nwFollow(nw, op);
    if (!end || end.state !== 'done') t.error = end ? end.text : 'no answer';
  } catch (e) { t.error = e.message || String(e); }
  await nwToolsRead(nw);
  t.phase = 'done';
  if (state.nw === nw) nwRender();
}
async function nwGo(i) {
  const nw = state.nw;
  nw.error = '';
  try {
    await nw.collect(i > nw.step);
  } catch (e) {
    // Back never stops on the step's own check (the folder step's excepted: nothing is open without it).
    if (i > nw.step || nw.step === 0) {
      nw.error = e.message || String(e);
      nwRender();
      return;
    }
  }
  if (!nw.form) { nwRender(); return; }
  nw.step = Math.max(0, Math.min(i, nw.steps.length - 1));
  nw.reached = Math.max(nw.reached, nw.step);
  nwRender();
}

function nwFolder() {
  const nw = state.nw;
  const radio = (value, label, extra) => {
    const r = h('input', { type: 'radio', name: 'nw-folder', value, 'data-nw-mode': value });
    r.checked = nw.mode === value;
    r.addEventListener('change', () => { if (r.checked) { nw.mode = value; nw.open = null; nw.form = null; nwRender(); } });
    return h('label', { class: 'wiz-choice' + (nw.mode === value ? ' chosen' : '') }, r, h('span', null, label, extra));
  };
  const name = h('input', { type: 'text', name: 'nw-new-name', 'data-nw-new-name': '', autocomplete: 'off', spellcheck: 'false', placeholder: 'a-z 0-9 -' });
  name.value = nw.newName;
  const where = h('div', { class: 'muted mono', 'data-nw-new-path': '' }, nw.projectsDir + '/' + nw.newName);
  name.addEventListener('input', () => { nw.newName = name.value.trim(); where.textContent = nw.projectsDir + '/' + nw.newName; nw.open = null; nw.form = null; });
  const path = h('input', { type: 'text', name: 'nw-path', 'data-nw-path': '', autocomplete: 'off', spellcheck: 'false', placeholder: '~/code/my-app' });
  path.value = nw.path;
  path.addEventListener('input', () => { nw.path = path.value.trim(); nw.open = null; nw.form = null; });
  const choose = btn('Choose…', async () => {
    try {
      const r = await api('workspace/choose', { method: 'POST', json: nw.path ? { start: nw.path } : {} });
      if (r.cancelled) return;
      nw.path = r.path; nw.mode = 'existing'; nw.open = null; nw.form = null;
      nwRender();
    } catch (e) { nw.error = e.message || String(e); nwRender(); }
  }, { small: true, icon: 'folder', title: 'This Mac’s folder picker' });
  choose.dataset.nwChoose = '';
  const found = nw.open && nw.open.file
    ? callout('info', { cls: 'notice', icon: 'layout-template', attrs: { 'data-nw-found': nw.open.file }, body: ['This folder has ', h('code', null, nw.open.file),
        ' — the wizard starts from it; the review shows what changes before anything is written.'] }) : null;
  const el = h('div', { class: 'wiz-choices' },
    radio('new', 'A new folder in your projects folder', h('div', { class: 'nw-sub' }, h('label', { class: 'field' }, h('span', null, 'Folder name'), name), where)),
    radio('existing', 'A folder you have (your project)', h('div', { class: 'nw-sub' }, h('label', { class: 'field' }, h('span', null, 'Folder'), h('div', { class: 'row' }, path, choose)),
      h('small', { class: 'muted' }, 'Shared at /workspace. If it has a doz_project.yaml (or .yml), the wizard starts from it.'))),
    found);
  return {
    el,
    async collect() {
      if (nw.mode === 'new' && !/^[a-z0-9][a-z0-9-]{0,39}$/.test(nw.newName)) throw new Error('The folder name: 1–40 of a-z 0-9 - (it is also the sandbox’s name).');
      const folder = nw.mode === 'new' ? nw.projectsDir + '/' + nw.newName : nw.path;
      if (!folder) throw new Error('Choose a folder.');
      if (nw.open && nw.form) return;
      const r = await api('project/open', { method: 'POST', json: { folder } });
      if (r.error) throw new Error(r.error);
      nw.open = r;
      nw.steps = r.steps;
      nw.form = JSON.parse(JSON.stringify(r.form));
      nw.explicit = new Set(r.explicit);
      nw.reached = r.file ? r.steps.length - 1 : 0;
    },
  };
}
function nwImage() {
  const nw = state.nw, f = nw.form;
  const name = h('input', { type: 'text', name: 'nw-name', 'data-nw-name': '', autocomplete: 'off', spellcheck: 'false', placeholder: 'a-z 0-9 -' });
  name.value = f.name;
  name.addEventListener('input', () => { f.name = name.value.trim(); nw.preview = null; });
  const picker = imagePicker({ images: nw.images, bases: nw.bases, value: f.dockerfile ? (f.agent === 'pi' ? 'pi' : f.agent === 'none' ? 'lab' : 'claude-code') : f.image,
                               dockerfile: f.dockerfile || '', onChange: () => {} });
  const el = h('div', { class: 'nw-fields' }, h('label', { class: 'field' }, h('span', null, 'Sandbox name'), name, h('small', { class: 'muted' }, 'Its name in doz ls and the dashboard.')), picker.el);
  return {
    el,
    collect() {
      if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(f.name || '')) throw new Error('The name: 1–40 of a-z 0-9 - (not starting with -).');
      const why = picker.blocked();
      if (why) throw new Error(why);
      const before = f.image + '|' + (f.dockerfile || '');
      const df = picker.dockerfile();
      f.image = picker.image();
      if (df) { f.dockerfile = df; f.agent = picker.agent() || 'none'; delete f.base; } else { delete f.dockerfile; delete f.agent; delete f.base; }
      if (before !== f.image + '|' + (f.dockerfile || '')) nw.preview = null;
    },
  };
}
function nwAccount() {
  const nw = state.nw, f = nw.form, agent = nwAgent(f);
  if (!agent) return { el: h('p', { class: 'muted', 'data-nw-no-account': '' }, 'This image runs no agent: it needs no account.') };
  if (!nwPermissionNet(nwNetwork(f)) && nwNetwork(f) !== 'bake') {
    return { el: h('p', { class: 'muted' }, 'Its network (' + nwNetwork(f) + ') reaches no account’s API: it uses none.') };
  }
  const acct = accountChooser({ accounts: nw.accounts, agent: () => agent, defaultValue: 'default', value: f.account || null,
                                onChange: () => { nwSet('account', acct.get() || 'default'); } });
  return {
    el: h('div', { class: 'nw-fields' }, acct.el, h('small', { class: 'muted' }, 'The account the Mac’s proxy uses for it — the sandbox only ever sees a placeholder.')),
    collect() { if (!acct.ok()) throw new Error((AGENT_NAMES[agent] || 'This agent') + ' needs an Anthropic API key — add one above, or go back and choose another agent.'); },
  };
}
function nwAccess() {
  // 599e's Access component (the onboarding wizard's and Settings' own), for THIS sandbox: GitHub as you
  // (off · read-only · read and push, and where the token comes from) and SSH agent forwarding, each choice
  // confirmed live on Next (Skip · Turn it off · Check again — never a dead end). It writes nothing but the
  // default GitHub key; the choices go into this project's file (github, ssh_agent) and so the create request.
  const nw = state.nw, f = nw.form, net = nwNetwork(f);
  const box = h('div', { class: 'wiz-access', 'data-nw-access': '' });
  if (!nw.access) {
    nw.access = {};
    nw.accessStart = { github: f.github || setting('defaults.github', 'off'),
                       githubSource: setting('github.credentials', 'gh') === 'key' ? 'key' : 'gh',
                       ssh: f.sshAgent || setting('sandbox.ssh_agent', 'off') };
  }
  const ctl = renderAccessStep(box, { mode: 'sandbox', state: nw.access, choices: nw.accessStart, onChange: (c) => {
    if (c.github !== (f.github || setting('defaults.github', 'off'))) nwSet('github', c.github);
    if (c.ssh !== (f.sshAgent || setting('sandbox.ssh_agent', 'off'))) nwSet('ssh_agent', c.ssh);
  } });
  const note = nwPermissionNet(net) ? null
    : callout('warn', { cls: 'notice', attrs: { 'data-nw-github-net': net }, body: 'GitHub as you needs a network with permissions (agent, locked or open) — this sandbox’s is ' + net +
      '. Choose it under Permissions and network, or leave GitHub off.' });
  return {
    el: h('div', { class: 'nw-fields' }, note, box),
    async collect(forward) {
      // Next (and Skip to review) confirms; Back keeps the choices without a check.
      if (!ctl.choices().github) return;                    // not read yet: nothing chosen here
      if (forward && !(await ctl.confirm())) throw new Error('Not everything is confirmed — Skip it, turn it off, or check again.');
      const c = ctl.choices();
      // Kept as chosen (a default that was not changed stays the setting's — commented in the file).
      if (c.github !== (f.github || setting('defaults.github', 'off')) || nw.explicit.has('github')) nwSet('github', c.github);
      if (c.ssh !== (f.sshAgent || setting('sandbox.ssh_agent', 'off')) || nw.explicit.has('ssh_agent')) nwSet('ssh_agent', c.ssh);
    },
  };
}
/// 599g (owner A2): the Workspace rules step — the onboarding's description, what the chosen folder already has
/// (its .dozignore / .dozreadonly, from project/open; Look again reads them again), and THIS sandbox's mode
/// (`ignore_mode` in its file — written only when it differs from the setting, or the file set it).
function nwRules() {
  const nw = state.nw, f = nw.form;
  const look = async () => {
    try {
      const r = await api('project/open', { method: 'POST', json: { folder: nw.open.folder } });
      nw.open.rules = r.rules || [];
      nw.open.exists = r.exists;
      nwRender();
    } catch (e) { nw.error = e.message || String(e); nwRender(); }
  };
  return {
    el: h('div', { class: 'nw-fields' },
      rulesStep({ mode: 'sandbox', guide: nw.open.rulesGuide, value: f.ignoreMode || setting('workspace.ignore_mode', 'lock'),
                  folder: nw.open, onLookAgain: look,
                  onPick: (v) => { if (v !== (f.ignoreMode || setting('workspace.ignore_mode', 'lock')) || nw.explicit.has('ignore_mode')) nwSet('ignore_mode', v); } })),
  };
}
function nwPermissions() {
  const nw = state.nw, f = nw.form, b = nw.bases;
  const nets = [['', 'default for this image (' + setting('images.' + nwSection(f) + '.network', nwSection(f) === 'lab' ? 'bake' : 'agent') + ')'],
                ['agent', 'agent — proxied: what the agent may do is its permissions'], ['bake', 'bake — proxied: package registries only'],
                ['locked', 'locked — proxied: its AI model only'], ['open', 'open — proxied: everything, still logged'],
                ['nat', 'nat — a real network interface, unfiltered'], ['none', 'none — no network']];
  const sel = h('select', { name: 'network', 'data-nw-network': '', 'aria-label': 'Network' }, nets.map(([v, l]) => h('option', { value: v }, l)));
  sel.value = f.network || '';
  sel.addEventListener('change', () => { nwSet('network', sel.value || null); if (!sel.value) nw.explicit.delete('network'); nwRender(); });
  const parts = [h('label', { class: 'field' }, h('span', null, 'Network'), sel)];
  if (b && b.permissions && nwPermissionNet(nwNetwork(f))) {
    const base = nwBase(f);
    const rows = b.permissions.filter((r) => r.group !== 'github');
    const std = new Set((b.standard[base] || b.standard[''] || []).filter((x) => !x.startsWith('github:')));
    const all = rows.map((r) => r.id).filter((x) => !isAgentModel(x));
    const fromWords = (ws) => {
      let s = new Set(std);
      for (const w of ws) {
        if (w === 'standard') s = new Set(std);
        else if (w === 'locked') s = new Set(['model']);
        else if (w === 'open') s = new Set(all);
        else if (w.startsWith('-')) s.delete(w.slice(1));
        else s.add(w.startsWith('+') ? w.slice(1) : w);
      }
      return s;
    };
    const words = (on) => {
      const same = (a, c) => a.size === c.size && [...a].every((x) => c.has(x));
      if (same(on, std)) return 'standard';
      if (same(on, new Set(['model']))) return 'locked';
      if (same(on, new Set(all))) return 'open';
      return [...all.filter((x) => on.has(x) && !std.has(x)).map((x) => '+' + x), ...all.filter((x) => !on.has(x) && std.has(x)).map((x) => '-' + x)].join(',');
    };
    const on = fromWords((f.permissions || setting('defaults.permissions', 'standard')).split(',').map((x) => x.trim()).filter(Boolean));
    const label = words(on);
    const preset = (name, set) => {
      const bt = btn(name[0].toUpperCase() + name.slice(1), () => { nwSet('permissions', words(set)); nwRender(); }, { small: true, icon: name === 'locked' ? 'shield' : name === 'open' ? 'eye' : 'check' });
      bt.dataset.nwPreset = name;
      return bt;
    };
    parts.push(h('div', { class: 'field perm-field', 'data-nw-permissions': label },
      h('span', null, 'What the agent can do ', h('code', { 'data-nw-perm-words': '' }, label)),
      h('div', { class: 'row' }, preset('locked', new Set(['model'])), preset('standard', std), preset('open', new Set(all))),
      permissionSwitches(rows, on, (id, v) => {
        const apply = () => {
          const inst = rows.filter((x) => x.group === 'install').map((x) => x.id);
          for (const x of id === 'install' ? inst : [id]) { if (v) on.add(x); else on.delete(x); }
          nwSet('permissions', words(on));
          nwRender();
        };
        if (id === 'web' && v) confirmWeb(async () => apply()); else apply();
      }, { hosts: true, agent: nwAgent(f) })));
  } else {
    parts.push(h('p', { class: 'muted' }, 'A ' + nwNetwork(f) + ' network has no permissions to choose.'));
  }
  return { el: h('div', { class: 'nw-fields' }, parts) };
}
function nwResources() {
  const nw = state.nw, f = nw.form, sec = nwSection(f);
  const cpus = h('input', { type: 'number', min: '1', max: '64', name: 'cpus', 'data-nw-cpus': '' });
  cpus.value = String(f.cpus || setting('defaults.cpus', 2));
  cpus.addEventListener('change', () => nwSet('cpus', Number(cpus.value)));
  const memMiB = Number(setting('images.' + sec + '.memory_mib', sec === 'lab' ? 1024 : 2048));
  const mem = h('input', { type: 'text', name: 'memory', 'data-nw-memory': '', placeholder: '2G, 512M' });
  mem.value = f.memory || (memMiB % 1024 === 0 ? memMiB / 1024 + 'G' : memMiB + 'M');
  mem.addEventListener('change', () => nwSet('memory', mem.value.trim()));
  return {
    el: h('div', { class: 'nw-fields' },
      h('label', { class: 'field' }, h('span', null, 'CPUs'), cpus, h('small', { class: 'muted' }, 'Virtual CPUs, 1–64.')),
      h('label', { class: 'field' }, h('span', null, 'Memory'), mem, h('small', { class: 'muted' }, 'Guest RAM, held only while it runs (2G, 512M).')),
      h('div', { class: 'field' }, h('span', null, 'Disk'), h('small', { class: 'muted' }, 'The image’s own, shared with it until the sandbox writes — not set per sandbox.'))),
    collect() {
      const n = Number(cpus.value);
      if (!Number.isInteger(n) || n < 1 || n > 64) throw new Error('CPUs: a whole number 1–64.');
      if (!/^\s*\d+(\.\d+)?\s*([gm](i?b)?)?\s*$/i.test(mem.value)) throw new Error('Memory: a size like 2G or 512M.');
    },
  };
}
function nwSelect(key, label, options, value, note) {
  const sel = h('select', { name: key, 'data-nw-setting': key, 'aria-label': label }, options.map(([v, l]) => h('option', { value: v }, l)));
  sel.value = value;
  sel.addEventListener('change', () => nwSet(key, sel.value));
  return h('label', { class: 'field' }, h('span', null, label), sel, note ? h('small', { class: 'muted' }, note) : null);
}
function nwBridges() {
  const f = state.nw.form;
  return {
    el: h('div', { class: 'nw-fields' },
      nwSelect('clipboard', 'Clipboard', [['write', 'write — a copy in the sandbox reaches the Mac clipboard, with a notice'], ['off', 'off']],
        f.clipboard || setting('sandbox.clipboard', 'write')),
      nwSelect('browser_bridge', 'Browser', [['on', 'on — links opened in the sandbox open in the Mac’s browser'], ['off', 'off']],
        f.browserBridge || setting('sandbox.browser_bridge', 'on')),
      nwSelect('open_files', 'Workspace files', [['on', 'on — documents opened in the sandbox open on the Mac, with a notice'], ['off', 'off']],
        f.openFiles || setting('sandbox.open_files', 'on'))),
  };
}
function nwSession() {
  const nw = state.nw, f = nw.form;
  const box = (key, label, value) => {
    const c = h('input', { type: 'checkbox', role: 'switch', 'data-nw-check': key });
    c.checked = value;
    c.addEventListener('change', () => nwSet(key, c.checked));
    return h('label', { class: 'field check' }, c, h('span', null, label));
  };
  const prompt = h('textarea', { name: 'agentPrompt', rows: 3, 'data-nw-prompt': '', placeholder: 'e.g. The tests run with `make test`.', spellcheck: 'false' });
  prompt.value = f.agentPrompt || '';
  prompt.addEventListener('change', () => { f.agentPrompt = prompt.value.trim() ? prompt.value.replace(/\s+$/, '') : null; nw.preview = null; });
  return {
    el: h('div', { class: 'nw-fields' },
      box('tmux', 'Run its sessions inside tmux (windows, panes, Ctrl-b)', f.tmux !== undefined && f.tmux !== null ? f.tmux : setting('sessions.tmux', false) === true),
      box('agent_sudo', 'The agent has passwordless sudo (apt-get install …)', f.agentSudo !== undefined && f.agentSudo !== null ? f.agentSudo : setting('sandbox.agent_sudo', true) === true),
      h('label', { class: 'field' }, h('span', null, 'This project’s lines for the agent (optional)'), prompt,
        h('small', { class: 'muted' }, 'Added to what the agent is told about its sandbox, from its next session.')),
      f.sessions && f.sessions.length ? h('p', { class: 'muted', 'data-nw-sessions': '' }, 'Sessions the file starts (kept): ' + f.sessions.map((s) => s.name).join(', ')) : null),
  };
}
function nwReview() {
  const nw = state.nw;
  const pre = h('pre', { class: 'nw-yaml', 'data-nw-yaml': '' }, nw.preview ? nw.preview.text : 'Reading…');
  const where = h('div', { class: 'muted mono', 'data-nw-file': '' }, nw.preview ? nw.preview.path : '');
  const diffBox = h('div', { 'data-nw-diff-box': '' });
  const go = btn(nw.open && nw.open.file ? 'Replace the file and create' : 'Write and create', () => nwCreate(go), { primary: true, lg: true, icon: 'rocket' });
  go.dataset.nwCreate = '';
  go.disabled = !nw.preview;
  const paint = () => {
    pre.textContent = nw.preview.text;
    where.textContent = nw.preview.path;
    diffBox.replaceChildren(nw.preview.existing === undefined || nw.preview.existing === null ? h('small', { class: 'muted' }, 'A new file.')
      : nw.preview.existing === nw.preview.text ? h('small', { class: 'muted', 'data-nw-same': '' }, 'The same as the file there now — nothing to write.')
      : h('small', { class: 'muted' }, 'It replaces the file there now — you see what changes before it is written.'));
    go.disabled = false;
  };
  if (nw.preview) setTimeout(paint, 0);
  else {
    api('project/preview', { method: 'POST', json: nwPayload() }).then((p) => { nw.preview = p; if (state.modal === 'new' && state.nw === nw) { paint(); pre.dispatchEvent(new Event('nw-preview')); } })
      .catch((e) => { pre.textContent = ''; const err = $('wm-box').querySelector('[data-nw-error]'); if (err) err.textContent = e.message || String(e); });
  }
  // 603 (E15, owner decision 11): what will happen first — the choices as facts, then the steps — and the file,
  // exactly as written, one click away (the replace diff still comes before an existing file is replaced).
  const f = nw.form, fact = (k, v) => (v ? [h('dt', null, k), h('dd', null, v)] : null);
  const img = nw.images.find((x) => x.name === f.image);
  const willPrepare = !f.dockerfile && img && !img.baked;
  const lines = h('span', { 'data-nw-lines': '' }, '');
  const disclosure = h('details', { class: 'disclosure nw-file' }, h('summary', null, icon('chevron-down'), 'The file, exactly as written', lines), where, pre);
  const lineCount = () => { lines.textContent = nw.preview ? ' (' + plural(nw.preview.text.split('\n').filter((l, i, a) => i < a.length - 1 || l).length, 'line', 'lines') + ')' : ''; };
  if (nw.preview) setTimeout(lineCount, 0);
  else pre.addEventListener('nw-preview', lineCount);
  return {
    el: h('div', { class: 'nw-fields nw-review' },
      h('dl', { class: 'facts' },
        fact('Folder', [h('code', null, nwAnswer('folder')), nw.open && nw.open.file ? ' — ' + nw.open.file + ' is there' : ' — doz_project.yaml is new']),
        fact('Sandbox', f.name + ' · ' + (f.dockerfile ? 'your Dockerfile' : f.image) + ' · ' + nwAnswer('resources')),
        fact('Account', nwAnswer('account')),
        fact('Network', nwAnswer('permissions')),
        fact('Access', nwAnswer('access')),
        fact('Workspace rules', nwAnswer('rules')),
        fact('Bridges', nwAnswer('bridges') + ' · files ' + (f.openFiles || setting('sandbox.open_files', 'on'))),
        fact('Session', nwAnswer('session') + ' · sudo ' + ((f.agentSudo ?? setting('sandbox.agent_sudo', true)) ? 'yes' : 'no'))),
      callout('info', { compact: true, attrs: { 'data-nw-what': '' }, body: ['Writing the file, then making the sandbox as ', h('code', null, 'doz up'),
        ' would there, starting it and setting up its tools; then it opens.', willPrepare ? ' The first start prepares the ' + f.image + ' image (minutes, needs network).' : ''] }),
      diffBox, disclosure),
    extra: go,
  };
}
function nwDiffNode(lines) {
  return h('pre', { class: 'nw-diff', 'data-nw-diff': '' }, lines.map((l) => h('div', { class: l.startsWith('+ ') ? 'add' : l.startsWith('- ') ? 'del' : 'same' }, l)));
}
async function nwCreate(button) {
  const nw = state.nw, p = nw.preview;
  const run = async (replace) => {
    button.disabled = true;
    try {
      const body = nwPayload();
      if (replace) body.replace = replace;
      const w = await api('project/write', { method: 'POST', json: body });
      toast((w.written ? 'Wrote ' : 'Kept ') + w.path);
      const op = await actOrThrow({ action: 'project-create', folder: w.folder });
      const end = await waitOp(op.id);
      if (!end || end.state !== 'done') { button.disabled = false; return; }
      // 599h: the last step — "Setting up tools": the start, with the sandbox's tools layer, before it opens.
      nw.tools = { name: nw.form.name, plan: null, phase: 'starting', progress: '', error: '' };
      nwRender();
      await nwRunTools(nw);
    } catch (e) {
      button.disabled = false;
      const err = $('wm-box').querySelector('[data-nw-error]');
      if (err) err.textContent = e.message || String(e); else pageFailure(e.message || String(e));
    }
  };
  if (p.existing !== undefined && p.existing !== null && p.existing !== p.text) {
    const d = dialog('Replace ' + p.path.split('/').pop() + '?', 'The folder has a project file. These lines change (− there now, + to be written):',
      [], 'Replace it', async () => { await run(p.replace); }, { danger: true });
    d.querySelector('.dlg-body > p.sub').after(nwDiffNode(p.diff.filter((l) => !l.startsWith('  '))));
    d.dataset.nwConfirm = '';
    return;
  }
  await run(null);
}

// ── a sandbox's page (593): a control bar, the terminal area, a collapsible details panel ──────
// #sbx is persistent: refreshSandbox() re-renders the bar and the details, never #terminals.
let sbxRefreshing = false, sbxAgain = false;
async function showSandbox() {
  const name = state.param;
  const want = state.session;                  // the addressed session (renderTerminals re-points the URL)
  const first = !state.sbx || state.sbx.name !== name;
  if (first) {
    state.sbx = { name, d: null };
    $('sbx-bar').replaceChildren(h('div', { class: 'sbx-title' }, h('h1', null, name)));
    $('sbx-details').replaceChildren();
    $('main').scrollTop = 0;
  }
  renderTerminals();
  // What arriving does needs the sandbox's detail: it runs once, after whichever refresh loads it first
  // (a refresh already in flight — the stream's hello — may be the one; this one then returns early).
  state.arrival = { name, want };
  await refreshSandbox();
  takeArrival(name);
}
function takeArrival(name) {
  const a = state.arrival;
  if (!a || a.name !== name || !state.sbx || state.sbx.name !== name || !state.sbx.d) return;
  state.arrival = null;
  sandboxArrived(a.name, a.want);
}
async function refreshSandbox() {
  // A re-run queued while the page was a sandbox's may come after it left for another page (593 §9:
  // it asked for sandboxes/null, got a 404 and sent the grid to the overview).
  if (state.view !== 'sandbox' || !state.param) return;
  if (sbxRefreshing) { sbxAgain = true; return; }
  sbxRefreshing = true;
  const name = state.param;
  try {
    const gen = state.trGen;
    const [d, net, accounts] = await Promise.all([api('sandboxes/' + name), api('sandboxes/' + name + '/network'), api('accounts').catch(() => ({ accounts: [] }))]);
    if (state.view !== 'sandbox' || state.param !== name || state.signedOut) return;
    // A transition began or ended while this was read: what it read may be the phase before — read again.
    if (gen !== state.trGen) { sbxAgain = true; return; }
    state.sbx = { name, d, net, accounts };
    if ($('sbx-bar').querySelector('.menu:not([hidden])') || $('sbx-details').querySelector('.menu:not([hidden])')) { state.sbxHeld = true; return; }
    const parts = sandboxParts(name, d, net, accounts);
    $('sbx-bar').replaceChildren(parts.bar);
    $('sbx-details').replaceChildren(parts.details);
    $('sbx-body').classList.toggle('details-closed', !setting('ui.details_open', true));
    paintRowOps();
    paintTermEmpty();
    paintStripActs();
    // 593 §9: saved panes go live once it runs (their sessions listed by the detail), or repaint.
    promoteSaved(name, d.info.phase === 'running' && !d.info.busy && d.sessions ? d.sessions.filter((x) => !x.ended).map((x) => x.name) : null);
    paintTabs();
    takeArrival(name);
    // An arrival that found it under way restores once it has settled (never over a tab opened since).
    const sv = sview(name);
    if (sv.deferred && !sv.restoring && !d.info.busy && d.info.phase !== 'booting' && !opRunningFor(name)) {
      if (pageTerminals(name).length) { sv.deferred = false; sv.restored = true; } else restorePanes(name);
    }
  } catch (e) {
    if (e.status === 404) { if (state.view === 'sandbox' && state.param === name) location.hash = '#/overview'; return; }
    if (!state.signedOut) failureFor(name, e.message || String(e));
  } finally {
    sbxRefreshing = false;
    if (sbxAgain) { sbxAgain = false; refreshSandbox(); }
  }
}
/// On arriving at a sandbox's page: an addressed session (#/sandbox/NAME/SESSION, from the grid)
/// gets its tab — opened, or selected; otherwise, when the sandbox runs and its own session runs,
/// the page attaches to it (explicit viewing of a live VM, which keeps nothing alive the VM does
/// not). A sandbox that is not running shows the empty area's actions instead.
async function sandboxArrived(name, want) {
  const s = state.sbx;
  if (!s || s.name !== name || !s.d) return;
  const mine = [...terminals.values()].filter((t) => !t.grid && t.sandbox === name);
  const running = s.d.info.phase === 'running';
  const live = (s.d.sessions || []).filter((x) => !x.ended).map((x) => x.name);
  // 593 §9 (S1): the panes the host kept for this sandbox, the first time this page shows it.
  if (!mine.length) await restorePanes(name);
  if (want) {
    const have = pageTerminals(name).find((t) => t.session === want && t.mode === 'interactive' && !t.ended);
    if (have) { const v = sview(name); v.selected[have.pane] = have.id; v.focusedPane = have.pane; renderTerminals(); if (!have.saved) focusTerm(have); }
    else if (running && live.includes(want)) openTerminal(name, want, 'interactive');
    else if (!running && (await savedRows(name)).some((r) => r.name === want)) openSavedTerminal(name, (await savedRows(name)).find((r) => r.name === want));
    else failureFor(name, 'Session ' + want + ' is not running in ' + name);
    return;
  }
  if (!pageTerminals(name).length && running && live.includes(s.d.defaultSession) && setting('ui.terminals', true) && !sview(name).restoredAny) {
    openTerminal(name, s.d.defaultSession, 'interactive');
  }
}

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
function persistLayout(name) {
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
async function savedRows(name) {
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
function openSavedTerminal(name, row, pane) {
  if (!terminalsAllowed() || !row) return;
  const v = sview(name);
  const have = pageTerminals(name).find((t) => t.session === row.name && t.saved);
  const t = have || addTab(name, row.name, 'interactive', v.split ? (pane ?? v.focusedPane) : 0, row);
  v.selected[t.pane] = t.id;
  renderTerminals();
}
/// Restore the stored layout: a RUNNING sandbox's tabs whose sessions run attach; a paused, asleep or
/// hibernated one shows every session it has a saved screen of (S3) — the layout's first, in their panes.
async function restorePanes(name) {
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
/// 603: a sandbox's terminal in the user's own terminal app (doz attach), from the bar, the strip or a session row.
async function openInTerminal(name, session) {
  try {
    const r = await api('sandboxes/' + name + '/terminal', { method: 'POST', json: session ? { session } : {} });
    toast(r.message, false, 'square-terminal');
  } catch (e) { failureFor(name, e.message); }
}
function runDetachedDialog(name) {
  dialog('Run a command in ' + name, 'A new session running the command — no shell in front (say bash -lc \'…\' for one). It runs inside the sandbox; attach to see it.',
    [{ name: 'session', label: 'Session name', placeholder: 'e.g. worker', required: true },
     { name: 'command', label: 'Command', placeholder: 'sleep 600', required: true }], 'Run', async (v) => {
      const argv = splitArgs(v.command);
      if (!argv.length) throw new Error('the command is empty');
      await actOrThrow({ action: 'open-session', sandbox: name, session: v.session, argv });
    });
}
function takePointDialog(name, running) {
  dialog('Take a restore point of ' + name, running ? 'A running sandbox pauses for the clone (milliseconds); its copy gets e2fsck on the first boot from it.' : 'An instant APFS clone of the disks.',
    [{ name: 'point', label: 'Name', placeholder: 'default point-N' }, { name: 'note', label: 'Note' }], 'Take', async (v) => {
      const b = { action: 'point-take', sandbox: name };
      if (v.point) b.point = v.point;
      if (v.note) b.note = v.note;
      await actOrThrow(b);
    });
}
/// 603: the inspector's tabs — the selected one is kept per sandbox in this page (owner decision 4).
const INSP_TABS = [['overview', 'Overview', 'Overview', 'info'], ['sessions', 'Sessions', 'Sessions', 'terminal'], ['points', 'Points', 'Restore points', 'history'],
                   ['network', 'Network', 'Network', 'shield'], ['keys', 'Keys', 'Keys & account', 'key-round'], ['config', 'Config', 'Configuration', 'settings']];
function inspShow(name, tab) {
  sview(name).inspTab = tab;
  const root = $('sbx-details');
  for (const b of root.querySelectorAll('.itab')) b.setAttribute('aria-selected', b.dataset.inspTab === tab ? 'true' : 'false');
  for (const p of root.querySelectorAll('.ipanel')) p.hidden = p.dataset.insp !== tab;
  root.scrollTop = 0;
}
function sandboxParts(name, d, net, accounts) {
  const i = d.info;
  const running = i.phase === 'running';
  const whyNot = sessionsWhyNot(name, i);
  const gated = (b) => { if (whyNot) { b.disabled = true; b.title = whyNot; } return b; };
  const fact = (k, v) => [h('dt', null, k), h('dd', null, v)];
  const copy = btn('Copy the command', async (ev) => {
    const b = ev.currentTarget;
    try { await navigator.clipboard.writeText(d.attachCommand); setButton(b, 'Copied', 'check'); } catch (_) { setButton(b, 'Select and copy', 'clipboard'); }
    setTimeout(() => { setButton(b, 'Copy the command', 'copy'); }, 1500);
  }, { small: true, quiet: true, iconOnly: true, icon: 'copy' });
  // 593 §9: paused, asleep or hibernated — the sessions as last saved, each can be shown (its saved
  // screen). A shut-down sandbox has none (owner, 2026-09-30).
  const savedState = (s) => 'screen saved ' + when(s.savedAt) + (s.savedReason ? ' (' + s.savedReason + ')' : '');
  const live = (d.sessions || []).filter((s) => !s.ended && !s.saved);
  const sessions = (d.sessions || []).map((s) => h('tr', { 'data-session': s.name },
    h('td', null, h('div', { class: 'cell-name' }, h('span', { class: 'dot ph-' + (s.saved ? i.phase : s.ended ? 'off' : 'running'), 'aria-hidden': 'true' }),
        h('span', { class: 'nm' }, s.name), s.name === d.defaultSession ? h('span', { class: 'tag' }, 'default') : null),
      h('div', { class: 'sub2' }, s.saved ? savedState(s) : s.ended ? 'ended (exit ' + s.exitCode + ')' : 'running' + (s.cols ? ' · ' + s.cols + '×' + s.rows : '') + ' · ' + plural(s.clients, 'viewer', 'viewers'))),
    h('td', { class: 'mono trunc', title: s.command }, s.command),
    h('td', { class: 'row-acts-cell' }, h('div', { class: 'row-acts' }, s.saved
      ? btn('Show', () => openSavedTerminal(name, s), { small: true, quiet: true, icon: 'eye', title: 'Its last saved screen in a tab (read-only; it goes live when the sandbox runs)' })
      : s.ended ? null : [
        btn('Open', () => openTerminal(name, s.name, 'interactive'), { small: true, quiet: true, title: 'A terminal on this session, here in the browser' }),
        moreMenu('More for ' + s.name, [
          { label: 'Watch', icon: 'eye', desc: 'Read-only: nothing you type reaches it, it never resizes', onSelect: () => openTerminal(name, s.name, 'watch') },
          { label: 'Open in Terminal', icon: 'square-terminal', desc: 'In your terminal app (doz attach)', disabled: !!whyNot, why: whyNot, onSelect: () => openInTerminal(name, s.name) },
        ], { small: true, onClose: sbxMenuClosed }).el]))));
  const pointMenu = (p) => moreMenu('More for ' + p.name, [
    { label: 'Fork…', icon: 'git-fork', desc: 'A new sandbox whose disks are this point’s', onSelect: () => dialog('Fork ' + p.name, 'A new sandbox whose disks are this point’s (it cold-boots on start).',
      [{ name: 'newName', label: 'New sandbox name', required: true }], 'Fork', async (v) => { await actOrThrow({ action: 'point-fork', sandbox: name, point: p.id, newName: v.newName }); }) },
    { label: 'Save as template…', icon: 'layout-template', desc: 'Its root disk becomes a template (never its state disk)', onSelect: () => templateDialog(name, d, p.id) },
    { label: 'Duplicate…', icon: 'copy', desc: 'A new sandbox from this point', onSelect: () => duplicateDialog(name, d, accounts, p.id) },
    { sep: true },
    { label: 'Delete…', icon: 'trash-2', danger: true, desc: 'Only this restore point', onSelect: () => confirmAction('Delete ' + p.name, 'Delete the restore point “' + p.name + '” of ' + name + '.', name,
      { action: 'point-rm', sandbox: name, point: p.id }) },
  ], { small: true, onClose: sbxMenuClosed });
  const points = d.restorePoints.map((p) => h('tr', null,
    h('td', null, h('div', { class: 'nm' }, p.name), h('div', { class: 'sub2 mono trunc', title: p.id }, p.id)),
    h('td', { title: full(p.createdAt) }, when(p.createdAt), h('div', { class: 'sub2' }, p.takenWhile + (p.automatic ? ' (auto)' : '')),
      p.needsFsck ? h('div', { class: 'st-warn sub2' }, 'e2fsck on next boot') : null, p.note ? h('div', { class: 'sub2' }, p.note) : null),
    h('td', { class: 'row-acts-cell' }, h('div', { class: 'row-acts' },
      btn('Revert', () => confirmAction('Revert ' + name, 'Revert to “' + p.name + '”: it shuts down (running programs end); the current disk is kept as a restore point first. Start boots it.', name,
        { action: 'point-revert', sandbox: name, point: p.id }), { small: true, quiet: true, danger: true }),
      pointMenu(p).el))));
  const creds = d.credentials.map((c) => h('tr', null,
    h('td', null, c.binding, h('div', { class: 'sub2 trunc', title: c.hosts.join(', ') }, c.hosts.join(', '))),
    h('td', null, c.set ? 'set' : 'not set', ((t) => h('div', { class: 'sub2 trunc', title: t }, t))([c.source || '—', c.account ? 'account ' + c.account : null].filter(Boolean).join(' · '))),
    h('td', null, c.state || '—', c.expiresAt ? h('div', { class: 'sub2' }, 'expires ' + when(c.expiresAt)) : null, c.policy ? h('div', { class: 'sub2' }, 'policy ' + c.policy) : null),
    h('td', { class: 'row-acts-cell' }, c.set && c.source && !c.source.startsWith('account:')
      ? btn('Remove', () => act({ action: 'key-rm', sandbox: name, binding: c.binding }), { small: true, quiet: true }) : null)));
  const foreign = d.credentials.flatMap((c) => c.foreign).map((f) => h('tr', null,
    h('td', null, f.kind + (f.matches ? ' (= ' + f.matches + ')' : ''), h('div', { class: 'sub2 mono' }, f.prefix + '…')),
    h('td', { class: 'mono trunc', title: f.fingerprint }, f.fingerprint),
    h('td', null, f.header, h('div', { class: 'sub2' }, plural(f.requests, 'request', 'requests') + ' · ' + when(f.lastSeen)))));
  const proxied = net.proxied;
  const busy = i.busy || i.phase === 'booting' || opRunningFor(name) || !!transitionOf(name);
  const detailsOpen = setting('ui.details_open', true);
  const noDisk = !d.hasRootDisk;
  const holdWhy = busy ? 'Wait until it settles' : noDisk ? 'It has no disk yet — start it once' : null;
  const showTab = (tab) => () => {
    if (!setting('ui.details_open', true)) { $('sbx-body').classList.remove('details-closed'); saveSetting('ui.details_open', true).then(() => refreshSandbox()).catch(() => {}); }
    inspShow(name, tab);
  };
  // ── the bar: title row (name, phase, labelled chips) · toolbar (lifecycle, Shut down, ⋯ | status, details) ──
  const more = moreMenu('More: duplicate, save as template, boot log, reset, remove', [
    { label: 'Duplicate…', icon: 'copy', desc: 'A new sandbox from this disk', disabled: !!holdWhy, why: holdWhy, onSelect: () => duplicateDialog(name, d, accounts, null) },
    { label: 'Save as template…', icon: 'layout-template', desc: 'Its root disk becomes an image (never its state disk)', disabled: !!holdWhy, why: holdWhy, onSelect: () => templateDialog(name, d, null) },
    { label: 'Boot log', icon: 'history', desc: 'Its last boots: the steps and the kernel console', onSelect: () => bootLogDialog(name) },
    { sep: true },
    { label: 'Reset…', icon: 'rotate-ccw', danger: true, desc: 'Discard the disk — back to the image', disabled: busy, why: 'Wait until it settles', data: { 'lifecycle-item': name }, onSelect: () => lifecycle('reset', name) },
    { label: 'Remove…', icon: 'trash-2', danger: true, desc: 'The sandbox, its disks and restore points', disabled: busy, why: 'Wait until it settles', data: { 'lifecycle-item': name }, onSelect: () => lifecycle('rm', name) },
  ], { data: { sbxMore: name }, onClose: sbxMenuClosed });
  more.button.dataset.lifecycleMore = name;
  const detailsBtn = btn(detailsOpen ? 'Hide details' : 'Details', () => {
    const open = !setting('ui.details_open', true);
    $('sbx-body').classList.toggle('details-closed', !open);
    saveSetting('ui.details_open', open).then(() => refreshSandbox()).catch((e) => pageFailure('ui.details_open was not saved: ' + (e.message || e)));
  }, { quiet: true, iconOnly: true, icon: 'panel-right', title: (detailsOpen ? 'Hide' : 'Show') + ' the details: sessions, restore points, network, keys (remembered: ui.details_open)' });
  detailsBtn.setAttribute('aria-pressed', detailsOpen ? 'true' : 'false');
  const suggestions = net.permissions ? net.permissions.suggestions : [];
  const refused = suggestions.reduce((n, s) => n + s.count, 0);
  const bar = h('div', { class: 'sbx-bar-inner' },
    h('div', { class: 'sbx-title' },
      h('h1', null, name), sandboxPill(i),
      h('span', { class: 'chips sbx-meta' },
        chip('Image', h('span', { 'data-image-title': '' }, i.imageTitle || i.image), { title: i.image + (i.dockerfile ? ' — Dockerfile ' + i.dockerfile : '') }),
        chip('RAM', (i.ramHeldMiB ? mib(i.ramHeldMiB) : '—') + ' of ' + mib(i.memoryMiB)),
        chip('Network', [i.network, i.deniedConnections ? h('span', { class: 'tag warn' }, i.deniedConnections + ' denied') : null, icon('panel-right')],
          { onClick: showTab('network'), title: 'Its network — the Network tab', data: { 'data-network-chip': '' } }),
        i.accountApplies ? chip('Account', i.account || '—') : null,
        i.workspace ? null : h('span', { class: 'tag outline badge-isolated', 'data-isolated': '', title: ISOLATED_NOTE }, withIcon('shield', 'isolated')),
        // 599g: the workspace's .dozignore / .dozreadonly (the details say how many patterns and whether in force).
        i.workspaceRules ? h('span', { class: 'tag outline', 'data-workspace-rules': i.workspaceRulesView || '', title: 'Workspace rules: ' + i.workspaceRules + ' — doz ignore show ' + name },
          withIcon('shield', 'rules')) : null)),
    h('div', { class: 'sbx-actions toolbar', role: 'toolbar', 'aria-label': name },
      lifecycleBar(i), more.el,
      h('span', { class: 'spacer' }),
      // The status slot: the operation under way (a quiet line), or how it ended (a callout that stays on failure).
      h('div', { 'data-op-for': name, 'data-banner': '1', role: 'status' }),
      detailsBtn),
    i.credentialProblem ? credentialBanner(name, i, accounts) : null,
    // 594 W28: its system disk came from an image an older doz made.
    i.olderImage ? callout('warn', { compact: true, cls: 'cred-banner img-banner', icon: 'flame', attrs: { 'data-older-image': name }, body: name + ' was ' + i.olderImage + '.' }) : null,
    // 596 (B8): its Dockerfile changed (or was built again) — offered, never rebuilt by itself.
    i.rebuildAvailable ? callout('warn', { compact: true, cls: 'cred-banner img-banner', icon: 'flame', attrs: { 'data-rebuild-available': name }, body: i.rebuildAvailable + '.',
      actions: [btn('Rebuild the image', () => dialog('Rebuild ' + i.image + '?',
        'Runs container build again (seconds when nothing changed: its cache), then bakes only if the built image changed. ' + DOCKERFILE_POLICY_NOTE + ' This sandbox keeps its disk until you reset it.',
        [], 'Rebuild', async () => { await actOrThrow({ action: 'image-bake', image: i.image }); }, { icon: 'flame' }), { small: true, icon: 'flame' })] }) : null,
    // 597: what the agent was refused, said once here with the way to decide (the Network tab).
    refused ? callout('warn', { compact: true, attrs: { 'data-refused': name }, body: ['The agent was refused ' + plural(refused, 'time', 'times') + ' — ',
      ...suggestions.slice(0, 3).flatMap((s, n) => [n ? ', ' : '', h('strong', null, s.permission ? s.what : s.what), ' (' + s.count + ')']), '.'],
      actions: [btn('Review in Network', showTab('network'), { small: true, icon: 'shield' })] }) : null);
  // ── the inspector: six tabs instead of nine stacked sections ──
  const tab = sview(name).inspTab || 'overview';
  const counts = { sessions: live.length ? h('span', { class: 'count' }, String(live.length)) : null,
                   network: i.deniedConnections ? h('span', { class: 'count warn' }, String(i.deniedConnections)) : null };
  const tabs = h('div', { class: 'itabs', role: 'tablist', 'aria-label': 'Details of ' + name },
    INSP_TABS.map(([id, label, title, ic]) => h('button', { type: 'button', role: 'tab', class: 'itab', id: 'itab-' + id, 'data-insp-tab': id, 'aria-controls': 'ipanel-' + id,
      'aria-selected': id === tab ? 'true' : 'false', title, on: { click: () => inspShow(name, id) } }, icon(ic), h('span', { class: 'itab-l' }, label), counts[id] || null)));
  const panel_ = (id, ...kids) => h('section', { class: 'ipanel', role: 'tabpanel', id: 'ipanel-' + id, 'data-insp': id, 'aria-labelledby': 'itab-' + id, hidden: id !== tab }, ...kids);
  const head = (title, ...acts) => h('div', { class: 'head' }, h('h2', null, title), acts.length ? h('div', { class: 'actions' }, acts) : null);
  const last = d.restorePoints.length ? d.restorePoints[d.restorePoints.length - 1] : null;
  const details = h('div', { class: 'sbx-details-inner' }, tabs,
    panel_('overview',
      h('div', { class: 'stats' },
        stat('RAM held', mib(i.ramHeldMiB), 'of ' + mib(i.memoryMiB) + (i.memoryReturnedMiB ? ' · balloon returned ' + mib(i.memoryReturnedMiB) : '')),
        stat('Disk', bytes(i.diskBytes), d.snapshotBytes ? 'snapshot ' + bytes(d.snapshotBytes) : (d.hasRootDisk ? 'root disk kept' : 'no root disk yet')),
        stat('CPUs', String(d.cpus))),
      h('div', null, h('div', { class: 'insp-lbl' }, 'Attach from a terminal'), h('div', { class: 'cmd' }, h('code', null, d.attachCommand), copy)),
      h('div', null, h('div', { class: 'insp-lbl' }, 'Workspace'),
        h('div', { class: i.workspace ? null : 'muted' }, i.workspace ? [h('code', null, i.workspace), ' → /workspace (live)'] : 'Isolated — ' + ISOLATED_NOTE),
        i.workspaceRules ? h('p', { class: 'muted', 'data-workspace-rules-line': '' },
          'Workspace rules: ' + i.workspaceRules + '. Which rule decides a path: doz ignore check ' + name + ' PATH. Not a security boundary.')
          // 599g (owner A3): a shared folder with no rule file says so, rather than nothing (isolated: nothing to say).
          : i.workspace ? h('p', { class: 'muted', 'data-workspace-rules-none': '' },
            'Workspace rules: none — the folder is shared as is. A .dozignore or .dozreadonly in it keeps the agent away from some files.') : null),
      h('div', null, h('div', { class: 'insp-lbl' }, 'Sessions'),
        live.length ? h('div', null, live.map((s) => s.name).join(', '), ' ', h('a', { href: '#/sandbox/' + name, on: { click: (ev) => { ev.preventDefault(); inspShow(name, 'sessions'); } } }, 'All sessions'))
          : h('div', { class: 'muted' }, running ? 'None running.' : 'None running — it is ' + (PHASE_WORD[i.phase] || i.phase) + '.')),
      h('div', null, h('div', { class: 'insp-lbl' }, 'Last restore point'),
        last ? h('div', null, last.name + ' · ' + when(last.createdAt) + ' ', h('a', { href: '#/sandbox/' + name, on: { click: (ev) => { ev.preventDefault(); inspShow(name, 'points'); } } }, 'All points'))
          : h('div', { class: 'muted' }, 'None yet.'))),
    panel_('sessions',
      head('Sessions', gated(btn('Run detached…', () => runDetachedDialog(name), { small: true }))),
      panel(table(['Session', 'Command', ''], sessions),
        running ? 'No sessions.' : i.phase === 'off' || i.phase === 'failed' ? 'No sessions — ' + (i.phase === 'off' ? 'shut down' : 'failed') + '. Start boots it fresh, with new sessions.'
          : 'No saved screens — sessions are listed while it runs, and saved when it pauses, sleeps or hibernates.')),
    panel_('points',
      head('Restore points', btn('Take a restore point…', () => takePointDialog(name, running), { small: true })),
      panel(table(['Point', 'Taken', ''], points), 'No restore points yet.')),
    panel_('network',
      head('Network', proxied ? btn('Edit policy…', () => policyDialog(name, net.policy), { small: true }) : null),
      networkPanel(net)),
    panel_('keys',
      head('Keys & account',
        proxied ? btn('Key policy…', () => dialog('Key policy of ' + name, 'What the proxy does with a credential the guest brings itself. auto: strict when the account is not the Mac login, allow otherwise.',
          [{ name: 'policy', label: 'Policy', type: 'select', options: ['auto', 'allow', 'strict'], value: 'auto' }], 'Set', async (v) => {
            await actOrThrow({ action: 'key-policy', sandbox: name, policy: v.policy });
          }), { small: true }) : null,
        proxied ? btn('Account…', () => accountDialog(name, i, accounts), { small: true }) : null),
      panel(table(['Key', 'Set', 'State', ''], creds), 'No keys — the sandbox uses none.'),
      keyEntry(name, proxied),
      foreign.length ? h('h2', null, 'Credentials the guest brought itself (fingerprints only)') : null,
      foreign.length ? panel(table(['Kind', 'Fingerprint', 'Header'], foreign)) : null),
    panel_('config',
      head('Configuration'),
      h('div', { class: 'panel' }, h('div', { class: 'panel-body' }, h('dl', { class: 'facts' },
        fact('Memory', mib(d.memoryMiB)), fact('Root disk', mib(d.rootfsMiB)), fact('State disk', mib(d.stateDiskMiB)),
        fact('Journal', d.journalMiB ? mib(d.journalMiB) : 'none'), fact('Network', d.networkMode + (d.subnet ? ' · ' + d.subnet : '')),
        fact('Account', i.accountApplies ? (i.account || '—') : 'n/a'),
        fact('Workspace', i.workspace ? i.workspace + ' → /workspace (live)' : 'isolated — ' + ISOLATED_NOTE),
        fact('Shares', d.shares.length ? d.shares.map((s) => s.hostPath + ' → ' + s.guestPath).join(', ') : 'none'),
        d.project ? fact('Project', d.project) : null,
        fact('Directory', d.directory)))),
      h('h2', null, 'Environment prompt'),
      promptPanel(d)),
    h('div', { class: 'insp-resize', role: 'separator', 'aria-orientation': 'vertical', 'aria-label': 'Resize the details', title: 'Drag to resize the details (320–560 px)',
      on: { pointerdown: inspResizeStart } }));
  return { bar, details };
}
/// A menu on the sandbox page closed: a re-render it held back runs now.
function sbxMenuClosed() { if (state.sbxHeld) { state.sbxHeld = false; refreshSandbox(); } }
/// 603: the inspector's width — dragged between 300 and 560 px, kept in this browser (a layout convenience).
function inspWidth(w) {
  const px = Math.max(320, Math.min(560, Math.round(w)));
  $('sbx-body').style.setProperty('--insp-w', px + 'px');
  return px;
}
(() => { try { const w = Number(localStorage.getItem('doz.inspectorWidth')); if (w) inspWidth(w); } catch (_) { /* no storage: the default */ } })();
function inspResizeStart(ev) {
  ev.preventDefault();
  const body = $('sbx-body'), right = body.getBoundingClientRect().right;
  let px = 0;
  const move = (e) => { px = inspWidth(right - e.clientX); };
  const up = () => {
    document.removeEventListener('pointermove', move); document.removeEventListener('pointerup', up);
    document.body.classList.remove('resizing');
    if (px) { try { localStorage.setItem('doz.inspectorWidth', String(px)); } catch (_) { /* */ } }
  };
  document.body.classList.add('resizing');
  document.addEventListener('pointermove', move);
  document.addEventListener('pointerup', up);
}
/// 594 (D15/D16): what the agent is told about where it runs, as its NEXT session gets it.
function promptPanel(d) {
  const p = d.agentPrompt;
  if (!p) return panel(null, 'This image runs no agent — there is no environment prompt.');
  if (!p.enabled) return panel(null, 'Off — agent.prompt is false (Settings): the agent gets no facts block and no dozer skill.');
  const how = p.agent === 'pi' ? 'pi’s --append-system-prompt ' + p.promptPath
    : p.agent === 'codex' ? 'Codex’s developer instructions (its launcher reads ' + p.promptPath + ')'
    : 'Claude Code’s --append-system-prompt (its launcher reads ' + p.promptPath + ')';
  return h('div', { class: 'panel prompt-panel' },
    h('div', { class: 'muted' }, 'Written at every session start, from this sandbox’s current facts — ', how, '. Layers: ', p.layers.join(' + '),
      '. The dozer skill: ', h('code', null, p.skillPath), ' (' + p.skillLines + ' lines).'),
    p.error ? callout('bad', { cls: 'notice', body: 'It does not render, so sessions do not start: ' + p.error })
            : h('pre', { class: 'prompt-text' }, p.text || ''),
    h('div', { class: 'muted' }, 'Your own template: agent-prompt.md beside doz.toml · this sandbox’s own lines: agent_prompt in doz_project.yaml, or doz create --agent-prompt FILE.'));
}

/// 593: Save as template — the ROOT disk only (never the state disk: logins and history stay out of a
/// disk meant to be shared). From the current disk (a live sandbox pauses for the clone) or a point.
function templateDialog(name, d, pointID) {
  const sources = [['', 'the current disk' + (d.info.phase === 'off' ? '' : ' (it pauses for the clone: milliseconds)')],
    ...d.restorePoints.map((p) => [p.id, 'restore point ' + p.name])];
  dialog('Save ' + name + ' as a template',
    'A template is an image other sandboxes are created from. Everything installed or written on the ROOT disk is in it: files in /root, /etc, /usr, /opt, caches — so do not save a secret you put there. The agent’s state disk (its logins, history) is never included.', [
      { name: 'image', label: 'Template name', placeholder: 'a-z 0-9 -', required: true },
      { name: 'source', label: 'From', type: 'select', options: sources, value: pointID || '' },
      { name: 'note', label: 'Note', placeholder: 'what is in it' },
    ], 'Save template', async (v) => {
      const b = { action: 'template-create', sandbox: name, image: v.image };
      if (v.source) b.point = v.source;
      if (v.note) b.note = v.note;
      await actOrThrow(b);
    });
}

/// 593: Duplicate — a new sandbox from this one's disk (or a point) with overrides. The root disk is
/// an APFS clone; the state disk starts fresh unless the person opts in.
function duplicateDialog(name, d, accounts, pointID) {
  const i = d.info;
  const sources = [['', 'the current disk' + (i.phase === 'off' ? '' : ' (it pauses for the clone: milliseconds)')],
    ...d.restorePoints.map((p) => [p.id, 'restore point ' + p.name])];
  const slot = h('div'), acctSlot = h('div');
  const dlg = dialog('Duplicate ' + name,
    'A new sandbox from ' + name + '’s root disk (an instant APFS clone). It is created off; Start boots it. Keys are not copied.', [
      { name: 'newName', label: 'New sandbox name', placeholder: 'a-z 0-9 -', required: true },
      // 596 (B1): the base and agent are the source's — shown, not changeable (the disk is a clone of its).
      { name: 'baseShown', type: 'custom', get: () => null, el: h('div', { class: 'field', 'data-duplicate-image': '' }, h('span', null, 'Image'),
        h('div', null, h('strong', null, i.imageTitle || i.image), ' ', h('span', { class: 'muted' }, '— ' + i.image + (i.dockerfile ? ', Dockerfile ' + i.dockerfile : '') + ' (the source’s; not changeable)'))) },
      { name: 'source', label: 'From', type: 'select', options: sources, value: pointID || '' },
      // 594: Shared folder (<projects_dir>/<new name> by default, made when missing) | Isolated.
      { name: 'ws', type: 'custom', el: slot, get: () => chooser.get() },
      { name: 'cpus', label: 'CPUs', type: 'number', min: 1, max: 64, placeholder: String(d.cpus) + ' (the same)' },
      { name: 'memoryMiB', label: 'Memory (MiB)', type: 'number', min: 256, placeholder: String(d.memoryMiB) + ' (the same)' },
      { name: 'network', label: 'Network', type: 'select', value: '',
        options: [['', i.network + ' (the same — its permissions and sites copied)'], ['agent', 'Standard permissions'], ['bake', 'bake'], ['locked', 'Locked — its AI model only'],
          ['open', 'Open — everything (logged)'], ['nat', 'nat'], ['none', 'none']] },
      // 594: only the accounts the agent can use ("the same" only when that one fits).
      { name: 'account', type: 'custom', el: acctSlot, get: () => {
        if (!acct.ok()) throw new Error((AGENT_NAMES[i.agent] || 'This agent') + ' needs an Anthropic API key — add one above.');
        return acct.get();
      } },
      { name: 'copyState', label: 'Copy the agent’s state disk too', type: 'checkbox',
        help: 'Off (the default): a fresh state disk. On: its logins and history are copied into the new sandbox.' },
    ], 'Duplicate', async (v) => {
      const b = { action: 'duplicate', sandbox: name, newName: v.newName, ...v.ws };
      if (v.source) b.point = v.source;
      if (v.cpus) b.cpus = Number(v.cpus);
      if (v.memoryMiB) b.memoryMiB = Number(v.memoryMiB);
      if (v.network) b.network = v.network;
      if (v.account) b.account = v.account;
      if (v.copyState) b.copyState = true;
      await actOrThrow(b);
    });
  const chooser = workspaceChooser({ nameInput: dlg.inputs.newName, image: () => i.image });
  slot.replaceWith(chooser.el);
  const submit = dlg.querySelector('button[type="submit"]');
  const acct = accountChooser({ accounts, agent: () => (['nat', 'none'].includes(dlg.inputs.network.value) ? null : i.agent),
    same: i.credentialProblem ? null : 'the same' + (i.account ? ' (' + i.account + ')' : ''), defaultValue: 'default',
    onChange: () => { submit.disabled = !acct.ok(); } });
  acctSlot.replaceWith(acct.el);
  submit.disabled = !acct.ok();
  dlg.inputs.network.addEventListener('change', () => acct.agentChanged());
}

/// Edit the policy in a dialog; Preview shows exactly what the host will do; Apply sends it.
function policyDialog(name, policy) {
  dialog('Network policy of ' + name, 'The change is live (the next connection is judged by it) and kept for the next start. Preview first.', [
    { name: 'preset', label: 'Replace with a preset', type: 'select', value: '', options: [['', '— keep the rules —'], 'agent', 'bake', 'locked', 'open'] },
    { name: 'allow', label: 'Allow hosts', type: 'textarea', placeholder: 'example.com\n*.example.org\nhost:443', help: 'one per line: exact, *.domain, host:port or an IPv4 CIDR' },
    { name: 'deny', label: 'Deny hosts', type: 'textarea', placeholder: 'one per line' },
    { name: 'remove', label: 'Remove every rule for these hosts', type: 'textarea', placeholder: 'one per line' },
  ], 'Preview', async (v, ui) => {
    const edit = {};
    if (v.preset) edit.preset = v.preset;
    for (const k of ['allow', 'deny', 'remove']) if (lines(v[k]).length) edit[k] = lines(v[k]);
    if (!Object.keys(edit).length) throw new Error('nothing to change');
    if (ui.submit.dataset.previewed === JSON.stringify(edit)) {
      await actOrThrow({ action: 'net-policy', sandbox: name, ...edit });
      return;
    }
    const p = await api('sandboxes/' + name + '/network/preview', { method: 'POST', json: edit });
    ui.extra.replaceChildren(h('div', { class: 'diff' },
      h('div', { class: 'muted' }, (p.before.preset ? p.before.preset + ' preset' : 'custom') + ' → ' + (p.after.preset ? p.after.preset + ' preset' : 'custom') +
        ' · anything else: ' + p.after.defaultAction),
      p.changed ? null : h('div', null, 'No change.'),
      ...p.removed.map((r) => h('div', { class: 'del' }, '− ' + r)),
      ...p.added.map((r) => h('div', { class: 'add' }, '+ ' + r)),
      h('details', null, h('summary', null, 'The whole policy after (' + p.after.rules.length + ' rules, in order)'),
        h('ol', null, p.after.rules.map((r) => h('li', { class: r.action === 'allow' ? 'st-ok' : 'st-fail' }, r.label + (r.note ? ' — ' + r.note : '')))))));
    ui.submit.dataset.previewed = JSON.stringify(edit);
    setButton(ui.submit, p.changed ? 'Apply' : 'Apply anyway');
    return 'keep-open';
  });
}
state.permErr = new Map();
function permissionsPanel(name, net) {
  const p = net.permissions;
  if (!p) return null;
  const on = new Set(p.rows.filter((r) => r.on).map((r) => r.id));
  const send = async (body) => {
    try { state.permErr.delete(name); await actOrThrow({ action: 'net-policy', sandbox: name, ...body }); }
    catch (e) { state.permErr.set(name, e.message || String(e)); refreshSandbox(); }
  };
  const change = (id, v) => {
    if (id === 'web' && v) return confirmWeb(() => send({ grant: ['web'] }));
    if ((id === 'github:as-you' || id === 'github:push') && v) return confirmGitHub(id, () => send({ grant: [id] }));
    send(v ? { grant: [id] } : { revoke: [id] });
  };
  const presetBtn = (id) => {
    const b = h('button', { type: 'button', class: 'seg' + (p.preset === id ? ' active' : ''), 'data-perm-preset': id, 'aria-pressed': p.preset === id ? 'true' : 'false' },
      withIcon(id === 'locked' ? 'shield' : id === 'open' ? 'eye' : 'check', PRESET_LABEL[id]));
    b.addEventListener('click', () => { if (id === 'open') confirmWeb(() => send({ preset: 'open' })); else send({ preset: id }); });
    return b;
  };
  const suggestions = p.suggestions.map((s) => callout('warn', { compact: true, cls: 'perm-suggest', icon: 'shield', attrs: { 'data-suggest': s.grant },
    body: ['The agent tried to ', h('strong', null, s.permission ? s.what : 'reach ' + s.what),
      h('div', { class: 'muted' }, s.hosts.join(', ') + ' · ' + s.count + ' time' + (s.count === 1 ? '' : 's'))],
    actions: [btn(s.permission ? 'Allow' : 'Allow this site', () => (s.permission === 'web' ? confirmWeb(() => send({ grant: [s.grant] })) : send({ grant: [s.grant] })),
      { small: true, icon: 'check' })] }));
  const sites = p.sites.map((host) => h('span', { class: 'tag perm-site', 'data-site': host }, host, ' ',
    h('button', { type: 'button', class: 'btn sm quiet icon-only', title: 'Deny ' + host, 'aria-label': 'Deny ' + host, on: { click: () => send({ revoke: ['site:' + host] }) } }, icon('x'))));
  const siteInput = h('input', { type: 'text', placeholder: 'api.example.com', 'aria-label': 'A site to allow', 'data-site-input': '', spellcheck: 'false' });
  return h('div', { class: 'panel perm-panel', 'data-perm-panel': name },
    h('div', { class: 'perm-head' }, h('strong', null, 'What the agent can do'),
      h('div', { class: 'segmented', role: 'group', 'aria-label': 'Preset' }, presetBtn('locked'), presetBtn('agent'), presetBtn('open')),
      p.preset ? null : h('span', { class: 'tag', 'data-perm-custom': '' }, 'Custom'),
      p.inferred ? h('span', { class: 'muted' }, ' an older policy, shown as permissions (stored as names at its first change)') : null),
    state.permErr.has(name) ? callout('bad', { compact: true, body: state.permErr.get(name), attrs: { 'data-perm-error': '' },
      dismiss: () => { state.permErr.delete(name); refreshSandbox(); } }) : null,
    suggestions.length ? h('div', { class: 'perm-suggestions' }, suggestions) : null,
    permissionSwitches(p.rows, on, change),
    h('div', { class: 'perm-sites' }, h('span', null, 'Other sites: '), sites.length ? sites : h('span', { class: 'muted' }, 'none'), ' ', siteInput,
      btn('Allow site', () => { const v = siteInput.value.trim().toLowerCase(); if (v) send({ grant: ['site:' + v] }); }, { small: true, icon: 'plus' })));
}

function networkPanel(net) {
  if (!net.proxied) return panel(null, net.note || 'Not proxied.');
  const rules = net.policy.rules.map((r, n) => h('tr', null, h('td', { class: 'num' }, String(n + 1)),
    h('td', null, h('span', { class: r.action === 'allow' ? 'st-ok' : 'st-fail' }, r.action)), h('td', { class: 'mono' }, r.label), h('td', null, r.note || '')));
  const log = net.log.filter((c) => !state.deniedOnly || c.verdict === 'denied').slice().reverse().map((c) => h('tr', null,
    h('td', null, clock(c.time)),
    h('td', null, h('span', { class: c.verdict === 'allowed' ? 'st-ok' : 'st-fail' }, c.verdict)),
    h('td', null, c.kind),
    h('td', { class: 'mono' }, c.host + (c.port ? ':' + c.port : ''), c.method ? h('div', { class: 'muted' }, c.method + ' ' + (c.path || '')) : null),
    h('td', null, c.rule),
    h('td', { class: 'num' }, '↑' + bytes(c.bytesUp) + ' ↓' + bytes(c.bytesDown)),
    h('td', null, c.credential || '')));
  const toggle = h('input', { type: 'checkbox', id: 'denied-only' });
  toggle.checked = state.deniedOnly;
  toggle.addEventListener('change', () => { state.deniedOnly = toggle.checked; refresh(false); });
  const policyParts = [
    h('div', { class: 'panel' }, h('div', { class: 'empty' },
      (net.policy.preset ? (PRESET_LABEL[net.policy.preset] || net.policy.preset) + ' preset' : 'custom policy') + ' · anything else: ' + net.policy.defaultAction)),
    h('div', { class: 'panel' }, table(['#', 'Rule', 'Host', 'Note'], rules, [0]) || h('div', { class: 'empty' }, 'No rules.'))];
  return h('div', null,
    // 597: the permissions first; the rules (every host they amount to) under details.
    net.permissions ? permissionsPanel(net.name, net) : null,
    net.permissions ? h('details', { class: 'net-rules', 'data-net-rules': '' }, h('summary', null, 'Details: the rules and hosts'), policyParts) : policyParts,
    h('h2', null, 'Connection log'),
    h('div', { class: 'toolbar' }, h('label', null, toggle, ' denied only'),
      net.logAvailable ? net.logTotal + ' connections since the host started · ' + net.denied + ' denied' + (net.logTotal > net.log.length ? ' · newest ' + net.log.length + ' shown' : '') : (net.note || '')),
    panel(table(['Time', 'Verdict', 'Kind', 'Target', 'Rule', 'Bytes', 'Credential'], log, [5]), net.logAvailable ? 'No connections.' : net.note));
}

/// 593: Images › Table | Lineage. The lineage is measured by the host (every disk's extent map), so
/// it is fetched only when shown, or on Refresh — never on a live update.
function imagesToggle() {
  const mk = (mode, label) => {
    const b = h('button', { type: 'button', class: 'seg' + (state.imagesMode === mode ? ' active' : ''), 'aria-pressed': state.imagesMode === mode ? 'true' : 'false', 'data-mode': mode },
      withIcon(iconFor(label), label));
    b.addEventListener('click', () => { if (state.imagesMode !== mode) { state.imagesMode = mode; refresh(false); } });
    return b;
  };
  return h('div', { class: 'segmented', role: 'group', 'aria-label': 'View' }, mk('table', 'Table'), mk('lineage', 'Lineage'));
}
function sizeBar(size, own, shared) {
  const whole = Math.max(1, size || 0);
  const bar = h('div', { class: 'lin-bar', 'data-own': String(own || 0), 'data-shared': String(shared || 0),
    title: 'own ' + bytes(own || 0) + ' (' + pct(own || 0, size) + ') · shared ' + bytes(shared || 0) + ' (' + pct(shared || 0, size) + ')' +
      ((size - (own || 0) - (shared || 0)) > 0 ? ' · the rest is shared with other disks' : '') });
  const a = h('span', { class: 'lin-shared' }), b = h('span', { class: 'lin-own' });
  a.style.width = Math.min(100, ((shared || 0) / whole) * 100).toFixed(1) + '%';
  b.style.width = Math.min(100, ((own || 0) / whole) * 100).toFixed(1) + '%';
  bar.append(a, b);
  return bar;
}
function barLegend() {
  return h('span', { class: 'bar-legend', 'data-legend': '' },
    h('span', { class: 'sw sw-own', 'aria-hidden': 'true' }), 'Own', h('span', { class: 'sw sw-shared', 'aria-hidden': 'true' }), 'Shared');
}
function sizePart(n, size) { return n == null ? '—' : [bytes(n), h('span', { class: 'muted pct' }, ' · ' + pct(n, size))]; }
/// The lineage node of an Images row (built-in: `image` NAME@KEY12; lab: its prepared disk; a template by name).
function treeNodeFor(tree, r) {
  if (!tree) return null;
  return tree.nodes.find((n) => r.kind === 'custom' ? n.kind === 'template' && n.name === r.name
    : r.name === 'lab' ? n.kind === 'prepared' && r.key && (n.name + '-' + String(n.detail || '').split(' ').pop()) === r.key
    : n.kind === 'image' && n.name === r.name && !!r.key && n.detail === r.key) || null;
}
async function viewImages() {
  if (state.imagesMode === 'lineage') return viewLineage();
  const [images, tree] = await Promise.all([api('images'), measured('tree', 'images/tree').catch(() => null)]);
  const rows = images.map((r) => {
    const n = treeNodeFor(tree, r);
    const size = n ? n.allocatedBytes : r.allocatedBytes;
    // Shared: with the disk it was made from (none for a disk with no parent — the lab's prepared disk).
    const own = n ? n.uniqueBytes : null, shared = n ? n.sharedWithParentBytes ?? null : null;
    return h('tr', { 'data-image': r.name, 'data-status': r.status || '' },
    h('td', null, h('span', { class: 'nm' }, r.name), ' ', r.kind === 'custom' ? h('span', { class: 'tag tpl' }, 'template') : null,
      // 594 W28: out of date — a badge, and the line that says why (never rebuilt by itself).
      r.status === 'older recipe' || r.status === 'update available' ? h('span', { class: 'tag img-status st-' + r.status.replace(/ /g, '-'), 'data-image-badge': r.status }, r.status) : null,
      r.standing ? h('div', { class: 'muted img-standing', 'data-image-standing': '' }, r.standing) : null,
      // 603 (E17): the key is rarely read — in the row's details, truncated (the whole of it as the tooltip).
      r.key ? h('div', { class: 'sub2 mono trunc img-key', title: 'key ' + r.key }, r.key) : null),
    // 596 (B1): base × agent ("Python · Claude Code").
    h('td', { 'data-image-base': r.base || '' }, r.kind === 'custom' ? 'template' : (r.title || r.kind)),
    // W32: what the image's state means, in words — never a bare dash.
    h('td', { 'data-image-status-cell': '' }, h('span', { class: r.status === 'up to date' ? 'muted' : '' }, r.status || 'up to date')),
    h('td', { title: r.bakedAt ? full(r.bakedAt) : null }, r.baked ? (r.bakedAt ? when(r.bakedAt) : 'yes') : h('span', { class: 'muted' }, 'no — bakes on first start')),
    h('td', { class: 'num' }, r.allocatedBytes ? bytes(r.allocatedBytes) : '—'),
    h('td', { class: 'num', 'data-own-cell': '' }, n ? sizePart(own, size) : '—'),
    h('td', { class: 'num', 'data-shared-cell': '' }, n ? sizePart(shared, size) : '—'),
    h('td', { class: 'bar-cell' }, n ? sizeBar(size, own, shared) : null),
    // 594: an agent image's version — the one a new sandbox gets, and a newer one available (594 W28:
    // said, never prepared by itself — Rebuild).
    h('td', { 'data-version': r.version || '', 'data-available': r.available || '' },
      r.versionSetting ? [
        r.version ? h('span', { class: 'mono' }, r.version)
          : h('span', { class: 'muted' }, (r.available ? r.available + ' ' : '') + 'when prepared' + (r.preparing ? ' — preparing' : '')),
        r.version && r.available ? h('span', { class: 'tag ver-available', title: 'a new sandbox gets ' + (r.version || 'it') + ' until you rebuild the image' },
          r.available + ' available' + (r.preparing ? ' — preparing' : '')) : null,
        h('div', { class: 'muted' }, r.versionSetting === 'latest'
          ? 'latest' + (r.latest ? ' (npm: ' + r.latest + ')' : '') : 'pinned: ' + r.versionSetting),
      ] : '—'),
    h('td', null, [r.versionSetting ? null : r.note, r.fromSandbox ? 'from ' + r.fromSandbox : null, r.dockerfile ? 'Dockerfile ' + r.dockerfile : null,
      r.baseUpdate].filter(Boolean).join(' · ') || '—'),
    h('td', { class: 'row-acts-cell' }, h('div', { class: 'row-acts' },
      // 594 W28: rebuilding is one explained step. 603: the row's next verb; Remove… in ⋯.
      r.kind === 'builtin' ? (r.baked
        ? btn('Rebuild', () => dialog('Rebuild the ' + r.name + ' image?',
            'About 2 minutes, needs network. Existing sandboxes keep their disks — nothing in them changes. New sandboxes, and Reset, use the new image (a reset keeps the agent’s own state and /workspace, and drops other system changes).',
            [], 'Rebuild', async () => { await actOrThrow({ action: 'image-bake', image: r.name }); }, { icon: 'flame' }),
          { small: true, primary: !!r.standing, quiet: !r.standing, icon: 'flame', title: 'Minutes, needs network' })
        : btn('Bake', () => act({ action: 'image-bake', image: r.name }), { small: true, quiet: true, title: 'Minutes, needs network' })) : null,
      r.baked || r.kind === 'custom' ? moreMenu('More for ' + r.name, [{ label: 'Remove…', icon: 'trash-2', danger: true,
        desc: r.kind === 'custom' ? 'The template; sandboxes made from it keep working' : 'Its baked disk; baked again when next needed',
        onSelect: () => confirmAction('Remove ' + (r.kind === 'custom' ? 'template ' : 'image ') + r.name,
          r.kind === 'custom' ? 'The template is deleted; sandboxes created from it keep working.' : 'Its baked disk is deleted (it is baked again when next needed); sandboxes cloned from it keep working.',
          r.name, { action: 'image-rm', image: r.name }) }], { small: true }).el : null)));
  });
  return h('div', null, h('div', { class: 'head' }, h('h1', null, 'Images'),
      h('div', { class: 'actions' }, btn('Refresh', () => { remeasure(); refresh(false); }, { small: true, title: 'Measure again' }), imagesToggle())),
    h('p', { class: 'sub' }, 'Built-in images, and templates saved from sandboxes (a sandbox’s root disk — never its state disk). Own is what only this image holds (what removing it frees); shared is what it reuses from the disk it was made from. Progress of a bake shows under Operations. Everything Dozer uses: ',
      h('a', { href: '#/resources' }, 'Resources'), '.'),
    panel(((t) => { if (t) t.classList.add('images-t'); return t; })(table(['Image', 'Base · Agent', 'Status', 'Baked', 'Size', 'Own', 'Shared', barLegend(), 'Version', 'Note', h('span', { class: 'sr-only' }, 'Actions')], rows, [4, 5, 6]))));
}
async function viewLineage() {
  const t = await measured('tree', 'images/tree');
  const labels = { base: 'OCI base', image: 'image', template: 'template', prepared: 'prepared disk', sandbox: 'sandbox', restorePoint: 'restore point' };
  const rows = t.nodes.map((n) => {
    const own = n.uniqueBytes || 0;
    const bar = sizeBar(n.allocatedBytes, own, n.sharedWithParentBytes || 0);
    const name = n.kind === 'sandbox' ? h('a', { href: '#/sandbox/' + n.sandbox }, n.name) : h('span', null, n.name);
    return h('div', { class: 'lin-row depth-' + Math.min(n.depth, 8) + ' lin-' + n.kind, 'data-kind': n.kind, 'data-name': n.name, 'data-depth': String(n.depth) },
      h('div', { class: 'lin-name' }, h('span', { class: 'lin-branch', 'aria-hidden': 'true' }, n.depth ? '└ ' : ''), name,
        h('span', { class: 'tag lin-kind' }, labels[n.kind] || n.kind), n.detail ? h('span', { class: 'muted mono lin-detail' }, n.detail) : null),
      h('div', { class: 'num lin-size' }, bytes(n.allocatedBytes), n.stateAllocatedBytes ? h('div', { class: 'muted' }, '+ state ' + bytes(n.stateAllocatedBytes)) : null),
      h('div', { class: 'num lin-shared-n' }, n.sharedWithParentBytes != null ? sizePart(n.sharedWithParentBytes, n.allocatedBytes) : '—'),
      h('div', { class: 'num lin-own-n' }, sizePart(own, n.allocatedBytes)),
      bar);
  });
  return h('div', null, h('div', { class: 'head' }, h('h1', null, 'Images'),
      h('div', { class: 'actions' }, btn('Refresh', () => { remeasure(); refresh(false); }, { small: true, title: 'Measure again' }), imagesToggle())),
    h('p', { class: 'sub' }, 'The lineage: OCI base → image → template → the sandboxes on each. Size is what the disk holds; shared is what it reuses from its parent (APFS clones); own is what removing it frees — each also as a % of its size. All disks together: ' +
      bytes(t.unionBytes) + ' (measured in ' + Math.round(t.milliseconds) + ' ms).'),
    t.nodes.length
      ? h('div', { class: 'panel lineage' },
          h('div', { class: 'lin-row lin-headrow' }, h('div', null, 'Image / sandbox'), h('div', { class: 'num' }, 'Size'), h('div', { class: 'num' }, 'Shared'), h('div', { class: 'num' }, 'Own'), h('div', null, barLegend())),
          rows)
      : panel(null, 'No disks yet — bake an image or start a sandbox.'));
}

// ── 595: Resources ──────────────────────────────────────────────────────────
// Owner (2026-09-30): "the Resources section should break down ALL the usage". An ACCOUNT first: every
// byte of the store on a row (the last, "unattributed", is ~0 — red when not), the memory and CPUs Dozer
// holds, the proxy's traffic, the kernels. Management stays where it lives — a row links to Images, the
// sandbox's page or Accounts & keys; this page deletes only what has no other home. A deletion is
// previewed (POST resources/preview — changes nothing), confirmed once (no typed names: the owner's
// ruling), and runs as ONE operation (`resources-rm` with exactly the ids shown).
const RES_GROUPS = [['sandboxes', 'Sandboxes'], ['images', 'Images & templates'], ['caches', 'Caches'], ['logs', 'Logs & metrics'],
                    ['stray', 'Stray files'], ['store', 'Dozer’s own'], ['outside', 'Outside the store']];
state.resSel = new Set();
state.resToggled = new Set();
function resOpen(it) { return (it.group === 'sandboxes') !== state.resToggled.has(it.id); }
function resLink(link) {
  if (!link) return null;
  if (link === 'images') return h('a', { href: '#/images', 'data-link': 'images' }, 'Images');
  if (link === 'accounts') return h('a', { href: '#/accounts', 'data-link': 'accounts' }, 'Accounts & keys');
  if (link === 'settings') return h('a', { href: '#/settings', 'data-link': 'settings' }, 'Settings');
  if (link.startsWith('sandbox:')) { const n = link.slice(8); return h('a', { href: '#/sandbox/' + n, 'data-link': 'sandbox' }, n); }
  return null;
}
function resSelectable(it) { return it.deletable && !it.refusal; }
function resRow(it, kids) {
  const cb = h('input', { type: 'checkbox', 'data-res-check': it.id, 'aria-label': 'Select ' + it.name });
  cb.checked = state.resSel.has(it.id);
  if (!resSelectable(it)) { cb.disabled = true; cb.title = it.refusal || 'not deleted here'; cb.checked = false; }
  cb.addEventListener('change', () => {
    if (cb.checked) state.resSel.add(it.id); else state.resSel.delete(it.id);
    paintResSelection();
  });
  let toggle = null;
  if (kids) {
    const open = resOpen(it);
    toggle = h('button', { type: 'button', class: 'res-toggle' + (open ? ' open' : ''), 'aria-expanded': open ? 'true' : 'false',
                           title: (open ? 'Hide' : 'Show') + ' its ' + kids + ' part' + (kids === 1 ? '' : 's') }, icon('chevron-down'));
    toggle.addEventListener('click', () => {
      if (state.resToggled.has(it.id)) state.resToggled.delete(it.id); else state.resToggled.add(it.id);
      renderResources();
    });
  }
  const bad = it.id === 'unattributed' && it.sizeBytes !== 0;
  const notes = [];
  if (it.refusal && it.deletable) notes.push(h('div', { class: 'res-refusal' }, 'Not now: ' + it.refusal));
  else if (it.refusal) notes.push(h('div', { class: 'muted' }, it.refusal));
  if (it.later && !it.refusal) notes.push(h('div', null, h('span', { class: 'muted' }, 'Later: '), it.later));
  if (it.warning) notes.push(h('div', { class: 'res-warn' }, '⚠ ' + it.warning));
  if (it.id === 'unattributed') notes.push(h('div', { class: bad ? 'res-refusal' : 'muted' }, it.detail));
  // 596: Apple's container storage is shown, never deleted by Dozer — no checkbox at all (its own commands are named).
  const foreign = it.id.startsWith('outside:apple-container');
  return h('tr', { class: 'res-row' + (it.parent ? ' res-child' : '') + (bad ? ' res-bad' : ''), 'data-res': it.id, 'data-group': it.group },
    h('td', { class: 'res-check' }, foreign ? null : cb),
    h('td', { class: 'res-name' }, h('div', { class: 'res-name-line' }, toggle, h('span', null, it.name),
        it.current ? h('span', { class: 'tag res-current' }, 'current') : null,
        it.cleanable && resSelectable(it) ? h('span', { class: 'tag res-clean', title: 'Clean up removes it: re-creatable and unused' }, 'clean-up') : null),
      it.detail && it.id !== 'unattributed' ? h('div', { class: 'muted res-detail' }, it.detail) : null,
      h('div', { class: 'muted mono res-id' }, it.id)),
    h('td', { class: 'num' }, it.sizeBytes == null ? '—' : bytes(it.sizeBytes)),
    h('td', { class: 'num' }, it.freedBytes == null ? '—' : bytes(it.freedBytes)),
    h('td', null, it.usedBy.length ? it.usedBy.join(', ') : h('span', { class: 'muted' }, '—')),
    h('td', { class: 'res-notes' }, notes),
    h('td', null, resLink(it.link)));
}
function resGroupPanel(r, group, title) {
  const items = r.items.filter((i) => i.group === group);
  if (!items.length) return null;
  const rows = [];
  let total = 0;
  for (const p of items.filter((i) => !i.parent)) {
    const kids = items.filter((i) => i.parent === p.id);
    total += p.sizeBytes || 0;
    rows.push(resRow(p, kids.length));
    if (kids.length && resOpen(p)) for (const k of kids) rows.push(resRow(k, 0));
  }
  return resSection(group, title, group === 'outside' ? 'shown, never deleted here' : bytes(total),
    panel(table(['', 'Item', 'Size', 'Freed if deleted', 'Used by', 'Notes', 'Managed in'], rows, [2, 3])));
}
/// 603 (E13): a Resources group — its heading opens and closes it (the state kept in this browser).
function resClosed() { try { return new Set(JSON.parse(localStorage.getItem('doz.resClosed') || '[]')); } catch (_) { return new Set(); } }
function resSection(group, title, figure, body) {
  const closed = resClosed().has(group);
  const toggle = h('button', { type: 'button', class: 'res-toggle' + (closed ? '' : ' open'), 'aria-expanded': closed ? 'false' : 'true',
    'aria-controls': 'res-body-' + group, title: (closed ? 'Show ' : 'Hide ') + title }, icon('chevron-down'));
  const wrap = h('div', { id: 'res-body-' + group, hidden: closed }, body);
  toggle.addEventListener('click', () => {
    const set = resClosed();
    const nowClosed = !wrap.hidden;
    if (nowClosed) set.add(group); else set.delete(group);
    try { localStorage.setItem('doz.resClosed', JSON.stringify([...set])); } catch (_) { /* this page only */ }
    wrap.hidden = nowClosed;
    toggle.classList.toggle('open', !nowClosed);
    toggle.setAttribute('aria-expanded', nowClosed ? 'false' : 'true');
  });
  return h('section', { class: 'res-group', 'data-res-group': group, id: 'res-' + group },
    h('div', { class: 'head res-head' }, h('h2', null, toggle, title), h('span', { class: 'muted' }, figure)), wrap);
}
/// The top bar is Dozer's own split only (owner, 595): what stays, what Clean up frees, and what `du`
/// counts again for blocks APFS clones share — the whole is Dozer's total. The volume's free space is
/// text beside it, never part of the bar.
function resTotalBar(r) {
  const clean = Math.min(r.cleanableBytes, r.occupiedBytes);
  const keep = Math.max(0, r.occupiedBytes - clean);
  const shared = Math.max(0, r.totalBytes - r.occupiedBytes);
  const whole = Math.max(1, keep + clean + shared);
  const seg = (cls, n, label) => {
    const s = h('span', { class: cls, 'data-seg': cls, title: label + ': ' + bytes(n) });
    s.style.width = ((n / whole) * 100).toFixed(2) + '%';
    if (n > 0) s.style.minWidth = '4px';
    return s;
  };
  return h('div', { class: 'res-total' },
    h('div', { class: 'res-total-line' },
      h('div', { class: 'res-bar', 'data-res-bar': '' }, seg('res-seg-used', keep, 'Kept'), seg('res-seg-clean', clean, 'Clean up frees'),
        seg('res-seg-shared', shared, 'Shared blocks du counts again')),
      h('span', { class: 'res-free', 'data-res-free': '' }, r.volumeFreeBytes != null ? bytes(r.volumeFreeBytes) + ' free on the volume' : '')),
    h('div', { class: 'res-legend' },
      h('span', null, 'Dozer ', h('strong', { 'data-total': '' }, bytes(r.totalBytes)), h('span', { class: 'muted' }, ' as du counts it')),
      h('span', null, h('span', { class: 'sw res-sw-used', 'aria-hidden': 'true' }), 'Kept ', h('strong', null, bytes(keep))),
      h('span', null, h('span', { class: 'sw res-sw-clean', 'aria-hidden': 'true' }), 'Clean up frees ', h('strong', { 'data-cleanable': '' }, bytes(r.cleanableBytes))),
      h('span', null, h('span', { class: 'sw res-sw-shared', 'aria-hidden': 'true' }), 'Shared (APFS clones, counted again by du) ', h('strong', null, bytes(shared)))));
}
function resMemoryPanel(r) {
  const held = r.memory.reduce((a, m) => a + m.heldBytes, 0);
  const kinds = { sandbox: 'sandbox', host: 'the host', ui: 'this UI' };
  const rows = r.memory.map((m) => h('tr', { 'data-mem': m.kind + ':' + m.name },
    h('td', null, m.kind === 'sandbox' ? h('a', { href: '#/sandbox/' + m.name }, m.name) : m.name, h('span', { class: 'muted' }, ' · ' + (kinds[m.kind] || m.kind))),
    h('td', null, m.phase ? phasePill(m.phase) : '—'),
    h('td', { class: 'num' }, bytes(m.heldBytes), m.allocationBytes ? meter(m.heldBytes, m.allocationBytes) : null),
    h('td', { class: 'num' }, m.allocationBytes ? bytes(m.allocationBytes) : '—'),
    h('td', { class: 'num' }, m.cpus ?? '—')));
  return resSection('memory', 'Memory and CPUs', bytes(held) + ' held · ' + r.allocatedCPUs + ' of ' + r.machineCPUs + ' CPUs given to sandboxes',
    panel(table(['What', 'Phase', 'Held now', 'Allocation', 'CPUs'], rows, [2, 3, 4]), 'No sandbox has a VM, and no host is running.'));
}
function resNetworkPanel(r) {
  const rows = r.network.map((n) => h('tr', { 'data-net': n.sandbox },
    h('td', null, h('a', { href: '#/sandbox/' + n.sandbox }, n.sandbox)),
    h('td', { class: 'num' }, bytes(n.upToday)), h('td', { class: 'num' }, bytes(n.downToday)),
    h('td', { class: 'num' }, bytes(n.upTotal)), h('td', { class: 'num' }, bytes(n.downTotal)), h('td', { class: 'num' }, n.connectionsTotal)));
  return resSection('network', 'Network', 'through each sandbox’s proxy, from the metrics',
    panel(table(['Sandbox', 'Up today', 'Down today', 'Up in all', 'Down in all', 'Connections'], rows, [1, 2, 3, 4, 5]), 'No proxied traffic recorded yet.'));
}
function resKernelsPanel(r) {
  const rows = r.kernels.map((k) => h('tr', { 'data-kernel': k.id },
    h('td', null, h('span', { class: 'mono' }, k.version), k.current ? h('span', { class: 'tag res-current' }, 'current') : null, k.pinned ? h('span', { class: 'tag' }, 'this build’s') : null,
      k.inStore ? null : h('div', { class: 'muted' }, 'in a kernel cache outside this store')),
    h('td', { class: 'mono muted' }, k.sha256 || '—'),
    h('td', { class: 'num' }, bytes(k.sizeBytes)),
    h('td', null, k.usedBy.length ? k.usedBy.join(', ') : h('span', { class: 'muted' }, 'none')),
    h('td', null, k.current ? h('span', { class: 'muted' }, 'new sandboxes boot it')
      : btn('Use this kernel', () => act({ action: 'resources-kernel', kernel: k.id }), { small: true, title: 'New sandboxes boot it; existing ones keep theirs (a wake keeps its snapshot’s kernel)' }))));
  return resSection('kernels', 'Kernels', '“Use this kernel” is for sandboxes created from now on',
    panel(table(['Version', 'sha256', 'Size', 'Needed by', ''], rows, [2]), 'No kernel yet — the first start fetches it.'));
}
function paintResSelection() {
  const n = [...state.resSel].length;
  const b = document.querySelector('[data-res-delete]');
  if (b) { b.disabled = n === 0; setButton(b, n ? 'Delete ' + n + ' selected…' : 'Delete selected…', 'trash-2'); }
}
async function viewResources() {
  const r = await measured('resources', 'resources');
  // A selection that no longer exists (or can no longer go) is dropped.
  const ok = new Set(r.items.filter(resSelectable).map((i) => i.id));
  for (const id of [...state.resSel]) if (!ok.has(id)) state.resSel.delete(id);
  return resourcesNode(r);
}
function renderResources() {
  if (state.view !== 'resources' || !state.measured.resources) return;
  const top = $('main').scrollTop;
  $('view').replaceChildren(resourcesNode(state.measured.resources));
  $('main').scrollTop = top;
}
function resourcesNode(r) {
  const del = btn('Delete selected…', () => resDelete([...state.resSel], false), { danger: true, icon: 'trash-2' });
  del.setAttribute('data-res-delete', '');
  const selAll = btn('Select all re-creatable', () => {
    for (const i of r.items) if (resSelectable(i) && i.recreatable && !(i.parent && state.resSel.has(i.parent))) state.resSel.add(i.id);
    // A parent selected covers its parts.
    for (const i of r.items) if (i.parent && state.resSel.has(i.parent)) state.resSel.delete(i.id);
    renderResources();
  }, { icon: 'list-checks', title: 'Everything that is re-created when next needed (built-in images, caches, kernels, the guest init)' });
  const clear = btn('Clear selection', () => { state.resSel.clear(); renderResources(); }, { icon: 'x' });
  const node = h('div', { class: 'resources' },
    h('div', { class: 'head' }, h('h1', null, 'Resources'),
      h('div', { class: 'actions' }, btn('Refresh', () => { remeasure(); refresh(false); }, { small: true, title: 'Measure again' }),
        btn('Clean up…', () => resDelete([], true), { primary: true, icon: 'badge-check',
          title: 'Re-creatable AND unused: the download cache, base disks, old kernels, images no sandbox was created from in ' + r.unusedDays + ' days, leftovers. Never templates, sandboxes, restore points, settings or keys.' }))),
    h('p', { class: 'sub' }, 'Everything Dozer uses. Images are managed on ', h('a', { href: '#/images' }, 'Images'), ', a sandbox on its page, accounts on ',
      h('a', { href: '#/accounts' }, 'Accounts & keys'), ' — the rows link there. Deleting here is for what has no other home. Measured in ' + Math.round(r.milliseconds) + ' ms.'),
    resTotalBar(r),
    pageIndex([...RES_GROUPS.filter(([g]) => r.items.some((i) => i.group === g)).map(([g, t]) => ['res-' + g, t,
      g === 'outside' ? null : bytes(r.items.filter((i) => i.group === g && !i.parent).reduce((a, i) => a + (i.sizeBytes || 0), 0))]),
      ['res-memory', 'Memory and CPUs'], ['res-network', 'Network'], ['res-kernels', 'Kernels']]),
    h('div', { class: 'res-toolbar' }, selAll, clear, del),
    RES_GROUPS.map(([g, t]) => resGroupPanel(r, g, t)),
    h('p', { class: 'res-sum', 'data-res-sum': '' }, 'The rows add up to ' + bytes(r.attributedBytes) + ' of the ' + bytes(r.totalBytes) + ' measured — unattributed: ',
      h('strong', { class: r.unattributedBytes ? 'res-refusal' : null }, bytes(r.unattributedBytes)), '.'),
    resMemoryPanel(r), resNetworkPanel(r), resKernelsPanel(r));
  const n = state.resSel.size;
  del.disabled = n === 0;
  if (n) setButton(del, 'Delete ' + n + ' selected…', 'trash-2');
  return node;
}
/// Preview (changes nothing), then ONE plain confirmation listing what goes, what it frees and what
/// each costs later; the operation deletes exactly those ids (a change since is refused, never widened).
async function resDelete(ids, clean) {
  if (!clean && !ids.length) return;
  let plan;
  try { plan = await api('resources/preview', { method: 'POST', json: clean ? { clean: true } : { ids } }); }
  catch (e) { pageFailure(e.message || String(e), { key: 'resources' }); return; }
  if (!plan.items.length) {
    if (clean) toast('Nothing to clean up — everything re-creatable is in use or already gone.', false, 'info');
    else pageFailure('Nothing can be deleted: ' + (plan.refused[0] ? plan.refused[0].reason : 'no such item'), { key: 'resources' });
    return;
  }
  const n = plan.items.length;
  const list = h('div', { class: 'res-plan', 'data-res-plan': '' },
    table(['Item', 'Frees', 'Later'], plan.items.map((e) => h('tr', { 'data-plan-item': e.id },
      h('td', null, e.name, h('div', { class: 'muted mono' }, e.id)),
      h('td', { class: 'num' }, bytes(e.freedBytes)),
      h('td', null, e.later || '—', e.warning ? h('div', { class: 'res-warn' }, '⚠ ' + e.warning) : null))), [1]),
    plan.refused.length ? h('div', { class: 'res-refused' }, h('strong', null, 'Not deleted: '),
      plan.refused.map((x) => h('div', { 'data-plan-refused': x.id }, x.id + ' — ' + x.reason))) : null,
    h('p', { class: 'res-plan-total' }, 'Frees ', h('strong', { 'data-plan-freed': '' }, bytes(plan.freedBytes)), ' in all (blocks shared between them counted once).'));
  const title = clean ? 'Clean up' : 'Delete ' + n + ' item' + (n === 1 ? '' : 's');
  const d = dialog(title, (clean ? 'Re-creatable and unused — never templates, sandboxes, restore points, settings or keys. Logs and metrics are kept — select them to clear. ' : '') +
    'One operation: the host waits until nothing that uses the disks is under way.', [],
    clean ? 'Clean up' : 'Delete', async () => {
      const op = await actOrThrow({ action: 'resources-rm', ids: plan.items.map((e) => e.id) });
      state.resSel.clear();
      return op;
    }, { danger: true, icon: clean ? 'badge-check' : 'trash-2' });
  d.querySelector('.dlg-extra').append(list);
  d.classList.add('dlg-wide');
}

async function viewAccounts() {
  const a = await api('accounts');
  const rows = a.accounts.map((x) => h('tr', null,
    h('td', null, x.name, x.isDefault ? h('span', { class: 'tag' }, 'default') : null),
    h('td', null, x.kind, x.plan ? h('div', { class: 'muted' }, x.plan) : null),
    h('td', null, x.identity || '—'),
    h('td', null, h('span', { class: x.state === 'ok' ? 'st-ok' : 'st-warn' }, x.state), x.verification ? h('div', { class: 'muted' }, x.verification) : null),
    h('td', null, x.expiresAt ? full(x.expiresAt) : '—', x.expiresAt ? h('div', { class: 'muted' }, when(x.expiresAt)) : null),
    h('td', { class: 'mono' }, x.fingerprint || '—', x.keychainService ? h('div', { class: 'muted' }, 'keychain: ' + x.keychainService) : null),
    h('td', null, x.usedBy.length ? x.usedBy.join(', ') : '—'),
    h('td', { class: 'row-acts-cell' }, (() => {
      const items = [
        x.isDefault ? null : { label: 'Make default', icon: 'star', desc: 'Sandboxes that follow the store default use it', onSelect: () => act({ action: 'account-default', account: x.name }) },
        x.kind === 'mac' || x.isDefault ? null : { label: 'Verify', icon: 'badge-check', desc: 'One tiny request to the API with it', onSelect: () => act({ action: 'account-verify', account: x.name }) },
        x.name === 'mac' ? null : { sep: true },
        x.name === 'mac' ? null : { label: 'Remove…', icon: 'trash-2', danger: true, desc: 'Its keychain item is deleted', onSelect: () => confirmAction('Remove account ' + x.name,
          'Its keychain item is deleted' + (x.usedBy.length ? '; sandboxes pinned to it must move first (' + x.usedBy.join(', ') + ')' : '') + '.', x.name, { action: 'account-rm', account: x.name }) },
      ].filter(Boolean);
      // The next verb: Verify for a key or a token, else Make default; the rest in ⋯.
      const next = x.kind !== 'mac' ? btn('Verify', () => act({ action: 'account-verify', account: x.name }), { small: true, quiet: true, title: 'One tiny request to the API with it' })
        : x.isDefault ? null : btn('Make default', () => act({ action: 'account-default', account: x.name }), { small: true, quiet: true });
      const rest = items.filter((it) => it.sep || !next || it.label !== next.textContent.trim());
      while (rest.length && rest[0].sep) rest.shift();
      return h('div', { class: 'row-acts' }, next, rest.length ? moreMenu('More for ' + x.name, rest, { small: true }).el : null);
    })())));
  const keep = h('input', { type: 'checkbox', role: 'switch', id: 'keepalive' });
  keep.checked = a.keepalive;
  keep.addEventListener('change', () => act({ action: 'account-keepalive', enabled: keep.checked }));
  return h('div', null, h('h1', null, 'Accounts & keys'),
    h('p', { class: 'sub' }, 'Anthropic credentials the host holds for sandboxes. Never a secret: states, keychain item names and fingerprints only.'),
    h('div', { class: 'stats' },
      card('Default account', a.defaultAccount, a.defaultAccount === 'none' ? 'sandboxes that follow it get none' : ''),
      h('div', { class: 'stat' }, h('div', { class: 'k' }, 'Keep-alive'), h('label', { class: 'v switch-row' }, keep, a.keepalive ? 'on' : 'off'),
        h('div', { class: 'n' }, 'runs the Mac’s own claude -p near expiry while a sandbox uses the login'))),
    h('div', { class: 'head' }, h('h2', null, 'Accounts'), btn('Set the default to none', () => act({ action: 'account-default', account: 'none' }), { small: true })),
    panel(table(['Account', 'Kind', 'Identity', 'State', 'Expires', 'Fingerprint', 'Used by', ''], rows)),
    h('h2', null, 'Add an account'),
    secretEntryAllowed()
      ? accountForm({ kind: null, onAdded: (r, name) => {
          const row = r.accounts.find((x) => x.name === name);
          toast('account ' + name + ' added' + (row && row.verification ? ' (' + row.verification + ')' : ''));
          refresh(false);
        } })
      : h('div', null, accountCommandsNode('setup-token'), accountCommandsNode('api-key')),
    h('p', { class: 'muted' }, 'Stored exactly as doz account add stores it: the login keychain (doz-claude:NAME, doz-anthropic:NAME), after one tiny check request. ',
      'This page keeps no copy. ui.allow_secret_entry (Settings) turns the field off.'));
}

async function viewMetrics() {
  const f = state.metricsFilter;
  const qs = new URLSearchParams();
  if (f.image) qs.set('image', f.image);
  if (f.days) qs.set('days', f.days);
  qs.set('steps', f.steps ? '1' : '0');
  const [m, images] = await Promise.all([api('metrics?' + qs), api('images').catch(() => [])]);
  const imageSel = h('select', { 'aria-label': 'image' }, [['', 'all images'], ...images.map((i) => [i.kind === 'custom' ? 'custom:' + i.name : i.name, i.name])].map(([v, l]) => {
    const o = h('option', { value: v }, l);
    if (v === f.image) o.selected = true;
    return o;
  }));
  const daysSel = h('select', { 'aria-label': 'since' }, [['', 'all time'], ['1', 'last day'], ['7', 'last 7 days'], ['30', 'last 30 days']].map(([v, l]) => {
    const o = h('option', { value: v }, l);
    if (v === f.days) o.selected = true;
    return o;
  }));
  const steps = h('input', { type: 'checkbox' });
  steps.checked = f.steps;
  for (const el of [imageSel, daysSel, steps]) {
    el.addEventListener('change', () => { state.metricsFilter = { image: imageSel.value, days: daysSel.value, steps: steps.checked }; refresh(false); });
  }
  const csv = h('a', { class: 'btn sm', href: '/api/v1/metrics.csv?' + qs, download: 'dozer-metrics.csv' }, withIcon('download', 'Download CSV'));
  const toolbar = h('div', { class: 'toolbar' }, imageSel, daysSel, h('label', null, steps, ' steps inside actions'), csv);
  if (!m.available) return h('div', null, h('h1', null, 'Metrics'), toolbar, panel(null, 'No metrics yet — the host records every action it times.'));
  const max = Math.max(1, ...m.summary.map((r) => r.p90Ms || r.medianMs || 0));
  const rows = m.summary.map((r) => {
    const bar = h('span');
    bar.style.width = (((r.medianMs || 0) / max) * 100).toFixed(1) + '%';
    return h('tr', null, h('td', null, r.action, r.kind === 'step' ? h('span', { class: 'tag' }, 'step') : null), h('td', { class: 'num' }, String(r.count)),
      h('td', { class: 'num' }, ms(r.medianMs)), h('td', { class: 'num' }, ms(r.p90Ms)),
      h('td', { class: 'num' }, ms(r.minMs)), h('td', { class: 'num' }, ms(r.maxMs)),
      h('td', { class: 'num' }, r.failed ? h('span', { class: 'st-fail' }, String(r.failed)) : ''),
      h('td', { class: 'bar' }, h('div', { class: 'hbar', title: 'median, relative to the slowest p90' }, bar)));
  });
  return h('div', null, h('h1', null, 'Metrics'),
    h('p', { class: 'sub' }, 'Lifecycle timings the host recorded.'),
    toolbar,
    h('div', { class: 'stats' }, card('Host runs', String(m.runs)), card('Rows', String(m.rows)), card('Sessions', String(m.sessions)), card('Network minutes', String(m.networkMinutes))),
    h('h2', null, 'Per action'),
    panel(h('div', { class: 'bars' }, table(['Action', 'Count', 'Median', 'P90', 'Min', 'Max', 'Failed', ''], rows, [1, 2, 3, 4, 5, 6])), 'Nothing recorded for this filter.'));
}

async function viewActivity() {
  const recent = await api('events');
  const seen = new Set(state.activity.map((a) => a.seq));
  for (const a of recent) if (!seen.has(a.seq)) state.activity.push(a);
  state.activity.sort((x, y) => x.seq - y.seq);
  return activityNode();
}
function activityNode() {
  const items = state.activity.slice().reverse().map((a) => h('li', null,
    h('span', { class: 't' }, clock(a.time)), h('span', { class: 'who muted' }, a.sandbox || a.kind),
    h('span', { class: 'text' }, a.text)));
  return h('div', null, h('h1', null, 'Activity'),
    h('p', { class: 'sub' }, 'What the host does — phases, timed steps, notes — while a sandbox is live and this page is open.'),
    panel(items.length ? h('ul', { class: 'feed' }, items) : null, 'Nothing yet. Start or wake a sandbox and it shows here.'));
}
function renderActivity() { $('view').replaceChildren(activityNode()); }

async function viewDoctor() {
  const checks = await api('doctor');
  const rows = checks.map((c) => h('tr', null, h('td', null, statusPill(c.status)), h('td', null, c.check), h('td', null, c.detail)));
  return h('div', null,
    h('div', { class: 'head' }, h('h1', null, 'Doctor'),
      btn('Run onboarding again', () => { state.wiz = null; location.hash = '#/onboarding'; },
        { title: 'The setup wizard: checks, the Claude account, settings, images — it prepares only what is missing' })),
    h('p', { class: 'sub' }, 'doz doctor: this Mac, the store, the host and the Claude login (re-checked at most every 30 s).'),
    panel(table(['', 'Check', 'Detail'], rows)));
}
let wizTimer = null;
function wizardStopPolling() { clearInterval(wizTimer); wizTimer = null; }
function wizardPoll() {
  if (wizTimer) return;
  wizTimer = setInterval(async () => {
    if (state.modal !== 'onboarding' || !state.wiz || state.wiz.step !== WIZ.preparing) { wizardStopPolling(); return; }
    try { state.preps = await api('preparations'); } catch (_) { return; }
    renderOps();
    renderWizard();
  }, 1000);
}
async function viewOnboarding() {
  if (!state.wiz) state.wiz = { step: 0, data: null, account: null, images: null, config: null, created: null, busy: false };
  const w = state.wiz;
  if (!w.data || w.step <= 1) w.data = await api('onboarding');
  if (w.step === WIZ.preparing) { await loadPreparations(); wizardPoll(); }
  return wizardNode();
}
/// Re-render in place (a preparation's progress; a step change). The first-sandbox form is never
/// re-rendered under the person typing in it.
function renderWizard(force) {
  if (state.modal !== 'onboarding' || !state.wiz) return;
  if (!force && state.wiz.step !== WIZ.preparing) return;
  // A step change moves focus in; a preparation's tick does not (it would pull focus from the button in use).
  const before = state.wizShown;
  state.wizShown = state.wiz.step;
  wizMount(wizardNode(), !!force && before !== state.wiz.step);
}
/// 603: a step's failure is said in the step (above its buttons) and stays until the next try or step.
function wizFail(text) {
  if (!state.wiz) { pageFailure(text); return; }
  state.wiz.error = text;
  renderWizard(true);
}
function wizGo(step) {
  const w = state.wiz;
  w.step = step;
  w.error = null;
  if (step === WIZ.preparing) { loadPreparations().then(() => renderWizard(true)); wizardPoll(); } else wizardStopPolling();
  if (step >= WIZ.first) refreshNav();          // the nav's Onboarding dot goes once the record is written
  renderWizard(true);
}
function wizButtons(...buttons) { return h('div', { class: 'wiz-buttons' }, buttons); }
function wizChosenImages() {
  const w = state.wiz, d = w.data;
  if (!w.images) w.images = new Set(d.images.filter((i) => i.recommended || i.prepared).map((i) => i.name));
  return WIZ_ORDER.filter((n) => w.images.has(n));
}
function wizDiskNeed() {
  const d = state.wiz.data;
  const todo = d.images.filter((i) => state.wiz.images.has(i.name) && !i.prepared);
  if (!todo.length) return 0;
  const base = todo.some((i) => i.name === 'claude-code' || i.name === 'pi') ? d.nodeBaseBytes : 0;
  return d.commonBytes + base + d.headroomBytes + todo.reduce((s, i) => s + i.diskBytes, 0);
}
function wizardNode() {
  const w = state.wiz, d = w.data;
  // 596: the base catalogue for the First sandbox step, read early (a late answer never re-renders a typed form).
  if (!w.basesAsked) { w.basesAsked = true; api('bases').then((b) => { w.bases = b; }).catch(() => { w.bases = null; }); }
  // 603: the same vertical stepper as New sandbox (a done step can be gone back to before Preparing).
  const { list: stepper, compact } = stepperNode(WIZ_STEPS.map((title, i) => ({ id: String(i), title })), w.step,
    { go: (i) => (i < w.step && w.step < WIZ.preparing && i > 0 ? () => wizGo(i) : null) });
  const body = [wizStep0, wizStep1, wizStep2, wizStepRules, wizStep3, wizStep4, wizStep5, wizStep6][w.step](d, w);
  // The step's buttons (its last part) become the card's footer, which never leaves the screen.
  const last = body[body.length - 1];
  const foot = last && last.classList && last.classList.contains('wiz-buttons') ? body.pop() : null;
  if (foot) foot.classList.add('w-foot');
  return h('div', { class: 'wizard', 'data-step': String(w.step) },
    wizHead('Set up Dozer Sandbox', ['Once for this Mac (store ', h('code', null, $('store-path').textContent), '). The same as ', h('code', null, 'doz onboard'), ' in a terminal.'],
      [], { list: stepper, compact }),
    h('section', { class: 'wiz-card wiz-body' }, h('div', { class: 'w-body' }, body,
      w.error ? callout('bad', { compact: true, body: w.error, attrs: { 'data-wiz-error': '' }, dismiss: () => { w.error = null; renderWizard(true); } }) : null), foot));
}
function wizStep0(d) {
  // 602 (owner: "detect if onboarding has already ran (i ran it in the cli) and show that and give the
  // option to run the onboarding again"): a store with its record opens on what was set up, not on the
  // welcome — the record is the host's, written by `doz onboard` and this wizard alike.
  if (d.onboarded) {
    const o = d.onboarded;
    return [
      h('h2', null, statusPill('ok'), ' Already set up'),
      h('p', null, 'Onboarding finished on ', h('strong', null, full(o.date)), ' with doz ', h('code', null, o.dozVersion),
        '. It is the same whether it ran here or as ', h('code', null, 'doz onboard'), ' in a terminal.'),
      table(['', ''], [
        h('tr', null, h('td', null, 'Images prepared'), h('td', { 'data-onboarded-images': '' },
          o.images.length ? o.images.join(', ') : 'none chosen')),
        h('tr', null, h('td', null, 'Store'), h('td', null, h('code', null, $('store-path').textContent))),
      ]),
      h('p', { class: 'sub' }, 'Running it again checks this Mac again, lets you change the Access choices and which images are '
        + 'prepared, and prepares only what is missing — nothing already prepared is rebuilt, and your sandboxes are not touched.'),
      wizButtons(
        btn('Run onboarding again', () => wizGo(1), { primary: true, icon: 'rotate-ccw' }),
        btn('Go to Sandboxes', () => { location.hash = '#/overview'; }, { icon: 'box' })),
    ];
  }
  return [
    h('h2', null, 'Welcome'),
    h('p', null, 'Dozer Sandbox runs each project in its own small Linux virtual machine on this Mac — an agent like Claude Code works there, not on your Mac. A sandbox pauses in a millisecond, hibernates to disk and wakes in a third of a second.'),
    h('p', null, 'Setting up takes a few minutes, once: this Mac is checked, you choose how sandboxes reach Claude, the settings file is written, and the images you pick are downloaded and prepared — in the background, so the first sandbox starts in seconds instead of minutes.'),
    wizButtons(btn('Get started', () => wizGo(1), { primary: true })),
  ];
}
function wizStep1(d, w) {
  const rows = d.checks.map((c) => h('tr', { 'data-check': c.check },
    h('td', null, statusPill(c.status === 'fail' && !c.hard ? 'warn' : c.status)),
    h('td', null, c.check, c.hard ? h('span', { class: 'tag' }, 'required') : null),
    h('td', null, c.detail)));
  const next = btn('Next', () => wizGo(2), { primary: true });
  if (d.blocked) next.disabled = true;
  return [
    h('h2', null, 'Checks'),
    h('p', { class: 'sub' }, 'The doctor’s checks. A required one that fails stops the setup; the others only say what will not work yet (Claude Code missing or signed out: add an account later; vmnet: only --network nat needs it).'),
    table(['', 'Check', 'Detail'], rows),
    d.blocked ? callout('bad', { cls: 'notice', body: 'A required check failed — fix it, then Check again.' }) : null,
    wizButtons(btn('Back', () => wizGo(0)), btn('Check again', async () => { w.data = await api('onboarding'); renderWizard(true); }), next),
  ];
}
function wizStep2(d, w) {
  if (!w.account) w.account = d.preferredAccount;
  const opts = d.accountOptions.map((o) => {
    const input = h('input', { type: 'radio', name: 'wiz-account', value: o.value });
    input.checked = o.value === w.account;
    input.addEventListener('change', () => { w.account = o.value; renderWizard(true); });
    return h('label', { class: 'wiz-choice' + (o.value === w.account ? ' chosen' : ''), 'data-account': o.value }, input,
      h('span', null, o.label, o.value === d.preferredAccount ? h('span', { class: 'tag' }, 'recommended') : null));
  });
  const keyed = w.account === 'api-key' || w.account === 'setup-token';
  let entry = null;
  if (keyed && w.added) {
    entry = callout('ok', { cls: 'notice', attrs: { 'data-added': w.added.name }, body: ['Account ', h('strong', null, w.added.name), ' added (' + w.added.kind +
      (w.added.verification ? ', ' + w.added.verification : '') + ') — the store’s default account. Its secret is in the login keychain, not in this page.'] });
  } else if (keyed && secretEntryAllowed()) {
    entry = accountForm({ kind: w.account, name: 'work', onAdded: async (r, name) => {
      const row = r.accounts.find((x) => x.name === name) || { kind: w.account };
      try { await actOrThrow({ action: 'account-default', account: name }); } catch (e) { w.error = e.message || String(e); }
      w.added = { name, kind: row.kind, verification: row.verification };
      renderWizard(true);
    } });
  } else if (keyed) {
    entry = accountCommandsNode(w.account);
  }
  // 599e: the rest of the Access step — GitHub as you and the SSH agent, then each credential confirmed.
  // The Claude account is confirmed too once it is one (this Mac's login, or an account just added).
  if (!w.access) w.access = {};
  const claudeConfirmable = w.account === 'mac' || (keyed && !!w.added);
  if (w.accessClaudeFor !== (claudeConfirmable ? (w.added ? w.added.name : w.account) : null)) {
    delete w.access.results?.claude;
    w.access.skipped?.delete('claude');
    w.accessClaudeFor = claudeConfirmable ? (w.added ? w.added.name : w.account) : null;
  }
  const accessBox = h('div', { class: 'wiz-access' });
  const access = renderAccessStep(accessBox, { mode: 'onboarding', state: w.access, claude: claudeConfirmable });
  return [
    h('h2', null, 'Access'),
    h('p', { class: 'sub' }, 'What sandboxes may use as you — each one a choice of yours (nothing is on unless you choose it), then confirmed live. A credential that cannot be confirmed can be skipped: the setup is never blocked.'),
    h('h3', null, 'Claude account'),
    h('p', null, d.macSignedIn
      ? 'Claude Code is signed in on this Mac. Sandboxes can use that login: nothing is copied into them — the Mac’s proxy adds it to their requests to Anthropic, and the Mac keeps renewing it.'
      : 'Claude Code is not signed in on this Mac. A sandbox can use an Anthropic API key or a Claude setup token instead, or you can decide later.'),
    h('fieldset', { class: 'wiz-choices' }, h('legend', null, 'How should sandboxes reach Claude?'), opts),
    entry,
    h('p', { class: 'muted' }, 'The setup never logs in for you and never copies Claude Code’s refresh token. A key or a token is stored as doz account add stores it (the login keychain). The store’s default account now: ' +
      (w.added ? w.added.name : d.defaultAccount) + '.'),
    h('h3', null, 'GitHub and SSH'),
    accessBox,
    wizButtons(btn('Back', () => wizGo(1)), btn('Next', async (ev) => {
      const b = ev.currentTarget;
      b.disabled = true;
      try {
        if (w.account === 'mac' && d.defaultAccount !== 'mac') { await actOrThrow({ action: 'account-default', account: 'mac' }); d.defaultAccount = 'mac'; }
        // Confirm what is not yet; a failure stays on this step with its reason and Skip — never a dead end.
        if (await access.confirm()) wizGo(WIZ.rules);
        else { wizFail('Not everything is confirmed — Skip it, turn it off, or check again.'); }
      } catch (e) { wizFail(e.message || String(e)); }
    }, { primary: true })),
  ];
}
/// 599g (owner A1): what .dozignore / .dozreadonly do, and the default mode for every sandbox — sent with the
/// settings (POST onboarding/config {ignoreMode}) and written only then, as the Access choices are.
function wizStepRules(d, w) {
  if (!w.ignoreMode) w.ignoreMode = setting('workspace.ignore_mode', 'lock');
  return [
    h('h2', null, d.rulesGuide.title),
    rulesStep({ mode: 'onboarding', guide: d.rulesGuide, value: w.ignoreMode, onPick: (v) => { w.ignoreMode = v; } }),
    wizButtons(btn('Back', () => wizGo(WIZ.access)), btn('Next', () => wizGo(WIZ.images), { primary: true })),
  ];
}
function wizStep3(d, w) {
  wizChosenImages();
  const items = d.images.map((i) => {
    const input = h('input', { type: 'checkbox', value: i.name });
    input.checked = w.images.has(i.name);
    input.addEventListener('change', () => { if (input.checked) w.images.add(i.name); else w.images.delete(i.name); renderWizard(true); });
    return h('label', { class: 'wiz-choice wiz-image' + (input.checked ? ' chosen' : ''), 'data-image': i.name }, input,
      h('span', null, h('strong', null, i.name), i.recommended ? h('span', { class: 'tag' }, 'recommended') : null,
        i.prepared ? h('span', { class: 'pill st-ok' }, 'ready') : null,
        h('div', null, i.summary),
        h('div', { class: 'muted' }, i.prepared ? 'already prepared in this store' : i.download + ' · ' + i.estimate)));
  });
  const need = wizDiskNeed();
  const short = d.freeBytes != null && need > d.freeBytes;
  const chosen = wizChosenImages();
  const todo = chosen.filter((n) => !d.images.find((i) => i.name === n).prepared);
  const go = btn(todo.length ? 'Prepare and continue' : 'Continue', async (ev) => {
    const b = ev.currentTarget;
    b.disabled = true;
    try {
      const config = { defaultImage: chosen[0] || 'claude-code', account: w.account || d.preferredAccount };
      if (w.access && w.access.choices) config.access = { ...w.access.choices };     // 599e: the defaults for new sandboxes
      if (w.ignoreMode) config.ignoreMode = w.ignoreMode;                             // 599g: chosen in the Workspace rules step
      w.config = await api('onboarding/config', { method: 'POST', json: config });
      await loadSettings();               // what was just written (Access, Workspace rules) is what New sandbox starts from
      await actOrThrow({ action: 'onboard', images: chosen });
      w.prepImages = todo;
      wizGo(todo.length ? WIZ.preparing : WIZ.first);
    } catch (e) { wizFail(e.message || String(e)); }
  }, { primary: true });
  if (short) go.disabled = true;
  return [
    h('h2', null, 'Images'),
    h('p', { class: 'sub' }, 'Preparing an image downloads its base and bakes it — the part a first start would otherwise make you wait for. claude-code is ticked; pi, codex and lab are optional (each can also be prepared later, or by its first start).'),
    h('div', { class: 'wiz-choices' }, items),
    chosen.includes('codex') ? wizCodexAccount(w) : null,
    h('p', { class: short ? 'st-fail' : 'muted', 'data-disk': '1' }, need ? 'About ' + bytes(need) + ' of disk needed (with room for a first sandbox)' +
      (d.freeBytes != null ? '; ' + bytes(d.freeBytes) + ' free' : '') + (short ? ' — free some space or choose fewer images.' : '.') : 'Nothing to download.'),
    wizButtons(btn('Back', () => wizGo(WIZ.rules)), go),
  ];
}
/// 599i: with the codex image ticked — Codex uses an OpenAI account: Dozer's own ChatGPT sign-in (a terminal
/// command: the browser opens on this Mac) or an OpenAI key in the masked field; made the store's OpenAI default.
function wizCodexAccount(w) {
  const box = h('div', { class: 'panel wiz-codex', 'data-codex-account': '' });
  const paint = () => {
    if (w.codexAdded) {
      box.replaceChildren(callout('ok', { cls: 'notice', attrs: { 'data-added': w.codexAdded }, body: ['Codex: account ', h('strong', null, w.codexAdded),
        ' added — the store’s default OpenAI account. Its secret is in the login keychain, not in this page.'] }));
      return;
    }
    if (w.codexMac) {
      // rc.3: Codex is signed in on this Mac — the least setup: nothing to add.
      box.replaceChildren(callout('ok', { cls: 'notice', attrs: { 'data-codex-mac': '' }, title: 'Codex is signed in on this Mac',
        body: [h('span', null, 'Codex sandboxes use that login (the account mac) — nothing is copied: Dozer reads only its short-lived access token, and the Mac’s Codex renews it. '
          + 'Keep Codex running on this Mac, or turn on Settings › codex.keep_alive, so it stays fresh. Another account can still be chosen per sandbox.')] }));
      return;
    }
    box.replaceChildren(h('h3', null, 'Codex account (OpenAI)'),
      h('p', { class: 'muted' }, 'Codex uses your ChatGPT plan (Dozer signs in on this Mac — your Mac’s own Codex login is not touched) or an OpenAI API key. Either can be added later; a codex sandbox says what it needs.'),
      accountCommandsNode('chatgpt'),
      secretEntryAllowed() ? accountForm({ kind: 'openai-key', name: 'openai', onAdded: async (r, name) => {
        try { await actOrThrow({ action: 'account-default', account: name }); } catch (e) { w.error = e.message || String(e); }
        w.codexAdded = name;
        paint();
      } }) : accountCommandsNode('openai-key'));
  };
  paint();
  if (w.codexMac === undefined) {
    w.codexMac = false;
    api('accounts').then((a) => { w.codexMac = a.accounts.some((x) => x.kind === 'codex-mac' && (x.state === 'ok' || x.state === 'expired')); paint(); }).catch(() => {});
  }
  return box;
}
function wizStep4(d, w) {
  const mine = w.prepImages || [];
  // Every preparation the host runs (another image's too — each with its own progress), and this
  // wizard's own; the newest of each image.
  const preps = state.preps.filter((p) => mine.includes(p.image) || prepRunning(p)).filter((p, i, a) => a.findIndex((x) => x.image === p.image) === i);
  const ours = preps.filter((p) => mine.includes(p.image));
  const running = ours.some(prepRunning);
  const failed = ours.filter((p) => !prepRunning(p) && p.state !== 'done');
  const next = btn('Next', () => wizGo(WIZ.first), { primary: true });
  if (running || failed.length) next.disabled = true;
  return [
    h('h2', null, 'Preparing'),
    h('p', { class: 'sub' }, 'In the host — not in this page: closing the tab changes nothing, and doz onboard --status in a terminal shows the same. Whoever starts a sandbox of these images meanwhile joins this preparation instead of starting another.'),
    preps.length ? h('div', { class: 'prep-cards' }, preps.map((p) => prepCard(p, { open: true }))) : h('p', { class: 'muted' }, 'Starting…'),
    wizButtons(
      running ? btn('Cancel preparation', () => act({ action: 'prepare-cancel', images: mine }), { danger: true }) : null,
      failed.length ? btn('Try again', async () => {
        try { await actOrThrow({ action: 'onboard', images: failed.map((p) => p.image) }); await loadPreparations(); renderWizard(true); } catch (e) { wizFail(e.message || String(e)); }
      }) : null,
      running ? btn('Continue in the background', () => { toast('It goes on in the host — Operations shows it.'); wizGo(WIZ.first); }) : null,
      next),
  ];
}
function wizStep5(d, w) {
  const chosen = wizChosenImages();
  const imgs = [...new Set([...chosen, ...d.images.filter((i) => i.prepared).map((i) => i.name)])];
  const name = h('input', { type: 'text', name: 'wiz-name', placeholder: 'a-z 0-9 -', autocomplete: 'off', spellcheck: 'false' });
  name.value = w.firstName || '';
  // 596 (B1): the same Agent × Base choice as New Sandbox (the catalogue read when the wizard opened).
  let chooser = null;
  const picker = imagePicker({ images: [], bases: w.bases || null, value: w.firstImage || imgs[0] || 'claude-code', dockerfile: w.firstDockerfile || '',
    onChange: () => { w.firstImage = picker.image(); w.firstDockerfile = picker.dockerfile() || ''; if (chooser) chooser.imageChanged(); if (acct) acct.agentChanged(); },
    onDockerfile: (folder) => { if (chooser) chooser.suggest(folder); } });
  const image = { get value() { return picker.image(); } };
  // 594: the name from the image (claude-sandbox, -2 when taken), its folder under the projects folder
  // (made when missing) — both follow until typed in; Choose… is the Mac's own folder picker; or Isolated.
  chooser = workspaceChooser({ nameInput: name, image: () => pickerNameHint(picker), initialPath: w.firstWorkspace || '', initialIsolated: !!w.firstIsolated });
  if (w.firstName) name.dispatchEvent(new Event('input'));
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  // 594: the agent's credential prerequisite — only accounts it can use; pi with none: the key here.
  if (!w.accounts) api('accounts').then((a) => { w.accounts = a; if (w.step === WIZ.first) renderWizard(true); }).catch(() => { w.accounts = { accounts: [] }; });
  let acct = null;
  const create = btn('Create sandbox', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const n = name.value.trim();
    w.firstName = n;
    if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(n)) { error.textContent = 'The name: 1–40 of a-z 0-9 - (not starting with -).'; return; }
    let ws;
    try { ws = chooser.get(); } catch (e) { error.textContent = e.message; return; }
    if (acct && !acct.ok()) { error.textContent = (AGENT_NAMES[picker.agent()] || 'This agent') + ' needs an account it can use — add one above.'; return; }
    const blocked = picker.blocked();
    if (blocked) { error.textContent = blocked; return; }
    w.firstWorkspace = ws.workspace || '';
    w.firstIsolated = !!ws.isolated;
    b.disabled = true;
    try {
      const account = acct ? acct.get() : undefined;
      const df = picker.dockerfile();
      await actOrThrow({ action: 'create', sandbox: n, image: image.value, ...ws, ...(account ? { account } : {}), ...(df ? { dockerfile: df } : {}) });
      w.created = n;
      wizGo(WIZ.done);
    } catch (e) { error.textContent = e.message || String(e); b.disabled = false; }
  }, { primary: true });
  if (w.accounts) {
    acct = accountChooser({ accounts: w.accounts, agent: () => picker.agent(),
      onChange: () => { create.disabled = !acct.ok(); api('accounts').then((a) => { w.accounts = a; }).catch(() => {}); } });
    create.disabled = !acct.ok();
  } else create.disabled = true;
  return [
    h('h2', null, 'First sandbox (optional)'),
    h('p', { class: 'sub' }, 'A sandbox for one project. Its workspace is a folder on this Mac, shared live at /workspace — Dozer makes it when it does not exist yet. Or Isolated: nothing is shared. It is created off; Start boots it.'),
    h('label', { class: 'field' }, h('span', null, 'Name'), name),
    picker.el,
    acct ? acct.el : null,
    chooser.el,
    error,
    h('p', { class: 'muted' }, 'In a terminal the same is: doz init in the project folder, then doz up.'),
    wizButtons(btn('Skip', () => wizGo(WIZ.done)), create),
  ];
}
function wizStep6(d, w) {
  const c = w.config;
  const fileLine = (label, outcome, path) => h('li', null, label + ': ', h('code', null, path || '—'),
    outcome === 'written' ? ' — written' : outcome === 'kept' ? ' — it existed, left exactly as it was' : ' — none');
  const preps = state.preps.filter((p) => (w.prepImages || []).includes(p.image));
  const still = preps.filter(prepRunning).map((p) => p.image);
  return [
    h('h2', null, 'Done'),
    h('p', null, still.length ? 'This Mac is set up; ' + still.join(', ') + ' ' + (still.length === 1 ? 'is' : 'are') + ' still being prepared in the host (Operations shows it) — the onboarding is recorded when it is ready.'
                              : 'This Mac is set up.'),
    h('ul', { class: 'plain wiz-summary' },
      h('li', null, 'Claude account: ' + (w.added ? 'the account ' + w.added.name + ' (' + w.added.kind + '), the store default'
        : (d.accountOptions.find((o) => o.value === w.account) || { label: w.account || '—' }).label)),
      w.access && w.access.choices ? h('li', { 'data-access-summary': '' }, 'Access for new sandboxes: GitHub as you ' +
        ({ off: 'off', read: 'read-only', push: 'read and push' }[w.access.choices.github] || w.access.choices.github) +
        (w.access.choices.github !== 'off' ? ' (' + (w.access.choices.githubSource === 'key' ? 'your key' : 'the Mac’s gh login') + ')' : '') +
        ', SSH agent ' + w.access.choices.ssh +
        (w.access.skipped && w.access.skipped.size ? ' — not confirmed: ' + [...w.access.skipped].map((id) => ACCESS_TITLES[id]).join(', ') + ' (Settings › Access checks again)' : '')) : null,
      w.ignoreMode ? h('li', { 'data-rules-summary': '' }, 'Workspace rules: ' + w.ignoreMode + ' — what a .dozignore does to the paths it lists, for every sandbox' +
        (c && c.rulesSet && !c.rulesSet.length ? ' (the settings already said so)' : '')) : null,
      c ? fileLine('Settings', c.settings, c.settingsPath) : null,
      c ? fileLine('Your environment prompt template', c.promptTemplate, c.promptTemplatePath) : null,
      // 599c: where Quick add, New sandbox and doz new put each sandbox's workspace folder.
      h('li', { 'data-wiz-projects': '' }, 'Workspace folders of new sandboxes: ', h('code', null, setting('defaults.projects_dir', '~/Developer/dozer-sandbox-projects') + '/<name>'),
        ' — Quick add and doz new use it; Settings › Choose… moves it'),
      h('li', null, 'Images: ' + (wizChosenImages().join(', ') || 'none now (each is prepared by its first start)')),
      w.created ? h('li', null, 'First sandbox: ', h('a', { href: '#/sandbox/' + w.created }, w.created)) : null),
    h('p', { class: 'muted' }, 'From a terminal: doz init in a project folder, then doz up there. This wizard is always here: Doctor › Run onboarding again.'),
    wizButtons(w.created ? btn('Open ' + w.created, () => { location.hash = '#/sandbox/' + w.created; }, { icon: 'box' }) : null,
      btn('Open Sandboxes', () => { state.wiz = null; location.hash = '#/overview'; }, { primary: true })),
  ];
}
/// After the sandbox's state changed: saved panes of a sandbox that runs go live (their session runs)
/// or close (it is gone); the others repaint their cover (the phase, the wake hint). A sandbox that is
/// SHUT DOWN shows no session screens anywhere (owner, 2026-09-30): every pane of it — saved, or a live
/// one whose session died with the VM — closes, and the area shows the off state. (A FAILED start keeps
/// its boot view: that is where the failure is.)
function promoteSaved(name, live) {
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

// ── a sandbox's terminal area: tabs, and a split (593: per sandbox; the grid's tiles are apart)
function paintTabs() { if (state.view === 'sandbox') renderTerminals(); }
function renderTerminals() {
  const root = $('terminals');
  if (!termUI.built) {
    // Split is a split button (owner, 591): the main part splits and ALWAYS fills the right pane
    // with the chosen kind (or, when split, unsplits); the ▾ menu picks the kind — and when already
    // split, adds that kind to the right pane at once.
    const unsplit = () => {
      const v = sview(state.param);
      v.split = false;
      for (const t of pageTerminals(state.param)) t.pane = 0;
      v.selected[0] = v.selected[0] ?? v.selected[1];
      v.selected[1] = null;
      v.focusedPane = 0;
      renderTerminals();
    };
    termUI.splitMain = btn('Split', () => {
      if (sview(state.param).split) unsplit();
      else splitWith(termUI.splitKind).catch((e) => failureFor(state.param, e.message || String(e)));
    }, { small: true, quiet: true, iconOnly: true, icon: 'columns-2', title: 'Two terminals side by side — the right one is a ' + SPLIT_KINDS[termUI.splitKind] });
    // 603: the caret is a menuButton (kept on screen; the old menu opened off the left edge and its items
    // ended in a literal "null" — replaceChildren writes a null as text, h() skips it).
    const caret = h('button', { type: 'button', class: 'btn sm quiet split-caret caret', title: 'What the split adds', 'aria-label': 'What the split adds' },
      icon('chevron-down'));
    termUI.splitBtn = h('div', { class: 'btn-group split-button', role: 'group', 'aria-label': 'Split' }, termUI.splitMain, caret);
    termUI.splitCtl = menuButton(caret, [], { wrap: termUI.splitBtn, label: 'What the split adds' });
    termUI.splitMenu = termUI.splitCtl.menu;
    // 603 (E3): what makes or arranges terminals sits on the tab strip it changes.
    termUI.newShell = btn('New shell', () => { const n = state.param; newShellTerminal(n).catch((e) => failureFor(n, e.message || String(e))); },
      { small: true, quiet: true, title: 'A new shell session (shell-2, shell-3, …) in a browser terminal' });
    const nsCaret = h('button', { type: 'button', class: 'btn sm quiet caret', title: 'Other terminals', 'aria-label': 'Other terminals' }, icon('chevron-down'));
    const nsGroup = h('div', { class: 'btn-group', role: 'group', 'aria-label': 'New terminal' }, termUI.newShell, nsCaret);
    termUI.nsCtl = menuButton(nsCaret, [], { wrap: nsGroup, label: 'Other terminals' });
    termUI.openTerm = btn('Open in Terminal', () => openInTerminal(state.param, null), { small: true, quiet: true, iconOnly: true, icon: 'square-terminal' });
    termUI.acts = h('div', { class: 'strip-acts', role: 'toolbar', 'aria-label': 'Terminals' }, nsGroup, termUI.splitBtn, termUI.openTerm);
    termUI.panes = [0, 1].map((i) => {
      const strip = h('div', { class: 'tabs', role: 'tablist', 'aria-label': 'Terminals' });
      const head = h('div', { class: 'term-strip' }, strip);
      const body = h('div', { class: 'term-body' });
      const empty = h('div', { class: 'term-empty' });
      const pane = h('div', { class: 'term-pane', 'data-pane': String(i) }, head, body);
      body.append(empty);
      pane.addEventListener('focusin', () => { if (state.param) sview(state.param).focusedPane = i; });
      pane.addEventListener('mousedown', () => { if (state.param) sview(state.param).focusedPane = i; });
      return { root: pane, strip, head, body, empty };
    });
    termUI.grid = h('div', { class: 'term-grid' }, termUI.panes[0].root, termUI.panes[1].root);
    root.replaceChildren(termUI.grid);
    termUI.built = true;
  }
  const name = state.view === 'sandbox' ? state.param : null;
  const v = name ? sview(name) : { split: false, selected: [null, null] };
  termUI.grid.classList.toggle('split', v.split);
  paintSplitButton();
  termUI.panes[1].root.hidden = !v.split;
  // Another sandbox's terminals stay open (hidden) — going back to it is instant.
  for (const t of terminals.values()) if (!t.grid && t.sandbox !== name) t.els.wrap.hidden = true;
  termUI.panes.forEach((p, i) => {
    const mine = name ? pageTerminals(name).filter((t) => t.pane === i) : [];
    if (!mine.some((t) => t.id === v.selected[i])) v.selected[i] = mine.length ? mine[mine.length - 1].id : null;
    p.strip.replaceChildren(...mine.map((t) => tabElement(t, i)));
    scrollActiveTab(p.strip);
    p.empty.hidden = mine.length > 0;
    for (const t of mine) {
      if (t.els.wrap.parentNode !== p.body) p.body.append(t.els.wrap);
      t.els.wrap.hidden = t.id !== v.selected[i];
      // 593 §9: a restored tab loads its engine the first time it is shown — a hidden frame has no size,
      // and an interactive attach at no size would resize its session.
      if (t.lazy && !t.els.wrap.hidden) {
        t.lazy = false;
        setTimeout(() => bootTerm(t, setting('ui.terminal_font_size', 13)), 0);
      }
    }
  });
  paintTermEmpty();
  // The strip's actions on the rightmost pane shown.
  const host = (v.split ? termUI.panes[1] : termUI.panes[0]).head;
  if (termUI.acts.parentNode !== host) host.append(termUI.acts);
  paintStripActs();
  if (name) persistLayout(name);
  // The URL names the session shown (replaceState: no route).
  const sel = name && terminals.get(v.selected[v.focusedPane] ?? v.selected[0]);
  // (603: never under a wizard's modal — its URL is #/new or #/onboarding; the page's hash follows.)
  if (sel && sel.session && state.session !== sel.session && !state.modal) {
    state.session = sel.session;
    history.replaceState(null, '', location.pathname + '#/sandbox/' + name + '/' + sel.session);
    state.bgHash = location.hash;
  }
}
/// The strip's actions follow the sandbox: a session needs a VM (New shell, Run detached, Open in Terminal); a new
/// terminal waits while something is under way.
function paintStripActs() {
  if (!termUI.acts) return;
  const name = state.param, s = state.sbx;
  const i = s && s.name === name && s.d ? s.d.info : null;
  const why = i ? sessionsWhyNot(name, i) : 'Loading…';
  const busy = !i || i.busy || i.phase === 'booting' || opRunningFor(name) || !!transitionOf(name);
  termUI.newShell.disabled = !!why;
  termUI.newShell.title = why || 'A new shell session (shell-2, shell-3, …) in a browser terminal';
  termUI.openTerm.disabled = !!why;
  termUI.openTerm.title = why || 'Open in Terminal — your terminal app attaches to the ' + (s && s.d ? s.d.defaultSession : 'default') + ' session';
  if (termUI.nsCtl.isOpen()) return;
  termUI.nsCtl.setItems([
    { label: 'Terminal…', icon: 'terminal', desc: 'A new session: a shell, or a command', disabled: busy, why: 'Wait until it settles', onSelect: () => newTerminalDialog(name) },
    { label: 'Run detached…', icon: 'play', desc: 'A new session running a command, not opened here', disabled: !!why, why, onSelect: () => runDetachedDialog(name) },
  ]);
}
/// A pane's tab strip scrolls sideways when its tabs overflow; the selected tab is always in view
/// (orchestrator ruling, 593 follow-up).
function scrollActiveTab(strip) {
  const w = strip.querySelector('.tab.active')?.closest('.tab-wrap');
  if (!w) return;
  const sr = strip.getBoundingClientRect(), wr = w.getBoundingClientRect();
  if (!sr.width) return;
  if (wr.left < sr.left) strip.scrollLeft += wr.left - sr.left;
  else if (wr.right > sr.right) strip.scrollLeft += wr.right - sr.right;
}
/// The terminal area with no terminal: what it can open, from the sandbox's state.
function paintTermEmpty() {
  if (!termUI.built) return;
  const s = state.sbx;
  const p = termUI.panes[0];
  if (p.empty.hidden) return;
  if (!s || !s.d || s.name !== state.param) { p.empty.replaceChildren(h('div', { class: 'term-empty-box' }, 'Loading…')); return; }
  const i = s.d.info;
  const tr = transitionOf(s.name);
  const busy = i.busy || i.phase === 'booting' || opRunningFor(s.name) || !!tr;
  const live = (s.d.sessions || []).filter((x) => !x.ended);
  const box = h('div', { class: 'term-empty-box' });
  if (busy) {
    box.append(h('div', { class: 'term-empty-head' }, tr ? TRANSITION_LABEL[tr.action] : i.phaseLabel + '…'), h('div', null, 'The terminal opens when it can.'));
  } else if (i.phase === 'off' || i.phase === 'failed') {
    // The plain off state (owner, 2026-09-30): no session screens — its sessions ended with the VM.
    box.dataset.off = i.phase;
    box.append(h('div', { class: 'term-empty-head' }, i.phase === 'off' ? 'Shut down' : s.name + ' failed to start'),
      h('div', { class: 'term-empty-note' }, 'Starting boots it fresh — new sessions.'),
      h('div', { class: 'actions center' },
        // The bar's Start is the page's one primary; here it is the terminal's own button, as on the covers.
        ((b) => { b.classList.add('tc-act'); return b; })(btn('Start', () => lifecycle('start', s.name), { small: true, title: bootViewOnStart() ? 'Boot it, and watch it boot here' : 'Boot it' }))));
  } else {
    // 593 §9 (S4): "New shell" always makes a NEW session; a running session is opened by its own name
    // (the sessions list). The image's own session is offered by name: opened when it runs, started when not.
    const saved = (s.d.sessions || []).filter((x) => x.saved);
    const defaultRuns = live.some((x) => x.name === s.d.defaultSession && !x.saved);
    const defaultSaved = saved.some((x) => x.name === s.d.defaultSession);
    box.append(h('div', { class: 'term-empty-head' }, 'No terminal open'),
      h('div', { class: 'actions center' },
        defaultSaved ? null : defaultRuns
          ? btn('Open ' + s.d.defaultSession, () => openTerminal(s.name, s.d.defaultSession, 'interactive'), { icon: 'terminal',
            title: 'A terminal on the running ' + s.d.defaultSession + ' session' })
          : btn('Start ' + s.d.defaultSession, () => openDefaultTerminal(s.name), { icon: 'play',
            title: 'Start the image’s own session (' + s.d.defaultSession + ')' + (i.phase === 'running' ? '' : ' — it wakes the sandbox') }),
        ...live.filter((x) => x.name !== s.d.defaultSession && !x.saved).slice(0, 8).map((x) => btn('Open ' + x.name, () => openTerminal(s.name, x.name, 'interactive'), { icon: 'terminal' })),
        ...saved.slice(0, 8).map((x) => btn('Show ' + x.name, () => openSavedTerminal(s.name, x), { icon: 'eye', title: 'Its last saved screen (read-only)' })),
        btn('New shell', () => newShellTerminal(s.name).catch((e) => failureFor(s.name, e.message || String(e))), { title: 'A NEW shell session (shell-2, shell-3, …)' })));
  }
  p.empty.replaceChildren(box);
}
function tabElement(t, pane) {
  const phase = t.ended || t.errorText || t.disconnected ? 'ended'
    : t.saved ? sandboxPhase(t.sandbox) || 'unknown' : (t.state && t.state.phase) || 'unknown';
  const v = sview(t.sandbox);
  // Tabs are numbered (1, 2, …) per sandbox, so a shared session can say which tab it is shared with.
  const order = pageTerminals(t.sandbox).map((x) => x.id);
  const num = order.indexOf(t.id) + 1;
  const label = num + ' · ' + terminalTitle(t);
  const twins = t.session && !t.ended ? pageTerminals(t.sandbox).filter((o) => o.id !== t.id && !o.ended && o.session === t.session) : [];
  const shared = twins.length ? h('span', { class: 'tag shared', title: 'Two views of ONE session: what is typed in either shows in both' },
    'shared with tab ' + twins.map((o) => order.indexOf(o.id) + 1).join(', ')) : null;
  const select = h('button', { type: 'button', role: 'tab', class: 'tab' + (t.id === v.selected[pane] ? ' active' : ''),
                               // 594 (W14): the one hint a mouse-using program needs.
                               title: (t.title ? t.title + ' — ' + label : label) + '\nShift+drag selects text while the program uses the mouse',
                               'data-term': String(t.id),
                               on: { click: () => { v.selected[pane] = t.id; v.focusedPane = pane; renderTerminals(); focusTerm(t); } } },
    h('span', { class: 'tab-dot ph-' + phase, 'aria-hidden': 'true' }), icon(t.mode === 'watch' ? 'eye' : 'terminal'), label,
    t.mode === 'watch' ? h('span', { class: 'tag' }, 'watch') : null,
    t.saved ? h('span', { class: 'tag saved', title: 'Its last saved screen (' + (t.saved.reason || 'saved') + ', ' + when(t.saved.savedAt) + ') — it goes live when the sandbox runs' }, 'saved') : null,
    shared);
  const move = v.split ? h('button', { type: 'button', class: 'tab-x', title: 'Move to the other pane', 'aria-label': 'Move ' + label + ' to the other pane',
    on: { click: () => { t.pane = 1 - t.pane; v.selected[t.pane] = t.id; renderTerminals(); focusTerm(t); } } }, icon('arrow-left-right')) : null;
  const close = h('button', { type: 'button', class: 'tab-x', title: 'Close this terminal (the session keeps running)', 'aria-label': 'Close ' + label,
    on: { click: () => closeTerminal(t.id) } }, icon('x'));
  return h('div', { class: 'tab-wrap' }, select, move, close);
}
const SPLIT_ICONS = { shell: 'plus', watch: 'eye', attach: 'link', dialog: 'terminal' };
function paintSplitButton() {
  if (!termUI.splitMain) return;
  const split = state.param ? sview(state.param).split : false;
  setButton(termUI.splitMain, split ? 'Unsplit' : 'Split', 'columns-2');
  termUI.splitMain.title = split ? 'Back to one pane (the right pane’s terminals move left)'
                                 : 'Two terminals side by side — the right one is a ' + SPLIT_KINDS[termUI.splitKind];
  termUI.splitCtl.setItems(Object.entries(SPLIT_KINDS).map(([kind, label]) => ({
    label: (split ? 'Add a ' : 'Split with a ') + label, icon: SPLIT_ICONS[kind], check: kind === termUI.splitKind, data: { kind },
    desc: kind === termUI.splitKind ? 'the default (ui.split_default)' : null,
    onSelect: () => {
      termUI.splitKind = kind;
      // The choice is the setting ui.split_default (doz.toml), not this browser's.
      if (setting('ui.split_default', 'shell') !== kind) saveSetting('ui.split_default', kind).catch((e) => pageFailure('ui.split_default was not saved: ' + (e.message || e)));
      paintSplitButton();
      splitWith(kind).catch((e) => failureFor(state.param, e.message || String(e)));
    },
  })));
}
/// Split (if needed) and fill the right pane with `kind` — so a split always creates something.
/// With no terminal on the left there is nothing to watch, attach to or put a shell beside: the
/// New terminal dialog opens instead (for the right pane).
async function splitWith(kind) {
  const name = state.param;
  if (state.view !== 'sandbox' || !name) return;
  const v = sview(name);
  const left = terminals.get(v.selected[0]) || pageTerminals(name).find((t) => t.pane === 0);
  if (!v.split) { v.split = true; renderTerminals(); }
  v.focusedPane = 1;
  if (kind === 'dialog' || !left) { await newTerminalDialog(name); return; }
  if (kind === 'watch' || kind === 'attach') {
    if (!left.session) throw new Error('the left terminal has no session yet — wait for it to start');
    openTerminal(name, left.session, kind === 'watch' ? 'watch' : 'interactive', 1);
    return;
  }
  await newShellTerminal(name, 1);
}

async function newTerminalDialog(sandbox) {
  const names = [sandbox || state.param].filter(Boolean);
  if (!names.length) { pageFailure('Open a sandbox first'); return; }
  const first = names[0];
  // What to open: ALWAYS a new session (593 §9 S4, owner — after "New terminal" attached to a session that
  // already ran): a new shell, or a new session running a command. A running session is reached through
  // its pane or the sessions list (Details › Sessions: Open / Watch), never from here.
  const d = dialog('New terminal in ' + first, 'A new session: a shell, or a command. A session that already runs is opened from the Sessions list.', [
    { name: 'sandbox', label: 'Sandbox', type: 'select', options: names, value: first },
    { name: 'what', label: 'Open', type: 'select', options: [['new', 'New shell'], ['command', 'New session running a command…']] },
    { name: 'session', label: 'Session name (new session only)', placeholder: 'e.g. worker' },
    { name: 'command', label: 'Command (new session only)', placeholder: 'e.g. htop — no shell in front (say bash -lc \'…\' for one)' },
  ], 'Open', async (v) => {
    const sv = sview(v.sandbox);
    const pane = sv.split ? sv.focusedPane : 0;
    if (v.what === 'new') { await newShellTerminal(v.sandbox, pane); return; }
    if (v.what === 'command') {
      const argv = splitArgs(v.command);
      if (!argv.length) throw new Error('the command is empty');
      if (!v.session) throw new Error('a new session needs a name');
      const done = await waitForOp(await actOrThrow({ action: 'open-session', sandbox: v.sandbox, session: v.session, argv }));
      if (!done || done.state !== 'done') throw new Error(done ? done.text : 'the session did not start in time');
      if (!done.text.startsWith('started')) throw new Error('a session named ' + v.session + ' already runs — pick another name (open it from the Sessions list)');
      openTerminal(v.sandbox, v.session, 'interactive', pane);
      return;
    }
    throw new Error('pick what to open');
  });
  const sandboxSel = d.querySelector('[name="sandbox"]'), whatSel = d.querySelector('[name="what"]');
  sandboxSel.closest('label').hidden = true;             // 593: the page's sandbox
  const nameField = d.querySelector('[name="session"]').closest('label'), cmdField = d.querySelector('[name="command"]').closest('label');
  const showFields = () => { const c = whatSel.value === 'command'; nameField.hidden = !c; cmdField.hidden = !c; };
  whatSel.addEventListener('change', showFields);
  showFields();
}

/// A NEW shell session in `sandbox` — `shell-2`, `shell-3`, … (the next name not taken), running a
/// login shell — opened with the ordinary open-session action (one HostOp; its idempotency unchanged:
/// a name that turns out to be taken answers "already running", and the next name is tried).
async function newShellTerminal(sandbox, pane) {
  if (!terminalsAllowed()) return;
  let rows = [], detail = null;
  try { [detail, rows] = await Promise.all([api('sandboxes/' + sandbox), api('sandboxes/' + sandbox + '/sessions')]); } catch (_) { /* asleep: listed after the wake */ }
  const argv = loginShell(detail, rows);
  const taken = new Set(rows.map((r) => r.name));
  for (let n = 2, tries = 0; tries < 20; n++) {
    const name = 'shell-' + n;
    if (taken.has(name)) continue;
    tries++;
    const op = await actOrThrow({ action: 'open-session', sandbox, session: name, argv });
    const done = await waitForOp(op);
    if (!done || done.state !== 'done') throw new Error(done ? done.text : 'the session did not start in time');
    if (done.text.startsWith('started')) { openTerminal(sandbox, name, 'interactive', pane); return; }
    taken.add(name);                                   // it already ran (a sandbox that was asleep): the next one
  }
  throw new Error('no free shell-N name');
}
/// `bash -l` where the image has bash (the built-in images, and custom images made from them; or
/// any running session that is bash), else `sh -l`.
function loginShell(detail, rows) {
  const image = detail && detail.info ? detail.info.image : '';
  const hasBash = ['lab', 'claude-code', 'pi', 'codex'].includes(image) || rows.some((r) => /(^|\/)bash(\s|$)/.test(r.command));
  return hasBash ? ['bash', '-l'] : ['sh', '-l'];
}

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
async function gridEnter() {
  if (!grid.built) gridBuild();
  grid.active = true;
  gridApplySize(setting('ui.grid_tile_size', 'medium'));
  await gridRefresh(true);
}
function gridLeave() {
  if (!grid.active) return;
  grid.active = false;
  clearTimeout(grid.listTimer);
  for (const tile of grid.tiles.values()) detachTile(tile);
}
async function gridRefresh(force) {
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
function gridSchedule() {
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

// ── 603: page shortcuts (owner decision 10 — only the guide's): g then s → Sandboxes, / → the Settings filter,
// ? → this list. Never while a terminal has the focus (its frame), nor in a field, a menu or a dialog.
const SHORTCUTS = [['g s', 'Sandboxes'], ['/', 'The Settings filter'], ['?', 'These shortcuts'], ['Esc', 'Close a menu or a dialog']];
let gPending = 0;
function shortcutsDialog() {
  const d = h('dialog', { class: 'dlg', 'aria-labelledby': 'sc-title' });
  const close = h('button', { type: 'button', class: 'btn quiet', on: { click: () => d.close() } }, withIcon('x', 'Close'));
  d.append(h('div', { class: 'dlg-head' }, h('h2', { class: 'h-title', id: 'sc-title' }, 'Keyboard shortcuts')),
    h('div', { class: 'dlg-body' }, h('dl', { class: 'facts' }, SHORTCUTS.flatMap(([k, what]) => [h('dt', null, k.split(' ').map((x) => h('kbd', null, x))), h('dd', null, what)])),
      h('p', { class: 'sub' }, 'Not while a terminal has the focus — there every key is the terminal’s. Tab moves between controls; arrow keys move within tabs, segmented controls and menus.')),
    h('div', { class: 'dlg-foot' }, close));
  d.addEventListener('close', () => d.remove());
  document.body.append(d);
  d.showModal();
  close.focus();
}
document.addEventListener('keydown', (ev) => {
  if (ev.defaultPrevented || ev.metaKey || ev.ctrlKey || ev.altKey || state.signedOut) return;
  const a = document.activeElement;
  if (a && (a.tagName === 'IFRAME' || a.closest('input, textarea, select, [contenteditable], dialog, .menu'))) return;
  if (document.querySelector('dialog[open]') || state.modal || document.body.classList.contains('ui-paused')) return;
  if (ev.key === 'g') { gPending = Date.now(); return; }
  if (ev.key === 's' && Date.now() - gPending < 1200) { gPending = 0; ev.preventDefault(); location.hash = '#/overview'; return; }
  gPending = 0;
  if (ev.key === '/') {
    ev.preventDefault();
    const focusFilter = () => { const f = document.querySelector('[data-settings-filter]'); if (f) { f.focus(); f.select(); return true; } return false; };
    if (!focusFilter()) { location.hash = '#/settings'; const t0 = Date.now(); const tick = () => { if (!focusFilter() && Date.now() - t0 < 4000) setTimeout(tick, 100); }; setTimeout(tick, 100); }
  } else if (ev.key === '?') { ev.preventDefault(); shortcutsDialog(); }
});

// ── start ───────────────────────────────────────────────────────────────────
// The static page's own controls get their icons here (index.html holds no SVG).
const NAV_ICONS = { overview: 'box', sessions: 'layout-grid', images: 'layers', resources: 'cylinder', operations: 'list-checks', accounts: 'key-round',
                    metrics: 'chart-line', activity: 'activity', onboarding: 'rocket', doctor: 'stethoscope', settings: 'settings' };
for (const a of document.querySelectorAll('#nav > a[data-view]')) {
  if (NAV_ICONS[a.dataset.view]) a.prepend(icon(NAV_ICONS[a.dataset.view]));
  a.title = a.querySelector('.lbl').textContent;       // the rail's tooltip (the label stays readable to assistive tech)
}
setButton($('sign-out'), 'Sign out');
$('nav-toggle').replaceChildren(icon('panel-right'));
$('nav-toggle').addEventListener('click', (ev) => { ev.stopPropagation(); navRail(!document.body.classList.contains('nav-open')); });
document.addEventListener('click', (ev) => { if (document.body.classList.contains('nav-open') && !ev.target.closest('.side')) navRail(false); });
document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && document.body.classList.contains('nav-open')) navRail(false); });

/// The page's start, once signed in (at load, or — 605 — after its first sign-in inside the page).
async function startApp() {
  if (state.started) return;
  state.started = true;
  {
    if (!/^#\/[a-z]/.test(location.hash)) history.replaceState(null, '', location.pathname + '#/overview');
    await loadSettings();
    // 594 (D8): a store never onboarded opens on the setup wizard (once per page load).
    try {
      const o = await api('overview');
      state.overview = o;
      renderNavSandboxes();
      if (o.onboarded === false && location.hash === '#/overview') history.replaceState(null, '', location.pathname + '#/onboarding');
    } catch (_) { /* the overview says so itself */ }
    route();
    connect();
    if (state.view !== 'resources') scheduleResTotal(0);   // 595: the nav's total (the page measures on its own)
    setInterval(() => {
      if (![...state.ops.values()].some((o) => o.state === 'running')) return;
      paintRowOps();
      if (state.view === 'operations') renderOperations();     // the running ones count their seconds
    }, 1000);
    setInterval(paintRowOps, 15000);
    setInterval(() => { for (const t of terminals.values()) paintCover(t); }, 30000);   // "asleep 7 min"
    // 599 (594.B4): the tabs' {time}, at each minute.
    setTimeout(() => { paintTabs(); setInterval(paintTabs, 60000); }, 60000 - (Date.now() % 60000) + 50);
  }
}

// The calls that go UP the layers (core/hooks.js): every upcall('name') a lower module makes is provided here, once,
// before anything runs.
provide({
  acknowledgeOps, banner, btn, callout, closeWizardModal, connect, dropBanner, failureFor, gridEnter, gridLeave,
  gridRefresh, hostChanged, lifecycle, modalInert, opFailed, openWizardModal, pageFailure, paintCover, paintNav,
  paintResTotal, paintRowOps, paintSplitButton, paintTabs, paintTermEmpty, paintTransition, reattachTerminals,
  refresh, refreshNav, refreshSandbox, renderActivity, renderHostFoot, renderOps, renderTerminals, renderWizard,
  showSandbox, signedOut, startApp, toast, viewAccounts, viewActivity, viewDoctor, viewImages, viewMetrics, viewNew,
  viewOnboarding, viewOperations, viewOverview, viewResources, viewSettings, wizardStopPolling,
});
// The browser probes' names. The one script's top-level names were globals, and the workspace's browser probes
// (probes/*, over CDP Runtime.evaluate) read and call some of them; module names are not globals, so these stay
// reachable by name as before (only this page's own scripts run here: script-src 'self'). One a lower layer calls
// up is reached through its hook — a probe that wraps it wraps what the page calls. The page itself never uses them.
expose({
  act, api, closeTerminal, focusTerm, gridRefresh, gridSchedule, newSandboxWizard, newShellTerminal, openTerminal,
  pageTerminals, paintTabs, refresh, renderTerminals, resetSetting, saveSetting, sendInput, showUiOverlay, splitWith,
  state, sview, terminals, termUI, uiLost, uiRetryTick, WIZ, wizGo,
});

(async () => { if (await bootstrap()) startApp(); })();

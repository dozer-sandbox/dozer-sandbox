// views/new-sandbox — The New Sandbox wizard (599f): the same model as doz init.
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { icon } from '../dom/icons-8392ebb8cb8879e3.js';
import { AGENT_NAMES, parseImageName } from '../core/agents-66154a04b9c4696c.js';
import { api } from '../core/api-1817573a49f0ab85.js';
import { plural } from '../core/format-b2e68384da8d2f36.js';
import { actOrThrow, waitOp } from '../core/operations-d824956fc29841f7.js';
import { setting } from '../core/settings-171e705abeccb983.js';
import { state } from '../core/state-6efaa5d4aa08116b.js';
import { isRemote } from '../core/session-545fa19d53ba02cc.js';
import { renderAccessStep } from '../components/access-step-8a3dfa651b81d1a1.js';
import { accountChooser } from '../components/accounts-b0f80747a1924e95.js';
import { btn } from '../components/button-8e61dd531eed2262.js';
import { callout } from '../components/callout-295f8e0570c7e239.js';
import { createDialog } from '../components/create-dialog-8c6533626d26d14a.js';
import { dialog } from '../components/dialog-d48442e03113646f.js';
import { imagePicker } from '../components/image-picker-cffe066c76f6fa60.js';
import { renderModal, wizHead, wizMount } from '../components/modal-a2bc09c77b545337.js';
import { pageFailure, toast } from '../components/notices-89b8886740537e92.js';
import { confirmWeb, isAgentModel, permissionSwitches } from '../components/permissions-2d2cf511e6aa7261.js';
import { rulesStep } from '../components/rules-step-caa581df445e9800.js';
import { stepperNode } from '../components/stepper-19d0f8aab00bfb93.js';
import { openDefaultTerminal } from '../components/terminal-154bdbfa793b8202.js';

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
export function newSandboxWizard(start = {}) {
  // 603: a draft left by the browser's Back is resumed, never silently replaced (a new start asks first).
  const go = () => { if (location.hash === '#/new') renderModal(true); else location.hash = '#/new'; };
  const draft = state.nw && !state.nw.tools && (state.nw.step > 0 || !!state.nw.form || state.nw.explicit.size > 0);
  if (draft && !start.folder) { go(); return; }
  const fresh = () => { state.nw = null; state.nwStart = start; go(); };
  if (!draft) { fresh(); return; }
  dialog('Discard the unfinished new sandbox?', 'A New sandbox wizard was left part-way; starting again forgets its choices.', [], 'Discard', async () => { fresh(); }, { danger: true, icon: 'x' });
}
export async function viewNew() {
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
    radio('existing', 'A folder you have (your project)', h('div', { class: 'nw-sub' }, h('label', { class: 'field' }, h('span', null, 'Folder'), h('div', { class: 'row' }, path, isRemote() ? null : choose)),
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

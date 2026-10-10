// views/onboarding — Onboarding (594): Welcome → Checks → Access → Workspace rules → Images → Preparing → First sandbox →
// Stay in touch (the optional sign-up — an official build only) → Done.
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { AGENT_NAMES } from '../core/agents-66154a04b9c4696c.js';
import { api } from '../core/api-0a712b05e0caf823.js';
import { bytes, full } from '../core/format-b2e68384da8d2f36.js';
import { act, actOrThrow, loadPreparations, prepRunning } from '../core/operations-c7eeae66c46d4582.js';
import { loadSettings, secretEntryAllowed, setting } from '../core/settings-b82be35de3dd1806.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { WIZ, WIZ_ORDER, WIZ_STEPS } from '../core/wizards-e3999d6ea48c0026.js';
import { ACCESS_TITLES, renderAccessStep } from '../components/access-step-77a175994279dc20.js';
import { accountChooser, accountCommandsNode, accountForm } from '../components/accounts-7a4491c3b003838e.js';
import { table } from '../components/blocks-53c969feeec8fe89.js';
import { btn } from '../components/button-72d87e1085f00b4e.js';
import { callout } from '../components/callout-48fdacc012091bbe.js';
import { imagePicker, pickerNameHint } from '../components/image-picker-2e7eb939950d54b2.js';
import { wizHead, wizMount } from '../components/modal-00d9789cbe47ee3c.js';
import { refreshNav } from '../components/nav-baacb3a712d5064d.js';
import { pageFailure, toast } from '../components/notices-f4d7053b68a08d1e.js';
import { statusPill } from '../components/pills-a0247e11708f05b5.js';
import { prepCard } from '../components/prep-card-594b7fd48d1542a0.js';
import { rulesStep } from '../components/rules-step-124b3dfb793c8146.js';
import { stepperNode } from '../components/stepper-eb70a810bda2f73e.js';
import { workspaceChooser } from '../components/workspace-chooser-e86fa5060e492601.js';
import { renderOps } from './operations-cbabf449e0c789d0.js';

let wizTimer = null;
export function wizardStopPolling() { clearInterval(wizTimer); wizTimer = null; }
function wizardPoll() {
  if (wizTimer) return;
  wizTimer = setInterval(async () => {
    if (state.modal !== 'onboarding' || !state.wiz || state.wiz.step !== WIZ.preparing) { wizardStopPolling(); return; }
    try { state.preps = await api('preparations'); } catch (_) { return; }
    renderOps();
    renderWizard();
  }, 1000);
}
export async function viewOnboarding() {
  if (!state.wiz) state.wiz = { step: 0, data: null, account: null, images: null, config: null, created: null, busy: false };
  const w = state.wiz;
  if (!w.data || w.step <= 1) w.data = await api('onboarding');
  if (w.step === WIZ.preparing) { await loadPreparations(); wizardPoll(); }
  return wizardNode();
}
/// Re-render in place (a preparation's progress; a step change). The first-sandbox form is never
/// re-rendered under the person typing in it.
export function renderWizard(force) {
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
export function wizGo(step) {
  if (step === WIZ.signup && !state.signup) step = WIZ.done;     // a build without the sign-up skips the step
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
  // Stay in touch is a step only in a build with the sign-up; the strip numbers what is shown.
  const shown = WIZ_STEPS.map((title, i) => ({ id: String(i), title, i })).filter((s) => s.i !== WIZ.signup || state.signup);
  const { list: stepper, compact } = stepperNode(shown, shown.findIndex((s) => s.i === w.step),
    { go: (k) => { const i = shown[k].i; return i < w.step && w.step < WIZ.preparing && i > 0 ? () => wizGo(i) : null; } });
  const body = [wizStep0, wizStep1, wizStep2, wizStepRules, wizStep3, wizStep4, wizStep5, wizStepSignup, wizStep6][w.step](d, w);
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
    box.replaceChildren(...[h('h3', null, 'Codex account (OpenAI)'),
      h('p', { class: 'muted' }, state.chatgptSignIn
        ? 'Codex uses your ChatGPT plan (Dozer signs in on this Mac — your Mac’s own Codex login is not touched) or an OpenAI API key. Either can be added later; a codex sandbox says what it needs.'
        : 'Codex uses this Mac’s own Codex login (sign in with codex on this Mac — Dozer only reads it) or an OpenAI API key. Either can be added later; a codex sandbox says what it needs.'),
      state.chatgptSignIn ? accountCommandsNode('chatgpt') : null,
      secretEntryAllowed() ? accountForm({ kind: 'openai-key', name: 'openai', onAdded: async (r, name) => {
        try { await actOrThrow({ action: 'account-default', account: name }); } catch (e) { w.error = e.message || String(e); }
        w.codexAdded = name;
        paint();
      } }) : accountCommandsNode('openai-key')].filter(Boolean));
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
      wizGo(WIZ.signup);
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
    wizButtons(btn('Skip', () => wizGo(WIZ.signup)), create),
  ];
}
/// Stay in touch (optional): an email and what it is for, posted to the one typed route (CSRF, strict body) — the
/// official build's package sends it; a confirmation email comes first. Nothing is pre-filled or pre-ticked; Skip
/// moves on. The address is never kept in the page after the request.
const SIGNUP_INTERESTS = [['release-news', 'Release news', 'A short email when a new version is out.'],
  ['early-access', 'Early access', 'Try new features before they are released.'],
  ['tips', 'Tips and tricks', 'Ways to get more out of Dozer, now and then.']];
function wizStepSignup(d, w) {
  if (w.signedUp) {
    return [
      h('h2', null, 'Stay in touch'),
      callout('ok', { cls: 'notice', attrs: { 'data-signed-up': '' }, body: w.signedUp === 'already-confirmed'
        ? 'That address is already signed up — nothing changed.'
        : 'Check your inbox: a confirmation email is on its way. Nothing else is sent until you confirm, and every email has a one-click unsubscribe.' }),
      wizButtons(btn('Next', () => wizGo(WIZ.done), { primary: true })),
    ];
  }
  const email = h('input', { type: 'email', name: 'wiz-email', autocomplete: 'email', spellcheck: 'false', placeholder: 'name@example.com' });
  const boxes = SIGNUP_INTERESTS.map(([value, label, desc]) => {
    const input = h('input', { type: 'checkbox', value });
    return { input, el: h('label', { class: 'wiz-choice', 'data-interest': value }, input, h('span', null, h('strong', null, label), h('div', { class: 'muted' }, desc))) };
  });
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  const send = btn('Sign up', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const interests = boxes.filter((x) => x.input.checked).map((x) => x.input.value);
    const address = email.value.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address)) { error.textContent = 'An email address, like name@example.com.'; return; }
    if (!interests.length) { error.textContent = 'Tick at least one.'; return; }
    b.disabled = true;
    try {
      const r = await api('signup', { method: 'POST', json: { email: address, interests } });
      email.value = '';
      w.signedUp = r.status;
      renderWizard(true);
    } catch (e) { error.textContent = e.message || String(e); b.disabled = false; }
  }, { primary: true });
  return [
    h('h2', null, 'Stay in touch (optional)'),
    h('p', { class: 'sub' }, 'Release news, early access and tips and tricks from the people who make Dozer — by email, only what you tick. A confirmation email comes first; every email has a one-click unsubscribe. Your address is never linked to the usage statistics.'),
    h('label', { class: 'field' }, h('span', null, 'Email'), email),
    h('fieldset', { class: 'wiz-choices' }, h('legend', null, 'What would you like?'), boxes.map((x) => x.el)),
    error,
    wizButtons(btn('Skip', () => wizGo(WIZ.done)), send),
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
      h('li', { 'data-wiz-projects': '' }, 'Workspace folders of new sandboxes: ', h('code', null, setting('defaults.projects_dir', '~/dozer-sandbox-workspaces') + '/<name>'),
        ' — Quick add and doz new use it; Settings › Choose… moves it'),
      h('li', null, 'Images: ' + (wizChosenImages().join(', ') || 'none now (each is prepared by its first start)')),
      w.created ? h('li', null, 'First sandbox: ', h('a', { href: '#/sandbox/' + w.created }, w.created)) : null),
    h('p', { class: 'muted' }, 'From a terminal: doz init in a project folder, then doz up there. This wizard is always here: Doctor › Run onboarding again.'),
    !state.signup && state.signupPage ? h('p', { class: 'muted', 'data-signup-link': '' }, 'Stay in touch (optional) — release news, early access and tips and tricks: sign up at ',
      h('a', { href: state.signupPage, target: '_blank', rel: 'noopener noreferrer' }, state.signupPage), '.') : null,
    wizButtons(w.created ? btn('Open ' + w.created, () => { location.hash = '#/sandbox/' + w.created; }, { icon: 'box' }) : null,
      btn('Open Sandboxes', () => { state.wiz = null; location.hash = '#/overview'; }, { primary: true })),
  ];
}

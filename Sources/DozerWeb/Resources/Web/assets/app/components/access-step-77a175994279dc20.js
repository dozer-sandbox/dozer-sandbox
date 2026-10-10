// components/access-step — Access (599e): one self-contained step — the onboarding, New Sandbox and Settings › Access.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { api } from '../core/api-0a712b05e0caf823.js';
import { secretEntryAllowed, secretEntryWhy } from '../core/settings-b82be35de3dd1806.js';
import { btn } from './button-72d87e1085f00b4e.js';
import { callout } from './callout-48fdacc012091bbe.js';

// ── Access (599e) ───────────────────────────────────────────────────────────
// Owner (2026-10-02): "github access on or off would be a pusposeful choice … a general 'Access' step in the
// onboarding where the credentials get confirmed (with the option to skip the confirmation if there is an
// issue so the onboarding doesnt get blocked)". ONE self-contained component, drawn by the onboarding wizard,
// the Settings page and (599f) the New Sandbox wizard:
//
//   const ctl = renderAccessStep(container, {
//     mode: 'onboarding' | 'sandbox' | 'settings',
//     state,        // optional: an object the caller keeps across its own re-renders (the component fills it)
//     claude,       // optional (onboarding): confirm the store's default Claude account too
//     choices,      // optional: the initial {github: off|read|push, githubSource: gh|key, ssh: off|on}
//                   //   (else the settings' — what new sandboxes get now)
//     onChange,     // optional: (choices) => void, after a choice changes
//   });
//   ctl.choices()   → {github, githubSource, ssh}, as chosen on the page
//   ctl.resolved()  → true when every credential is confirmed, off, or skipped
//   ctl.confirm()   → Promise<bool>: checks what is not resolved yet (POST /api/v1/access/check with the
//                     choices — no setting is written); resolves to ctl.resolved()
//   ctl.render()    → draws it again into `container`
//
// It WRITES NOTHING but the default GitHub key (its masked field, while ui.allow_secret_entry): the caller
// writes the choices (onboarding: POST onboarding/config {access}; sandbox: its create request; settings: the
// setting rows below it). A failure shows its reason with Skip (keep the choice, not confirmed), Turn it off,
// or Check again. 'settings' mode shows the last confirmation of each and "Check again", without choices.
export const ACCESS_TITLES = { claude: 'Claude account', github: 'GitHub as you', ssh: 'SSH agent forwarding' };
/**
 * @typedef {{ github?: 'off' | 'read' | 'push', githubSource?: 'gh' | 'key', ssh?: 'off' | 'on' }} AccessChoices
 * @typedef {object} AccessStepOptions
 * @property {'onboarding' | 'sandbox' | 'settings'} [mode]   default onboarding
 * @property {object} [state]       kept by the caller across its own re-renders (the component fills it)
 * @property {boolean} [claude]     (onboarding) confirm the store's default Claude account too
 * @property {AccessChoices} [choices]   the initial choices (else the settings')
 * @property {(choices: AccessChoices) => void} [onChange]
 * @typedef {object} AccessStep
 * @property {() => AccessChoices} choices
 * @property {() => boolean} resolved
 * @property {() => Promise<boolean>} confirm
 * @property {() => void} render
 */
/**
 * @param {HTMLElement} container
 * @param {AccessStepOptions} [opts]
 * @returns {AccessStep}
 */
export function renderAccessStep(container, opts = {}) {
  const mode = opts.mode || 'onboarding';
  const st = opts.state || {};
  if (!st.results) st.results = {};
  if (!st.skipped) st.skipped = new Set();
  const ctl = { state: st, choices: () => ({ ...(st.choices || {}) }), resolved, confirm, render };
  const ids = () => [...(opts.claude ? ['claude'] : []), 'github', 'ssh'];
  const isOff = (id) => (id === 'github' ? st.choices.github === 'off' : id === 'ssh' ? st.choices.ssh === 'off' : false);
  const confirmed = (id) => !!st.results[id] && st.results[id].state === 'confirmed';
  function resolved() { return !!st.choices && ids().every((id) => isOff(id) || st.skipped.has(id) || confirmed(id)); }
  function changed(id) {
    delete st.results[id];
    st.skipped.delete(id);
    if (opts.onChange) opts.onChange(ctl.choices());
    render();
  }
  async function check(which) {
    st.busy = true;
    render();
    try {
      const body = { items: which };
      if (mode !== 'settings') body.choices = st.choices;
      const r = await api('access/check', { method: 'POST', json: body });
      st.report = { ...st.report, githubKeySet: r.githubKeySet };
      for (const it of r.items) if (which.includes(it.id)) { st.results[it.id] = it; st.skipped.delete(it.id); }
    } catch (e) {
      for (const id of which) st.results[id] = { id, state: 'failed', detail: e.message || String(e) };
    } finally {
      st.busy = false;
      render();
    }
  }
  async function confirm() {
    if (!st.choices) return false;
    const todo = ids().filter((id) => !isOff(id) && !st.skipped.has(id) && !confirmed(id));
    if (todo.length) await check(todo);
    return resolved();
  }
  function radios(name, value, options, onPick) {
    return options.map(([v, label, sub]) => {
      const input = h('input', { type: 'radio', name: 'access-' + name + '-' + mode, value: v });
      input.checked = v === value;
      input.addEventListener('change', () => onPick(v));
      const a = { class: 'wiz-choice' + (v === value ? ' chosen' : '') };
      a['data-access-' + name] = v;
      return h('label', a, input, h('span', null, label, sub ? h('div', { class: 'muted' }, sub) : null));
    });
  }
  function keyNode() {
    if (st.report.githubKeySet) {
      const rm = btn('Remove key', async () => {
        try { st.error = null; st.report = await api('access/github-key', { method: 'POST', json: { remove: true } }); delete st.results.github; render(); }
        catch (e) { st.error = e.message || String(e); render(); }
      }, { small: true, icon: 'trash-2' });
      return callout('ok', { cls: 'notice', icon: 'key-round', attrs: { 'data-access-key': 'set' }, body: 'A GitHub key is set (in the login keychain as doz-github — never in a sandbox).', actions: [rm] });
    }
    if (!secretEntryAllowed()) {
      return h('div', { class: 'panel wiz-cmds', 'data-access-key': 'commands' },
        h('div', { 'data-secret-why': '1' }, 'Not here: ' + secretEntryWhy() + ' in a terminal on this Mac:'),
        h('pre', { class: 'mono' }, 'doz access set --github-key   (paste it; not echoed)'));
    }
    const secret = h('input', { type: 'password', name: 'access-github-key', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
                                'data-secret': '1', placeholder: 'paste it here' });
    const error = h('div', { class: 'dlg-error', role: 'alert' });
    const save = btn('Save key', async (ev) => {
      const b = ev.currentTarget, value = secret.value.trim();
      secret.value = '';                                   // gone from the page before the request
      error.textContent = '';
      if (value.length < 20 || /\s/.test(value)) { error.textContent = 'Paste the whole token (one word).'; return; }
      b.disabled = true;
      try { st.report = await api('access/github-key', { method: 'POST', json: { secret: value } }); delete st.results.github; render(); }
      catch (e) { error.textContent = e.message || String(e); b.disabled = false; }
    }, { primary: true, icon: 'key-round' });
    return h('div', { class: 'panel acct-form', 'data-access-key': 'form' },
      h('label', { class: 'field' }, h('span', null, 'GitHub token'), secret,
        h('small', null, 'Best: a fine-grained token limited to the repositories the agent needs (github.com → Settings → Developer settings). Not shown, not kept in this page.')),
      error, h('div', { class: 'wiz-buttons' }, save));
  }
  function statusRow(id) {
    const r = st.results[id];
    const skipped = st.skipped.has(id);
    const off = mode !== 'settings' && isOff(id);
    const s = off ? 'off' : skipped ? 'skipped' : r ? r.state : 'unchecked';
    const pill = h('span', { class: 'pill ' + ({ confirmed: 'st-ok', failed: 'st-fail', skipped: 'st-warn' }[s] || 'st-off') },
      { confirmed: 'confirmed', failed: 'not confirmed', skipped: 'skipped', off: 'off', unchecked: 'not checked' }[s] || s);
    const detail = off ? 'off — nothing to confirm' : skipped ? 'kept, not confirmed' + (r && r.detail ? ' — ' + r.detail : '') : r ? r.detail : 'not checked yet';
    const row = h('div', { class: 'access-item', 'data-access-item': id, 'data-state': s },
      h('div', { class: 'access-head' }, pill, ' ', h('strong', null, ACCESS_TITLES[id]),
        r && r.choice && mode === 'settings' ? h('code', { class: 'muted' }, ' ' + r.choice + (id === 'github' && r.choice !== 'off' ? ' (' + (r.source === 'key' ? 'a key' : 'gh login') + ')' : '')) : null),
      h('div', { class: s === 'failed' ? 'st-fail' : 'muted' }, detail));
    if (s === 'failed' && mode !== 'settings') {
      const acts = [btn('Skip', () => { st.skipped.add(id); render(); }, { small: true, icon: 'skip-forward', title: 'Keep ' + ACCESS_TITLES[id] + ' as chosen, not confirmed — doz access checks again later' })];
      if (id !== 'claude') acts.push(btn('Turn it off', () => { st.choices[id] = 'off'; changed(id); }, { small: true, icon: 'power' }));
      acts.push(btn('Check again', () => check([id]), { small: true, icon: 'refresh-cw' }));
      row.append(h('div', { class: 'wiz-buttons access-fix' }, acts));
    }
    return row;
  }
  function render() {
    if (!st.report) {
      container.replaceChildren(h('p', { class: 'muted' }, 'Reading the Access choices…'));
      if (!st.loading) {
        st.loading = true;
        api('access').then((r) => {
          st.report = r;
          const item = (id) => r.items.find((x) => x.id === id) || {};
          if (!st.choices) {
            st.choices = opts.choices ? { ...opts.choices }
              : { github: item('github').choice || 'off', githubSource: item('github').source === 'key' ? 'key' : 'gh', ssh: item('ssh').choice || 'off' };
          }
          if (mode === 'settings') for (const it of r.items) st.results[it.id] = it;
          render();
        }).catch((e) => { container.replaceChildren(callout('bad', { cls: 'notice', body: e.message || String(e) })); })
          .finally(() => { st.loading = false; });
      }
      return ctl;
    }
    const c = st.choices, cons = st.report.consequences || {};
    const parts = [];
    if (mode !== 'settings') {
      parts.push(h('fieldset', { class: 'wiz-choices', 'data-access-choice': 'github' },
        h('legend', null, 'GitHub as you — should git and gh in ' + (mode === 'sandbox' ? 'this sandbox' : 'new sandboxes') + ' be signed in to GitHub as you?'),
        radios('github', c.github, [['off', 'Off', 'not signed in as you (public repositories still work)'],
                                    ['read', 'Read-only', 'clone and read your private repositories, issues and pull requests; no push'],
                                    ['push', 'Read and push', 'also push and change things on GitHub as you']],
               (v) => { c.github = v; changed('github'); })));
      parts.push(h('p', { class: 'access-consequence', 'data-consequence': 'github' }, (cons.github || {})[c.github] || ''));
      if (c.github !== 'off') {
        parts.push(h('fieldset', { class: 'wiz-choices', 'data-access-choice': 'source' }, h('legend', null, 'Where the token comes from'),
          radios('source', c.githubSource, [['gh', 'This Mac’s gh login', 'gh auth token — read when used, never stored; gh auth logout ends it'],
                                            ['key', 'A token you give Dozer', 'kept in the login keychain; a fine-grained token can be limited to some repositories']],
                 (v) => { c.githubSource = v; changed('github'); })));
        if (c.githubSource === 'key') parts.push(keyNode());
      }
      parts.push(h('fieldset', { class: 'wiz-choices', 'data-access-choice': 'ssh' },
        h('legend', null, 'SSH agent forwarding — may ssh and git over SSH ask this Mac’s ssh-agent to sign?'),
        radios('ssh', c.ssh, [['off', 'Off', null], ['on', 'On', 'github.com only; your keys never leave the Mac']], (v) => { c.ssh = v; changed('ssh'); })));
      parts.push(h('p', { class: 'access-consequence', 'data-consequence': 'ssh' }, (cons.ssh || {})[c.ssh] || ''));
    } else if (st.report.githubKeySet || (st.results.github && st.results.github.source === 'key')) {
      parts.push(keyNode());
    }
    const confirmBtn = btn(mode === 'settings' ? 'Check again' : 'Confirm', () => (mode === 'settings' ? check(ids()) : confirm()),
      { icon: mode === 'settings' ? 'refresh-cw' : 'badge-check', title: 'Confirm each credential works now, live' });
    confirmBtn.dataset.accessConfirm = '';
    if (st.busy) confirmBtn.disabled = true;
    parts.push(h('div', { class: 'access-status', 'aria-live': 'polite', 'data-busy': st.busy ? '1' : null },
      h('h3', null, mode === 'settings' ? 'Each credential, as last confirmed' : 'Confirmed?'),
      ids().map(statusRow),
      h('div', { class: 'wiz-buttons' }, st.busy ? h('span', { class: 'muted' }, h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), ' checking…') : null, confirmBtn)));
    if (st.error) parts.push(callout('bad', { compact: true, body: st.error, dismiss: () => { st.error = null; render(); } }));
    container.replaceChildren(h('div', { class: 'access-step', 'data-access-mode': mode }, parts));
    return ctl;
  }
  render();
  return ctl;
}

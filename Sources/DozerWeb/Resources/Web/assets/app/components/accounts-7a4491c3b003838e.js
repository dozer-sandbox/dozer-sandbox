// components/accounts — Accounts (594): adding one from a key or a token, choosing one for an agent, a sandbox's own key.
import { upcall } from '../core/hooks-a4b871a481b363cd.js';
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { AGENT_NAMES, agentKey, isOpenAIAgent, KIND_LABELS } from '../core/agents-66154a04b9c4696c.js';
import { api } from '../core/api-0a712b05e0caf823.js';
import { actOrThrow } from '../core/operations-c7eeae66c46d4582.js';
import { secretEntryAllowed, secretEntryWhy } from '../core/settings-b82be35de3dd1806.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { btn } from './button-72d87e1085f00b4e.js';
import { callout } from './callout-48fdacc012091bbe.js';
import { dialog } from './dialog-eda31d5dbf8a6de4.js';
import { toast } from './notices-f4d7053b68a08d1e.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const refreshSandbox = upcall('refreshSandbox');

const ACCOUNT_COMMANDS = {
  'api-key': ['doz account add work --api-key       (it asks for the key, not echoed)', 'doz account default work'],
  // 599i: Codex — an OpenAI key, or Dozer's own ChatGPT sign-in (the browser opens on this Mac).
  'openai-key': ['doz account add openai --openai-key   (it asks for the key, not echoed)', 'doz account default openai'],
  chatgpt: ['doz account add chatgpt --chatgpt     (your browser opens: sign in with ChatGPT — Dozer’s own sign-in;',
    '                                       your Mac’s Codex login is not touched)', 'doz account default chatgpt'],
  'setup-token': ['claude setup-token                    (on this Mac: prints a 1-year token)',
    'doz account add work --setup-token   (paste it; not echoed)', 'doz account default work'],
};
export function accountCommandsNode(kind) {
  return h('div', { class: 'panel wiz-cmds' },
    h('div', { 'data-secret-why': secretEntryAllowed() ? null : '1' }, secretEntryAllowed() ? 'In a terminal on this Mac:' : 'Not here: ' + secretEntryWhy() + ' in a terminal on this Mac:'),
    h('pre', { class: 'mono' }, ACCOUNT_COMMANDS[kind].join('\n')));
}
/// opts: {kind (fixed) | null (a choice), name, onAdded(result, name)}.
export function accountForm(opts) {
  const kindSel = h('select', { name: 'acct-kind', 'aria-label': 'Kind' },
    h('option', { value: 'api-key' }, 'Anthropic API key'), h('option', { value: 'setup-token' }, 'Claude setup token'),
    h('option', { value: 'openai-key' }, 'OpenAI API key (Codex)'));
  if (opts.kind) kindSel.value = opts.kind;
  const name = h('input', { type: 'text', name: 'acct-name', autocomplete: 'off', spellcheck: 'false', placeholder: 'a-z 0-9 -' });
  name.value = opts.name || 'work';
  const plan = h('select', { name: 'acct-plan', 'aria-label': 'Plan' }, ['max', 'pro', 'team', 'enterprise'].map((p) => h('option', { value: p }, p)));
  const secret = h('input', { type: 'password', name: 'acct-secret', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
                              'data-secret': '1', placeholder: 'paste it here' });
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  const planRow = h('label', { class: 'field' }, h('span', null, 'Plan (what Claude Code shows; it picks its default model by it)'), plan);
  const secretLabel = h('span', null, '');
  const hint = h('small', null, '');
  const paint = () => {
    const token = kindSel.value === 'setup-token';
    planRow.hidden = !token;
    secretLabel.textContent = token ? 'Setup token' : 'API key';
    hint.textContent = token ? 'Run claude setup-token on this Mac and paste what it prints (it starts sk-ant-oat…; valid a year). Not shown, not kept in this page.'
      : kindSel.value === 'openai-key' ? 'An OpenAI API key (sk-…) for Codex. Not shown, not kept in this page.'
      : 'An Anthropic API key (sk-ant-api…). Not shown, not kept in this page.';
  };
  kindSel.addEventListener('change', paint);
  paint();
  const add = btn('Add account', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const value = secret.value;
    secret.value = '';                                     // gone from the page before the request
    const n = name.value.trim();
    if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(n) || n === 'default' || n === 'none') { error.textContent = 'The name: 1–40 of a-z 0-9 - (not default or none).'; return; }
    if (value.trim().length < 20) { error.textContent = 'Paste the whole ' + (kindSel.value === 'setup-token' ? 'token' : 'key') + '.'; return; }
    b.disabled = true;
    try {
      const body = { name: n, kind: kindSel.value, secret: value };
      if (kindSel.value === 'setup-token') body.plan = plan.value;
      const r = await api('accounts', { method: 'POST', json: body });
      opts.onAdded(r, n);
    } catch (e) {
      error.textContent = e.message || String(e);
    } finally {
      b.disabled = false;
    }
  }, { primary: true, icon: 'key-round' });
  return h('div', { class: 'panel acct-form' },
    opts.kind ? null : h('label', { class: 'field' }, h('span', null, 'Kind'), kindSel),
    h('label', { class: 'field' }, h('span', null, 'Account name'), name),
    planRow,
    h('label', { class: 'field' }, secretLabel, secret, hint),
    error,
    h('div', { class: 'wiz-buttons' }, add));
}
export function accountChooser({ accounts, agent, same = null, defaultValue = '', value = null, onChange = () => {} }) {
  let acc = accounts, current = agent(), chosen = value;            // 599f: `value` pre-selects (a project file's account)
  const el = h('div', { class: 'field acct-chooser', 'data-acct-chooser': '' });
  const kindsOf = (a) => (a && acc.agents ? acc.agents[agentKey(a, acc.agents)] : null);
  const fits = (kinds) => acc.accounts.filter((x) => !kinds || kinds.includes(x.kind));
  function state() {
    const kinds = kindsOf(current);
    const needs = !!kinds && !kinds.includes('mac');
    const usable = fits(kinds);
    // 599i: Codex follows the store's OpenAI default (none until one is chosen), never the Anthropic one.
    const defName = isOpenAIAgent(kinds) ? (acc.openaiDefault || 'none') : acc.defaultAccount;
    // Two rows can be named mac (Claude's and, rc.3, this Mac's Codex login): the one this agent can use.
    const def = acc.accounts.find((x) => x.name === defName && (!kinds || kinds.includes(x.kind)));
    const defFits = defName !== 'none' ? (!!def && (!kinds || kinds.includes(def.kind))) : !needs;
    return { kinds, needs, usable, defFits, defName };
  }
  function render() {
    const s = state();
    const opts = [];
    if (same) opts.push(['', same]);
    if (s.defFits) opts.push([defaultValue, 'the store default (' + s.defName + ')']);
    for (const x of s.usable) opts.push([x.name, x.name + ' (' + (KIND_LABELS[x.kind] || x.kind) + ')']);
    if (!s.needs) opts.push(['none', 'none']);
    const sel = h('select', { name: 'account', 'aria-label': 'Account' }, opts.map(([v, l]) => h('option', { value: v }, l)));
    if (chosen !== null && opts.some(([v]) => v === chosen)) sel.value = chosen;
    chosen = sel.value;
    sel.addEventListener('change', () => { chosen = sel.value; onChange(); });
    const name = AGENT_NAMES[current] || current;
    const missing = s.needs && !s.usable.length;
    el.dataset.acctOk = String(!missing);
    const parts = [h('span', null, 'Account')];
    if (!missing) parts.push(sel);
    if (s.kinds && current) {
      parts.push(h('small', { class: 'muted' }, name + ' can use: ' + s.kinds.map((k) => KIND_LABELS[k] || k).join(', ')
        + (isOpenAIAgent(s.kinds) ? ' — never a Claude account' : s.needs ? ' — never a Claude subscription' : '')));
    }
    if (missing && isOpenAIAgent(s.kinds)) {
      // 599i: Codex — Dozer's own ChatGPT sign-in runs in a terminal (the browser opens on this Mac); a key can be typed here.
      parts.push(callout('warn', { cls: 'acct-need', icon: 'key-round', attrs: { 'data-acct-need': current }, title: name + ' needs an OpenAI account',
        body: [h('small', null, (state.chatgptSignIn ? 'Sign in with ChatGPT (your plan) in a terminal, or add an OpenAI API key' : 'Sign in with Codex on this Mac (the account mac), or add an OpenAI API key')
            + ' — stored as `doz account add` stores it (the login keychain); the sandbox only ever sees a placeholder.'),
          state.chatgptSignIn ? accountCommandsNode('chatgpt') : null,
          secretEntryAllowed()
            ? accountForm({ kind: 'openai-key', name: acc.accounts.some((x) => x.name === 'openai') ? 'openai-2' : 'openai',
                onAdded: (r, n) => { acc = r; chosen = n; toast('account ' + n + ' added'); render(); onChange(); } })
            : accountCommandsNode('openai-key'),
          btn('Check again', async () => { try { acc = await api('accounts'); } catch (_) { /* keep */ } render(); onChange(); }, { small: true, icon: 'refresh-cw' })].filter(Boolean) }));
    } else if (missing) {
      parts.push(callout('warn', { cls: 'acct-need', icon: 'key-round', attrs: { 'data-acct-need': current }, title: name + ' needs an Anthropic API key',
        body: [h('small', null, 'Add one now — it is stored as `doz account add` stores it (the login keychain), and this sandbox uses it.'),
          secretEntryAllowed()
            ? accountForm({ kind: 'api-key', name: acc.accounts.some((x) => x.name === 'anthropic') ? 'anthropic-2' : 'anthropic',
                onAdded: (r, n) => { acc = r; chosen = n; toast('account ' + n + ' added'); render(); onChange(); } })
            : accountCommandsNode('api-key')] }));
    }
    el.replaceChildren(...parts);
  }
  render();
  return {
    el,
    /// The image changed: its agent's accounts.
    agentChanged() { current = agent(); chosen = null; render(); onChange(); },
    ok() { return el.dataset.acctOk === 'true'; },
    /// The account to send (undefined: the store default / the same).
    get() { return chosen ? chosen : undefined; },
  };
}

/// 594: which account a sandbox uses — only the ones its agent can use (and the key right there when
/// none fits). It applies to the sandbox's next session.
export function accountDialog(name, i, accounts) {
  const slot = h('div');
  let acct = null;
  const dlg = dialog('Account of ' + name, 'Which account the proxy uses for it — from its next session. The guest only ever sees a placeholder.',
    [{ name: 'account', type: 'custom', el: slot, get: () => {
      if (!acct.ok()) throw new Error((AGENT_NAMES[agentKey(i.agent, AGENT_NAMES)] || 'This agent') + ' needs an account it can use — add one above.');
      return acct.get() || 'default';
    } }], 'Use', async (v) => {
      await actOrThrow({ action: 'account-use', sandbox: name, account: v.account });
    });
  const submit = dlg.querySelector('button[type="submit"]');
  acct = accountChooser({ accounts, agent: () => i.agent, defaultValue: 'default', onChange: () => { submit.disabled = !acct.ok(); } });
  slot.replaceWith(acct.el);
  submit.disabled = !acct.ok();
}

/// 594: an existing sandbox whose account does not fit its agent — "pi can't use the account mac —
/// choose an API-key account" — with the accounts that fit (or the key field) right there.
export function credentialBanner(name, i, accounts) {
  return callout('bad', { compact: true, cls: 'cred-banner', icon: 'key-round', attrs: { 'data-cred-banner': name }, body: i.credentialProblem,
    actions: [btn('Choose an account…', () => accountDialog(name, i, accounts), { small: true, primary: true, icon: 'key-round' })] });
}

/// 594 (owner ruling: sandbox keys in the browser too): a sandbox's own Anthropic key — what `doz key set
/// NAME --anthropic` does — under the same setting and rules as accountForm: a masked field, emptied
/// before the request, one CSRF-checked POST /api/v1/sandboxes/NAME/key body; off: the commands.
export function keyEntry(name, proxied) {
  if (!proxied) return h('p', { class: 'muted' }, 'Not proxied: a key would have to enter the sandbox — create it with a proxied network (agent, open, …) to give it one.');
  if (!secretEntryAllowed()) {
    return h('div', { class: 'panel wiz-cmds', 'data-key-commands': name },
      h('div', { 'data-secret-why': '1' }, 'Not here: ' + secretEntryWhy() + ' in a terminal on this Mac:'),
      h('pre', { class: 'mono' }, ['doz key set ' + name + ' --anthropic                       (it asks for the key, not echoed)',
        'doz key set ' + name + ' --anthropic --keychain SERVICE      (read from a keychain item)'].join('\n')));
  }
  const secret = h('input', { type: 'password', name: 'key-secret', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
                              'data-secret': '1', placeholder: 'sk-ant-api… — paste it here' });
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  const set = btn('Set key', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const value = secret.value;
    secret.value = '';                                     // gone from the page before the request
    if (value.trim().length < 20) { error.textContent = 'Paste the whole key.'; return; }
    b.disabled = true;
    try {
      await api('sandboxes/' + name + '/key', { method: 'POST', json: { secret: value } });
      toast('anthropic key set for ' + name + ' (held by the host, in memory; never in the sandbox)');
      refreshSandbox();
    } catch (e) {
      error.textContent = e.message || String(e);
    } finally {
      b.disabled = false;
    }
  }, { primary: true, small: true, icon: 'key-round' });
  return h('div', { class: 'panel acct-form key-form', 'data-key-form': name },
    h('label', { class: 'field' }, h('span', null, 'Set an Anthropic API key for ' + name), secret,
      h('small', null, 'Held by the host in memory (as doz key set from a prompt): it lasts while the host runs, replaces this sandbox’s account, and the guest only ever sees a placeholder. Not shown, not kept in this page.')),
    error, h('div', { class: 'wiz-buttons' }, set),
    h('div', { class: 'muted' }, 'From a keychain item instead: ', h('code', null, 'doz key set ' + name + ' --anthropic --keychain SERVICE'), ' in a terminal.'));
}

// views/accounts — Accounts & keys (617.B9, the owner's chosen "Full" redesign, mock changes/617-*/accounts-redesign.html;
// owner: "the Accounts & Keys ui page is horrible and needs a redesign. Confusing and clunky").
//
// One card per provider (its tools named in the header, Add a key), each key a row: a Default radio (the host's own
// per-provider account-default; Anthropic also "No default"), the key's name and where it lives in plain words, ONE
// status (Works · Not checked · Refused · Can't read · No check for this provider — a glyph and a word), the one useful
// verb (Check, Read again, Fix), Details (fingerprint, keychain item, source…) and ⋯ (Remove…). Failing keys come first
// as callouts: what the provider or the source answered, the fix, the sandboxes it affects. The Mac login's keep-alive
// sits under its row. "By sandbox": every sandbox, the key it uses now and how it got it (the default, or chosen for it);
// Change… is the existing account-use (from its next session). Keys with the same fingerprint are flagged. Add a key:
// any provider, searchable by tool; a pasted key follows ui.allow_secret_entry and the secret rules (a masked field,
// emptied before the one POST /api/v1/accounts, never echoed); 1Password / AWS / a command / a custom key / a ChatGPT
// sign-in: the exact `doz account add` line to copy. Only what the host already exposes; every action one HostOp.
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { api } from '../core/api.js';
import { full, when } from '../core/format.js';
import { act, actOrThrow } from '../core/operations.js';
import { refresh } from '../core/router.js';
import { secretEntryAllowed, secretEntryWhy } from '../core/settings.js';
import { state } from '../core/state.js';
import { accountDialog } from '../components/accounts.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { confirmAction } from '../components/dialog.js';
import { moreMenu } from '../components/menus.js';
import { toast } from '../components/notices.js';

/// Page memory (kept across re-renders, never stored): the view and the rows whose details are open.
const UI = { lens: 'provider', open: new Set() };
const NAME = /^[a-z0-9][a-z0-9-]{0,39}$/;

// ── what the host gives, read the way the page needs it ──────────────────────────────────────────────────────────────
/// The provider a row's key belongs to: a `key` its own (custom included); OpenAI's kinds; else Anthropic's.
export function providerOf(x) {
  if (x.kind === 'key') return x.provider || 'custom';
  if (['openai-key', 'chatgpt', 'codex-mac'].includes(x.kind)) return 'openai';
  return 'anthropic';
}
const isLogin = (x) => x.kind === 'mac' || x.kind === 'codex-mac';
const failingStates = ['rejected', 'unavailable', 'missing', 'locked'];
const isFailing = (x) => failingStates.includes(x.state);
/// What its provider answered at the last check ("rejected: HTTP 400 from …" → "HTTP 400 from …").
const refusal = (x) => (x.verification || '').replace(/^rejected:\s*/, '');
/// A key added without its check, or never read: "unverified: …" or a key read on use not read yet.
const checked = (x) => /^verified/.test(x.verification || '');

/// One status per key: [tone, glyph, word, the line under it].
export function statusOf(x, a) {
  const prov = providerOf(x);
  if (isLogin(x)) {
    if (x.state === 'ok' || x.state === 'expires-soon') return ['ok', 'circle-check', 'Signed in', x.plan ? (x.kind === 'mac' ? 'Claude ' : 'ChatGPT ') + x.plan : null];
    if (x.state === 'expired') return ['warn', 'triangle-alert', 'Expired', x.kind === 'mac' ? 'claude on this Mac renews it' : 'codex on this Mac renews it'];
    return ['warn', 'triangle-alert', 'Signed out', x.kind === 'mac' ? 'sign in with claude on this Mac' : 'sign in with codex on this Mac'];
  }
  // The row says it short (the callout above says it in full): "HTTP 400", not the whole answer.
  if (x.state === 'rejected') return ['fail', 'circle-x', 'Refused', refusal(x).replace(/\s+from\s+\S+$/, '') || null];
  if (x.state === 'unavailable') return ['fail', 'circle-x', 'Can’t read', x.sourceLabel ? 'its source did not answer' : 'it could not be read'];
  if (x.state === 'missing') return ['fail', 'circle-x', 'Can’t read', 'its keychain item is gone'];
  if (x.state === 'locked') return ['fail', 'circle-x', 'Can’t read', 'the login keychain is locked'];
  if (x.state === 'expired') return ['warn', 'triangle-alert', 'Expired', x.expiresAt ? 'on ' + full(x.expiresAt) : null];
  if (x.state === 'unsupported') return ['off', 'info', 'Not used', 'this build has no ChatGPT sign-in'];
  if (prov === 'custom' || (a.uncheckedProviders || []).includes(prov)) {
    return ['off', 'info', 'No check for this provider', prov === 'custom' ? 'a custom key is used as is' : title(a, prov) + ' has no key check'];
  }
  if (checked(x)) return ['ok', 'circle-check', 'Works', x.verifiedAt ? 'checked ' + when(x.verifiedAt) : (x.sourceLabel ? 'read on use' : null)];
  return ['off', 'info', 'Not checked', x.state === 'unchecked' ? 'not read yet' : 'added without its check'];
}
function statusPill(s) { return h('span', { class: 'pill st-' + s[0], 'data-key-status': s[2] }, icon(s[1]), s[2]); }

/// Where the key lives, in plain words: [glyph, words, a code part].
export function whereOf(x) {
  if (x.kind === 'mac') return ['user-round', 'This Mac’s Claude login', null];
  if (x.kind === 'codex-mac') return ['user-round', 'This Mac’s Codex login', null];
  if (x.sourceLabel) {
    const m = /^([^:]+):\s*(.*)$/.exec(x.sourceLabel);
    const kind = m ? m[1] : x.sourceLabel, ref = m ? m[2] : '';
    return [/1password|aws/i.test(kind) ? 'shield' : 'square-terminal', kind, ref];
  }
  if (x.kind === 'setup-token') return ['key-round', 'Claude subscription token · Keychain', null];
  if (x.kind === 'chatgpt') return ['key-round', 'ChatGPT sign-in · Keychain', null];
  return ['key-round', x.hosts && x.hosts.length ? 'Keychain · only to ' + x.hosts.join(', ') : 'Keychain', null];
}
const title = (a, p) => p === 'custom' ? 'Your own services' : (a.sourceTitles || {})[p] || p;
const article = (t) => (/^[AEIOx]/.test(t) ? 'an ' : 'a ');
/// The tools a provider's key serves, by name.
function toolsOf(a, p) { return ((a.providerTools || {})[p] || []).map((id) => (a.agentTitles || {})[id] || id); }
function toolsLine(a, p) {
  const t = toolsOf(a, p);
  if (p === 'custom') return 'Keys for a service of yours, sent only to the hosts you name';
  if (!t.length) return 'No tool uses it yet';
  return 'For ' + t.slice(0, 5).join(', ') + (t.length > 5 ? ' and ' + (t.length - 5) + ' more' : '');
}
/// Another key with the same fingerprint (the same key stored twice).
function twinOf(x, rows) { return x.fingerprint ? rows.find((y) => y !== x && y.fingerprint === x.fingerprint) : null; }

// ── the page ─────────────────────────────────────────────────────────────────────────────────────────────────────────
export async function viewAccounts() {
  const [a, ov] = await Promise.all([api('accounts'), api('overview').catch(() => state.overview || { sandboxes: [] })]);
  const rows = a.accounts || [];
  // A key, or a login that is signed in; a signed-out Mac login alone is not "a key yet".
  const keys = rows.filter((x) => !isLogin(x) || x.state === 'ok' || x.state === 'expires-soon' || x.state === 'expired');
  const sandboxes = (ov.sandboxes || []).filter((s) => s.agent);
  const head = h('div', { class: 'ak-head' },
    h('div', null, h('h1', null, 'Accounts & keys'),
      h('p', { class: 'sub' }, 'The keys and sign-ins your sandboxes’ tools use. Each stays on this Mac: a sandbox only ever sees a placeholder, and this page never shows a key.')),
    keys.length ? h('div', null, btn('Add a key', () => openAddKey(a, null), { primary: true, icon: 'plus' })) : null);
  const foot = h('p', { class: 'ak-foot' }, 'Pasting a key here can be turned off in Settings (ui.allow_secret_entry); the terminal does the same: ',
    h('code', null, 'doz account add'), '.');
  if (!keys.length) return h('div', { class: 'ak-page', 'data-accounts': 'empty' }, head, emptyPage(a), foot);
  const lens = h('span', { class: 'segmented', role: 'group', 'aria-label': 'View' },
    ...[['provider', 'By provider', 'list'], ['sandbox', 'By sandbox', 'table']].map(([v, l, ic]) =>
      h('button', { type: 'button', class: 'seg' + (UI.lens === v ? ' active' : ''), 'aria-pressed': String(UI.lens === v), 'data-ak-lens': v,
        on: { click: () => { UI.lens = v; refresh(false); } } }, icon(ic), l)));
  const tools = h('div', { class: 'ak-tools' }, lens,
    h('span', { class: 'muted' }, keys.length + (keys.length === 1 ? ' key' : ' keys') + ' · ' + sandboxes.length + (sandboxes.length === 1 ? ' sandbox' : ' sandboxes')));
  return h('div', { class: 'ak-page', 'data-accounts': UI.lens }, head, tools, attention(a, rows),
    ...(UI.lens === 'provider' ? byProvider(a, rows) : bySandbox(a, rows, sandboxes, ov)), foot);
}

/// The failing keys, first: what the provider or source answered, the fix, the sandboxes it affects.
function attention(a, rows) {
  const f = rows.filter((x) => !isLogin(x) && isFailing(x));
  if (!f.length) return null;
  return h('div', { class: 'ak-attn' }, ...f.map((x) => {
    const p = providerOf(x), t = title(a, p);
    const used = x.usedBy || [];
    const affects = used.length ? h('p', null, 'Used by ' + used.join(', ') + ' — their next session gets no ' + t + ' key.') : h('p', { class: 'muted' }, 'No sandbox uses it now.');
    if (x.state === 'rejected') {
      return callout('bad', { attrs: { 'data-ak-failing': x.name }, title: 'Refused: ' + x.name + ' (' + t + ')',
        body: [h('p', null, t + ' refused it (' + refusal(x) + '): the key is wrong, revoked or out of credit. Add a new key, then remove this one.'), affects],
        actions: [btn('Add a new key…', () => openAddKey(a, p), { small: true, icon: 'key-round' }),
          btn('Check again', () => act({ action: 'account-verify', account: x.name }), { small: true, quiet: true, icon: 'badge-check' })] });
    }
    const why = x.state === 'missing' ? 'its keychain item is gone' : x.state === 'locked' ? 'the login keychain is locked' : (x.sourceProblem || 'it did not answer');
    const fix = x.state === 'locked' ? 'Unlock the login keychain (Keychain Access), then Read again.'
      : x.state === 'missing' ? 'Add the key again (the same name replaces it: doz account add ' + x.name + ' --force), or remove it.'
      : 'Fix it where the key lives (run the same in Terminal to see), then Read again.';
    // The host's sourceProblem is the whole story — what the source said and the fix — so it is said as it is.
    const body = x.sourceProblem ? [h('p', null, x.sourceProblem)]
      : x.sourceLabel ? [h('p', null, 'Dozer reads it from ', h('code', null, x.sourceLabel), ', which did not answer.'), h('p', null, fix)]
      : [h('p', null, 'Dozer cannot read it: ', why, '.'), h('p', null, fix)];
    return callout('bad', { attrs: { 'data-ak-failing': x.name }, title: 'Can’t read: ' + x.name + ' (' + t + ')',
      body: [...body.filter(Boolean), affects],
      actions: [x.sourceLabel ? btn('Read again', () => act({ action: 'account-refresh', account: x.name }), { small: true, icon: 'refresh-cw' })
        : btn('Add a new key…', () => openAddKey(a, p), { small: true, icon: 'key-round' })] });
  }));
}

function byProvider(a, rows) {
  const order = [...(a.providers || []), 'custom'];
  const have = order.filter((p) => rows.some((x) => providerOf(x) === p && !(x.kind === 'codex-mac' && x.state !== 'ok')));
  const cards = have.map((p) => providerCard(a, rows, p));
  const without = order.filter((p) => !have.includes(p));
  if (without.length) {
    cards.push(h('div', { class: 'ak-more' }, h('span', null, 'No key yet:'),
      ...without.map((p) => btn(p === 'custom' ? 'Your own service' : title(a, p), () => openAddKey(a, p), { small: true, quiet: true, icon: 'plus' }))));
  }
  return cards;
}

function providerCard(a, rows, p) {
  const keys = rows.filter((x) => providerOf(x) === p);
  const custom = p === 'custom';
  const t = title(a, p);
  const gateway = p === 'openrouter' || p === 'vercel-ai-gateway';
  const card = h('section', { class: 'ak-prov', 'data-provider': p },
    h('div', { class: 'ak-prov-h' },
      h('div', { class: 'ak-av', 'aria-hidden': 'true' }, custom ? '+' : t.charAt(0)),
      h('h3', null, t, gateway ? h('span', { class: 'tag outline' }, 'gateway') : null),
      h('div', { class: 'muted' }, toolsLine(a, p)),
      h('div', { class: 'ak-add' }, btn(custom ? 'Add a custom key…' : 'Add a key', () => openAddKey(a, p), { small: true, icon: 'plus' }))));
  const list = h('div', { class: 'ak-rows' },
    h('div', { class: 'ak-row ak-colhead', 'aria-hidden': 'true' }, h('span', null, custom ? '' : 'Default'), h('span', null, 'Key'),
      h('span', { class: 'h-state' }, 'Status'), h('span', { class: 'h-used' }, 'Used by'), h('span')));
  for (const x of keys) {
    list.append(keyRow(a, rows, x, p));
    // The keep-alive belongs to the Mac login (Claude Code renews it).
    if (x.kind === 'mac' && (a.keepalive || ['ok', 'expires-soon', 'expired'].includes(x.state))) list.append(keepAlive(a));
  }
  card.append(list);
  const hasDefault = keys.some((x) => x.isDefault && !isLogin(x)) || keys.some((x) => x.kind === 'mac' && x.isDefault);
  if (p === 'anthropic') {
    const none = h('input', { type: 'radio', name: 'ak-def-' + p, 'aria-label': 'No default for Anthropic', 'data-ak-default': 'none' });
    none.checked = !hasDefault;
    none.addEventListener('change', () => { if (none.checked) act({ action: 'account-default', account: 'none' }); });
    card.append(h('div', { class: 'ak-none-row' }, h('label', { class: 'ak-def' }, none, 'No default'),
      h('span', null, '— Claude Code and pi sandboxes that follow the default get no Anthropic key')));
  } else if (!custom && !keys.some((x) => x.isDefault)) {
    card.append(h('div', { class: 'ak-none-row' }, icon('info'),
      h('span', null, p === 'openai' ? 'No default yet — Codex sandboxes that follow the default get no key until you choose one above.' : 'No default yet — choose one above.')));
  }
  return card;
}

function keyRow(a, rows, x, p) {
  const s = statusOf(x, a);
  const [glyph, words, ref] = whereOf(x);
  const twin = twinOf(x, rows);
  const open = UI.open.has(x.name + '|' + x.kind);
  const custom = p === 'custom';
  let def = h('span');
  if (!custom && x.kind !== 'codex-mac') {
    const r = h('input', { type: 'radio', name: 'ak-def-' + p, 'aria-label': 'Default for ' + title(a, p) + ': ' + x.name, 'data-ak-default': x.name });
    r.checked = !!x.isDefault;
    r.addEventListener('change', () => { if (r.checked) act({ action: 'account-default', account: x.name }); });
    def = h('label', { class: 'ak-def', title: 'Sandboxes that follow ' + title(a, p) + '’s default use it' }, r, x.isDefault ? 'Default' : '');
  } else if (x.kind === 'codex-mac') {
    def = h('span', { class: 'ak-def' }, x.isDefault ? 'Default' : '');
  }
  const verb = nextVerb(a, x, p);
  const items = [
    !isLogin(x) && !isFailing(x) && !(p === 'custom' || (a.uncheckedProviders || []).includes(p)) && (x.sourceLabel || checked(x))
      ? { label: 'Check again', icon: 'badge-check', desc: 'One tiny request to ' + title(a, p) + ' with it', onSelect: () => act({ action: 'account-verify', account: x.name }) } : null,
    isLogin(x) ? null : { label: 'Remove…', icon: 'trash-2', danger: true,
      desc: x.sourceLabel ? 'Only Dozer’s record — where you keep the key is not touched' : 'Its keychain item is deleted',
      onSelect: () => confirmAction('Remove account ' + x.name,
        (x.sourceLabel ? 'Only Dozer’s record goes' : 'Its keychain item is deleted') + ((x.usedBy || []).length ? '; sandboxes that use it (' + x.usedBy.join(', ') + ') must move to another key first' : '') + '.',
        x.name, { action: 'account-rm', account: x.name }) },
  ].filter(Boolean);
  const row = h('div', { class: 'ak-row', 'data-ak-key': x.name, 'data-ak-kind': x.kind },
    def,
    h('div', { class: 'ak-keycell' },
      h('div', { class: 'ak-name' }, x.name, twin ? h('span', { class: 'tag warn', 'data-ak-twin': twin.name, title: 'The same fingerprint: one key stored twice' }, 'same key as ' + twin.name) : null),
      h('div', { class: 'ak-where' }, icon(glyph), h('span', null, words), ref ? h('code', { title: ref }, ref) : null)),
    h('div', { class: 'ak-state' }, statusPill(s), s[3] ? h('span', { class: 'muted' }, s[3]) : null),
    h('div', { class: 'ak-used' }, (x.usedBy || []).length ? x.usedBy.map((n) => h('span', { class: 'ak-chip' }, n))
      : h('span', null, 'no sandbox')),
    h('div', { class: 'ak-acts' }, verb,
      btn(open ? 'Hide details' : 'Details', () => { open ? UI.open.delete(x.name + '|' + x.kind) : UI.open.add(x.name + '|' + x.kind); refresh(false); },
        { small: true, quiet: true, iconOnly: true, icon: 'chevron-down', title: (open ? 'Hide' : 'Show') + ' the details: fingerprint, keychain item, source, expiry' }),
      items.length ? moreMenu('More for ' + x.name, items, { small: true }).el : null));
  if (open) {
    const d = h('dl', { class: 'ak-details', 'data-ak-details': x.name });
    const add = (k, v) => { if (v) d.append(h('dt', null, k), h('dd', null, v)); };
    add('Fingerprint', x.fingerprint ? x.fingerprint + ' (a sha256 prefix — never the key)' : null);
    add('Keychain item', x.keychainService);
    add('Source', x.sourceLabel);
    add('Identity', x.identity);
    add('Expires', x.expiresAt ? full(x.expiresAt) + ' (' + when(x.expiresAt) + ')' : null);
    add('Only to', x.hosts && x.hosts.length ? x.hosts.join(', ') : null);
    add('Last check', x.verification);
    add('Kind', x.kind);
    add('Remove', isLogin(x) ? 'not removable — it is this Mac’s own login' : x.sourceLabel ? 'only Dozer’s record — the source is not touched' : 'deletes its keychain item');
    row.append(d);
  }
  return row;
}

/// The one verb that helps now: Fix (refused), Read again (a key read on use, or one it cannot read), Check (never checked).
function nextVerb(a, x, p) {
  if (isLogin(x)) return null;
  if (x.state === 'rejected') return btn('Fix', () => openAddKey(a, p), { small: true, icon: 'key-round', title: 'Add a new key for ' + title(a, p) + ' (this one stays until you remove it)' });
  if (x.sourceLabel) return btn('Read again', () => act({ action: 'account-refresh', account: x.name }), { small: true, quiet: x.state !== 'unavailable', icon: 'refresh-cw', title: 'Read the key from where you keep it again now' });
  if (x.state === 'missing' || x.state === 'locked') return null;
  const s = statusOf(x, a);
  if (s[2] === 'Not checked') return btn('Check', () => act({ action: 'account-verify', account: x.name }), { small: true, quiet: true, icon: 'badge-check', title: 'One tiny request to ' + title(a, p) + ' with it' });
  return null;
}

function keepAlive(a) {
  const sw = h('input', { type: 'checkbox', role: 'switch', 'aria-label': 'Keep the Mac login fresh while a sandbox uses it', 'data-ak-keepalive': '' });
  sw.checked = !!a.keepalive;
  sw.addEventListener('change', () => act({ action: 'account-keepalive', enabled: sw.checked }));
  return h('div', { class: 'ak-keep' }, sw, h('div', null, h('b', null, 'Keep this login fresh while a sandbox uses it'),
    h('div', null, 'Shortly before it expires, Dozer runs Claude Code on this Mac once, so the login renews. Off: it renews when you next use claude here.')));
}

/// Every sandbox, the key its tool uses now and how it got it; Change… is account-use (from its next session).
function bySandbox(a, rows, sandboxes, ov) {
  if (!sandboxes.length) return [h('p', { class: 'muted ak-tablewrap' }, 'No sandbox runs an agent yet.')];
  const trs = sandboxes.map((s) => {
    const k = rows.find((x) => (x.usedBy || []).includes(s.name));
    const st = k ? statusOf(k, a) : null;
    const p = k ? providerOf(k) : null;
    const chosen = !!s.account && s.account !== 'default';
    // accountApplies asks about Anthropic's hosts only: a key the host resolved for it is the answer for any provider.
    const how = !k && !s.accountApplies ? 'its network reaches no model provider'
      : chosen ? 'chosen for this sandbox' : k ? 'follows the ' + title(a, p) + ' default' : 'follows the default — there is none';
    return h('tr', { 'data-ak-sandbox': s.name },
      h('td', null, h('b', null, s.name)),
      h('td', null, (a.agentTitles || {})[s.agent] || s.agent),
      h('td', null, k ? [k.name, ' ', h('span', { class: 'muted' }, '(' + title(a, p) + ')')] : h('span', { class: 'st-warn' }, s.account === 'none' ? 'none (chosen)' : 'none')),
      h('td', null, how),
      h('td', null, st ? statusPill(st) : statusPill(['warn', 'triangle-alert', 'No key', null])),
      h('td', { class: 'ak-tdacts' }, btn('Change…', () => accountDialog(s.name, { agent: s.agent }, a), { small: true, quiet: !!k && !(st && st[0] === 'fail'), icon: 'key-round',
        title: 'Which key ' + s.name + ' uses — from its next session' })));
  });
  return [h('p', { class: 'muted ak-lead' }, 'The key each sandbox’s tool uses now. A change applies from its next session; the sandbox only ever sees a placeholder.'),
    h('div', { class: 'ak-tablewrap' }, h('table', { class: 'ak-table' },
      h('thead', null, h('tr', null, ...['Sandbox', 'Tool', 'Key', 'How', 'Status', ''].map((t) => h('th', null, t)))), h('tbody', null, ...trs)))];
}

function emptyPage(a) {
  return h('div', { class: 'ak-empty', 'data-ak-empty': '' },
    h('h2', null, 'No keys yet'),
    h('p', { class: 'muted' }, 'A sandbox’s tool needs a key or a sign-in to reach its model. Dozer keeps it on this Mac and gives the sandbox only a placeholder.'),
    h('div', { class: 'ak-cards' },
      h('div', { class: 'ak-card' }, h('b', null, icon('user-round'), 'Use this Mac’s Claude login'),
        h('span', { class: 'muted' }, 'For Claude Code. Sign in with claude on this Mac and it shows up here by itself.'), h('code', null, 'claude   (then /login)')),
      h('div', { class: 'ak-card' }, h('b', null, icon('key-round'), 'Paste an API key'),
        h('span', { class: 'muted' }, (a.providers || []).map((p) => title(a, p)).join(', ') + '.'),
        h('div', null, btn('Add a key', () => openAddKey(a, null), { primary: true, icon: 'plus' }))),
      h('div', { class: 'ak-card' }, h('b', null, icon('shield'), 'Keep it in 1Password or AWS'),
        h('span', { class: 'muted' }, 'Dozer reads it when a sandbox needs it and keeps it in memory only.'),
        h('div', null, btn('Show me how', () => openAddKey(a, null, '1password'), { small: true, icon: 'info' })))),
    h('p', { class: 'muted ak-empty-foot' }, 'Setting up a particular tool? Quick try asks for exactly the key it needs.'));
}

// ── Add a key: provider → the key → the check ────────────────────────────────────────────────────────────────────────
let FLOW = null;

/// pid: a provider (null: choose one); source: where the key comes from first (paste by default).
export function openAddKey(a, pid, source) {
  if (FLOW && FLOW.d && FLOW.d.open) FLOW.d.close();
  const d = h('dialog', { class: 'dlg ak-flow', 'aria-labelledby': 'ak-flow-title', 'data-ak-flow': '' });
  d.addEventListener('close', () => { d.remove(); if (FLOW && FLOW.d === d) FLOW = null; });
  document.body.append(d);
  FLOW = { d, a, step: pid ? 2 : 1, provider: pid, source: source || (pid === 'custom' ? 'custom' : 'paste'), kind: 'api-key', plan: 'max', q: '', name: '',
    ref: '', host: 'api.example.com', envVar: 'EXAMPLE_API_KEY', header: 'bearer', makeDefault: null, result: null, busy: false };
  d.showModal();
  paintFlow();
}

function suggestName(a, p) {
  const base = p === 'vercel-ai-gateway' ? 'vercel' : p === 'google-stitch' ? 'stitch' : p === 'custom' ? 'example' : p;
  const taken = new Set((a.accounts || []).map((x) => x.name));
  let n = base, i = 2;
  while (taken.has(n)) n = base + '-' + i++;
  return n;
}
function seg(items, current, on, label) {
  return h('span', { class: 'segmented', role: 'group', 'aria-label': label },
    ...items.map(([v, l]) => h('button', { type: 'button', class: 'seg' + (v === current ? ' active' : ''), 'aria-pressed': String(v === current), 'data-ak-seg': v,
      on: { click: () => on(v) } }, l)));
}
function copyBtn(text) {
  return btn('Copy', async (ev) => {
    const b = ev.currentTarget;
    try { await navigator.clipboard.writeText(text); toast('Copied'); } catch (_) { b.title = 'Select the line and copy it'; }
  }, { small: true, icon: 'copy' });
}
/// The `doz account add` flag for a provider's key.
function provFlag(p) { return p === 'anthropic' ? ' --api-key' : p === 'openai' ? ' --openai-key' : ' --provider ' + p; }
const shq = (s) => (/^[A-Za-z0-9_./:@#=+-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'");

function paintFlow() {
  const f = FLOW;
  if (!f) return;
  const a = f.a, d = f.d, p = f.provider;
  const steps = h('div', { class: 'ak-steps' }, ...['Provider', 'The key', 'Check'].map((t, i) =>
    h('span', { class: i + 1 === f.step ? 'on' : i + 1 < f.step ? 'done' : '' }, (i + 1 < f.step ? '✓ ' : (i + 1) + ' ') + t)));
  const close = btn('Close', () => d.close(), { small: true, quiet: true, iconOnly: true, icon: 'x' });
  const body = h('div', { class: 'dlg-body ak-flow-body' });
  const foot = h('div', { class: 'dlg-foot dlg-buttons' });
  const head = h('div', { class: 'dlg-head ak-flow-head' },
    h('h2', { class: 'h-title', id: 'ak-flow-title' }, p && f.step > 1 ? (p === 'custom' ? 'Add a custom key' : 'Add ' + article(title(a, p)) + title(a, p) + ' key') : 'Add a key'), close);
  if (f.step === 1) {
    const order = [...(a.providers || []), 'custom'];
    const q = h('input', { type: 'search', class: 'ak-in', placeholder: 'A tool or a provider — grok, codex, gemini, openrouter…', 'aria-label': 'Find a tool or a provider', 'data-ak-search': '' });
    q.value = f.q;
    const grid = h('div', { class: 'ak-pgrid' });
    const paintGrid = () => {
      const ql = f.q.trim().toLowerCase();
      grid.replaceChildren(...order.map((pp) => {
        const tools = toolsOf(a, pp);
        const hit = ql ? tools.find((t) => t.toLowerCase().includes(ql)) : null;
        const match = !ql || title(a, pp).toLowerCase().includes(ql) || pp.includes(ql) || !!hit;
        const have = (a.accounts || []).filter((x) => providerOf(x) === pp && !isLogin(x)).length;
        const sub = pp === 'custom' ? 'any host you name (a command)' : hit ? hit + ' uses it'
          : (have ? have + (have === 1 ? ' key' : ' keys') + ' · ' : '') + (tools.length ? 'for ' + tools.slice(0, 2).join(', ') + (tools.length > 2 ? '…' : '') : 'no tool yet');
        return h('button', { type: 'button', class: 'ak-pick' + (match ? '' : ' dim'), 'data-ak-pick': pp,
          on: { click: () => { f.provider = pp; f.step = 2; f.name = ''; f.source = pp === 'custom' ? 'custom' : f.source === 'custom' ? 'paste' : f.source; paintFlow(); } } },
          h('span', { class: 'ak-av', 'aria-hidden': 'true' }, pp === 'custom' ? '+' : title(a, pp).charAt(0)), h('b', null, pp === 'custom' ? 'Your own service' : title(a, pp)), h('small', null, sub));
      }));
    };
    q.addEventListener('input', () => { f.q = q.value; paintGrid(); });
    paintGrid();
    body.append(h('label', { class: 'field' }, h('span', null, 'Which provider or gateway?'), q,
      h('small', null, 'Type a tool to see the providers it can use. A gateway (OpenRouter, Vercel) reaches many models with one key.')), grid);
    foot.append(h('span', { class: 'spacer' }), btn('Cancel', () => d.close(), { icon: 'x' }));
    d.replaceChildren(head, h('div', { class: 'ak-flow-steps' }, steps), body, foot);
    q.focus();
    return;
  }
  if (f.step === 2) {
    if (!f.name) f.name = suggestName(a, p);
    const custom = p === 'custom';
    const choices = custom ? [['custom', 'Your own service']] : [['paste', 'Paste it'], ['1password', '1Password'], ['aws', 'AWS Secrets Manager'], ['command', 'A command']];
    if (p === 'openai' && state.chatgptSignIn) choices.splice(1, 0, ['chatgpt', 'ChatGPT sign-in']);
    if (!choices.some(([v]) => v === f.source)) f.source = choices[0][0];
    const name = h('input', { class: 'ak-in', autocomplete: 'off', spellcheck: 'false', 'aria-label': 'Name', 'data-ak-name': '' });
    name.value = f.name;
    name.addEventListener('input', () => { f.name = name.value.trim(); paintCmd(); });
    body.append(h('div', { class: 'ak-two' },
      h('div', { class: 'field' }, h('span', null, 'Provider'), h('div', null, h('b', null, custom ? 'Your own service' : title(a, p)), ' ',
        btn('Change', () => { f.step = 1; paintFlow(); }, { small: true, quiet: true, icon: 'arrow-left' }))),
      h('label', { class: 'field' }, h('span', null, 'Name'), name, h('small', null, 'How it is called here and in doz commands: a-z 0-9 -.'))));
    if (!custom) body.append(h('div', { class: 'field' }, h('span', null, 'Where the key comes from'), seg(choices, f.source, (v) => { f.source = v; paintFlow(); }, 'Where the key comes from')));
    let cmdLine = null;
    const cmdBox = h('div', { class: 'ak-cmdbox' });
    const paintCmd = () => {
      if (!cmdLine) return;
      const line = cmdLine();
      cmdBox.replaceChildren(h('pre', { class: 'ak-cmd', 'data-ak-cmd': '' }, line), h('div', null, copyBtn(line)));
    };
    const pastes = f.source === 'paste' && secretEntryAllowed();
    let secret = null, plan = null;
    if (f.source === 'paste') {
      if (p === 'anthropic') {
        body.append(h('div', { class: 'field' }, h('span', null, 'Kind'),
          seg([['api-key', 'API key'], ['setup-token', 'Claude subscription (setup token)']], f.kind, (v) => { f.kind = v; paintFlow(); }, 'Kind'),
          h('small', null, f.kind === 'api-key' ? 'Billed to your Anthropic Console account. It starts sk-ant-api.' : 'Your Claude plan: run claude setup-token on this Mac and paste what it prints (valid a year).')));
        if (f.kind === 'setup-token') {
          plan = h('select', { class: 'ak-in', 'aria-label': 'Plan' }, ...['max', 'pro', 'team', 'enterprise'].map((x) => h('option', { value: x }, x)));
          plan.value = f.plan;
          plan.addEventListener('change', () => { f.plan = plan.value; });
          body.append(h('label', { class: 'field' }, h('span', null, 'Plan'), plan, h('small', null, 'Claude Code shows it and picks its default model by it.')));
        }
      }
      if (pastes) {
        secret = h('input', { class: 'ak-in', type: 'password', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', 'data-secret': '1', placeholder: 'paste it here',
          'aria-label': p === 'anthropic' && f.kind === 'setup-token' ? 'Setup token' : 'API key' });
        body.append(h('label', { class: 'field' }, h('span', null, p === 'anthropic' && f.kind === 'setup-token' ? 'Setup token' : 'API key'), secret,
          h('small', null, 'Not shown, not kept in this page. ' + ((a.uncheckedProviders || []).includes(p) ? title(a, p) + ' has no key check, so it is saved as it is' : 'Checked with one tiny request to ' + title(a, p)) + ', then kept in your login keychain.')));
      } else {
        cmdLine = () => 'doz account add ' + (f.name || 'NAME') + (p === 'anthropic' && f.kind === 'setup-token' ? ' --setup-token --plan ' + f.plan : provFlag(p));
        body.append(callout('info', { attrs: { 'data-secret-why': '1' }, title: 'Pasting a key here is turned off',
          body: [h('p', null, secretEntryWhy() + ' — in Terminal on this Mac (it asks for the key and does not echo it):'), cmdBox] }));
      }
    } else if (f.source === 'chatgpt') {
      cmdLine = () => 'doz account add ' + (f.name || 'NAME') + ' --chatgpt';
      body.append(h('p', { class: 'muted' }, 'Codex on your ChatGPT plan. Your browser opens on OpenAI’s sign-in — Dozer’s own sign-in; your Mac’s Codex login is not touched. It runs from Terminal:'), cmdBox);
    } else if (f.source === 'custom') {
      const host = h('input', { class: 'ak-in', spellcheck: 'false', 'aria-label': 'Host it may go to' }); host.value = f.host;
      const env = h('input', { class: 'ak-in', spellcheck: 'false', 'aria-label': 'Variable in the sandbox' }); env.value = f.envVar;
      const hdr = h('select', { class: 'ak-in', 'aria-label': 'Sent as' }, h('option', { value: 'bearer' }, 'Authorization: Bearer KEY'), h('option', { value: 'x-api-key' }, 'x-api-key: KEY'));
      hdr.value = f.header;
      host.addEventListener('input', () => { f.host = host.value.trim(); paintCmd(); });
      env.addEventListener('input', () => { f.envVar = env.value.trim(); paintCmd(); });
      hdr.addEventListener('change', () => { f.header = hdr.value; paintCmd(); });
      cmdLine = () => 'doz account add ' + (f.name || 'NAME') + ' --custom --host ' + shq(f.host || 'HOST') + ' --env-var ' + shq(f.envVar || 'VAR')
        + (f.header === 'bearer' ? ' --bearer' : ' --header x-api-key');
      body.append(h('div', { class: 'ak-two' }, h('label', { class: 'field' }, h('span', null, 'Host it may go to'), host), h('label', { class: 'field' }, h('span', null, 'Variable in the sandbox'), env)),
        h('label', { class: 'field' }, h('span', null, 'Sent as'), hdr),
        h('p', { class: 'muted' }, 'A custom key names the hosts it may go to, so it is added in Terminal (it asks for the key):'), cmdBox);
    } else {
      const ex = f.source === '1password' ? 'op://VAULT/ITEM/FIELD' : f.source === 'aws' ? 'aws:arn:aws:secretsmanager:REGION:ACCOUNT:secret:NAME' : '/usr/local/bin/my-token';
      const ref = h('input', { class: 'ak-in', spellcheck: 'false', placeholder: ex, 'aria-label': f.source === '1password' ? '1Password reference' : f.source === 'aws' ? 'Secret ARN' : 'The program and its arguments', 'data-ak-ref': '' });
      ref.value = f.ref;
      ref.addEventListener('input', () => { f.ref = ref.value.trim(); paintCmd(); });
      cmdLine = () => 'doz account add ' + (f.name || 'NAME') + provFlag(p) + (f.source === 'command' ? ' --from-command ' + shq(f.ref || ex) : ' --from ' + shq(f.ref || ex));
      body.append(h('label', { class: 'field' }, h('span', null, f.source === '1password' ? '1Password reference' : f.source === 'aws' ? 'Secret ARN (optionally #jsonKey)' : 'The program and its arguments (never a shell)'), ref,
        h('small', null, f.source === '1password' ? 'In 1Password: the field’s … menu › Copy Secret Reference.' : f.source === 'aws' ? 'The AWS CLI on this Mac reads it, with your AWS_PROFILE.' : 'Its output is the key.')),
        h('p', { class: 'muted' }, 'Dozer reads the key on this Mac each time a sandbox needs it (kept in memory, never stored). Because that runs '
          + (f.source === '1password' ? 'op' : f.source === 'aws' ? 'aws' : 'a program') + ' as you, it is added in Terminal; this page then shows it and can read it again:'), cmdBox);
    }
    paintCmd();
    const err = h('div', { class: 'dlg-error', role: 'alert', 'data-ak-error': '' }, f.error || '');
    let mk = null;
    if (!custom && pastes) {
      const cur = (a.accounts || []).find((x) => providerOf(x) === p && x.isDefault);
      mk = h('input', { type: 'checkbox', 'data-ak-make-default': '' });
      mk.checked = f.makeDefault ?? !cur;
      mk.addEventListener('change', () => { f.makeDefault = mk.checked; });
      body.append(h('label', { class: 'field check' }, mk, h('span', null, 'Make it ' + title(a, p) + '’s default' + (cur ? ' (now: ' + cur.name + ')' : ' — there is none yet'))));
    }
    body.append(err);
    foot.append(btn('Back', () => { f.step = 1; f.error = ''; paintFlow(); }, { quiet: true, icon: 'arrow-left' }), h('span', { class: 'spacer' }),
      btn(pastes ? 'Cancel' : 'Done', () => d.close(), { icon: pastes ? 'x' : 'check' }));
    if (pastes) {
      const go = btn('Add and check', async () => {
        const value = secret.value;
        secret.value = '';                                        // gone from the page before the request
        const n = (f.name || '').trim();
        if (!NAME.test(n) || n === 'default' || n === 'none') { f.error = 'The name: 1–40 of a-z 0-9 - (not default or none).'; err.textContent = f.error; return; }
        if (value.trim().length < 20) { f.error = 'Paste the whole ' + (f.kind === 'setup-token' && p === 'anthropic' ? 'token' : 'key') + '.'; err.textContent = f.error; return; }
        const kind = p === 'anthropic' ? f.kind : p === 'openai' ? 'openai-key' : 'key';
        const body2 = { name: n, kind, secret: value };
        if (kind === 'setup-token') body2.plan = f.plan;
        if (kind === 'key') body2.provider = p;
        f.step = 3; f.result = { checking: true, name: n }; f.error = ''; paintFlow();
        try {
          const r = await api('accounts', { method: 'POST', json: body2 });
          const row = (r.accounts || []).find((x) => x.name === n);
          if (mk && mk.checked && row && !row.isDefault) { try { await actOrThrow({ action: 'account-default', account: n }); } catch (_) { /* said on the page */ } }
          f.a = { ...a, ...r };
          f.result = { name: n, row };
        } catch (e) {
          f.result = { name: n, error: e.message || String(e) };
        }
        if (FLOW === f) paintFlow();
        refresh(false);
      }, { primary: true, icon: 'key-round' });
      go.dataset.akAdd = '';
      foot.append(go);
    }
    d.replaceChildren(head, h('div', { class: 'ak-flow-steps' }, steps), body, foot);
    (secret || name).focus();
    return;
  }
  // 3. the check's outcome, where you are
  const r = f.result || {};
  let res;
  if (r.checking) res = [h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), h('div', null, h('b', null, 'Checking with ' + title(a, p) + '…'), h('div', { class: 'muted' }, 'One tiny request, then it is kept in your login keychain.'))];
  else if (r.error) res = [statusPill(['fail', 'circle-x', 'Refused', null]), h('div', null, h('b', null, 'Not added: ' + r.error), h('div', { class: 'muted' }, 'Nothing was saved. Check you copied the whole key, then paste it again.'))];
  else {
    const s = r.row ? statusOf(r.row, f.a) : ['ok', 'circle-check', 'Works', null];
    const line = s[2] === 'Works' ? title(a, p) + ' accepted it. It is in your login keychain.'
      : s[2] === 'No check for this provider' ? title(a, p) + ' has no key check, so it is used as is; a sandbox’s first request will tell.'
      : 'Saved' + (s[3] ? ' — ' + s[3] : '') + '.';
    res = [statusPill(s), h('div', null, h('b', null, r.name + ' is ' + (s[0] === 'fail' ? 'saved, but ' + s[2].toLowerCase() : 'ready') + '.'), h('div', { class: 'muted' }, line))];
  }
  body.append(h('div', { class: 'ak-result', role: 'status', 'data-ak-result': r.checking ? 'checking' : r.error ? 'refused' : 'done' }, ...res));
  foot.append(r.error ? btn('Paste again', () => { f.step = 2; paintFlow(); }, { primary: true, icon: 'key-round' }) : null, h('span', { class: 'spacer' }),
    r.checking ? null : btn(r.error ? 'Cancel' : 'Done', () => d.close(), { primary: !r.error, icon: r.error ? 'x' : 'check' }));
  d.replaceChildren(head, h('div', { class: 'ak-flow-steps' }, steps), body, ...[foot].filter(Boolean));
}

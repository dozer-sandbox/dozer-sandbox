// views/accounts — Accounts & keys.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { api } from '../core/api-0a712b05e0caf823.js';
import { full, when } from '../core/format-b2e68384da8d2f36.js';
import { act } from '../core/operations-c7eeae66c46d4582.js';
import { refresh } from '../core/router-317300748e6e69ca.js';
import { secretEntryAllowed } from '../core/settings-b82be35de3dd1806.js';
import { accountCommandsNode, accountForm } from '../components/accounts-7a4491c3b003838e.js';
import { card, panel, table } from '../components/blocks-53c969feeec8fe89.js';
import { btn } from '../components/button-72d87e1085f00b4e.js';
import { confirmAction } from '../components/dialog-eda31d5dbf8a6de4.js';
import { moreMenu } from '../components/menus-08caea0a1297bf90.js';
import { toast } from '../components/notices-f4d7053b68a08d1e.js';

export async function viewAccounts() {
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

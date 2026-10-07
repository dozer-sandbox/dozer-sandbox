// views/devices — Devices (606): the browsers let in to doz serve (this Mac's dashboard for your other computers,
// tablets and phones) — who, since when, last seen from where, with which browser — each removable; Add another
// browser; and what they did lately (the audit log). The same page on doz serve (any browser that is in) and on the
// Mac's own doz ui (through the running doz serve, else from its files).
import { h } from '../dom/h.js';
import { api } from '../core/api.js';
import { when, full } from '../core/format.js';
import { refresh } from '../core/router.js';
import { isRemote } from '../core/session.js';
import { state } from '../core/state.js';
import { panel, table } from '../components/blocks.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { dialog } from '../components/dialog.js';
import { moreMenu } from '../components/menus.js';
import { toast } from '../components/notices.js';
import { shareDialog } from '../components/share.js';

const KIND_WORDS = {
  admit: 'let in', 'admit-refused': 'refused a code or link', share: 'invite made', revoke: 'removed', rename: 'renamed',
  'sign-out': 'signed out', change: 'did', 'terminal-open': 'opened a terminal', 'terminal-close': 'closed a terminal',
  refused: 'refused', dropped: 'connection dropped', start: 'doz serve started', stop: 'doz serve stopped',
};

export async function viewDevices() {
  const [st, list] = await Promise.all([api('serve'), api('serve/devices')]);
  const running = st.state === 'running';
  const reload = () => { if (state.view === 'devices') refresh(false); };
  const add = btn('Add another browser', () => shareDialog(), { primary: true, icon: 'plus',
    title: running ? 'A QR code, an access code and a link — each lets one browser in, within five minutes' : 'doz serve is not running' });
  if (!running) add.disabled = true;
  const status = running
    ? callout('info', { compact: true, cls: 'notice', attrs: { 'data-serve-state': 'running' }, body: [
      'doz serve is running: ', ...st.origins.slice(0, 3).flatMap((o, i) => [i ? ' · ' : '', h('code', null, o)]),
      st.publicOrigins.length ? [' · behind your proxy: ', ...st.publicOrigins.flatMap((o, i) => [i ? ', ' : '', h('code', null, o)])] : null,
      st.advertised ? ' · announced as “' + st.advertised + '”' : null] })
    : callout('warn', { compact: true, cls: 'notice', attrs: { 'data-serve-state': 'stopped' }, body: [
      'doz serve is not running — start it in a terminal on this Mac: ', h('code', null, 'doz serve'),
      '. The browsers below stay let in; removing one here takes effect at once.'] });
  const rows = list.devices.map((d) => h('tr', { 'data-device': d.id },
    h('td', null, h('div', { class: 'cell-name' }, h('span', { class: 'nm' }, d.name), d.current ? h('span', { class: 'tag' }, 'this browser') : null),
      h('div', { class: 'sub2 mono' }, d.id)),
    h('td', { title: full(d.created) }, when(d.created)),
    h('td', { title: full(d.lastSeen) }, when(d.lastSeen)),
    h('td', { class: 'mono' }, d.lastAddress),
    h('td', { class: 'trunc', title: d.userAgent }, d.userAgent || '—'),
    h('td', { class: 'muted' }, 'by ' + d.admittedBy + ', ' + d.admittedVia),
    h('td', { class: 'row-acts-cell' }, h('div', { class: 'row-acts' },
      btn('Remove', () => removeDevice(d, reload), { small: true, quiet: true, danger: true, icon: 'trash-2',
        title: 'Signed out at once (its terminals close); it needs a new invite to come back' }),
      moreMenu('More for ' + d.name, [
        { label: 'Rename…', icon: 'user-round', desc: 'A name you will recognise', onSelect: () => renameDevice(d, reload) },
      ], { small: true }).el))));
  const activity = list.activity.map((e) => h('tr', null,
    h('td', { title: full(e.time) }, when(e.time)),
    h('td', null, KIND_WORDS[e.kind] || e.kind, e.count ? ' ×' + e.count : ''),
    h('td', null, e.deviceName || '—'),
    h('td', { class: 'mono' }, e.address || '—'),
    h('td', { class: 'mono' }, [e.route, e.action, e.sandbox].filter(Boolean).join(' · ') || '—'),
    h('td', { class: 'muted' }, e.outcome || '')));
  const node = h('div', { 'data-devices': '' },
    h('div', { class: 'head' }, h('h1', null, 'Devices'), add),
    h('p', { class: 'sub' }, isRemote()
      ? 'The browsers let in to Dozer on this Mac’s network (doz serve) — this one among them. Each stays in until it is removed.'
      : 'The browsers of your other computers, tablets and phones let in to doz serve — this Mac’s dashboard on your network. Each stays in until it is removed.'),
    status,
    panel(rows.length ? table(['Browser', 'Let in', 'Last seen', 'From', 'User agent', 'How', ''], rows) : null,
      'No browser is let in yet — Add another browser (or doz serve share on the Mac).'),
    h('h2', { class: 'section-title' }, 'Recent activity'),
    h('p', { class: 'sub' }, 'What the other browsers did (doz serve log): admissions, changes, terminals, refusals — never a key, a code or what was typed.'),
    panel(activity.length ? table(['When', 'What', 'Browser', 'From', 'Where', 'Outcome'], activity) : null, 'Nothing yet.'));
  return node;
}

function removeDevice(d, reload) {
  dialog('Remove ' + d.name, d.current
    ? 'This browser is signed out at once; it needs a new invite (or a code) to come back.'
    : d.name + ' is signed out at once — its pages and terminals close — and it needs a new invite to come back.',
  [], 'Remove', async () => {
    await api('serve/devices/' + d.id + '/revoke', { method: 'POST', json: {} });
    toast('Removed ' + d.name);
    reload();
  }, { danger: true, icon: 'trash-2' });
}

function renameDevice(d, reload) {
  dialog('Rename ' + d.name, null, [{ name: 'name', label: 'Name', value: d.name, required: true, help: '1–60 characters — “Kitchen iPad”' }], 'Rename', async (v) => {
    await api('serve/devices/' + d.id + '/name', { method: 'POST', json: { name: v.name } });
    reload();
  }, { icon: 'user-round' });
}

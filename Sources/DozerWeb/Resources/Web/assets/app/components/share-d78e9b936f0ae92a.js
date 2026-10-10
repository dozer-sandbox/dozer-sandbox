// components/share — "Add another browser" (606, owner ruling): an invite from doz serve — a QR code, an access code
// and a link, whichever is used first lets ONE browser in, within five minutes. From any browser that is in (doz
// serve) and from the Mac's own dashboard (doz ui asks the running doz serve). The link is a key: it is shown in a
// read-only field to copy, never put in the address bar or storage.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, withIcon } from '../dom/icons-75c107270d336b51.js';
import { api } from '../core/api-0a712b05e0caf823.js';
import { quietly } from '../core/util-1195caf40612902f.js';
import { btn } from './button-72d87e1085f00b4e.js';
import { callout } from './callout-48fdacc012091bbe.js';
import { qrSvg } from './qr-70eb03c3c4d654f1.js';

export function shareDialog(onShared) {
  const d = h('dialog', { class: 'dlg dlg-wide share-dialog', 'data-share': '' });
  const body = h('div', { class: 'dlg-body' });
  const close = h('button', { type: 'button', class: 'btn sm quiet icon-only', title: 'Close', 'aria-label': 'Close', on: { click: () => d.close() } }, icon('x'));
  const done = h('button', { type: 'button', class: 'btn', on: { click: () => d.close() } }, withIcon('check', 'Done'));
  let timer = null;
  d.append(h('div', { class: 'dlg-head' }, h('h2', { class: 'h-title' }, 'Add another browser'), close), body,
    h('div', { class: 'dlg-foot dlg-buttons' }, done));
  d.addEventListener('close', () => { clearInterval(timer); d.remove(); });
  async function make() {
    clearInterval(timer);
    body.replaceChildren(h('p', { class: 'muted' }, 'Making an invite…'));
    let inv;
    try {
      inv = await api('serve/share', { method: 'POST', json: {} });
    } catch (e) {
      body.replaceChildren(callout('bad', { title: 'No invite', body: e.message || String(e) }));
      return;
    }
    if (onShared) onShared();
    const left = h('span', { 'data-share-left': '' });
    const link = h('input', { type: 'text', readonly: true, class: 'mono share-link', 'data-share-link': '', 'aria-label': 'The invite link', spellcheck: 'false' });
    link.value = inv.link;
    const copy = btn('Copy link', async (ev) => {
      const b = ev.currentTarget;
      link.select();
      let ok = false;
      // An http page (doz serve without your proxy) is not a secure context: no clipboard API — the field stays selected.
      try { if (navigator.clipboard) { await navigator.clipboard.writeText(inv.link); ok = true; } } catch (_) { /* below */ }
      b.textContent = ok ? 'Copied' : 'Selected — copy it (⌘C)';
    }, { small: true, icon: 'copy' });
    const again = btn('Make another', () => make(), { small: true, icon: 'refresh-cw' });
    const qr = inv.qr ? qrSvg(inv.qr.rows, 'QR code of the invite link') : null;
    body.replaceChildren(
      h('p', { class: 'sub' }, 'Whichever is used first lets ONE browser in, within five minutes. That browser then stays in until it is removed (Devices).'),
      h('div', { class: 'share-grid' },
        qr ? h('figure', { class: 'share-qr', 'data-share-qr': String(inv.qr.size) }, qr, h('figcaption', { class: 'muted' }, 'Scan it with a phone or tablet')) : null,
        h('div', { class: 'share-side' },
          h('div', { class: 'share-k' }, 'Access code'),
          h('div', { class: 'share-code mono', 'data-share-code': '' }, inv.code),
          h('small', { class: 'muted' }, 'Type it on the sign-in page of ', h('code', null, inv.link.split('/#')[0])),
          h('div', { class: 'share-k' }, 'Or the link'),
          h('div', { class: 'ws-row' }, link, copy),
          h('small', { class: 'muted' }, 'A key for one browser: send it only to yourself.'),
          h('div', { class: 'share-left' }, left, again))));
    const expires = new Date(inv.expiresAt).getTime();
    const tick = () => {
      const s = Math.max(0, Math.round((expires - Date.now()) / 1000));
      left.textContent = s > 0 ? 'Valid for ' + Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0') : 'Expired — make another';
      if (s === 0) { clearInterval(timer); qr?.classList.add('expired'); link.value = ''; }
    };
    tick();
    timer = setInterval(tick, 1000);
  }
  document.body.append(d);
  d.showModal();
  quietly(() => done.focus());
  make();
  return d;
}

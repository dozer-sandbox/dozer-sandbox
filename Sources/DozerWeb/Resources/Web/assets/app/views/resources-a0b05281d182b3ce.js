// views/resources — Resources (595).
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, setButton } from '../dom/icons-75c107270d336b51.js';
import { api } from '../core/api-129e35835156aceb.js';
import { bytes } from '../core/format-b2e68384da8d2f36.js';
import { measured, remeasure } from '../core/measure-93b2fe0a1b136d9b.js';
import { act, actOrThrow } from '../core/operations-24912c84c13d7e09.js';
import { refresh } from '../core/router-007bb37dea7abb80.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { meter, pageIndex, panel, table } from '../components/blocks-53c969feeec8fe89.js';
import { btn } from '../components/button-72d87e1085f00b4e.js';
import { dialog } from '../components/dialog-627b79752657f161.js';
import { pageFailure, toast } from '../components/notices-4ade591a3c0f51da.js';
import { phasePill } from '../components/pills-5d9961b7c3bb32b1.js';

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
export async function viewResources() {
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

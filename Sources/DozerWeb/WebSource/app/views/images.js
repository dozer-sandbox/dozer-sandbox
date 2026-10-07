// views/images — Images: the table and the lineage (593, 595).
import { h } from '../dom/h.js';
import { iconFor, withIcon } from '../dom/icons.js';
import { api } from '../core/api.js';
import { bytes, full, pct, when } from '../core/format.js';
import { measured, remeasure } from '../core/measure.js';
import { act, actOrThrow } from '../core/operations.js';
import { refresh } from '../core/router.js';
import { state } from '../core/state.js';
import { panel, table } from '../components/blocks.js';
import { btn } from '../components/button.js';
import { confirmAction, dialog } from '../components/dialog.js';
import { moreMenu } from '../components/menus.js';

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
export async function viewImages() {
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

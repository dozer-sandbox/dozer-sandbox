// views/overview — Sandboxes (the overview).
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon } from '../dom/icons-75c107270d336b51.js';
import { api } from '../core/api-0a712b05e0caf823.js';
import { bytes, mib } from '../core/format-b2e68384da8d2f36.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { card, meter, panel, table } from '../components/blocks-53c969feeec8fe89.js';
import { btn } from '../components/button-72d87e1085f00b4e.js';
import { hostCard } from '../components/host-02089da4b07a5e2b.js';
import { rowLifecycle } from '../components/lifecycle-0cd4b4f45cf7a3d6.js';
import { renderNavSandboxes } from '../components/nav-baacb3a712d5064d.js';
import { sandboxPill } from '../components/pills-a0247e11708f05b5.js';
import { quickAddButton } from '../components/quick-add-58345c4c4ad978fa.js';
import { ISOLATED_NOTE } from '../components/workspace-chooser-e86fa5060e492601.js';
import { newSandboxWizard } from './new-sandbox-32b9adf5a7927e90.js';

// ── views ───────────────────────────────────────────────────────────────────
export async function viewOverview() {
  const o = await api('overview');
  state.overview = o;
  renderNavSandboxes();
  const rows = o.sandboxes.map((s) => h('tr', { class: 'click', 'data-sandbox-row': s.name, on: { click: () => { location.hash = '#/sandbox/' + s.name; } } },
    h('td', null, h('a', { class: 'name', href: '#/sandbox/' + s.name }, s.name),
      h('div', { class: 'sub2' }, s.image, s.workspace ? null : h('span', { class: 'no-ws', 'data-isolated': '', title: ISOLATED_NOTE }, ' · isolated')),
      h('div', { 'data-op-for': s.name })),
    h('td', null, sandboxPill(s), s.diedWithHost ? h('div', { class: 'st-warn sub2' }, 'died with its host') : null),
    h('td', { class: 'num' }, h('div', null, s.ramHeldMiB ? mib(s.ramHeldMiB) : '—'), h('div', { class: 'sub2' }, 'of ' + mib(s.memoryMiB)), meter(s.ramHeldMiB, s.memoryMiB)),
    h('td', { class: 'num' }, bytes(s.diskBytes)),
    h('td', null, s.network, s.deniedConnections ? [' ', h('span', { class: 'tag warn' }, s.deniedConnections + ' denied')] : null),
    s.accountApplies
      ? h('td', null, s.account || '—', s.credentialState ? h('div', { class: (s.credentialState === 'ok' ? 'st-ok' : 'st-warn') + ' sub2' }, s.credentialState) : null,
        s.foreignCredentials ? h('div', { class: 'st-warn sub2' }, s.foreignCredentials + ' own credential(s)') : null)
      : h('td', { class: 'muted', title: 'its network cannot reach an account’s API' }, 'n/a'),
    h('td', { class: 'row-acts-cell' }, rowLifecycle(s))));
  return h('div', null,
    h('div', { class: 'head' }, h('h1', null, 'Sandboxes'),
      h('div', { class: 'actions' }, quickAddButton(), (() => {
        const b = btn('New sandbox', () => newSandboxWizard(), { primary: true, title: 'Step by step — your choices go in the project folder’s doz_project.yaml' });
        b.dataset.newSandbox = '';
        return b;
      })())),
    h('p', { class: 'sub' }, o.source === 'host' ? 'Live from the host.' : 'No host is running: read from the store (nothing is live). An action starts the host.'),
    h('div', { class: 'stats' },
      hostCard(o.host),
      card('Sandboxes', String(o.totals.sandboxes), o.totals.live + ' with a VM'),
      card('RAM held', mib(o.totals.ramHeldMiB), 'charged to this Mac now'),
      card('Disk', bytes(o.totals.diskBytes), 'allocated, all sandboxes')),
    h('h2', null, 'All sandboxes'),
    // No session column: counting sessions asks every session's holder in the guest, and this list
    // is kept live — sessions are on each sandbox's page (590 bug 3).
    o.sandboxes.length ? panel(table(['Sandbox', 'Phase', 'RAM held', 'Disk', 'Network', 'Account', h('span', { class: 'sr-only' }, 'Actions')], rows, [2, 3]))
      : h('div', { class: 'panel' }, h('div', { class: 'empty-big' }, icon('box'), h('div', { class: 'e-title' }, 'No sandboxes yet'),
        h('p', null, 'A sandbox is a small Linux VM for one project. Quick add makes one with every default; New sandbox walks through each choice. In a terminal: doz new, or doz init then doz up.'),
        h('div', { class: 'actions center' }, quickAddButton()))));
}

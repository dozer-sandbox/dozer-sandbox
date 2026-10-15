// views/doctor — Doctor.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { api } from '../core/api-2814f617dbd35bcd.js';
import { state } from '../core/state-450cb6573a620304.js';
import { panel, table } from '../components/blocks-53c969feeec8fe89.js';
import { btn } from '../components/button-cbb8a60e3220f977.js';
import { statusPill } from '../components/pills-4037a7464bd2c4fa.js';
import { tildeIn } from '../core/paths-074fefdb8b1d48aa.js';

export async function viewDoctor() {
  const checks = await api('doctor');
  const rows = checks.map((c) => h('tr', null, h('td', null, statusPill(c.status)), h('td', null, c.check), h('td', null, tildeIn(c.detail))));
  return h('div', null,
    h('div', { class: 'head' }, h('h1', null, 'Doctor'),
      btn('Run onboarding again', () => { state.wiz = null; location.hash = '#/onboarding'; },
        { title: 'The setup wizard: checks, the Claude account, settings, images — it prepares only what is missing' })),
    h('p', { class: 'sub' }, 'doz doctor: this Mac, the store, the host and the Claude login (re-checked at most every 30 s).'),
    panel(table(['', 'Check', 'Detail'], rows)));
}

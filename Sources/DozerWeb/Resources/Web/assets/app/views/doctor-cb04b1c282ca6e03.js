// views/doctor — Doctor.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { api } from '../core/api-1817573a49f0ab85.js';
import { state } from '../core/state-6efaa5d4aa08116b.js';
import { panel, table } from '../components/blocks-53c969feeec8fe89.js';
import { btn } from '../components/button-8e61dd531eed2262.js';
import { statusPill } from '../components/pills-cc8cdee2b0253bea.js';

export async function viewDoctor() {
  const checks = await api('doctor');
  const rows = checks.map((c) => h('tr', null, h('td', null, statusPill(c.status)), h('td', null, c.check), h('td', null, c.detail)));
  return h('div', null,
    h('div', { class: 'head' }, h('h1', null, 'Doctor'),
      btn('Run onboarding again', () => { state.wiz = null; location.hash = '#/onboarding'; },
        { title: 'The setup wizard: checks, the Claude account, settings, images — it prepares only what is missing' })),
    h('p', { class: 'sub' }, 'doz doctor: this Mac, the store, the host and the Claude login (re-checked at most every 30 s).'),
    panel(table(['', 'Check', 'Detail'], rows)));
}

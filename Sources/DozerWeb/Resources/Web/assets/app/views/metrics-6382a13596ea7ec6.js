// views/metrics — Metrics.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { withIcon } from '../dom/icons-75c107270d336b51.js';
import { api } from '../core/api-129e35835156aceb.js';
import { ms } from '../core/format-b2e68384da8d2f36.js';
import { refresh } from '../core/router-007bb37dea7abb80.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { card, panel, table } from '../components/blocks-53c969feeec8fe89.js';

export async function viewMetrics() {
  const f = state.metricsFilter;
  const qs = new URLSearchParams();
  if (f.image) qs.set('image', f.image);
  if (f.days) qs.set('days', f.days);
  qs.set('steps', f.steps ? '1' : '0');
  const [m, images] = await Promise.all([api('metrics?' + qs), api('images').catch(() => [])]);
  const imageSel = h('select', { 'aria-label': 'image' }, [['', 'all images'], ...images.map((i) => [i.kind === 'custom' ? 'custom:' + i.name : i.name, i.name])].map(([v, l]) => {
    const o = h('option', { value: v }, l);
    if (v === f.image) o.selected = true;
    return o;
  }));
  const daysSel = h('select', { 'aria-label': 'since' }, [['', 'all time'], ['1', 'last day'], ['7', 'last 7 days'], ['30', 'last 30 days']].map(([v, l]) => {
    const o = h('option', { value: v }, l);
    if (v === f.days) o.selected = true;
    return o;
  }));
  const steps = h('input', { type: 'checkbox' });
  steps.checked = f.steps;
  for (const el of [imageSel, daysSel, steps]) {
    el.addEventListener('change', () => { state.metricsFilter = { image: imageSel.value, days: daysSel.value, steps: steps.checked }; refresh(false); });
  }
  const csv = h('a', { class: 'btn sm', href: '/api/v1/metrics.csv?' + qs, download: 'dozer-metrics.csv' }, withIcon('download', 'Download CSV'));
  const toolbar = h('div', { class: 'toolbar' }, imageSel, daysSel, h('label', null, steps, ' steps inside actions'), csv);
  if (!m.available) return h('div', null, h('h1', null, 'Metrics'), toolbar, panel(null, 'No metrics yet — the host records every action it times.'));
  const max = Math.max(1, ...m.summary.map((r) => r.p90Ms || r.medianMs || 0));
  const rows = m.summary.map((r) => {
    const bar = h('span');
    bar.style.width = (((r.medianMs || 0) / max) * 100).toFixed(1) + '%';
    return h('tr', null, h('td', null, r.action, r.kind === 'step' ? h('span', { class: 'tag' }, 'step') : null), h('td', { class: 'num' }, String(r.count)),
      h('td', { class: 'num' }, ms(r.medianMs)), h('td', { class: 'num' }, ms(r.p90Ms)),
      h('td', { class: 'num' }, ms(r.minMs)), h('td', { class: 'num' }, ms(r.maxMs)),
      h('td', { class: 'num' }, r.failed ? h('span', { class: 'st-fail' }, String(r.failed)) : ''),
      h('td', { class: 'bar' }, h('div', { class: 'hbar', title: 'median, relative to the slowest p90' }, bar)));
  });
  return h('div', null, h('h1', null, 'Metrics'),
    h('p', { class: 'sub' }, 'Lifecycle timings the host recorded.'),
    toolbar,
    h('div', { class: 'stats' }, card('Host runs', String(m.runs)), card('Rows', String(m.rows)), card('Sessions', String(m.sessions)), card('Network minutes', String(m.networkMinutes))),
    h('h2', null, 'Per action'),
    panel(h('div', { class: 'bars' }, table(['Action', 'Count', 'Median', 'P90', 'Min', 'Max', 'Failed', ''], rows, [1, 2, 3, 4, 5, 6])), 'Nothing recorded for this filter.'));
}

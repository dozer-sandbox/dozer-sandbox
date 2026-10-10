// views/activity — Activity.
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { api } from '../core/api-0a712b05e0caf823.js';
import { clock } from '../core/format-b2e68384da8d2f36.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { panel } from '../components/blocks-53c969feeec8fe89.js';

export async function viewActivity() {
  const recent = await api('events');
  const seen = new Set(state.activity.map((a) => a.seq));
  for (const a of recent) if (!seen.has(a.seq)) state.activity.push(a);
  state.activity.sort((x, y) => x.seq - y.seq);
  return activityNode();
}
function activityNode() {
  const items = state.activity.slice().reverse().map((a) => h('li', null,
    h('span', { class: 't' }, clock(a.time)), h('span', { class: 'who muted' }, a.sandbox || a.kind),
    h('span', { class: 'text' }, a.text)));
  return h('div', null, h('h1', null, 'Activity'),
    h('p', { class: 'sub' }, 'What the host does — phases, timed steps, notes — while a sandbox is live and this page is open.'),
    panel(items.length ? h('ul', { class: 'feed' }, items) : null, 'Nothing yet. Start or wake a sandbox and it shows here.'));
}
export function renderActivity() { $('view').replaceChildren(activityNode()); }

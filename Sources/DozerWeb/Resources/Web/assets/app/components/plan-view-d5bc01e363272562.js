// components/plan-view — A plan's parts as the dashboard shows them (617): the command that makes it ("The same, in a
// terminal", copyable) and what it can reach (the planner's reach lines, in plain words). The New Sandbox review and
// the Quick try page draw the SAME plan the CLI's --dry-run prints.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { btn } from './button-cbb8a60e3220f977.js';
import { toast } from './notices-0eac624a71d00e4f.js';
import { tildeIn } from '../core/paths-074fefdb8b1d48aa.js';

/// The command, copyable (a page served over plain HTTP from another device has no clipboard: the text stays selectable).
export function planCommand(plan) {
  const code = h('code', { class: 'plan-cmd-text', 'data-plan-command': '' }, plan.command);
  const copy = btn('Copy', async () => {
    try {
      if (!navigator.clipboard) throw new Error('no clipboard here');
      await navigator.clipboard.writeText(plan.command);
      toast('Copied the command');
    } catch (_) { toast('Select the command and copy it by hand', true); }
  }, { small: true, quiet: true, icon: 'copy' });
  return h('div', { class: 'plan-cmd' }, code, copy);
}

/// The reach lines, each with its kind (model, packages, folder, bridge, key, excluded, denied …) as a hook for the style.
export function reachList(reach, kinds = null) {
  const lines = (reach || []).filter((r) => !kinds || kinds.includes(r.kind));
  return h('ul', { class: 'reach-list', 'data-plan-reach': '' }, ...lines.map((r) => h('li', { class: 'reach-' + r.kind, 'data-reach-kind': r.kind }, tildeIn(r.text))));
}

/// Both, under their headings — the review's block.
export function planBlock(plan) {
  return h('div', { class: 'plan-block', 'data-plan': '' },
    h('h3', { class: 'plan-h' }, 'The same, in a terminal'), planCommand(plan),
    h('h3', { class: 'plan-h' }, 'What it can reach'), reachList(plan.reach));
}

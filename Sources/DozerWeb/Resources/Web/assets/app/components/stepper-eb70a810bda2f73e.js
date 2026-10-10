// components/stepper — The wizards' step strip.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon } from '../dom/icons-75c107270d336b51.js';

/// 603 (E15; owner on rc.1: horizontal, in the modal's header): the wizards' step strip — done (a check; the step's
/// answer as its tooltip), current (the accent circle), later; a done or reachable step is a link back. One row of
/// equal columns, never two; in a narrow window the circles only, with "Step N of M · its name" above.
export function stepperNode(steps, current, opts = {}) {
  const list = h('ol', { class: 'stepper wiz-steps' }, steps.map((s, i) => {
    const state_ = i === current ? 'current' : (opts.done ? opts.done(i) : i < current) ? 'done' : null;
    const go = opts.go && opts.go(i);
    const note = state_ === 'done' && opts.note ? opts.note(s, i) : null;
    const attrs = { class: state_, 'aria-current': i === current ? 'step' : null, title: s.title + (note ? ' — ' + note : '') };
    if (opts.data) attrs[opts.data] = s.id;
    return h('li', attrs, h('span', { class: 'n wiz-n', 'aria-hidden': state_ === 'done' ? null : 'true' }, state_ === 'done' ? icon('check') : String(i + 1)),
      go ? h('a', { class: 's-label', href: opts.href || '#', on: { click: (ev) => { ev.preventDefault(); go(); } } }, s.title) : h('span', { class: 's-label' }, s.title),
      note ? h('span', { class: 's-note' }, note) : null);
  }));
  const compact = h('div', { class: 'step-compact', 'aria-hidden': 'true' },
    h('b', null, 'Step ' + (current + 1) + ' of ' + steps.length), ' · ', h('span', null, (steps[current] || {}).title || ''));
  return { list, compact };
}

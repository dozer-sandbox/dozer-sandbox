// components/rules-step — Workspace rules (599g): the onboarding's and the New Sandbox wizard's step.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon } from '../dom/icons-75c107270d336b51.js';
import { btn } from './button-72d87e1085f00b4e.js';

// ── workspace rules: the onboarding's and the New Sandbox wizard's step (599g) ──────────────────────
// ONE component (owner: the same human description in both): what .dozignore and .dozreadonly do, the mode
// (onboarding: the default workspace.ignore_mode; sandbox: this sandbox's ignore_mode) and, in the wizard, what
// the chosen folder already has. Its words are the host's (`rulesGuide` — WorkspaceRulesGuide, the same
// doz onboard and doz init print). It writes nothing: the caller keeps the choice (onPick).
//   rulesStep({ mode: 'onboarding'|'sandbox', guide, value, onPick(value), folder: {rules: [...]}, onLookAgain })
export function rulesStep(opts) {
  const g = opts.guide, mode = opts.mode || 'onboarding';
  const points = h('ul', { class: 'rules-points' }, g.points.map((p) =>
    h('li', null, p.term ? [h('code', null, p.term), ' — ' + p.text] : p.text)));
  let folder = null;
  if (mode === 'sandbox') {
    const files = (opts.folder && opts.folder.rules) || [];
    const found = files.map((r) => h('div', { class: 'rules-file', 'data-rules-file': r.name },
      h('div', null, h('code', null, r.name), ' — ' + r.count),
      r.first.length ? h('pre', { class: 'rules-lines' }, r.first.join('\n') + (r.patterns > r.first.length ? '\n…' : '')) : null));
    folder = h('div', { class: 'rules-folder', 'data-rules-folder': files.length ? 'found' : 'none' },
      h('div', { class: 'rules-folder-head' }, icon('folder'), h('strong', null, 'This folder’s rules'),
        opts.onLookAgain ? btn('Look again', opts.onLookAgain, { small: true, title: 'Read the folder again — after you add or change a rule file' }) : null),
      files.length ? found : [h('p', { 'data-rules-none': '' }, g.noRules.charAt(0).toUpperCase() + g.noRules.slice(1) + '.'),
                              h('p', { class: 'muted' }, g.howToAdd)]);
  }
  const labels = [];
  const radios = g.modes.map((m) => {
    const input = h('input', { type: 'radio', name: 'rules-mode-' + mode, value: m.value });
    input.checked = m.value === opts.value;
    const label = h('label', { class: 'wiz-choice' + (input.checked ? ' chosen' : ''), 'data-rules-mode': m.value }, input,
      h('span', null, h('strong', null, m.label), m.recommended ? h('span', { class: 'tag' }, 'recommended') : null,
        h('div', { class: 'muted' }, m.detail)));
    input.addEventListener('change', () => {
      if (!input.checked) return;
      for (const l of labels) l.classList.toggle('chosen', l === label);
      opts.onPick(m.value);
    });
    labels.push(label);
    return label;
  });
  return h('div', { class: 'rules-step', 'data-rules-step': mode },
    h('p', null, g.intro),
    h('details', { class: 'disclosure' }, h('summary', null, icon('chevron-down'), 'How they work, and what they are not'), points), folder,
    h('fieldset', { class: 'wiz-choices' }, h('legend', null, g.question), radios),
    h('p', { class: 'muted' }, mode === 'sandbox' ? g.sandboxScope : g.defaultScope));
}

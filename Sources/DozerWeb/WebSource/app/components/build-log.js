// components/build-log — the build log as a document (617; owner: "the objective is to show how the image was made
// including all the commands to build and configure"). Drawn from the host's `BuildLogDocument` — the same record
// `doz image log IMAGE` prints: the inputs (base with its digest, kernel, guest init, the recipe and its version, the
// bake network policy, the early steps and whether each was cached), then each step — a plain heading, the command
// exactly as it ran (a script verbatim, monospace), every file it writes (path and contents; a long one folded), how it
// went and its output — then the checks (command, what it expects, what it got) and the trim. Text only (textContent):
// every line is guest or recipe text, inert.
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';

function secs(s) {
  if (s == null) return '';
  return s >= 60 ? Math.floor(s / 60) + ':' + String(Math.floor(s % 60)).padStart(2, '0') : s.toFixed(1) + ' s';
}
const pre = (lines, cls) => h('pre', { class: 'bl-code' + (cls ? ' ' + cls : '') }, lines.join('\n'));
function fold(summary, body, open) {
  const d = h('details', { class: 'disclosure bl-fold' }, h('summary', null, icon('chevron-down'), summary), body);
  if (open) d.open = true;
  return d;
}
const mark = (ok) => h('span', { class: 'bl-mark ' + (ok ? 'ok' : 'bad'), 'aria-hidden': 'true' }, ok ? '✓' : '✗');

function stepNode(s, n) {
  const how = s.result === 'ran' ? 'ran' + (s.seconds != null ? ' in ' + secs(s.seconds) : '') : s.result;
  return h('section', { class: 'bl-step', 'data-bl-step': String(n + 1), 'data-result': s.result },
    h('h3', null, mark(s.result !== 'failed' && s.result !== 'not run'), (n + 1) + '. ' + s.title),
    h('p', { class: 'bl-sub' }, 'step: ' + s.name + ' · as ' + (s.user || 'root') + ' · ' + how + (s.error ? ' — ' + s.error : '')),
    s.environment.length ? fold('Environment (' + s.environment.length + ')', pre(s.environment.map((e) => e.label + '=' + e.value))) : null,
    s.script.length ? h('div', { class: 'bl-cmd' }, h('div', { class: 'bl-label' }, s.runner ? 'Command: ' + s.runner + ' — the script, verbatim' : 'Command'),
      pre(s.script, 'bl-script')) : null,
    ...s.files.map((f) => fold('Writes ' + f.path + ' (' + f.lines.length + (f.lines.length === 1 ? ' line)' : ' lines)'), pre(f.lines, 'bl-file'), !f.long)),
    s.output.length ? h('div', { class: 'bl-out' }, h('div', { class: 'bl-label' }, 'Output (' + s.output.length + (s.output.length === 1 ? ' line)' : ' lines)')),
      pre(s.output, 'bl-output')) : null);
}

function checkNode(c) {
  return h('li', { class: 'bl-check', 'data-result': c.result },
    h('div', { class: 'bl-check-head' }, mark(c.result === 'passed'), h('strong', null, c.title), c.seconds != null ? h('span', { class: 'muted' }, secs(c.seconds)) : null),
    h('dl', { class: 'bl-facts' },
      h('dt', null, 'Command'), h('dd', null, h('code', null, c.command)),
      h('dt', null, 'Expects'), h('dd', null, c.expect),
      h('dt', null, 'Got'), h('dd', null, c.got.length ? pre(c.got) : h('span', { class: 'muted' }, '(nothing)')),
      c.error ? h('dt', null, 'Error') : null, c.error ? h('dd', null, c.error) : null));
}

/// The document's node (a scroller filling the pane).
export function buildLogNode(d) {
  const when = new Date(d.finishedAt).toLocaleString();
  const early = d.early.map((e) => h('li', null, mark(e.ok), e.label, ' ', h('span', { class: 'muted' }, secs(e.seconds)),
    e.cached ? h('span', { class: 'tag' }, 'cached') : null));
  return h('div', { class: 'buildlog-doc', 'data-buildlog-doc': d.image },
    h('header', { class: 'bl-head' },
      h('h2', null, 'How ' + d.image + ' was built'),
      h('p', { class: 'bl-sub' }, (d.state === 'done' ? 'Built' : d.state === 'failed' ? 'Failed' : d.state) + ' in ' + secs(d.seconds) + ' · ' + when + (d.error && d.state !== 'done' ? ' — ' + d.error : '')),
      d.recorded ? null : h('p', { class: 'bl-note' }, 'Kept by an earlier doz: the commands were not recorded. The next build of ' + d.image + ' records them.')),
    d.inputs.length || early.length ? h('section', { class: 'bl-inputs', 'data-bl-inputs': '' },
      h('h3', null, 'Inputs'),
      h('dl', { class: 'bl-facts' }, ...d.inputs.flatMap((f) => [h('dt', null, f.label), h('dd', null, f.value)])),
      d.policy.length ? fold('Bake network policy (' + d.policy.length + (d.policy.length === 1 ? ' rule)' : ' rules)'), pre(d.policy)) : null,
      early.length ? h('ul', { class: 'bl-early' }, ...early) : null) : null,
    ...d.steps.map(stepNode),
    d.checks.length ? h('section', { class: 'bl-checks' }, h('h3', null, 'Checks'), h('ul', { class: 'bl-check-list' }, ...d.checks.map(checkNode))) : null,
    d.closing.length ? h('section', { class: 'bl-closing' }, h('h3', null, 'After the steps'),
      h('ul', { class: 'bl-early' }, ...d.closing.map((e) => h('li', null, mark(e.ok), e.label, ' ', h('span', { class: 'muted' }, secs(e.seconds))))),
      d.trimCommand ? h('div', { class: 'bl-cmd' }, h('div', { class: 'bl-label' }, 'The trim, as root'), pre([d.trimCommand])) : null) : null);
}

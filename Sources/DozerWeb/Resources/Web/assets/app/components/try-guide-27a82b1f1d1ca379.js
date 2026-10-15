// components/try-guide — the sandbox page's Guide tab (617.11; owner: "i tried fabric and it just gave me a terminal …
// whats missing for trys is our companion guide"; mock 617.11-TRY-GUIDE-MOCK.html). Four parts: the preamble (what it is,
// how to use it here — Dozer's words and the recipe's intro), "This try" (Dozer's facts of THIS sandbox: version, key and
// model, network, folder, settings), "Start here" (the recipe's steps — each command with Copy and Run, or Type for one
// to change first) and "Good to know" (its tips, its docs, when the recipe was checked).
//
// Text only: every string is textContent; `code` in a step or tip is cut by a tiny tokenizer (backquotes), never markup.
// Run types the command and presses Enter in a session of this sandbox through the ordinary input path (`sendInput`) —
// its own session for a tool that answers in the shell, a SHELL beside it for an agent with its own screen (never into
// the agent). Type types it without Enter. Both only while such a pane is open and live; otherwise disabled, with why.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { isAux, pageTerminals, sview } from '../core/terminals-933851e9be49078e.js';
import { btn } from './button-cbb8a60e3220f977.js';
import { toast } from './notices-0eac624a71d00e4f.js';
import { focusTerm, sendInput } from './terminal-626bae4b7cf1f181.js';
import { tildeIn } from '../core/paths-074fefdb8b1d48aa.js';

/// Which steps ran, per sandbox (page memory).
const RAN = new Map();

/// `a `b` c` → ["a ", <code>b</code>, " c"] — backquotes only, nothing else is read as markup.
export function codeText(s) {
  return String(s).split('`').map((p, i) => (i % 2 ? h('code', null, p) : p)).filter((x) => x !== '');
}

/// The pane a step goes to: a live interactive pane of this sandbox — its own session for a shell tool, a shell (not the
/// agent's session) for an agent with its own screen; the focused one first. { t } or { why }.
export function guideTarget(name, g) {
  const live = pageTerminals(name).filter((t) => !isAux(t) && t.mode === 'interactive' && !t.saved && !t.closed && !t.ended
    && t.ws && t.ws.readyState === WebSocket.OPEN);
  const fit = g.session === 'shell' ? live : live.filter((t) => t.session !== g.agentSession);
  if (!fit.length) {
    return { why: g.session === 'shell' ? 'Open its session first: start the sandbox, or click its tab'
      : 'Open a shell beside it first (New shell): ' + g.title + '’s own session is its screen' };
  }
  const v = sview(name);
  const sel = v.selected[v.focusedPane || 0];
  return { t: fit.find((t) => t.id === sel) || fit[0] };
}

function sect(title, ...kids) { return h('div', { class: 'guide-sect' }, h('h3', null, title), ...kids); }

/// The Guide tab's body. `onTab(id)` opens another tab (the Network fact links to Network).
export function guidePanel(name, g, onTab = () => {}) {
  const ran = RAN.get(name) || new Set();
  const target = guideTarget(name, g);
  const head = h('div', { class: 'guide-head' },
    h('div', { class: 'guide-title' }, h('strong', null, g.title), h('span', { class: 'muted' }, ' · ' + g.what)),
    h('p', null, g.intro),
    h('p', { class: 'muted' }, g.howTo));
  const facts = h('dl', { class: 'facts guide-facts', 'data-guide-facts': '' },
    ...g.facts.flatMap((f) => [h('dt', null, f.label),
      h('dd', { 'data-guide-fact': f.id }, tildeIn(f.value), f.id === 'network'
        ? h('button', { type: 'button', class: 'linkish', on: { click: () => onTab('network') } }, ' · Network') : null)]));
  const steps = h('ol', { class: 'guide-steps', 'data-guide-steps': '' }, ...g.steps.map((s, i) => {
    const kids = [h('p', null, ...codeText(s.text), ran.has(i) ? h('span', { class: 'guide-ran', 'data-guide-ran': String(i + 1) }, ' ✓ ran') : null)];
    if (s.command) {
      const copy = btn('Copy', async () => {
        try {
          if (!navigator.clipboard) throw new Error('no clipboard here');
          await navigator.clipboard.writeText(s.command);
          toast('Copied the command');
        } catch (_) { toast('Select the command and copy it by hand', true); }
      }, { small: true, quiet: true, icon: 'copy' });
      copy.dataset.guideCopy = String(i + 1);
      const go = btn(s.edit ? 'Type' : 'Run', () => {
        const tt = guideTarget(name, g);
        if (!tt.t) { toast(tt.why, true); return; }
        // Type: the command, for you to change and press Enter. Run: and Enter.
        sendInput(tt.t, s.command + (s.edit ? '' : '\r'));
        focusTerm(tt.t);
        if (!s.edit) { ran.add(i); RAN.set(name, ran); }
        guideRepaint(name, g, onTab);
      }, { small: true, icon: s.edit ? 'square-terminal' : 'play', title: target.t ? (s.edit ? 'Type it in the terminal — change it, then press Enter' : 'Run it in the terminal') : target.why });
      go.dataset.guideRun = String(i + 1);
      go.disabled = !target.t;
      kids.push(h('div', { class: 'guide-cmd' }, h('code', { 'data-guide-command': String(i + 1) }, s.command), copy, go));
    }
    return h('li', { 'data-guide-step': String(i + 1) }, ...kids);
  }));
  const why = target.t ? null : h('p', { class: 'muted guide-why', 'data-guide-why': '' }, target.why + '.');
  const tips = g.tips.length ? sect('Good to know', h('ul', { class: 'guide-tips' }, ...g.tips.map((t) => h('li', null, ...codeText(t))))) : null;
  const foot = h('p', { class: 'muted guide-foot' },
    g.docs ? h('span', null, 'Docs: ', h('code', null, g.docs)) : null,
    g.checked ? h('span', null, (g.docs ? ' · ' : '') + 'Recipe checked ' + g.checked) : null);
  return h('div', { class: 'guide', 'data-guide': g.agent },
    head,
    sect(g.trial ? 'This try' : 'This sandbox', facts),
    sect('Start here', steps, why),
    tips, foot);
}

/// Redraw the tab in place (a step ran).
function guideRepaint(name, g, onTab) {
  const box = document.querySelector('[data-insp="guide"]');
  if (box) box.replaceChildren(guideHead(), guidePanel(name, g, onTab));
}

/// The tab's own heading (the inspector's panels open with one).
export function guideHead() { return h('div', { class: 'head' }, h('h2', null, 'Guide')); }

export const GUIDE_TAB = ['guide', 'Guide', 'Guide: how to use it', 'list-checks'];

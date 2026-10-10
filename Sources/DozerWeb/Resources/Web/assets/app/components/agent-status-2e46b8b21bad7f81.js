// components/agent-status — What the agent is doing (612): the program's own status (OSC 7501), as chips and notices.
// Claude Code and pi say when they are working, blocked (a permission, a question, a sign-in), done or failed; deckhold
// in the sandbox keeps it and the host holds it per session (the overview carries it — no guest call). The words come
// from the server (`label`); a program's message and title are ITS text (untrusted): textContent and tooltips only.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { state } from '../core/state-c0289349b457ba56.js';
import { btn } from './button-72d87e1085f00b4e.js';
import { dropPageNotice, pageFailure } from './notices-4ade591a3c0f51da.js';

/// The status of `session` in `sandbox` (null: its program said nothing — Codex, a shell, an older holder).
export function agentStatusOf(sandbox, session) {
  const s = state.overview && state.overview.sandboxes.find((x) => x.name === sandbox);
  return (s && s.sessionStatuses && s.sessionStatuses.find((x) => x.session === session)) || null;
}

/// A few words for a small place (a tab, a tile): the kind of a block, else the state.
const KIND_WORD = { permission: 'needs permission', question: 'has a question', auth: 'needs sign-in' };
function shortWord(st) {
  if (st.state === 'blocked') return KIND_WORD[st.kind] || 'blocked';
  if (st.state === 'working' && st.progress != null) return 'working ' + st.progress + '%';
  return st.state;
}
function tooltip(st) {
  return [st.label, st.title, st.message].filter(Boolean).join(' — ');
}

/// A chip for one session — kept up to date in place by `paintAgentStatuses` (it carries `data-agent-for`).
export function agentChip(sandbox, session) {
  const el = h('span', { class: 'ag-chip', 'data-agent-for': sandbox + '/' + session, hidden: true });
  paintChip(el, agentStatusOf(sandbox, session));
  return el;
}
function paintChip(el, st) {
  const key = st ? st.state + '|' + st.label + '|' + (st.message || '') + '|' + (st.title || '') : '';
  if (el.dataset.painted === key) return;
  el.dataset.painted = key;
  el.hidden = !st;
  if (!st) { el.replaceChildren(); return; }
  el.className = 'ag-chip ag-' + st.state;
  el.title = tooltip(st);
  el.replaceChildren(h('span', { class: 'ag-mark', 'aria-hidden': 'true' }), h('span', { class: 'ag-word' }, shortWord(st)));
}

/// The sidebar's dot for a sandbox: its most urgent agent (idle says nothing there).
export function agentDot(row) {
  const st = row && row.agentStatus;
  if (!st || st.state === 'idle') return null;
  return h('span', { class: 'ag-dot ag-' + st.state, role: 'img', 'aria-label': 'agent: ' + st.label, title: 'agent: ' + st.label + (st.session ? ' (' + st.session + ')' : '') });
}

// ── notices: an agent that finished, is blocked or failed — told once per change, on any page ──────────
let seen = null;          // sandbox/session → state|kind, as last painted (null until the first overview: nothing old is told)
const said = (st) => st.state + '|' + (st.kind || '');
const TELL = {
  done: { tone: 'ok', says: 'is done' },
  error: { tone: 'bad', says: 'stopped with an error' },
  blocked: { tone: 'warn', says: 'is blocked' },
};
const BLOCKED_SAYS = { permission: 'needs permission', question: 'has a question', auth: 'needs sign-in' };

function tell(sandbox, st) {
  const t = TELL[st.state];
  const says = st.state === 'blocked' ? (BLOCKED_SAYS[st.kind] || t.says) : t.says;
  const open = btn('Open', () => { location.hash = '#/sandbox/' + sandbox + '/' + st.session; }, { small: true, quiet: true, title: 'Its session, on its sandbox’s page' });
  pageFailure(st.message || '', { key: 'agent:' + sandbox + '/' + st.session, tone: t.tone, title: sandbox + ' · ' + st.session + ' ' + says, actions: [open] });
}

/// After every overview: the chips on screen, and a notice for each session whose program has just become done,
/// blocked or failed. One that works again (or is gone) takes its notice away — it is no longer true.
export function paintAgentStatuses() {
  const o = state.overview;
  if (!o) return;
  for (const el of document.querySelectorAll('[data-agent-for]')) {
    const at = el.dataset.agentFor.indexOf('/');
    paintChip(el, agentStatusOf(el.dataset.agentFor.slice(0, at), el.dataset.agentFor.slice(at + 1)));
  }
  const now = new Map();
  for (const s of o.sandboxes) for (const st of s.sessionStatuses || []) now.set(s.name + '/' + st.session, { sandbox: s.name, st });
  if (seen) {
    for (const [key, { sandbox, st }] of now) {
      if (seen.get(key) === said(st)) continue;
      if (TELL[st.state]) tell(sandbox, st);
      else dropPageNotice('agent:' + key);
    }
    for (const key of seen.keys()) if (!now.has(key)) dropPageNotice('agent:' + key);
  }
  seen = new Map([...now].map(([k, v]) => [k, said(v.st)]));
}

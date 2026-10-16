// views/try — Quick try (617; the owner's redesign, mock 616 quick-try-v2, then the owner's feedback on the built one):
// the wizards' modal over the app, like onboarding (#/try, #/try/AGENT; the app stays visible behind the scrim; Esc or
// Close returns to where it was opened). Two panes: on the left a search box (`doz search`'s matching + fuzzy,
// core/agent-search.js), the filter pills (Ready · Open source · Current · Headless · Through a gateway — AND), the
// count and the cards/list toggle (remembered), then the results, superseded last; on the right the chosen agent,
// INFORMATION ONLY (what a published recipe page shows: description, versions, tags, what it can reach, the command)
// and a Try button. Try opens the SETUP — a smaller modal holding every prerequisite (the key, what is not offered,
// the image, the plan) and Start. Keyboard: / searches, ↑/↓ move through the results, Enter opens the setup. Below
// 760 px the panes stack (a back control).
//
// The same decisions as `doz try`: the host's planner (`POST plan`, purpose try) names it try-AGENT, gives it a NEW
// EMPTY folder of its own, Locked + its own model, the agent's own base and a key it can use. Browsing prepares
// NOTHING (owner: no build per recipe looked at); Start makes it with the ordinary `create` action (trial), starts it
// (the image prepared then, its progress in the terminal area) and opens its session. A try's page then offers
// Sleep · Delete · Keep (`tryBar`, views/sandbox.js).
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, mark } from '../dom/icons-2b30ba761d2d921b.js';
import { api } from '../core/api-2814f617dbd35bcd.js';
import { rank, suggest } from '../core/agent-search-a05f165f3681cc81.js';
import { actOrThrow, beginTransition, cancelTransition, prepRunning, waitOp } from '../core/operations-56949f5379c9806f.js';
import { secretEntryAllowed } from '../core/settings-e508eb68e0b62892.js';
import { state } from '../core/state-450cb6573a620304.js';
import { btn } from '../components/button-cbb8a60e3220f977.js';
import { callout } from '../components/callout-e7d97c36b36fe970.js';
import { startWithBootView } from '../components/lifecycle-924851199c461d50.js';
import { renderModal, wizardCloseRequest } from '../components/modal-8b94d803d636ec5e.js';
import { renderNavSandboxes } from '../components/nav-6f650ce2ca4e8409.js';
import { pageFailure, toast } from '../components/notices-0eac624a71d00e4f.js';
import { paintStartProgress } from '../components/start-progress-b16374ebc7173de4.js';
import { drawPendingTry } from './sandbox-f272187004699aa3.js';
import { planCommand, reachList } from '../components/plan-view-d5bc01e363272562.js';
import { modelPicker, noKeyNodes, resetModelSearch, sourceCommand, sourceList } from '../components/model-source-60dac846f8ef41a6.js';
import { prepCard } from '../components/prep-card-f04587dbc4728b29.js';

const AGENT_ID = /^[a-z0-9][a-z0-9-]{0,39}$/;
const VIEW_KEY = 'doz.tryView';
/// 617 (owner: "split them, also use tags to classify them"): the list is in two sections — coding agents and AI tools
/// (a segmented control; `tr.kind`) — and the filter pills are the declared CATEGORIES of that section (any of them:
/// OR), after Ready (its key is here). The capability tags stay searchable (`tag:headless`).
const READY = ['ready', 'Ready', (a) => !!a.ready];

/// "4 days" → "4 days ago"; "today" stays.
const ago = (age) => age === 'today' ? 'today' : age + ' ago';

function savedView() { try { return localStorage.getItem(VIEW_KEY) === 'list' ? 'list' : 'cards'; } catch (_) { return 'cards'; } }

// 617 (owner: "try now button in the UI creates a blank modal with a considerable delay … this needs to be an async
// step on the page which should load instantly"): the modal is drawn AT ONCE — the head, the search, the two sections,
// the pills — with the list of the last open (kept for the page's life) or skeleton cards, and fills in by itself:
// the list (`GET try/list`: from the recipes, milliseconds), then the plans (`GET try`: readiness — Ready, the key
// card, the image — and what each can reach; one reading of the store for all of them). One read at a time
// (`tr.reader`, an AbortController — closing the modal cancels it); a failure is said in the list, with Retry; while
// it loads the list never says "nothing matches". `tr.stage`: loading (nothing yet) · list · full — `data-try-state`.
let CACHE = null;
/// Before the first list arrives: the two sections as tags.json names them (the list's own words replace them).
const FIRST_KINDS = [{ id: 'coding-agent', title: 'Coding agents', meaning: '' }, { id: 'ai-tool', title: 'AI tools', meaning: '' }];
const NOTHING_YET = { agents: [], coming: [], kinds: FIRST_KINDS, categories: [], secretEntry: false };

/// The modal's view (the router passes the agent of `#/try/AGENT`). Never waits for the server.
export async function viewTry() {
  const want = state.tryAgent && AGENT_ID.test(state.tryAgent) ? state.tryAgent : null;
  const old = state.tr;
  if (!old) {
    state.tr = { asked: want, catalog: CACHE ? CACHE.catalog : NOTHING_YET, stage: CACHE ? CACHE.stage : 'loading', reader: null, loadError: '',
      agent: null, error: '', creating: false, kind: 'coding-agent', q: '', f: new Set(), view: savedView(), detail: !!want };
    choose(state.tr, want);
    load(state.tr, true);
  } else {
    // The search, the section, the pills, the view and the pane survive (a key saved, Check again, #/try/AGENT).
    if (old.asked !== want) { old.asked = want; choose(old, want); if (want) old.detail = true; }
    if (old.stage !== 'full' && !old.reader) load(old, false);
  }
  return tryNode();
}

/// The agent shown: the one asked for (its section with it), else the one chosen if the list still has it, else the
/// section's first ready one, else its first.
function choose(tr, want) {
  const c = tr.catalog;
  // 618: a family's card is its recommended major — another major asked for (#/try/opencode2) is that card, with its
  // Version chosen in the setup.
  const cards = c.agents.filter((a) => !a.family || a.family.recommended);
  let named = c.agents.find((a) => a.id === want) || c.coming.find((a) => a.id === want);
  if (named && named.family && !named.family.recommended) {
    tr.version = named.id;
    named = cards.find((a) => a.family && a.family.name === named.family.name) || named;
  }
  if (named && named.catalogKind) tr.kind = named.catalogKind;
  if (named) { tr.agent = named.id; return; }
  if (tr.agent && (cards.some((a) => a.id === tr.agent) || c.coming.some((a) => a.id === tr.agent))) return;
  const first = cards.find((a) => a.catalogKind === tr.kind && a.ready) || cards.find((a) => a.catalogKind === tr.kind) || cards[0] || null;
  tr.agent = first ? first.id : null;
}

/// Read the list (unless one is there), then the plans — drawn in place as each arrives. `fresh`: a new open, so
/// the plans are read again even when the kept list has them (a key may have been added since).
async function load(tr, fresh) {
  if (tr.reader) return;
  if (!fresh && tr.stage === 'full') return;
  const ctl = new AbortController();
  tr.reader = ctl;
  tr.loadError = '';
  const live = () => state.tr === tr && !ctl.signal.aborted;
  try {
    if (tr.stage === 'loading') {
      const list = await api('try/list', { signal: ctl.signal });
      if (!live()) return;
      take(tr, list, 'list');
    }
    const whole = await api('try', { signal: ctl.signal });
    if (!live()) return;
    take(tr, whole, 'full');
  } catch (e) {
    if (ctl.signal.aborted || state.tr !== tr) return;
    tr.loadError = e.message || String(e);
    if (state.modal === 'try') paint({});
  } finally {
    if (tr.reader === ctl) tr.reader = null;
  }
}

function take(tr, catalog, stage) {
  CACHE = { catalog, stage };
  tr.catalog = catalog;
  tr.stage = stage;
  choose(tr, tr.agent || tr.asked);
  if (state.modal === 'try') paint({});
}

function retryLoad() { const tr = state.tr; if (tr) { tr.loadError = ''; paint({}); load(tr, true); } }

/// Agents (and the coming ones) as the search sees them — a family once (618: its recommended major's card; the
/// setup's Version choice reaches the others).
function entries() {
  const c = state.tr.catalog;
  // 617: the declared kind and categories search as tags too (tag:terminal-tool).
  const words = (x) => [...(x.categories || []), ...(x.catalogKind ? [x.catalogKind] : [])];
  return [...c.agents.filter((a) => !a.family || a.family.recommended).map((a) => ({ ...a, kind: 'agent', tags: [...(a.tags || []), ...words(a)] })),
    ...c.coming.map((x) => ({ ...x, kind: 'coming', tags: words(x), current: true }))];
}

/// 618: the majors of `a`'s family in the catalog, oldest first (empty: not a family).
function familyOf(a) {
  if (!a || !a.family || !state.tr) return [];
  return state.tr.catalog.agents.filter((x) => x.family && x.family.name === a.family.name).sort((x, y) => x.family.major - y.family.major);
}

/// 618: "also @1" — the other majors, for a card.
function alsoWords(a) {
  const others = familyOf(a).filter((x) => x.id !== a.id);
  return others.length ? 'also ' + others.map((x) => '@' + x.family.major).join(', ') : null;
}

/// 618: what a major is called — "OpenCode 1" (its family's title), else the tool's own.
function nameOf(a) { return a && a.family ? a.family.title : a ? a.title : ''; }

/// 618: the major chosen in its card's setup (the card itself until one is).
function chosenOf(card) { const tr = state.tr; return (tr && tr.version && familyOf(card).find((x) => x.id === tr.version)) || card; }

/// 618: a catalog agent by id — a family's other majors included (they have no card of their own).
function anyAgent(id) { return state.tr ? state.tr.catalog.agents.find((x) => x.id === id) : null; }

/// In the section shown (an entry with no kind shows in both).
function inKind(e, kind = state.tr.kind) { return !e.catalogKind || e.catalogKind === kind; }

/// The category pills of a section: those some entry of it has, in the vocabulary's order (not the section's own name).
function categoryPills(kind = state.tr.kind) {
  const have = new Set(entries().filter((e) => inKind(e, kind)).flatMap((e) => e.categories || []));
  return (state.tr.catalog.categories || []).filter((c) => have.has(c.id) && c.id !== kind);
}

/// Whether an entry passes the pills: Ready (an agent whose key is here), and ANY of the categories pressed.
function passes(e) {
  const tr = state.tr;
  if (tr.f.has('ready') && !(e.kind === 'agent' && READY[2](e))) return false;
  const cats = [...tr.f].filter((x) => x !== 'ready');
  return !cats.length || cats.some((c) => (e.categories || []).includes(c));
}

/// The results: the section's search matches that pass the pills — best match first, superseded and coming last.
function hits(kind = state.tr.kind) {
  const tr = state.tr;
  return entries().map((e, i) => ({ e, i, r: rank(e, tr.q) }))
    .filter(({ e, r }) => r > 0 && inKind(e, kind) && (kind !== tr.kind || passes(e)))
    .sort((x, y) => (x.e.kind === 'coming') - (y.e.kind === 'coming') || (x.e.current === false) - (y.e.current === false) || y.r - x.r || x.i - y.i)
    .map(({ e }) => e);
}

/// The other section's title and how many of its entries the search matches (a hint when the search is in use).
function otherKind() {
  const tr = state.tr;
  const k = (tr.catalog.kinds || []).find((x) => x.id !== tr.kind);
  return k ? { kind: k, n: tr.q.trim() ? hits(k.id).length : 0 } : null;
}

function switchKind(kind) {
  const tr = state.tr;
  if (tr.kind === kind) return;
  tr.kind = kind;
  tr.f = new Set([...tr.f].filter((x) => x === 'ready'));          // a category of the other section means nothing here
  const list = hits();
  if (list.length && !list.some((a) => a.id === tr.agent)) tr.agent = list[0].id;
  paint({});
}

function current() {
  const tr = state.tr;
  return tr && entries().find((a) => a.id === tr.agent);
}

function rerender() { if (state.modal === 'try') renderModal(false); }

/// 594's preparations arrive over SSE: the card of the chosen agent's image is drawn in place.
export function renderTryPrep() {
  const box = document.querySelector('[data-try-prep]');
  const a = current();
  if (!box || !a || a.kind !== 'agent' || !a.plan) return;
  box.replaceChildren(...prepNodes(a));
}

function prepNodes(a) {
  const p = (state.preps || []).find((x) => x.image === a.plan.image.name);
  if (p && (prepRunning(p) || p.error)) return [prepCard(p)];
  if (a.plan.image.state === 'unprepared' && !(p && p.state === 'done')) {
    return [h('span', null, (a.plan.image.title || a.plan.image.name) + ' — prepared when you press Start (minutes the first time; it needs the network); the progress shows in its terminal area.')];
  }
  return [h('span', { 'data-try-ready': '' }, (a.plan.image.title || a.plan.image.name) + ' — ready.')];
}

// ── the left pane ────────────────────────────────────────────────────────────

function select(id, opts = {}) {
  const tr = state.tr;
  if (tr.agent !== id) { tr.error = ''; tr.version = null; }
  const e = entries().find((x) => x.id === id);
  if (e && e.catalogKind && e.catalogKind !== tr.kind) { tr.kind = e.catalogKind; tr.f = new Set([...tr.f].filter((x) => x === 'ready')); }
  tr.agent = id;
  tr.asked = id; state.tryAgent = id;
  history.replaceState(null, '', '#/try/' + id);
  if (opts.detail) tr.detail = true;
  paint({ focusItem: !!opts.focusItem });
}

function resultItem(a) {
  const tr = state.tr, sel = a.id === tr.agent;
  const sub = a.kind === 'coming' ? 'coming' : [a.version, a.age ? ago(a.age) : null, a.current === false ? 'superseded' : null,
    // 618: a family's card — the recommended major (never "latest"), and the others its setup offers.
    a.family ? 'recommended' : null, alsoWords(a)].filter(Boolean).join(' · ');
  const b = h('button', { type: 'button', role: 'option', class: 'qt-item' + (a.current === false ? ' superseded' : '') + (a.kind === 'coming' ? ' coming' : ''),
    'aria-selected': String(sel), tabindex: sel ? '0' : '-1', 'data-try-agent': a.id, ...(a.kind === 'coming' ? { 'data-try-coming': a.id } : {}) },
    mark(a.icon),
    h('span', { class: 'tp' }, h('span', { class: 't' }, a.title), h('span', { class: 'p' }, a.publisher)),
    h('span', { class: 'v' }, sub),
    a.ready ? h('span', { class: 'ready', title: 'Its key is here: ready to start' }, icon('circle-check')) : h('span', { class: 'ready-gap' }));
  b.addEventListener('click', () => select(a.id, { detail: true }));
  return b;
}

/// While the list is read: placeholder cards (never "nothing matches"). A failed read: said here, with Retry.
function skeletonNodes() {
  return Array.from({ length: 9 }, () => h('div', { class: 'qt-item skeleton', 'aria-hidden': 'true', 'data-try-skeleton': '' },
    h('span', { class: 'sk sk-mark' }), h('span', { class: 'tp' }, h('span', { class: 'sk sk-line' }), h('span', { class: 'sk sk-line short' }))));
}

function loadErrorNode() {
  const tr = state.tr;
  if (!tr.loadError) return null;
  const retry = btn('Retry', retryLoad, { small: true, icon: 'refresh-cw' });
  retry.dataset.tryRetry = '';
  return callout('bad', { compact: true, cls: 'qt-error', attrs: { 'data-try-error': '' },
    title: tr.stage === 'loading' ? 'The agents could not be read' : 'Whether each one is ready could not be read', body: tr.loadError, actions: [retry] });
}

function resultsNodes() {
  const tr = state.tr;
  const err = loadErrorNode();
  if (tr.stage === 'loading') return err ? [err] : skeletonNodes();
  const list = hits();
  if (!list.length) {
    const s = suggest(tr.q, entries());
    return [err, h('div', { class: 'qt-empty', 'data-try-empty': '' },
      icon('search'),
      h('p', null, 'Nothing here matches' + (tr.q.trim() ? ' “' + tr.q.trim() + '”' : '') + (tr.f.size ? ' with these filters' : '') + '.'),
      (() => { const o = otherKind(); return o && o.n ? h('p', null, h('button', { type: 'button', class: 'linkish', 'data-try-other-kind': o.kind.id,
        on: { click: () => switchKind(o.kind.id) } }, o.n + ' in ' + o.kind.title)) : null; })(),
      s ? h('p', null, 'Did you mean ', h('button', { type: 'button', class: 'linkish', on: { click: () => { tr.q = s.id; tr.f.clear(); paint({ keepSearch: false }); } } }, s.title), '?') : null,
      btn('Clear search and filters', () => { tr.q = ''; tr.f.clear(); paint({ keepSearch: false }); }, { small: true, icon: 'x' }),
      h('p', { class: 'muted' }, 'Missing an agent? ', h('code', null, 'doz search NAME'), ' says whether it is coming.'))].filter(Boolean);
  }
  if (!list.some((a) => a.id === tr.agent)) tr.agent = list[0].id;
  return [err, ...list.map(resultItem)].filter(Boolean);       // (replaceChildren writes a null as "null")
}

function countText() {
  const tr = state.tr;
  const word = tr.kind === 'ai-tool' ? 'tools' : 'agents';
  if (tr.stage === 'loading') return tr.loadError ? '' : 'Reading the ' + word + '…';
  const all = entries().filter((e) => e.kind === 'agent' && inKind(e)).length;
  const list = hits(), agents = list.filter((e) => e.kind === 'agent').length;
  const base = !tr.q.trim() && !tr.f.size ? all + ' ' + word : agents + ' of ' + all + ' ' + word + (list.length > agents ? ' · ' + (list.length - agents) + ' coming' : '');
  const o = otherKind();
  return base + (o && o.n ? ' · ' + o.n + ' in ' + o.kind.title : '');
}

/// The two sections (a segmented control): each with how many it holds.
function kindNodes() {
  const tr = state.tr;
  return (tr.catalog.kinds || []).map((k) => {
    const n = entries().filter((e) => e.kind === 'agent' && e.catalogKind === k.id).length;
    return h('button', { type: 'button', 'aria-pressed': String(tr.kind === k.id), 'data-try-kind': k.id, title: k.meaning,
      on: { click: () => switchKind(k.id) } }, k.title, h('span', { class: 'n' }, tr.stage === 'loading' ? '' : String(n)));
  });
}

/// Ready, then the section's categories.
function pillNodes() {
  const tr = state.tr;
  const pill = (id, label, ic, title) => h('button', { type: 'button', class: 'qt-pill', 'aria-pressed': String(tr.f.has(id)), 'data-try-pill': id, title,
    on: { click: () => { if (tr.f.has(id)) tr.f.delete(id); else tr.f.add(id); paint({}); } } }, ic ? icon(ic) : null, label);
  return [pill(READY[0], READY[1], 'key-round', 'Its key is here: ready to start'),
    ...categoryPills().map((c) => pill(c.id, c.title, null, c.meaning))];
}

function leftPane() {
  const tr = state.tr;
  const input = h('input', { type: 'search', placeholder: 'Search agents — name, maker, tag:headless', autocomplete: 'off', spellcheck: 'false',
    'aria-label': 'Search agents', 'data-try-search': '', value: tr.q });
  input.addEventListener('input', () => { tr.q = input.value; paint({ keepSearch: true }); });
  input.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') {
      ev.preventDefault(); ev.stopPropagation();
      if (input.value) { input.value = ''; tr.q = ''; paint({ keepSearch: true }); } else wizardCloseRequest();
    }
  });
  const seg = h('span', { class: 'qt-seg', role: 'group', 'aria-label': 'View' },
    ...[['cards', 'Cards', 'layout-grid'], ['list', 'List', 'list']].map(([v, label, ic]) => h('button', { type: 'button', 'aria-label': label, title: label,
      'aria-pressed': String(tr.view === v), 'data-try-view': v,
      on: { click: () => { tr.view = v; try { localStorage.setItem(VIEW_KEY, v); } catch (_) { /* no storage: this visit only */ } paint({}); } } }, icon(ic))));
  return h('section', { class: 'qt-left', 'aria-label': 'Agents' },
    h('div', { class: 'qt-search' },
      h('div', { class: 'qt-kinds', role: 'group', 'aria-label': 'Coding agents or AI tools', 'data-try-kinds': '' }, ...kindNodes()),
      h('label', { class: 'qt-box' }, icon('search'), input, h('span', { class: 'qt-kbd', 'aria-hidden': 'true' }, '/')),
      h('div', { class: 'qt-pills', role: 'group', 'aria-label': 'Filters', 'data-try-pills': '' }, ...pillNodes()),
      h('div', { class: 'qt-bar' }, h('span', { 'data-try-count': '' }, countText()), h('span', { class: 'qt-gap' }), seg)),
    h('div', { class: 'qt-results ' + tr.view, role: 'listbox', 'aria-label': 'Agents', 'data-try-results': '' }, ...resultsNodes()));
}

// ── the right pane: information only ─────────────────────────────────────────
// 617 (owner): "similar to what we will eventually publish" — browsing is the first intention. What it is, its
// versions and tags, what it can reach and the command; no key, no plan form. Try opens the setup (below).

function sect(title, ...body) { return h('div', { class: 'qt-sect' }, h('h3', null, title), ...body); }

/// Tags no pill already says (its other capabilities), as the directory names them.
const TAG_WORDS = { 'api-key': 'an API key', 'vendor-sign-in': 'its maker’s sign-in', 'multi-vendor-models': 'many models', 'no-account': 'no account',
                    'free-tier': 'a free tier', status: 'reports its status', resume: 'resumes a conversation', musl: 'runs on Alpine' };

function detailNodes() {
  const tr = state.tr, a = current();
  const back = btn('All agents', () => { tr.detail = false; paint({}); }, { small: true, quiet: true, icon: 'arrow-left' });
  back.classList.add('qt-back');
  if (!a && tr.stage === 'loading') {
    return [back, h('div', { class: 'qt-loading', 'aria-hidden': 'true', 'data-try-loading': '' },
      h('span', { class: 'sk sk-mark lg' }), h('span', { class: 'sk sk-line' }), h('span', { class: 'sk sk-line' }), h('span', { class: 'sk sk-line short' }))];
  }
  if (!a) return [back, h('div', { class: 'qt-empty' }, h('p', null, 'Nothing selected.'))];
  const head = h('div', { class: 'qt-head' }, mark(a.icon, 'lg'),
    h('div', null, h('h2', { 'data-try-title': '' }, a.title), h('div', { class: 'p' }, a.publisher + (a.kind === 'agent' ? ' · ' + (a.openSource ? 'open source' : 'closed source') : ''))));
  if (a.kind === 'coming') {
    return [back, head, callout('info', { body: 'Coming — ' + a.reason }),
      h('p', { class: 'muted' }, 'Dozer cannot run it yet. ', h('code', null, 'doz search ' + a.id), ' says when that changes.')];
  }
  const facts = h('div', { class: 'qt-facts' },
    h('span', { class: 'tag ' + (a.current === false ? 'warn' : 'ok') }, a.current === false ? 'superseded' : 'current'),
    a.headless ? h('span', { class: 'tag outline' }, 'headless') : null,
    a.gateway ? h('span', { class: 'tag outline' }, 'through a gateway') : null,
    ...(a.tags || []).filter((t) => TAG_WORDS[t]).map((t) => h('span', { class: 'tag outline', 'data-try-tag': t }, TAG_WORDS[t])));
  const by = a.supersededBy && state.tr.catalog.agents.find((x) => x.id === a.supersededBy);
  const standing = a.current === false
    ? callout('warn', { attrs: { 'data-try-standing': a.id }, title: by ? 'Superseded by ' + by.title : 'Not current with its maker',
      body: h('span', null, (a.standing || '').replace(/^Superseded by [^—]*—\s*/, '') + ' ', by ? h('button', { type: 'button', class: 'linkish', on: { click: () => select(by.id, { detail: true }) } }, 'See ' + by.title) : null) })
    : null;
  const versions = h('dl', { class: 'qt-plan' },
    h('dt', null, 'Dozer installs'), h('dd', { 'data-try-latest': a.id }, (a.version || '—') + (a.age ? ' · released ' + ago(a.age) : '')),
    a.latest ? h('dt', null, 'Its newest') : null, a.latest ? h('dd', { class: 'muted' }, a.latest.replace(/^latest:?\s*/, '')) : null,
    h('dt', null, 'Base'), h('dd', null, a.base || '—'),
    // 618: a family's majors — each one Dozer checked; Try's Version picks one.
    ...(familyOf(a).length > 1 ? [h('dt', null, 'Majors'), h('dd', { 'data-try-majors': '' },
      familyOf(a).map((x) => x.family.title + (x.version ? ' ' + x.version : '') + (x.family.recommended ? ' (recommended)' : '')).join(' · ')
        + ' — Try lets you choose')] : []));
  const shown = chosenOf(a);                                    // 618: the major chosen in its setup
  const tryBtn = btn('Try ' + nameOf(shown) + '…', () => openSetup(a), { primary: true, lg: true, icon: 'rocket', title: 'Set it up and start it (Enter)' });
  tryBtn.dataset.tryOpen = '';
  // The list alone (no plan yet): what it can reach and its command follow with the plans; Try waits for them.
  const planning = (what) => h('p', { class: 'muted', 'data-try-planning': '' }, tr.loadError ? 'Not read: ' + tr.loadError : 'Reading ' + what + '…');
  if (!shown.plan) { tryBtn.disabled = true; tryBtn.title = 'Reading its plan…'; }
  return [back, head, facts,
    a.description ? h('p', { class: 'qt-desc', 'data-try-description': '' }, a.description) : null,
    standing,
    sect('Versions', versions),
    sect('What it can reach', shown.plan ? reachList(shown.plan.reach) : planning('what it can reach')),
    sect('The same, in a terminal', shown.plan ? planCommand(shown.plan) : planning('its command')),
    h('div', { class: 'qt-foot' }, h('span', { class: 'qt-gap' }), h('span', { class: 'qt-note' }, 'Enter'), tryBtn)].filter(Boolean);   // (replaceChildren writes a null as "null")
}

// ── Try: the setup — a smaller modal over the Quick try ──────────────────────
// 617 (owner): every prerequisite lives here — the key (one there, one saved now, one kept outside: the command),
// what is not offered (a sign-in, a gateway), the image, the plan — and the final Start. Cancel (or Esc) leaves
// nothing behind. Later: customising the try (the clipboard bridge off, …) gets a section of its own here.
//
// The key that did not work (owner): a key saved for an agent the provider's DEFAULT account cannot serve (pi, whose
// Anthropic default is the Mac's Claude Code login — pi takes API keys only) was saved, then the plan asked the
// default again and still found none. The setup now plans WITH the account it uses — the one just saved, one chosen,
// or (the default being unusable) the first usable one — as `doz try` does ("this try uses it").

// 617 (owner: "add OpenAI and Anthropic AND gateway support"): an agent whose recipe speaks several APIs (models@1) gets
// a Model section — the provider or gateway (its key only ever goes there) and the model (empty: that source's
// default) — and the key part follows the source chosen: its accounts, or a paste saved as that source's key.
const SETUP = { d: null, a: null, plan: null, account: null, source: null, model: '', busy: false, error: '', adding: false };

/// The accounts the agent can use — of the model source chosen, when it has a choice — the provider's default first.
function usable(a) {
  const src = SETUP.plan && SETUP.plan.model ? SETUP.plan.model.source : null;
  return [...(a.usableAccounts || [])].filter((x) => !src || !x.modelSource || x.modelSource === src)
    .sort((x, y) => (y.isDefault ? 1 : 0) - (x.isDefault ? 1 : 0));
}

async function replan(account) {
  const a = SETUP.a;
  SETUP.account = account || null;
  SETUP.plan = await api('plan', { method: 'POST', json: { purpose: 'try', agent: a.ref || a.id, ...(account ? { account } : {}),
    ...(SETUP.source ? { source: SETUP.source } : {}), ...(SETUP.model ? { model: SETUP.model } : {}) } });
}

/// The source chosen (the plan's): its entry of the offered list.
function chosenSource(plan) {
  const m = plan && plan.model;
  return m ? (m.offered || []).find((x) => x.id === m.source) || null : null;
}

/// 617 (models@1): the provider or gateway it talks to, and the model — only for an agent that can use more than one.
/// 618 (owner: "make sure there is a way the user can chose an earlier major version"): a family's majors, the
/// recommended one first chosen. Choosing one RE-PLANS only (POST plan with its ref) — the catalog is never read again.
function versionNodes(a) {
  const fam = familyOf(a);
  if (fam.length < 2) return [];
  // The recommended major first, then the others newest first; the chosen one is the segmented control's `.active`.
  const order = [...fam].sort((x, y) => (y.family.recommended ? 1 : 0) - (x.family.recommended ? 1 : 0) || y.family.major - x.family.major);
  const seg = h('div', { class: 'segmented try-versions', role: 'group', 'aria-label': 'Version', 'data-try-version': a.id },
    ...order.map((x) => h('button', { type: 'button', class: 'seg' + (x.id === a.id ? ' active' : ''), 'aria-pressed': String(x.id === a.id), 'data-try-version-choice': x.id,
      title: x.family.recommended ? 'The major Dozer recommends' : 'An earlier (or other) major',
      on: { click: () => chooseVersion(x) } }, x.id === a.id ? icon('check') : null,
      x.family.title + (x.version ? ' · ' + x.version : '') + (x.family.recommended ? ' (recommended)' : ''))));
  return [seg, h('p', { class: 'muted' }, 'A sandbox keeps the major it is made with — the other one is a new try.')];
}

async function chooseVersion(x) {
  if (!SETUP.a || SETUP.a.id === x.id || SETUP.busy) return;
  SETUP.a = x; SETUP.source = null; SETUP.model = ''; SETUP.error = '';
  if (state.tr) state.tr.version = x.family && x.family.recommended ? null : x.id;
  try {
    // Its own plan, with a key it can use (another major may take other keys).
    const u = usable(x);
    SETUP.plan = x.plan || SETUP.plan;
    await replan(x.plan && keyProblem(x.plan) && u.length ? u[0].name : null);
  } catch (e) { SETUP.error = e.message || String(e); }
  paintSetup();
  if (state.modal === 'try') paint({});                          // the details pane behind follows the choice
}

/// 618 (owner: "open router should be part of the key choices; needs rethink" — mockup try-model-source): ONE section,
/// "Where TOOL gets its model": its providers and the gateways as equal rows, each with its key status; the chosen row
/// holds its key (or a choice of keys, or a paste field); then the model picker (the source's own list).
function keysBySource(a) {
  const all = a.usableAccounts || [];
  return (id) => all.filter((x) => x.modelSource === id).sort((x, y) => (y.isDefault ? 1 : 0) - (x.isDefault ? 1 : 0));
}

function sourceSections(a, plan, missing) {
  const m = plan.model, keysOf = keysBySource(a), tool = nameOf(a);
  const card = a.card || null;
  const notOffered = card && card.notOffered && card.notOffered.length ? 'Not offered: ' + card.notOffered.join(' · ') : null;
  const list = sourceList({ tool, sources: m.offered, chosen: m.source, keysOf, onChoose: chooseSource,
    needFor: (id) => sourceNeed(plan, m.offered.find((x) => x.id === id), keysOf(id)), notOffered });
  const out = [sect('Where ' + tool + ' gets its model',
    ...(m.offered.length > 1 ? [h('p', { class: 'muted ms-lead' }, 'Its own provider is chosen; any other — or a gateway — works the same way.')] : []), ...list)];
  if (!missing) {
    out.push(sect('Model', modelPicker({ source: m.source, title: m.title, gateway: m.gateway, current: m.model, onPick: chooseModel })));
  }
  return out;
}

/// 618: a tool with ONE source and no choice of model (Grok Build: an xAI key, checked by the tool at start-up) — the same
/// section as one line (the source and its key status); its key part below. Claude Code and Codex (their own sign-ins and
/// subscriptions) keep their Key section.
function keyOnly(a) {
  return !!a.provider && !['claude-code', 'codex'].includes(a.id)
    && (a.usableAccounts || []).every((x) => ['api-key', 'openai-key', 'key'].includes(x.kind));
}

function oneSourceSection(a, plan, missing) {
  const src = { id: a.provider, title: a.providerTitle || a.provider, gateway: false, defaultModel: null };
  const keys = usable(a);
  const nodes = sourceList({ tool: nameOf(a), sources: [src], chosen: src.id, keysOf: () => keys, onChoose: () => {},
    needFor: () => keyNodes(a, plan, missing) });
  if (!missing && keys.length > 1) nodes.push(keyNodes(a, plan, null)[1]);
  return [sect('Where ' + nameOf(a) + ' gets its model', ...nodes)];
}

/// What the chosen source needs: the key it uses (a choice when there are several, another one added), else a paste.
function sourceNeed(plan, src, keys) {
  if (!src) return [];
  if (src.accountKind === 'none') return noKeyNodes(src);          // 618: OpenCode Zen's free models — no key
  const acc = plan.account;
  if (keys.length && !SETUP.adding) {
    let line;
    if (keys.length > 1) {
      const sel = h('select', { 'aria-label': 'The key this try uses', 'data-try-account': '' },
        ...keys.map((x) => h('option', { value: x.name }, x.name + (x.source ? ' — ' + x.source : '') + (x.isDefault ? ' (default)' : ''))));
      sel.value = (acc && keys.some((x) => x.name === acc.name)) ? acc.name : keys[0].name;
      sel.addEventListener('change', async () => { await replan(sel.value).catch((e) => { SETUP.error = e.message || String(e); }); paintSetup(); });
      line = h('div', { class: 'ms-keyline' }, icon('key-round'), h('span', null, 'Key'), sel);
    } else {
      line = h('div', { class: 'ms-keyline', 'data-try-key-ok': '' }, icon('key-round'), h('span', null, 'Uses ', h('strong', null, keys[0].name),
        ' — ' + (keys[0].source || 'Keychain') + ' · the sandbox only ever sees a placeholder'));
    }
    return [line, h('div', null, btn('Add another key', () => { SETUP.adding = true; paintSetup(); }, { small: true, quiet: true, icon: 'plus' }))];
  }
  return pasteNodes(src, keys.length > 0);
}

function pasteNodes(src, adding) {
  const a1 = /^[AEIOUx]/.test(src.title) ? 'an ' : 'a ';
  const nodes = [];
  if (secretEntryAllowed()) {
    const field = h('input', { type: 'password', autocomplete: 'off', spellcheck: 'false', 'data-try-key': '',
      placeholder: 'paste your ' + src.title + ' key' + (src.keyHint ? ' (' + src.keyHint + '…)' : ''), 'aria-label': 'Paste ' + a1 + src.title + ' key' });
    const save = btn('Save the key', () => saveKey(field, save), { small: true, icon: 'key-round' });
    field.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); saveKey(field, save); } });
    nodes.push(h('div', { class: 'try-paste' }, field, save),
      h('div', { class: 'muted ms-small' }, 'Kept in this Mac’s keychain; the sandbox only ever sees a placeholder.',
        src.keysPage ? [' Get one at ', h('strong', null, src.keysPage.replace(/^https?:\/\//, '')), '.'] : null));
  } else {
    nodes.push(h('div', { class: 'muted ms-small', 'data-secret-why': '1' }, 'Pasting keys here is off (ui.allow_secret_entry) — in a terminal on this Mac:'),
      h('code', { class: 'ms-cmd' }, 'doz account add NAME ' + (src.accountKind === 'api-key' ? '--api-key' : src.accountKind === 'openai-key' ? '--openai-key' : '--provider ' + src.id)));
  }
  nodes.push(h('details', { class: 'ms-other' }, h('summary', null, 'Keep it in 1Password, AWS or a program instead'),
    h('code', { class: 'ms-cmd' }, sourceCommand(src.id, src.accountKind)),
    h('div', { class: 'muted ms-small' }, 'or --from aws:arn:… or --from-command \'…\' — then Check again.'),
    h('div', null, btn('Check again', () => recheck(), { small: true, quiet: true, icon: 'refresh-cw' }))));
  if (adding) nodes.push(h('div', null, btn('Keep the key it has', () => { SETUP.adding = false; paintSetup(); }, { small: true, quiet: true })));
  return nodes;
}

/// Another source: its default (or only) key, else none — then its row asks for one. The tool's own source is
/// planned without a flag (the default needs no choice).
async function chooseSource(id) {
  const m = SETUP.plan && SETUP.plan.model;
  SETUP.source = m && m.offered[0] && m.offered[0].id === id ? null : id;
  SETUP.model = ''; SETUP.error = ''; SETUP.adding = false;
  const keys = keysBySource(SETUP.a)(id);
  SETUP.source = SETUP.source || (keys.length ? null : id);
  await replan(keys.length ? keys[0].name : null).catch((e) => { SETUP.error = e.message || String(e); });
  paintSetup();
}

/// A model from the picker (its default: no flag), or an id as typed.
async function chooseModel(id, isDefault) {
  SETUP.model = isDefault ? '' : id; SETUP.error = '';
  const acc = SETUP.plan && SETUP.plan.account;
  await replan(SETUP.account || (acc && acc.name) || null).catch((e) => { SETUP.error = e.message || String(e); });
  paintSetup();
}

function whyNoKey(plan) { const t = plan.model.title; return 'Save ' + (/^[AEIOUx]/.test(t) ? 'an ' : 'a ') + t + ' key, or choose a source that has one'; }

function keyProblem(plan) { return (plan.problems || []).find((p) => p.code === 'key'); }

async function openSetup(card) {
  // 618: another major asked for by its link (#/try/opencode2): the setup opens on it (its Version chosen).
  const asked = state.tr && state.tr.version ? anyAgent(state.tr.version) : null;
  const a = asked && familyOf(card).some((x) => x.id === asked.id) && asked.plan ? asked : card;
  if (!a.plan) return;                                            // the list alone: its plan is still being read
  if (SETUP.d && SETUP.d.open) return;
  if (SETUP.d) { SETUP.d.remove(); SETUP.d = null; }      // closed, its (asynchronous) close event not yet run
  SETUP.a = a; SETUP.plan = a.plan; SETUP.account = null; SETUP.source = null; SETUP.model = ''; SETUP.busy = false; SETUP.error = ''; SETUP.adding = false;
  resetModelSearch();
  const d = h('dialog', { class: 'dlg try-setup', 'aria-labelledby': 'try-setup-title', 'data-try-setup': card.id });
  d.addEventListener('close', () => { d.remove(); if (SETUP.d === d) SETUP.d = null; });
  SETUP.d = d;
  document.body.append(d);
  d.showModal();
  // The default cannot serve it, but a key it can use is here: use that one.
  const u = usable(a);
  if (keyProblem(a.plan) && u.length) { try { await replan(u[0].name); } catch (e) { SETUP.error = e.message || String(e); } }
  paintSetup();
}

function paintSetup() {
  const d = SETUP.d, a = SETUP.a, plan = SETUP.plan;
  if (!d) return;
  const missing = keyProblem(plan);
  const blocked = (plan.problems || []).filter((p) => p.code !== 'key');
  const close = h('button', { type: 'button', class: 'btn sm quiet icon-only', title: 'Cancel', 'aria-label': 'Cancel', on: { click: () => d.close() } }, icon('x'));
  const start = btn('Start', () => tryCreate(start), { primary: true, icon: 'rocket' });
  start.dataset.tryCreate = '';
  start.disabled = !!missing || blocked.length > 0 || SETUP.busy;
  const cancel = btn('Cancel', () => d.close(), { quiet: true, icon: 'x' });
  d.replaceChildren(h('form', { method: 'dialog', on: { submit: (ev) => { ev.preventDefault(); if (!start.disabled) tryCreate(start); } } },
    h('div', { class: 'dlg-head' }, mark(a.icon), h('h2', { class: 'h-title', id: 'try-setup-title' }, 'Try ' + nameOf(a)), close),
    h('div', { class: 'dlg-body' },
      h('p', { class: 'sub' }, 'A fresh sandbox, ' + plan.name + ': a new empty folder of its own, the network locked to its model, your key never inside.'),
      ...(familyOf(a).length > 1 ? [sect('Version', ...versionNodes(a))] : []),
      ...(plan.model && plan.model.offered && plan.model.offered.length ? sourceSections(a, plan, missing) : keyOnly(a) ? oneSourceSection(a, plan, missing) : [sect('Key', ...keyNodes(a, plan, missing))]),
      sect('Image', h('div', { class: 'try-prep', 'data-try-prep': '' }, ...prepNodes({ ...a, plan }))),
      sect('The plan', planFacts(a, plan)),
      ...blocked.map((p) => callout('bad', { compact: true, body: p.text + (p.fix ? ' — ' + p.fix : '') })),
      SETUP.error ? callout('bad', { compact: true, attrs: { 'data-try-error': '' }, body: SETUP.error }) : null),
    h('div', { class: 'dlg-foot dlg-buttons' }, h('span', { class: 'why' }, missing ? (plan.model ? whyNoKey(plan) : 'Add a key first') : ''), cancel, start)));
  const f = d.querySelector('[data-try-key]');
  (f || (start.disabled ? cancel : start)).focus();
}

/// The key part: the one this try uses (and, when it can use several, a choice), or what it needs.
function keyNodes(a, plan, missing) {
  const u = usable(a);
  const nodes = [];
  if (!missing) {
    const acc = plan.account;
    nodes.push(h('p', { class: 'try-key', 'data-try-key-ok': '' }, icon('circle-check'), ' ',
      acc && acc.name ? h('strong', null, acc.name) : 'none needed', acc && acc.sourceLabel ? ' — ' + acc.sourceLabel : '',
      acc && acc.name ? ' — the sandbox only ever sees a placeholder.' : ''));
    if (u.length > 1) {
      const sel = h('select', { 'aria-label': 'The key this try uses', 'data-try-account': '' },
        ...u.map((x) => h('option', { value: x.name }, x.name + (x.source ? ' — ' + x.source : '') + (x.isDefault ? ' (default)' : ''))));
      sel.value = (acc && acc.name) || u[0].name;
      sel.addEventListener('change', async () => { await replan(sel.value).catch((e) => { SETUP.error = e.message || String(e); }); paintSetup(); });
      nodes.push(h('label', { class: 'field' }, h('span', null, 'Use another key'), sel));
    }
    return nodes;
  }
  // 617 (models@1): another provider or a gateway than the agent's own — a key of THAT source.
  const src = chosenSource(plan);
  if (src && src.id !== a.provider) return sourceKeyNodes(src, missing);
  const c = a.card;
  if (!c) return [callout('bad', { compact: true, body: missing.text + (missing.fix ? ' — ' + missing.fix : '') })];
  nodes.push(h('h4', null, c.title));
  for (const o of c.options) {
    if (o.kind === 'paste') {
      if (secretEntryAllowed()) {
        const field = h('input', { type: 'password', autocomplete: 'off', spellcheck: 'false', 'data-try-key': '', placeholder: 'paste the key', 'aria-label': o.label });
        const save = btn('Save the key', () => saveKey(field, save), { small: true, icon: 'key-round' });
        field.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); saveKey(field, save); } });
        nodes.push(h('div', { class: 'try-option' }, h('div', null, h('strong', null, o.label), h('div', { class: 'muted' }, o.consequence)), h('div', { class: 'try-paste' }, field, save)));
      } else {
        nodes.push(h('div', { class: 'try-option' }, h('strong', null, o.label), h('div', { class: 'muted' }, 'Pasting keys here is off (ui.allow_secret_entry) — in a terminal on this Mac:'),
          h('code', null, c.addCommand || 'doz account add NAME')));
      }
    } else if (o.kind === 'source') {
      nodes.push(h('div', { class: 'try-option' }, h('strong', null, o.label), h('div', { class: 'muted' }, o.consequence + ' — set up in a terminal on this Mac:'),
        h('code', null, (c.addCommand || 'doz account add NAME') + ' --from op://VAULT/ITEM/FIELD'),
        h('div', { class: 'muted' }, 'or --from aws:arn:… or --from-command \'…\'; then press Check again.')));
    } else {
      nodes.push(h('div', { class: 'try-option' }, h('strong', null, o.label), h('div', { class: 'muted' }, o.consequence)));
    }
  }
  for (const n of c.notOffered) nodes.push(h('div', { class: 'try-option not-offered', 'data-try-not-offered': '' }, h('strong', null, 'Not offered here'), h('div', { class: 'muted' }, n)));
  if (c.getKey) nodes.push(h('p', { class: 'muted' }, c.getKey));
  nodes.push(h('div', null, btn('Check again', () => recheck(), { small: true, quiet: true, icon: 'refresh-cw' })));
  return [h('div', { class: 'try-need', 'data-try-need': '' }, ...nodes)];
}

/// 617 (models@1): no key of the chosen source yet — paste one (saved as that source's account), or the command.
function sourceKeyNodes(src, missing) {
  const a1 = /^[AEIOUx]/.test(src.title) ? 'An ' : 'A ';           // an OpenAI, an xAI
  const nodes = [h('h4', null, a1 + src.title + ' key')];
  if (secretEntryAllowed()) {
    const field = h('input', { type: 'password', autocomplete: 'off', spellcheck: 'false', 'data-try-key': '',
      placeholder: src.keyHint ? 'paste the key (' + src.keyHint + '…)' : 'paste the key', 'aria-label': 'Paste ' + a1.toLowerCase() + src.title + ' key' });
    const save = btn('Save the key', () => saveKey(field, save), { small: true, icon: 'key-round' });
    field.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); saveKey(field, save); } });
    nodes.push(h('div', { class: 'try-option' }, h('div', null, h('strong', null, 'Paste ' + a1.toLowerCase() + src.title + ' key'),
      h('div', { class: 'muted' }, 'Kept in this Mac\'s keychain as an account; the sandbox only ever sees a placeholder.')),
    h('div', { class: 'try-paste' }, field, save)));
  } else {
    nodes.push(h('div', { class: 'try-option' }, h('div', { class: 'muted' }, 'Pasting keys here is off (ui.allow_secret_entry) — in a terminal on this Mac:'),
      h('code', null, missing.fix || 'doz account add NAME --provider ' + src.id)));
  }
  nodes.push(h('div', null, btn('Check again', () => recheck(), { small: true, quiet: true, icon: 'refresh-cw' })));
  return [h('div', { class: 'try-need', 'data-try-need': '' }, ...nodes)];
}

/// A pasted key: saved as an account of the provider (a free name), then THIS try plans with it.
async function saveKey(field, button) {
  const a = SETUP.a;
  const secret = field.value.trim();
  field.value = '';                                   // emptied before the request
  if (!secret || SETUP.busy) return;
  button.disabled = true;
  SETUP.error = '';
  try {
    // 617 (models@1): the chosen source's key when the agent can use several (its kind: api-key, openai-key or key).
    const src = chosenSource(SETUP.plan);
    const p = src ? src.id : a.provider;
    const kind = src ? src.accountKind : p === 'anthropic' ? 'api-key' : p === 'openai' ? 'openai-key' : 'key';
    const taken = new Set(((await api('accounts')).accounts || []).map((x) => x.name));
    const base = p || a.id;
    let name = base;
    for (let n = 2; taken.has(name); n++) name = base + '-' + n;
    await api('accounts', { method: 'POST', json: { name, kind, secret, ...(kind === 'key' ? { provider: p } : {}) } });
    toast('Key saved — ' + name + ' (' + (src ? src.title : a.providerTitle || p) + ')');
    SETUP.adding = false;
    // The source's row reads the agent's usable accounts: the key just saved is one of them now (the owner's "kept
    // asking for a key" — the plan used it, the row still read the list from before), until the catalog is read again.
    SETUP.a = { ...a, usableAccounts: [...(a.usableAccounts || []),
      { name, kind, source: null, isDefault: false, modelSource: src ? src.id : p }] };
    await replan(name);
    refreshCatalog(a.id);
  } catch (e) { SETUP.error = e.message || String(e); }
  paintSetup();
}

/// Check again (a key set up in a terminal): the catalog read again, and the try planned with a key it can use.
async function recheck() {
  SETUP.error = '';
  try {
    const catalog = await api('try');
    take(state.tr, catalog, 'full');
    const a = catalog.agents.find((x) => x.id === SETUP.a.id) || SETUP.a;
    SETUP.a = a;
    if (SETUP.source || SETUP.model) {
      // A source or model chosen: plan with it again (a key added in a terminal is that source's default now).
      await replan(null);
    } else {
      SETUP.plan = a.plan;
      const u = usable(a);
      if (keyProblem(a.plan) && u.length) await replan(u[0].name);
    }
    paint({});
  } catch (e) { SETUP.error = e.message || String(e); }
  paintSetup();
}

/// The catalog read again; an open setup of `id` takes its agent from it (the accounts as the host lists them).
function refreshCatalog(id) {
  api('try').then((catalog) => {
    if (state.tr) take(state.tr, catalog, 'full');
    const fresh = id && catalog.agents.find((x) => x.id === id);
    if (!fresh || !SETUP.d || !SETUP.a || SETUP.a.id !== id) return;
    // Repainted only when the accounts differ (a repaint moves the focus — the model search may be in use).
    const names = (x) => (x.usableAccounts || []).map((u) => u.name).sort().join(',');
    const differ = names(fresh) !== names(SETUP.a);
    SETUP.a = fresh;
    if (differ) paintSetup();
  }).catch(() => { /* the list stays */ });
}

function planFacts(a, p) {
  const lines = (kind) => p.reach.filter((r) => r.kind === kind).map((r) => r.text);
  const fact = (k, v) => [h('dt', null, k), h('dd', null, v)];
  return h('dl', { class: 'qt-plan try-facts' },
    ...fact('Name', p.name),
    // 618: which major and release ("OpenCode 1 · 1.19.0").
    ...fact('Version', nameOf(a) + ' · ' + ((p.version && p.version.version) || a.version || '—')),
    ...fact('Base', a.base || '—'),
    // 617 (models@1): the model and where its key goes; the network line then names no single host.
    ...(p.model ? fact('Model', keyProblem(p) ? p.model.title + ' — once its key is saved' : p.model.model + ' through ' + p.model.title) : []),
    ...fact('Network', p.model ? 'Locked — only its model providers' : 'Locked — only its model (' + (lines('model')[0] || 'its model') + ')'),
    ...fact('Folder', lines('folder')[0] || '—'),
    ...fact('Your Mac', lines('bridge').join(' · ') || '—'),
    // 618: what Start makes, as a command.
    ...fact('Same in Terminal', h('code', { 'data-try-command': '' }, p.command)));
}

/// Start → the ordinary `create` action (a try: `trial`, its new folder, the account the setup chose), then the start
/// with the boot view, which opens its own session in a terminal on its page.
/// 617 (owner, 2026-10-15: "fix the delay when clicking … There should be immediate feedback and … the try browser /
/// detail modals should close"): the click's own frame disables Start with a spinner, closes both modals and goes to
/// the try's page, which draws its header and the build panel ("Preparing…") from the plan (`state.pendingTry`) while
/// the create runs behind it (it was ~0.1–1 s, and the page then read the overview and the sandbox before it moved). A
/// failure before the sandbox exists (a name taken, a key refused, a version missing) stays on that page with Back to
/// setup, which reopens the setup with the error.
async function tryCreate(button) {
  const a = SETUP.a, plan = SETUP.plan;
  if (!a || SETUP.busy) return;
  SETUP.busy = true;
  button.disabled = true;
  button.setAttribute('aria-busy', 'true');
  button.replaceChildren(h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), h('span', null, 'Starting…'));
  const c = plan.create, name = plan.name;
  state.pendingTry = { name, agent: a.id, title: a.title, image: c.image, imageTitle: plan.image && plan.image.title,
    workspace: c.workspace || null, account: plan.account && plan.account.name, network: c.network || 'locked',
    plan, account_: SETUP.account, error: null, at: Date.now() };
  beginTransition(name, 'start', ['start']);
  renderNavSandboxes();
  if (SETUP.d) SETUP.d.close();
  state.tr = null;
  location.hash = '#/sandbox/' + name;
  try {
    const op = await actOrThrow({ action: 'create', sandbox: name, image: c.image, trial: true,
      ...(c.network ? { network: c.network } : {}), ...(c.workspace ? { workspace: c.workspace } : { isolated: true }),
      ...(c.account ? { account: c.account } : {}),
      ...(c.modelSource ? { modelSource: c.modelSource } : {}), ...(c.model ? { model: c.model } : {}) });
    const end = await waitOp(op.id);
    if (!end || end.state !== 'done') throw new Error((end && end.text) || 'the try was not made');
    // The nav lists it, then its own page takes over from the plan's (the start keeps the transition and the panel).
    try { state.overview = await api('overview'); renderNavSandboxes(); } catch (_) { /* the next poll */ }
    const p = state.pendingTry;
    if (p && p.name === name) state.pendingTry = null;
    startWithBootView(name);
  } catch (e) {
    const p = state.pendingTry;
    if (p && p.name === name) p.error = e.message || String(e);
    cancelTransition(name, 'start');
    renderNavSandboxes();
    SETUP.busy = false;
    upcallRepaint(name);
  }
}

/// The try's page repaints what it shows of a failed create (the header and the panel).
function upcallRepaint(name) {
  if (state.view === 'sandbox' && state.param === name) { drawPendingTry(name); paintStartProgress(); }
}

/// 617: Back to setup — Quick try on the agent, its setup reopened with the plan and the error it had.
export function backToTrySetup() {
  const p = state.pendingTry;
  if (!p) return;
  state.pendingTry = null;
  location.hash = '#/try/' + p.agent;
  const until = Date.now() + 15000;
  const again = () => {
    const tr = state.tr;
    const a = tr && tr.catalog.agents.find((x) => x.id === p.agent);
    if (a && a.plan && state.modal === 'try') {
      openSetup(a).then(() => { SETUP.plan = p.plan; SETUP.account = p.account_; SETUP.error = p.error; paintSetup(); });
      return;
    }
    if (Date.now() < until) setTimeout(again, 100);
  };
  again();
}

// ── the page ─────────────────────────────────────────────────────────────────

/// Redraw what the search, the pills, the view or the choice changed — in place, so the search box keeps its focus.
function paint(opts) {
  const root = document.querySelector('[data-qt]');
  if (!root) { rerender(); return; }
  const tr = state.tr;
  const results = root.querySelector('[data-try-results]');
  results.className = 'qt-results ' + tr.view;
  results.replaceChildren(...resultsNodes());
  root.querySelector('[data-try-count]').textContent = countText();
  root.querySelector('[data-try-pills]').replaceChildren(...pillNodes());
  root.querySelector('[data-try-kinds]').replaceChildren(...kindNodes());
  for (const b of root.querySelectorAll('[data-try-view]')) b.setAttribute('aria-pressed', String(tr.view === b.dataset.tryView));
  const search = root.querySelector('[data-try-search]');
  if (opts.keepSearch === false) search.value = tr.q;
  root.querySelector('[data-try-detail]').replaceChildren(...detailNodes());
  root.dataset.detail = tr.detail ? '1' : '';
  root.dataset.tryState = tr.stage;
  if (opts.focusItem) { const s = results.querySelector('[aria-selected="true"]'); if (s) { s.focus(); s.scrollIntoView({ block: 'nearest' }); } }
  if (current()) root.dataset.try = current().id;
}

function onKey(ev) {
  const tr = state.tr;
  const t = ev.target;
  const inSearch = t.matches && t.matches('[data-try-search]');
  const inField = !inSearch && t.closest && t.closest('input, textarea, select, [contenteditable]');
  if (ev.key === '/' && !inSearch && !inField) {
    ev.preventDefault();
    const s = document.querySelector('[data-try-search]'); if (s) s.focus();
    return;
  }
  if ((ev.key === 'ArrowDown' || ev.key === 'ArrowUp') && !inField) {
    const list = hits(); if (!list.length) return;
    ev.preventDefault();
    const i = list.findIndex((a) => a.id === tr.agent);
    const next = list[(i + (ev.key === 'ArrowDown' ? 1 : list.length - 1)) % list.length];
    select(next.id, { focusItem: !inSearch });
    return;
  }
  // Enter = Try (the setup opens; Start is there).
  if (ev.key === 'Enter' && !inField && (inSearch || (t.closest && t.closest('[data-try-results]')))) {
    const s = document.querySelector('[data-try-open]');
    if (s && !s.disabled) { ev.preventDefault(); s.click(); }
  }
}

function tryNode() {
  const tr = state.tr;
  const close = btn('Close', () => wizardCloseRequest(), { title: 'Close (Esc)', icon: 'x' });
  close.classList.add('qt-close');
  close.dataset.wmClose = '';
  close.append(h('span', { class: 'qt-kbd', 'aria-hidden': 'true' }, 'Esc'));
  const head = h('header', { class: 'qt-mhead' },
    h('div', null, h('h1', { id: 'wm-title' }, 'Quick try'),
      h('p', { class: 'sub' }, 'Pick an agent and try it in a fresh sandbox: its own folder, the network locked to its model, your key never inside. Nothing is prepared until you press Start.')),
    close);
  if (tr.stage !== 'loading' && !tr.catalog.agents.length && !tr.catalog.coming.length) {
    return h('div', { class: 'wizard try qt-page' }, head, callout('info', { body: 'No agent this Dozer can try.' }));
  }
  const root = h('div', { class: 'qt', 'data-qt': '', 'data-detail': tr.detail ? '1' : '', 'data-try-state': tr.stage },
    leftPane(),
    h('section', { class: 'qt-right', 'aria-live': 'polite', 'aria-label': 'The chosen agent', 'data-try-detail': '' }, ...detailNodes()));
  if (current()) root.dataset.try = current().id;
  root.addEventListener('keydown', onKey);
  return h('div', { class: 'wizard try qt-page' }, head, root);
}

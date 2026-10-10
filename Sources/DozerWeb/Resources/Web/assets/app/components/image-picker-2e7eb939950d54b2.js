// components/image-picker — The image of a new sandbox — Agent × Base (596).
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, withIcon } from '../dom/icons-75c107270d336b51.js';
import { AGENT_NAMES, AGENTS, imageNameOf, parseImageName } from '../core/agents-66154a04b9c4696c.js';
import { api } from '../core/api-0a712b05e0caf823.js';
import { bytes } from '../core/format-b2e68384da8d2f36.js';
import { actOrThrow, waitOps } from '../core/operations-c7eeae66c46d4582.js';
import { isRemote } from '../core/session-54591f6f727fe191.js';
import { btn } from './button-72d87e1085f00b4e.js';
import { callout } from './callout-48fdacc012091bbe.js';

export function imagePicker({ images = [], bases = null, value = 'claude-code', dockerfile = '', onChange = () => {}, onDockerfile = () => {} }) {
  const catalogue = bases ? bases.bases : [];
  const ids = catalogue.map((b) => b.id);
  const templates = images.filter((i) => i.kind === 'custom');
  const parsed = parseImageName(value, ids);
  let agent = parsed ? parsed.agent : 'claude-code', base = parsed ? parsed.base : 'node';
  let kind = dockerfile ? 'dockerfile' : parsed || !templates.some((t) => t.name === value) ? 'recommended' : 'template';
  let template = templates.some((t) => t.name === value) ? value : (templates[0] ? templates[0].name : '');
  let builder = bases ? bases.builder : { state: 'missing', note: '', startNote: '', installNote: '' };
  let notNow = false;
  const changed = () => { paint(); onChange(); };
  // Agent.
  const agentSegs = {};
  const agentCtl = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Agent', 'data-agent-choice': '' },
    AGENTS.map(([a, label]) => (agentSegs[a] = h('button', { type: 'button', class: 'seg', 'data-agent': a, on: { click: () => { agent = a; changed(); } } },
      withIcon(a === 'none' ? 'terminal' : 'rocket', label)))));
  // Base kind.
  const kindSegs = {};
  const kindSeg = (k, label, ic, extra = {}) => (kindSegs[k] = h('button', { type: 'button', class: 'seg', 'data-base-kind': k, ...extra,
    on: { click: () => { if (!extra.disabled) { kind = k; changed(); } } } }, withIcon(ic, label)));
  const kindCtl = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Base' },
    kindSeg('recommended', 'Recommended', 'star'), kindSeg('dockerfile', 'Dockerfile', 'box'),
    templates.length ? kindSeg('template', 'Template', 'layout-template') : null);
  // Recommended: a card per base.
  const cards = {};
  const grid = h('div', { class: 'base-grid', role: 'radiogroup', 'aria-label': 'Recommended bases', 'data-base-grid': '' },
    catalogue.map((b) => (cards[b.id] = h('button', { type: 'button', class: 'base-card', role: 'radio', 'data-base': b.id,
      on: { click: () => { base = b.id; changed(); } } },
      h('span', { class: 'base-title' }, b.title),
      h('span', { class: 'base-use' }, b.useCase),
      h('code', { class: 'base-ref' }, b.reference),
      h('span', { class: 'base-meta', 'data-base-meta': '' }, '↓ ' + bytes(b.downloadBytes) + ' · first prepare ~' + Math.max(1, Math.round(b.prepareSeconds / 60)) + ' min'),
      h('span', { class: 'base-prepared', 'data-base-prepared': '' }),
      b.updateAvailable ? h('span', { class: 'tag ver-available' }, 'update available') : null))));
  // Dockerfile.
  const dfPath = h('input', { type: 'text', name: 'dockerfile', 'data-dockerfile-path': '', placeholder: '~/code/app/Dockerfile', autocomplete: 'off',
                              spellcheck: 'false', 'aria-label': 'Dockerfile' });
  dfPath.value = dockerfile;
  const dfChoose = h('button', { type: 'button', class: 'btn sm', 'data-dockerfile-choose': '', title: 'Opens the Mac’s file picker' },
    withIcon('folder', 'Choose Dockerfile…'));
  const policyNote = callout('warn', { compact: true, cls: 'df-policy', icon: 'shield', role: 'note', attrs: { 'data-dockerfile-policy': '' }, body: bases ? bases.outsidePolicy : '' });
  const builderBox = h('div', { class: 'df-builder', 'data-builder': '' });
  const dfError = h('div', { class: 'dlg-error', role: 'alert', 'data-dockerfile-error': '' });
  const dfFail = (e) => { dfError.textContent = e ? e.message || String(e) : ''; };
  const dfPanel = h('div', { class: 'df-panel' },
    h('div', { class: 'ws-row' }, dfPath, isRemote() ? null : dfChoose),
    h('small', { class: 'muted' }, 'Dozer builds it with Apple’s container build, then adds the developer baseline and the agent — your Dockerfile need not install Claude Code. Its folder is the build context, and the workspace unless you set one.'),
    policyNote, builderBox, dfError);
  const dfTell = () => { onDockerfile(dfPath.value.trim() ? dfPath.value.trim().replace(/\/[^/]*$/, '') || '/' : ''); };
  dfPath.addEventListener('input', () => { onChange(); });
  dfPath.addEventListener('change', dfTell);
  dfChoose.addEventListener('click', async () => {
    dfChoose.disabled = true;
    try {
      const r = await api('dockerfile/choose', { method: 'POST', json: dfPath.value.trim() ? { start: dfPath.value.trim() } : {} });
      if (r && r.path) { dfPath.value = r.path; onDockerfile(r.folder); onChange(); }
      dfFail(null);
    } catch (e) { dfFail(e); } finally { dfChoose.disabled = false; }
  });
  async function refreshBuilder() {
    try { const b = await api('bases'); builder = b.builder; } catch (_) { /* keep */ }
    paint(); onChange();
  }
  function paintBuilder() {
    const s = builder.state;
    const kids = [h('p', { class: 'df-state', 'data-builder-state': s }, icon(s === 'ready' ? 'check' : 'box'), ' ', builder.note)];
    if (notNow && s !== 'ready') {
      kids.push(h('p', { class: 'muted', 'data-builder-notnow': '' }, 'Dockerfile images are unavailable until Apple’s container tool is ' + (s === 'stopped' ? 'running' : 'installed') + ' — or choose a recommended base.'),
        btn('Set it up now…', () => { notNow = false; paint(); onChange(); }, { small: true, icon: 'settings' }));
    } else if (s === 'stopped') {
      kids.push(h('p', { class: 'muted' }, builder.startNote),
        h('div', { class: 'actions' },
          btn('Start its services', async () => { try { dfFail(null); await actOrThrow({ action: 'builder-start' }); await waitOps(); } catch (e) { dfFail(e); } refreshBuilder(); },
            { small: true, primary: true, icon: 'play' }),
          btn('Not now', () => { notNow = true; paint(); onChange(); }, { small: true, icon: 'x' })));
    } else if (s !== 'ready') {
      kids.push(h('p', { class: 'muted' }, builder.installNote),
        h('div', { class: 'actions' },
          btn('Install Apple’s container tool…', async () => { try { dfFail(null); await actOrThrow({ action: 'builder-install' }); } catch (e) { dfFail(e); } setTimeout(refreshBuilder, 1500); },
            { small: true, primary: true, icon: 'download' }),
          btn('Not now', () => { notNow = true; paint(); onChange(); }, { small: true, icon: 'x' })));
    }
    builderBox.replaceChildren(...kids);
  }
  // Templates.
  const tplSelect = h('select', { name: 'template', 'aria-label': 'Template' }, templates.map((t) => h('option', { value: t.name }, t.name + (t.fromSandbox ? ' (from ' + t.fromSandbox + ')' : ''))));
  tplSelect.value = template;
  tplSelect.addEventListener('change', () => { template = tplSelect.value; onChange(); });
  const tplPanel = h('div', { class: 'tpl-panel' }, tplSelect, h('small', { class: 'muted' }, 'A template is a saved root disk: its base and agent are the ones it was saved from.'));
  const summary = h('small', { class: 'muted image-summary', 'data-image-summary': '' });
  // The image by its name, too (hidden): what a script or an older page names — setting it moves the choices.
  const names = [...new Set(['claude-code', 'pi', 'lab', ...catalogue.flatMap((b) => AGENTS.map(([a]) => imageNameOf(b.id, a))), ...templates.map((t) => t.name)])];
  const byName = h('select', { name: 'image', hidden: true, 'aria-hidden': 'true', tabindex: '-1' }, names.map((n) => h('option', { value: n }, n)));
  byName.addEventListener('change', () => {
    const p = parseImageName(byName.value, ids.length ? ids : ['node', 'alpine']);
    if (p) { agent = p.agent; base = p.base; kind = 'recommended'; } else if (templates.some((t) => t.name === byName.value)) { kind = 'template'; template = byName.value; tplSelect.value = template; }
    changed();
  });
  function paint() {
    for (const [a, b] of Object.entries(agentSegs)) { b.classList.toggle('active', a === agent); b.setAttribute('aria-pressed', a === agent ? 'true' : 'false'); b.disabled = kind === 'template'; }
    for (const [k, b] of Object.entries(kindSegs)) { b.classList.toggle('active', k === kind); b.setAttribute('aria-pressed', k === kind ? 'true' : 'false'); }
    for (const [id, c] of Object.entries(cards)) {
      c.classList.toggle('active', id === base);
      c.setAttribute('aria-checked', id === base ? 'true' : 'false');
      const b = catalogue.find((x) => x.id === id);
      c.querySelector('[data-base-prepared]').textContent = b && b.prepared.includes(agent) ? 'prepared' : '';
    }
    grid.hidden = kind !== 'recommended';
    dfPanel.hidden = kind !== 'dockerfile';
    tplPanel.hidden = kind !== 'template';
    paintBuilder();
    const b = catalogue.find((x) => x.id === base);
    const now = kind === 'template' ? template : kind === 'dockerfile' ? null : imageNameOf(base, agent);
    if (now && [...byName.options].some((o) => o.value === now)) byName.value = now;
    summary.textContent = kind === 'template' ? 'Template ' + template
      : kind === 'dockerfile' ? 'Your Dockerfile · ' + (AGENTS.find((x) => x[0] === agent) || [0, agent])[1]
      : (b ? b.title : base) + ' · ' + (AGENTS.find((x) => x[0] === agent) || [0, agent])[1] + ' — image ' + imageNameOf(base, agent);
  }
  paint();
  const el = h('div', { class: 'field image-picker' },
    h('span', null, 'Agent'), agentCtl,
    h('span', null, 'Base'), kindCtl, grid, dfPanel, tplPanel, summary, byName);
  return {
    el,
    /// The image name the host is sent (a Dockerfile's: the agent's carrier — the host names it by its file).
    image() { return kind === 'template' ? template : kind === 'dockerfile' ? (agent === 'none' ? 'lab' : agent) : imageNameOf(base, agent); },
    /// The agent a sandbox of it runs (for the account's choice).
    agent() {
      if (kind === 'template') { const t = templates.find((x) => x.name === template); return t ? AGENT_NAMES[t.agent] ? t.agent : (parseImageName(t.agent || '', ids) || {}).agent : null; }
      return agent === 'none' ? null : agent;
    },
    dockerfile() { return kind === 'dockerfile' ? dfPath.value.trim() : null; },
    /// 597: the catalogue base (a Dockerfile's: '', a template's: null) — its permissions' Standard.
    base() { return kind === 'recommended' ? base : kind === 'dockerfile' ? '' : null; },
    /// Why Create cannot go ahead now (null: it can).
    blocked() {
      if (kind === 'template' && !template) return 'No template to start from.';
      if (kind !== 'dockerfile') return null;
      if (!dfPath.value.trim()) return 'Choose the Dockerfile (Choose Dockerfile…), or type its path.';
      if (notNow && builder.state !== 'ready') return 'Dockerfile images are unavailable until Apple’s container tool is ' + (builder.state === 'stopped' ? 'running.' : 'installed.');
      return null;
    },
  };
}
/// What a new sandbox's suggested name follows: the image, or for a Dockerfile "dockerfile-claude" (→ dockerfile-claude-sandbox).
export function pickerNameHint(picker) {
  if (picker.dockerfile() === null) return picker.image();
  const a = picker.agent();
  return 'dockerfile' + (a === 'claude-code' ? '-claude' : a ? '-' + a : '');
}

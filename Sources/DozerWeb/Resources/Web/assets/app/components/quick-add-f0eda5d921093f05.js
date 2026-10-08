// components/quick-add — Quick add (599c): a sandbox with every default, started and opened.
import { api } from '../core/api-1817573a49f0ab85.js';
import { act, actOrThrow, waitOp } from '../core/operations-d824956fc29841f7.js';
import { bootViewOnStart, setting, terminalsAllowed } from '../core/settings-171e705abeccb983.js';
import { state } from '../core/state-6efaa5d4aa08116b.js';
import { btn } from './button-8e61dd531eed2262.js';
import { createDialog } from './create-dialog-2f1bed7f0e6e5b6f.js';
import { startWithBootView } from './lifecycle-fb038e14f2670db4.js';
import { pageFailure, toast } from './notices-89b8886740537e92.js';
import { openTerminal } from './terminal-154bdbfa793b8202.js';

// ── 599c: Quick add (owner: "a "Quick Add" sandbox that picks defaults for workspace name etc and opens
// it immediately") — one click, no form: the default image (defaults.image), a free name (claude-sandbox,
// -2, …), its workspace <defaults.projects_dir>/<name> (made), the default account and permissions;
// created, started with the boot view, its page open. What one click cannot decide (the agent's
// account, an out-of-date image) opens New sandbox with the requirement said.
function quickAddTitle() {
  return 'One click: a ' + setting('defaults.image', 'lab') + ' sandbox with a free name, its folder in ' + setting('defaults.projects_dir', '~/dozer-sandbox-workspaces') + ' — started and opened';
}
export function quickAddButton() {
  const b = btn('Quick add', (ev) => quickAdd(ev.currentTarget), { icon: 'rocket', title: quickAddTitle() });
  b.dataset.quickAdd = '';
  return b;
}
export async function quickAdd(button) {
  if (state.quickAdding) return;
  state.quickAdding = true;
  const buttons = [...document.querySelectorAll('[data-quick-add]')];
  for (const b of buttons) b.disabled = true;
  try {
    const p = await api('quick-add', { method: 'POST', json: {} });
    if (p.requirement) { createDialog({ why: p.requirement, kind: p.requirementKind, image: p.image }); return; }
    const op = await actOrThrow({ action: 'create', sandbox: p.name, image: p.image, ...(p.workspace ? { workspace: p.workspace } : { isolated: true }) });
    const end = await waitOp(op.id);
    if (!end || end.state !== 'done') return;        // a failure is said by the operation's own toast
    toast('Quick add: ' + p.name + ' · ' + p.image + ' · ' + (p.workspace || 'isolated'));
    if (bootViewOnStart()) { await startWithBootView(p.name); return; }
    location.hash = '#/sandbox/' + p.name;
    const started = await act({ action: 'start', sandbox: p.name });
    if (started && terminalsAllowed()) {
      const s = await waitOp(started.id, 600000);
      if (s && s.state === 'done' && state.view === 'sandbox' && state.param === p.name) openTerminal(p.name, null, 'interactive');
    }
  } catch (e) {
    pageFailure('Quick add: ' + (e.message || String(e)), { key: 'quick-add' });
  } finally {
    state.quickAdding = false;
    for (const b of document.querySelectorAll('[data-quick-add]')) b.disabled = false;
    if (button && button.isConnected) button.disabled = false;
  }
}

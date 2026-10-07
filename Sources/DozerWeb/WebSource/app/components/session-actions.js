// components/session-actions — End session / Restart session (a terminal tab's menu, the inspector's
// Sessions tab). Each is ONE action (session-end / session-restart → one host operation). A restart keeps
// the pane: its socket's end is not "the session ended" but "restarting", and once the operation is done
// the pane reattaches (its scrollback kept) to the same session, now running again.
import { state } from '../core/state.js';
import { terminals } from '../core/terminals.js';
import { actOrThrow, waitForOp } from '../core/operations.js';
import { dialog } from './dialog.js';
import { keepScrollback, paintCover, reattachTerminals } from './terminal.js';
import { failureFor } from './notices.js';

const AGENT_SESSIONS = { claude: 'Claude Code', codex: 'Codex', pi: 'pi' };

/// The agent a session runs, when it is the sandbox's own agent session (its default session).
export function sessionAgent(name, session) {
  const s = state.sbx;
  const def = s && s.name === name && s.d ? s.d.defaultSession : null;
  return def && def === session ? AGENT_SESSIONS[session] || null : null;
}

function panesOf(name, session) {
  return [...terminals.values()].filter((t) => t.sandbox === name && t.session === session && !t.closed && !t.saved);
}

/// The menu items for one running session (`opts.disabled`: why they cannot run now).
export function sessionMenuItems(name, session, why) {
  return [
    { label: 'Restart session', icon: 'rotate-ccw', desc: sessionAgent(name, session) ? 'Start it again — the conversation continues' : 'End its program and start it again',
      disabled: !!why, why, onSelect: () => restartSessionDialog(name, session) },
    { label: 'End session', icon: 'power', danger: true, desc: 'Its program stops (hung up, then terminated)', disabled: !!why, why, onSelect: () => endSessionDialog(name, session) },
  ];
}

export function restartSessionDialog(name, session) {
  const agent = sessionAgent(name, session);
  const intro = agent
    ? agent + ' is stopped and started again in the same folder, continuing its last conversation. If it is in the middle of a turn, that turn is lost.'
    : 'Its program (' + session + ') is stopped and started again in the same folder. Whatever it is doing now is lost.';
  const fields = agent ? [{ name: 'fresh', type: 'checkbox', label: 'Start a new conversation instead', value: false }] : [];
  dialog('Restart ' + session + '?', intro, fields, 'Restart session', async (v) => {
    await restartSession(name, session, !!v.fresh);
  }, { icon: 'rotate-ccw' });
}

export function endSessionDialog(name, session) {
  const agent = sessionAgent(name, session);
  dialog('End ' + session + '?', (agent ? agent + ' stops' : 'Its program stops') + ' — hung up as when its terminal closes, then terminated if it must be. Whatever it is doing now is lost.',
    [], 'End session', async () => {
      const op = await actOrThrow({ action: 'session-end', sandbox: name, session });
      const done = await waitForOp(op, 60);
      if (done && done.state === 'failed') failureFor(name, done.text);
    }, { danger: true, icon: 'power' });
}

/// Restart: the panes on the session wait ("Restarting…") instead of ending, and reattach when it is back.
export async function restartSession(name, session, fresh) {
  const panes = panesOf(name, session);
  for (const t of panes) { t.restarting = true; t.ended = false; t.endText = ''; paintCover(t); }
  let done = null;
  try {
    const op = await actOrThrow({ action: 'session-restart', sandbox: name, session, fresh: fresh || undefined });
    done = await waitForOp(op, 120);
  } finally {
    for (const t of panes) {
      t.restarting = false;
      if (done && done.state === 'done' && !t.closed) { keepScrollback(t); t.ended = false; t.errorText = ''; t.disconnected = ''; t.reattach = true; }
      else if (!t.ws && !t.closed) { t.ended = true; t.endText = 'the restart did not finish'; }
      paintCover(t);
    }
    if (done && done.state === 'done') reattachTerminals();
    else if (done) failureFor(name, done.text);
  }
}

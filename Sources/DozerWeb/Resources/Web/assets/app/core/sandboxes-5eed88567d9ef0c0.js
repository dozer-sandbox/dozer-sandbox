// core/sandboxes — What the page knows of a sandbox: its phase, busy-ness, image, and the lifecycle verbs for a phase.
import { state } from './state-c0289349b457ba56.js';

export function opRunningFor(name) { return [...state.ops.values()].some((o) => o.sandbox === name && o.state === 'running'); }

// The owner's vocabulary (2026-09-25); aliases in the tooltips.
export const VERBS = {
  start: ['Start', 'Boot it (cold boot) — or wake / resume it'],
  pause: ['Pause', 'Suspend: guest CPU to 0 in ~1 ms, RAM kept'],
  resume: ['Resume', 'Run again after a pause'],
  sleep: ['Sleep', 'Pause + snapshot to disk: RAM kept, survives a host crash'],
  hibernate: ['Hibernate', 'Snapshot and stop the VM — RAM returned; wake in ~0.3 s'],
  wake: ['Wake', 'Back from sleep or hibernation, sessions where they were'],
  shutdown: ['Shut down', 'Cold stop, keeping the disk (running programs end)'],
  reset: ['Reset', 'Discard the disk — back to the image'],
  rm: ['Remove', 'Remove the sandbox and everything it has on disk'],
};
export const DESTRUCTIVE = {
  shutdown: 'Running programs end; the disk is kept.',
  reset: 'The root disk is discarded — everything installed or written since the image is gone. Restore points are kept.',
  rm: 'The sandbox, its disks, snapshot and restore points are deleted.',
};
export function verbsFor(phase) {
  switch (phase) {
    case 'off': return ['start'];
    case 'running': return ['pause', 'sleep', 'hibernate', 'shutdown'];
    case 'paused': return ['resume', 'sleep', 'hibernate', 'shutdown'];
    case 'asleep': return ['wake', 'hibernate', 'shutdown'];
    case 'hibernated': return ['wake', 'shutdown'];
    case 'failed': return ['start'];
    default: return [];
  }
}
/// 603 (E4): a Sandboxes row's actions — the one likely next verb (Start, Resume, Wake, Pause) as a quiet button,
/// the phase's other verbs in ⋯ (each with what it does). In a transition: the set shown when asked, disabled.
export const NEXT_VERB = { off: 'start', failed: 'start', paused: 'resume', asleep: 'wake', hibernated: 'wake', running: 'pause' };
/// The phases one wakes (or resumes) back into — the only ones with saved screens (owner, 2026-09-30:
/// a shut-down sandbox shows no session screens anywhere).
export const SAVED_PHASES = ['paused', 'asleep', 'hibernated'];
/// 603: the bar's lifecycle — the phase's verbs as ONE group (led by the primary for an off, failed, paused,
/// asleep or hibernated sandbox: Start, Resume or Wake; a running one has none) and Shut down apart, in red.
/// In a transition this page started: the buttons it showed when asked — disabled, never swapped.
export const PRIMARY_VERB = { off: 'start', failed: 'start', paused: 'resume', asleep: 'wake', hibernated: 'wake' };
export function sandboxImage(name) {
  if (state.sbx && state.sbx.name === name && state.sbx.d) return state.sbx.d.info.image || '';
  const row = state.overview && state.overview.sandboxes.find((s) => s.name === name);
  return row ? row.image || '' : '';
}
export function sandboxPhase(name) {
  if (state.sbx && state.sbx.name === name && state.sbx.d) return state.sbx.d.info.phase;
  const row = state.overview && state.overview.sandboxes.find((s) => s.name === name);
  return row ? row.phase : '';
}
export function sandboxBusy(name) {
  if (state.transitions.has(name)) return true;
  if (state.sbx && state.sbx.name === name && state.sbx.d) return !!state.sbx.d.info.busy || opRunningFor(name);
  const row = state.overview && state.overview.sandboxes.find((s) => s.name === name);
  return (row && row.busy) || opRunningFor(name);
}

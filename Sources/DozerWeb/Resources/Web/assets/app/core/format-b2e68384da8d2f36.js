// core/format — Formatting for people: sizes, durations, times, counts.


// ── formatting ──────────────────────────────────────────────────────────────
export function bytes(n) {
  if (n === undefined || n === null) return '—';
  if (n < 1024) return n + ' B';
  const u = ['KiB', 'MiB', 'GiB', 'TiB'];
  let v = n / 1024, i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (v >= 10 ? v.toFixed(0) : v.toFixed(1)) + ' ' + u[i];
}
export function mib(m) { return m ? bytes(m * 1048576) : '—'; }
export function ms(v) {
  if (v === undefined || v === null) return '—';
  if (v < 1) return v.toFixed(2) + ' ms';
  if (v < 1000) return Math.round(v) + ' ms';
  return (v / 1000).toFixed(v < 10000 ? 2 : 1) + ' s';
}
export function when(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  const s = (Date.now() - d.getTime()) / 1000;
  const abs = Math.abs(s);
  let rel;
  if (abs < 45) rel = 'just now';
  else if (abs < 3600) rel = Math.round(abs / 60) + ' min';
  else if (abs < 86400) rel = Math.round(abs / 3600) + ' h';
  else rel = Math.round(abs / 86400) + ' d';
  if (rel !== 'just now') rel = s >= 0 ? rel + ' ago' : 'in ' + rel;
  return rel;
}
export function clock(iso) { return iso ? new Date(iso).toLocaleTimeString() : '—'; }
export function full(iso) { return iso ? new Date(iso).toLocaleString() : '—'; }
export function plural(n, one, many) { return n + ' ' + (n === 1 ? one : many); }
// ── 595 (R9, owner: "show the shared block reuse size and percentage per image and use a different
// colour in the size bar … a legend in the bar column header Own / Shared"). Own = the blocks only this
// disk holds (what deleting it frees — Resources' "freed if deleted"); Shared = the blocks it reuses
// from the disk it was made from (APFS clones — 587's DiskAccounting). Each also as a % of its size.
export function pct(part, whole) { return whole > 0 && part != null ? Math.round((part / whole) * 100) + '%' : '—'; }
/// 594 (owner: "more progress detail"): ONE card for a host preparation — the wizard's Preparing step and
/// the Operations page both draw it — from the host's model (593's ProgressBoard: the step under way, the
/// transfer, the output's last lines; plus step N of M, the finished steps, the last run's times).
///   · overall: "Step N of M" and a DETERMINATE bar (steps done / M), about how long is left;
///   · the step under way: its label, its seconds, "usually ~X" — and an animated strip, never a full bar;
///   · a download: its own determinate bar with bytes, speed and time left;
///   · the output's last lines (guest text, already inert; cut to the width here);
///   · the finished steps (open in the wizard), ✓ with the time each took, ✕ with why and its last output.
export function dur(s) { return s == null ? '—' : s < 1 ? Math.round(s * 1000) + ' ms' : s < 60 ? (s < 10 ? s.toFixed(1) : Math.round(s)) + ' s' : Math.floor(s / 60) + ' min ' + Math.round(s % 60) + ' s'; }
export function approx(s) { return s < 60 ? '~' + Math.max(1, Math.round(s)) + ' s' : '~' + Math.round(s / 60) + ' min'; }

// ── the cover (the UI process derives it; this only draws it)
export function elapsedText(verb, since) {
  if (!verb || !since) return null;
  const s = Math.floor((Date.now() - new Date(since).getTime()) / 1000);
  if (s < 60) return null;
  const m = Math.floor(s / 60);
  if (m < 60) return verb + ' ' + m + ' min';
  const hr = Math.floor(m / 60);
  if (hr < 24) return verb + ' ' + hr + ' h';
  return verb + ' ' + Math.floor(hr / 24) + ' d';
}

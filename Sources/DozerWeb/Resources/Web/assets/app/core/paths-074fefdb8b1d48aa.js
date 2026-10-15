// core/paths — 617: how the page SHOWS a Mac path. A path under the Mac user's home reads `~/…` (never
// `/Users/<name>/…`); anything else as it is. Display only: what the page stores and sends stays absolute. The home
// (and its resolved spelling) comes with the session info (`homes`, the host's `DisplayPath`, which the CLI's lines use
// too). One helper for every place the page shows one: the sidebar's store, the try banner, the Guide's facts, the
// Overview and the details' workspace, a Dockerfile, the plan's lines, Doctor.
let HOMES = [];

/// The session info's homes, checked: absolute paths only, longest first.
export function setHomes(list) {
  HOMES = (Array.isArray(list) ? list : []).filter((h) => typeof h === 'string' && h.startsWith('/') && h !== '/' && h.length < 1024)
    .map((h) => (h.length > 1 && h.endsWith('/') ? h.slice(0, -1) : h))
    .sort((a, b) => b.length - a.length);
}

/// One path: `~` for home itself, `~/…` under it.
export function tildePath(p) {
  const s = String(p == null ? '' : p);
  for (const h of HOMES) {
    if (s === h) return '~';
    if (s.startsWith(h + '/')) return '~' + s.slice(h.length);
  }
  return s;
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/// Every home path inside a line of text (a host's sentence naming a folder) — only where a path starts.
export function tildeIn(text) {
  let out = String(text == null ? '' : text);
  for (const h of HOMES) {
    out = out.replace(new RegExp('(^|[^A-Za-z0-9_./~-])' + escapeRe(h) + '(?=/|$|[\\s,;:)\\]\'"])', 'g'), '$1~');
  }
  return out;
}

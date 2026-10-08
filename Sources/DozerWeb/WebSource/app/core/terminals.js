// core/terminals — The browser terminals' shared data (591, 593): every terminal, each sandbox page's panes.


// ── terminals (591) ─────────────────────────────────────────────────────────
// Browser terminals on the host's attach relay (591.01-DESIGN.md). Rules this section keeps:
//   · the engine (vendored ghostty-web 0.4.0, pinned by digest) runs ONLY in a sandboxed, opaque-origin
//     iframe per terminal (/terminal-frame, frame.js — owner ruling T2): it has no cookie, no API, no
//     CSRF token and can connect to nothing; this page owns the WebSocket and talks to the frame over a
//     narrow, checked postMessage protocol. One frame = one WASM instance (upstream #141);
//   · links are never opened (the frame drops Cmd/Ctrl clicks, and its sandbox has no popups);
//   · a paste is made safe HERE (Ghostty 1.3.0's encode: unsafe control characters become spaces),
//     confirmed when unsafe or large and refused over 1 MiB (CVE-2026-26982, upstream #193);
//   · the ticket lives only in connectTerminal's memory for the moment it takes to open the socket;
//   · guest text (a title, the ended line) is shown with textContent only;
//   · what wakes a sandbox is decided by the UI process (the 541 rule), never here: every key and
//     every report is sent, and the server says what it did.
export const terminals = new Map();
export const termUI = { built: false, by: {}, nextId: 1, dropped: 0 };
/// 593: each sandbox's page keeps its own split, selected tab per pane and focused pane.
export function sview(name) {
  if (!termUI.by[name]) termUI.by[name] = { split: false, selected: [null, null], focusedPane: 0 };
  return termUI.by[name];
}
export const PASTE_CONFIRM_BYTES = 64 * 1024;
export const PASTE_MAX_BYTES = 1024 * 1024;
export const INPUT_CHUNK = 16 * 1024;
export function pageTerminals(name) { return [...terminals.values()].filter((t) => !t.grid && t.sandbox === name); }

/// What a split adds on the right (the Split button's ▾ menu). Remembered per browser.
export const SPLIT_KINDS = {
  shell: 'new shell',
  watch: 'watch of the left terminal’s session (read-only)',
  attach: 'second view of the left terminal’s session (shared)',
  dialog: 'terminal you choose (New terminal…)',
};
termUI.splitKind = 'shell';   // until the settings load (ui.split_default)

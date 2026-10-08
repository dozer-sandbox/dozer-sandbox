// components/keyboard — Keyboard (603): arrow keys inside segmented controls and tab lists (roving tabindex).


// ── 603: keyboard — arrow keys inside segmented controls and tab lists move the focus (roving tabindex:
// the chosen one is the group's one Tab stop); Enter/Space chooses.
function rove(group) {
  const items = [...group.querySelectorAll(':scope > button, :scope > .tab-wrap > button.tab')].filter((b) => !b.hidden);
  if (!items.length) return;
  const cur = items.find((b) => b.getAttribute('aria-pressed') === 'true' || b.getAttribute('aria-selected') === 'true' || b.classList.contains('active')) || items[0];
  for (const b of items) b.tabIndex = b === cur ? 0 : -1;
}
function roveAll(root) { for (const g of root.querySelectorAll('.segmented, [role="tablist"]')) rove(g); }
new MutationObserver((list) => {
  const seen = new Set();
  for (const m of list) {
    const t = m.target instanceof Element ? m.target : m.target.parentElement;
    if (!t) continue;
    const g = t.closest('.segmented, [role="tablist"]');
    if (g) seen.add(g);
    for (const n of m.addedNodes) if (n instanceof Element) { if (n.matches('.segmented, [role="tablist"]')) seen.add(n); for (const x of n.querySelectorAll('.segmented, [role="tablist"]')) seen.add(x); }
  }
  for (const g of seen) rove(g);
}).observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['aria-pressed', 'aria-selected', 'class'] });
document.addEventListener('keydown', (ev) => {
  const t = ev.target;
  if (!(t instanceof HTMLElement) || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(ev.key) || ev.altKey || ev.metaKey || ev.ctrlKey) return;
  const g = t.closest('.segmented, [role="tablist"]');
  if (!g || !t.matches('button')) return;
  const items = [...g.querySelectorAll(':scope > button, :scope > .tab-wrap > button.tab')].filter((b) => !b.hidden && !b.disabled);
  const i = items.indexOf(t);
  if (i < 0) return;
  ev.preventDefault();
  const n = items.length;
  const next = ev.key === 'Home' ? items[0] : ev.key === 'End' ? items[n - 1] : items[(i + (ev.key === 'ArrowRight' ? 1 : n - 1)) % n];
  for (const b of items) b.tabIndex = b === next ? 0 : -1;
  next.focus();
});

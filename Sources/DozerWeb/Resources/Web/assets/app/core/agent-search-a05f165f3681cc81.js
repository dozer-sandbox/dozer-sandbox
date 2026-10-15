// core/agent-search — The Quick try's search (617, owner: "a search box at the top"): `doz search`'s matching
// (DozerKit DirectorySearch — every term must match: an exact id, alias or title; or, from 3 letters, the start of the
// id, an alias, a word of the title or of the publisher; `tag:X` needs that supported tag), then, for a term that
// does not match that way, fuzzy: the start of any word (so typing narrows as it goes), or its letters in order
// ("agy", "cdx"). Ranked: exact names, then `doz search` matches, then fuzzy; within a rank the catalog's order
// (current agents first, superseded last). Pure — no DOM.

const words = (s) => (s || '').toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);

/// `doz search`'s own test of one term (DirectorySearch.matches): 2 = exact, 1 = matches, 0 = no.
function searchMatch(e, t) {
  const title = e.title.toLowerCase();
  if (e.id === t || (e.aliases || []).includes(t) || title === t) return 2;
  if (t.length < 3) return 0;
  const hit = e.id.startsWith(t) || (e.aliases || []).some((a) => a.startsWith(t)) || words(e.title).some((w) => w.startsWith(t))
    || words(e.publisher).some((w) => w.startsWith(t));
  return hit ? 1 : 0;
}

/// Letters of `t` in order inside `s`.
function inOrder(s, t) {
  let i = 0;
  for (const c of s) { if (c === t[i]) i++; if (i === t.length) return true; }
  return t.length === 0;
}

/// Fuzzy: the start of a word, or (from 2 letters) the letters in order inside ONE word, starting with its first
/// letter ("agy" → antigravity, "cdx" → codex; "goo" is not "GitHub Copilot").
function fuzzyMatch(e, t) {
  const names = [...words(e.title), ...words(e.publisher), e.id, ...(e.aliases || [])];
  if (names.some((w) => w.startsWith(t))) return true;
  return t.length >= 2 && names.some((w) => w[0] === t[0] && inOrder(w, t));
}

/// The query's terms: words, `tag:X` apart (lower-cased, like SearchQuery.parse).
export function parseQuery(q) {
  const terms = [], tags = [];
  for (const w of (q || '').toLowerCase().split(/\s+/).filter(Boolean)) {
    if (w.startsWith('tag:')) { if (w.length > 4) tags.push(w.slice(4)); } else terms.push(w);
  }
  return { terms, tags };
}

/// How well `e` matches the query: 3 exact · 2 `doz search` · 1 fuzzy · 0 no (an empty query matches everything at 2).
export function rank(e, q) {
  const { terms, tags } = parseQuery(q);
  if (tags.length && !tags.every((t) => (e.tags || []).includes(t))) return 0;
  if (!terms.length) return 2;
  let best = 3;
  for (const t of terms) {
    const m = searchMatch(e, t);
    const r = m === 2 ? 3 : m === 1 ? 2 : fuzzyMatch(e, t) ? 1 : 0;
    if (!r) return 0;
    best = Math.min(best, r);
  }
  return best;
}

/// Levenshtein distance (DirectorySearch.distance).
function distance(a, b) {
  const x = [...a], y = [...b];
  if (!x.length) return y.length;
  if (!y.length) return x.length;
  let prev = Array.from({ length: y.length + 1 }, (_, j) => j);
  for (let i = 1; i <= x.length; i++) {
    const cur = [i];
    for (let j = 1; j <= y.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] === y[j - 1] ? 0 : 1));
    prev = cur;
  }
  return prev[y.length];
}

/// "Did you mean …?" for a query nothing matched (DirectorySearch.suggest): the closest id, alias or title's first word.
export function suggest(q, entries) {
  const t = parseQuery(q).terms[0];
  if (!t) return null;
  let best = null;
  for (const e of entries) {
    for (const n of [e.id, ...(e.aliases || []), words(e.title)[0] || e.id]) {
      const d = distance(t, n);
      if (d <= Math.max(1, Math.min(3, Math.floor(n.length / 3))) && (!best || d < best.d)) best = { e, d };
    }
  }
  return best ? best.e : null;
}

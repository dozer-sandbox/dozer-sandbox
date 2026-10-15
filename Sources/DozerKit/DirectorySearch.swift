import Foundation

// 617 (616.07) — `doz search [THING]`: is it supported here? Matching over the directory index (agents, key providers,
// bases), `tag:` terms and `--tag` (a capability tag, or — 617 — a kind or category: coding-agent, ai-tool, terminal-tool …),
// an optional base, and "did you mean" for a name nothing has. Pure (unit-tested).

public struct SearchQuery: Equatable, Sendable {
    public var terms: [String]
    public var tags: [String]
    /// The tag levels that count (default: supported — documented, verified).
    public var levels: Set<String>
    /// `--base B`: an agent that cannot run on it is `limited` there.
    public var base: String?

    public init(terms: [String] = [], tags: [String] = [], levels: Set<String> = ["documented", "verified"], base: String? = nil) {
        self.terms = terms
        self.tags = tags
        self.levels = levels
        self.base = base
    }

    /// `doz search grok tag:multi-vendor-models` → terms and tags (lower-cased).
    public static func parse(_ words: [String], tags: [String] = [], level: String? = nil, base: String? = nil) -> SearchQuery {
        var q = SearchQuery(base: base?.lowercased())
        for w in words.flatMap({ $0.split(separator: " ").map(String.init) }) where !w.isEmpty {
            let l = w.lowercased()
            if l.hasPrefix("tag:") { q.tags.append(String(l.dropFirst(4))) } else { q.terms.append(l) }
        }
        q.tags += tags.map { $0.lowercased() }
        if let level { q.levels = level == "any" ? Set(AgentRecipe.GatewaySupport.levels) : Set(level.split(separator: ",").map { String($0).lowercased() }) }
        return q
    }
}

public struct SearchHit: Equatable, Sendable {
    /// `supported` | `limited` | `coming` | `not-possible`.
    public var outcome: String
    /// Why it is limited here (`--base alpine`).
    public var limit: String?
    public var entry: DirectoryIndex.Entry
    public init(outcome: String, limit: String?, entry: DirectoryIndex.Entry) { self.outcome = outcome; self.limit = limit; self.entry = entry }
}

public struct SearchResult: Equatable, Sendable {
    public var hits: [SearchHit]
    /// "grok" for `grokk` — only when nothing matched.
    public var suggestion: String?

    /// `supported` (the best hit is) | `limited` | `coming` (or not possible) | `unknown` (nothing) — what a script checks.
    public var verdict: String {
        guard let best = hits.first else { return "unknown" }
        switch best.outcome {
        case "supported": return "supported"
        case "limited": return "limited"
        default: return "coming"
        }
    }
}

public enum DirectorySearch {
    static let rank = ["supported": 0, "limited": 1, "coming": 2, "not-possible": 3]

    public static func search(_ q: SearchQuery, in index: DirectoryIndex) -> SearchResult {
        func matches(_ e: DirectoryIndex.Entry, _ t: String) -> (Bool, exact: Bool) {
            let title = e.title.lowercased()
            if e.id == t || e.aliases.contains(t) || title == t { return (true, true) }
            guard t.count >= 3 else { return (false, false) }
            let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let hit = e.id.hasPrefix(t) || e.aliases.contains { $0.hasPrefix(t) } || words.contains { $0.hasPrefix(t) }
                || (e.publisher?.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(t) } ?? false)
            return (hit, false)
        }
        var found: [(SearchHit, Bool)] = []
        for e in index.entries {
            var exact = false
            if !q.terms.isEmpty {
                var all = true
                for t in q.terms {
                    let m = matches(e, t)
                    if !m.0 { all = false; break }
                    exact = exact || m.exact
                }
                guard all else { continue }
            }
            if !q.tags.isEmpty {
                // 617 (owner): a kind or a category (coding-agent, ai-tool, terminal-tool …) is declared — a coming entry has
                // them too; any other tag is a capability tag at the levels asked for.
                guard e.kind == "agent", q.tags.allSatisfy({ t in
                    Categories.word(t) != nil ? (e.catalogKind == t || (e.categories ?? []).contains(t))
                        : e.tags.contains { $0.tag == t && q.levels.contains($0.level) }
                }) else { continue }
            }
            var outcome = e.status
            var limit: String?
            if e.status == "supported", e.kind == "agent", let b = q.base, let l = e.limits.first(where: { $0.with["base"] == b }) {
                outcome = "limited"
                limit = l.reason
            }
            found.append((SearchHit(outcome: outcome, limit: limit, entry: e), exact))
        }
        // Exact names first, then by outcome, kind, id.
        let kind = ["agent": 0, "provider": 1, "base": 2]
        found.sort { a, b in
            if a.1 != b.1 { return a.1 }
            let ra = rank[a.0.outcome] ?? 9, rb = rank[b.0.outcome] ?? 9
            if ra != rb { return ra < rb }
            return (kind[a.0.entry.kind] ?? 9, a.0.entry.id) < (kind[b.0.entry.kind] ?? 9, b.0.entry.id)
        }
        var r = SearchResult(hits: found.map(\.0), suggestion: nil)
        if r.hits.isEmpty, let t = q.terms.first { r.suggestion = suggest(t, in: index) }
        return r
    }

    /// The closest name (id, alias or a title's first word) within a small edit distance.
    public static func suggest(_ term: String, in index: DirectoryIndex) -> String? {
        var best: (String, Int)?
        for e in index.entries {
            let names = [e.id] + e.aliases + [e.title.lowercased().split(separator: " ").first.map(String.init) ?? e.id]
            for n in names {
                let d = distance(term, n)
                if d <= max(1, min(3, n.count / 3)), best == nil || d < best!.1 { best = (e.id, d) }
            }
        }
        return best?.0
    }

    /// Levenshtein distance.
    public static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }
}

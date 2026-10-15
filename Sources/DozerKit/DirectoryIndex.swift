import Foundation

// 617 (616.03 §4.5, D12) — the directory index, `dozer-directory/v1`: every agent, key provider and base this Dozer
// knows, with its honest status. ONE format, three readers: `doz search` / `doz try` (built from the compiled-in data
// now; fetched later), the dashboard (later) and directory.dozersandbox.com (later). Generated, never hand-written.
//
// · CLOSED and versioned: the strict decoder refuses an unknown field; a new field is `v2` beside `v1` (the update
//   feed's rule). Every string is plain text (readers render with textContent).
// · No user state: whether YOU have a key is never in it — `doz search` adds a separate `local` object per hit.
// · Deterministic: entries sorted by kind then id; the same build writes the same bytes.
// · Signing comes later (D12): `index.json` + `index.json.sig`, Ed25519 over `"dozer-directory/v1\n" + the exact
//   bytes`, with the update feed's key — domain-separated, so a feed signature can never pass as an index's.

/// A thing Dozer knows of but does not run yet (`Recipes/known.json`), with why.
public struct KnownThing: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var publisher: String?
    public var aliases: [String]?
    public var homepage: String?
    /// `coming` | `not-possible`.
    public var status: String
    public var reason: String
    public var checked: String?
    /// 617: where it stands with its maker (superseded by …).
    public var lifecycle: AgentLifecycle?
    /// 617 (owner): what it is — `coding-agent` | `ai-tool` — and its categories, declared (tags.json's vocabulary).
    public var kind: String?
    public var categories: [String]?
}

public enum KnownThings {
    struct File: Codable { var schema: Int; var known: [KnownThing] }

    public static let all: [KnownThing] = {
        do { return try JSONDecoder().decode(File.self, from: Data(PackageResources.known_json)).known } catch {
            fatalError("617: the built-in known.json does not decode: \(error)")
        }
    }()

    /// Each entry well formed — and no known entry for an id a recipe now has (the recipe wins; the entry must go).
    public static func validate(_ known: [KnownThing], recipes: [AgentRecipe] = AgentRecipes.all) throws {
        let ids = Set(recipes.map(\.id) + recipes.flatMap { $0.aliases ?? [] })
        var seen = Set<String>()
        for k in known {
            guard k.id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil, seen.insert(k.id).inserted else {
                throw SandboxError.invalidSpec("known \(k.id): an id, unique")
            }
            guard ["coming", "not-possible"].contains(k.status), !k.reason.isEmpty, !k.title.isEmpty else {
                throw SandboxError.invalidSpec("known \(k.id): status coming or not-possible, with a reason")
            }
            if ids.contains(k.id) || (k.aliases ?? []).contains(where: ids.contains) {
                throw SandboxError.invalidSpec("known \(k.id): a recipe has it now — remove it from known.json")
            }
            if let c = k.checked, !AgentRecipe.isISODate(c) { throw SandboxError.invalidSpec("known \(k.id): checked is an ISO date") }
            try Categories.validate(kind: k.kind, categories: k.categories, what: "known \(k.id)")     // 617 (owner): what it is
        }
        // 617: every lifecycle well formed, and every "superseded by" names a recipe or a known entry.
        try AgentLifecycle.validate(recipes: recipes, known: known)
    }
}

public struct DirectoryIndex: Codable, Sendable, Equatable {
    public static let format = "dozer-directory/v1"
    /// What a later signature covers before the bytes (domain separation, D12).
    public static let signaturePrefix = "dozer-directory/v1\n"

    public var format: String
    /// ISO 8601; phase 1: the newest `checked` date of the data (deterministic for a given build).
    public var generated: String
    public var dozer: Dozer
    public var entries: [Entry]

    public struct Dozer: Codable, Sendable, Equatable {
        public var version: String
    }

    public struct Entry: Codable, Sendable, Equatable {
        /// `agent` | `provider` | `base` (later: `model`).
        public var kind: String
        public var id: String
        public var title: String
        public var publisher: String?
        public var aliases: [String]
        /// `supported` | `coming` | `not-possible`.
        public var status: String
        /// Plain words; required unless supported.
        public var reason: String?
        public var checked: String?
        public var since: String?
        /// Supported, but not every combination.
        public var limits: [Limit]
        public var keys: [KeyRef]
        public var reach: Reach?
        public var install: Install?
        public var defaultBase: String?
        public var terms: String?
        /// `doz try grok`.
        public var tryCommand: String?
        public var homepage: String?
        /// The "What you need" facts (`auth`).
        public var auth: [AuthFact]
        public var gateways: [GatewayFact]
        public var tags: [TagFact]
        /// A provider: the agents that use its keys; a base: the agents that run on it.
        public var agents: [String]?
        /// 617: an agent's standing with its maker (recorded: current, superseded by …).
        public var lifecycle: AgentLifecycle? = nil
        /// 617: its latest release as this Mac last saw it (measured — never in the built-in index; `build(currency:)`).
        public var latest: Latest? = nil
        /// 617: its mark in the icon registry (an agent: product → vendor → a generated lettermark; a provider: its
        /// vendor's, when there is one). Additive: absent for a base.
        public var icon: IconRef? = nil
        /// 617 (owner): an agent's section — `coding-agent` | `ai-tool` — and its categories (declared; a coming one's too).
        public var catalogKind: String? = nil
        public var categories: [String]? = nil

        enum CodingKeys: String, CodingKey {
            case kind, id, title, publisher, aliases, status, reason, checked, since, limits, keys, reach, install, terms, homepage, auth, gateways, tags, agents
            case lifecycle, latest, icon, categories
            case catalogKind = "catalog_kind"
            case defaultBase = "default_base", tryCommand = "try"
        }
    }

    /// 617: a release as measured — its version, the day it came out, and how fresh that is.
    public struct Latest: Codable, Sendable, Equatable {
        public var version: String
        /// YYYY-MM-DD.
        public var released: String?
        /// `active` (a release within 90 days) | `quiet` (none for 90) | `stale` (none for 180) | `deprecated`.
        public var freshness: String?
        public var deprecated: String?
        public init(version: String, released: String?, freshness: String?, deprecated: String?) {
            self.version = version; self.released = released; self.freshness = freshness; self.deprecated = deprecated
        }
    }

    /// 617: a mark — what a reader needs to draw it. `mono` is the registry file, RELATIVE to the index (a website
    /// publishes `Recipes/icons/` beside `index.json`; nil for a generated lettermark, which a reader draws from `d`).
    public struct IconRef: Codable, Sendable, Equatable {
        public var id: String
        /// `product` | `vendor` | `generated`.
        public var kind: String
        /// `official` | `lettermark`.
        public var allowed: String
        public var mono: String?
        public var viewBox: String
        public var d: String
        public var stroke: Double?
        public init(_ m: ResolvedIcon) {
            id = m.id; kind = m.kind; allowed = m.allowed; mono = m.mono; viewBox = m.viewBox; d = m.d; stroke = m.stroke
        }
    }

    public struct Limit: Codable, Sendable, Equatable {
        /// What it does not work with (`{"base": "alpine"}`).
        public var with: [String: String]
        public var reason: String
    }

    public struct KeyRef: Codable, Sendable, Equatable {
        public var provider: String
        public var accounts: [String]
    }

    public struct Reach: Codable, Sendable, Equatable {
        public var model: [HostPaths]
        public var update: [HostPaths]
        public var excluded: [String]
    }

    public struct HostPaths: Codable, Sendable, Equatable {
        public var host: String
        public var paths: [String]?
    }

    public struct Install: Codable, Sendable, Equatable {
        public var kind: String
        public var version: String
        public var source: String?
    }

    public struct AuthFact: Codable, Sendable, Equatable {
        public var kind: String
        public var provider: String?
        public var keysPage: String?
        public var freeTier: Bool?
        public var freeTierNote: String?
        public var account: String?
        public var note: String?
        public var checked: String?

        enum CodingKeys: String, CodingKey {
            case kind, provider, account, note, checked
            case keysPage = "keys_page", freeTier = "free_tier", freeTierNote = "free_tier_note"
        }
    }

    public struct GatewayFact: Codable, Sendable, Equatable {
        public var gateway: String
        public var level: String
        public var reason: String?
    }

    public struct TagFact: Codable, Sendable, Equatable {
        public var tag: String
        public var level: String
    }

    // MARK: building

    /// The whole index from the compiled-in data (and, in tests, registered recipes).
    public static func build(version: String, recipes: [AgentRecipe] = AgentRecipes.all, known: [KnownThing] = KnownThings.all,
                             latest: [String: Latest] = [:]) -> DirectoryIndex {
        var entries = recipes.map { r -> Entry in var e = entry(for: r); e.latest = latest[r.id]; return e }
        entries += known.map { k in
            Entry(kind: "agent", id: k.id, title: k.title, publisher: k.publisher, aliases: (k.aliases ?? []).sorted(), status: k.status, reason: k.reason,
                  checked: k.checked, since: nil, limits: [], keys: [], reach: nil, install: nil, defaultBase: nil, terms: nil, tryCommand: nil,
                  homepage: k.homepage, auth: [], gateways: [], tags: [], agents: nil, lifecycle: k.lifecycle,
                  icon: IconRef(AgentIcons.resolve(icon: nil, publisher: k.publisher, title: k.title)), catalogKind: k.kind, categories: k.categories)
        }
        for p in KeyProviders.all {
            let users = recipes.filter { $0.credentials.contains { $0.provider == p.id } }.map(\.id).sorted()
            let page = recipes.flatMap(\.auth.methods).first { $0.provider == p.id && $0.keysPage != nil }?.keysPage
            entries.append(Entry(kind: "provider", id: p.id, title: p.title, publisher: nil, aliases: [], status: "supported", reason: nil, checked: nil,
                                 since: nil, limits: [], keys: [KeyRef(provider: p.id, accounts: ["key"])],
                                 reach: Reach(model: p.hosts.map { HostPaths(host: $0, paths: nil) }, update: [], excluded: []),
                                 install: nil, defaultBase: nil, terms: nil, tryCommand: nil, homepage: page, auth: [], gateways: [], tags: [], agents: users,
                                 icon: AgentIcons.vendor(p.id).map(IconRef.init)))
        }
        for b in BaseCatalogue.all {
            let on = recipes.filter { !b.musl || $0.platforms.musl }.map(\.id).sorted()
            let limits = recipes.filter { b.musl && !$0.platforms.musl }.map { Limit(with: ["agent": $0.id], reason: $0.muslRefusal) }
            entries.append(Entry(kind: "base", id: b.id, title: b.title, publisher: nil, aliases: [], status: "supported", reason: nil, checked: nil,
                                 since: nil, limits: limits, keys: [], reach: nil, install: Install(kind: "oci", version: b.shortReference, source: b.repository),
                                 defaultBase: nil, terms: nil, tryCommand: nil, homepage: nil, auth: [], gateways: [], tags: [], agents: on))
        }
        let order = ["agent": 0, "provider": 1, "base": 2]
        // 617: a superseded or retired agent comes after the current ones.
        func standing(_ e: Entry) -> Int { (e.lifecycle?.isCurrent ?? true) ? 0 : 1 }
        entries.sort { (order[$0.kind] ?? 9, standing($0), $0.id) < (order[$1.kind] ?? 9, standing($1), $1.id) }
        let dates = recipes.compactMap(\.checked) + known.compactMap(\.checked)
        return DirectoryIndex(format: format, generated: (dates.max() ?? "2026-01-01") + "T00:00:00Z", dozer: Dozer(version: version), entries: entries)
    }

    public static func entry(for r: AgentRecipe) -> Entry {
        var limits = (r.limits ?? []).map { l in Limit(with: l.base.map { ["base": $0] } ?? (l.musl == true ? ["libc": "musl"] : [:]), reason: l.reason) }
        if !r.platforms.musl {
            for b in BaseCatalogue.all where b.musl && !limits.contains(where: { $0.with["base"] == b.id }) {
                limits.append(Limit(with: ["base": b.id], reason: r.muslRefusal))
            }
        }
        let model = (r.network.model.hosts ?? []).map { HostPaths(host: $0.host, paths: $0.paths) }
        return Entry(kind: "agent", id: r.id, title: r.title, publisher: r.publisher, aliases: (r.aliases ?? []).sorted(), status: "supported",
                     reason: nil, checked: r.checked, since: r.isBuiltin ? nil : "0.34.0", limits: limits,
                     keys: r.credentials.map { KeyRef(provider: $0.provider, accounts: $0.accounts) },
                     reach: Reach(model: model, update: r.network.update.map { HostPaths(host: $0.host, paths: $0.paths) }, excluded: r.network.excluded),
                     install: Install(kind: r.install.kind, version: r.install.pinned.version, source: r.install.package),
                     defaultBase: r.defaultBase, terms: r.terms, tryCommand: "doz try \(r.id)", homepage: r.homepage,
                     auth: r.auth.methods.map { AuthFact(kind: $0.kind, provider: $0.provider, keysPage: $0.keysPage, freeTier: $0.freeTier,
                                                         freeTierNote: $0.freeTierNote, account: $0.account, note: $0.note, checked: $0.checked) },
                     gateways: r.gateways.map { GatewayFact(gateway: $0.gateway, level: $0.level, reason: $0.reason) },
                     tags: r.capabilityTags.map { TagFact(tag: $0.tag, level: $0.level) }, agents: nil, lifecycle: r.lifecycle,
                     icon: IconRef(AgentIcons.resolve(r)), catalogKind: r.catalogKind, categories: r.categories)
    }

    // MARK: bytes

    /// The canonical bytes (sorted keys, no escaped slashes, a final newline).
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try enc.encode(self) + Data("\n".utf8)
    }

    /// The strict decoder: the format named, and no field this build does not know.
    public static func decode(_ data: Data) throws -> DirectoryIndex {
        let i = try JSONDecoder().decode(DirectoryIndex.self, from: data)
        guard i.format == format else { throw SandboxError.invalidSpec("not a \(format) index (format \(i.format))") }
        let back = try JSONSerialization.jsonObject(with: try i.encoded())
        let original = try JSONSerialization.jsonObject(with: data)
        if let unknown = AgentRecipes.unknownKey(original, back, path: "") { throw SandboxError.invalidSpec("unknown field \(unknown)") }
        return i
    }
}

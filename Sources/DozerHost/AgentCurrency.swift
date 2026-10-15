import Foundation
import DozerKit

/// 617 (owner: "we are going to see this a lot so need to record the latest version and how old it is and is it
/// current"): an agent's latest release as this Mac last saw it — MEASURED by the host's hourly registry check
/// (`AgentVersions`, agent-versions.json) — beside its standing with its maker, RECORDED in the data
/// (`AgentLifecycle`). Reading it never asks the registry: no check yet is said as such.
public struct AgentCurrency: Codable, Sendable, Equatable {
    public var agent: String
    /// The latest version (without a release's build part), nil: not checked yet.
    public var latest: String?
    public var released: Date?
    /// Whole days since `released`.
    public var ageDays: Int?
    /// `active` (a release within 90 days) | `quiet` (none for 90) | `stale` (none for 180) | `deprecated` | `unknown`.
    public var freshness: String
    public var deprecated: String?
    public var checkedAt: Date?
    public var lifecycle: AgentLifecycle

    public static let quietAfterDays = 90
    public static let staleAfterDays = 180

    /// What the store's cache says for `agent` now.
    public static func of(_ agent: String, store: DozerStore, now: Date = Date()) -> AgentCurrency {
        let rec = AgentVersions.all(store)[agent]
        let lifecycle = AgentRecipes.recipe(agent)?.lifecycle ?? .current
        return make(agent: agent, record: rec, lifecycle: lifecycle, now: now)
    }

    /// Pure, for the tests: the record → the currency.
    public static func make(agent: String, record rec: AgentVersionRecord?, lifecycle: AgentLifecycle, now: Date) -> AgentCurrency {
        let latest = rec?.latest.map { String($0.version.split(separator: "+").first ?? Substring($0.version)) }
        // The release facts belong to the version they were looked up for.
        let info = rec?.infoVersion != nil && rec?.infoVersion == rec?.latest?.version
        let released = info ? rec?.latestReleased : nil
        let deprecated = info ? rec?.latestDeprecated : nil
        let age = released.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
        let freshness: String
        if deprecated != nil { freshness = "deprecated" }
        else if let a = age { freshness = a > staleAfterDays ? "stale" : a > quietAfterDays ? "quiet" : "active" }
        else { freshness = "unknown" }
        return AgentCurrency(agent: agent, latest: latest, released: released, ageDays: age, freshness: freshness,
                             deprecated: deprecated, checkedAt: rec?.checkedAt, lifecycle: lifecycle)
    }

    /// The day as a person reads it (`10 Oct 2026`).
    public static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }

    /// How old, in plain words (`today`, `2 days ago`, `3 months ago`).
    public static func age(_ days: Int) -> String {
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case ..<14: return "\(days) days ago"
        case ..<60: return "\(days / 7) weeks ago"
        case ..<730: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }

    /// One line: `latest 1.3.3 · released 10 Oct 2026 (2 days ago) · active`, or `latest: not checked yet`.
    public var line: String {
        guard let v = latest else { return "latest: not checked yet" }
        var s = "latest \(v)"
        if let r = released { s += " · released \(Self.day(r))" + (ageDays.map { " (\(Self.age($0)))" } ?? "") }
        switch freshness {
        case "active": s += " · active"
        case "quiet": s += " · quiet (no release in 3 months)"
        case "stale": s += " · stale (no release in 6 months)"
        case "deprecated": s += " · deprecated by its maker" + (deprecated.map { ": \($0)" } ?? "")
        default: break
        }
        return s
    }

    /// The index's measured part.
    public var indexLatest: DirectoryIndex.Latest? {
        latest.map { DirectoryIndex.Latest(version: $0, released: released.map(Self.isoDay), freshness: freshness == "unknown" ? nil : freshness,
                                           deprecated: deprecated) }
    }
    static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Every agent's, for the index and the lists.
    public static func all(store: DozerStore, now: Date = Date()) -> [String: AgentCurrency] {
        Dictionary(uniqueKeysWithValues: AgentRecipes.all.map { ($0.id, of($0.id, store: store, now: now)) })
    }
}

import Foundation
import DozerKit
import DozerHost

// 595 — the Resources page's routes, as PROJECTIONS of the host's `resources` report (the one
// inventory the CLI prints too). Nothing here deletes: deletion is the typed actions
// `resources-rm` / `resources-clean` (WebAction → one HostOp, serialised in the host).
//
//   GET  /api/v1/resources           → WebResources  (+ this UI's own memory)
//   POST /api/v1/resources/preview   → ResourcePlan  ({ids: […]} | {clean: true}; changes nothing)

/// The report as the page gets it: no filesystem paths (the CLI shows them), plus the UI process.
public struct WebResources: Codable, Equatable, Sendable {
    public var report: ResourceReport

    public init(_ r: ResourceReport, uiFootprint: Int64?) {
        var r = r
        for i in r.items.indices { r.items[i].path = nil }
        if let ui = uiFootprint { r.memory.append(ResourceMemory(kind: "ui", name: "doz ui", heldBytes: ui)) }
        report = r
    }

    public func encode(to encoder: Encoder) throws { try report.encode(to: encoder) }
    public init(from decoder: Decoder) throws { report = try ResourceReport(from: decoder) }
}

/// `POST /api/v1/resources/preview` — strict: exactly `{ids: [1–500 ids]}` or `{clean: true}`.
public struct WebResourcePreview: Equatable, Sendable {
    public var ids: [String]
    public var clean: Bool

    public static func decode(_ body: Data) throws -> WebResourcePreview {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        let extra = Set(d.keys).subtracting(["ids", "clean"])
        guard extra.isEmpty else { throw WebAction.Invalid("unexpected field(s): \(extra.sorted().joined(separator: ", "))") }
        if let c = d["clean"] {
            guard d["ids"] == nil, let b = c as? Bool, CFGetTypeID(c as CFTypeRef) == CFBooleanGetTypeID(), b else {
                throw WebAction.Invalid("clean: true (and no ids)")
            }
            return WebResourcePreview(ids: [], clean: true)
        }
        return WebResourcePreview(ids: try WebAction.Fields(d).resourceIDs("ids"), clean: false)
    }

    /// The host request: a dry run of the deletion (read-only — no host is started for it).
    public var hostRequest: HostRequest {
        var r = HostRequest(clean ? .resourcesClean : .resourcesRemove)
        r.ids = clean ? nil : ids
        r.dryRun = true
        return r
    }
}

extension HostWebData {
    public func resources() async throws -> WebResources {
        WebResources(try await query(HostRequest(.resources)).0.decode(ResourceReport.self), uiFootprint: Resources.footprint())
    }

    public func resourcesPreview(_ p: WebResourcePreview) async throws -> ResourcePlan {
        try await query(p.hostRequest).0.decode(ResourcePlan.self)
    }
}

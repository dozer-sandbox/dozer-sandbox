import Foundation
import DozerKit
import DozerHost

// 599c (owner, 2026-10-01: "add a "Quick Add" sandbox that picks defaults for workspace name etc and
// opens it immediately"):
//
//   · `POST /api/v1/quick-add` {image?, isolated?} — changes nothing: what one click makes (`QuickAdd`:
//     the default image, a free name, `<defaults.projects_dir>/<name>`) and, when one click cannot
//     decide (the agent's account, an out-of-date image), the requirement — the page then opens the New
//     Sandbox form with it said. The page makes it with the ordinary `create` action, then starts it
//     with the boot view and opens its page.
//   · `POST /api/v1/settings/projects-dir/choose` {} — the Settings page's Choose… for
//     `defaults.projects_dir`: the Mac's folder picker (the projects prompt), and the folder the person
//     chose there is written by the SERVER. The browser never sends the path — `settings` still refuses
//     the key (a host path is never named by the browser).

/// The question, decoded strictly: at most {image, isolated}.
public struct WebQuickAddQuery: Equatable, Sendable {
    public var image: String?
    public var isolated = false

    public static func decode(_ body: Data) throws -> WebQuickAddQuery {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys).isSubset(of: ["image", "isolated"]) else { throw WebAction.Invalid("only image and isolated") }
        var q = WebQuickAddQuery()
        if let v = d["image"], !(v is NSNull) {
            guard let s = v as? String, s.range(of: #"^(custom:)?[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) != nil else {
                throw WebAction.Invalid("image: an image name")
            }
            q.image = s
        }
        if let v = d["isolated"], !(v is NSNull) {
            guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { throw WebAction.Invalid("isolated: true or false") }
            q.isolated = b
        }
        return q
    }

    /// The plan, with the requirement one click cannot decide (from the images and accounts the page
    /// would show).
    public func plan(taken: Set<String>, settings: DozerSettings, images: [WebImage], accounts: WebAccounts) throws -> QuickAddPlan {
        var p = try QuickAdd.plan(image: image, name: nil, isolated: isolated, taken: taken, settings: settings)
        var kinds: [String: AccountKind] = ["mac": .mac]
        for a in accounts.accounts where a.kind != AccountKind.codexMac.rawValue { if let k = AccountKind(rawValue: a.kind) { kinds[a.name] = k } }
        let codexMac = accounts.accounts.contains { $0.kind == AccountKind.codexMac.rawValue && ($0.state == "ok" || $0.state == "expired") }
        let row = images.first { $0.name == p.image }
        let outOfDate = row.flatMap { $0.baked ? $0.standing : nil }
        if let r = QuickAdd.requirement(image: p.image, network: QuickAdd.network(image: p.image, settings: settings),
                                        defaultAccount: accounts.defaultAccount,
                                        accountKinds: kinds, outOfDate: outOfDate, openaiDefault: accounts.openaiDefault, codexMac: codexMac) {
            p.requirementKind = r.kind
            p.requirement = r.text
        }
        return p
    }
}

/// The Settings page's Choose… answer: the folder written, or cancelled — and the settings as they are now.
public struct WebProjectsDirChoice: Codable, Equatable, Sendable {
    public var path: String?
    public var cancelled: Bool
    public var report: SettingsReport
}

extension WebSettingsStore {
    /// 599c: `defaults.projects_dir` = a folder the person chose in the Mac's own picker (the only way
    /// the UI sets a host path). Refused like any change when the environment, a flag or an unreadable
    /// file decides it; and never `/` or a folder inside the store.
    public func applyProjectsDir(_ chosen: String, store: String) throws -> SettingsReport {
        let path = try Workspace.normalize(chosen)
        if path == "/" { throw HostError(.invalid, "the projects folder cannot be / (the whole Mac)") }
        let root = (try? Workspace.normalize(store)) ?? store
        if path == root || path.hasPrefix(root + "/") { throw HostError(.invalid, "\(path) is inside the store — pick a folder outside it") }
        return try applyHostPath(SettingKey.projectsDir, path)
    }
}

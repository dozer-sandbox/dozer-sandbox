import DozerKit
import Foundation

/// 617 (owner: "after the build, keep its log … so the user can go back to it"): an image's build log — the last
/// preparation of that image in this store, kept as `<store>/build-logs/<image>.json` (0600, in a 0700 folder, written
/// atomically) when the preparation ends, done or failed. It survives `doz ui` and host restarts; the sandbox page shows
/// it as a small tab (the steps with their times, then every step's whole output), also for a sandbox whose start built
/// nothing — the log of the build that made its image. Text only, inert (the library removed every control character).
public struct BuildLog: Codable, Equatable, Sendable {
    public struct Section: Codable, Equatable, Sendable {
        public var label: String
        public var lines: [String]
        public init(label: String, lines: [String]) {
            self.label = label
            self.lines = lines
        }
    }
    public var image: String
    /// done · failed · cancelled.
    public var state: String
    public var startedAt: Date
    public var finishedAt: Date
    public var seconds: Double
    public var error: String?
    /// Every finished step (and download), oldest first — the summary.
    public var steps: [PreparationStep]
    /// Each bake step's whole output (and each check's).
    public var sections: [Section]
    /// 617 (owner: "show how the image was made including all the commands"): what the bake ran — every step's argv,
    /// user and environment, the checks, the inputs — exactly as the baker ran it (`BakePlan`). nil: no bake ran (a
    /// failure before it, the lab's first boot) or a log an earlier build kept.
    public var plan: BakePlan?
    public init(image: String, state: String, startedAt: Date, finishedAt: Date, seconds: Double, error: String?,
                steps: [PreparationStep], sections: [Section], plan: BakePlan? = nil) {
        self.plan = plan
        self.image = image
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.seconds = seconds
        self.error = error
        self.steps = steps
        self.sections = sections
    }
}

public enum BuildLogs {
    /// Kept in all, across sections (the oldest sections' lines go first).
    public static let maximumLines = 8000

    /// An image name that can be a file name — the names Dozer gives images (`node-codex`, `df-1a2b…`).
    public static func isValidImage(_ image: String) -> Bool {
        image.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil && !image.contains("..")
    }

    static func folder(_ store: DozerStore) -> URL { store.root.appendingPathComponent("build-logs", isDirectory: true) }

    public static func url(_ image: String, store: DozerStore) -> URL? {
        isValidImage(image) ? folder(store).appendingPathComponent(image + ".json") : nil
    }

    /// Never fails a preparation: a log that cannot be written is only missing.
    public static func save(_ log: BuildLog, store: DozerStore) {
        guard let u = url(log.image, store: store) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder(store), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let tmp = folder(store).appendingPathComponent(".\(log.image).json.\(UUID().uuidString.prefix(8))")
            try enc.encode(scrubbed(capped(log))).write(to: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if rename(tmp.path, u.path) != 0 { try? fm.removeItem(at: tmp) }
        } catch {}
    }

    public static func read(_ image: String, store: DozerStore) -> BuildLog? {
        guard let u = url(image, store: store), let d = try? Data(contentsOf: u) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(BuildLog.self, from: d)
    }

    /// At most `maximumLines` output lines: the newest sections are kept whole first.
    static func capped(_ log: BuildLog) -> BuildLog {
        var left = maximumLines
        var kept: [BuildLog.Section] = []
        for s in log.sections.reversed() {
            if left <= 0 { kept.append(.init(label: s.label, lines: ["… \(s.lines.count) lines not kept …"])); continue }
            if s.lines.count <= left { kept.append(s); left -= s.lines.count; continue }
            kept.append(.init(label: s.label, lines: ["… \(s.lines.count - left) lines not kept …"] + s.lines.suffix(left)))
            left = 0
        }
        var l = log
        l.sections = kept.reversed()
        return l
    }

    /// The log as a terminal draws it: the document's plain text (`doz image log`), with CRLF line ends.
    public static func render(_ log: BuildLog) -> String {
        plainText(document(scrubbed(log))).replacingOccurrences(of: "\n", with: "\r\n")
    }
}

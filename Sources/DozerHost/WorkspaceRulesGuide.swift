import Foundation
import DozerKit

// 599g (owner additions A1–A3, 2026-10-03): workspace rules explained to a person — ONE text for the four
// places that explain them: `doz onboard`'s step and the dashboard's onboarding (the default
// `workspace.ignore_mode`), `doz init` and the dashboard's New Sandbox wizard (this sandbox's `ignore_mode`,
// and what the chosen folder already has). The CLI prints it; the web layer serves it as data, so the page
// says exactly the same.

public enum WorkspaceRulesGuide {
    /// One point of the description: a file name (`term`, shown as code) and what it means, or a plain line.
    public struct Point: Codable, Equatable, Sendable {
        public var term: String?
        public var text: String
        public init(term: String? = nil, _ text: String) {
            self.term = term
            self.text = text
        }
    }

    /// A value of `workspace.ignore_mode` as the step offers it.
    public struct Mode: Codable, Equatable, Sendable {
        public var value: String
        public var label: String
        public var detail: String
        public var recommended: Bool
    }

    public static let title = "Workspace rules"

    public static let intro = "A sandbox sees its project folder live, at /workspace. Two small files in that folder can keep "
        + "the agent away from some of it — without moving anything."

    public static let points: [Point] = [
        Point(term: WorkspaceRules.ignoreFile, "paths the agent must not use: your secrets, keys, a folder of private data."),
        Point(term: WorkspaceRules.readOnlyFile, "paths the agent may read but not change."),
        Point("Your Mac is never touched: you go on editing every file as before. Both files take the lines of Docker’s .dockerignore."),
        Point("Only a folder with one of these files changes. Without them the folder is shared exactly as it is, and nothing costs anything."),
        Point("With rules, the first look through many files is a little slower (about 0.1 s more for 2,000 files)."),
        Point("A convenience, not a security boundary: root in the sandbox — and the agent has sudo by default — can get round it. "
              + "Keep anything that must never reach a sandbox outside its folder."),
    ]

    public static let question = "What should .dozignore do to the paths it lists?"

    public static let modes: [Mode] = [
        Mode(value: "lock", label: "Lock",
             detail: "they stay listed but cannot be opened or changed; the agent knows they exist, and sees why it cannot use them",
             recommended: true),
        Mode(value: "hide", label: "Hide",
             detail: "they are not there at all; quieter, good for clutter like build output, but the agent cannot tell what is missing",
             recommended: false),
    ]

    /// What the onboarding's choice is for, and what the wizard's is for.
    public static let defaultScope = "The default for every sandbox; a sandbox can choose its own. Later: doz config set workspace.ignore_mode hide"
    public static let sandboxScope = "For this sandbox only (ignore_mode in its doz_project.yaml). It matters only once the folder has a .dozignore."

    /// A folder without a rule file.
    public static let noRules = "none — the folder is shared as is"

    public static let howToAdd = "To add rules, put a .dozignore (or .dozreadonly) at the top of the folder, one path per line — "
        + "for example secrets.env or **/*.key. Once the sandbox exists, doz ignore check NAME PATH says what a path is and which line decides."

    /// One rule file found in a folder: its usable patterns (how many, the first few — made inert: the file may
    /// have been written from inside a sandbox) and the lines skipped as not valid.
    public struct FolderFile: Codable, Equatable, Sendable {
        public var name: String
        public var patterns: Int
        public var first: [String]
        public var skipped: Int
        public init(name: String, patterns: Int, first: [String], skipped: Int) {
            self.name = name
            self.patterns = patterns
            self.first = first
            self.skipped = skipped
        }
    }

    /// The rule files in `folder` (none: an empty list — also for a folder that does not exist yet).
    public static func folderFiles(_ folder: URL, shown: Int = 4) -> [FolderFile] {
        guard WorkspaceRules.present(in: folder) else { return [] }
        let rules = WorkspaceRules.load(folder: folder, mode: .lock)
        var out: [FolderFile] = []
        for (name, present) in [(WorkspaceRules.ignoreFile, rules.ignorePresent), (WorkspaceRules.readOnlyFile, rules.readOnlyPresent)] where present {
            let lines = (name == WorkspaceRules.ignoreFile ? rules.ignore : rules.readOnly).filter { $0.file == name }
            out.append(FolderFile(name: name, patterns: lines.count,
                                  first: lines.prefix(shown).map { InertText.line(Substring($0.pattern), limit: 80) },
                                  skipped: rules.problems.filter { $0.file == name }.count))
        }
        return out
    }

    /// "3 patterns", "1 pattern, 1 line skipped".
    public static func count(_ f: FolderFile) -> String {
        "\(f.patterns) pattern\(f.patterns == 1 ? "" : "s")" + (f.skipped > 0 ? ", \(f.skipped) line\(f.skipped == 1 ? "" : "s") skipped" : "")
    }
}

extension Onboarding {
    /// 599g: the Workspace rules step's choice — `workspace.ignore_mode`, the default for every sandbox — written
    /// ONLY when chosen (a flag or an answer), as the Access step's are: into the settings file even when it was
    /// kept, and not at all when the file already says so. Returns what it set (`key = value`).
    public static func writeIgnoreMode(_ mode: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
        let settings = DozerSettings.load(environment: environment)
        guard let d = DozerSettings.definition(SettingKey.ignoreMode) else { return [] }
        let v = try d.parse(mode)
        if settings.resolve(SettingKey.ignoreMode).value == v, settings.fileValues[SettingKey.ignoreMode] != nil { return [] }
        try settings.writing(SettingKey.ignoreMode, v)
        return ["\(SettingKey.ignoreMode) = \(mode)"]
    }
}

import Foundation
import DozerKit
import DozerHost

/// 599g (owner additions A1/A2): the Workspace rules step on a terminal — `doz onboard`'s (the default
/// `workspace.ignore_mode`) and `doz init`'s (this sandbox's `ignore_mode`, and what its folder already has).
/// The words are `WorkspaceRulesGuide`'s, the same the dashboard shows.
struct RulesStep {
    let asker: Asker
    let talk: Bool
    /// `--ignore-mode`: answers the question.
    var flag: String?
    /// The answer Enter keeps: the project file's, else the settings'.
    var current: String
    /// `doz init`: the project folder (its rule files are listed); nil for the onboarding.
    var folder: URL?

    func say(_ s: String) { if talk { Out.stdout(s + "\n") } }

    /// The description, the folder's rules, then the question. Returns the mode CHOSEN — the flag, or the answer
    /// on a terminal — and nil when nothing was chosen (`--yes`, no terminal: nothing changes).
    func run() -> String? {
        if talk {
            say("  " + WorkspaceRulesGuide.intro)
            for p in WorkspaceRulesGuide.points { say("  · " + (p.term.map { "\($0) — " } ?? "") + p.text) }
        }
        if let folder, talk {
            let files = WorkspaceRulesGuide.folderFiles(folder)
            if files.isEmpty {
                say("  This folder's rules: \(WorkspaceRulesGuide.noRules).")
                say("  " + WorkspaceRulesGuide.howToAdd)
            } else {
                say("  This folder's rules:")
                for f in files {
                    say("    \(f.name) — \(WorkspaceRulesGuide.count(f))")
                    for l in f.first { say("      \(l)") }
                    if f.patterns > f.first.count { say("      …") }
                }
            }
        }
        if let flag {
            say("  \(flag) (--ignore-mode)")
            return flag
        }
        guard asker.interactive else {
            say("  \(current) — unchanged")
            return nil
        }
        let modes = WorkspaceRulesGuide.modes
        let i = asker.choose("  " + WorkspaceRulesGuide.question,
                             modes.map { "\($0.label) — \($0.detail)" },
                             preferred: modes.firstIndex { $0.value == current } ?? 0)
        say("  " + (folder == nil ? WorkspaceRulesGuide.defaultScope : WorkspaceRulesGuide.sandboxScope))
        return modes[i].value
    }
}

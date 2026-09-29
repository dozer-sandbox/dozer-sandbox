import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost
import DozerWeb

/// 594 (D13) — `doz uninstall`: a clean slate without a hand-typed `rm -rf`. It lists EXACTLY what it
/// removes and asks once (plainly; `--yes` for scripts): the store (every sandbox, image, kernel and
/// the host's files), the settings directory, and the installed `doz` (`make install-cli`'s
/// `<prefix>/libexec/doz/` and the `<prefix>/bin/doz` link to it). It never touches the keychain
/// (items `doz account add` made are listed, with how to remove them) nor anything of Claude Code's.
struct Uninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove Dozer Sandbox from this Mac: the store, the settings and the installed doz — listed first, asked once.",
        discussion: "Never the keychain and never Claude Code's own files. --keep-store and --keep-config leave those. A running doz ui for the store must be stopped first; a running host is stopped first (its sandboxes hibernate, then the store goes).")

    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Leave the store (sandboxes, images) where it is.") var keepStore = false
    @Flag(name: .long, help: "Leave the settings directory (doz.toml, agent-prompt.md).") var keepConfig = false
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false

    struct Item: Encodable {
        var path: String
        var what: String
        var removed: Bool?
        var error: String?
    }

    struct Report: Encodable {
        var removed: [Item]
        var kept: [String]
        var keychain: [String]
    }

    /// The installation this executable belongs to, when it is one `make install-cli` made:
    /// `<prefix>/libexec/doz/doz` (and `<prefix>/bin/doz` when it links there).
    static func installation(executable: String = HostLauncher.executablePath) -> (libexec: URL, link: URL?)? {
        let exe = URL(fileURLWithPath: executable).standardizedFileURL
        let libexec = exe.deletingLastPathComponent()
        guard exe.lastPathComponent == "doz", libexec.lastPathComponent == "doz", libexec.deletingLastPathComponent().lastPathComponent == "libexec" else { return nil }
        let prefix = libexec.deletingLastPathComponent().deletingLastPathComponent()
        let link = prefix.appendingPathComponent("bin/doz")
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)).map {
            URL(fileURLWithPath: $0, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.path
        }
        return (libexec, target == exe.path ? link : nil)
    }

    /// A store directory is removed only when it looks like one (or is empty): never a folder
    /// someone pointed --store at by mistake.
    static func looksLikeStore(_ root: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        if names.isEmpty { return true }
        let known: Set<String> = ["sandboxes", "images", "kernels", "golden", "content", "initfs.ext4", "host.log", "host.lock", "metrics.sqlite",
                                  "accounts.json", "onboarded.json", "ui.lock", "state.json", "containers"]
        return names.contains(where: known.contains)
    }

    func run() async throws {
        let fm = FileManager.default
        let store = g.dozerStore
        var items: [Item] = []
        var kept: [String] = []
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        // The store.
        if keepStore {
            kept.append("the store \(store.root.path) (--keep-store)")
        } else if fm.fileExists(atPath: store.root.path) {
            guard store.root.path != "/", store.root.path != home else { throw fail(HostError(.invalid, "refusing to remove \(store.root.path)"), g) }
            guard Self.looksLikeStore(store.root) else {
                throw fail(HostError(.invalid, "\(store.root.path) does not look like a Dozer store — not removing it (check --store / $DOZ_STORE)"), g)
            }
            let n = store.sandboxNames().count
            items.append(Item(path: store.root.path, what: "the store: \(n) sandbox\(n == 1 ? "" : "es"), every image, kernel and restore point, the host's log and metrics"))
        }
        // The settings.
        let configDir = DozerSettings.fileURL()?.deletingLastPathComponent()
        if keepConfig {
            kept.append("the settings \(configDir?.path ?? "(none)") (--keep-config)")
        } else if let dir = configDir, fm.fileExists(atPath: dir.path) {
            guard dir.lastPathComponent == DozerSettings.directoryName else { throw fail(HostError(.invalid, "refusing to remove \(dir.path)"), g) }
            items.append(Item(path: dir.path, what: "the settings: doz.toml, agent-prompt.md"))
        }
        // The installed doz.
        if let inst = Self.installation() {
            items.append(Item(path: inst.libexec.path, what: "the installed doz and its resources"))
            if let link = inst.link { items.append(Item(path: link.path, what: "the doz command (a link to it)")) }
        } else {
            kept.append("this doz (\(HostLauncher.executablePath)) — not an installed one (make install-cli installs to <prefix>/libexec/doz)")
        }
        // Never the keychain: say what is left there.
        let accounts = AccountStore(store: store, settings: .load()).load().accounts.compactMap { a -> String? in
            guard let s = a.keychainService, a.adopted != true else { return nil }
            return "\(s) (account \(a.name) — doz account rm \(a.name) removes it; do that BEFORE uninstalling)"
        }
        kept.append("the keychain (never touched)" + (accounts.isEmpty ? "" : ": " + accounts.joined(separator: " · ")))
        kept.append("Claude Code's own files and login (never touched)")

        if items.isEmpty {
            if g.json { Out.json(Report(removed: [], kept: kept, keychain: accounts)) } else { Out.stdout("nothing to remove\n") }
            return
        }
        if !g.json {
            Out.stdout("doz uninstall removes exactly this:\n")
            for i in items { Out.stdout("  \(i.path)\n      \(i.what)\n") }
            Out.stdout("and leaves:\n")
            for k in kept { Out.stdout("  \(k)\n") }
        }
        // A UI serving this store would lose its store under it.
        let uiLock = open(WebControl.lockFile(store).path, O_RDONLY | O_CLOEXEC)
        if uiLock >= 0 {
            let held = flock(uiLock, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
            if !held { flock(uiLock, LOCK_UN) }
            close(uiLock)
            if held { throw fail(HostError(.failed, "a doz ui is running for this store — stop it first (Ctrl-C where it runs), then uninstall"), g) }
        }
        try confirm("Remove all of the above?", yes: yes, g)
        // The host goes first (it owns every VM); it shuts them down as it stops.
        if !keepStore, store.hostIsRunning() {
            if !g.json { Out.stdout("stopping the host …\n") }
            _ = try? HostClient.request(HostRequest(.hostStop), store: store, autostart: false)
            let deadline = Date().addingTimeInterval(120)
            while store.hostIsRunning(), Date() < deadline { usleep(200_000) }
            if store.hostIsRunning() { throw fail(HostError(.failed, "the host did not stop within 2 minutes — nothing was removed"), g) }
        }
        var failed = false
        for i in items.indices {
            do {
                try fm.removeItem(atPath: items[i].path)
                items[i].removed = true
                if !g.json { Out.stdout("removed \(items[i].path)\n") }
            } catch {
                failed = true
                items[i].removed = false
                items[i].error = error.localizedDescription
                if !g.json { Out.stderr("doz: could not remove \(items[i].path): \(error.localizedDescription)\n") }
            }
        }
        if g.json { Out.json(Report(removed: items, kept: kept, keychain: accounts)) }
        else if !failed { Out.stdout("Dozer Sandbox is removed from this Mac. (To install again: make install-cli in a DozerKit checkout, then doz onboard.)\n") }
        if failed { throw ExitCode(DozerExit.failed) }
    }
}

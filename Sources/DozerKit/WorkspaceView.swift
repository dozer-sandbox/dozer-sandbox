import Foundation

// The guest half of workspace rules: where the view lives in the guest and the root scripts that lay it
// out. The daemon is `dozview` (Guest/dozview/, committed as Resources/dozview, copied in — never run
// from the share it serves).
//
// Layout while a view runs for a share (tag T, guest path G — e.g. /workspace):
//   /run/doz/raw/T     the share itself, bound privately; /run/doz/raw is 0700 root (/run/doz stays 0755:
//                      the forwarded SSH agent's socket lives there)
//   G                  the view (fuse.dozview, allow_other, default_permissions) over an EMPTY folder of
//                      the root disk — never over the share: if the daemon stops, G shows nothing
//   /run/doz/view/T.*  conf (mode, fold — written by the host), pid (the supervisor), state, log
//
// The lifecycle (the 599g spike, workspace changes/599g-*/599g.03-SPIKE.md): the FUSE connection and its
// daemon survive pause, sleep, hibernate and a restore into a new process (both are guest memory) — the
// view is NEVER re-mounted. What dies in a hibernation is the daemon's link to the share: a wake re-binds
// RAW (never G), then signals the daemon (SIGUSR1) in the SAME root script. Pause and sleep→wake in place
// need nothing.
//
// When: a fresh boot whose share holds a rule file starts the view; a wake, and every session start, turn
// it on for a share that gained a rule file meanwhile (a process already inside G keeps what it had open
// until it changes directory — said in the manual); a view whose rule files are gone stays (showing
// everything) until the next start. Not a security boundary: root in the guest can stop it.

/// One share's view, as the host wants it.
public struct WorkspaceViewConfig: Sendable, Equatable, Codable {
    public var tag: String
    public var guestPath: String
    public var mode: WorkspaceRuleMode
    public var fold: Bool
    /// The share's Mac folder holds NO rule file: the view only keeps /workspace alive across a hibernation
    /// (a process whose cwd is inside keeps it — the raw re-mount would cut it). It hides nothing, makes
    /// nothing read-only (dozview ≥ 1.1.0), and when it cannot start the share is bound as it is — never
    /// left empty. nil (an older record) = false.
    public var passthrough: Bool?
    public var isPassthrough: Bool { passthrough == true }
    public init(tag: String, guestPath: String, mode: WorkspaceRuleMode, fold: Bool, passthrough: Bool = false) {
        self.tag = tag; self.guestPath = guestPath; self.mode = mode; self.fold = fold; self.passthrough = passthrough ? true : nil
    }
}

/// What the guest reported about one share's view.
public struct WorkspaceViewStatus: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable { case running, started, restarted, failed, off }
    public var tag: String
    public var state: State
    public var pid: Int?
}

public enum WorkspaceView {
    public static let binaryGuestPath = GuestCommand.openShimDirectory + "/dozview"
    public static let rawRoot = "/run/doz/raw"
    public static let viewDirectory = "/run/doz/view"

    public static func rawPath(_ tag: String) -> String { "\(rawRoot)/\(tag)" }
    public static func confPath(_ tag: String) -> String { "\(viewDirectory)/\(tag).conf" }
    public static func pidPath(_ tag: String) -> String { "\(viewDirectory)/\(tag).pid" }
    public static func statePath(_ tag: String) -> String { "\(viewDirectory)/\(tag).state" }
    public static func logPath(_ tag: String) -> String { "\(viewDirectory)/\(tag).log" }

    /// A tag or guest path the scripts can quote safely (Containerization's tags are hex; paths are the
    /// spec's). Anything else gets no view.
    public static func isSafe(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) } && !s.contains("..")
    }

    /// Shell: is the supervisor whose pid is in file $1 alive? Not `kill -0`: the container's PID 1
    /// (`sleep infinity`) never reaps, so a killed supervisor stays a ZOMBIE that `kill -0` reports as alive
    /// (seen in the suite). Alive = its /proc entry is dozview's and is not a zombie.
    static let aliveFunction = "dzv_alive() { p=$(cat \"$1\" 2>/dev/null) && [ -n \"$p\" ] && grep -q dozview \"/proc/$p/cmdline\" 2>/dev/null && ! grep -q '^State:[[:space:]]*Z' \"/proc/$p/status\" 2>/dev/null; }"

    static func confText(_ c: WorkspaceViewConfig) -> String { "mode=\(c.mode.rawValue)\nfold=\(c.fold ? 1 : 0)\n" }

    static func writeConf(_ c: WorkspaceViewConfig) -> String {
        "printf '\(confText(c).replacingOccurrences(of: "\n", with: "\\n"))' > '\(confPath(c.tag)).tmp' && mv -f '\(confPath(c.tag)).tmp' '\(confPath(c.tag))'"
    }

    static func startCommand(_ c: WorkspaceViewConfig) -> String {
        "'\(binaryGuestPath)' start --raw '\(rawPath(c.tag))' --mount '\(c.guestPath)' --conf '\(confPath(c.tag))'"
            + " --state '\(statePath(c.tag))' --pidfile '\(pidPath(c.tag))' --log '\(logPath(c.tag))'"
    }

    /// Root shell: turn the view on for a share that is mounted (directly or as a bind) at its guest path.
    /// Best effort — it never fails the caller; it prints `doz-view TAG started PID` or `doz-view TAG failed …`.
    /// The share is bound privately FIRST, then every mount at G is detached (a view never sits on the
    /// share), then the daemon mounts the view at G. A failure after the detach leaves G EMPTY (the rules
    /// are not dropped silently); the next wake or start tries again.
    public static func startScript(_ c: WorkspaceViewConfig) -> String {
        guard isSafe(c.tag), isSafe(c.guestPath) else { return "echo 'doz-view \(c.tag.filter { $0.isLetter || $0.isNumber }) failed: unsafe name'" }
        let r = rawPath(c.tag), g = c.guestPath
        // `&&` throughout: `set -e` is ignored inside a list whose status is tested.
        return "{ mkdir -p /run/doz '\(rawRoot)' '\(viewDirectory)' && chmod 0755 /run/doz '\(viewDirectory)' && chmod 0700 '\(rawRoot)'"
            + " && mkdir -p '\(r)' && { mountpoint -q '\(r)' || mount --bind '\(g)' '\(r)'; } && ls -a '\(r)' >/dev/null"
            + " && { n=0; while mountpoint -q '\(g)' && [ $n -lt 8 ]; do umount -l '\(g)'; n=$((n+1)); done; } && ! mountpoint -q '\(g)'"
            + " && mkdir -p '\(g)' && \(writeConf(c)) && pid=$(\(startCommand(c))) && ls -a '\(g)' >/dev/null"
            + " && echo \"doz-view \(c.tag) started $pid\"; } 2>&1 || { \(fallback(c.tag, g, c.isPassthrough))echo 'doz-view \(c.tag) failed: the view could not start'; }"
    }

    /// A passthrough view that could not start leaves the SHARE at G (bound from RAW, else from the fresh
    /// virtio-fs mount) — never an empty folder: there are no rules to keep.
    static func fallback(_ tag: String, _ g: String, _ passthrough: Bool) -> String {
        passthrough ? "{ mountpoint -q '\(g)' || mount --bind '\(rawPath(tag))' '\(g)' 2>/dev/null || mount --bind '/run/dozer-vfs/\(tag)' '\(g)' 2>/dev/null; } ; " : ""
    }

    /// Root shell, inside the wake's re-mount (after `/run/dozer-vfs` is fresh and listed), for a share
    /// whose guest runs a view (its conf exists): re-bind RAW — never G — then, in the same script,
    /// SIGUSR1 the daemon (it re-opens its link to the share and re-reads the rules), or start a new one
    /// when the supervisor is gone. `wanted` updates the conf first (mode/fold changed while it slept).
    static func remountWithView(tag: String, guestPath g: String, wanted: WorkspaceViewConfig?) -> String {
        let r = rawPath(tag), pf = pidPath(tag)
        var s = "umount -l '\(r)' 2>/dev/null || true; mount --bind '/run/dozer-vfs/\(tag)' '\(r)'; ls -a '\(r)' >/dev/null"
        if let w = wanted { s += "; \(writeConf(w)) || true" }
        let c = WorkspaceViewConfig(tag: tag, guestPath: g, mode: wanted?.mode ?? .lock, fold: wanted?.fold ?? true, passthrough: wanted?.isPassthrough ?? false)
        s += "; \(aliveFunction); if dzv_alive '\(pf)'; then kill -USR1 \"$(cat '\(pf)')\"; echo \"doz-view \(tag) running $(cat '\(pf)')\""
            + "; else umount -l '\(g)' 2>/dev/null || true; mkdir -p '\(g)'"
            + "; if pid=$(\(startCommand(c)) 2>&1); then echo \"doz-view \(tag) restarted $pid\"; else \(fallback(tag, g, c.isPassthrough))echo \"doz-view \(tag) failed: $pid\"; fi; fi"
        return s
    }

    /// Root shell: what each view is doing (`doz-view TAG running PID` / `off`), and its state file (rewritten
    /// first: SIGUSR2 makes the worker write it now).
    public static func statusScript(_ tags: [String]) -> String {
        aliveFunction + "; " + tags.filter(isSafe).map { t in
            "if [ -f '\(confPath(t))' ] && dzv_alive '\(pidPath(t))'"
                + "; then kill -USR2 \"$(cat '\(pidPath(t))')\"; sleep 0.2; echo \"doz-view \(t) running $(cat '\(pidPath(t))')\"; sed 's/^/doz-state \(t) /' '\(statePath(t))' 2>/dev/null; "
                + "elif [ -f '\(confPath(t))' ]; then echo 'doz-view \(t) failed: the view is not running'; else echo 'doz-view \(t) off'; fi"
        }.joined(separator: "; ")
    }

    /// Root shell: re-read the conf and the rules now (a mode change on a running sandbox).
    public static func reloadScript(_ c: WorkspaceViewConfig) -> String {
        "\(aliveFunction); \(writeConf(c)) && if dzv_alive '\(pidPath(c.tag))'; then kill -HUP \"$(cat '\(pidPath(c.tag))')\"; echo \"doz-view \(c.tag) running $(cat '\(pidPath(c.tag))')\"; "
            + "else echo 'doz-view \(c.tag) failed: the view is not running'; fi"
    }

    /// The `doz-view` lines of a script's output.
    public static func parse(_ output: String) -> [WorkspaceViewStatus] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard f.count >= 3, f[0] == "doz-view", let st = WorkspaceViewStatus.State(rawValue: f[2].trimmingCharacters(in: CharacterSet(charactersIn: ":"))) else { return nil }
            return WorkspaceViewStatus(tag: f[1], state: st, pid: f.count > 3 ? Int(f[3].trimmingCharacters(in: .whitespaces)) : nil)
        }
    }

    /// The `doz-state TAG key=value` lines (the daemon's state file) of one tag.
    public static func parseState(_ output: String, tag: String) -> [String: String] {
        var d: [String: String] = [:]
        for line in output.split(separator: "\n") where line.hasPrefix("doz-state \(tag) ") {
            let kv = line.dropFirst("doz-state \(tag) ".count)
            if let eq = kv.firstIndex(of: "=") { d[String(kv[..<eq])] = String(kv[kv.index(after: eq)...]) }
        }
        return d
    }
}

/// Finds the committed `dozview` guest binary (the workspace rules' view daemon) the same way as
/// deckhold — `$DOZ_DOZVIEW` overrides.
public enum DozviewBinary {
    public static let resourceName = "dozview"
    public static let environmentOverride = "DOZ_DOZVIEW"
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        DeckholdBinary.locate(resource: resourceName, override: environmentOverride, environment: environment)
    }
}

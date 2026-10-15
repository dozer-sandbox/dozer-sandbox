import Foundation

/// 617 (owner: a page should never print the Mac user's home — `/Users/<name>/…` — nor a long path a person does not
/// need): how a Mac path is SHOWN. A path under the Mac user's home reads `~/…`. Display only: what is stored, sent to
/// the host or a client, and every JSON field stays absolute.
///
/// The dashboard does the same with `core/paths.js` (`tildePath`, `tildeIn`), fed `DisplayPath.homes` through the
/// session info; the CLI's human lines that name a Mac folder use `tilde` here. One rule, two languages.
///
/// "Home" is the Mac user's real one (`TestSafety.realHome`, never `$HOME`). A guarded test run (`DOZ_TEST_GUARD=1`) may
/// name another with `DOZ_TEST_HOME` — a scratch folder that stands in for home ON SCREEN ONLY (the release post's
/// screenshots: a scratch store and projects folder that read `~/…`). Nothing else reads that variable.
public enum DisplayPath {
    /// The home a path is shown relative to, and its resolved spelling when that differs (`/tmp/x` is `/private/tmp/x`):
    /// paths reach the page in either form.
    public static func homes(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var h = TestSafety.realHome.path
        if TestSafety.guarded(env, inXCTest: false), let t = env["DOZ_TEST_HOME"], t.hasPrefix("/") { h = t }
        let plain = trimmed(URL(fileURLWithPath: h).standardizedFileURL.path)
        // macOS's /tmp, /var and /etc are /private/…: a path can reach the page in either spelling (realpath gives the
        // long one, a setting the short one). Foundation's own symlink resolution shortens /private/tmp, so it is
        // spelled out here.
        for short in ["/tmp", "/var", "/etc"] where plain == short || plain.hasPrefix(short + "/") { return [plain, "/private" + plain] }
        if plain.hasPrefix("/private/") {
            let short = String(plain.dropFirst("/private".count))
            if ["/tmp", "/var", "/etc"].contains(where: { short == $0 || short.hasPrefix($0 + "/") }) { return [plain, short] }
        }
        return [plain]
    }

    /// `path` as a person reads it: `~` for home itself, `~/…` under it, anything else as it is.
    public static func tilde(_ path: String, homes: [String] = homes()) -> String {
        for h in homes where !h.isEmpty && h != "/" {
            if path == h { return "~" }
            if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        }
        return path
    }

    /// Every home path inside a line of text shown as `~/…` (a host's sentence that names a folder).
    public static func tildeIn(_ text: String, homes: [String] = homes()) -> String {
        var out = text
        for h in homes.sorted(by: { $0.count > $1.count }) where !h.isEmpty && h != "/" {
            // Only where a path starts (not inside another path: /x/Users/a/… stays as it is).
            let pattern = "(?<![A-Za-z0-9_./~-])" + NSRegularExpression.escapedPattern(for: h) + "(?=/|$|[\\s,;:)\\]'\"])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "~")
        }
        return out
    }

    private static func trimmed(_ p: String) -> String { p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
}

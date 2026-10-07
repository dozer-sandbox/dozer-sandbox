import Darwin
import Foundation

/// 606: the `serve.*` settings' value checks (the schema's `serveBind`, `originList`, `addressList`). The web
/// layer parses the same text into its own types (`WebServeBind`, `WebPublicOrigin`, `WebCIDR`) —
/// `ServeSettingsTests` keeps the two agreeing.
public enum ServeSettingValues {
    static func words(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// An IPv4 or IPv6 address literal (IPv6 optionally in brackets).
    static func isAddress(_ s: String) -> Bool {
        var t = s
        if t.hasPrefix("["), t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, t, &v4) == 1 || inet_pton(AF_INET6, t, &v6) == 1
    }

    static func isUnusableBindAddress(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return t == "0.0.0.0" || t == "::" || t.hasPrefix("fe80:") || t.hasPrefix("169.254.")
    }

    /// `lan`, `loopback`, or 1–16 of the Mac's addresses (never the wildcard, never link-local).
    public static func isBind(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "lan" || t == "loopback" { return true }
        let w = words(t)
        return !w.isEmpty && w.count <= 16 && w.allSatisfy { isAddress($0) && !isUnusableBindAddress($0) }
    }

    /// `http(s)://host[:port]` origins, at most 8, no path, query, fragment or user.
    public static func isOriginList(_ s: String) -> Bool {
        let w = words(s)
        guard w.count <= 8 else { return false }
        return w.allSatisfy { o in
            guard o.utf8.count <= 255, let u = URLComponents(string: o), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = u.host, !host.isEmpty, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
                  u.path.isEmpty || u.path == "/" else { return false }
            if let p = u.port, !(1...65_535).contains(p) { return false }
            return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]".contains($0)) }
        }
    }

    /// Addresses or networks (`a.b.c.d[/n]`, `v6[/n]`), at most 32.
    public static func isAddressList(_ s: String) -> Bool {
        let w = words(s)
        guard w.count <= 32 else { return false }
        return w.allSatisfy { item in
            let parts = item.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), isAddress(String(parts[0])) else { return false }
            guard parts.count == 2 else { return true }
            let max = String(parts[0]).contains(":") ? 128 : 32
            return parts[1].allSatisfy(\.isNumber) && (Int(parts[1]).map { (0...max).contains($0) } ?? false)
        }
    }
}

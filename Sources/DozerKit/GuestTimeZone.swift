import Foundation

/// 594 W10 (the owner's walkthrough: Claude said "done 3:23 AM" — UTC — on a Mac in Australia): the
/// guest's time zone. The zone's TZif file is copied from THIS Mac (`/usr/share/zoneinfo/<name>` —
/// the format is the same on Linux, glibc and musl alike), so it works in every image, with or
/// without tzdata in it. Written to `/etc/localtime` (and its name to `/etc/timezone`) at every fresh
/// boot and every wake — a laptop that changes zone while a sandbox sleeps is followed.
public struct GuestTimeZone: Sendable, Equatable {
    /// An IANA name (`Australia/Sydney`).
    public let name: String
    /// The zone's TZif bytes.
    public let tzif: Data

    public init?(name: String, tzif: Data) {
        guard Self.isPlainName(name), tzif.count <= 64 << 10, tzif.starts(with: Data("TZif".utf8)) else { return nil }
        self.name = name
        self.tzif = tzif
    }

    /// The zone from this Mac's zoneinfo (nil: not a zone this Mac has).
    public init?(named name: String, zoneinfo: URL = URL(fileURLWithPath: "/usr/share/zoneinfo")) {
        guard Self.isPlainName(name), !name.split(separator: "/").contains(".."),
              let d = FileManager.default.contents(atPath: zoneinfo.appendingPathComponent(name).path) else { return nil }
        self.init(name: name, tzif: d)
    }

    static func isPlainName(_ s: String) -> Bool {
        s.count <= 64 && s.range(of: #"^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$"#, options: .regularExpression) != nil
    }

    /// Root shell, idempotent: the TZif bytes to /etc/localtime (atomically — it replaces the image's
    /// symlink), the name to /etc/timezone. Never fails the caller.
    public var script: String {
        let b64 = tzif.base64EncodedString()
        return "{ printf %s '\(b64)' | base64 -d > /etc/.doz-localtime && chmod 0644 /etc/.doz-localtime"
            + " && mv -f /etc/.doz-localtime /etc/localtime && printf '%s\\n' '\(name)' > /etc/timezone; } || rm -f /etc/.doz-localtime"
    }
}

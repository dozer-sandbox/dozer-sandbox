import Darwin
import Foundation
import Security

/// 591 — which program file a host runs from, so it can tell when that file changes under it.
///
/// Found on the owner's Mac: `make install-cli` overwrote the installed `doz` IN PLACE while a host
/// ran from it. The running process's code signature no longer matched its file, and the
/// Virtualization framework refused every VM it asked for ("Internal Virtualization error") — a raw
/// error that said nothing about the cause. (The install now renames a new file over the old one —
/// e1af862 — which a running host survives: it keeps its own file.) The host records its file's
/// identity at start and compares it when a VM fails, in `host status` and in `doctor`.
public struct ExecutableIdentity: Codable, Equatable, Sendable {
    public var path: String
    public var inode: UInt64
    public var device: Int64
    public var size: Int64
    public var modified: Double
    /// The code directory hash of the file's signature (hex), when it is signed.
    public var cdhash: String?

    public init(path: String, inode: UInt64, device: Int64, size: Int64, modified: Double, cdhash: String?) {
        self.path = path
        self.inode = inode
        self.device = device
        self.size = size
        self.modified = modified
        self.cdhash = cdhash
    }

    /// The file at `path` now; nil when there is none.
    public static func of(path: String) -> ExecutableIdentity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return ExecutableIdentity(path: path, inode: UInt64(st.st_ino), device: Int64(st.st_dev), size: Int64(st.st_size),
                                  modified: mtime, cdhash: cdhash(path))
    }

    /// The signature's code directory hash, from the file (cheap: the signature is read, not the code).
    static func cdhash(_ path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 0), &info) == errSecSuccess,
              let d = info as? [String: Any], let u = d[kSecCodeInfoUnique as String] as? Data else { return nil }
        return u.map { String(format: "%02x", $0) }.joined()
    }

    public enum Change: String, Codable, Equatable, Sendable {
        /// The file this process runs from was rewritten in place: its code no longer matches its
        /// signature, and macOS refuses the virtual machines it asks for. Stop it and start a new one.
        case overwritten
        /// A different file is at the path now (an update renamed a new build over it): this process
        /// keeps running its own copy and works; the next host runs the new build.
        case replaced
        /// Nothing is at the path any more.
        case removed
    }

    /// How the file at the same path differs from `self` (recorded when this process started), and
    /// whether this process's own code is still valid. A running process whose code the kernel no
    /// longer trusts is `overwritten` whatever is at the path now: an install that wrote into the
    /// file and then re-signed it (a new inode) broke the process just the same.
    public func change(now: ExecutableIdentity?, runningCodeValid: Bool = true) -> Change? {
        if !runningCodeValid { return .overwritten }
        guard let now else { return .removed }
        if now.inode != inode || now.device != device { return .replaced }
        if now.size != size || now.modified != modified || (cdhash != nil && now.cdhash != cdhash) { return .overwritten }
        return nil
    }

    /// Whether the kernel still considers THIS process's code valid (a file rewritten under a running
    /// process invalidates it; the Virtualization entitlement is then refused).
    public static func runningCodeIsValid() -> Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return true }
        return SecCodeCheckValidity(me, [], nil) == errSecSuccess
    }

    /// The sentence a person reads about `change`.
    public static func explain(_ change: Change, path: String) -> String {
        switch change {
        case .overwritten:
            "this host's program was updated underneath it (\(path) was rewritten while it ran, so macOS no longer trusts "
                + "its code and refuses its virtual machines) — `doz host stop`, then retry: sandboxes that are asleep keep "
                + "their snapshots and wake on the new build"
        case .replaced:
            "a newer doz is installed (\(path)); this host still runs the previous build — `doz host stop` switches "
                + "(sandboxes hibernate and wake on the new one)"
        case .removed:
            "this host's program (\(path)) is gone — an upgrade removed it (brew upgrade / brew cleanup) — `doz host stop`, "
                + "then retry: the installed doz starts a new host (sandboxes asleep keep their snapshots and wake on it)"
        }
    }
}

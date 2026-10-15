import Foundation
import DozerKit

// 617 (owner: "fold doz cp into 617", then "maybe two way: doz put and doz get") — files and folders between the Mac
// and a sandbox, like `docker cp`: `doz get NAME PATH [LOCAL]`, `doz put NAME LOCAL [PATH]`, and `doz cp` (the Docker
// spelling) over the same code. The bytes are a tar stream over the host's guest stream (`Sandbox.openGuestStream`,
// the browser bridge's path) — no new guest→host channel. Works in an isolated sandbox (no share needed).
//
// The rules: never write into Dozer's store or anywhere but what the person named (a temporary folder BESIDE the
// destination, checked, then moved into place); a symlink that points outside the copied folder is refused (in the
// guest before anything moves, on the Mac again after unpacking); an existing destination is refused unless --force
// (which says what it replaces); files land owned by the Mac user on the Mac, and by the image's user in the guest
// unless the destination is not writable by it (then root, said).

/// `copy`'s what and where.
public struct CopyRequest: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable { case get, put }
    public var direction: Direction
    /// The path in the sandbox (absolute, or relative to /workspace).
    public var path: String
    /// put: the local item's kind and the name it arrives under (its own name unless PATH names a new one).
    public var kind: CopyKind?
    public var name: String?
    public var force: Bool?

    public init(direction: Direction, path: String, kind: CopyKind? = nil, name: String? = nil, force: Bool? = nil) {
        self.direction = direction
        self.path = path
        self.kind = kind
        self.name = name
        self.force = force
    }
}

public enum CopyKind: String, Codable, Equatable, Sendable { case file, folder }

/// The host's answer before the bytes: what will be copied, and as whom.
public struct CopyReady: Codable, Equatable, Sendable {
    public var kind: CopyKind
    /// get: the source in the guest (links in it resolved); put: the destination in the guest.
    public var path: String
    /// get: the size on the guest's disk (an estimate for progress); put: nil.
    public var bytes: Int64?
    public var files: Int?
    /// put: the guest user that writes (the image's, else root) and why root when it is.
    public var runAs: String?
    public var rootReason: String?
    /// put: what --force replaces (nil: nothing was there).
    public var replaces: CopyKind?
    public var woke: Bool?
    public var started: Bool?
}

/// The end of a copy.
public struct CopyDone: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    /// The tar stream's bytes (either way).
    public var bytes: Int64
    public var milliseconds: Double
    /// A warning that did not fail it (tar's "file changed as we read it").
    public var warning: String?
}

/// The connection after `CopyReady`: frames of one type byte + a 4-byte big-endian length + the payload.
/// Host → client: `D` (data, get), `E` (end: a `CopyDone`). Client → host: `D` (data, put), `F` (the input is done).
public enum CopyFrame {
    public static let data: UInt8 = 0x44, end: UInt8 = 0x45, finish: UInt8 = 0x46
    public static let maximumPayload = 1 << 20

    public static func encode(_ type: UInt8, _ payload: Data = Data()) -> Data {
        var d = Data([type])
        let n = UInt32(payload.count)
        d.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        d.append(payload)
        return d
    }

    /// Frames out of a byte stream cut anywhere. A frame over the maximum or of an unknown type is an error.
    public final class Parser {
        private var buffer = Data()
        public init() {}
        public enum Failure: Error, Equatable { case tooLarge, unknownType(UInt8) }
        public func feed(_ bytes: Data) throws -> [(type: UInt8, payload: Data)] {
            buffer.append(bytes)
            var out: [(UInt8, Data)] = []
            while buffer.count >= 5 {
                let b = buffer.startIndex
                let t = buffer[b]
                guard [CopyFrame.data, CopyFrame.end, CopyFrame.finish].contains(t) else { throw Failure.unknownType(t) }
                let n = Int(buffer[b + 1]) << 24 | Int(buffer[b + 2]) << 16 | Int(buffer[b + 3]) << 8 | Int(buffer[b + 4])
                guard n <= CopyFrame.maximumPayload else { throw Failure.tooLarge }
                guard buffer.count >= 5 + n else { break }
                out.append((t, Data(buffer[(b + 5)..<(b + 5 + n)])))
                buffer = Data(buffer[(b + 5 + n)...])
            }
            return out
        }
    }
}

/// Paths, the guest's checks and the commands — pure, so they are tested without a VM.
public enum CopyPaths {
    public static let workspace = "/workspace"

    /// A sandbox path as given → an absolute, lexically clean one (relative = under /workspace). nil: not a usable path.
    public static func guestPath(_ given: String) -> String? {
        guard !given.isEmpty, given.utf8.count <= 4096, !given.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let base = given.hasPrefix("/") ? given : workspace + "/" + given
        var parts: [String] = []
        for p in base.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." { continue }
            if p == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(p))
        }
        return "/" + parts.joined(separator: "/")
    }

    /// A name a copy's item may arrive under (one path component).
    public static func isItemName(_ n: String) -> Bool {
        !n.isEmpty && n != "." && n != ".." && !n.contains("/") && n.utf8.count <= 255
            && !n.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// get: what is at `path` — one `doz-copy …` line: `ok KIND KIB FILES RESOLVED`, `missing`, `dangling`, `special`,
    /// `root`, or up to five `escape LINK -> TARGET` lines (a link in the folder that points outside it).
    public static func getCheckScript(_ path: String) -> String {
        """
        p=\(q(path))
        if [ ! -e "$p" ]; then if [ -L "$p" ]; then echo 'doz-copy dangling'; else echo 'doz-copy missing'; fi; exit 0; fi
        r=$(readlink -f "$p" 2>/dev/null); [ -n "$r" ] || r=$p
        [ "$r" = / ] && { echo 'doz-copy root'; exit 0; }
        if [ -d "$r" ]; then k=folder; elif [ -f "$r" ]; then k=file; else echo 'doz-copy special'; exit 0; fi
        if [ "$k" = folder ]; then
          find "$r" -type l 2>/dev/null | while IFS= read -r l; do
            t=$(readlink -f "$l" 2>/dev/null)
            if [ -z "$t" ]; then
              g=$(readlink "$l" 2>/dev/null)
              case "$g" in /*|..|../*|*/..|*/../*) echo "doz-copy escape ${l#"$r"/} -> $g" ;; esac
            else
              case "$t" in "$r"|"$r"/*) ;; *) echo "doz-copy escape ${l#"$r"/} -> $(readlink "$l" 2>/dev/null)" ;; esac
            fi
          done | head -5
        fi
        b=$(du -sk "$r" 2>/dev/null | cut -f1)
        n=$(find "$r" 2>/dev/null | wc -l | tr -d ' ')
        echo "doz-copy ok $k ${b:-0} ${n:-1} $r"
        """
    }

    /// put (run AS the user that would write): where `name` lands for `dest` — `ok WRITABLE EXISTING TARGET` (WRITABLE
    /// yes|no, EXISTING none|file|folder), or `noparent PARENT`.
    public static func putCheckScript(dest: String, name: String) -> String {
        """
        d=\(q(dest)); n=\(q(name))
        if [ -d "$d" ]; then parent=$d; t="${d%/}/$n"; else
          case "$d" in */) echo "doz-copy noparent $d"; exit 0 ;; esac
          parent=$(dirname "$d"); t=$d
        fi
        [ -d "$parent" ] || { echo "doz-copy noparent $parent"; exit 0; }
        if [ -e "$t" ] || [ -L "$t" ]; then if [ -d "$t" ] && [ ! -L "$t" ]; then e=folder; else e=file; fi; else e=none; fi
        w=no; [ -w "$parent" ] && w=yes
        echo "doz-copy ok $w $e $t"
        """
    }

    public enum GetCheck: Equatable {
        case ok(kind: CopyKind, kib: Int64, files: Int, resolved: String)
        case missing, dangling, special, root
        case escapes([String])
        case unreadable(String)
    }

    public static func parseGet(_ output: String) -> GetCheck {
        let lines = output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("doz-copy ") }.map { String($0.dropFirst(9)) }
        let escapes = lines.filter { $0.hasPrefix("escape ") }.map { String($0.dropFirst(7)) }
        if !escapes.isEmpty { return .escapes(escapes) }
        guard let last = lines.last else { return .unreadable(output) }
        switch last {
        case "missing": return .missing
        case "dangling": return .dangling
        case "special": return .special
        case "root": return .root
        default:
            let f = last.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, f[0] == "ok", let k = CopyKind(rawValue: f[1]), let kib = Int64(f[2]), let n = Int(f[3]) else { return .unreadable(output) }
            return .ok(kind: k, kib: kib, files: n, resolved: f[4])
        }
    }

    public enum PutCheck: Equatable {
        case ok(writable: Bool, existing: CopyKind?, target: String)
        case noParent(String)
        case unreadable(String)
    }

    public static func parsePut(_ output: String) -> PutCheck {
        guard let last = output.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("doz-copy ") })?.dropFirst(9) else {
            return .unreadable(output)
        }
        if last.hasPrefix("noparent ") { return .noParent(String(last.dropFirst(9))) }
        let f = last.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4, f[0] == "ok", ["yes", "no"].contains(f[1]) else { return .unreadable(output) }
        return .ok(writable: f[1] == "yes", existing: f[2] == "none" ? nil : CopyKind(rawValue: f[2]), target: f[3])
    }

    /// The guest's tar: get packs `resolved` as its own name; put unpacks into the target's folder (`-o`: never the
    /// archive's owner — the writing user owns what it writes; GNU tar and busybox alike).
    public static func getTar(_ resolved: String) -> [String] {
        let parent = (resolved as NSString).deletingLastPathComponent, base = (resolved as NSString).lastPathComponent
        return ["tar", "-C", parent.isEmpty ? "/" : parent, "-cf", "-", base]
    }
    public static func putTar(_ target: String) -> [String] {
        let parent = (target as NSString).deletingLastPathComponent
        return ["tar", "-C", parent.isEmpty ? "/" : parent, "-x", "-o", "-f", "-"]
    }

    /// `doz cp`'s operands: `NAME:PATH` is a sandbox's (a name by the sandbox rule, then a colon); anything else is a
    /// path on this Mac (`./a:b` for a local name with a colon).
    public static func operand(_ s: String) -> (sandbox: String?, path: String) {
        if let i = s.firstIndex(of: ":") {
            let name = String(s[..<i])
            if WebNameCheck.isSandboxName(name) { return (name, String(s[s.index(after: i)...])) }
        }
        return (nil, s)
    }

    /// The first line of a guest tar's stderr, inert and short — why it failed, in its own words.
    public static func tarError(_ stderr: String) -> String? {
        let line = stderr.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { String($0.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(200)) }
    }
}

/// The Mac's side of a copy — pure parts (the CLI runs /usr/bin/tar around them).
public enum LocalCopy {
    /// Where a `get` lands: no LOCAL → ./NAME; an existing folder (or one written with a trailing /) → inside it as
    /// NAME; else LOCAL itself (its folder must exist).
    public static func destination(name: String, local: String?, cwd: String) -> (path: String, problem: String?) {
        guard let l = local, !l.isEmpty else { return ((cwd as NSString).appendingPathComponent(name), nil) }
        let abs = l.hasPrefix("/") ? l : (l.hasPrefix("~/") ? (l as NSString).expandingTildeInPath : (cwd as NSString).appendingPathComponent(l))
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: abs, isDirectory: &isDir), isDir.boolValue {
            return ((abs as NSString).appendingPathComponent(name), nil)
        }
        if l.hasSuffix("/") { return (abs, "no such folder on this Mac: \(l)") }
        let parent = (abs as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else {
            return (abs, "no such folder on this Mac: \(parent)")
        }
        return ((abs as NSString).standardizingPath, nil)
    }

    /// Never into (or out of) Dozer's store: the path, its existing part resolved, compared with the store's real path.
    public static func inStore(_ path: String, store: URL) -> Bool {
        let s = store.resolvingSymlinksInPath().standardizedFileURL.path
        var p = (path as NSString).standardizingPath
        while !FileManager.default.fileExists(atPath: p), p != "/" { p = (p as NSString).deletingLastPathComponent }
        let r = URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
        let full = r + String(((path as NSString).standardizingPath).dropFirst(p.count))
        return full == s || full.hasPrefix(s + "/")
    }

    /// The symlinks under `root` that point outside it (relative to `root`, with their targets) — a copy refuses them.
    public static func escapingLinks(_ root: String) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let rootReal = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        func check(_ p: String) {
            guard let target = try? fm.destinationOfSymbolicLink(atPath: p) else { return }
            let dir = (p as NSString).deletingLastPathComponent
            let lexical = ((target.hasPrefix("/") ? target : (dir as NSString).appendingPathComponent(target)) as NSString).standardizingPath
            let inside: (String) -> Bool = { $0 == rootReal || $0.hasPrefix(rootReal + "/") || $0 == root || $0.hasPrefix(root + "/") }
            if !inside(lexical) { out.append(String(p.dropFirst(root.count + 1)) + " -> " + target) }
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let e = fm.enumerator(atPath: root) else { return [] }
        while let rel = e.nextObject() as? String {
            let p = (root as NSString).appendingPathComponent(rel)
            if (try? fm.attributesOfItem(atPath: p)[.type] as? FileAttributeType) == .typeSymbolicLink { check(p) }
            if out.count >= 5 { break }
        }
        return out
    }

    /// A local item's size and count of entries (for progress); links are not followed.
    public static func measure(_ path: String) -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return (0, 0) }
        if !isDir.boolValue { return (Int64((try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)??.int64Value ?? 0), 1) }
        var bytes: Int64 = 0, n = 1
        if let e = fm.enumerator(atPath: path) {
            while let rel = e.nextObject() as? String {
                n += 1
                let a = try? fm.attributesOfItem(atPath: (path as NSString).appendingPathComponent(rel))
                if (a?[.type] as? FileAttributeType) == .typeRegular { bytes += (a?[.size] as? NSNumber)?.int64Value ?? 0 }
            }
        }
        return (bytes, n)
    }

    /// Put `item` (unpacked in a temporary folder beside the destination) at `dest`: a rename when nothing is there; with
    /// `force`, a file replaces a file, and a folder is merged into a folder (files of the same name replaced). Never
    /// a folder over a file or the other way round.
    public static func place(_ item: String, at dest: String, force: Bool) throws {
        let fm = FileManager.default
        var srcDir: ObjCBool = false, dstDir: ObjCBool = false
        _ = fm.fileExists(atPath: item, isDirectory: &srcDir)
        let exists = fm.fileExists(atPath: dest, isDirectory: &dstDir) || (try? fm.destinationOfSymbolicLink(atPath: dest)) != nil
        if !exists { try fm.moveItem(atPath: item, toPath: dest); return }
        guard force else { throw HostError(.exists, "\(dest) is there already — --force replaces it") }
        if srcDir.boolValue != dstDir.boolValue {
            throw HostError(.exists, "\(dest) is a \(dstDir.boolValue ? "folder" : "file") and this is a \(srcDir.boolValue ? "folder" : "file") — not replaced")
        }
        if !srcDir.boolValue {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: dest), withItemAt: URL(fileURLWithPath: item))
            return
        }
        for name in try fm.contentsOfDirectory(atPath: item) {
            try place((item as NSString).appendingPathComponent(name), at: (dest as NSString).appendingPathComponent(name), force: true)
        }
    }
}

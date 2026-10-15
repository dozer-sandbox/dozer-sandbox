import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost

// 617 (owner: "fold doz cp into 617", then "maybe two way: doz put and doz get"): `doz get` and `doz put` are the verbs,
// `doz cp` the Docker spelling over the same code. The bytes are a tar stream: /usr/bin/tar on the Mac, the guest's
// tar in the sandbox, the host's guest stream between them (FileCopy.swift, HostCore+Copy.swift).

struct CopyFlags: ParsableArguments {
    @Flag(name: .long, help: "Replace what is there (a file replaces a file; a folder is merged into a folder, files of the same name replaced).")
    var force = false
    @Flag(name: .long, help: "Fail instead of waking a sleeping sandbox.") var noWake = false
    @Flag(name: .long, help: "Fail instead of starting (cold-booting) a sandbox that is off.") var noStart = false
}

struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get",
        abstract: "Copy a file or folder out of a sandbox to this Mac.",
        discussion: """
        doz get try-grok /workspace/report.md · doz get my-app src ./backup/src · doz get my-app /etc/hosts hosts.txt. \
        PATH is in the sandbox (relative: under /workspace); LOCAL is the current folder unless given — into a folder \
        that exists it keeps its name, else LOCAL is the new name. Folders are copied whole. Works in an isolated \
        sandbox too. An existing LOCAL is not replaced unless --force. A link inside a folder that points outside it \
        stops the copy. Files arrive owned by you. A sleeping sandbox is woken and one that is off is started, as for \
        doz exec (--no-wake, --no-start refuse instead). Same as doz cp NAME:PATH LOCAL.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Argument(help: "The file or folder in the sandbox (relative: under /workspace).") var path: String
    @Argument(help: "Where on this Mac (default: the current folder).") var local: String?
    @OptionGroup var flags: CopyFlags

    func run() async throws { try await FileTransfer.get(name, path, local, flags, g) }
}

struct PutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "put",
        abstract: "Copy a file or folder from this Mac into a sandbox.",
        discussion: """
        doz put try-grok notes.md · doz put my-app ./data /workspace/input · doz put my-app script.sh /tmp/run.sh. \
        PATH is in the sandbox (default /workspace, there in every sandbox; relative: under /workspace) — into a folder \
        that exists it keeps its name, else PATH is the new name. Folders are copied whole. An existing PATH is not \
        replaced unless --force. A link inside a folder that points outside it stops the copy. Files arrive owned by \
        the image's user (as root only where that user cannot write, said). A sleeping sandbox is woken and one that is \
        off is started, as for doz exec. Same as doz cp LOCAL NAME:PATH.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Argument(help: "The file or folder on this Mac.") var local: String
    @Argument(help: "Where in the sandbox (default /workspace).") var path: String?
    @OptionGroup var flags: CopyFlags

    func run() async throws { try await FileTransfer.put(name, local, path, flags, g) }
}

struct CpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cp",
        abstract: "Copy files and folders between this Mac and a sandbox (as docker cp; doz get and doz put are the same).",
        discussion: """
        doz cp try-grok:/workspace/report.md . · doz cp try-grok:report.md . · doz cp ./data my-app:/workspace/input. \
        One side is NAME:PATH (a path in sandbox NAME; a relative PATH is under /workspace, and NAME: alone is \
        /workspace), the other a path on this Mac (./a:b for a name with a colon).
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "From: NAME:PATH or a path on this Mac.") var source: String
    @Argument(help: "To: NAME:PATH or a path on this Mac.") var destination: String
    @OptionGroup var flags: CopyFlags

    func run() async throws {
        let s = CopyPaths.operand(source), d = CopyPaths.operand(destination)
        switch (s.sandbox, d.sandbox) {
        case (let n?, nil): try await FileTransfer.get(n, s.path.isEmpty ? CopyPaths.workspace : s.path, d.path, flags, g)
        case (nil, let n?): try await FileTransfer.put(n, s.path, d.path.isEmpty ? nil : d.path, flags, g)
        case (_?, _?): throw fail(HostError(.invalid, "both sides are in a sandbox — one side is a path on this Mac"), g, code: DozerExit.usage)
        case (nil, nil):
            let rows = await CopyHint.sandboxes(g)
            let hint = CopyHint.neitherSide(source: source, destination: destination, sandboxes: rows,
                                            existsOnMac: { FileManager.default.fileExists(atPath: $0) },
                                            cwd: FileManager.default.currentDirectoryPath, shown: FileTransfer.shown)
            throw fail(HostError(.invalid, "neither side is in a sandbox — write one as NAME:PATH" + (hint.map { "\n" + $0 } ?? "")), g, code: DozerExit.usage)
        }
    }
}

/// 617 (owner, after `doz cp FILE ~/somewhere` with no NAME:): when neither side names a sandbox, look — read-only,
/// never starting a host — for the source in each sandbox's folder on the Mac, else name the one running sandbox.
enum CopyHint {
    struct Row: Equatable { var name: String; var phase: String; var workspace: String? }

    static func sandboxes(_ g: GlobalOptions) async -> [Row] {
        var r = HostRequest(.ls)
        r.withSessions = false
        let store = g.dozerStore
        let value: JSONValue?
        if store.hostIsRunning() {
            value = try? call(r, g, autostart: false)
        } else {
            let core = HostCore(store: store, readOnly: true, version: DozerCommand.version)
            await core.load()
            let m = await core.handle(r)
            value = m.ok == true ? m.result : nil
        }
        guard let value, let rows = try? value.decode([SandboxInfo].self) else { return [] }
        return rows.map { Row(name: $0.name, phase: $0.phase, workspace: $0.workspace) }
    }

    /// The line after the refusal (nil: nothing to suggest). Pure but for the two closures.
    static func neitherSide(source: String, destination: String, sandboxes: [Row], existsOnMac: (String) -> Bool,
                            cwd: String, shown: (String) -> String) -> String? {
        let rel = source.hasPrefix("./") ? String(source.dropFirst(2)) : source
        if !rel.isEmpty, !rel.hasPrefix("/"), !rel.hasPrefix("~"), !rel.split(separator: "/").contains("..") {
            for row in sandboxes {
                guard let ws = row.workspace else { continue }
                let onMac = (ws as NSString).appendingPathComponent(rel)
                guard existsOnMac(onMac) else { continue }
                let item = (rel as NSString).lastPathComponent
                // Into the destination's folder when it names the same item (the owner's `… ~/Developer/fun/FILE`).
                var to = destination
                if (destination as NSString).lastPathComponent == item, destination.contains("/") {
                    to = (destination as NSString).deletingLastPathComponent + "/"
                }
                return "\(rel) is in \(row.name)'s folder — it's already on your Mac at \(shown(onMac)). Or: doz get \(row.name) \(rel) \(to)"
            }
        }
        let running = sandboxes.filter { $0.phase == "running" }
        guard running.count == 1, let n = running.first?.name else { return nil }
        let local = source.hasPrefix("/") || source.hasPrefix("~") ? source : (cwd as NSString).appendingPathComponent(source)
        let expanded = local.hasPrefix("~/") ? (local as NSString).expandingTildeInPath : local
        return existsOnMac(expanded) ? "Into \(n): doz cp \(source) \(n):\(destination)" : "From \(n): doz cp \(n):\(source) \(destination)"
    }
}

enum FileTransfer {
    static func shown(_ p: String) -> String {
        return DisplayPath.tilde(p)
    }

    /// Open the copy: the request, then the host's events (a wake, a start) until its answer.
    static func open(_ name: String, _ c: CopyRequest, _ flags: CopyFlags, _ g: GlobalOptions) throws -> (HostClient, CopyReady) {
        noteHostBuild(g)
        var r = HostRequest(.copy, name: name)
        r.fileCopy = c
        r.wake = !flags.noWake
        r.start = !flags.noStart
        let client: HostClient
        do { client = try HostClient.connect(store: g.dozerStore, autostart: true) } catch let e as HostError { throw fail(e, g) }
        let progress = Progress(g)
        defer { progress.finish() }
        do {
            let m = try client.call(r) { progress.handle($0) }
            guard m.ok == true else { throw fail(m.error ?? HostError(.failed, "the host gave no reason"), g) }
            return (client, try (m.result ?? .null).decode(CopyReady.self))
        } catch let e as HostError { throw fail(e, g) }
    }

    /// The bytes' meter: a line on stderr while a copy longer than a second runs (a terminal, not -q / --json).
    final class Meter {
        let label: String, total: Int64?
        let t0 = Date()
        var last = Date.distantPast
        var drawn = false
        let on: Bool
        init(_ label: String, total: Int64?, _ g: GlobalOptions) {
            self.label = label
            self.total = total
            on = isatty(STDERR_FILENO) != 0 && !g.quiet && !g.json
        }
        func update(_ n: Int64) {
            let now = Date()
            guard on, now.timeIntervalSince(t0) > 1, now.timeIntervalSince(last) > 0.25 else { return }
            last = now
            let secs = now.timeIntervalSince(t0)
            var s = "  \(label)  "
            if let t = total, t > 0 {
                let f = min(1, Double(n) / Double(t))
                s += ProgressFormat.bar(f, width: 20) + "  " + ProgressFormat.amount(min(n, t), t)
                if f > 0.05, f < 1 { s += "  ~" + ProgressFormat.duration(secs / f - secs) }
            } else {
                s += ProgressFormat.bytes(n)
            }
            s += "  " + ProgressFormat.rate(Double(n) / max(secs, 0.001))
            FileHandle.standardError.write(Data(("\r\u{1B}[K" + s).utf8))
            drawn = true
        }
        func finish() { if drawn { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) } }
    }

    /// Frames from the host: what was buffered past the answer, then the socket.
    static func readFrames(_ client: HostClient, _ body: (UInt8, Data) throws -> Bool) throws {
        let parser = CopyFrame.Parser()
        var pending = client.reader.takeRemainder()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            if !pending.isEmpty {
                let frames: [(type: UInt8, payload: Data)]
                do { frames = try parser.feed(pending) } catch { throw HostError(.failed, "the host sent something this doz cannot read") }
                pending = Data()
                for f in frames where try !body(f.type, f.payload) { return }
            }
            let n = read(client.fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { throw HostError(.unavailable, "the host closed the connection during the copy") }
            pending = Data(buf[0..<n])
        }
    }

    static func tarProcess(_ args: [String], stdin: Pipe? = nil, stdout: Pipe? = nil, stderr: Pipe) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"                 // no ._ AppleDouble files in an archive
        p.environment = env
        if let stdin { p.standardInput = stdin }
        if let stdout { p.standardOutput = stdout }
        p.standardError = stderr
        try p.run()
        return p
    }

    static func say(_ g: GlobalOptions, _ json: [String: JSONValue], _ line: String) {
        if g.json { Out.json(json) } else if !g.quiet { Out.stdout(line + "\n") }
    }

    // MARK: get

    static func get(_ name: String, _ given: String, _ local: String?, _ flags: CopyFlags, _ g: GlobalOptions) async throws {
        signal(SIGPIPE, SIG_IGN)
        guard let path = CopyPaths.guestPath(given) else { throw fail(HostError(.invalid, "not a path in a sandbox: \(given.debugDescription)"), g, code: DozerExit.usage) }
        let itemName = (path as NSString).lastPathComponent
        guard CopyPaths.isItemName(itemName) else { throw fail(HostError(.invalid, "not the whole of \(name) (/) — name a folder"), g, code: DozerExit.usage) }
        let cwd = FileManager.default.currentDirectoryPath
        let (dest, problem) = LocalCopy.destination(name: itemName, local: local, cwd: cwd)
        if let problem { throw fail(HostError(.notFound, problem), g) }
        if LocalCopy.inStore(dest, store: g.dozerStore.root) {
            throw fail(HostError(.failed, "\(dest) is inside Dozer's store — never written there"), g)
        }
        let exists = FileManager.default.fileExists(atPath: dest) || (try? FileManager.default.destinationOfSymbolicLink(atPath: dest)) != nil
        if exists, !flags.force { throw fail(HostError(.exists, "\(shown(dest)) is there already — --force replaces it"), g) }

        let (client, ready) = try open(name, CopyRequest(direction: .get, path: path), flags, g)
        // A temporary folder BESIDE the destination (same volume: the final move is a rename), removed whatever happens.
        let parent = (dest as NSString).deletingLastPathComponent
        var template = Array(((parent as NSString).appendingPathComponent(".doz-get-XXXXXX")).utf8CString)
        guard let made = mkdtemp(&template) else { throw fail(HostError(.failed, "cannot write in \(shown(parent)): \(String(cString: strerror(errno)))"), g) }
        let tmp = String(cString: made)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let input = Pipe(), errs = Pipe()
        let tar = try tarProcess(["-x", "-f", "-", "-C", tmp], stdin: input, stderr: errs)
        let meter = Meter("Copying \(name):\(ready.path)", total: ready.bytes, g)
        var received: Int64 = 0
        var done: CopyDone?
        let w = input.fileHandleForWriting.fileDescriptor
        var tarGone = false
        do {
            try readFrames(client) { type, payload in
                if type == CopyFrame.data {
                    received += Int64(payload.count)
                    meter.update(received)
                    if !tarGone, !UnixSocket.writeAll(w, payload) { tarGone = true }
                    return true
                }
                if type == CopyFrame.end { done = try? HostWire.decoder.decode(CopyDone.self, from: payload); return false }
                return true
            }
        } catch {
            meter.finish()
            try? input.fileHandleForWriting.close()
            tar.waitUntilExit()
            throw fail(HostError.from(error), g)
        }
        meter.finish()
        try? input.fileHandleForWriting.close()
        tar.waitUntilExit()
        let tarErr = String(decoding: errs.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let done else { throw fail(HostError(.failed, "the copy ended without its result"), g) }
        guard done.ok else { throw fail(HostError(.failed, "\(name):\(ready.path) — \(done.error ?? "failed")"), g) }
        guard tar.terminationStatus == 0 else {
            throw fail(HostError(.failed, "unpacking on this Mac failed: " + (CopyPaths.tarError(tarErr) ?? "tar ended with \(tar.terminationStatus)")), g)
        }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []
        guard items.count == 1, let item = items.first else { throw fail(HostError(.failed, "the copy did not hold one item (\(items.count))"), g) }
        let unpacked = (tmp as NSString).appendingPathComponent(item)
        let escapes = LocalCopy.escapingLinks(unpacked)
        guard escapes.isEmpty else {
            throw fail(HostError(.failed, "\(name):\(ready.path) holds links that point outside it — not copied (\(escapes.joined(separator: "; ")))"), g)
        }
        do { try LocalCopy.place(unpacked, at: dest, force: flags.force) } catch { throw fail(HostError.from(error), g) }
        let what = ready.kind == .folder ? "folder, \(ready.files.map { "\(max(0, $0 - 1)) items" } ?? "")" : "file"
        var j: [String: JSONValue] = ["sandbox": .string(name), "direction": .string("get"), "from": .string(ready.path), "to": .string(dest),
                                      "kind": .string(ready.kind.rawValue), "bytes": .number(Double(received)), "milliseconds": .number(done.milliseconds)]
        if exists { j["replaced"] = .bool(true) }
        if let w = done.warning { j["warning"] = .string(w); if !g.json { Out.stderr("[doz] note: \(w)\n") } }
        say(g, j, "copied \(name):\(ready.path) → \(shown(dest)) (\(what); \(ProgressFormat.bytes(received)) in \(ProgressFormat.duration(done.milliseconds / 1000)))"
            + (exists ? " — replaced what was there" : ""))
    }

    // MARK: put

    static func put(_ name: String, _ localGiven: String, _ given: String?, _ flags: CopyFlags, _ g: GlobalOptions) async throws {
        signal(SIGPIPE, SIG_IGN)
        let cwd = FileManager.default.currentDirectoryPath
        let expanded = localGiven.hasPrefix("~/") ? (localGiven as NSString).expandingTildeInPath : localGiven
        let abs = (expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded) as String)
        let source = URL(fileURLWithPath: abs).resolvingSymlinksInPath().path      // the item named (a link to it: what it points to)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir) else {
            throw fail(HostError(.notFound, "no such file or folder on this Mac: \(localGiven)"), g)
        }
        let type = (try? FileManager.default.attributesOfItem(atPath: source)[.type] as? FileAttributeType)
        guard isDir.boolValue || type == .typeRegular else { throw fail(HostError(.failed, "\(localGiven) is not a file or a folder — not copied"), g) }
        if LocalCopy.inStore(source, store: g.dozerStore.root) {
            throw fail(HostError(.failed, "\(localGiven) is inside Dozer's store — never copied"), g)
        }
        let kind: CopyKind = isDir.boolValue ? .folder : .file
        if kind == .folder {
            let escapes = LocalCopy.escapingLinks(source)
            guard escapes.isEmpty else { throw fail(HostError(.failed, "\(localGiven) holds links that point outside it — not copied (\(escapes.joined(separator: "; ")))"), g) }
        }
        let base = (source as NSString).lastPathComponent
        guard CopyPaths.isItemName(base) else { throw fail(HostError(.invalid, "not a name to copy: \(base)"), g) }
        let dest = given ?? CopyPaths.workspace
        guard let path = CopyPaths.guestPath(dest) else { throw fail(HostError(.invalid, "not a path in a sandbox: \(dest.debugDescription)"), g, code: DozerExit.usage) }

        let (client, ready) = try open(name, CopyRequest(direction: .put, path: dest.hasSuffix("/") ? path + "/" : path, kind: kind, name: base, force: flags.force), flags, g)
        let target = (ready.path as NSString).lastPathComponent
        var args = ["--format", "gnutar", "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags", "-c", "-f", "-",
                    "-C", (source as NSString).deletingLastPathComponent]
        if target != base { args += ["-s", "/^" + bre(base) + "/" + breReplacement(target) + "/S"] }
        args.append(base)
        let output = Pipe(), errs = Pipe()
        let tar = try tarProcess(args, stdout: output, stderr: errs)
        let measured = LocalCopy.measure(source)
        let meter = Meter("Copying \(shown(abs)) → \(name):\(ready.path)", total: measured.bytes, g)
        var sent: Int64 = 0
        let r = output.fileHandleForReading.fileDescriptor
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        var cut = false
        while true {
            let n = read(r, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            sent += Int64(n)
            meter.update(sent)
            if !UnixSocket.writeAll(client.fd, CopyFrame.encode(CopyFrame.data, Data(buf[0..<n]))) { cut = true; break }
        }
        meter.finish()
        tar.waitUntilExit()
        let tarErr = String(decoding: errs.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard !cut else { throw fail(HostError(.unavailable, "the host closed the connection during the copy"), g) }
        guard tar.terminationStatus == 0 else {
            // Leave the guest's tar with a cut archive: it fails and says so; this says why.
            Darwin.shutdown(client.fd, SHUT_WR)
            throw fail(HostError(.failed, "packing \(localGiven) on this Mac failed: " + (CopyPaths.tarError(tarErr) ?? "tar ended with \(tar.terminationStatus)")), g)
        }
        _ = UnixSocket.writeAll(client.fd, CopyFrame.encode(CopyFrame.finish))
        var done: CopyDone?
        do {
            try readFrames(client) { type, payload in
                if type == CopyFrame.end { done = try? HostWire.decoder.decode(CopyDone.self, from: payload); return false }
                return true
            }
        } catch { throw fail(HostError.from(error), g) }
        guard let done else { throw fail(HostError(.failed, "the copy ended without its result"), g) }
        guard done.ok else { throw fail(HostError(.failed, "\(name):\(ready.path) — \(done.error ?? "failed")"), g) }
        if let why = ready.rootReason, !g.json, !g.quiet { Out.stderr("[doz] note: written as root — \(why)\n") }
        let what = kind == .folder ? "folder, \(max(0, measured.files - 1)) items" : "file"
        var j: [String: JSONValue] = ["sandbox": .string(name), "direction": .string("put"), "from": .string(source), "to": .string(ready.path),
                                      "kind": .string(kind.rawValue), "bytes": .number(Double(sent)), "milliseconds": .number(done.milliseconds),
                                      "runAs": .string(ready.runAs ?? "root")]
        if ready.replaces != nil { j["replaced"] = .bool(true) }
        say(g, j, "copied \(shown(abs)) → \(name):\(ready.path) (\(what); \(ProgressFormat.bytes(sent)) in \(ProgressFormat.duration(done.milliseconds / 1000)))"
            + (ready.replaces != nil ? " — replaced what was there" : ""))
    }

    /// A literal for bsdtar's -s (a basic regular expression), and for its replacement.
    static func bre(_ s: String) -> String {
        var o = ""
        for ch in s { if "\\.[]*^$/".contains(ch) { o.append("\\") }; o.append(ch) }
        return o
    }
    static func breReplacement(_ s: String) -> String {
        var o = ""
        for ch in s { if "\\~/".contains(ch) { o.append("\\") }; o.append(ch) }
        return o
    }
}

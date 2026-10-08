#!/usr/bin/env swift
// update-key.swift — Dozer's update-signing key (Ed25519, CryptoKit) and the signature on each feed entry.
//
//   swift Scripts/update-key.swift generate          # ONCE, by the owner (`make doz-update-keys`): makes the key in the
//                                                    # login keychain — after asking — and prints the PUBLIC key
//   swift Scripts/update-key.swift public            # print the public key of the key in the keychain
//   swift Scripts/update-key.swift export FILE       # a BACKUP of the private key to FILE (0600) — keep it offline
//   swift Scripts/update-key.swift sign-entry --version V --build N --archive NAME --sha256 HEX --size BYTES [--key-file F]
//                                                    # the entry's signature (base64) on stdout — `make publish` runs it
//   swift Scripts/update-key.swift verify-entry … --signature B64 --public-key B64
//   swift Scripts/update-key.swift test-key FILE     # a THROWAWAY keypair for tests: FILE holds the private key (base64),
//                                                    # the public key is printed. Never the real key.
//
// THE KEY. Dozer's own — never Deckosaurus's — and never rotated: every installed doz carries the public key compiled
// in (`Distribution.updatePublicKey`, Sources/DozerHost/Updates.swift) and refuses an entry it did not sign. Losing the
// private key means no installed doz can be told about a new release again. The private key lives ONLY in the login
// keychain of the Mac that publishes (generic password, service "dozersandbox.com update signing", account "ed25519",
// its raw 32 bytes base64) plus the owner's offline backup; publishing is local, never CI. It reaches `security` on
// STDIN (`security -i`), never in an argument, and this tool never prints it (only `export` writes it, to a file).
//
// WHAT IS SIGNED — the canonical message, byte for byte (`UpdateSignature.message` in doz builds the same):
//
//     dozer-sandbox update v1\n
//     version: <version>\n
//     build: <build>\n
//     archive: <file name of the tarball>\n
//     sha256: <lowercase hex>\n
//     size: <bytes>\n
//
// The file NAME (not the URL) is signed so the download host can move; the sha256 pins the bytes. The channel is NOT
// signed: promoting a build (canary → beta → stable) never needs the key — the same signed bytes move.
import CryptoKit
import Foundation

let service = "dozersandbox.com update signing"
let account = "ed25519"

func die(_ s: String) -> Never {
    FileHandle.standardError.write(Data("x update-key: \(s)\n".utf8))
    exit(1)
}

func message(version: String, build: String, archive: String, sha256: String, size: String) -> Data {
    Data("dozer-sandbox update v1\nversion: \(version)\nbuild: \(build)\narchive: \(archive)\nsha256: \(sha256.lowercased())\nsize: \(size)\n".utf8)
}

@discardableResult
func security(_ args: [String], stdin: String? = nil) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    let inPipe = Pipe()
    p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
    do { try p.run() } catch { die("cannot run /usr/bin/security") }
    if let stdin {
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func keychainKey() -> Curve25519.Signing.PrivateKey? {
    let r = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard r.status == 0, let raw = Data(base64Encoded: r.out) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func fileKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { die("\(path) does not hold a base64 Ed25519 private key") }
    return k
}

func ask(_ question: String) -> Bool {
    guard let tty = FileHandle(forUpdatingAtPath: "/dev/tty") else { return false }
    tty.write(Data("\(question) Type yes to go on: ".utf8))
    var line = Data()
    while true {
        let b = tty.readData(ofLength: 1)
        if b.isEmpty || b == Data("\n".utf8) { break }
        line.append(b)
    }
    return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces) == "yes"
}

func options(_ args: ArraySlice<String>) -> [String: String] {
    var o: [String: String] = [:]
    var it = args.makeIterator()
    while let a = it.next() {
        guard a.hasPrefix("--"), let v = it.next() else { die("unexpected \(a)") }
        o[String(a.dropFirst(2))] = v
    }
    return o
}

func entryMessage(_ o: [String: String]) -> Data {
    for k in ["version", "build", "archive", "sha256", "size"] where (o[k] ?? "").isEmpty { die("--\(k) is required") }
    guard o["sha256"]!.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { die("--sha256 is 64 hex") }
    guard Int(o["build"]!) != nil, Int(o["size"]!) != nil else { die("--build and --size are numbers") }
    guard !o["archive"]!.contains("/") else { die("--archive is the tarball's FILE NAME (not a URL)") }
    return message(version: o["version"]!, build: o["build"]!, archive: o["archive"]!, sha256: o["sha256"]!, size: o["size"]!)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if keychainKey() != nil || security(["find-generic-password", "-s", service, "-a", account]).status == 0 {
        die("the login keychain already holds Dozer's update-signing key (\(service)) — it is NEVER replaced (every installed doz trusts it); `public` prints its public key")
    }
    print("""
    This makes Dozer's update-signing key — Ed25519, Dozer's own — and keeps its private half in your LOGIN KEYCHAIN
    (generic password "\(service)", account "\(account)"). Every doz built afterwards trusts it, so it must never change:
    keep an offline backup (`swift Scripts/update-key.swift export FILE` writes one) — without the key, no installed doz
    can be offered an update again.
    """)
    guard ask("Create the key in your login keychain now?") else { die("not confirmed — nothing made") }
    let k = Curve25519.Signing.PrivateKey()
    let hex = k.rawRepresentation.base64EncodedString().utf8.map { String(format: "%02x", $0) }.joined()
    // `security -i`: the secret goes on STDIN (as hex, -X), never in a process argument.
    let r = security(["-i"], stdin: "add-generic-password -a \"\(account)\" -s \"\(service)\" -l \"\(service)\" -X \"\(hex)\"\n")
    guard r.status == 0, let back = keychainKey(), back.publicKey.rawRepresentation == k.publicKey.rawRepresentation else {
        die("the keychain did not keep the key (is the login keychain unlocked?) — nothing to use")
    }
    print("""

    Made. The PUBLIC key (commit it — it is not a secret):

        \(k.publicKey.rawRepresentation.base64EncodedString())

    Put it in Sources/DozerHost/Updates.swift as Distribution.updatePublicKey, then `make test`.
    Backup now, to a disk you keep offline:  swift Scripts/update-key.swift export /Volumes/<backup>/dozer-update-key.txt
    """)
case "public":
    guard let k = keychainKey() else { die("no update-signing key in the login keychain — `make doz-update-keys` makes it (once)") }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "export":
    guard let path = args.dropFirst().first else { die("export FILE") }
    guard let k = keychainKey() else { die("no update-signing key in the login keychain") }
    guard !FileManager.default.fileExists(atPath: path) else { die("\(path) exists — not overwritten") }
    guard FileManager.default.createFile(atPath: path, contents: Data((k.rawRepresentation.base64EncodedString() + "\n").utf8),
                                         attributes: [.posixPermissions: 0o600]) else { die("cannot write \(path)") }
    print("wrote the private key's backup to \(path) (0600) — keep it offline; it signs every doz update")
case "test-key":
    guard let path = args.dropFirst().first else { die("test-key FILE") }
    let k = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: path, contents: Data((k.rawRepresentation.base64EncodedString() + "\n").utf8),
                                         attributes: [.posixPermissions: 0o600]) else { die("cannot write \(path)") }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "sign-entry":
    let o = options(args.dropFirst())
    let key: Curve25519.Signing.PrivateKey
    if let f = o["key-file"] { key = fileKey(f) } else {
        guard let k = keychainKey() else { die("no update-signing key in the login keychain — `make doz-update-keys` makes it (once); tests pass --key-file") }
        key = k
    }
    var o2 = o
    o2["key-file"] = nil
    let sig = try key.signature(for: entryMessage(o2))
    print(sig.base64EncodedString())
case "verify-entry":
    var o = options(args.dropFirst())
    guard let s = o.removeValue(forKey: "signature"), let sig = Data(base64Encoded: s),
          let p = o.removeValue(forKey: "public-key"), let raw = Data(base64Encoded: p),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { die("--signature and --public-key (base64)") }
    if pub.isValidSignature(sig, for: entryMessage(o)) { print("valid") } else { print("INVALID"); exit(1) }
default:
    die("generate | public | export FILE | sign-entry … | verify-entry … | test-key FILE")
}

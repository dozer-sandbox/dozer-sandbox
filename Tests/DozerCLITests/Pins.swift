import Foundation
import XCTest

/// 617 step 0: golden text files for the behaviour and CLI-spelling pins — `Tests/Fixtures/pins/<name>.txt`
/// (outside every target, so SwiftPM does not treat them as resources). A pin is plain text so a reviewer reads
/// the behaviour it holds, and a change shows as a diff. A missing file is written and the test FAILS ("recorded"),
/// so a pin is only ever created on purpose and committed; an existing one is never rewritten by a test.
enum Pins {
    static let packageRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" {
            u.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("Package.swift").path) { return u }
        }
        fatalError("no Package.swift above \(#filePath)")
    }()

    /// `test_x()` (a `#function`) → `x`.
    static func url(_ name: String) -> URL {
        var n = name.hasSuffix("()") ? String(name.dropLast(2)) : name
        if n.hasPrefix("test_") { n.removeFirst(5) }
        return packageRoot.appendingPathComponent("Tests/Fixtures/pins/\(n).txt")
    }

    static func check(_ name: String, _ actual: String, file: StaticString = #filePath, line: UInt = #line) {
        let u = url(name)
        let text = actual.hasSuffix("\n") ? actual : actual + "\n"
        guard let expected = try? String(contentsOf: u, encoding: .utf8) else {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: u, options: .atomic)
            XCTFail("pin \(name) recorded at \(u.path) — review and commit it, then re-run", file: file, line: line)
            return
        }
        guard expected != text else { return }
        let e = expected.components(separatedBy: "\n"), a = text.components(separatedBy: "\n")
        var diff: [String] = []
        for i in 0..<max(e.count, a.count) where (i < e.count ? e[i] : nil) != (i < a.count ? a[i] : nil) {
            diff.append("line \(i + 1):\n  pinned: \(i < e.count ? e[i] : "(none)")\n  now:    \(i < a.count ? a[i] : "(none)")")
            if diff.count == 12 { diff.append("…"); break }
        }
        XCTFail("pin \(name) (\(u.path)) changed:\n" + diff.joined(separator: "\n"), file: file, line: line)
    }
}

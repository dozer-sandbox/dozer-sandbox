import Darwin
import Foundation

/// 594 (D10) — questions on the terminal: `doz onboard` and `doz init` ask on a TTY, with the
/// recommended answer pre-selected (Enter accepts it); `--yes` accepts every default; not a terminal
/// or `--json` never asks (a missing answer with no default is an error). Asked on /dev/tty — never
/// stdin, which may carry data.
struct Asker {
    /// True: questions are asked. False: every answer is its default.
    let interactive: Bool
    private let fd: Int32

    /// Interactive only when stdin and stdout are terminals, and neither `yes` nor `json`.
    init(yes: Bool, json: Bool) {
        if yes || json || isatty(STDIN_FILENO) != 1 || isatty(STDOUT_FILENO) != 1 {
            interactive = false
            fd = -1
        } else {
            let f = open("/dev/tty", O_RDWR | O_CLOEXEC)
            interactive = f >= 0
            fd = f
        }
    }

    private func write(_ s: String) { _ = s.withCString { Darwin.write(fd, $0, strlen($0)) } }

    private func readLine() -> String? {
        var buf = [UInt8]()
        var c: UInt8 = 0
        while true {
            let n = read(fd, &c, 1)
            if n <= 0 { return buf.isEmpty ? nil : String(decoding: buf, as: UTF8.self) }
            if c == 10 { break }
            buf.append(c)
            if buf.count > 4096 { break }
        }
        return String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A line of text; Enter keeps `default`. `valid` returns an error message to ask again.
    func text(_ question: String, default def: String, valid: (String) -> String? = { _ in nil }) -> String {
        guard interactive else { return def }
        while true {
            write("\(question) [\(def)]: ")
            guard let line = readLine() else { write("\n"); return def }
            let v = line.isEmpty ? def : line
            if let why = valid(v) { write("  \(why)\n"); continue }
            return v
        }
    }

    /// One of `options` (numbered); Enter keeps `preferred`.
    func choose(_ question: String, _ options: [String], preferred: Int) -> Int {
        guard interactive else { return preferred }
        write("\(question)\n")
        for (i, o) in options.enumerated() { write("  \(i + 1)) \(o)\(i == preferred ? "   ← recommended" : "")\n") }
        while true {
            write("Choose 1–\(options.count) [\(preferred + 1)]: ")
            guard let line = readLine() else { write("\n"); return preferred }
            if line.isEmpty { return preferred }
            if let n = Int(line), (1...options.count).contains(n) { return n - 1 }
            write("  a number from 1 to \(options.count)\n")
        }
    }

    /// A checklist (numbered, ticked ones marked); Enter keeps the ticks; else the numbers wanted
    /// (`1,3`), or `0` for none.
    func checklist(_ question: String, _ items: [(label: String, ticked: Bool)]) -> [Bool] {
        let def = items.map(\.ticked)
        guard interactive else { return def }
        write("\(question)\n")
        for (i, it) in items.enumerated() { write("  [\(it.ticked ? "x" : " ")] \(i + 1)) \(it.label)\n") }
        while true {
            write("Enter keeps the ticked ones; or type the numbers you want (e.g. 1,3), 0 for none: ")
            guard let line = readLine() else { write("\n"); return def }
            if line.isEmpty { return def }
            if line == "0" { return items.map { _ in false } }
            let parts = line.split(whereSeparator: { $0 == "," || $0 == " " }).map { Int($0) }
            if parts.allSatisfy({ $0 != nil && (1...items.count).contains($0!) }) {
                let set = Set(parts.map { $0! - 1 })
                return items.indices.map { set.contains($0) }
            }
            write("  numbers from 1 to \(items.count), separated by commas\n")
        }
    }

    /// Yes or no; Enter keeps `default`.
    func yesNo(_ question: String, default def: Bool) -> Bool {
        guard interactive else { return def }
        while true {
            write("\(question) [\(def ? "Y/n" : "y/N")]: ")
            guard let line = readLine()?.lowercased() else { write("\n"); return def }
            if line.isEmpty { return def }
            if ["y", "yes"].contains(line) { return true }
            if ["n", "no"].contains(line) { return false }
        }
    }
}

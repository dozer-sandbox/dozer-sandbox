import Foundation

// 591 settings — a small, STRICT reader and writer for the TOML the settings file uses, our own (no
// new dependency). The subset: `[section]` / `[a.b]` headers of bare keys, `key = value` with a bare
// key, `#` comments, and three value types — basic "strings" (with TOML's escapes) or 'literal'
// strings, booleans, and decimal integers. Everything else TOML has (floats, dates, arrays, inline
// tables, multi-line strings, dotted or quoted keys, arrays of tables) is refused with the line
// number: the settings file never needs it, and a reader that half-understands a value is worse than
// one that says so. A duplicate key or section is an error, as TOML says.

/// One value.
public enum TOMLValue: Equatable, Sendable, CustomStringConvertible {
    case string(String)
    case bool(Bool)
    case int(Int)

    /// As TOML writes it (`"text"`, `true`, `42`).
    public var description: String { TOML.render(self) }

    /// As a person reads it (a string without quotes).
    public var plain: String {
        switch self {
        case .string(let s): s
        case .bool(let b): b ? "true" : "false"
        case .int(let i): String(i)
        }
    }

    public var typeName: String {
        switch self {
        case .string: "string"
        case .bool: "boolean"
        case .int: "integer"
        }
    }
}

/// In JSON (the CLI's --json, the web UI): the plain JSON value — `true`, `13`, `"shell"`.
extension TOMLValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "a string, a boolean or a whole number")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        }
    }
}

/// One `key = value` line, where it was.
public struct TOMLEntry: Equatable, Sendable {
    /// The table it is in (`""` at the top, `images.lab` under `[images.lab]`).
    public var section: String
    public var key: String
    public var value: TOMLValue
    public var line: Int

    public init(section: String, key: String, value: TOMLValue, line: Int = 0) {
        self.section = section
        self.key = key
        self.value = value
        self.line = line
    }

    /// `section.key` (just `key` at the top level).
    public var path: String { section.isEmpty ? key : "\(section).\(key)" }
}

public struct TOMLError: Error, Equatable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public init(line: Int, _ message: String) {
        self.line = line
        self.message = message
    }
    public var description: String { line > 0 ? "line \(line): \(message)" : message }
}

public enum TOML {
    /// A settings file is small; anything bigger is not one.
    public static let maximumBytes = 64 * 1024

    /// Parse a document into its entries, in file order.
    public static func parse(_ text: String) throws -> [TOMLEntry] {
        guard text.utf8.count <= maximumBytes else { throw TOMLError(line: 0, "the file is over \(maximumBytes / 1024) KiB") }
        var entries: [TOMLEntry] = []
        var section = ""
        var sections: Set<String> = [""]
        var seen: Set<String> = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let n = i + 1
            var line = Substring(raw)
            if line.hasSuffix("\r") { line = line.dropLast() }
            var s = Scanner(line, line: n)
            s.skipSpace()
            if s.atEnd || s.peek == "#" { continue }
            if s.peek == "[" {
                s.advance()
                if s.peek == "[" { throw TOMLError(line: n, "arrays of tables ([[…]]) are not supported") }
                s.skipSpace()
                var parts: [String] = []
                while true {
                    parts.append(try s.bareKey())
                    s.skipSpace()
                    if s.peek == "." { s.advance(); s.skipSpace(); continue }
                    break
                }
                guard s.peek == "]" else { throw TOMLError(line: n, "a section header is [name] (bare names, dot-separated)") }
                s.advance()
                try s.expectEndOfLine()
                section = parts.joined(separator: ".")
                guard sections.insert(section).inserted else { throw TOMLError(line: n, "section [\(section)] appears twice") }
                continue
            }
            let key = try s.bareKey()
            s.skipSpace()
            if s.peek == "." { throw TOMLError(line: n, "dotted keys are not supported — use a [section]") }
            guard s.peek == "=" else { throw TOMLError(line: n, "expected key = value") }
            s.advance()
            s.skipSpace()
            let value = try s.value()
            try s.expectEndOfLine()
            let entry = TOMLEntry(section: section, key: key, value: value, line: n)
            guard seen.insert(entry.path).inserted else { throw TOMLError(line: n, "\(entry.path) is set twice") }
            entries.append(entry)
        }
        return entries
    }

    /// A value as TOML.
    public static func render(_ v: TOMLValue) -> String {
        switch v {
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .string(let s):
            var out = "\""
            for u in s.unicodeScalars {
                switch u {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\t": out += "\\t"
                case "\r": out += "\\r"
                default:
                    if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
                }
            }
            return out + "\""
        }
    }

    /// A bare key: `A-Za-z0-9_-`, at least one.
    public static func isBareKey(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy(isBareKeyScalar)
    }

    static func isBareKeyScalar(_ u: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(u) || ("A"..."Z").contains(u) || ("0"..."9").contains(u) || u == "_" || u == "-"
    }

    /// A cursor over one line.
    struct Scanner {
        let scalars: [Unicode.Scalar]
        var i = 0
        let line: Int

        init(_ text: Substring, line: Int) {
            scalars = Array(text.unicodeScalars)
            self.line = line
        }

        var atEnd: Bool { i >= scalars.count }
        var peek: Unicode.Scalar? { atEnd ? nil : scalars[i] }
        mutating func advance() { i += 1 }
        mutating func skipSpace() { while let c = peek, c == " " || c == "\t" { advance() } }

        func fail(_ m: String) -> TOMLError { TOMLError(line: line, m) }

        mutating func expectEndOfLine() throws {
            skipSpace()
            guard atEnd || peek == "#" else { throw fail("unexpected text after the value (a comment starts with #)") }
            if peek == "#" {
                // A comment may hold anything but control characters (tab is fine).
                for c in scalars[i...] where (c.value < 0x20 && c != "\t") || c.value == 0x7F {
                    throw fail("a control character in a comment")
                }
            }
        }

        mutating func bareKey() throws -> String {
            if peek == "\"" || peek == "'" { throw fail("quoted keys are not supported") }
            var k = String.UnicodeScalarView()
            while let c = peek, TOML.isBareKeyScalar(c) { k.append(c); advance() }
            guard !k.isEmpty else { throw fail("expected a key (letters, digits, _ and -)") }
            return String(k)
        }

        mutating func value() throws -> TOMLValue {
            guard let c = peek else { throw fail("a value is missing") }
            switch c {
            case "\"":
                if i + 2 < scalars.count, scalars[i + 1] == "\"", scalars[i + 2] == "\"" { throw fail("multi-line strings are not supported") }
                return .string(try basicString())
            case "'":
                if i + 2 < scalars.count, scalars[i + 1] == "'", scalars[i + 2] == "'" { throw fail("multi-line strings are not supported") }
                return .string(try literalString())
            case "[": throw fail("arrays are not supported")
            case "{": throw fail("inline tables are not supported")
            default:
                var word = String.UnicodeScalarView()
                while let d = peek, d != " ", d != "\t", d != "#" { word.append(d); advance() }
                let w = String(word)
                if w == "true" { return .bool(true) }
                if w == "false" { return .bool(false) }
                if let v = Self.integer(w) { return .int(v) }
                throw fail("unsupported value \(w.prefix(40)) — strings, booleans (true/false) and whole numbers only")
            }
        }

        /// Decimal, optional sign, `_` only between digits, no leading zero.
        static func integer(_ w: String) -> Int? {
            var digits = Substring(w)
            var negative = false
            if let f = digits.first, f == "+" || f == "-" { negative = f == "-"; digits = digits.dropFirst() }
            guard let first = digits.first, first.isASCII, first.isNumber else { return nil }
            if first == "0", digits.count > 1 { return nil }
            var prevUnderscore = false
            var clean = ""
            for ch in digits {
                if ch == "_" {
                    guard !prevUnderscore, !clean.isEmpty else { return nil }
                    prevUnderscore = true
                    continue
                }
                guard ch.isASCII, ch.isNumber else { return nil }
                prevUnderscore = false
                clean.append(ch)
            }
            guard !prevUnderscore else { return nil }
            return Int((negative ? "-" : "") + clean)
        }

        mutating func basicString() throws -> String {
            advance()
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek else { throw fail("a string is not closed") }
                advance()
                switch c {
                case "\"": return String(out)
                case "\\":
                    guard let e = peek else { throw fail("a string is not closed") }
                    advance()
                    switch e {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u", "U":
                        let count = e == "u" ? 4 : 8
                        guard i + count <= scalars.count else { throw fail("a short \\\(e) escape") }
                        let hex = String(String.UnicodeScalarView(scalars[i..<(i + count)]))
                        guard let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else { throw fail("an invalid \\\(e) escape") }
                        i += count
                        out.append(u)
                    default: throw fail("an unknown escape \\\(e)")
                    }
                default:
                    if (c.value < 0x20 && c != "\t") || c.value == 0x7F { throw fail("a control character in a string") }
                    out.append(c)
                }
            }
        }

        mutating func literalString() throws -> String {
            advance()
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek else { throw fail("a string is not closed") }
                advance()
                if c == "'" { return String(out) }
                if (c.value < 0x20 && c != "\t") || c.value == 0x7F { throw fail("a control character in a string") }
                out.append(c)
            }
        }
    }
}

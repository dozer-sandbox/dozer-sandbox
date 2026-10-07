import Foundation

// 606 — a QR code encoder of our own (no dependency): what `doz serve share` draws on a terminal and the
// dashboard draws as SVG, so a phone can scan its way in. ISO/IEC 18004: byte mode only, versions 1–10
// (up to 213 bytes at level M — a share link is ~80), the four error-correction levels, all eight masks
// scored by the standard's four penalty rules. The matrix is DATA (dark/light modules) — the page builds
// its SVG from it with createElementNS; nothing here is markup.

public struct WebQR: Equatable, Sendable {
    /// Error-correction level. The raw value is its two format bits (L 01, M 00, Q 11, H 10).
    public enum Level: Int, Sendable, CaseIterable {
        case low = 1, medium = 0, quartile = 3, high = 2
        /// The row of `WebQR.blocks` for this level.
        var index: Int { switch self { case .low: 0; case .medium: 1; case .quartile: 2; case .high: 3 } }
    }

    public enum Failure: Error, Equatable, Sendable { case tooLong }

    public let version: Int
    public let level: Level
    public let mask: Int
    /// Modules per side (`17 + 4 × version`).
    public let size: Int
    /// Row-major, `true` = dark.
    public let modules: [Bool]

    public func isDark(x: Int, y: Int) -> Bool { modules[y * size + x] }

    /// The matrix as rows of "1" (dark) and "0" (light) — what the dashboard receives.
    public var rows: [String] {
        (0..<size).map { y in String((0..<size).map { modules[y * size + $0] ? "1" : "0" }) }
    }

    public static let maximumVersion = 10

    /// A matrix received as rows ("1" dark) — the CLI draws an invite's QR code from `doz serve`'s answer.
    public init?(rows: [String]) {
        let n = rows.count
        guard (21...177).contains(n), (n - 17) % 4 == 0, rows.allSatisfy({ $0.count == n && $0.allSatisfy { $0 == "0" || $0 == "1" } }) else { return nil }
        version = (n - 17) / 4
        level = .medium
        mask = 0
        size = n
        modules = rows.flatMap { $0.map { $0 == "1" } }
    }

    init(version: Int, level: Level, mask: Int, size: Int, modules: [Bool]) {
        self.version = version
        self.level = level
        self.mask = mask
        self.size = size
        self.modules = modules
    }

    /// Encode `text` (UTF-8, byte mode) at the smallest version that holds it at `level`.
    public static func encode(_ text: String, level: Level = .medium) throws -> WebQR {
        try encode(bytes: Array(text.utf8), level: level)
    }

    public static func encode(bytes: [UInt8], level: Level) throws -> WebQR {
        guard let version = (1...maximumVersion).first(where: { dataCapacityBits($0, level) >= 4 + countBits($0) + bytes.count * 8 }) else {
            throw Failure.tooLong
        }
        let codewords = interleaved(dataCodewords(bytes, version: version, level: level), version: version, level: level)
        var m = Matrix(version: version)
        m.drawFunctionPatterns()
        m.placeData(codewords)
        var best: (penalty: Int, mask: Int, grid: [Bool])?
        for mask in 0..<8 {
            var t = m
            t.applyMask(mask)
            t.drawFormat(level: level, mask: mask)
            let p = t.penalty()
            if best == nil || p < best!.penalty { best = (p, mask, t.dark) }
        }
        return WebQR(version: version, level: level, mask: best!.mask, size: m.size, modules: best!.grid)
    }

    // MARK: capacity and the codewords

    /// Per version (1…10), per level (L, M, Q, H): error-correction codewords per block, then the
    /// blocks of group 1 and their data codewords, then group 2's (ISO/IEC 18004 table 9).
    static let blocks: [[(ecc: Int, g1: Int, d1: Int, g2: Int, d2: Int)]] = [
        [(7, 1, 19, 0, 0), (10, 1, 16, 0, 0), (13, 1, 13, 0, 0), (17, 1, 9, 0, 0)],
        [(10, 1, 34, 0, 0), (16, 1, 28, 0, 0), (22, 1, 22, 0, 0), (28, 1, 16, 0, 0)],
        [(15, 1, 55, 0, 0), (26, 1, 44, 0, 0), (18, 2, 17, 0, 0), (22, 2, 13, 0, 0)],
        [(20, 1, 80, 0, 0), (18, 2, 32, 0, 0), (26, 2, 24, 0, 0), (16, 4, 9, 0, 0)],
        [(26, 1, 108, 0, 0), (24, 2, 43, 0, 0), (18, 2, 15, 2, 16), (22, 2, 11, 2, 12)],
        [(18, 2, 68, 0, 0), (16, 4, 27, 0, 0), (24, 4, 19, 0, 0), (28, 4, 15, 0, 0)],
        [(20, 2, 78, 0, 0), (18, 4, 31, 0, 0), (18, 2, 14, 4, 15), (26, 4, 13, 1, 14)],
        [(24, 2, 97, 0, 0), (22, 2, 38, 2, 39), (22, 4, 18, 2, 19), (26, 4, 14, 2, 15)],
        [(30, 2, 116, 0, 0), (22, 3, 36, 2, 37), (20, 4, 16, 4, 17), (24, 4, 12, 4, 13)],
        [(18, 2, 68, 2, 69), (26, 4, 43, 1, 44), (24, 6, 19, 2, 20), (28, 6, 15, 2, 16)],
    ]

    static func layout(_ version: Int, _ level: Level) -> (ecc: Int, g1: Int, d1: Int, g2: Int, d2: Int) {
        blocks[version - 1][level.index]
    }

    static func dataCapacityBits(_ version: Int, _ level: Level) -> Int {
        let b = layout(version, level)
        return (b.g1 * b.d1 + b.g2 * b.d2) * 8
    }

    /// The byte mode's character-count field: 8 bits up to version 9, 16 from 10.
    static func countBits(_ version: Int) -> Int { version <= 9 ? 8 : 16 }

    /// Mode, count, the bytes, the terminator, then the pad bytes 0xEC 0x11 … to the capacity.
    static func dataCodewords(_ bytes: [UInt8], version: Int, level: Level) -> [UInt8] {
        var bits: [Bool] = []
        func put(_ value: Int, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) } }
        put(0b0100, 4)
        put(bytes.count, countBits(version))
        for b in bytes { put(Int(b), 8) }
        let capacity = dataCapacityBits(version, level)
        put(0, min(4, capacity - bits.count))
        while bits.count % 8 != 0 { bits.append(false) }
        var out: [UInt8] = stride(from: 0, to: bits.count, by: 8).map { i in
            (0..<8).reduce(UInt8(0)) { $0 << 1 | (bits[i + $1] ? 1 : 0) }
        }
        var pad: UInt8 = 0xEC
        while out.count * 8 < capacity { out.append(pad); pad = pad == 0xEC ? 0x11 : 0xEC }
        return out
    }

    /// Split into the blocks, add each block's Reed–Solomon codewords, interleave (data, then ECC).
    static func interleaved(_ data: [UInt8], version: Int, level: Level) -> [UInt8] {
        let b = layout(version, level)
        var blocksData: [[UInt8]] = []
        var at = 0
        for (count, len) in [(b.g1, b.d1), (b.g2, b.d2)] {
            for _ in 0..<count { blocksData.append(Array(data[at..<at + len])); at += len }
        }
        let eccs = blocksData.map { reedSolomon($0, ecc: b.ecc) }
        var out: [UInt8] = []
        for i in 0..<max(b.d1, b.d2) { for d in blocksData where i < d.count { out.append(d[i]) } }
        for i in 0..<b.ecc { for e in eccs { out.append(e[i]) } }
        return out
    }

    // MARK: Reed–Solomon over GF(256), x^8 + x^4 + x^3 + x^2 + 1

    static let exp: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 512)
        var x = 1
        for i in 0..<255 {
            t[i] = UInt8(x)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { t[i] = t[i - 255] }
        return t
    }()
    static let log: [Int] = {
        var t = [Int](repeating: 0, count: 256)
        for i in 0..<255 { t[Int(exp[i])] = i }
        return t
    }()

    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 || b == 0 ? 0 : exp[log[Int(a)] + log[Int(b)]]
    }

    /// The generator polynomial ∏ (x − α^i), i < degree — coefficients from the highest power, the leading 1 dropped.
    static func generator(_ degree: Int) -> [UInt8] {
        var g: [UInt8] = [1]
        for i in 0..<degree {
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (j, c) in g.enumerated() {
                next[j] ^= c
                next[j + 1] ^= multiply(c, exp[i])
            }
            g = next
        }
        return Array(g.dropFirst())
    }

    /// The `ecc` error-correction codewords of `data`.
    static func reedSolomon(_ data: [UInt8], ecc: Int) -> [UInt8] {
        let g = generator(ecc)
        var r = [UInt8](repeating: 0, count: ecc)
        for d in data {
            let factor = d ^ r[0]
            r.removeFirst()
            r.append(0)
            for i in 0..<ecc { r[i] ^= multiply(g[i], factor) }
        }
        return r
    }

    // MARK: format and version information

    /// The 15 format bits for a level and mask (BCH(15,5), then XOR 0x5412).
    static func formatBits(level: Level, mask: Int) -> Int {
        let data = level.rawValue << 3 | mask
        var rem = data
        for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
        return (data << 10 | rem) ^ 0x5412
    }

    /// The 18 version bits (BCH(18,6)) for version 7 and up.
    static func versionBits(_ version: Int) -> Int {
        var rem = version
        for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
        return version << 12 | rem
    }

    static func alignmentPositions(_ version: Int) -> [Int] {
        guard version > 1 else { return [] }
        let size = 17 + 4 * version
        let count = version / 7 + 2
        let step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
        var out = [6]
        var pos = size - 7
        for _ in 0..<(count - 1) { out.insert(pos, at: 1); pos -= step }
        return out
    }

    // MARK: the matrix

    struct Matrix {
        let version: Int
        let size: Int
        var dark: [Bool]
        var function: [Bool]

        init(version: Int) {
            self.version = version
            size = 17 + 4 * version
            dark = [Bool](repeating: false, count: size * size)
            function = dark
        }

        mutating func set(_ x: Int, _ y: Int, _ v: Bool) {
            dark[y * size + x] = v
            function[y * size + x] = true
        }

        mutating func drawFunctionPatterns() {
            for i in 0..<size {
                set(6, i, i % 2 == 0)
                set(i, 6, i % 2 == 0)
            }
            finder(3, 3)
            finder(size - 4, 3)
            finder(3, size - 4)
            let a = WebQR.alignmentPositions(version)
            for (i, ax) in a.enumerated() {
                for (j, ay) in a.enumerated() where !((i == 0 && j == 0) || (i == 0 && j == a.count - 1) || (i == a.count - 1 && j == 0)) {
                    for dy in -2...2 { for dx in -2...2 { set(ax + dx, ay + dy, max(abs(dx), abs(dy)) != 1) } }
                }
            }
            // Reserve the format areas (drawn per mask), and the version areas.
            drawFormat(level: .medium, mask: 0)
            if version >= 7 {
                let bits = WebQR.versionBits(version)
                for i in 0..<18 {
                    let v = (bits >> i) & 1 == 1
                    let a = size - 11 + i % 3, b = i / 3
                    set(a, b, v)
                    set(b, a, v)
                }
            }
        }

        /// A finder pattern centred at (cx, cy), with its light separator.
        mutating func finder(_ cx: Int, _ cy: Int) {
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = cx + dx, y = cy + dy
                    guard (0..<size).contains(x), (0..<size).contains(y) else { continue }
                    let d = max(abs(dx), abs(dy))
                    set(x, y, d != 2 && d != 4)
                }
            }
        }

        mutating func drawFormat(level: Level, mask: Int) {
            let bits = WebQR.formatBits(level: level, mask: mask)
            func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
            for i in 0...5 { set(8, i, bit(i)) }
            set(8, 7, bit(6))
            set(8, 8, bit(7))
            set(7, 8, bit(8))
            for i in 9..<15 { set(14 - i, 8, bit(i)) }
            for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
            for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
            set(8, size - 8, true)                                   // the dark module
        }

        /// The codewords in the two-column zigzag from the bottom right, skipping the timing column.
        mutating func placeData(_ codewords: [UInt8]) {
            var i = 0
            let total = codewords.count * 8
            var right = size - 1
            while right >= 1 {
                if right == 6 { right = 5 }
                for vert in 0..<size {
                    for j in 0..<2 {
                        let x = right - j
                        let upward = (right + 1) & 2 == 0
                        let y = upward ? size - 1 - vert : vert
                        guard !function[y * size + x] else { continue }
                        if i < total {
                            dark[y * size + x] = (codewords[i >> 3] >> (7 - (i & 7))) & 1 == 1
                            i += 1
                        }                                             // the remainder bits stay light
                    }
                }
                right -= 2
            }
        }

        mutating func applyMask(_ mask: Int) {
            for y in 0..<size {
                for x in 0..<size where !function[y * size + x] {
                    let flip = switch mask {
                    case 0: (x + y) % 2 == 0
                    case 1: y % 2 == 0
                    case 2: x % 3 == 0
                    case 3: (x + y) % 3 == 0
                    case 4: (x / 3 + y / 2) % 2 == 0
                    case 5: x * y % 2 + x * y % 3 == 0
                    case 6: (x * y % 2 + x * y % 3) % 2 == 0
                    default: ((x + y) % 2 + x * y % 3) % 2 == 0
                    }
                    if flip { dark[y * size + x].toggle() }
                }
            }
        }

        func at(_ x: Int, _ y: Int) -> Bool { dark[y * size + x] }

        /// The standard's four penalty rules (N1 3, N2 3, N3 40, N4 10).
        func penalty() -> Int {
            var p = 0
            // 1: runs of five or more of one colour, in rows and columns.
            for horizontal in [true, false] {
                for a in 0..<size {
                    var run = 1
                    for b in 1..<size {
                        let same = horizontal ? at(b, a) == at(b - 1, a) : at(a, b) == at(a, b - 1)
                        if same { run += 1 } else { if run >= 5 { p += 3 + run - 5 }; run = 1 }
                    }
                    if run >= 5 { p += 3 + run - 5 }
                }
            }
            // 2: each 2×2 block of one colour.
            for y in 0..<size - 1 {
                for x in 0..<size - 1 where at(x, y) == at(x + 1, y) && at(x, y) == at(x, y + 1) && at(x, y) == at(x + 1, y + 1) {
                    p += 3
                }
            }
            // 3: the finder-like 1:1:3:1:1 with four light modules on a side (outside the symbol counts as light).
            let pattern: [Bool] = [true, false, true, true, true, false, true]
            func light(_ x: Int, _ y: Int) -> Bool { !(0..<size).contains(x) || !(0..<size).contains(y) || !at(x, y) }
            for horizontal in [true, false] {
                for a in 0..<size {
                    for b in 0...(size - 7) {
                        let ok = (0..<7).allSatisfy { k in (horizontal ? at(b + k, a) : at(a, b + k)) == pattern[k] }
                        guard ok else { continue }
                        let before = (1...4).allSatisfy { k in horizontal ? light(b - k, a) : light(a, b - k) }
                        let after = (7...10).allSatisfy { k in horizontal ? light(b + k, a) : light(a, b + k) }
                        if before || after { p += 40 }
                    }
                }
            }
            // 4: how far the share of dark modules is from half, in 5 % steps.
            let darkCount = dark.filter { $0 }.count
            p += abs(darkCount * 20 - size * size * 10) / (size * size) * 10
            return p
        }
    }
}

extension WebQR {
    /// The code drawn with Unicode half blocks, two module rows per text line, dark on light with a
    /// four-module quiet zone. `ansi`: black on white explicitly (what a phone camera needs, whatever the
    /// terminal's colours); without it, the light modules are drawn as blocks (for a dark terminal).
    public func terminalText(ansi: Bool) -> String {
        let q = 4, n = size + 2 * q
        func darkAt(_ x: Int, _ y: Int) -> Bool {
            let mx = x - q, my = y - q
            guard (0..<size).contains(mx), (0..<size).contains(my) else { return false }
            return isDark(x: mx, y: my)
        }
        var out = ""
        for y in stride(from: 0, to: n, by: 2) {
            var line = ansi ? "\u{1B}[38;5;16;48;5;231m" : ""
            for x in 0..<n {
                let top = darkAt(x, y), bottom = y + 1 < n ? darkAt(x, y + 1) : false
                if ansi {
                    line += top && bottom ? "█" : top ? "▀" : bottom ? "▄" : " "
                } else {
                    // Inverted: a block where BOTH halves are light.
                    line += !top && !bottom ? "█" : !top ? "▀" : !bottom ? "▄" : " "
                }
            }
            out += line + (ansi ? "\u{1B}[0m" : "") + "\n"
        }
        return out
    }
}

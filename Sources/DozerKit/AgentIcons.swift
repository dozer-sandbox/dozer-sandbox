import Foundation

// 617 (owner: "we also need a registry of vendor / product icons (b&w only initially - support for colour later)") —
// ONE registry beside the recipes: `Recipes/icons/icons.json` + its SVG files, compiled in. Two kinds: a `vendor`
// (anthropic, openai, google, xai) and a `product` (claude-code, codex, …, each naming its vendor). A recipe names its
// product (`icon`); resolution is product → its vendor → a generated lettermark, so nothing is ever blank.
//
// · A MONO file is one `<path>` drawn in `currentColor` (stroked, or filled) under a viewBox — no colour, no script, no
//   reference, no text (`MonoSVG.check`, byte-exact shape). The page and a website colour it with CSS.
// · `variants` has room for `color` and `color-dark` (the schema accepts them; nothing draws them yet).
// · `allowed`: `official` (the maker's own mark, used as its brand terms allow, only made monochrome) | `lettermark`
//   (a neutral mark Dozer draws — `Lettermark`, deterministic; the file must be exactly what it draws). Each entry
//   records where its mark came from, the brand terms it was checked against, and when.

public struct IconEntry: Codable, Sendable, Equatable {
    public struct Variants: Codable, Sendable, Equatable {
        /// The monochrome file (required).
        public var mono: String
        /// Later: the maker's colours (accepted, not drawn yet).
        public var color: String?
        public var colorDark: String?
        enum CodingKeys: String, CodingKey { case mono, color, colorDark = "color-dark" }
    }
    public var id: String
    /// `vendor` | `product`.
    public var kind: String
    public var name: String
    /// A product's maker (a vendor id); nil for one with no company (pi).
    public var vendor: String?
    public var variants: Variants
    /// Where the mark came from: the maker's page for an official mark; for a lettermark, Dozer's generator.
    public var source: String
    /// The brand terms checked.
    public var terms: String?
    /// `official` | `lettermark`.
    public var allowed: String
    /// YYYY-MM-DD.
    public var checked: String
    public var notes: String?
    /// A lettermark's letters and frame (what `Lettermark` draws).
    public var lettermark: Lettermark.Spec?
}

/// One mark, ready to draw: a viewBox and one path (stroked when `stroke` is set, else filled), in currentColor.
public struct ResolvedIcon: Codable, Sendable, Equatable {
    /// The registry id (`claude-code`), or `letter-x` for a generated one.
    public var id: String
    /// `product` | `vendor` | `generated`.
    public var kind: String
    /// `official` | `lettermark`.
    public var allowed: String
    public var viewBox: String
    public var d: String
    public var stroke: Double?
    /// The registry's file (`icons/claude-code.svg`) — what a website fetches; nil for a generated one.
    public var mono: String?
}

public enum AgentIcons {
    struct File: Codable {
        /// The editor's schema link (schema/dozer-icons-1.schema.json).
        var schemaLink: String?
        var schema: Int
        var icons: [IconEntry]
        enum CodingKeys: String, CodingKey { case schemaLink = "$schema", schema, icons }
    }

    /// The manifest from its JSON: refused when it carries a key this build does not know (as the schema says).
    static func decodeManifest(_ data: Data) throws -> [IconEntry] {
        let f = try JSONDecoder().decode(File.self, from: data)
        guard f.schema == 1 else { throw SandboxError.invalidSpec("icons.json: schema \(f.schema) — this build reads 1") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let back = try JSONSerialization.jsonObject(with: try enc.encode(f))
        if let unknown = AgentRecipes.unknownKey(try JSONSerialization.jsonObject(with: data), back, path: "") {
            throw SandboxError.invalidSpec("icons.json: unknown key \(unknown)")
        }
        return f.icons
    }

    /// The compiled-in files, by name (Package.swift embeds each; `AgentIconsTests` ties this list to the folder).
    public static let files: [String: [UInt8]] = [
        "anthropic.svg": PackageResources.anthropic_svg, "openai.svg": PackageResources.openai_svg,
        "google.svg": PackageResources.google_svg, "xai.svg": PackageResources.xai_svg,
        "claude-code.svg": PackageResources.claude_code_svg, "codex.svg": PackageResources.codex_svg,
        "antigravity.svg": PackageResources.antigravity_svg, "gemini-cli.svg": PackageResources.gemini_cli_svg,
        "grok-build.svg": PackageResources.grok_build_svg, "pi.svg": PackageResources.pi_svg,
        "fabric.svg": PackageResources.fabric_svg,
        "openclaw.svg": PackageResources.openclaw_svg,
        "nanobot.svg": PackageResources.nanobot_svg,
        "gptme.svg": PackageResources.gptme_svg,
        "llm.svg": PackageResources.llm_svg,
        "shell-gpt.svg": PackageResources.shell_gpt_svg,
        "zeroclaw.svg": PackageResources.zeroclaw_svg,
        "aichat.svg": PackageResources.aichat_svg,
        "tgpt.svg": PackageResources.tgpt_svg,
        "opencode.svg": PackageResources.opencode_svg,
        "smolagents.svg": PackageResources.smolagents_svg,
        "adk.svg": PackageResources.adk_svg,
        "promptfoo.svg": PackageResources.promptfoo_svg,
        "clai.svg": PackageResources.clai_svg,
        "copilot.svg": PackageResources.copilot_svg,
        "qwen-code.svg": PackageResources.qwen_code_svg,
        "goose.svg": PackageResources.goose_svg,
        "kilo.svg": PackageResources.kilo_svg,
        "mistral-vibe.svg": PackageResources.mistral_vibe_svg,
        "droid.svg": PackageResources.droid_svg,
        "dirac.svg": PackageResources.dirac_svg,
        "kimi-code.svg": PackageResources.kimi_code_svg,
        "every-code.svg": PackageResources.every_code_svg,
        "cline.svg": PackageResources.cline_svg,
        "openhands.svg": PackageResources.openhands_svg,
        "codebuddy.svg": PackageResources.codebuddy_svg,
        "letta-code.svg": PackageResources.letta_code_svg,
        "docker-agent.svg": PackageResources.docker_agent_svg,
        "nanocoder.svg": PackageResources.nanocoder_svg,
        "mini-swe-agent.svg": PackageResources.mini_swe_agent_svg,
        "open-interpreter.svg": PackageResources.open_interpreter_svg,
        "crush.svg": PackageResources.crush_svg,
        "mimo-code.svg": PackageResources.mimo_code_svg,
        "codewhale.svg": PackageResources.codewhale_svg,
        "maki.svg": PackageResources.maki_svg,
        "omp.svg": PackageResources.omp_svg,
        "tau.svg": PackageResources.tau_svg,
        "stitch.svg": PackageResources.stitch_svg,
    ]

    public static let all: [IconEntry] = {
        do {
            let icons = try decodeManifest(Data(PackageResources.icons_json))
            try validate(icons, files: files)
            return icons
        } catch {
            fatalError("617: the built-in icons.json does not decode or validate: \(error)")
        }
    }()

    public static func entry(_ id: String) -> IconEntry? { all.first { $0.id == id } }

    public static func validate(_ icons: [IconEntry], files: [String: [UInt8]]) throws {
        var seen = Set<String>()
        func bad(_ id: String, _ s: String) -> Error { SandboxError.invalidSpec("icon \(id): \(s)") }
        for i in icons {
            guard i.id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil, seen.insert(i.id).inserted else { throw bad(i.id, "an id, unique") }
            guard ["vendor", "product"].contains(i.kind), !i.name.isEmpty else { throw bad(i.id, "kind vendor or product, a name") }
            guard ["official", "lettermark"].contains(i.allowed) else { throw bad(i.id, "allowed: official or lettermark") }
            guard AgentRecipe.isISODate(i.checked) else { throw bad(i.id, "checked is an ISO date") }
            if i.kind == "vendor", i.vendor != nil { throw bad(i.id, "a vendor has no vendor") }
            if let v = i.vendor, !icons.contains(where: { $0.id == v && $0.kind == "vendor" }) { throw bad(i.id, "vendor \(v) is not a vendor here") }
            if i.allowed == "official", (i.terms ?? "").isEmpty || !i.source.hasPrefix("https://") {
                throw bad(i.id, "an official mark records its source and the brand terms checked")
            }
            if i.allowed == "lettermark", i.lettermark == nil { throw bad(i.id, "a lettermark records its letters and frame") }
            for f in [i.variants.mono, i.variants.color, i.variants.colorDark].compactMap({ $0 }) {
                guard f.range(of: "^[a-z0-9-]+\\.svg$", options: .regularExpression) != nil else { throw bad(i.id, "a file is NAME.svg") }
                guard files[f] != nil else { throw bad(i.id, "\(f) is not compiled in") }
            }
            _ = try MonoSVG.check(String(decoding: files[i.variants.mono]!, as: UTF8.self))
        }
        let used = Set(icons.flatMap { [$0.variants.mono, $0.variants.color, $0.variants.colorDark].compactMap { $0 } })
        if let stray = Set(files.keys).subtracting(used).sorted().first { throw SandboxError.invalidSpec("icons: \(stray) is in no entry") }
    }

    /// A drawable mark from a registry entry's mono file.
    public static func resolved(_ e: IconEntry, kind: String? = nil) -> ResolvedIcon? {
        guard let bytes = files[e.variants.mono], let m = try? MonoSVG.check(String(decoding: bytes, as: UTF8.self)) else { return nil }
        return ResolvedIcon(id: e.id, kind: kind ?? e.kind, allowed: e.allowed, viewBox: m.viewBox, d: m.d, stroke: m.stroke, mono: "icons/" + e.variants.mono)
    }

    /// A recipe's mark: its product, else its product's (or publisher's) vendor, else a lettermark of its title.
    public static func resolve(_ r: AgentRecipe) -> ResolvedIcon {
        resolve(icon: r.icon, publisher: r.publisher, title: r.title)
    }

    public static func resolve(icon: String?, publisher: String?, title: String) -> ResolvedIcon {
        if let id = icon, let e = entry(id), let m = resolved(e) { return m }
        let vendorId = icon.flatMap { entry($0)?.vendor }
            ?? all.first { $0.kind == "vendor" && $0.name.lowercased() == (publisher ?? "").lowercased() }?.id
        if let v = vendorId, let e = entry(v), let m = resolved(e) { return m }
        return generated(title)
    }

    /// The fallback: the title's first letter (A–Z) in a square — drawn, never blank.
    public static func generated(_ title: String) -> ResolvedIcon {
        let letter = title.uppercased().first { $0.isASCII && $0.isLetter }.map(String.init) ?? ""
        let spec = Lettermark.Spec(text: letter, frame: "square")
        return ResolvedIcon(id: "letter-" + (letter.isEmpty ? "none" : letter.lowercased()), kind: "generated", allowed: "lettermark",
                            viewBox: "0 0 48 48", d: Lettermark.path(spec), stroke: Lettermark.strokeWidth, mono: nil)
    }

    /// A key provider's mark (the index's provider entries): the vendor with that id, when there is one.
    public static func vendor(_ id: String) -> ResolvedIcon? {
        entry(id).flatMap { $0.kind == "vendor" ? resolved($0) : nil }
    }
}

/// The one shape a mono file may have — checked byte for byte, so nothing else (a colour, a script, a reference, a
/// second element) can ride along: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="…"><path d="…" ATTRS/></svg>`,
/// ATTRS either `fill="none" stroke="currentColor" stroke-width="N" stroke-linecap="round" stroke-linejoin="round"`
/// or `fill="currentColor"`.
public enum MonoSVG {
    public struct Mark: Equatable { public var viewBox: String; public var d: String; public var stroke: Double? }

    static let shape = #"^<svg xmlns="http://www\.w3\.org/2000/svg" viewBox="(\d+(?:\.\d+)? \d+(?:\.\d+)? \d+(?:\.\d+)? \d+(?:\.\d+)?)"><path d="([MmLlHhVvCcSsQqTtAaZz0-9 .,-]+)" (fill="none" stroke="currentColor" stroke-width="(\d+(?:\.\d+)?)" stroke-linecap="round" stroke-linejoin="round"|fill="currentColor")/></svg>\n?$"#

    public static func check(_ text: String) throws -> Mark {
        let re = try NSRegularExpression(pattern: shape)
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            throw SandboxError.invalidSpec("a mono icon is ONE path in currentColor under a viewBox (no colour, script, reference, text or other element)")
        }
        let g = { (i: Int) -> String? in m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        return Mark(viewBox: g(1)!, d: g(2)!, stroke: g(4).flatMap(Double.init))
    }
}

/// Dozer's neutral lettermarks: letters drawn as strokes (a small built-in stroke alphabet — no font, no text element)
/// inside a frame. Deterministic: the same spec is the same bytes.
public enum Lettermark {
    public struct Spec: Codable, Sendable, Equatable {
        /// One or two letters: A–Z, or `x`, `m`, `π`.
        public var text: String
        /// `square` | `circle` | `hex` | `diamond` | `octagon`.
        public var frame: String
        public init(text: String, frame: String) { self.text = text; self.frame = frame }
    }

    public static let strokeWidth = 2.5
    public static let frames = ["square", "circle", "hex", "diamond", "octagon"]

    /// The file's exact text.
    public static func svg(_ s: Spec) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 48 48\"><path d=\"\(path(s))\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"\(n(strokeWidth))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>\n"
    }

    public static func path(_ s: Spec) -> String {
        var parts = [frame(s.frame)]
        let letters = Array(s.text).map(String.init).filter { glyphs[$0] != nil }
        // The letters' box: one letter larger; two side by side; smaller inside the pointed frames.
        let small = s.frame == "diamond" || s.frame == "hex"
        let h: Double = letters.count > 1 ? (small ? 12 : 14) : (small ? 13 : 17)
        let w: Double = letters.count > 1 ? (small ? 7.5 : 9) : (small ? 11 : 14)
        let gap: Double = 3
        let total = Double(letters.count) * w + Double(max(0, letters.count - 1)) * gap
        var x = 24 - total / 2
        let y = 24 - h / 2
        for l in letters {
            parts.append(glyph(l, x: x, y: y, w: w, h: h))
            x += w + gap
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func frame(_ f: String) -> String {
        switch f {
        case "circle": return "M24 4.5A19.5 19.5 0 1 1 24 43.5A19.5 19.5 0 1 1 24 4.5Z"
        case "hex": return "M24 4L41.3 14V34L24 44L6.7 34V14Z"
        case "diamond": return "M24 3.5L44.5 24L24 44.5L3.5 24Z"
        case "octagon": return "M16 4.5H32L43.5 16V32L32 43.5H16L4.5 32V16Z"
        default: return "M14 4.5H34A9.5 9.5 0 0 1 43.5 14V34A9.5 9.5 0 0 1 34 43.5H14A9.5 9.5 0 0 1 4.5 34V14A9.5 9.5 0 0 1 14 4.5Z"
        }
    }

    /// The stroke alphabet, in a unit box (x right, y down). `A` is a half-ellipse arc of the box from one point to
    /// another (large arc, counter-clockwise) — the box's own ellipse.
    enum Op { case m(Double, Double), l(Double, Double), q(Double, Double, Double, Double), a(Double, Double), z }

    static let c45 = 0.5 + 0.5 * cos(Double.pi / 4), s45 = 0.5 - 0.5 * sin(Double.pi / 4)
    static let glyphs: [String: [Op]] = [
        "A": [.m(0, 1), .l(0.5, 0), .l(1, 1), .m(0.2, 0.62), .l(0.8, 0.62)],
        "B": [.m(0, 0.5), .l(0.55, 0.5), .q(0.9, 0.5, 0.9, 0.25), .q(0.9, 0, 0.55, 0), .l(0, 0), .l(0, 1), .l(0.6, 1), .q(1, 1, 1, 0.75), .q(1, 0.5, 0.6, 0.5)],
        "C": [.m(c45, s45), .a(c45, 1 - s45)],
        "D": [.m(0, 0), .l(0, 1), .l(0.45, 1), .q(1, 1, 1, 0.5), .q(1, 0, 0.45, 0), .z],
        "E": [.m(1, 0), .l(0, 0), .l(0, 1), .l(1, 1), .m(0, 0.5), .l(0.75, 0.5)],
        "F": [.m(1, 0), .l(0, 0), .l(0, 1), .m(0, 0.5), .l(0.75, 0.5)],
        "G": [.m(c45, s45), .a(0.933, 0.75), .l(0.933, 0.55), .l(0.55, 0.55)],
        "H": [.m(0, 0), .l(0, 1), .m(1, 0), .l(1, 1), .m(0, 0.5), .l(1, 0.5)],
        "I": [.m(0.5, 0), .l(0.5, 1), .m(0.2, 0), .l(0.8, 0), .m(0.2, 1), .l(0.8, 1)],
        "J": [.m(0.8, 0), .l(0.8, 0.7), .q(0.8, 1, 0.45, 1), .q(0.1, 1, 0.1, 0.7)],
        "K": [.m(0, 0), .l(0, 1), .m(1, 0), .l(0, 0.6), .m(0.3, 0.42), .l(1, 1)],
        "L": [.m(0, 0), .l(0, 1), .l(1, 1)],
        "M": [.m(0, 1), .l(0, 0), .l(0.5, 0.6), .l(1, 0), .l(1, 1)],
        "N": [.m(0, 1), .l(0, 0), .l(1, 1), .l(1, 0)],
        "O": [.m(0.5, 0), .a(0.5, 1), .a(0.5, 0)],
        "P": [.m(0, 1), .l(0, 0), .l(0.6, 0), .q(1, 0, 1, 0.27), .q(1, 0.55, 0.6, 0.55), .l(0, 0.55)],
        "Q": [.m(0.5, 0), .a(0.5, 1), .a(0.5, 0), .m(0.6, 0.7), .l(0.95, 1)],
        "R": [.m(0, 1), .l(0, 0), .l(0.6, 0), .q(1, 0, 1, 0.27), .q(1, 0.55, 0.6, 0.55), .l(0, 0.55), .m(0.5, 0.55), .l(1, 1)],
        "S": [.m(0.95, 0.15), .q(0.8, 0, 0.5, 0), .q(0.05, 0, 0.05, 0.27), .q(0.05, 0.5, 0.5, 0.5), .q(0.95, 0.5, 0.95, 0.75), .q(0.95, 1, 0.5, 1), .q(0.2, 1, 0.05, 0.85)],
        "T": [.m(0, 0), .l(1, 0), .m(0.5, 0), .l(0.5, 1)],
        "U": [.m(0, 0), .l(0, 0.65), .q(0, 1, 0.5, 1), .q(1, 1, 1, 0.65), .l(1, 0)],
        "V": [.m(0, 0), .l(0.5, 1), .l(1, 0)],
        "W": [.m(0, 0), .l(0.25, 1), .l(0.5, 0.4), .l(0.75, 1), .l(1, 0)],
        "X": [.m(0, 0), .l(1, 1), .m(1, 0), .l(0, 1)],
        "Y": [.m(0, 0), .l(0.5, 0.5), .l(1, 0), .m(0.5, 0.5), .l(0.5, 1)],
        "Z": [.m(0, 0), .l(1, 0), .l(0, 1), .l(1, 1)],
        "x": [.m(0, 0.4), .l(1, 1), .m(1, 0.4), .l(0, 1)],
        "m": [.m(0, 1), .l(0, 0.4), .m(0, 0.62), .q(0, 0.4, 0.25, 0.4), .q(0.5, 0.4, 0.5, 0.62), .l(0.5, 1),
              .m(0.5, 0.62), .q(0.5, 0.4, 0.75, 0.4), .q(1, 0.4, 1, 0.62), .l(1, 1)],
        "π": [.m(0, 0.3), .l(1, 0.3), .m(0.3, 0.3), .l(0.3, 1), .m(0.72, 0.3), .l(0.72, 0.85), .q(0.72, 1, 0.9, 1)],
    ]

    static func glyph(_ l: String, x: Double, y: Double, w: Double, h: Double) -> String {
        guard let ops = glyphs[l] else { return "" }
        let px = { (u: Double) in n(x + u * w) }, py = { (v: Double) in n(y + v * h) }
        return ops.map { op -> String in
            switch op {
            case let .m(u, v): return "M\(px(u)) \(py(v))"
            case let .l(u, v): return "L\(px(u)) \(py(v))"
            case let .q(cu, cv, u, v): return "Q\(px(cu)) \(py(cv)) \(px(u)) \(py(v))"
            case let .a(u, v): return "A\(n(w / 2)) \(n(h / 2)) 0 1 0 \(px(u)) \(py(v))"
            case .z: return "Z"
            }
        }.joined()
    }

    /// At most two decimals, no trailing zeros.
    static func n(_ v: Double) -> String {
        var s = String(format: "%.2f", (v * 100).rounded() / 100)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s == "-0" ? "0" : s
    }
}

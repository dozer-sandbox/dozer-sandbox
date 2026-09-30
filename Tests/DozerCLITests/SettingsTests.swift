import Darwin
import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// 591 settings: the strict TOML subset, the closed schema, the generated file, precedence
/// (flag > env > file > default, each with its source), validation, the atomic 0600 write, and the
/// places that read a setting. Every file lives under a scratch XDG_CONFIG_HOME — never ~/.config.
final class SettingsTests: XCTestCase {
    private var xdg: URL!
    private var env: [String: String] { ["XDG_CONFIG_HOME": xdg.path] }
    private var file: URL { xdg.appendingPathComponent("dozer-sandbox/doz.toml") }

    override func setUpWithError() throws {
        xdg = FileManager.default.temporaryDirectory.appendingPathComponent("doz-settings-\(UUID().uuidString.prefix(8))")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: xdg)
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: TOML

    func testParsesTheSubset() throws {
        let e = try TOML.parse("""
        # a comment
        top = 1
          [ui]   # trailing comment
        a = true
        b = false
        n = -1_000
        z = 0
        s = "tab\\there \\"q\\" \\u00e9 \\U0001F600 \\\\"
        l = 'C:\\raw'   # literal
        [images.claude-code]
        memory_mib = +4096\r
        """)
        XCTAssertEqual(e.map(\.path), ["top", "ui.a", "ui.b", "ui.n", "ui.z", "ui.s", "ui.l", "images.claude-code.memory_mib"])
        XCTAssertEqual(e[1].value, .bool(true))
        XCTAssertEqual(e[3].value, .int(-1000))
        XCTAssertEqual(e[4].value, .int(0))
        XCTAssertEqual(e[5].value, .string("tab\there \"q\" é 😀 \\"))
        XCTAssertEqual(e[6].value, .string("C:\\raw"))
        XCTAssertEqual(e[7].value, .int(4096))
        XCTAssertEqual(e[7].line, 11)
    }

    func testRefusesWhatItDoesNotSupportWithTheLine() {
        let bad: [(String, String)] = [
            ("a = 1.5", "whole numbers"), ("a = 1e3", "whole numbers"), ("a = [1, 2]", "arrays"), ("a = { b = 1 }", "inline tables"),
            ("a = 1979-05-27", "unsupported"), ("a = \"\"\"x\"\"\"", "multi-line"), ("a.b = 1", "dotted keys"), ("\"a\" = 1", "quoted keys"),
            ("[[t]]", "arrays of tables"), ("a = \"open", "not closed"), ("a = 1 2", "after the value"), ("a = 01", "unsupported"),
            ("a = 1__0", "unsupported"), ("a = \"\\x\"", "unknown escape"), ("a =", "missing"), ("= 1", "expected a key"),
            ("a = 1\na = 2", "set twice"), ("[s]\n[s]", "appears twice"), ("[s", "section header"), ("a = TRUE", "unsupported"),
            ("a = 99999999999999999999", "unsupported"),
        ]
        for (text, words) in bad {
            XCTAssertThrowsError(try TOML.parse(text), text) { e in
                let t = (e as? TOMLError)?.description ?? ""
                XCTAssertTrue(t.contains(words), "\(text) → \(t)")
                XCTAssertTrue(t.hasPrefix("line "), t)
            }
        }
        XCTAssertThrowsError(try TOML.parse(String(repeating: "#", count: TOML.maximumBytes + 1)))
    }

    func testRenderRoundTrips() throws {
        let values: [TOMLValue] = [.bool(true), .bool(false), .int(0), .int(-42), .int(Int.max), .string(""), .string("plain"),
                                   .string("quote \" back \\ nl \n tab \t cr \r bell \u{07} del \u{7F} é 😀")]
        for v in values {
            let e = try TOML.parse("k = \(TOML.render(v))")
            XCTAssertEqual(e.first?.value, v, TOML.render(v))
        }
    }

    // MARK: the schema and the file

    func testSchemaIsClosedAndCoversWhatTheOwnerAskedFor() {
        let keys = DozerSettings.schema.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "no duplicate key")
        for k in ["ui.boot_view_on_start", "ui.confirm_shutdown", "ui.split_default", "ui.terminals", "ui.terminal_font_size", "ui.theme",
                  "host.idle_timeout_minutes", "host.keepalive", "store.path", "claude.permissions", "defaults.cpus", "defaults.nat_subnet",
                  "images.lab.memory_mib", "images.lab.network", "images.claude-code.memory_mib", "images.claude-code.network",
                  "images.pi.memory_mib", "images.pi.network", "kernel.path", "kernel.cache"] {
            XCTAssertNotNil(DozerSettings.definition(k), k)
        }
        XCTAssertEqual(DozerSettings.definition("ui.boot_view_on_start")?.defaultValue, .bool(true), "the owner's default: on")
        for d in DozerSettings.schema {
            XCTAssertNoThrow(try d.validate(d.defaultValue), "\(d.key)'s default is valid")
            XCTAssertTrue(TOML.isBareKey(d.name), d.key)
            if case .path = d.type { XCTAssertFalse(d.editableInUI, "\(d.key): the UI never names a host path") }
        }
    }

    func testTheTemplateListsEverySettingCommentedOutAndParses() throws {
        let text = DozerSettings.render(values: [:])
        for d in DozerSettings.schema {
            XCTAssertTrue(text.contains("\n# \(d.name) = \(TOML.render(d.defaultValue))\n"), "\(d.key) is listed at its default")
        }
        XCTAssertTrue(text.contains("[images.claude-code]"))
        XCTAssertTrue(text.contains("Not settable"))
        let s = DozerSettings(text: text)
        XCTAssertNil(s.fileError)
        XCTAssertTrue(s.fileValues.isEmpty, "every line is commented: nothing is set")
        XCTAssertTrue(s.warnings.isEmpty, s.warnings.joined(separator: "\n"))
    }

    func testOnlySetValuesAreUncommentedAndTheyRoundTrip() throws {
        let values: [String: TOMLValue] = ["ui.boot_view_on_start": .bool(false), "defaults.cpus": .int(4),
                                           "images.pi.network": .string("locked"), "store.path": .string("~/stores/a \"b\"")]
        let text = DozerSettings.render(values: values)
        XCTAssertTrue(text.contains("\nboot_view_on_start = false\n"))
        XCTAssertFalse(text.contains("# boot_view_on_start ="))
        XCTAssertTrue(text.contains("\n# confirm_shutdown = true\n"))
        XCTAssertEqual(DozerSettings(text: text).fileValues, values)
    }

    func testUnknownKeysAndBadValuesAreWarningsNeverACrash() throws {
        let s = DozerSettings(text: """
        [ui]
        boot_view_on_start = "yes"
        terminal_font_size = 200
        theme = "dark"
        colour = "blue"
        [future]
        thing = 1
        """)
        XCTAssertNil(s.fileError)
        XCTAssertEqual(s.fileValues, ["ui.theme": .string("dark")])
        XCTAssertEqual(s.unknown.map(\.path), ["ui.colour", "future.thing"])
        XCTAssertEqual(s.warnings.count, 4, s.warnings.joined(separator: "\n"))
        XCTAssertTrue(s.warnings.contains { $0.hasPrefix("line 2:") && $0.contains("boolean") })
        XCTAssertTrue(s.warnings.contains { $0.hasPrefix("line 3:") && $0.contains("9–32") })
        XCTAssertTrue(s.warnings.contains { $0.contains("unknown setting ui.colour") })
        XCTAssertEqual(s.resolve("ui.boot_view_on_start").source, .default)
        XCTAssertEqual(s.resolve("ui.boot_view_on_start").value, .bool(true))
        // A rewrite keeps the unknown keys, as they were.
        let again = DozerSettings(text: DozerSettings.render(values: s.fileValues, unknown: s.unknown))
        XCTAssertEqual(again.unknown.map(\.path), ["ui.colour", "future.thing"])
        XCTAssertEqual(again.fileValues, s.fileValues)
    }

    func testAFileThatDoesNotParseIsIgnoredWholeAndNeverOverwritten() throws {
        try write("[ui]\nboot_view_on_start = false\ntheme = [\"x\"]\n")
        let s = DozerSettings.load(environment: env)
        XCTAssertNotNil(s.fileError)
        XCTAssertTrue(s.fileValues.isEmpty, "none of it applies")
        XCTAssertEqual(s.resolve("ui.boot_view_on_start").source, .default)
        XCTAssertTrue(s.warnings.first?.contains("line 3") == true, s.warnings.first ?? "")
        XCTAssertThrowsError(try s.writing("ui.theme", .string("dark")))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[ui]\nboot_view_on_start = false\ntheme = [\"x\"]\n")
    }

    // MARK: precedence

    func testPrecedenceFlagEnvFileDefaultEachWithItsSource() throws {
        try write("[host]\nidle_timeout_minutes = 30\n[store]\npath = \"/from/file\"\n")
        var e = env
        var s = DozerSettings.load(environment: e)
        XCTAssertEqual(s.resolve("host.idle_timeout_minutes").value, .int(30))
        XCTAssertEqual(s.resolve("host.idle_timeout_minutes").source, .file)
        XCTAssertEqual(s.resolve("ui.theme").source, .default)
        XCTAssertEqual(s.idleTimeoutMinutes(flag: nil), 30)
        e["DOZ_HOST_IDLE"] = "7"
        s = DozerSettings.load(environment: e)
        XCTAssertEqual(s.resolve("host.idle_timeout_minutes").value, .int(7))
        XCTAssertEqual(s.resolve("host.idle_timeout_minutes").source, .env)
        XCTAssertEqual(s.resolve("host.idle_timeout_minutes").fileValue, .int(30), "the file's value is still known")
        XCTAssertEqual(s.idleTimeoutMinutes(flag: nil), 7)
        XCTAssertEqual(s.idleTimeoutMinutes(flag: 0.05), 0.05, "the flag wins")
        e["DOZ_HOST_IDLE"] = "0.5"
        s = DozerSettings.load(environment: e)
        XCTAssertEqual(s.idleTimeoutMinutes(flag: nil), 0.5, "a fractional environment value works as it always did")
        XCTAssertEqual(s.resolve("host.idle_timeout_minutes").source, .env)
        e["DOZ_HOST_IDLE"] = "soon"
        s = DozerSettings.load(environment: e)
        XCTAssertEqual(s.resolve("host.idle_timeout_minutes").source, .file, "an environment value that does not parse is skipped")
        let flagged = s.resolve("store.path", flag: .string("/from/flag"))
        XCTAssertEqual(flagged.source, .flag)
        XCTAssertEqual(flagged.value, .string("/from/flag"))
        let row = s.report(flags: ["store.path": .string("/from/flag")]).settings.first { $0.key == "store.path" }!
        XCTAssertEqual(row.source, .flag)
        XCTAssertFalse(row.editable)
    }

    func testTheStoreFollowsFlagEnvFileDefault() throws {
        try write("[store]\npath = \"~/from-file\"\n")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(DozerStore.resolve("/flag", environment: env.merging(["DOZ_STORE": "/env"]) { a, _ in a }).root.path, "/flag")
        XCTAssertEqual(DozerStore.resolve(nil, environment: env.merging(["DOZ_STORE": "/env"]) { a, _ in a }).root.path, "/env")
        XCTAssertEqual(DozerStore.resolve(nil, environment: env).root.path, home + "/from-file")
        XCTAssertEqual(DozerStore.resolve(nil, environment: [:]).root.path, home + "/Library/Application Support/dozer-sandbox")
    }

    func testNewSandboxDefaultsComeFromTheSettings() throws {
        try write("""
        [defaults]
        cpus = 6
        nat_subnet = "192.168.77.0/24"
        [images.lab]
        memory_mib = 3072
        network = "nat"
        [images.pi]
        network = "locked"
        [kernel]
        cache = "/kernels"
        """)
        let store = DozerStore(root: xdg.appendingPathComponent("store"))
        let (lab, _) = try DozerImages.spec(name: "a", options: CreateOptions(image: "lab"), store: store, environment: env)
        XCTAssertEqual(lab.cpus, 6)
        XCTAssertEqual(lab.memoryMiB, 3072)
        XCTAssertEqual(lab.network, .nat)
        XCTAssertEqual(lab.subnet, "192.168.77.0/24")
        XCTAssertEqual(lab.kernelCacheDirectory?.path, "/kernels")
        let (pi, _) = try DozerImages.spec(name: "b", options: CreateOptions(image: "pi"), store: store, environment: env)
        XCTAssertEqual(pi.network, .proxied(.permissions(["model"], preset: "locked")), "597: Locked = the model only, by name")
        XCTAssertEqual(pi.memoryMiB, 2048, "unset: the default")
        let (flags, _) = try DozerImages.spec(name: "c", options: CreateOptions(image: "lab", cpus: 1, memoryMiB: 512, network: "bake"),
                                               store: store, environment: env.merging(["DOZ_SUBNET": "10.9.0.0/24", "DOZ_KERNEL_CACHE": "/env-k"]) { a, _ in a })
        XCTAssertEqual(flags.cpus, 1, "the flag wins")
        XCTAssertEqual(flags.memoryMiB, 512)
        XCTAssertEqual(flags.network, .proxied(.bake))
        XCTAssertEqual(flags.kernelCacheDirectory?.path, "/env-k", "the environment wins over the file")
        XCTAssertEqual(DozerSettings.imageSection(imageSpecName: nil), "lab")
        XCTAssertEqual(DozerSettings.imageSection(imageSpecName: "pi"), "pi")
    }

    func testClaudePermissionsReachOnlyAClaudeCodeSessionAndNeverOverTheCallers() throws {
        let ask = DozerSettings(text: "[claude]\npermissions = \"ask\"\n")
        let skip = DozerSettings(text: nil)
        XCTAssertEqual(HostCore.withClaudePermissions(["A": "1"], imageSpec: "claude-code", settings: ask), ["A": "1", "DOZ_CLAUDE_PERMISSIONS": "ask"])
        XCTAssertEqual(HostCore.withClaudePermissions([:], imageSpec: "pi", settings: ask), [:])
        XCTAssertEqual(HostCore.withClaudePermissions([:], imageSpec: nil, settings: ask), [:])
        XCTAssertEqual(HostCore.withClaudePermissions([:], imageSpec: "claude-code", settings: skip), [:], "the default adds nothing")
        XCTAssertEqual(HostCore.withClaudePermissions(["DOZ_CLAUDE_PERMISSIONS": "skip"], imageSpec: "claude-code", settings: ask),
                       ["DOZ_CLAUDE_PERMISSIONS": "skip"], "the caller's -e wins")
    }

    func testKeepaliveIsTheChoiceOfAStoreThatHasNotMadeOne() throws {
        let store = DozerStore(root: xdg.appendingPathComponent("store"))
        let on = AccountStore(store: store, settings: DozerSettings(text: "[host]\nkeepalive = true\n"))
        XCTAssertTrue(on.load().keepalive, "a new store: the setting")
        var f = on.load()
        f.keepalive = false
        try on.save(f)
        XCTAssertFalse(on.load().keepalive, "the store's own choice wins")
        XCTAssertFalse(AccountStore(store: DozerStore(root: xdg.appendingPathComponent("other"))).load().keepalive)
    }

    // MARK: validation

    func testValuesAreCheckedAgainstTheirTypeAndRange() throws {
        func parse(_ k: String, _ t: String) throws -> TOMLValue { try XCTUnwrap(DozerSettings.definition(k)).parse(t) }
        XCTAssertEqual(try parse("ui.boot_view_on_start", "off"), .bool(false))
        XCTAssertEqual(try parse("ui.terminal_font_size", "16"), .int(16))
        XCTAssertEqual(try parse("ui.split_default", "watch"), .string("watch"))
        XCTAssertEqual(try parse("defaults.nat_subnet", ""), .string(""))
        XCTAssertEqual(try parse("kernel.path", "~/k/vmlinux"), .string("~/k/vmlinux"))
        for (k, t) in [("ui.boot_view_on_start", "maybe"), ("ui.terminal_font_size", "8"), ("ui.terminal_font_size", "33"),
                       ("ui.terminal_font_size", "1.5"), ("ui.split_default", "tab"), ("ui.theme", "Dark"), ("host.idle_timeout_minutes", "-1"),
                       ("defaults.cpus", "0"), ("defaults.cpus", "65"), ("images.lab.memory_mib", "100"), ("images.pi.network", "wide-open"),
                       ("defaults.nat_subnet", "10.0.0.0"), ("defaults.nat_subnet", "300.0.0.0/24"), ("defaults.nat_subnet", "10.0.0.0/4"),
                       ("kernel.path", "relative/k"), ("store.path", "/a\nb"), ("claude.permissions", "yolo")] {
            XCTAssertThrowsError(try parse(k, t), "\(k) = \(t)")
        }
        XCTAssertThrowsError(try DozerSettings.definition("ui.theme")!.validate(.int(1)))
        XCTAssertThrowsError(try DozerSettings(text: nil, url: file).writing("ui.nope", .bool(true)))
    }

    // MARK: writing

    func testWritingIsAtomicPrivateAndRegeneratesTheWholeFile() throws {
        var s = DozerSettings.load(environment: env)
        XCTAssertEqual(s.url, file)
        XCTAssertFalse(s.fileExists)
        s = try s.writing("ui.boot_view_on_start", .bool(false))
        XCTAssertTrue(s.fileExists)
        XCTAssertEqual(s.resolve("ui.boot_view_on_start").source, .file)
        XCTAssertFalse(s.bool(SettingKey.bootViewOnStart))
        var st = stat()
        XCTAssertEqual(stat(file.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(file.deletingLastPathComponent().path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\nboot_view_on_start = false\n"))
        for d in DozerSettings.schema where d.key != "ui.boot_view_on_start" {
            XCTAssertTrue(text.contains("\n# \(d.name) = "), "\(d.key) still listed")
        }
        s = try s.writing("defaults.cpus", .int(8))
        s = try s.writing("ui.boot_view_on_start", nil)
        XCTAssertEqual(s.fileValues, ["defaults.cpus": .int(8)])
        XCTAssertEqual(s.resolve("ui.boot_view_on_start").source, .default)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["doz.toml"], "no temp file left behind")
    }

    func testTheFileIsFoundTheXDGWay() {
        XCTAssertEqual(DozerSettings.fileURL(environment: ["XDG_CONFIG_HOME": "/x", "HOME": "/h"])?.path, "/x/dozer-sandbox/doz.toml")
        XCTAssertEqual(DozerSettings.fileURL(environment: ["XDG_CONFIG_HOME": "relative", "HOME": "/h"])?.path, "/h/.config/dozer-sandbox/doz.toml",
                       "a relative XDG_CONFIG_HOME is ignored (the XDG rule)")
        XCTAssertEqual(DozerSettings.fileURL(environment: ["HOME": "/h"])?.path, "/h/.config/dozer-sandbox/doz.toml")
        XCTAssertNil(DozerSettings.fileURL(environment: [:]))
        XCTAssertEqual(DozerSettings.load(environment: [:]).resolve("ui.theme").source, .default)
    }
}

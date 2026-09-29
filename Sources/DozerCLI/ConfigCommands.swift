import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 591 settings — `doz config`: the settings file (`${XDG_CONFIG_HOME:-~/.config}/dozer-sandbox/doz.toml`),
// its effective values and where each came from. One closed schema (`DozerSettings.schema`); the
// file is regenerated from it on every write, atomically, 0600.

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config",
        abstract: "Settings: the doz.toml file, every value and where it came from (flag, env, file or default).",
        discussion: """
        Precedence: a command-line flag, then its environment variable (DOZ_STORE, DOZ_HOST_IDLE, \
        DOZ_SUBNET, DOZ_KERNEL, DOZ_KERNEL_CACHE), then the file, then the default. The file lists \
        every setting with its default commented out; set writes one value, unset puts the default back. \
        The UI's Settings page edits the same file.
        """,
        subcommands: [ConfigShow.self, ConfigGet.self, ConfigSet.self, ConfigUnset.self, ConfigInit.self, ConfigPath.self],
        defaultSubcommand: ConfigShow.self)
}

/// `--store` is the one setting a flag of every command sets.
func configFlags(_ g: GlobalOptions) -> [String: TOMLValue] {
    g.store.map { [SettingKey.storePath: .string($0)] } ?? [:]
}

func settingsWarnings(_ s: DozerSettings, _ g: GlobalOptions) {
    guard !g.json, !g.quiet else { return }
    for w in s.warnings { Out.stderr("doz: \(s.url?.lastPathComponent ?? DozerSettings.fileName): \(w)\n") }
}

func settingDefinition(_ key: String, _ g: GlobalOptions) throws -> SettingDefinition {
    guard let d = DozerSettings.definition(key) else {
        throw fail(HostError(.invalid, "unknown setting \(key) — doz config show lists them (section.name, e.g. ui.boot_view_on_start)"), g)
    }
    return d
}

struct ConfigShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Every setting: its effective value and its source (the default).")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let s = DozerSettings.load()
        let report = s.report(flags: configFlags(g))
        if g.json { Out.json(report); return }
        settingsWarnings(s, g)
        var t = [["SETTING", "VALUE", "SOURCE", "DEFAULT"]]
        for r in report.settings {
            let source = r.source == .env ? "env \(r.environment ?? "")" : r.source.rawValue
            t.append([r.key, Self.shown(r.value), source, r.value == r.defaultValue ? "" : Self.shown(r.defaultValue)])
        }
        Out.stdout(Out.table(t))
        Out.stdout("\nfile: \(report.path ?? "none (neither XDG_CONFIG_HOME nor HOME is set)")\(report.exists ? "" : " (not created yet — doz config init)")\n")
    }

    static func shown(_ v: TOMLValue) -> String {
        if case .string(let s) = v { return s.isEmpty ? "\"\"" : s }
        return v.plain
    }
}

struct ConfigGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "One setting's effective value (--json adds its source and default).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "section.name, e.g. ui.boot_view_on_start") var key: String

    func run() async throws {
        _ = try settingDefinition(key, g)
        let s = DozerSettings.load()
        let row = s.report(flags: configFlags(g)).settings.first { $0.key == key }!
        if g.json { Out.json(row); return }
        settingsWarnings(s, g)
        Out.stdout(row.value.plain + "\n")
    }
}

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set one setting in the file (checked against its type and range).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "section.name, e.g. ui.boot_view_on_start") var key: String
    @Argument(help: "The value: true/false, a number, or one of the setting's choices.") var value: String

    func run() async throws {
        let d = try settingDefinition(key, g)
        let v: TOMLValue
        do { v = try d.parse(value) } catch let e as SettingsError { throw fail(HostError(.invalid, e.message), g) }
        let now: DozerSettings
        do { now = try DozerSettings.load().writing(key, v) } catch let e as SettingsError { throw fail(HostError(.failed, e.message), g) }
        let r = now.resolve(key, flag: configFlags(g)[key])
        if g.json { Out.json(now.report(flags: configFlags(g)).settings.first { $0.key == key }!); return }
        Out.stdout("\(key) = \(TOML.render(v)) in \(now.url?.path ?? "?") — \(d.applies.note)\n")
        if r.source == .env || r.source == .flag, !g.quiet {
            Out.stderr("note: \(r.source == .env ? "$\(d.environment ?? "")" : d.flag ?? "a flag") overrides it here: the effective value is \(r.value.plain)\n")
        }
    }
}

struct ConfigUnset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unset", abstract: "Put one setting back to its default (comment it out in the file).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "section.name") var key: String

    func run() async throws {
        let d = try settingDefinition(key, g)
        let now: DozerSettings
        do { now = try DozerSettings.load().writing(key, nil) } catch let e as SettingsError { throw fail(HostError(.failed, e.message), g) }
        if g.json { Out.json(now.report(flags: configFlags(g)).settings.first { $0.key == key }!); return }
        Out.stdout("\(key) is the default (\(d.defaultValue.plain)) in \(now.url?.path ?? "?")\n")
    }
}

struct ConfigInit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "init",
        abstract: "Write the settings file: every setting with its default commented out (an existing file keeps its values and gains any new settings).")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let s = DozerSettings.load()
        let now: DozerSettings
        do { now = try s.writingAll(s.fileValues) } catch let e as SettingsError { throw fail(HostError(.failed, e.message), g) }
        if g.json { Out.json(now.report(flags: configFlags(g))); return }
        settingsWarnings(now, g)
        Out.stdout("\(s.fileExists ? "rewrote" : "wrote") \(now.url?.path ?? "?") — \(DozerSettings.schema.count) settings, \(now.fileValues.count) set\n")
    }
}

struct ConfigPath: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "Where the settings file is (${XDG_CONFIG_HOME:-~/.config}/dozer-sandbox/doz.toml).")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        guard let url = DozerSettings.fileURL() else {
            throw fail(HostError(.unavailable, "no settings file: neither XDG_CONFIG_HOME nor HOME is set"), g)
        }
        if g.json { Out.json(["path": url.path, "exists": FileManager.default.fileExists(atPath: url.path) ? "true" : "false"]) }
        else { Out.stdout(url.path + "\n") }
    }
}

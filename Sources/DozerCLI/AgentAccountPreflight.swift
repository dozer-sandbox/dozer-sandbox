import ArgumentParser
import Darwin
import Foundation
import DozerKit
import DozerHost

// 594 (owner, 2026-09-30: "creating a Pi sandbox should have pre-requisites for things like API key so
// that this is not the first experience"): before `doz create`, `doz up` (a project's too) or `doz
// duplicate` makes anything, the agent's credential prerequisite (`AgentCredentials`). It fits: go on.
// It does not: on a terminal, offer an account that fits or the hidden paste of an API key (added as
// `doz account add` adds it); off one, fail with the exact next step. The host checks again.

/// `o.account`, checked (and chosen or added on a terminal) for a create of a built-in agent image. A
/// template's agent is checked by the host alone (the same message, without the offer).
func preflightAgentAccount(_ o: inout CreateOptions, _ g: GlobalOptions) throws {
    guard AgentImages.credentials(o.image) != nil else { return }
    let section = DozerSettings.imageSection(imageSpecName: o.image)
    let network = o.network ?? DozerSettings.load().string(SettingKey.network(section))
    o.account = try preflightAgentAccount(image: o.image, network: network, account: o.account, g)
}

/// The account to create with (the one given, or one chosen or added here).
func preflightAgentAccount(image: String?, network: String?, account: String?, _ g: GlobalOptions) throws -> String? {
    guard let image, AgentCredentials.kinds(image) != nil else { return account }
    if let n = network, n == "nat" || n == "none" { return account }        // not proxied: no account at all
    let m = try rawCall(HostRequest(.accountList), g)
    guard m.ok == true, let rows = try? m.result?.decode([AccountRow].self) else { return account }
    var kinds: [String: AccountKind] = ["mac": .mac]
    for r in rows { if let k = AccountKind(rawValue: r.kind) { kinds[r.name] = k } }
    let defaultAccount = rows.first { $0.isDefault }?.name ?? "none"
    guard let problem = AgentCredentials.createProblem(image: image, account: account, defaultAccount: defaultAccount, kinds: kinds) else {
        return account
    }
    let asker = Asker(yes: false, json: g.json)
    guard asker.interactive, isatty(STDIN_FILENO) == 1 else { throw fail(HostError(.invalid, problem), g) }
    Out.stderr("[doz] \(problem)\n")
    let fits = kinds.filter { AgentCredentials.accepts(image, $0.value) }.keys.sorted()
    if !fits.isEmpty {
        let i = asker.choose("Which account?", fits.map { "use \($0)" } + ["add an Anthropic API key now"], preferred: 0)
        if i < fits.count { return fits[i] }
    }
    let name = asker.text("Account name", default: kinds["anthropic"] == nil ? "anthropic" : "anthropic-2") {
        (try? AccountStore.validateName($0)) == nil ? "1–40 of a-z 0-9 - (not default or none)" : (kinds[$0] != nil ? "\($0) exists" : nil)
    }
    let secret = try readSecret("Anthropic API key for \(AgentImages.agentName(image) ?? image) (not echoed): ", g)
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw fail(HostError(.invalid, problem), g) }
    let added = try rawCall(HostRequest.accountAdd(name: name, kind: .apiKey, plan: nil, secret: secret), g)
    guard added.ok == true else {
        throw fail(HostError(.invalid, "could not add \(name): " + (added.error?.message ?? "no reason").replacingOccurrences(of: trimmed, with: "…")), g)
    }
    Out.stderr("[doz] account \(name) added (api-key) — this sandbox uses it\n")
    return name
}

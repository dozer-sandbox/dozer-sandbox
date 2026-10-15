import ArgumentParser
import Foundation
import DozerKit
import DozerHost

// 618 (owner: "… its also missing the step to choose a model") — `doz models [--gateway X | --provider X] [SEARCH]`: the
// models a gateway publishes (read by the host on this Mac at most once a day; `--refresh` reads it now) and, for a
// provider, the model Dozer checked. And the note when `--model` names an id a gateway does not list.

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "The models a provider or gateway offers (a gateway's own list; a provider's checked default).",
        discussion: """
        A gateway (OpenRouter, Vercel AI Gateway) publishes its list: Dozer reads it on this Mac at most once a day and \
        keeps the last one (offline: the last list). A provider (Anthropic, OpenAI, xAI, Google) lists its models only \
        with a key, so only the model Dozer checked is shown — any model id may still be given with --model. SEARCH \
        narrows the list by id, name or maker.
        """)

    @OptionGroup var g: GlobalOptions
    @Option(name: .long, help: "A gateway: openrouter, vercel-ai-gateway.") var gateway: String?
    @Option(name: .long, help: "A provider: anthropic, openai, xai, google.") var provider: String?
    @Flag(name: .long, help: "Read a gateway's list now (starts the host when none runs).") var refresh = false
    @Argument(help: "Words to look for in a model's id, name or maker.") var search: [String] = []

    func run() async throws {
        if provider != nil && gateway != nil { throw ValidationError("--provider or --gateway, not both") }
        if let x = gateway, !ModelSources.isGateway(x) {
            throw ValidationError("\(x) is not a gateway — " + ModelSources.ids.filter(ModelSources.isGateway).joined(separator: ", "))
        }
        if let x = provider {
            if ModelSources.isGateway(x) { throw ValidationError("\(x) is a gateway: --gateway \(x)") }
            guard ModelSources.ids.contains(x) else { throw ValidationError("--provider: " + ModelSources.ids.filter { !ModelSources.isGateway($0) }.joined(separator: ", ")) }
        }
        var r = HostRequest(.models)
        r.modelsSource = gateway ?? provider
        r.modelsRefresh = refresh ? true : nil
        let lists = try decode(refresh ? try call(r, g) : try await query(r, g), [ModelList].self, g)
        let words = search.flatMap { $0.lowercased().split(separator: " ").map(String.init) }
        let shown = lists.map { l -> ModelList in
            var l = l
            l.models = l.models.filter { m in words.allSatisfy { w in [m.id, m.name, m.maker ?? ""].contains { $0.lowercased().contains(w) } } }
            return l
        }
        if g.json { Out.json(shown); return }
        Out.stdout(renderModelLists(shown, searched: !words.isEmpty))
    }
}

/// A person's view: one block per source, a row per model (id, context, price in/out per million tokens, tools).
func renderModelLists(_ lists: [ModelList], searched: Bool, now: Date = Date()) -> String {
    var s = ""
    for l in lists {
        if !s.isEmpty { s += "\n" }
        switch l.kind {
        case "fetched":
            let age = l.fetchedAt.map { " — read " + ModelsAge.text(now.timeIntervalSince($0)) } ?? ""
            s += "\(l.title) (gateway): \(l.models.count) model\(l.models.count == 1 ? "" : "s")\(searched ? " match" : "")\(age)\n"
        case "none":
            s += "\(l.title) (gateway): its list has not been read yet — doz models --gateway \(l.source) --refresh\n"
        default:
            s += "\(l.title): the model Dozer checked — any other id with --model\n"
        }
        guard !l.models.isEmpty else { continue }
        var t = [["MODEL", "CONTEXT", "IN $/M", "OUT $/M", "TOOLS", "NAME"]]
        for m in l.models {
            t.append([m.id + (m.id == l.defaultModel ? " (default)" : ""), m.context.map(ModelsAge.tokens) ?? "—",
                      m.pricePerMillionIn.map(ModelsAge.price) ?? "—", m.pricePerMillionOut.map(ModelsAge.price) ?? "—",
                      m.tools.map { $0 ? "yes" : "no" } ?? "—", (m.maker.map { $0 + " · " } ?? "") + m.name])
        }
        s += Out.table(t)
    }
    return s
}

enum ModelsAge {
    static func text(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<120: return "just now"
        case ..<7200: return "\(Int(seconds / 60)) minutes ago"
        case ..<172_800: return "\(Int(seconds / 3600)) hours ago"
        default: return "\(Int(seconds / 86_400)) days ago"
        }
    }
    static func tokens(_ n: Int) -> String { n >= 1_000_000 && n % 1_000_000 == 0 ? "\(n / 1_000_000)M" : n >= 1000 ? "\(n / 1000)K" : "\(n)" }
    static func price(_ v: Double) -> String { v == 0 ? "free" : String(format: v < 1 ? "%.3g" : "%.2f", v) }
}

/// The `--model` note, at most once per command: a gateway's model id it does not list — the closest ids. Never a
/// refusal (a list can be a day old, and a gateway adds models every week). Looking never starts the host.
enum ModelNote {
    nonisolated(unsafe) static var said = false

    static func text(model: String, list: ModelList) -> String? {
        guard list.kind == "fetched", !list.models.contains(where: { $0.id == model }) else { return nil }
        let near = ModelLists.suggestions(for: model, in: list)
        let mean = near.isEmpty ? "" : " — did you mean \(near.joined(separator: ", "))?"
        return "note: \(model) is not in \(list.title)'s model list\(mean) (doz models --gateway \(list.source); used as given)"
    }

    static func check(_ o: CreateOptions, _ g: GlobalOptions) async {
        guard !said, !g.json, !g.quiet, let model = o.model, let source = o.modelSource, ModelLists.fetched(source) else { return }
        var r = HostRequest(.models)
        r.modelsSource = source
        guard let lists = try? decode(try await query(r, g), [ModelList].self, g), let l = lists.first,
              let t = text(model: model, list: l) else { return }
        said = true
        Out.stderr("[doz] \(t)\n")
    }
}

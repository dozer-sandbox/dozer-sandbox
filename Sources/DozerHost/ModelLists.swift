import Foundation
import DozerKit

/// 618 (owner, trying OpenRouter in a try: "… its also missing the step to choose a model"): the models a model source
/// offers, for the Try setup's picker, `doz models` and the `--model` note.
///
///   · A GATEWAY (OpenRouter, Vercel AI Gateway) publishes its list without a key. The HOST fetches it on the Mac — never
///     a sandbox — at most once a day (`maxAge`), with a short back-off after a failure (`retryAfterFailure`); offline it
///     says nothing and keeps the last list. `<store>/model-lists.json` (a cache: public data, never a key).
///   · A PROVIDER (Anthropic, OpenAI, xAI, Google) lists its models only with a key, so Dozer offers the model it
///     checked (`ModelSources.endpoints`' default) and any id a person types — a list built in would go stale.
///
/// Each entry keeps id, name, maker, context, the price per million tokens in and out, and whether it takes tools —
/// strictly decoded, every text capped and made inert (the list is someone else's).
public struct ModelInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var maker: String?
    /// Tokens.
    public var context: Int?
    /// US dollars per million tokens.
    public var pricePerMillionIn: Double?
    public var pricePerMillionOut: Double?
    public var tools: Bool?
    /// 618: a key-less source's model — its data terms as the source's docs state them (Dozer's own list, never fetched).
    public var note: String?

    public init(id: String, name: String, maker: String? = nil, context: Int? = nil, pricePerMillionIn: Double? = nil,
                pricePerMillionOut: Double? = nil, tools: Bool? = nil, note: String? = nil) {
        self.id = id; self.name = name; self.maker = maker; self.context = context
        self.pricePerMillionIn = pricePerMillionIn; self.pricePerMillionOut = pricePerMillionOut; self.tools = tools; self.note = note
    }
}

/// One source's list, as the host answers it (`models`).
public struct ModelList: Codable, Equatable, Sendable {
    public var source: String
    public var title: String
    public var gateway: Bool
    /// `fetched` (a gateway's own list), `none` (a gateway whose list was never read — offline, or no host yet),
    /// `default` (a provider: the model Dozer checked only), 618: `listed` (a key-less source: the models Dozer lists,
    /// checked against its docs on `checked`).
    public var kind: String
    /// 618: when a `listed` list was checked against the source's docs (YYYY-MM-DD), and where they are.
    public var checked: String? = nil
    public var docs: String? = nil
    public var fetchedAt: Date?
    /// The source's default model (the plan's, when nothing is chosen).
    public var defaultModel: String?
    public var models: [ModelInfo]

    public init(source: String, title: String, gateway: Bool, kind: String, fetchedAt: Date?, defaultModel: String?, models: [ModelInfo]) {
        self.source = source; self.title = title; self.gateway = gateway; self.kind = kind
        self.fetchedAt = fetchedAt; self.defaultModel = defaultModel; self.models = models
    }
}

/// What the store keeps per gateway.
public struct ModelListRecord: Codable, Equatable, Sendable {
    public var fetchedAt: Date?
    public var failedAt: Date?
    public var lastError: String?
    public var models: [ModelInfo]
    public init(fetchedAt: Date? = nil, failedAt: Date? = nil, lastError: String? = nil, models: [ModelInfo] = []) {
        self.fetchedAt = fetchedAt; self.failedAt = failedAt; self.lastError = lastError; self.models = models
    }
}

/// Where a list is read from. The real host: the gateways' public URLs; `DOZ_TEST_MODEL_LIST` = `offline` (every read
/// fails) or a FILE (its bytes for every gateway) or a FOLDER (`<folder>/<source>.json`) — tests and probes only. A
/// guarded test run without it reads nothing. In-process hosts and unit tests: `.disabled` (the cache only).
public struct ModelListFetcher: Sendable {
    public var read: (@Sendable (String) async throws -> Data)?

    public init(read: (@Sendable (String) async throws -> Data)?) { self.read = read }

    public static let disabled = ModelListFetcher(read: nil)

    /// The gateways' public model lists (no key: both answer without one).
    public static let urls: [String: URL] = [
        "openrouter": URL(string: "https://openrouter.ai/api/v1/models")!,
        "vercel-ai-gateway": URL(string: "https://ai-gateway.vercel.sh/v1/models")!,
    ]

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ModelListFetcher {
        switch env["DOZ_TEST_MODEL_LIST"] {
        case "offline":
            return ModelListFetcher { s in throw HostError(.unavailable, "offline (DOZ_TEST_MODEL_LIST): \(s)'s models not read") }
        case let p? where !p.isEmpty:
            return ModelListFetcher { s in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { throw HostError(.unavailable, "no model list at \(p)") }
                let file = isDir.boolValue ? URL(fileURLWithPath: p).appendingPathComponent("\(s).json") : URL(fileURLWithPath: p)
                guard let d = try? Data(contentsOf: file) else { throw HostError(.unavailable, "no model list for \(s) at \(p)") }
                return d
            }
        default:
            if TestSafety.guarded(env) { return .disabled }
            return http()
        }
    }

    /// Over HTTPS, at most `timeout` seconds and `maximumBytes`.
    public static func http(timeout: TimeInterval = 10) -> ModelListFetcher {
        ModelListFetcher { source in
            guard let url = urls[source] else { throw HostError(.invalid, "\(source) publishes no model list") }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw HostError(.failed, "\(ModelSources.title(source)) answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for its model list")
            }
            guard data.count <= ModelLists.maximumBytes else { throw HostError(.failed, "\(ModelSources.title(source))'s model list is larger than \(ModelLists.maximumBytes) bytes") }
            return data
        }
    }
}

public enum ModelLists {
    /// How long a list is trusted before it is read again.
    public static let maxAge: TimeInterval = 24 * 3600
    /// After a failed read, how long before trying again.
    public static let retryAfterFailure: TimeInterval = 600
    public static let maximumBytes = 16 << 20
    public static let maximumModels = 3000
    static let maximumName = 120
    static let maximumMaker = 60

    /// The sources whose list is fetched (a gateway with a published list).
    public static func fetched(_ source: String) -> Bool { ModelListFetcher.urls[source] != nil }

    public static func fileURL(_ store: DozerStore) -> URL { store.root.appendingPathComponent("model-lists.json") }

    public static func all(_ store: DozerStore) -> [String: ModelListRecord] {
        guard let d = try? Data(contentsOf: fileURL(store)) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: ModelListRecord].self, from: d)) ?? [:]
    }

    static func save(_ all: [String: ModelListRecord], _ store: DozerStore) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(all) else { return }
        try? d.write(to: fileURL(store), options: .atomic)
    }

    /// Whether to read a gateway's list now: never read, or older than a day — unless a read failed recently.
    public static func due(_ r: ModelListRecord?, now: Date = Date(), force: Bool = false) -> Bool {
        if let f = r?.failedAt, now.timeIntervalSince(f) < retryAfterFailure, f >= (r?.fetchedAt ?? .distantPast) { return false }
        if force { return true }
        guard let at = r?.fetchedAt else { return true }
        return now.timeIntervalSince(at) >= maxAge
    }

    /// A list as a source publishes it → the entries Dozer keeps (text models only, each checked; a malformed entry is
    /// dropped, a document that is not a list is an error). Sorted by name.
    public static func parse(_ data: Data, source: String) throws -> [ModelInfo] {
        let dec = JSONDecoder()
        let out: [ModelInfo]
        switch source {
        case "openrouter":
            guard let doc = try? dec.decode(OpenRouterList.self, from: data) else { throw HostError(.failed, "OpenRouter's model list is not a list of models") }
            out = doc.data.compactMap(\.value).compactMap { e in
                guard e.architecture?.outputModalities.map({ $0.contains("text") }) ?? true else { return nil }
                // "Meta: Muse Spark Open" → maker Meta, name Muse Spark Open; else the id's prefix.
                let raw = e.name ?? e.id
                var maker: String? = e.id.split(separator: "/").first.map(String.init)
                var name = raw
                if let r = raw.range(of: ": "), raw.distance(from: raw.startIndex, to: r.lowerBound) <= 40 {
                    maker = String(raw[..<r.lowerBound]); name = String(raw[r.upperBound...])
                }
                return entry(id: e.id, name: name, maker: maker, context: e.contextLength,
                             priceIn: e.pricing?.prompt, priceOut: e.pricing?.completion, tools: e.supportedParameters.map { $0.contains("tools") })
            }
        case "vercel-ai-gateway":
            guard let doc = try? dec.decode(VercelList.self, from: data) else { throw HostError(.failed, "Vercel AI Gateway's model list is not a list of models") }
            out = doc.data.compactMap(\.value).compactMap { e in
                guard e.type == nil || e.type == "language" else { return nil }
                return entry(id: e.id, name: e.name ?? e.id, maker: e.ownedBy ?? e.id.split(separator: "/").first.map(String.init),
                             context: e.contextWindow, priceIn: e.pricing?.input, priceOut: e.pricing?.output,
                             tools: e.tags.map { $0.contains("tool-use") } ?? e.supportedParameters.map { $0.contains("tools") })
            }
        default:
            throw HostError(.invalid, "\(source) publishes no model list")
        }
        var seen = Set<String>(), unique: [ModelInfo] = []
        for m in out where seen.insert(m.id).inserted { unique.append(m) }
        return Array(unique.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }.prefix(maximumModels))
    }

    /// One entry, checked: the id is a model id (`ModelSelection.isModelID`), the text inert and capped, the numbers sane.
    static func entry(id: String, name: String, maker: String?, context: Int?, priceIn: String?, priceOut: String?, tools: Bool?) -> ModelInfo? {
        guard ModelSelection.isModelID(id) else { return nil }
        let n = inert(name, maximumName)
        return ModelInfo(id: id, name: n.isEmpty ? id : n, maker: maker.map { inert($0, maximumMaker) }.flatMap { $0.isEmpty ? nil : $0 },
                         context: context.flatMap { (1...100_000_000).contains($0) ? $0 : nil },
                         pricePerMillionIn: perMillion(priceIn), pricePerMillionOut: perMillion(priceOut), tools: tools)
    }

    /// A price per token as the lists give it ("0.000003") → per million tokens (3.0); negative (OpenRouter's "-1": a
    /// variable price) or absurd → nil. Rounded to 4 decimals.
    static func perMillion(_ s: String?) -> Double? {
        guard let s, s.count <= 24, let v = Double(s), v.isFinite, v >= 0, v < 1 else { return nil }
        return (v * 1_000_000 * 10_000).rounded() / 10_000
    }

    /// Someone else's text: control characters and bidirectional overrides removed, whitespace folded, capped.
    static func inert(_ s: String, _ max: Int) -> String {
        let kept = s.unicodeScalars.filter { u in
            !(u.properties.generalCategory == .control || u.properties.generalCategory == .format || u.properties.generalCategory == .lineSeparator
              || u.properties.generalCategory == .paragraphSeparator)
        }
        let t = String(String.UnicodeScalarView(kept)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.count <= max ? t : String(t.prefix(max - 1)) + "…"
    }

    /// A provider's (or a gateway's never-read) list: the model Dozer checked, nothing else.
    public static func defaultsOnly(_ source: String) -> [ModelInfo] {
        var seen = Set<String>()
        return ModelSources.endpoints(source).compactMap(\.defaultModel).filter { seen.insert($0).inserted }.map {
            ModelInfo(id: $0, name: $0, maker: ModelSources.title(source))
        }
    }

    /// The list a source offers now, from what the store has.
    public static func list(_ source: String, record: ModelListRecord?) -> ModelList {
        let def = ModelSources.endpoints(source).first?.defaultModel
        if let k = ModelSources.keyless(source) {
            var l = ModelList(source: source, title: k.title, gateway: false, kind: "listed", fetchedAt: nil, defaultModel: def,
                              models: k.models.map { ModelInfo(id: $0.id, name: $0.name, pricePerMillionIn: 0, pricePerMillionOut: 0, note: $0.note) })
            l.checked = k.checked
            l.docs = k.docs
            return l
        }
        if fetched(source), let r = record, !r.models.isEmpty {
            return ModelList(source: source, title: ModelSources.title(source), gateway: ModelSources.isGateway(source), kind: "fetched",
                             fetchedAt: r.fetchedAt, defaultModel: def, models: r.models)
        }
        return ModelList(source: source, title: ModelSources.title(source), gateway: ModelSources.isGateway(source),
                         kind: fetched(source) ? "none" : "default", fetchedAt: nil, defaultModel: def, models: defaultsOnly(source))
    }

    /// `--model X` with a source chosen: X is not in its list — the closest few ids (a note, never a refusal: lists go
    /// stale). Empty when X is listed, or the list is only the default (a provider's).
    public static func suggestions(for model: String, in list: ModelList, limit: Int = 3) -> [String] {
        guard list.kind == "fetched" || list.kind == "listed", !list.models.contains(where: { $0.id == model }) else { return [] }
        let want = model.lowercased()
        let tail = want.split(separator: "/").last.map(String.init) ?? want
        let scored = list.models.map { m -> (Int, String) in
            let id = m.id.lowercased()
            let mtail = id.split(separator: "/").last.map(String.init) ?? id
            var d = min(distance(want, id), distance(tail, mtail) + 1)
            if id.contains(tail) || tail.contains(mtail) { d = min(d, max(0, abs(mtail.count - tail.count)) + 1) }
            return (d, m.id)
        }
        // Only ids that are close (a typo, a missing creator/) — never three random ones.
        let near = max(3, tail.count / 3)
        return scored.filter { $0.0 <= near }.sorted { $0 < $1 }.prefix(limit).map(\.1)
    }

    /// Levenshtein distance (short strings: model ids).
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a.prefix(128)), b = Array(b.prefix(128))
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // The published shapes (only the fields kept; anything else is ignored, a wrong type drops the entry).
    struct OpenRouterList: Decodable {
        struct Entry: Decodable {
            var id: String
            var name: String?
            var contextLength: Int?
            var pricing: Pricing?
            var supportedParameters: [String]?
            var architecture: Architecture?
            struct Pricing: Decodable { var prompt: String?; var completion: String? }
            struct Architecture: Decodable {
                var outputModalities: [String]?
                enum CodingKeys: String, CodingKey { case outputModalities = "output_modalities" }
            }
            enum CodingKeys: String, CodingKey {
                case id, name, pricing, architecture
                case contextLength = "context_length", supportedParameters = "supported_parameters"
            }
        }
        var data: [Lenient<Entry>]
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            data = try c.decode([Lenient<Entry>].self, forKey: .data)
        }
        enum CodingKeys: String, CodingKey { case data }
    }

    struct VercelList: Decodable {
        struct Entry: Decodable {
            var id: String
            var name: String?
            var ownedBy: String?
            var contextWindow: Int?
            var type: String?
            var tags: [String]?
            var supportedParameters: [String]?
            var pricing: Pricing?
            struct Pricing: Decodable { var input: String?; var output: String? }
            enum CodingKeys: String, CodingKey {
                case id, name, type, tags, pricing
                case ownedBy = "owned_by", contextWindow = "context_window", supportedParameters = "supported_parameters"
            }
        }
        var data: [Lenient<Entry>]
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            data = try c.decode([Lenient<Entry>].self, forKey: .data)
        }
        enum CodingKeys: String, CodingKey { case data }
    }

    /// An entry that does not decode is dropped, not the whole list.
    struct Lenient<T: Decodable>: Decodable {
        var value: T?
        init(from d: Decoder) throws { value = try? T(from: d) }
    }
}

import Foundation

// 617 (owner: "yes - split them, also use tags to classify them"): New Sandbox and the Quick try list some 35 agents and
// tools in one list. Every recipe and every known entry now DECLARES what it is (never derived — nothing in its data
// says it): a primary KIND — a coding agent or an AI tool, the split the lists show — and one or more CATEGORIES (a
// personal agent, a terminal tool, a framework …), the Quick try's filter pills and `doz search --tag`. The vocabulary
// is `Recipes/tags.json` (`kinds`, `categories`, beside the capability tags); a recipe says them in
// `directory@1` (`kind`, `categories`), a known entry in known.json. docs/recipes/RECIPE-FORMAT.md, "Kinds and
// categories".

/// One word of the kind or category vocabulary.
public struct CatalogWord: Codable, Sendable, Equatable {
    public var id: String
    /// "Coding agents", "Terminal tools".
    public var title: String
    public var meaning: String
    /// A category: the kind it belongs to when it belongs to one (`coding-agent` → coding agents), nil: either.
    public var kind: String?
}

public enum Categories {
    struct File: Codable { var schema: Int; var kinds: [CatalogWord]; var categories: [CatalogWord] }

    static let file: File = {
        do { return try JSONDecoder().decode(File.self, from: Data(PackageResources.tags_json)) } catch {
            fatalError("617: the built-in tags.json has no kinds and categories: \(error)")
        }
    }()

    /// `coding-agent`, `ai-tool` — the lists' two sections, in this order.
    public static var kinds: [CatalogWord] { file.kinds }
    public static var all: [CatalogWord] { file.categories }

    public static func kind(_ id: String) -> CatalogWord? { kinds.first { $0.id == id } }
    public static func category(_ id: String) -> CatalogWord? { all.first { $0.id == id } }

    /// A kind or a category, by id.
    public static func word(_ id: String) -> CatalogWord? { kind(id) ?? category(id) }

    /// The vocabulary itself: ids unique in each list (the category `coding-agent` is also the kind's name), a title and
    /// a meaning each, a category's kind a kind, and no category that is a capability tag.
    public static func validate(kinds: [CatalogWord] = kinds, categories: [CatalogWord] = all) throws {
        for list in [kinds, categories] {
            var ids = Set<String>()
            for w in list {
                guard w.id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil, ids.insert(w.id).inserted,
                      !w.title.isEmpty, !w.meaning.isEmpty, CapabilityTags.tag(w.id) == nil else {
                    throw SandboxError.invalidSpec("category \(w.id): an id, unique, with a title and a meaning, not a capability tag")
                }
            }
        }
        guard kinds.map(\.id) == ["coding-agent", "ai-tool"] else { throw SandboxError.invalidSpec("kinds: coding-agent, then ai-tool") }
        for c in categories where c.kind.map({ k in !kinds.contains { $0.id == k } }) == true {
            throw SandboxError.invalidSpec("category \(c.id): its kind is a kind")
        }
    }

    /// What a recipe or a known entry declares: one kind, one or more categories of the vocabulary, each once, none of
    /// another kind's.
    public static func validate(kind: String?, categories: [String]?, what: String) throws {
        guard let kind, let k = Categories.kind(kind) else {
            throw SandboxError.invalidSpec("\(what): kind is \(kinds.map(\.id).joined(separator: " or "))")
        }
        guard let categories, !categories.isEmpty, Set(categories).count == categories.count else {
            throw SandboxError.invalidSpec("\(what): one or more categories, each once")
        }
        for c in categories {
            guard let w = category(c) else { throw SandboxError.invalidSpec("\(what): \(c) is not a category (tags.json)") }
            if let wk = w.kind, wk != k.id { throw SandboxError.invalidSpec("\(what): \(c) is a category of \(wk), not of \(k.id)") }
        }
    }
}

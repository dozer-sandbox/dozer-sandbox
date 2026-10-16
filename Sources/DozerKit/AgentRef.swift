import Foundation

/// 618 (owner: "go with B and one card … make sure there is a way the user can chose an earlier major version"; the first
/// real case of 617.B5's qualified names): what a person types to name a tool —
///
///   · `NAME`            the tool; for a family (`opencode`), its RECOMMENDED major — a pin Dozer checked, never "latest";
///   · `NAME@MAJOR`      that major (`opencode@1`): the family's recipe of that major (any tool: its own major only);
///   · `NAME@VERSION`    an exact release (`opencode@2.0.28`) of the major it belongs to.
///
/// NAME is a recipe's id or alias, or a family's name. Only what a person TYPES goes through here (try/new/create/up, a
/// project file's `agent:`, the web plan, search) — a stored name never does: a sandbox, an image, a setting and a
/// statistics id keep the recipe's own id, so an existing sandbox never changes major. `@` qualifies only a tool's
/// name (`NAME:PATH` stays `doz get/put/cp`'s). Vendor and directory parts (617.B5) are later; the grammar leaves room.
public struct AgentRef: Equatable, Sendable {
    /// The recipe a create uses.
    public var recipe: AgentRecipe
    /// An exact release asked for (nil: the version the agent's setting gives — latest within its major, or exact).
    public var exact: String?
    /// The name as resolved: the family's name for a family member, else the recipe's id.
    public var name: String
    /// What was asked for after `@` (nil: none).
    public var qualifier: String?

    public var family: AgentRecipe.Family? { recipe.family }
    /// "opencode", "opencode@1", "opencode@2.0.28".
    public var text: String { qualifier.map { "\(name)@\($0)" } ?? name }
    /// What a file written for later records (a plan's doz_project.yaml, `doz init`, New Sandbox): a family's name keeps
    /// the major it resolved to (`opencode` → `opencode@2`), so the file never changes major when the recommendation
    /// moves; a member's own id becomes the family's name (`opencode2` → `opencode@2`). Anything else: `text`.
    public var pinned: String {
        guard let f = family else { return text }
        return "\(name)@\(qualifier ?? String(f.major))"
    }

    /// A reference that cannot be served — said with the choices there are.
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The leading number of a release (`2.0.29` → 2, `0.160.1` → 0).
    public static func major(of version: String) -> Int? {
        let d = version.prefix { $0.isNumber }
        guard !d.isEmpty, d.count <= 6 else { return nil }
        return Int(d)
    }

    static let versionPattern = "^[0-9]{1,6}(\\.[0-9]{1,9}){1,3}([-+][0-9A-Za-z.-]{1,40})?$"

    /// `NAME@…` split (nil: not a tool reference's shape).
    public static func split(_ s: String) -> (name: String, qualifier: String?)? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, t.count <= 80 else { return nil }
        let parts = t.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let n = parts.first, n.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else { return nil }
        if parts.count == 1 { return (n, nil) }
        let q = parts[1]
        guard !q.isEmpty else { return nil }
        return (n, q)
    }

    /// The majors of a family, oldest first.
    public static func members(_ family: String, in recipes: [AgentRecipe] = AgentRecipes.all) -> [AgentRecipe] {
        recipes.filter { $0.family?.family == family }.sorted { $0.family!.major < $1.family!.major }
    }

    /// The recommended major of a family (nil: not a family).
    public static func recommended(_ family: String, in recipes: [AgentRecipe] = AgentRecipes.all) -> AgentRecipe? {
        members(family, in: recipes).first { $0.family!.isRecommended }
    }

    /// What `s` names — nil when it names no tool at all (a base, a template, `none`: the caller's), a Problem when it
    /// names one that cannot be served as asked.
    public static func resolve(_ s: String, in recipes: [AgentRecipe] = AgentRecipes.all) throws -> AgentRef? {
        guard let (name, q) = split(s) else {
            if s.contains("@") { throw Problem(description: "\(s) is not a tool's name — NAME, NAME@MAJOR (opencode@1) or NAME@VERSION (opencode@2.0.28)") }
            return nil
        }
        let family = members(name, in: recipes)
        let base: AgentRecipe
        let shown: String
        if !family.isEmpty {
            shown = name
            if let q, let m = Int(q), q.allSatisfy(\.isNumber) {
                guard let r = family.first(where: { $0.family!.major == m }) else { throw Self.noMajor(name, q, family) }
                return AgentRef(recipe: r, exact: nil, name: name, qualifier: q)
            }
            base = family.first { $0.family!.isRecommended } ?? family.last!
        } else {
            let k = name
            guard let r = recipes.first(where: { $0.id == k || ($0.aliases ?? []).contains(k) }) else {
                if q != nil { throw Problem(description: "no tool is named \(name) (doz search \(name))") }
                return nil
            }
            base = r
            shown = r.family?.family ?? r.id
            if r.family != nil, q == nil {
                // A member named by its own id (`opencode2`) is that major — never the family's recommended one.
                return AgentRef(recipe: r, exact: nil, name: shown, qualifier: "\(r.family!.major)")
            }
            if let q, q.allSatisfy(\.isNumber) {
                guard let m = Int(q), m == major(of: r.install.pinned.version) else {
                    throw Problem(description: "\(name) has only \(name)@\(major(of: r.install.pinned.version).map(String.init) ?? "?") — not @\(q)")
                }
                return AgentRef(recipe: r, exact: nil, name: shown, qualifier: q)
            }
        }
        guard let q else { return AgentRef(recipe: base, exact: nil, name: shown, qualifier: nil) }
        guard q.range(of: versionPattern, options: .regularExpression) != nil, let m = major(of: q) else {
            throw Problem(description: "\(name)@\(q): after @ comes a major (\(name)@1) or a release (\(name)@\(base.install.pinned.version))")
        }
        let r: AgentRecipe
        if !family.isEmpty {
            guard let x = family.first(where: { $0.family!.major == m }) else { throw Self.noMajor(name, q, family) }
            r = x
        } else {
            guard major(of: base.install.pinned.version) == m else {
                throw Problem(description: "\(base.title) \(q) is not a release Dozer installs — its recipe is for \(name)@\(major(of: base.install.pinned.version) ?? 0)")
            }
            r = base
        }
        if AgentRecipe.pinnedOnlyKinds.contains(r.install.kind), q != r.install.pinned.version {
            throw Problem(description: "\(r.title) is installed at the release its recipe pins (\(r.install.pinned.version)) — not \(q)")
        }
        return AgentRef(recipe: r, exact: q, name: shown, qualifier: q)
    }

    static func noMajor(_ name: String, _ q: String, _ family: [AgentRecipe]) -> Problem {
        let have = family.map { "\(name)@\($0.family!.major)" + ($0.family!.isRecommended ? " (recommended)" : "") }
        return Problem(description: "\(name) has \(have.joined(separator: " and ")) — not @\(q)")
    }

    /// The name that means exactly `recipe` when typed: a family's name for its recommended major, `family@major` for any
    /// other (its id alone would be the family's), else its id.
    public static func typed(_ recipe: AgentRecipe) -> String {
        guard let f = recipe.family else { return recipe.id }
        return f.isRecommended ? f.family : "\(f.family)@\(f.major)"
    }

    /// What a sandbox records: `opencode@2.0.29` — the family's (or tool's) name and the exact release it was made with.
    public static func recorded(_ recipe: AgentRecipe, version: String?) -> String {
        let n = recipe.family?.family ?? recipe.id
        guard let v = version?.split(separator: "+").first.map(String.init), !v.isEmpty else { return n }
        return "\(n)@\(v)"
    }

    /// "OpenCode 2 (recommended; also @1)" — how a family's choice reads in a list.
    public static func choicesLine(_ recipe: AgentRecipe, in recipes: [AgentRecipe] = AgentRecipes.all) -> String? {
        guard let f = recipe.family else { return nil }
        let others = members(f.family, in: recipes).filter { $0.id != recipe.id }.map { "@\($0.family!.major)" }
        let head = f.isRecommended ? "recommended" : "@\(f.major)"
        return others.isEmpty ? head : "\(head); also \(others.joined(separator: ", "))"
    }
}

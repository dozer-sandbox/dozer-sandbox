import Foundation
import DozerKit
import Yams

// 617 — the recipe SOURCE files (`Sources/DozerKit/Recipes/agents/VENDOR/PRODUCT.yaml`, `schema: 2`) and their compiled
// form (`Recipes/compiled/PRODUCT.json`, the same tree as canonical JSON — what DozerKit embeds; it has no YAML
// parser, and Yams stays in the CLI: Scripts/audit.sh). `make recipes` compiles; RecipeSourceTests fails when a
// compiled file is not exactly what its YAML compiles to. docs/recipes/RECIPE-FORMAT.md is the spec.
public enum RecipeSource {
    /// YAML 1.2's core schema only: `true`/`false`, integers, floats and `null` — never YAML 1.1's `yes`/`no`/`on`/`off`
    /// (a gateway's `level: no` is the word "no") and never a timestamp (a date stays a string).
    static let resolver = Resolver.basic
        .appending(try! Resolver.Rule(.bool, "^(?:true|false)$"))
        .appending(try! Resolver.Rule(.int, "^[-+]?(?:0|[1-9][0-9]*)$"))
        .appending(try! Resolver.Rule(.float, #"^[-+]?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?$"#))
        .appending(try! Resolver.Rule(.null, "^(?:null|~|)$"))

    /// The YAML's tree as canonical JSON (sorted keys, two-space indent, unescaped slashes, a final newline). Refuses
    /// anything that is not one mapping, and anchors or merge keys (a recipe is plain data).
    public static func compile(yaml: String) throws -> Data {
        if yaml.range(of: #"(?m)^[^#'"\n]*[&*][A-Za-z0-9_-]+"#, options: .regularExpression) != nil
            || yaml.range(of: #"(?m)^\s*<<\s*:"#, options: .regularExpression) != nil {
            throw SandboxError.invalidSpec("a recipe uses no YAML anchors, aliases or merge keys")
        }
        guard let tree = try Yams.load(yaml: yaml, resolver), tree is [String: Any] else {
            throw SandboxError.invalidSpec("a recipe is one YAML mapping")
        }
        return try JSONSerialization.data(withJSONObject: normalized(tree), options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    /// Yams' values as JSONSerialization's (an integer stays an integer).
    static func normalized(_ v: Any) -> Any {
        if let o = v as? [String: Any] { return o.mapValues(normalized) }
        if let a = v as? [Any] { return a.map(normalized) }
        if v is NSNull { return NSNull() }
        return v
    }

    /// The document as a YAML file: the editor line (`# yaml-language-server: $schema=…`, relative to the file), a
    /// comment, then the tree in block style.
    public static func yaml(_ d: RecipeDocument, schemaPath: String, header: String) throws -> String {
        let tree = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(d))
        let body = try Yams.serialize(node: try node(tree), indent: 2, width: -1, allowUnicode: true)
        return "# yaml-language-server: $schema=\(schemaPath)\n" + header.split(separator: "\n").map { "# " + $0 }.joined(separator: "\n") + "\n" + body
    }

    /// The order a field is written in (a field of the format; a key not here — an environment variable, a dotted
    /// setting, a path — comes after, alphabetically): deterministic, and in the order a person reads a recipe.
    static let fieldOrder: [String] = [
        "schema", "kind", "type", "id", "gateway", "tag", "level", "displayName", "title", "description", "author", "sourceUrl", "licenses",
        "args", "version", "default", "pattern", "buildArg", "provides", "capabilities", "config",
        "install", "runtime", "allow", "deny",
        "service", "phase", "apiKey", "name", "proxyManaged", "inject", "domain", "header", "format",
        "path", "directory", "filename",
        "model", "shared", "summary", "phrase", "hosts", "host", "paths", "exact_paths", "reason", "update", "excluded", "vendor", "quiet",
        "off_without", "permission",
        "manifest", "file", "json", "launcher_arg",
        "builtin", "package", "platform_package", "payload", "compression", "binary", "needs_node", "npm_args", "url", "bake_hosts", "integrity",
        "command", "no_prompts_args", "passthrough", "env", "says", "state_env", "first_run", "set", "session_env", "status", "resume", "resume_check",
        "verify", "argv", "expect", "settings", "permissions",
        "methods", "provider", "account", "accounts", "keys_page", "free_tier", "free_tier_note", "in_sandbox", "gateways", "note",
        "entries", "shape", "endpoint", "how", "model_args", "proxy_route", "from_host", "unmapped", "limits", "notes", "evidence", "source",
        "checked", "lifecycle", "by",
        "aliases", "icon", "default_base", "platforms", "glibc", "musl", "base", "tags", "terms", "licence",
        "dozer",
    ]
    static let rank: [String: Int] = { var r: [String: Int] = [:]; for (i, k) in fieldOrder.enumerated() where r[k] == nil { r[k] = i }; return r }()

    static func node(_ v: Any) throws -> Node {
        if let o = v as? [String: Any] {
            let keys = o.keys.sorted { a, b in
                switch (rank[a], rank[b]) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a < b
                }
            }
            var pairs: [(Node, Node)] = []
            for k in keys { pairs.append((try k.represented(), try node(o[k]!))) }
            return Node(pairs)
        }
        if let a = v as? [Any] { return Node(try a.map(node)) }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return try n.boolValue.represented() }
            if n.doubleValue == n.doubleValue.rounded(), abs(n.doubleValue) < 1e15 { return try Int(n.int64Value).represented() }
            return try n.doubleValue.represented()
        }
        if let s = v as? String { return try s.represented() }
        return Node("null", Tag(.null))
    }
}

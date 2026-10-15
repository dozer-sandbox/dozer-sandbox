import Foundation

/// 617: a small JSON Schema validator for the tests — the keywords our published schemas (draft 2020-12) and Docker
/// Sandbox Kit v3's vendored ones (draft-07) use, and nothing else: an unknown keyword is reported as an error, so a
/// schema can never be half-checked in silence. `$ref` resolves within a document (`#/…`) and to sibling files
/// (`capabilities/x.schema.json#/…`), relative to the referring file.
struct JSONSchemaValidator {
    private var docs: [URL: Any] = [:]

    static let annotations: Set<String> = ["$schema", "$id", "$comment", "title", "description", "default", "examples", "definitions", "$defs",
                                           "format", "readOnly", "deprecated"]

    mutating func validate(_ instance: Any, schemaFile: URL) -> [String] {
        let root = load(schemaFile)
        var errors: [String] = []
        check(instance, root, file: schemaFile, at: "", into: &errors)
        return errors
    }

    private mutating func load(_ u: URL) -> Any {
        let k = u.standardizedFileURL
        if let d = docs[k] { return d }
        let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: k), options: [.fragmentsAllowed])) ?? ["$unreadable": k.path]
        docs[k] = d
        return d
    }

    private mutating func resolve(_ ref: String, from file: URL) -> (Any, URL)? {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let target = parts[0].isEmpty ? file : file.deletingLastPathComponent().appendingPathComponent(parts[0]).standardizedFileURL
        var node: Any = load(target)
        if parts.count == 2, !parts[1].isEmpty {
            for raw in parts[1].split(separator: "/") {
                let key = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                guard let o = node as? [String: Any], let next = o[key] else { return nil }
                node = next
            }
        }
        return (node, target)
    }

    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func isNumber(_ v: Any) -> Bool { v is NSNumber && !isBool(v) }
    static func isInteger(_ v: Any) -> Bool { guard isNumber(v), let n = v as? NSNumber else { return false }; return n.doubleValue == n.doubleValue.rounded() }

    static func typeMatches(_ v: Any, _ t: String) -> Bool {
        switch t {
        case "object": return v is [String: Any]
        case "array": return v is [Any]
        case "string": return v is String
        case "boolean": return isBool(v)
        case "number": return isNumber(v)
        case "integer": return isInteger(v)
        case "null": return v is NSNull
        default: return false
        }
    }

    /// JSON equality (a boolean is never a number).
    static func equal(_ a: Any, _ b: Any) -> Bool {
        if isBool(a) || isBool(b) { return isBool(a) && isBool(b) && (a as! NSNumber).boolValue == (b as! NSNumber).boolValue }
        if let x = a as? NSNumber, let y = b as? NSNumber { return x.doubleValue == y.doubleValue }
        if let x = a as? String, let y = b as? String { return x == y }
        if a is NSNull, b is NSNull { return true }
        if let x = a as? [Any], let y = b as? [Any] { return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) } }
        if let x = a as? [String: Any], let y = b as? [String: Any] { return Set(x.keys) == Set(y.keys) && x.allSatisfy { equal($0.value, y[$0.key]!) } }
        return false
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private mutating func valid(_ v: Any, _ schema: Any, file: URL) -> Bool {
        var e: [String] = []
        check(v, schema, file: file, at: "", into: &e)
        return e.isEmpty
    }

    private mutating func check(_ v: Any, _ schema: Any, file: URL, at path: String, into errors: inout [String]) {
        if let b = schema as? Bool { if !b { errors.append("\(path): false schema") }; return }
        guard let s = schema as? [String: Any] else { errors.append("\(path): not a schema"); return }
        let here = path.isEmpty ? "/" : path
        for key in s.keys where !Self.known.contains(key) && !Self.annotations.contains(key) { errors.append("\(here): the validator does not know the keyword \(key)") }

        if let ref = s["$ref"] as? String {
            if let (target, f) = resolve(ref, from: file) { check(v, target, file: f, at: path, into: &errors) } else { errors.append("\(here): unresolvable $ref \(ref)") }
        }
        if let t = s["type"] {
            let types = (t as? [String]) ?? [(t as? String) ?? ""]
            if !types.contains(where: { Self.typeMatches(v, $0) }) { errors.append("\(here): not of type \(types.joined(separator: "|"))"); return }
        }
        if let c = s["const"], !Self.equal(v, c) { errors.append("\(here): not \(c)") }
        if let e = s["enum"] as? [Any], !e.contains(where: { Self.equal(v, $0) }) { errors.append("\(here): not one of \(e)") }

        if let str = v as? String {
            if let p = s["pattern"] as? String, !Self.matches(str, p) { errors.append("\(here): \"\(str.prefix(80))\" does not match \(p)") }
            if let n = s["minLength"] as? Int, str.count < n { errors.append("\(here): shorter than \(n)") }
            if let n = s["maxLength"] as? Int, str.count > n { errors.append("\(here): longer than \(n)") }
        }
        if Self.isNumber(v), let n = v as? NSNumber {
            if let lo = s["minimum"] as? NSNumber, n.doubleValue < lo.doubleValue { errors.append("\(here): less than \(lo)") }
            if let hi = s["maximum"] as? NSNumber, n.doubleValue > hi.doubleValue { errors.append("\(here): more than \(hi)") }
        }
        if let o = v as? [String: Any] {
            let props = s["properties"] as? [String: Any] ?? [:]
            for r in s["required"] as? [String] ?? [] where o[r] == nil { errors.append("\(here): \(r) is required") }
            for (k, x) in o {
                if let ps = props[k] { check(x, ps, file: file, at: path + "/" + k, into: &errors) }
                else if let ap = s["additionalProperties"] {
                    if let b = ap as? Bool { if !b { errors.append("\(here): \(k) is not allowed") } }
                    else { check(x, ap, file: file, at: path + "/" + k, into: &errors) }
                }
                if let pn = s["propertyNames"] { check(k, pn, file: file, at: path + "/" + k + "(name)", into: &errors) }
            }
            if let n = s["minProperties"] as? Int, o.count < n { errors.append("\(here): fewer than \(n) properties") }
            if let n = s["maxProperties"] as? Int, o.count > n { errors.append("\(here): more than \(n) properties") }
            for key in ["dependencies", "dependentRequired"] {
                for (k, d) in s[key] as? [String: Any] ?? [:] where o[k] != nil {
                    if let need = d as? [String] { for n in need where o[n] == nil { errors.append("\(here): \(k) needs \(n)") } }
                    else { check(v, d, file: file, at: path, into: &errors) }
                }
            }
        }
        if let a = v as? [Any] {
            if let items = s["items"] { for (i, x) in a.enumerated() { check(x, items, file: file, at: path + "/\(i)", into: &errors) } }
            if let n = s["minItems"] as? Int, a.count < n { errors.append("\(here): fewer than \(n) items") }
            if let n = s["maxItems"] as? Int, a.count > n { errors.append("\(here): more than \(n) items") }
            if s["uniqueItems"] as? Bool == true {
                for i in a.indices { for j in a.indices where j > i && Self.equal(a[i], a[j]) { errors.append("\(here): items \(i) and \(j) are the same") } }
            }
            if let c = s["contains"] {
                let n = a.filter { valid($0, c, file: file) }.count
                let lo = s["minContains"] as? Int ?? 1
                if n < lo { errors.append("\(here): \(n) items match contains (at least \(lo))") }
                if let hi = s["maxContains"] as? Int, n > hi { errors.append("\(here): \(n) items match contains (at most \(hi))") }
            }
        }
        if let all = s["allOf"] as? [Any] { for x in all { check(v, x, file: file, at: path, into: &errors) } }
        if let any = s["anyOf"] as? [Any], !any.contains(where: { valid(v, $0, file: file) }) { errors.append("\(here): matches none of anyOf") }
        if let one = s["oneOf"] as? [Any] {
            let n = one.filter { valid(v, $0, file: file) }.count
            if n != 1 {
                errors.append("\(here): matches \(n) of oneOf")
                if n == 0, let o = v as? [String: Any], let t = o["type"] as? String {
                    // Say why the branch for this capability type refused it.
                    for x in one {
                        guard let ref = (x as? [String: Any])?["$ref"] as? String, let (target, f) = resolve(ref, from: file),
                              let tconst = (((target as? [String: Any])?["properties"] as? [String: Any])?["type"] as? [String: Any])?["const"] as? String,
                              tconst == t else { continue }
                        check(v, target, file: f, at: path, into: &errors)
                    }
                }
            }
        }
        if let not = s["not"], valid(v, not, file: file) { errors.append("\(here): matches not") }
        if let cond = s["if"] {
            if valid(v, cond, file: file) { if let t = s["then"] { check(v, t, file: file, at: path, into: &errors) } }
            else if let e = s["else"] { check(v, e, file: file, at: path, into: &errors) }
        }
    }

    static let known: Set<String> = ["$ref", "type", "const", "enum", "pattern", "minLength", "maxLength", "properties", "required",
                                     "additionalProperties", "propertyNames", "minProperties", "maxProperties", "dependencies", "dependentRequired",
                                     "items", "minItems", "maxItems", "uniqueItems", "contains", "minContains", "maxContains", "allOf", "anyOf",
                                     "oneOf", "not", "if", "then", "else", "minimum", "maximum"]
}

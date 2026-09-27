import Foundation

/// Any JSON value — the `result` of a host response, whose shape depends on the operation. Typed
/// structs go in and come out through `JSONValue(encoding:)` / `decode(_:)`.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Whole numbers go out without a fraction (byte counts, pids), so a reader never sees 12.0.
            if n.rounded() == n, abs(n) < 9_007_199_254_740_992 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Any Encodable, as a JSON value (dates ISO-8601, like everything on the wire).
    public init<T: Encodable>(encoding value: T) throws {
        let data = try HostWire.encoder.encode(value)
        self = try HostWire.decoder.decode(JSONValue.self, from: data)
    }

    /// This value as `T`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try HostWire.decoder.decode(T.self, from: HostWire.encoder.encode(self))
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
}

/// The encoders every message and every `--json` document uses.
public enum HostWire {
    /// One line: sorted keys, ISO-8601 dates with fractions, no newline anywhere inside.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(isoFormatter().string(from: date))
        }
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = isoFormatter().date(from: s) ?? ISO8601DateFormatter().date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO-8601 date: \(s)")
        }
        return d
    }()

    /// A pretty, sorted document for `--json` output.
    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = encoder.dateEncodingStrategy
        return e
    }()

    static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

import Foundation

/// Splits a client's HTTP/1.x byte stream into request heads and body bytes, so the proxy can
/// judge (and rewrite) every request's head while passing bodies through byte for byte. Handles
/// `Content-Length`, `Transfer-Encoding: chunked` (framing passed through unchanged) and
/// `Upgrade` (after that head, everything is `.raw`).
struct HTTPRequestReader {
    enum Event: Equatable {
        case head([UInt8])
        case body([UInt8])
        /// After an Upgrade (WebSocket) request: opaque bytes.
        case raw([UInt8])
        case malformed(String)
    }

    private enum State: Equatable {
        case head
        case body(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkDataEnd
        case trailer
        case raw
        case failed
    }

    static let maxHead = 64 * 1024

    private var state: State = .head
    private var buffer: [UInt8] = []

    mutating func feed(_ bytes: [UInt8]) -> [Event] {
        buffer += bytes
        var out: [Event] = []
        var bodyRun: [UInt8] = []
        func flushBody() { if !bodyRun.isEmpty { out.append(.body(bodyRun)); bodyRun = [] } }
        loop: while !buffer.isEmpty {
            switch state {
            case .failed:
                buffer = []
                break loop
            case .raw:
                flushBody()
                out.append(.raw(buffer)); buffer = []
            case .head:
                guard let end = Self.find(buffer, [13, 10, 13, 10]) else {
                    if buffer.count > Self.maxHead { state = .failed; out.append(.malformed("request head over 64 KiB")) }
                    break loop
                }
                let head = Array(buffer[0..<end + 4])
                buffer.removeFirst(end + 4)
                guard let h = HTTPHead(head) else { state = .failed; flushBody(); out.append(.malformed("unparseable request head")); break loop }
                flushBody()
                out.append(.head(head))
                if h.value("upgrade") != nil { state = .raw; continue }
                if h.value("transfer-encoding")?.lowercased().contains("chunked") == true { state = .chunkSize; continue }
                let n = Int(h.value("content-length") ?? "0") ?? -1
                guard n >= 0 else { state = .failed; out.append(.malformed("bad content-length")); break loop }
                state = n > 0 ? .body(remaining: n) : .head
            case .body(let remaining):
                let take = min(remaining, buffer.count)
                bodyRun += buffer[0..<take]; buffer.removeFirst(take)
                state = remaining - take == 0 ? .head : .body(remaining: remaining - take)
            case .chunkSize:
                guard let e = Self.find(buffer, [13, 10]) else { break loop }
                let line = String(decoding: buffer[0..<e], as: UTF8.self)
                let hex = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(hex, radix: 16), size >= 0 else { state = .failed; out.append(.malformed("bad chunk size")); break loop }
                bodyRun += buffer[0..<e + 2]; buffer.removeFirst(e + 2)
                state = size == 0 ? .trailer : .chunkData(remaining: size)
            case .chunkData(let remaining):
                let take = min(remaining, buffer.count)
                bodyRun += buffer[0..<take]; buffer.removeFirst(take)
                state = remaining - take == 0 ? .chunkDataEnd : .chunkData(remaining: remaining - take)
            case .chunkDataEnd:
                guard buffer.count >= 2 else { break loop }
                bodyRun += buffer[0..<2]; buffer.removeFirst(2)
                state = .chunkSize
            case .trailer:
                guard let e = Self.find(buffer, [13, 10]) else { break loop }
                bodyRun += buffer[0..<e + 2]; buffer.removeFirst(e + 2)
                if e == 0 { state = .head }
            }
        }
        flushBody()
        return out
    }

    /// Between requests (nothing of a body outstanding).
    var atRequestBoundary: Bool { state == .head && buffer.isEmpty }

    static func find(_ b: [UInt8], _ needle: [UInt8]) -> Int? {
        guard b.count >= needle.count else { return nil }
        var i = 0
        while i <= b.count - needle.count {
            if b[i] == needle[0] {
                var ok = true
                for j in 1..<needle.count where b[i + j] != needle[j] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }
}

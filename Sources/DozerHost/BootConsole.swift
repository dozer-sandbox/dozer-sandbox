import Foundation
import DozerKit

/// The `console` op's result (without --follow).
public struct BootConsoleLines: Codable, Equatable, Sendable {
    public var name: String
    public var lines: [String]
    public init(name: String, lines: [String]) {
        self.name = name
        self.lines = lines
    }
}

/// 591 — a sandbox's boot console (`Sandbox.bootLogURL`: the kernel + vminitd serial log the VM
/// appends to), read incrementally as LINES for `doz console` and the `console` host op.
///
/// `Sandbox.bootConsole()` re-emits the last N lines whenever the file grows (right for a panel that
/// redraws); a stream needs each line once, so this keeps an offset into the same file. A cold boot
/// deletes and recreates the log (`Sandbox` removes it before the VM starts): a file shorter than the
/// offset starts over from its first byte. The text is written by the guest — callers show it as
/// data; lines are capped at `maximumLineBytes`, carriage returns dropped.
public struct BootConsoleTail: Sendable {
    public let url: URL
    public static let maximumLineBytes = 1024
    /// On the first read, at most this much of an existing log is replayed (its newest part).
    public static let replayBytes = 256 * 1024
    private var offset: Int?
    private var partial: [UInt8] = []

    public init(url: URL) { self.url = url }

    /// The complete lines written since the last call (the replayed tail on the first).
    public mutating func poll() -> [String] {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            if offset != nil { offset = 0; partial = [] }       // gone (a cold boot is recreating it)
            return []
        }
        defer { try? fh.close() }
        let size = Int((try? fh.seekToEnd()) ?? 0)
        var skipToNewline = false
        if offset == nil {
            offset = max(0, size - Self.replayBytes)
            skipToNewline = offset! > 0                          // began mid-file: drop the partial first line
        } else if size < offset! {
            offset = 0                                           // truncated or recreated: from the top
            partial = []
        }
        guard size > offset! else { return [] }
        try? fh.seek(toOffset: UInt64(offset!))
        var bytes = [UInt8]((try? fh.read(upToCount: size - offset!)) ?? Data())
        offset! += bytes.count
        if skipToNewline, let nl = bytes.firstIndex(of: 10) { bytes.removeSubrange(...nl) }
        var lines: [String] = []
        for b in bytes {
            if b == 10 {
                lines.append(Self.line(partial))
                partial = []
            } else if b != 13, partial.count < Self.maximumLineBytes {
                partial.append(b)
            }
        }
        return lines
    }

    static func line(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    /// Everything so far (the replayed tail), for `doz console` without --follow.
    public static func lines(of url: URL) -> [String] {
        var t = BootConsoleTail(url: url)
        var out = t.poll()
        if !t.partial.isEmpty { out.append(line(t.partial)) }
        return out
    }
}

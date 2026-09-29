import Foundation
import DozerKit
import XCTest
@testable import DozerHost

/// 593: the progress view — formatting, the board's life cycle, the terminal bytes in both modes
/// (the live block erased and redrawn, never in the scrollback), guest text inert, digests trimmed,
/// and `ui.progress`'s precedence.
final class ProgressViewTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func ev(_ kind: HostEvent.Kind, _ text: String? = nil, ms: Double? = nil, done: Int64? = nil, total: Int64? = nil,
            items: Int? = nil, totalItems: Int? = nil, error: String? = nil) -> HostEvent {
        var e = HostEvent(kind: kind, sandbox: "c1", text: text, milliseconds: ms, completedBytes: done, totalBytes: total)
        e.completedItems = items
        e.totalItems = totalItems
        e.error = error
        return e
    }

    func testFormatting() {
        XCTAssertEqual(ProgressFormat.duration(0.0123), "12 ms")
        XCTAssertEqual(ProgressFormat.duration(1.23), "1.2 s")
        XCTAssertEqual(ProgressFormat.duration(125), "2 min 5 s")
        XCTAssertEqual(ProgressFormat.bytes(142_000_000), "142 MB")
        XCTAssertEqual(ProgressFormat.bytes(1_400_000_000), "1.4 GB")
        XCTAssertEqual(ProgressFormat.amount(87_000_000, 142_000_000), "87 / 142 MB")
        XCTAssertEqual(ProgressFormat.rate(6_100_000), "6.1 MB/s")
        XCTAssertEqual(ProgressFormat.bar(0.5, width: 10), "█████░░░░░")
        XCTAssertEqual(ProgressFormat.bar(2, width: 4), "████")
        XCTAssertEqual(ProgressFormat.bar(.nan, width: 4), "░░░░")
        let d = String(repeating: "0123456789abcdef", count: 4)
        XCTAssertEqual(ProgressFormat.trimDigests("from docker.io/library/node@sha256:\(d) (one-time)"), "from docker.io/library/node@0123456789ab (one-time)")
        XCTAssertEqual(ProgressFormat.trimDigests("key \(d)"), "key 0123456789ab")
        XCTAssertEqual(ProgressFormat.inert("a\u{1B}[2Jb\u{7}c"), "a[2Jbc", "no control character survives")
    }

    func testTheBoardFollowsStepsTransfersAndOutput() {
        let b = ProgressBoard()
        XCTAssertEqual(b.apply(ev(.started, "booted the bake VM"), now: t0), [])
        XCTAssertEqual(b.live(now: t0 + 2.5), [.step("booted the bake VM", seconds: 2.5)])
        XCTAssertEqual(b.apply(ev(.output, "added 12 packages"), now: t0), [])
        XCTAssertEqual(b.apply(ev(.output, "added 13 packages"), now: t0), [])
        XCTAssertEqual(b.apply(ev(.output, "added 14 packages"), now: t0), [])
        XCTAssertEqual(b.live(now: t0).suffix(2), [.output("added 13 packages"), .output("added 14 packages")], "the last two lines")
        XCTAssertEqual(b.apply(ev(.step, "booted the bake VM", ms: 1200), now: t0 + 3), [.stepDone("booted the bake VM", seconds: 1.2)])
        XCTAssertFalse(b.isLive, "the tail goes with its step")
        // A pull: the transfer line, then done when it reaches its total.
        _ = b.apply(ev(.started, "pulled the base image node"), now: t0)
        _ = b.apply(ev(.progress, "pulling node@1a2b3c4d5e6f", done: 0, total: 142_000_000, items: 0, totalItems: 5), now: t0)
        _ = b.apply(ev(.progress, "pulling node@1a2b3c4d5e6f", done: 87_000_000, total: 142_000_000, items: 3, totalItems: 5), now: t0 + 10)
        guard case .transfer(let line)? = b.live(now: t0 + 10).dropFirst().first else { return XCTFail("no transfer line") }
        XCTAssertEqual(line, "pulling node@1a2b3c4d5e6f  ████████████░░░░░░░░  87 / 142 MB  8.7 MB/s  ~6.3 s  (3/5 layers)")
        let done = b.apply(ev(.progress, "pulling node@1a2b3c4d5e6f", done: 142_000_000, total: 142_000_000, items: 5, totalItems: 5), now: t0 + 16)
        XCTAssertEqual(done, [.transferDone("pulling node@1a2b3c4d5e6f", bytes: 142_000_000, seconds: 16)])
        XCTAssertEqual(b.apply(ev(.failed, "pulled the base image node", ms: 16_000, error: "registry said 503"), now: t0 + 16),
                       [.stepFailed("pulled the base image node", seconds: 16, error: "registry said 503")])
        XCTAssertFalse(b.isLive)
        XCTAssertEqual(b.apply(ev(.note, "first start in this store")), [.note("first start in this store")])
    }

    func testAnimatedBytesKeepTheLiveBlockOutOfTheScrollback() {
        let v = ProgressTerminal(mode: .animated, color: false)
        let a = v.apply(ev(.started, "step: npm install"), now: t0)
        XCTAssertEqual(a, "⠋ step: npm install  0 ms", "the block: no newline after it")
        let b = v.apply(ev(.output, "added 3 packages"), now: t0 + 1)
        XCTAssertEqual(b, "\r\u{1B}[J" + "⠋ step: npm install  1.0 s\r\n  │ added 3 packages", "erased, redrawn")
        let tick = v.tick(now: t0 + 1.2)
        XCTAssertEqual(tick, "\r\u{1B}[1A\u{1B}[J" + "⠙ step: npm install  1.2 s\r\n  │ added 3 packages", "a tick: the next frame, in place")
        let c = v.apply(ev(.step, "step: npm install", ms: 2500), now: t0 + 2.5)
        XCTAssertEqual(c, "\r\u{1B}[1A\u{1B}[J" + "✓ step: npm install — 2.5 s\r\n", "the finished line — and no block left")
        XCTAssertFalse(v.hasBlock)
        XCTAssertEqual(v.tick(now: t0 + 3), "", "nothing live: no bytes")
        // A console line from outside goes above the block.
        _ = v.apply(ev(.started, "VM created and booted"), now: t0)
        let console = v.write([.raw("[    0.1] Linux version")], now: t0)
        XCTAssertTrue(console.hasPrefix("\r\u{1B}[J[    0.1] Linux version\r\n") && console.hasSuffix(" VM created and booted  0 ms"), console)
        XCTAssertEqual(v.finish(now: t0), "\r\u{1B}[J", "the end erases the block")
    }

    /// A live line wider than the terminal would wrap, and the redraw would leave a row behind each
    /// tick (the first-start probe caught it): every live line fits one row.
    func testLiveLinesFitTheTerminalsWidth() {
        let v = ProgressTerminal(mode: .animated, color: false)
        v.width = 40
        _ = v.apply(ev(.started, "step: install the developer baseline (procps git less jq unzip openssh-client)"), now: t0)
        _ = v.apply(ev(.progress, "pulling node@d649c27dae7b", done: 30_000_000, total: 328_000_000, items: 11, totalItems: 45), now: t0)
        let block = v.apply(ev(.output, String(repeating: "npm warn deprecated ", count: 10)), now: t0 + 5)
        let rows = block.replacingOccurrences(of: "\r\u{1B}[1A\u{1B}[J", with: "").replacingOccurrences(of: "\r\u{1B}[J", with: "")
            .replacingOccurrences(of: #"\r\u{1B}\[\d+A\u{1B}\[J"#, with: "", options: .regularExpression)
            .components(separatedBy: "\r\n")
        XCTAssertEqual(rows.count, 3)
        for r in rows { XCTAssertLessThanOrEqual(r.count, 39, r) }
        XCTAssertTrue(rows[0].hasSuffix("5.0 s"), "the seconds stay visible: \(rows[0])")
        XCTAssertTrue(rows[1].hasSuffix("…"))
    }

    func testPlainModeIsLinesAndASummaryOnly() {
        let v = ProgressTerminal(mode: .plain, color: false, plainPrefix: "  · ")
        XCTAssertEqual(v.apply(ev(.started, "booted the bake VM"), now: t0), "", "no line for a start")
        XCTAssertEqual(v.apply(ev(.output, "\u{1B}]52;c;x\u{07}added"), now: t0), "", "no output tail")
        XCTAssertEqual(v.tick(now: t0 + 1), "", "no ticks")
        XCTAssertEqual(v.apply(ev(.step, "booted the bake VM", ms: 812), now: t0), "  · booted the bake VM — 812 ms\r\n")
        _ = v.apply(ev(.progress, "pulling node@1a2b3c4d5e6f", done: 0, total: 142_000_000), now: t0)
        XCTAssertEqual(v.apply(ev(.progress, "pulling node@1a2b3c4d5e6f", done: 142_000_000, total: 142_000_000), now: t0 + 23), "  · pulled node@1a2b3c4d5e6f: 142 MB in 23.0 s\r\n")
        for s in [v.apply(ev(.step, "x", ms: 1)), v.finish()] {
            XCTAssertFalse(s.contains("\u{1B}"), "plain without colour: no escape at all")
            XCTAssertFalse(s.contains("⠋"))
        }
        let web = ProgressTerminal(mode: .plain, color: true, plainPrefix: "[doz] ", plainStyle: "2")
        XCTAssertEqual(web.apply(ev(.step, "kernel ready", ms: 11)), "\u{1B}[2m[doz] kernel ready — 11 ms\u{1B}[0m\r\n", "the web's plain lines, dim")
    }

    func testGuestOutputCannotEscape() {
        let v = ProgressTerminal(mode: .animated, color: true)
        _ = v.apply(ev(.started, "step"), now: t0)
        let out = v.apply(ev(.output, "\u{1B}]8;;http://evil\u{07}click\u{1B}[?1049h\u{9B}2J"), now: t0)
        XCTAssertFalse(out.contains("\u{1B}]"), "no OSC")
        XCTAssertFalse(out.contains("?1049h\u{1B}") || out.contains("\u{1B}[?1049h"), "no mode change")
        XCTAssertFalse(out.contains("\u{9B}"), "no C1 CSI")
        XCTAssertFalse(out.contains("\u{07}"))
    }

    func testTheSettingFlagEnvFileDefault() throws {
        XCTAssertEqual(DozerSettings(text: nil).progressMode(), .animated, "the default")
        XCTAssertEqual(DozerSettings(text: "[ui]\nprogress = \"plain\"\n").progressMode(), .plain, "the file")
        XCTAssertEqual(DozerSettings(text: "[ui]\nprogress = \"plain\"\n", environment: ["DOZ_PROGRESS": "animated"]).progressMode(), .animated, "the environment over the file")
        XCTAssertEqual(DozerSettings(text: nil, environment: ["DOZ_PROGRESS": "plain"]).progressMode(), .plain)
        XCTAssertEqual(DozerSettings(text: nil, environment: ["DOZ_PROGRESS": "plain"]).progressMode(flag: "auto"), .animated, "the flag over all")
        XCTAssertEqual(DozerSettings(text: nil).progressMode(flag: "plain"), .plain)
        XCTAssertEqual(DozerSettings.definition("ui.progress")?.environment, "DOZ_PROGRESS")
        XCTAssertThrowsError(try DozerSettings.definition("ui.progress")!.parse("fancy"))
    }
}

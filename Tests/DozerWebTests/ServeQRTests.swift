import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import DozerWeb

/// 606 — our own QR encoder (`WebQR`): the standard's own vectors, and every code it draws read back by an
/// independent decoder (CoreImage's), at each level and across the lengths an invite link has.
final class ServeQRTests: XCTestCase {
    /// ISO/IEC 18004 annex I: "01234567" at 1-M — its 16 data codewords give these 10 error-correction codewords.
    func testReedSolomonMatchesTheStandardsExample() {
        let data: [UInt8] = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
        XCTAssertEqual(WebQR.reedSolomon(data, ecc: 10), [196, 35, 39, 119, 235, 215, 231, 226, 93, 23])
    }

    func testFormatAndVersionInformationMatchTheStandardsTables() {
        XCTAssertEqual(WebQR.formatBits(level: .medium, mask: 0), 0b101010000010010)
        XCTAssertEqual(WebQR.formatBits(level: .low, mask: 0), 0b111011111000100)
        XCTAssertEqual(WebQR.versionBits(7), 0x07C94)
        XCTAssertEqual(WebQR.versionBits(8), 0x085BC)
        XCTAssertEqual(WebQR.versionBits(9), 0x09A99)
        XCTAssertEqual(WebQR.versionBits(10), 0x0A4D3)
        // The 32 format words are distinct.
        let all = WebQR.Level.allCases.flatMap { l in (0..<8).map { WebQR.formatBits(level: l, mask: $0) } }
        XCTAssertEqual(Set(all).count, 32)
    }

    func testAlignmentPatternPositions() {
        XCTAssertEqual(WebQR.alignmentPositions(1), [])
        XCTAssertEqual(WebQR.alignmentPositions(2), [6, 18])
        XCTAssertEqual(WebQR.alignmentPositions(6), [6, 34])
        XCTAssertEqual(WebQR.alignmentPositions(7), [6, 22, 38])
        XCTAssertEqual(WebQR.alignmentPositions(10), [6, 28, 50])
    }

    func testTheBlockTableAddsUpToEachVersionsCodewords() {
        let total = [26, 44, 70, 100, 134, 172, 196, 242, 292, 346]
        for v in 1...10 {
            for l in WebQR.Level.allCases {
                let b = WebQR.layout(v, l)
                XCTAssertEqual(b.g1 * (b.d1 + b.ecc) + b.g2 * (b.d2 + b.ecc), total[v - 1], "v\(v) \(l)")
            }
        }
    }

    func testEveryCodeDecodesToWhatWasEncoded() throws {
        let base = Array("https://doz.home.example:8443/#cap=QX3esil2CGFwAbcdEFGH-_0123456789xyzXYZ")
        var decoded = 0
        for len in [1, 7, 17, 25, 40, 63, 78, 100, 120, 150, 180, 210] {
            for level in WebQR.Level.allCases {
                let text = String((0..<len).map { base[$0 % base.count] })
                guard let qr = try? WebQR.encode(text, level: level) else {
                    XCTAssertGreaterThan(len * 8 + 20, WebQR.dataCapacityBits(10, level), "\(len) fits version 10 \(level)")
                    continue
                }
                XCTAssertEqual(qr.size, 17 + 4 * qr.version)
                XCTAssertEqual(try decode(qr), text, "v\(qr.version) \(level) mask \(qr.mask) — \(len) bytes")
                decoded += 1
            }
        }
        XCTAssertGreaterThan(decoded, 40)
    }

    func testAnInviteLinkFitsAtLevelMAndTheMatrixRoundTripsAsRows() throws {
        let link = "http://m1max.local:7443/#cap=" + String(repeating: "A", count: 43)
        let qr = try WebQR.encode(link)
        XCTAssertEqual(qr.level, .medium)
        XCTAssertLessThanOrEqual(qr.version, 6)
        let back = try XCTUnwrap(WebQR(rows: qr.rows))
        XCTAssertEqual(back.modules, qr.modules)
        XCTAssertNil(WebQR(rows: ["101", "010"]), "not a QR size")
        // On a terminal: two module rows a line, the quiet zone included.
        let text = qr.terminalText(ansi: false)
        XCTAssertEqual(text.split(separator: "\n").count, (qr.size + 8 + 1) / 2)
    }

    func testTooLongIsRefused() {
        XCTAssertThrowsError(try WebQR.encode(String(repeating: "x", count: 400)))
    }

    /// Render the matrix (6 px a module, the quiet zone) and read it with CoreImage.
    func decode(_ q: WebQR) throws -> String? {
        let scale = 6, n = (q.size + 8) * scale
        var px = [UInt8](repeating: 255, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let mx = x / scale - 4, my = y / scale - 4
                if (0..<q.size).contains(mx), (0..<q.size).contains(my), q.isDark(x: mx, y: my) { px[y * n + x] = 0 }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(px) as CFData))
        let img = try XCTUnwrap(CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let det = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        return (det.features(in: CIImage(cgImage: img)).first as? CIQRCodeFeature)?.messageString
    }
}

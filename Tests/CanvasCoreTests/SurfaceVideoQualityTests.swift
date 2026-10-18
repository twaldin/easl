import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
#if SURFACE_QUALITY_PROBE
import CanvasCore
#else
import Testing
@testable import CanvasCore
#endif

private enum BrowserQuality {
    struct Manifest: Codable {
        let pages: [Page]
    }

    struct Page: Codable {
        let id: String
        let sourceURL: String
        let resolvedURL: String
        let title: String
        let renderer: String
        let caretProvenance: String
        let width: Int
        let height: Int
        let off: String
        let on: String
        let offSHA256: String
        let onSHA256: String
    }

    struct Score: Codable {
        let maximum: Int
        let mean: Double
        let rgbaMaximum: Int
        let rgbaMean: Double
        var passes: Bool { maximum <= 8 && mean <= 1 }
    }

    struct Frame: Codable {
        let checkpoint: String
        let format: String
        let bytes: Int
        let encodedWidth: Int
        let encodedHeight: Int
        let refresh: Bool
        let packetMagic: String
        let keyframe: Bool
        let profileIDC: Int
        let constraintFlags: Int
        let levelIDC: Int
        let score: Score
    }

    struct Result: Codable {
        let id: String
        let provenance: Page?
        let width: Int
        let height: Int
        let qualityGated: Bool
        let caretTransitions: Int
        var frames: [Frame] = []
        var exceptions: [String] = []
        var passed: Bool {
            let checkpoints = frames.filter { $0.checkpoint != "initial" }
            return exceptions.isEmpty && frames.count == caretTransitions + 2
                && (!qualityGated || checkpoints.count == caretTransitions + 1 && checkpoints.allSatisfy { $0.score.passes })
        }
    }

    enum Failure: Error { case invalid(String) }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure.invalid(message) }
        return value
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.invalid(message) }
    }

    static func raster(_ image: CGImage, width: Int? = nil, height: Int? = nil) throws -> [UInt8] {
        let width = width ?? image.width, height = height ?? image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try require(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue), "sRGB context")
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    static func score(_ actual: CGImage, _ expected: [UInt8], width: Int, height: Int, initial: Bool) throws -> Score {
        try check(initial || actual.width == width && actual.height == height, "Decoder changed actual tile dimensions")
        let pixels = try raster(actual, width: width, height: height)
        try check(pixels.count == expected.count, "Raster size mismatch")
        var maximum = 0, total: UInt64 = 0, rgbaMaximum = 0, rgbaTotal: UInt64 = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<4 {
                let error = abs(Int(pixels[offset + channel]) - Int(expected[offset + channel]))
                rgbaMaximum = max(rgbaMaximum, error)
                rgbaTotal += UInt64(error)
                if channel < 3 {
                    maximum = max(maximum, error)
                    total += UInt64(error)
                }
            }
        }
        return Score(maximum: maximum, mean: Double(total) / Double(width * height * 3),
                     rgbaMaximum: rgbaMaximum, rgbaMean: Double(rgbaTotal) / Double(pixels.count))
    }

    static func load(_ file: String, hash: String, root: URL, width: Int, height: Int) throws -> CGImage {
        try check(!file.contains("/") && file.hasSuffix(".png"), "Fixture must be a PNG basename")
        let url = root.appendingPathComponent(file)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try check(size > 0 && size <= 4 * 1024 * 1024, "PNG exceeds 4 MiB fixture bound")
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try check(digest == hash, "Fixture SHA256 mismatch for \(file)")
        let source = try require(CGImageSourceCreateWithData(data as CFData, nil), "PNG source")
        let image = try require(CGImageSourceCreateImageAtIndex(source, 0, nil), "PNG image")
        try check(image.width == width && image.height == height, "Fixture is not actual tile size")
        return image
    }

    static func frame(_ encoded: SurfaceImageEncoding, checkpoint: String, decoder: SurfaceVideoDecoder,
                      expected: [UInt8], width: Int, height: Int) throws -> Frame {
        try check(encoded.format == .h264, "Video capture returned non-H264 data")
        let packet = encoded.data
        try check(packet.count >= 14 && packet[0] == 69 && packet[1] == 83
                  && packet[2] == 86 && packet[3] == 49, "Missing ESV1 packet")
        let decoded = try SurfaceImageDecoder.decode(encoded.data, format: encoded.format,
            width: encoded.width, height: encoded.height, canvas: encoded.canvas,
            video: decoder, refinement: encoded.refresh)
        return Frame(checkpoint: checkpoint, format: encoded.format.rawValue, bytes: packet.count,
            encodedWidth: encoded.width, encodedHeight: encoded.height,
            refresh: encoded.refresh, packetMagic: "ESV1", keyframe: packet[4] == 1,
            profileIDC: Int(packet[11]), constraintFlags: Int(packet[12]), levelIDC: Int(packet[13]),
            score: try score(decoded, expected, width: width, height: height, initial: checkpoint == "initial"))
    }

    static func run(id: String, page: Page?, off: CGImage, on: CGImage, gated: Bool, caretTransitions: Int) -> Result {
        var result = Result(id: id, provenance: page, width: off.width, height: off.height,
                            qualityGated: gated, caretTransitions: caretTransitions)
        do {
            let offPixels = try raster(off), onPixels = try raster(on)
            var changedPixels = 0
            for offset in stride(from: 0, to: offPixels.count, by: 4) {
                if (0..<4).contains(where: { offPixels[offset + $0] != onPixels[offset + $0] }) { changedPixels += 1 }
            }
            try check(changedPixels > 0 && changedPixels < off.width * off.height / 100,
                      "Caret pair must differ by less than the cumulative 1% rearm threshold")
            let encoder = SurfaceImageEncoder(), decoder = SurfaceVideoDecoder(), revision = SurfaceInputRevision()
            func capture(_ image: CGImage, at time: Double) throws -> SurfaceImageEncoding? {
                try encoder.capture(image, width: image.width, height: image.height, mode: .video,
                    inputActive: false, lastInput: 0, forceState: false, revision: revision, at: time)
            }
            let first = try require(capture(off, at: 0), "Missing initial video frame")
            result.frames.append(try frame(first, checkpoint: "initial", decoder: decoder,
                                           expected: offPixels, width: off.width, height: off.height))
            var sharp: SurfaceImageEncoding?
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while sharp == nil && ProcessInfo.processInfo.systemUptime < deadline {
                if let encoded = try capture(off, at: 1.1) {
                    try check(encoded.refresh, "Unexpected motion while waiting for settle")
                    sharp = encoded
                } else {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            let refresh = try require(sharp, "Missing settled H264 refresh within 15 seconds")
            try check(refresh.data.count <= SurfaceImageEncoder.refinementBytes, "Refresh exceeds transport byte bound")
            result.frames.append(try frame(refresh, checkpoint: "settled", decoder: decoder,
                                           expected: offPixels, width: off.width, height: off.height))
            encoder.acknowledgeRefinement()
            for index in 1...caretTransitions {
                let image = index.isMultiple(of: 2) ? off : on
                // Browser blink pixels change without input, so the input revision and settle epoch stay fixed.
                let motion = try require(capture(image, at: 1.1 + Double(index) * 0.5), "Missing caret frame \(index)")
                try check(!motion.refresh, "Caret blink artificially rearmed sharp refresh")
                let row = try frame(motion, checkpoint: "caret-\(index)", decoder: decoder,
                    expected: index.isMultiple(of: 2) ? offPixels : onPixels, width: off.width, height: off.height)
                result.frames.append(row)
                if row.keyframe {
                    result.exceptions.append("Caret frame \(index) lost the continuing sharp prediction reference")
                }
            }
            try check(try capture(off, at: 2.1 + Double(caretTransitions) * 0.5) == nil, "Quiet caret sequence rearmed another refresh")
        } catch {
            result.exceptions.append(String(describing: error))
        }
        return result
    }

    static func saturated(caret: Bool) throws -> CGImage {
        let width = 128, height = 96
        let colors: [[UInt8]] = [[255, 0, 0], [0, 0, 255], [0, 255, 0], [255, 0, 255], [0, 255, 255], [255, 255, 255]]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = colors[(x + y * 3) % colors.count][channel] }
            }
        }
        if caret {
            for y in 80..<90 {
                for channel in 0..<3 { pixels[(y * width + 120) * 4 + channel] = 0 }
            }
        }
        let provider = try require(CGDataProvider(data: Data(pixels) as CFData), "Saturated fixture provider")
        return try require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent), "Saturated fixture")
    }

    static func reports(root: URL) throws -> [Result] {
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        try check(manifestData.count <= 64 * 1024, "Manifest exceeds 64 KiB")
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        try check(manifest.pages.map(\.id).sorted() == ["dense-table", "docs", "github-file"], "All three real pages are required")
        var results: [Result] = []
        for page in manifest.pages {
            try check(page.width == 1800 && page.height == 1324, "Use actual 900x662 tile at scale 2")
            try check(URL(string: page.sourceURL)?.scheme == "https" && URL(string: page.resolvedURL)?.scheme == "https",
                      "Real-page source provenance must contain HTTPS URLs")
            try check(!page.title.isEmpty && !page.renderer.isEmpty && !page.caretProvenance.isEmpty, "Missing capture provenance")
            let off = try load(page.off, hash: page.offSHA256, root: root, width: page.width, height: page.height)
            let on = try load(page.on, hash: page.onSHA256, root: root, width: page.width, height: page.height)
            results.append(run(id: page.id, page: page, off: off, on: on, gated: true,
                               caretTransitions: page.id == "docs" ? 200 : 30))
        }
        results.append(run(id: "saturated-128x96-report-only", page: nil,
                           off: try saturated(caret: false), on: try saturated(caret: true), gated: false, caretTransitions: 30))
        return results
    }

    static func json(_ results: [Result]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(results)
    }
}

#if SURFACE_QUALITY_PROBE
@main private struct SurfaceVideoQualityProbe {
    static func main() {
        do {
            try BrowserQuality.check(CommandLine.arguments.count == 3, "Usage: quality-probe FIXTURE_DIRECTORY REPORT_JSON")
            let results = try BrowserQuality.reports(root: URL(fileURLWithPath: CommandLine.arguments[1]))
            let data = try BrowserQuality.json(results)
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
            exit(results.filter(\.qualityGated).allSatisfy(\.passed) ? 0 : 2)
        } catch {
            let report = ["exception": String(describing: error), "passed": "false"]
            if CommandLine.arguments.count == 3,
               let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
            }
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
#else
@Suite(.serialized)
struct SurfaceVideoQualityTests {
    @Test func realBrowserPagesRetainSharpReferenceThroughTwoHundredDocsCaretTransitions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/browser-quality")
        let results = try BrowserQuality.reports(root: root)
        print(String(decoding: try BrowserQuality.json(results), as: UTF8.self))
        for result in results where result.qualityGated {
            #expect(result.exceptions.isEmpty, "\(result.id): \(result.exceptions)")
            #expect(result.frames.count == result.caretTransitions + 2,
                    "\(result.id) must decode initial, settled, and \(result.caretTransitions) caret frames")
            for frame in result.frames where frame.checkpoint != "initial" {
                #expect(frame.score.maximum <= 8, "\(result.id) \(frame.checkpoint) full-image RGB maximum")
                #expect(frame.score.mean <= 1, "\(result.id) \(frame.checkpoint) full-image RGB mean")
            }
        }
    }
}
#endif

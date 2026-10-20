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

        var qualityCheckpoint: Bool { checkpoint != "initial" && checkpoint != "motion-return" }
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
            let checkpoints = frames.filter(\.qualityCheckpoint)
            return exceptions.isEmpty && frames.count == caretTransitions + 4
                && (!qualityGated || checkpoints.count == caretTransitions + 2 && checkpoints.allSatisfy { $0.score.passes })
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
            score: try score(decoded, expected, width: width, height: height,
                             initial: checkpoint == "initial" || checkpoint == "motion-return"))
    }

    static func scrolled(_ image: CGImage) throws -> CGImage {
        let context = try require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            "Scrolled fixture context")
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: -min(32, image.height / 4), width: image.width, height: image.height))
        return try require(context.makeImage(), "Scrolled fixture")
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
            func capture(_ image: CGImage, at time: Double, inputActive: Bool = false,
                         lastInput: Double = 0) throws -> SurfaceImageEncoding? {
                let fitted = SurfaceEvent.Frame.fittedPixels(width: image.width, height: image.height, ratio: 1, format: .h264)
                return try encoder.capture(image, width: fitted.width, height: fitted.height, mode: .video,
                    inputActive: inputActive, lastInput: lastInput, forceState: false, revision: revision, at: time)
            }
            func settled(_ image: CGImage, at time: Double, lastInput: Double = 0) throws -> SurfaceImageEncoding {
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if let encoded = try capture(image, at: time, lastInput: lastInput) {
                        try check(encoded.refresh, "Unexpected motion while waiting for settle")
                        try check(encoded.data.count <= SurfaceImageEncoder.refinementBytes,
                                  "Refresh exceeds transport byte bound")
                        return encoded
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                throw Failure.invalid("Missing settled H264 refresh within 15 seconds")
            }
            let first = try require(capture(off, at: 0), "Missing initial video frame")
            result.frames.append(try frame(first, checkpoint: "initial", decoder: decoder,
                                           expected: offPixels, width: off.width, height: off.height))
            encoder.acknowledgeFrame()
            let refresh = try settled(off, at: 1.1)
            result.frames.append(try frame(refresh, checkpoint: "settled", decoder: decoder,
                                           expected: offPixels, width: off.width, height: off.height))
            encoder.acknowledgeFrame()
            for index in 1...caretTransitions {
                let image = index.isMultiple(of: 2) ? off : on
                let encoded = try require(capture(image, at: 1.1 + Double(index) * 0.5), "Missing caret frame \(index)")
                let row = try frame(encoded, checkpoint: "caret-\(index)", decoder: decoder,
                    expected: index.isMultiple(of: 2) ? offPixels : onPixels, width: off.width, height: off.height)
                result.frames.append(row)
                encoder.acknowledgeFrame()
                if encoded.refresh {
                    try check(encoded.data.count <= SurfaceImageEncoder.refinementBytes, "Sharp frame exceeds refresh transport bound")
                }
            }
            try check(try capture(off, at: 2.1 + Double(caretTransitions) * 0.5) == nil, "Quiet caret sequence rearmed another refresh")
            let moving = try scrolled(off), movingPixels = try raster(moving)
            let motionAt = 3.1 + Double(caretTransitions) * 0.5
            revision.advance()
            let motion = try require(capture(moving, at: motionAt, inputActive: true, lastInput: motionAt),
                                     "Missing motion return after acknowledged caret frames")
            try check(!motion.refresh && motion.data[4] == 1, "Input must return to independent motion")
            try check(motion.data.count <= 48 * 1024, "Motion return exceeds transport byte bound")
            result.frames.append(try frame(motion, checkpoint: "motion-return", decoder: decoder,
                                           expected: movingPixels, width: moving.width, height: moving.height))
            encoder.acknowledgeFrame()
            let returned = try settled(moving, at: motionAt + 1.1, lastInput: motionAt)
            try check(returned.data[4] == 0, "Acknowledged native reference was not reused after motion")
            result.frames.append(try frame(returned, checkpoint: "settled-return", decoder: decoder,
                                           expected: movingPixels, width: moving.width, height: moving.height))
            encoder.acknowledgeFrame()
            try check(try capture(moving, at: motionAt + 2.1, lastInput: motionAt) == nil,
                      "Unchanged pixels emitted another frame after motion return")
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
            if page.id == "docs" {
                let bounds = CGRect(x: 0, y: 0, width: page.width - 1, height: page.height - 1)
                let oddOff = try require(off.cropping(to: bounds), "Odd documentation viewport")
                let oddOn = try require(on.cropping(to: bounds), "Odd documentation caret viewport")
                results.append(run(id: "docs-odd-viewport", page: page, off: oddOff, on: oddOn, gated: true, caretTransitions: 30))
            }
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

#if !SURFACE_QUALITY_PROBE
@Suite(.serialized)
struct SurfaceVideoQualityTests {
    @Test func realBrowserPagesRetainSharpQualityThroughCaretTransitionsAndMotionReturn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/browser-quality")
        let results = try BrowserQuality.reports(root: root)
        print(String(decoding: try BrowserQuality.json(results), as: UTF8.self))
        for result in results where result.qualityGated {
            #expect(result.exceptions.isEmpty, "\(result.id): \(result.exceptions)")
            #expect(result.frames.count == result.caretTransitions + 4,
                    "\(result.id) must decode initial, settled, \(result.caretTransitions) caret frames, motion return, and resettled pixels")
            for frame in result.frames where frame.qualityCheckpoint {
                #expect(frame.score.maximum <= 8, "\(result.id) \(frame.checkpoint) full-image RGB maximum")
                #expect(frame.score.mean <= 1, "\(result.id) \(frame.checkpoint) full-image RGB mean")
            }
        }
    }
}
#endif

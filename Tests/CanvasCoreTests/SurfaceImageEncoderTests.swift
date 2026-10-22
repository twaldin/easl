import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import CanvasCore

@SurfaceHardwareCodec
struct SurfaceImageEncoderTests {
    private final class RefreshQueue {
        let queue = DispatchQueue(label: "easl.tests.surface.refresh")
        private var suspended = false

        func pause() {
            queue.suspend()
            suspended = true
        }

        func finish() {
            if suspended {
                queue.resume()
                suspended = false
            }
            queue.sync {}
        }

        deinit { if suspended { queue.resume() } }
    }

    private struct Fixture {
        let image: CGImage
        let pixels: [UInt8]
    }

    private func fixture(width: Int = 129, height: Int = 97, redLeftHalf: Bool = false,
                         shift: Int = 0, noise: Bool = false, marker: Int? = nil,
                         filledPixels: Int = 0) throws -> Fixture {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let colors: [[UInt8]] = [[0, 0, 0], [255, 0, 0], [0, 0, 255], [0, 255, 0]]
        var random: UInt32 = 0x12345678
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    if noise {
                        random = random &* 1664525 &+ 1013904223
                        pixels[offset + channel] = UInt8(truncatingIfNeeded: random >> 24)
                    } else if (y + shift) % 13 < 8 && (x + shift) % 7 < 3 {
                        pixels[offset + channel] = colors[(x / 7 + y / 13 + shift) % colors.count][channel]
                    }
                }
                if redLeftHalf && x < width / 2 {
                    pixels[offset] = 255
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                }
            }
        }
        for pixel in 0..<filledPixels {
            pixels[pixel * 4] = 31
            pixels[pixel * 4 + 1] = 63
            pixels[pixel * 4 + 2] = 127
        }
        if let marker {
            let offset = (width * (height / 2) + marker % width) * 4
            pixels[offset] = 31
            pixels[offset + 1] = 63
            pixels[offset + 2] = 127
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return Fixture(image: image, pixels: pixels)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }

    private func realFixture(_ name: String) throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/browser-quality/" + name)
        let data = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(data, 0, nil))
        return Fixture(image: image, pixels: try pixels(image))
    }

    private func capture(_ encoder: SurfaceImageEncoder, _ source: Fixture, at time: TimeInterval,
                         revision: SurfaceInputRevision, mode: SurfaceLinkMode = .video,
                         input: Bool = false, lastInput: TimeInterval = 0,
                         forceState: Bool = false) throws -> SurfaceImageEncoding? {
        try encoder.capture(source.image, width: source.image.width, height: source.image.height, mode: mode,
            inputActive: input, lastInput: lastInput, forceState: forceState,
            revision: revision, at: time)
    }

    private func decode(_ frame: SurfaceImageEncoding, video: SurfaceVideoDecoder = SurfaceVideoDecoder()) throws -> CGImage {
        try SurfaceImageDecoder.decode(frame.data, format: frame.format, width: frame.width, height: frame.height,
            canvas: frame.canvas, video: video, refinement: frame.refresh)
    }

    @discardableResult
    private func expectSharp(_ frame: SurfaceImageEncoding, source: Fixture,
                             video: SurfaceVideoDecoder = SurfaceVideoDecoder()) throws -> (maximum: Int, mean: Double) {
        #expect(frame.format == .h264)
        #expect(frame.refresh)
        #expect(frame.data.count <= 576 * 1024)
        #expect(Array(frame.data.prefix(6)) == [69, 83, 86, 49, 1, 4])
        #expect(frame.width == max(16, (source.image.width + 1) / 2 * 2))
        #expect(frame.height == max(16, (source.image.height + 1) / 2 * 2))
        let image = try decode(frame, video: video)
        #expect(image.width == source.image.width && image.height == source.image.height)
        let actual = try pixels(image)
        #expect(actual.count == source.pixels.count)
        var maximum = 0, total: UInt64 = 0
        for index in actual.indices where index % 4 != 3 {
            let error = abs(Int(actual[index]) - Int(source.pixels[index]))
            maximum = max(maximum, error)
            total += UInt64(error)
        }
        let mean = Double(total) / Double(actual.count / 4 * 3)
        print("Sharp RGB report max=\(maximum) mean=\(mean)")
        return (maximum, mean)
    }

    @Test func jpegPreservesTheOddCanvasAndInputPixelsWithoutIdleRefinement() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        let first = try #require(try capture(encoder, source, at: 0, revision: revision, mode: .jpeg))
        #expect(first.format == .jpeg && !first.refresh)
        #expect(first.width == 129 && first.height == 97)
        #expect(try capture(encoder, source, at: 1, revision: revision, mode: .jpeg) == nil)
        let state = try #require(try capture(encoder, source, at: 1.1, revision: revision, mode: .jpeg, forceState: true))
        #expect(state.format == .jpeg && !state.refresh && state.canvas == CGSize(width: 129, height: 97))
        let changed = try fixture(redLeftHalf: true)
        let motion = try #require(try capture(encoder, changed, at: 2, revision: revision, mode: .jpeg, input: true))
        #expect(motion.format == .jpeg && !motion.refresh)
        let visible = try pixels(decode(motion))
        #expect(visible[0] >= 240 && visible[1] <= 15 && visible[2] <= 15)
        work.finish()
        for time in [2.1, 3, 30] {
            #expect(try capture(encoder, changed, at: time, revision: revision, mode: .jpeg) == nil)
        }
    }

    @Test func probingKeepsTheLowLatencyMotionPathUntilTheLinkIsMeasured() throws {
        let work = RefreshQueue()
        work.pause()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        let video = SurfaceVideoDecoder()
        let first = try #require(try capture(encoder, source, at: 0, revision: revision, mode: .probing))
        #expect(first.format == .h264 && !first.refresh)
        _ = try decode(first, video: video)
        #expect(try capture(encoder, source, at: 1, revision: revision, mode: .probing) == nil)
        let state = try #require(try capture(encoder, source, at: 2, revision: revision,
                                           mode: .probing, forceState: true))
        #expect(!state.refresh && state.data[4] == 0)
        #expect(try decode(state, video: video).width == state.width)
        #expect(try capture(encoder, source, at: 3, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, source, at: 3.1, revision: revision))
        try expectSharp(sharp, source: source)
    }

    @Test func settledRefreshReplacesTheOddCanvasOnceAndBecomesTheLiveReference() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        let video = SurfaceVideoDecoder()
        let motion = try #require(try capture(encoder, source, at: 0, revision: revision))
        #expect(motion.format == .h264 && !motion.refresh)
        _ = try decode(motion, video: video)
        #expect(try capture(encoder, source, at: 0.99, revision: revision) == nil)
        #expect(try capture(encoder, source, at: 1, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, source, at: 1.1, revision: revision))
        #expect(sharp.canvas == CGSize(width: 129, height: 97))
        try expectSharp(sharp, source: source, video: video)
        for time in [1.2, 1.5, 100] {
            #expect(try capture(encoder, source, at: time, revision: revision) == nil)
        }
        let changed = try fixture(redLeftHalf: true)
        let predicted = try #require(try capture(encoder, changed, at: 100.1, revision: revision))
        #expect(predicted.format == .h264 && !predicted.refresh)
        #expect(predicted.data[4] == 0)
        #expect(predicted.width == 130 && predicted.height == 98)
        #expect(throws: (any Error).self) { try decode(predicted) }
        let visible = try pixels(decode(predicted, video: video))
        #expect(visible[0] > visible[1] && visible[0] > visible[2])
    }

    @Test func negotiatedPerStreamSizingDefinesTheNativeSharpCanvas() throws {
        let source = try fixture(width: 258, height: 194, redLeftHalf: true)
        let context = try #require(CGContext(data: nil, width: 129, height: 97, bitsPerComponent: 8,
            bytesPerRow: 129 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .high
        context.draw(source.image, in: CGRect(x: 0, y: 0, width: 129, height: 97))
        let normalized = try #require(context.makeImage())
        let expected = Fixture(image: normalized, pixels: try pixels(normalized))
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        func sizedCapture(at time: TimeInterval) throws -> SurfaceImageEncoding? {
            try encoder.capture(source.image, width: 129, height: 97, mode: .video,
                inputActive: false, lastInput: 0, forceState: false,
                revision: revision, at: time)
        }
        let motion = try #require(try sizedCapture(at: 0))
        #expect(motion.canvas == CGSize(width: 129, height: 97) && !motion.refresh)
        #expect(try sizedCapture(at: 1) == nil)
        work.finish()
        let sharp = try #require(try sizedCapture(at: 1.1))
        #expect(sharp.width == 130 && sharp.height == 98)
        try expectSharp(sharp, source: expected)
    }

    @Test func pendingRefreshInputCancellationDoesNotBlockMotionOrLoseTheNewSettledVersion() throws {
        let work = RefreshQueue()
        work.pause()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let video = SurfaceVideoDecoder()
        let original = try fixture()
        let first = try #require(try capture(encoder, original, at: 0, revision: revision))
        _ = try decode(first, video: video)
        #expect(try capture(encoder, original, at: 1, revision: revision) == nil)
        revision.advance()
        let changed = try fixture(redLeftHalf: true)
        let motion = try #require(try capture(encoder, changed, at: 1.1, revision: revision, input: true, lastInput: 1.1))
        #expect(!motion.refresh && motion.data.count <= 48 * 1024)
        #expect(motion.data[4] == 1)
        let visible = try pixels(decode(motion, video: video))
        #expect(visible[0] >= 220 && visible[1] <= 30 && visible[2] <= 30)
        #expect(try capture(encoder, changed, at: 2.09, revision: revision, lastInput: 1.1) == nil)
        #expect(try capture(encoder, changed, at: 2.11, revision: revision, lastInput: 1.1) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, changed, at: 2.2, revision: revision, lastInput: 1.1))
        try expectSharp(sharp, source: changed)
        #expect(try capture(encoder, changed, at: 10, revision: revision, lastInput: 1.1) == nil)
    }

    @Test func aReadyRefreshCannotCrossANewerLargeChange() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let original = try fixture()
        _ = try #require(try capture(encoder, original, at: 0, revision: revision))
        #expect(try capture(encoder, original, at: 1, revision: revision) == nil)
        work.finish()
        let changed = try fixture(shift: 1)
        let motion = try #require(try capture(encoder, changed, at: 1.2, revision: revision))
        #expect(motion.format == .h264 && !motion.refresh)
        #expect(try capture(encoder, changed, at: 2.21, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, changed, at: 2.3, revision: revision))
        try expectSharp(sharp, source: changed)
    }

    @Test func aReadyRefreshIsCanceledByInputEvenWhenThePixelsDoNotChange() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        _ = try #require(try capture(encoder, source, at: 0, revision: revision))
        #expect(try capture(encoder, source, at: 1, revision: revision) == nil)
        work.finish()
        revision.advance()
        let recovery = try #require(try capture(encoder, source, at: 1.1, revision: revision, lastInput: 1.1))
        #expect(recovery.format == .h264 && !recovery.refresh && recovery.data[4] == 1)
        let recovered = try decode(recovery)
        #expect(recovered.width == recovery.width && recovered.height == recovery.height)
        #expect(try capture(encoder, source, at: 2.11, revision: revision, lastInput: 1.1) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, source, at: 2.2, revision: revision, lastInput: 1.1))
        try expectSharp(sharp, source: source)
    }

    @Test(arguments: [false, true])
    func cancelingATransferredReferenceRecoversWhetherOrNotItWasDecoded(decoded: Bool) throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let video = SurfaceVideoDecoder()
        let source = try fixture()
        let first = try #require(try capture(encoder, source, at: 0, revision: revision))
        _ = try decode(first, video: video)
        #expect(try capture(encoder, source, at: 1, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, source, at: 1.1, revision: revision))
        #expect(sharp.refresh && sharp.format == .h264)
        if decoded { try expectSharp(sharp, source: source, video: video) }
        revision.advance()
        let changed = try fixture(redLeftHalf: true)
        let recovered = try #require(try capture(encoder, changed, at: 1.2, revision: revision,
                                               input: true, lastInput: 1.2))
        #expect(!recovered.refresh && recovered.data[4] == 1)
        for consumer in [video, SurfaceVideoDecoder()] {
            let visible = try pixels(decode(recovered, video: consumer))
            #expect(visible[0] > visible[1] && visible[0] > visible[2])
        }
    }

    @Test func acknowledgedSharpReferenceRemainsPredictiveWhenInputResumes() throws {
        // Keep the prediction-only fixture independent of the full runner's codec lifetime.
        if try runIsolatedTestIfParallelNow("acknowledgedSharpReferenceRemainsPredictiveWhenInputResumes") { return }
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let decoder = SurfaceVideoDecoder()
        let original = try fixture()
        let first = try #require(try capture(encoder, original, at: 0, revision: revision))
        _ = try decode(first, video: decoder)
        #expect(try capture(encoder, original, at: 1, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, original, at: 1.1, revision: revision))
        try expectSharp(sharp, source: original, video: decoder)
        encoder.acknowledgeRefinement()
        revision.advance()
        let changed = try fixture(marker: 7)
        let motion = try #require(try capture(encoder, changed, at: 1.2, revision: revision, input: true, lastInput: 1.2))
        #expect(!motion.refresh && motion.data[4] == 0)
        #expect(throws: (any Error).self) { try decode(motion) }
        let actual = try pixels(decode(motion, video: decoder))
        let marker = (97 / 2 * 129 + 7) * 4
        #expect(Int(actual[marker + 2]) - Int(actual[marker]) > 40)
    }

    @Test func largeInputAfterSharpRestartsIndependentMotionAndSettlesAgain() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let decoder = SurfaceVideoDecoder()
        let original = try realFixture("docs-caret-off.png")
        let first = try #require(try capture(encoder, original, at: 0, revision: revision))
        _ = try decode(first, video: decoder)
        #expect(try capture(encoder, original, at: 1, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, original, at: 1.1, revision: revision))
        _ = try decode(sharp, video: decoder)
        encoder.acknowledgeRefinement()
        revision.advance()
        let changed = try realFixture("dense-table-caret-off.png")
        let motion = try #require(try capture(encoder, changed, at: 1.2, revision: revision, input: true, lastInput: 1.2))
        #expect(!motion.refresh && motion.data[4] == 1)
        for video in [decoder, SurfaceVideoDecoder()] {
            let visible = try decode(motion, video: video)
            #expect(visible.width == motion.width && visible.height == motion.height)
        }
        #expect(try capture(encoder, changed, at: 2.3, revision: revision, lastInput: 1.2) == nil)
        work.finish()
        let settled = try #require(try capture(encoder, changed, at: 2.4, revision: revision, lastInput: 1.2))
        let quality = try expectSharp(settled, source: changed, video: decoder)
        #expect(quality.maximum <= 8)
        #expect(quality.mean <= 1)
    }

    @Test func smallChangesKeepTheFrozenPendingRefreshAndFollowItsReferenceAfterDelivery() throws {
        let work = RefreshQueue()
        work.pause()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        let video = SurfaceVideoDecoder()
        let first = try #require(try capture(encoder, source, at: 0, revision: revision))
        _ = try decode(first, video: video)
        for index in 1...4 {
            let tick = try fixture(marker: index)
            let motion = try #require(try capture(encoder, tick, at: Double(index) * 0.2, revision: revision))
            #expect(motion.format == .h264 && !motion.refresh)
            _ = try decode(motion, video: video)
        }
        let snapshot = try fixture(marker: 5)
        #expect(try capture(encoder, snapshot, at: 1, revision: revision) == nil)
        for index in 6...10 {
            #expect(try capture(encoder, fixture(marker: index), at: Double(index) * 0.2, revision: revision) == nil)
        }
        work.finish()
        let current = try fixture(marker: 10)
        let sharp = try #require(try capture(encoder, current, at: 2.2, revision: revision))
        try expectSharp(sharp, source: snapshot, video: video)
        let following = try #require(try capture(encoder, current, at: 2.21, revision: revision))
        #expect(following.format == .h264 && !following.refresh && following.data[4] == 0)
        _ = try decode(following, video: video)
        for index in 12...20 {
            let tick = try fixture(marker: index)
            let motion = try #require(try capture(encoder, tick, at: Double(index) * 0.2, revision: revision))
            #expect(motion.format == .h264 && !motion.refresh && motion.data[4] == 0)
            _ = try decode(motion, video: video)
            work.finish()
        }
        #expect(try capture(encoder, fixture(marker: 20), at: 10, revision: revision) == nil)
    }

    @Test func cumulativeSmallChangesRefreshAfterQuietWithoutStarvingTheFrozenSnapshot() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        let first = try #require(try capture(encoder, source, at: 0, revision: revision))
        #expect(first.format == .h264 && !first.refresh)
        #expect(try capture(encoder, source, at: 1, revision: revision) == nil)
        work.finish()
        let initialSharp = try #require(try capture(encoder, source, at: 1.1, revision: revision))
        try expectSharp(initialSharp, source: source)

        work.pause()
        for index in 1...5 {
            let changed = try fixture(filledPixels: index * 100)
            let motion = try #require(try capture(encoder, changed, at: 1.25 + Double(index) * 0.25, revision: revision))
            #expect(motion.format == .h264 && !motion.refresh)
        }
        for index in 6...15 {
            let changed = try fixture(filledPixels: index * 100)
            #expect(try capture(encoder, changed, at: 1.25 + Double(index) * 0.25, revision: revision) == nil)
        }
        work.finish()
        let final = try fixture(filledPixels: 1500)
        let frozen = try fixture(filledPixels: 600)
        let pendingSharp = try #require(try capture(encoder, final, at: 5.25, revision: revision))
        try expectSharp(pendingSharp, source: frozen)

        let motion = try #require(try capture(encoder, final, at: 5.5, revision: revision))
        #expect(motion.format == .h264 && !motion.refresh)
        #expect(try capture(encoder, final, at: 6.49, revision: revision) == nil)
        #expect(try capture(encoder, final, at: 6.5, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, final, at: 6.75, revision: revision))
        try expectSharp(sharp, source: final)
        #expect(try capture(encoder, final, at: 10, revision: revision) == nil)
        work.finish()
        #expect(try capture(encoder, final, at: 11, revision: revision) == nil)
    }

    @Test func changesConfinedToOnePercentDoNotRepeatedlyRefresh() throws {
        // Keep the prediction-only fixture independent of the full runner's codec lifetime.
        if try runIsolatedTestIfParallelNow("changesConfinedToOnePercentDoNotRepeatedlyRefresh") { return }
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        _ = try #require(try capture(encoder, source, at: 0, revision: revision))
        #expect(try capture(encoder, source, at: 1, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, source, at: 1.1, revision: revision))
        try expectSharp(sharp, source: source)
        for index in 1...20 {
            let tick = try fixture(filledPixels: index % 2 == 0 ? 0 : 125)
            let motion = try #require(try capture(encoder, tick, at: 1.5 + Double(index) * 0.25, revision: revision))
            #expect(motion.format == .h264 && !motion.refresh)
            work.finish()
        }
        #expect(try capture(encoder, source, at: 10, revision: revision) == nil)
    }

    @Test func inputCancelsARearmedCumulativeRefreshWithoutLosingTheSharpAnchor() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        _ = try #require(try capture(encoder, source, at: 0, revision: revision))
        #expect(try capture(encoder, source, at: 1, revision: revision) == nil)
        work.finish()
        let initialSharp = try #require(try capture(encoder, source, at: 1.1, revision: revision))
        try expectSharp(initialSharp, source: source)

        work.pause()
        for index in 1...5 {
            let changed = try fixture(filledPixels: index * 100)
            let motion = try #require(try capture(encoder, changed, at: 1.25 + Double(index) * 0.25, revision: revision))
            #expect(motion.format == .h264 && !motion.refresh)
        }
        #expect(try capture(encoder, fixture(filledPixels: 600), at: 2.75, revision: revision) == nil)
        revision.advance()
        let current = try fixture(filledPixels: 700)
        let motion = try #require(try capture(encoder, current, at: 3, revision: revision, input: true, lastInput: 3))
        #expect(motion.format == .h264 && !motion.refresh)
        #expect(try capture(encoder, current, at: 3.99, revision: revision, lastInput: 3) == nil)
        #expect(try capture(encoder, current, at: 4, revision: revision, lastInput: 3) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, current, at: 4.1, revision: revision, lastInput: 3))
        try expectSharp(sharp, source: current)
        #expect(try capture(encoder, current, at: 10, revision: revision, lastInput: 3) == nil)
    }

    @Test(arguments: [0.45, 0.5])
    func repeatingLargeChangesDoNotProduceRefreshStorms(interval: TimeInterval) throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let sources = try [fixture(), fixture(redLeftHalf: true)]
        var final = sources[0]
        var lastChange: TimeInterval = 0
        for index in 0..<10 {
            final = sources[index % 2]
            lastChange = Double(index) * interval
            let motion = try #require(try capture(encoder, final, at: lastChange, revision: revision))
            #expect(motion.format == .h264 && !motion.refresh)
            #expect(motion.data.count <= 48 * 1024)
            #expect(try capture(encoder, final, at: lastChange + 0.35, revision: revision) == nil)
            work.finish()
        }
        #expect(try capture(encoder, final, at: lastChange + 0.99, revision: revision) == nil)
        #expect(try capture(encoder, final, at: lastChange + 1.01, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, final, at: lastChange + 1.1, revision: revision))
        try expectSharp(sharp, source: final)
        #expect(try capture(encoder, final, at: 100, revision: revision) == nil)
    }

    @Test func switchingToJpegDiscardsQueuedRefreshAndVideoCanSettleAgain() throws {
        let work = RefreshQueue()
        work.pause()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let source = try fixture()
        _ = try #require(try capture(encoder, source, at: 0, revision: revision))
        #expect(try capture(encoder, source, at: 1, revision: revision) == nil)
        let jpeg = try #require(try capture(encoder, source, at: 1.1, revision: revision, mode: .jpeg))
        #expect(jpeg.format == .jpeg && !jpeg.refresh)
        work.finish()
        #expect(try capture(encoder, source, at: 10, revision: revision, mode: .jpeg) == nil)
        let motion = try #require(try capture(encoder, source, at: 10.1, revision: revision))
        #expect(motion.format == .h264 && !motion.refresh)
        #expect(try capture(encoder, source, at: 11.11, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, source, at: 11.2, revision: revision))
        try expectSharp(sharp, source: source)
    }

    @Test func anOverBudgetReferenceIsRefusedWithoutShrinkingAndTheNextMotionRecovers() throws {
        let work = RefreshQueue()
        let encoder = SurfaceImageEncoder(refreshQueue: work.queue)
        let revision = SurfaceInputRevision()
        let changed = try realFixture("docs-caret-off.png")
        let docs = changed.image
        let entropy = try fixture(width: docs.width, height: docs.height, noise: true)
        let motion = try #require(try capture(encoder, entropy, at: 0, revision: revision))
        #expect(motion.format == .h264 && !motion.refresh && motion.data.count <= 48 * 1024)
        let image = try decode(motion)
        #expect(image.width == motion.width && image.height == motion.height)
        #expect(try capture(encoder, entropy, at: 1, revision: revision) == nil)
        work.finish()
        for time in [1.1, 2, 5] {
            #expect(try capture(encoder, entropy, at: time, revision: revision) == nil)
            work.finish()
        }
        let recovered = try #require(try capture(encoder, entropy, at: 5.1, revision: revision, forceState: true))
        #expect(recovered.format == .h264 && !recovered.refresh && recovered.data[4] == 1)
        #expect(recovered.data.count <= 48 * 1024)
        #expect(try decode(recovered).width == recovered.width)
        let next = try #require(try capture(encoder, changed, at: 7, revision: revision))
        #expect(next.format == .h264 && !next.refresh)
        #expect(try capture(encoder, changed, at: 8.01, revision: revision) == nil)
        work.finish()
        let sharp = try #require(try capture(encoder, changed, at: 8.1, revision: revision))
        let quality = try expectSharp(sharp, source: changed)
        #expect(quality.maximum <= 8)
        #expect(quality.mean <= 1)
    }
}

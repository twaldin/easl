import Foundation
import CoreGraphics
import Testing
@testable import CanvasCore

// VideoToolbox session creation can occupy every cooperative worker. These hardware-codec
// suites share one actor so unrelated Core tests can keep making progress.
@globalActor
actor SurfaceHardwareCodec {
    static let shared = SurfaceHardwareCodec()
}

@SurfaceHardwareCodec
struct SurfaceVideoTests {
    nonisolated private func image(width: Int = 64, height: Int = 64, red: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: red ? 1 : 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return try #require(context.makeImage())
    }

    private func center(_ image: CGImage) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Array(pixel.prefix(3))
    }

    @Test func encodedChangesAreVisibleAndImagesRemainImmutable() throws {
        let encoder = SurfaceVideoEncoder()
        let decoder = SurfaceVideoDecoder()
        let first = try #require(try encoder.encode(image(), width: 64, height: 64))
        let black = try decoder.decode(first.data, width: first.width, height: first.height)
        let second = try #require(try encoder.encode(image(red: true), width: 64, height: 64))
        let red = try decoder.decode(second.data, width: second.width, height: second.height)
        #expect(black.width == 64 && black.height == 64)
        let blackPixel = try center(black)
        let redPixel = try center(red)
        #expect(blackPixel.allSatisfy { $0 < 30 })
        #expect(redPixel[0] > 220 && redPixel[1] < 30 && redPixel[2] < 30)
        #expect(try center(black) == blackPixel)
    }

    @Test func nativeSharpFrameStartsTheContinuingPredictionChain() throws {
        // This fixture requires a predicted sharp successor, which VideoToolbox does not guarantee.
        if try runIsolatedTestIfParallelNow("nativeSharpFrameStartsTheContinuingPredictionChain") { return }
        let encoder = SurfaceVideoEncoder()
        let decoder = SurfaceVideoDecoder()
        let initial = try #require(try encoder.encode(image(width: 65, height: 67), width: 65, height: 67))
        _ = try decoder.decode(initial.data, width: initial.width, height: initial.height)
        let sharp = try #require(try encoder.encode(image(width: 65, height: 67), width: 65, height: 67, refresh: true))
        #expect(sharp.width == 66 && sharp.height == 68 && sharp.data[4] == 1)
        #expect(sharp.data.count <= 576 * 1024)
        let black = try decoder.decode(sharp.data, width: sharp.width, height: sharp.height)
        let originalPixel = try center(black)
        let predicted = try #require(try encoder.encode(image(width: 65, height: 67, red: true), width: 65, height: 67))
        #expect(predicted.width == 66 && predicted.height == 68 && predicted.data[4] == 0)
        #expect(predicted.data.count <= 48 * 1024)
        #expect(throws: (any Error).self) {
            try SurfaceVideoDecoder().decode(predicted.data, width: predicted.width, height: predicted.height)
        }
        let red = try decoder.decode(predicted.data, width: predicted.width, height: predicted.height)
        let redPixel = try center(red)
        #expect(redPixel[0] > redPixel[1] && redPixel[0] > redPixel[2])
        #expect(redPixel[0] > originalPixel[0])
        #expect(try center(black) == originalPixel)
    }

    @Test func budgetCappedCaptureRastersProduceVisibleSharpReferences() throws {
        for (width, height, expectedWidth, expectedHeight) in [
            (2530, 1581, 2530, 1580),
            (2560, 1600, 2528, 1580),
        ] {
            let raster = SurfaceEvent.Frame.fittedPixels(width: width, height: height, ratio: 1, format: .h264)
            let source = try image(width: raster.width, height: raster.height, red: true)
            let encoder = SurfaceVideoEncoder()
            let packet = try #require(try encoder.encode(source, width: raster.width, height: raster.height, refresh: true))
            #expect(packet.width == expectedWidth && packet.height == expectedHeight)
            #expect(packet.data.count <= 576 * 1024)
            let decoded = try SurfaceVideoDecoder().decode(packet.data, width: packet.width, height: packet.height)
            #expect(decoded.width == expectedWidth && decoded.height == expectedHeight)
            let visible = try center(decoded)
            #expect(visible[0] > visible[1] && visible[0] > visible[2])
        }
    }

    @Test func aCanceledSharpFrameCannotBecomeAnUnpublishedPredictionReference() throws {
        let encoder = SurfaceVideoEncoder()
        let decoder = SurfaceVideoDecoder()
        let initial = try #require(try encoder.encode(image(), width: 64, height: 64))
        _ = try decoder.decode(initial.data, width: initial.width, height: initial.height)
        var checks = 0
        let canceled = try encoder.encode(image(red: true), width: 64, height: 64, refresh: true, isCancelled: {
            checks += 1
            return checks >= 5
        })
        #expect(canceled == nil)
        let recovered = try #require(try encoder.encode(image(red: true), width: 64, height: 64))
        #expect(recovered.data[4] == 1)
        for consumer in [decoder, SurfaceVideoDecoder()] {
            let visible = try center(consumer.decode(recovered.data, width: recovered.width, height: recovered.height))
            #expect(visible[0] > visible[1] && visible[0] > visible[2])
        }
    }

    @Test func resizingAndNewStreamsProduceRecoverableKeyframes() throws {
        let encoder = SurfaceVideoEncoder()
        let decoder = SurfaceVideoDecoder()
        let original = try #require(try encoder.encode(image(), width: 64, height: 64))
        _ = try decoder.decode(original.data, width: original.width, height: original.height)
        let resized = try #require(try encoder.encode(image(width: 96, height: 80, red: true), width: 96, height: 80))
        for consumer in [decoder, SurfaceVideoDecoder()] {
            let decoded = try consumer.decode(resized.data, width: resized.width, height: resized.height)
            #expect(decoded.width == 96 && decoded.height == 80)
            #expect(try center(decoded)[0] > 220)
        }
        let restarted = try #require(try SurfaceVideoEncoder().encode(image(), width: 64, height: 64))
        #expect(try center(SurfaceVideoDecoder().decode(restarted.data, width: restarted.width, height: restarted.height)).allSatisfy { $0 < 30 })
    }

    @Test func sharpSizeChangeDoesNotFallBackThroughTheMotionFrameCap() throws {
        let encoder = SurfaceVideoEncoder()
        _ = try #require(try encoder.encode(image(), width: 64, height: 64, refresh: true))
        let source = try noise(width: 258, height: 256, seed: 0x123456789abcdef)
        let resized = try #require(try encoder.encode(source, width: 258, height: 256))
        #expect(resized.data[4] == 1)
        #expect(resized.data[11] == 244)
        #expect(resized.data.count > 48 * 1024 && resized.data.count <= 576 * 1024)
        let decoded = try SurfaceVideoDecoder().decode(resized.data, width: resized.width, height: resized.height)
        #expect(decoded.width == 258 && decoded.height == 256)
    }

    @Test func predictedFirstFrameAndForgedKeyframeAreRejected() throws {
        let encoder = SurfaceVideoEncoder()
        let first = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        let predicted = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        #expect(predicted[4] == 0)
        let decoder = SurfaceVideoDecoder()
        #expect(throws: (any Error).self) { try decoder.decode(predicted, width: 64, height: 64) }
        var forged = predicted
        forged[4] = 1
        #expect(throws: (any Error).self) { try decoder.decode(forged, width: 64, height: 64) }
        var hiddenIDR = first
        hiddenIDR[4] = 0
        #expect(throws: (any Error).self) { try decoder.decode(hiddenIDR, width: 64, height: 64) }
        #expect(try center(decoder.decode(first, width: 64, height: 64)).allSatisfy { $0 < 30 })
    }

    @Test func malformedPacketsResetTheDecoderAndKeyframesRecover() throws {
        let encoder = SurfaceVideoEncoder()
        let keyframe = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        let predicted = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        var malformed = [Data(), Data(keyframe.prefix(9)), Data(keyframe.dropLast()),
                         Data(repeating: 0, count: 8 * 1024 * 1024 + 1)]
        for (index, value) in [(0, UInt8(0)), (4, 2), (5, 3), (6, 255), (7, 255), (10, 0x68)] {
            var packet = keyframe
            packet[index] = value
            malformed.append(packet)
        }
        let spsSize = Int(keyframe[6]) << 8 | Int(keyframe[7])
        let ppsSize = Int(keyframe[8]) << 8 | Int(keyframe[9])
        var wrongPPS = keyframe
        wrongPPS[10 + spsSize] = 0x67
        malformed.append(wrongPPS)
        var invalidNAL = keyframe
        let sampleStart = 10 + spsSize + ppsSize
        invalidNAL.replaceSubrange(sampleStart..<(sampleStart + 4), with: [255, 255, 255, 255])
        malformed.append(invalidNAL)
        for packet in malformed {
            let decoder = SurfaceVideoDecoder()
            _ = try decoder.decode(keyframe, width: 64, height: 64)
            #expect(throws: (any Error).self) { try decoder.decode(packet, width: 64, height: 64) }
            #expect(throws: (any Error).self) { try decoder.decode(predicted, width: 64, height: 64) }
            #expect(try center(decoder.decode(keyframe, width: 64, height: 64)).allSatisfy { $0 < 30 })
        }
    }

    @Test func invalidAndMismatchedDimensionsAreRejected() throws {
        let encoder = SurfaceVideoEncoder()
        let source = try image()
        let packet = try #require(try encoder.encode(source, width: 64, height: 64)).data
        for (width, height) in [(0, 64), (-1, 64), (Int.max, Int.max), (2001, 2000), (64, 80)] {
            let decoder = SurfaceVideoDecoder()
            #expect(throws: (any Error).self) { try decoder.decode(packet, width: width, height: height) }
            #expect(try center(decoder.decode(packet, width: 64, height: 64)).allSatisfy { $0 < 30 })
        }
        for (width, height) in [(0, 64), (-1, 64), (Int.max, Int.max), (2001, 2000)] {
            #expect(throws: (any Error).self) { try encoder.encode(source, width: width, height: height) }
        }
    }

    @Test func oversizedParameterSetDimensionsAreRejected() throws {
        let encoder = SurfaceVideoEncoder()
        let original = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        func golomb(_ value: Int) -> String {
            let binary = String(value + 1, radix: 2)
            return String(repeating: "0", count: binary.count - 1) + binary
        }
        var bits = golomb(0) + golomb(0) + golomb(0) + golomb(0) + golomb(1) + "0"
        bits += golomb(125) + golomb(124) + "11001"
        while bits.count % 8 != 0 { bits += "0" }
        let digits = Array(bits)
        var sps = Data([0x67, 66, 0, 51])
        for offset in stride(from: 0, to: digits.count, by: 8) {
            sps.append(UInt8(String(digits[offset..<(offset + 8)]), radix: 2)!)
        }
        let oldSPSSize = Int(original[6]) << 8 | Int(original[7])
        var oversized = original
        oversized.replaceSubrange(10..<(10 + oldSPSSize), with: sps)
        oversized[6] = UInt8(sps.count >> 8)
        oversized[7] = UInt8(sps.count & 255)
        let decoder = SurfaceVideoDecoder()
        #expect(throws: (any Error).self) { try decoder.decode(oversized, width: 64, height: 64) }
        #expect(try center(decoder.decode(original, width: 64, height: 64)).allSatisfy { $0 < 30 })
    }

    @Test func fittedOddAndThinCapturesRoundTrip() throws {
        for (width, height, expectedWidth, expectedHeight) in [(1, 1, 16, 16), (65, 67, 64, 66), (1, 64, 16, 64)] {
            let fitted = SurfaceVideoEncoder.fittedVideoPixels(width: width, height: height)
            #expect(fitted.width == expectedWidth && fitted.height == expectedHeight)
            let encoder = SurfaceVideoEncoder()
            let packet = try #require(try encoder.encode(image(width: fitted.width, height: fitted.height),
                width: fitted.width, height: fitted.height))
            let decoded = try SurfaceVideoDecoder().decode(packet.data, width: packet.width, height: packet.height)
            #expect(decoded.width == expectedWidth && decoded.height == expectedHeight)
            #expect(try center(decoded).allSatisfy { $0 < 30 })
        }
        for (width, height) in [(Int.max, 1), (1, Int.max), (Int.max, Int.max), (2001, 2000)] {
            let fitted = SurfaceVideoEncoder.fittedVideoPixels(width: width, height: height)
            #expect(fitted.width >= 16 && fitted.height >= 16)
            #expect(fitted.width <= 4096 && fitted.height <= 4096)
            #expect(fitted.width % 2 == 0 && fitted.height % 2 == 0)
            #expect(fitted.width * fitted.height <= 4_000_000)
        }
    }

    @Test func predictedConfigurationChangesRequireAKeyframe() throws {
        let encoder = SurfaceVideoEncoder()
        let decoder = SurfaceVideoDecoder()
        let original = try #require(try encoder.encode(image(), width: 64, height: 64)).data
        _ = try decoder.decode(original, width: 64, height: 64)
        let resized = try #require(try encoder.encode(image(width: 96, height: 80), width: 96, height: 80)).data
        let predicted = try #require(try encoder.encode(image(width: 96, height: 80), width: 96, height: 80)).data
        #expect(predicted[4] == 0)
        #expect(throws: (any Error).self) { try decoder.decode(predicted, width: 96, height: 80) }
        let recovered = try decoder.decode(resized, width: 96, height: 80)
        #expect(recovered.width == 96 && recovered.height == 80)
        #expect(try center(recovered).allSatisfy { $0 < 30 })
    }

    private func noise(width: Int, height: Int, seed: UInt64) throws -> CGImage {
        var state = seed
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[offset] = UInt8(truncatingIfNeeded: state)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 16)
                bytes[offset + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func anOversizedSharpReferenceIsRefusedAndMotionRestartsIndependently() throws {
        let encoder = SurfaceVideoEncoder()
        let rejected = try encoder.encode(noise(width: 1024, height: 1024, seed: 0x123456789abcdef),
                                          width: 1024, height: 1024, refresh: true)
        #expect(rejected == nil)
        let recovered = try #require(try encoder.encode(image(width: 1024, height: 1024, red: true),
                                                       width: 1024, height: 1024))
        #expect(recovered.data[4] == 1)
        #expect(recovered.data.count <= 48 * 1024)
        let visible = try center(SurfaceVideoDecoder().decode(recovered.data, width: recovered.width, height: recovered.height))
        #expect(visible[0] > visible[1] && visible[0] > visible[2])
    }

    @Test func entropyChangesAndFrozenNoiseStayBoundedAndDecodable() throws {
        let encoder = SurfaceVideoEncoder()
        let decoder = SurfaceVideoDecoder()
        let width = 1536
        let height = 1024
        let original = try #require(try encoder.encode(image(width: width, height: height),
            width: width, height: height))
        let preserved = try decoder.decode(original.data, width: original.width, height: original.height)
        let black = try center(preserved)
        let frozen = try noise(width: width, height: height, seed: 0x123456789abcdef)
        var previous: SurfaceVideoFrame?
        var frozenPredictedFrames = 0
        for index in 0..<8 {
            let source = index < 3 ? try noise(width: width, height: height, seed: UInt64(index + 1)) : frozen
            guard let frame = try encoder.encode(source, width: width, height: height) else { continue }
            #expect(frame.data.count <= 48 * 1024)
            #expect(frame.width >= 16 && frame.height >= 16)
            #expect(frame.width % 2 == 0 && frame.height % 2 == 0)
            #expect(frame.width <= width && frame.height <= height)
            let decoded = try decoder.decode(frame.data, width: frame.width, height: frame.height)
            #expect(decoded.width == frame.width && decoded.height == frame.height)
            if index == 0 || previous?.width != frame.width || previous?.height != frame.height {
                let fresh = try SurfaceVideoDecoder().decode(frame.data, width: frame.width, height: frame.height)
                #expect(fresh.width == frame.width && fresh.height == frame.height)
            }
            if index >= 3, frame.data[4] == 0 { frozenPredictedFrames += 1 }
            previous = frame
        }
        #expect(frozenPredictedFrames > 0)
        #expect(try center(preserved) == black)
    }

    @Test func oddRequestedDimensionsReportEvenDecodablePixels() throws {
        let frame = try #require(try SurfaceVideoEncoder().encode(image(width: 65, height: 67), width: 65, height: 67))
        #expect(frame.width == 64 && frame.height == 66)
        #expect(frame.data.count <= 48 * 1024)
        let decoded = try SurfaceVideoDecoder().decode(frame.data, width: frame.width, height: frame.height)
        #expect(decoded.width == 64 && decoded.height == 66)
    }

    private enum LifecycleError: Error {
        case missingFrame
        case synchronizationTimeout(String)
    }

    private struct LifecycleObservation: Sendable {
        let frames: [SurfaceVideoFrame]
        let cancellations: [Bool]
    }

    private final class LifecycleResult<Observation: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let completed = DispatchSemaphore(value: 0)
        private var result: Result<Observation, Error>?

        func finish(_ result: Result<Observation, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
            completed.signal()
        }

        func wait() -> Result<Observation, Error>? {
            guard completed.wait(timeout: .now() + 20) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    @Test func cancellationResizeAndRepeatedDestructionCompleteWithinDeadline() throws {
        let result = LifecycleResult<LifecycleObservation>()
        // A detached worker lets the deadline fail even if a synchronous codec call never returns.
        DispatchQueue.global(qos: .userInitiated).async {
            result.finish(Result {
                var frames: [SurfaceVideoFrame] = []
                var cancellations: [Bool] = []
                for _ in 0..<3 {
                    var encoder: SurfaceVideoEncoder? = SurfaceVideoEncoder()
                    let source = try image()
                    guard let first = try encoder?.encode(source, width: 64, height: 64) else {
                        throw LifecycleError.missingFrame
                    }
                    frames.append(first)
                    var checks = 0
                    let cancelled = try encoder?.encode(source, width: 64, height: 64, isCancelled: {
                        checks += 1
                        return checks >= 5
                    })
                    cancellations.append(cancelled == nil)
                    guard let recovered = try encoder?.encode(image(red: true), width: 64, height: 64),
                          let resized = try encoder?.encode(image(width: 96, height: 80, red: true),
                                                            width: 96, height: 80) else {
                        throw LifecycleError.missingFrame
                    }
                    frames.append(contentsOf: [recovered, resized])
                    encoder = nil
                }
                return LifecycleObservation(frames: frames, cancellations: cancellations)
            })
        }
        let observation = try #require(result.wait(), "Encoder lifecycle exceeded 20 seconds").get()
        #expect(observation.cancellations == [true, true, true])
        #expect(observation.frames.count == 9)
        for (index, frame) in observation.frames.enumerated() {
            let resized = index % 3 == 2
            #expect(frame.width == (resized ? 96 : 64))
            #expect(frame.height == (resized ? 80 : 64))
            #expect(frame.data.count <= 48 * 1024)
            #expect(frame.data[4] == 1)
            let decoded = try SurfaceVideoDecoder().decode(frame.data, width: frame.width, height: frame.height)
            let pixel = try center(decoded)
            if index % 3 == 0 {
                #expect(pixel.allSatisfy { $0 < 30 })
            } else {
                #expect(pixel[0] > 220 && pixel[1] < 30 && pixel[2] < 30)
            }
        }
    }

    private struct RetirementObservation: Sendable {
        let releasedEncoder: Bool
        let afterCreation: (live: Int, retiring: Int)
        let active: [(live: Int, retiring: Int)]
        let retired: [(live: Int, retiring: Int)]
        let keyframes: Int
        let drained: (live: Int, retiring: Int)
    }

    nonisolated private func drainCompressionRetirements() -> Bool {
        let result = LifecycleResult<Void>()
        DispatchQueue.global(qos: .userInitiated).async {
            SurfaceVideoCompressionSessions.waitForRetirements()
            result.finish(.success(()))
        }
        return result.wait() != nil
    }

    @Test func rapidEncoderRetirementAppliesBackpressureWithoutBlockingDestruction() throws {
        let initialReady = DispatchSemaphore(value: 0)
        let beginRetirement = DispatchSemaphore(value: 0)
        let retirementBlocked = DispatchSemaphore(value: 0)
        let releaseRetirement = DispatchSemaphore(value: 0)
        let encoderRetired = DispatchSemaphore(value: 0)
        let creationEntered = DispatchSemaphore(value: 0)
        let nextCreated = DispatchSemaphore(value: 0)
        let beginChurn = DispatchSemaphore(value: 0)
        let result = LifecycleResult<RetirementObservation>()
        var workerStarted = false
        var resultAwaited = false
        defer {
            beginRetirement.signal()
            releaseRetirement.signal()
            beginChurn.signal()
            if workerStarted && !resultAwaited {
                if let completion = result.wait() {
                    if case .failure(let error) = completion { Issue.record(error) }
                } else {
                    Issue.record("Encoder retirement worker exceeded 20 seconds during cleanup")
                }
            }
            #expect(drainCompressionRetirements(), "Compression retirement cleanup exceeded 20 seconds")
            let counts = SurfaceVideoCompressionSessions.counts
            #expect(counts.live == 0 && counts.retiring == 0)
        }
        try #require(drainCompressionRetirements(), "Previous compression retirements exceeded 20 seconds")
        let baseline = SurfaceVideoCompressionSessions.counts
        #expect(baseline.live == 0 && baseline.retiring == 0)

        workerStarted = true
        DispatchQueue.global(qos: .userInitiated).async {
            result.finish(Result {
                let source = try image()
                var encoder: SurfaceVideoEncoder? = SurfaceVideoEncoder()
                defer { encoder = nil }
                guard let initial = try encoder?.encode(source, width: 64, height: 64) else {
                    throw LifecycleError.missingFrame
                }
                var active = [SurfaceVideoCompressionSessions.counts]
                var retired: [(live: Int, retiring: Int)] = []
                var keyframes = initial.data[4] == 1 ? 1 : 0
                initialReady.signal()
                guard beginRetirement.wait(timeout: .now() + 20) == .success else {
                    throw LifecycleError.synchronizationTimeout("initial encoder retirement")
                }
                weak var releasedEncoder = encoder
                encoder = nil
                let released = releasedEncoder == nil
                retired.append(SurfaceVideoCompressionSessions.counts)
                encoderRetired.signal()

                encoder = SurfaceVideoEncoder()
                guard let next = try encoder?.encode(source, width: 64, height: 64, isCancelled: {
                    creationEntered.signal()
                    return false
                }) else {
                    throw LifecycleError.missingFrame
                }
                let afterCreation = SurfaceVideoCompressionSessions.counts
                active.append(SurfaceVideoCompressionSessions.counts)
                keyframes += next.data[4] == 1 ? 1 : 0
                nextCreated.signal()
                guard beginChurn.wait(timeout: .now() + 20) == .success else {
                    throw LifecycleError.synchronizationTimeout("rapid encoder churn")
                }
                encoder = nil
                retired.append(SurfaceVideoCompressionSessions.counts)
                for _ in 0..<40 {
                    encoder = SurfaceVideoEncoder()
                    guard let frame = try encoder?.encode(source, width: 64, height: 64) else {
                        throw LifecycleError.missingFrame
                    }
                    active.append(SurfaceVideoCompressionSessions.counts)
                    keyframes += frame.data[4] == 1 ? 1 : 0
                    encoder = nil
                    retired.append(SurfaceVideoCompressionSessions.counts)
                }
                SurfaceVideoCompressionSessions.waitForRetirements()
                return RetirementObservation(releasedEncoder: released, afterCreation: afterCreation,
                    active: active, retired: retired, keyframes: keyframes,
                    drained: SurfaceVideoCompressionSessions.counts)
            })
        }
        try #require(initialReady.wait(timeout: .now() + 20) == .success,
                     "Initial encoder creation exceeded 20 seconds")
        SurfaceVideoCompressionSessions.retirementQueue.async {
            retirementBlocked.signal()
            if releaseRetirement.wait(timeout: .now() + 60) != .success {
                Issue.record("Controlled compression retirement blocker exceeded 60 seconds")
            }
        }
        try #require(retirementBlocked.wait(timeout: .now() + 20) == .success,
                     "Controlled retirement blocker did not start within 20 seconds")
        beginRetirement.signal()
        try #require(encoderRetired.wait(timeout: .now() + 20) == .success,
                     "Encoder destruction blocked on the held retirement queue")
        let held = SurfaceVideoCompressionSessions.counts
        #expect(held.live == 1 && held.retiring == 1)
        try #require(creationEntered.wait(timeout: .now() + 20) == .success,
                     "Next encoder did not enter encode within 20 seconds")
        let completedWhileBlocked = nextCreated.wait(timeout: .now() + 1)
        #expect(completedWhileBlocked == .timedOut,
                "Next encoder completed creation before the held retirement was released")
        let waiting = SurfaceVideoCompressionSessions.counts
        #expect(waiting.live == 1 && waiting.retiring == 1)
        releaseRetirement.signal()
        if completedWhileBlocked == .timedOut {
            try #require(nextCreated.wait(timeout: .now() + 20) == .success,
                         "Next encoder did not complete after releasing retirement")
        }
        beginChurn.signal()
        let completion = result.wait()
        resultAwaited = true
        let observation = try #require(completion, "Rapid encoder churn exceeded 20 seconds").get()
        #expect(observation.releasedEncoder)
        #expect(observation.afterCreation.live == 1 && observation.afterCreation.retiring == 0)
        #expect(observation.active.count == 42 && observation.retired.count == 42)
        #expect(observation.keyframes == 42)
        #expect(observation.active.allSatisfy { $0.live == 1 && $0.retiring == 0 })
        #expect(observation.retired.allSatisfy { (0...1).contains($0.live) && $0.live == $0.retiring })
        #expect(observation.drained.live == 0 && observation.drained.retiring == 0)
    }
}

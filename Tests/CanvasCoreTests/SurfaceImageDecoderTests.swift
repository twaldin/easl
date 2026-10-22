import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import CanvasCore

@SurfaceHardwareCodec
struct SurfaceImageDecoderTests {
    private func image(redLeftHalf: Bool = false, width: Int = 65, height: Int = 67,
                       noise: Bool = false) throws -> CGImage {
        let colors: [[UInt8]] = [[255, 0, 0], [0, 0, 255], [0, 255, 0], [255, 0, 255], [0, 255, 255], [255, 255, 255]]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var random: UInt32 = 0x7135_4269
        for y in 0..<height {
            for x in 0..<width {
                random = random &* 1_664_525 &+ 1_013_904_223
                let value = UInt8(truncatingIfNeeded: random >> 24)
                let color = redLeftHalf && x < width / 2 ? colors[0] :
                    (noise ? [value, value, value] : colors[(x + y * 3) % colors.count])
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = color[channel] }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
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

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    private func decode(_ data: Data, format: SurfaceFormat = .png, width: Int = 65, height: Int = 67,
                        canvas: CGSize = CGSize(width: 65, height: 67),
                        video: SurfaceVideoDecoder, refinement: Bool = false) throws -> CGImage {
        try SurfaceImageDecoder.decode(data, format: format, width: width, height: height,
            canvas: canvas, video: video, refinement: refinement)
    }

    @Test func refreshBecomesTheReferenceForNativeSizePredictedFrames() throws {
        // Keep the prediction-only fixture independent of the full runner's codec lifetime.
        if try runIsolatedTestIfParallelNow("refreshBecomesTheReferenceForNativeSizePredictedFrames") { return }
        let encoder = SurfaceVideoEncoder()
        let video = SurfaceVideoDecoder()
        let source = try image()
        let first = try #require(try encoder.encode(source, width: 65, height: 67))
        let original = try decode(first.data, format: .h264, width: first.width, height: first.height, video: video)
        #expect(original.width == 64 && original.height == 66)
        let sharp = try #require(try encoder.encode(source, width: 65, height: 67, refresh: true))
        #expect(sharp.data[4] == 1)
        #expect(sharp.width == 66 && sharp.height == 68)
        let settled = try decode(sharp.data, format: .h264, width: sharp.width, height: sharp.height,
                                 video: video, refinement: true)
        #expect(settled.width == 65 && settled.height == 67)
        let predicted = try #require(try encoder.encode(image(redLeftHalf: true), width: 65, height: 67))
        #expect(predicted.data[4] == 0)
        #expect(throws: (any Error).self) {
            try decode(predicted.data, format: .h264, width: predicted.width, height: predicted.height,
                       video: SurfaceVideoDecoder())
        }
        let moved = try decode(predicted.data, format: .h264, width: predicted.width, height: predicted.height, video: video)
        #expect(moved.width == 65 && moved.height == 67)
        let visible = try pixels(moved)
        let red = (16 * moved.width + 16) * 4
        #expect(visible[red] >= 220 && visible[red + 1] <= 30 && visible[red + 2] <= 30)
    }

    @Test func refreshAboveMotionBudgetDecodesAsOneCompletePacket() throws {
        let source = try image(redLeftHalf: true, width: 384, height: 384, noise: true)
        let frame = try #require(try SurfaceVideoEncoder().encode(source, width: 384, height: 384, refresh: true))
        #expect(frame.data.count > 48 * 1024)
        #expect(frame.data.count <= 576 * 1024)
        let video = SurfaceVideoDecoder()
        let canvas = CGSize(width: 384, height: 384)
        var sourceFrame = SurfaceEvent.Frame(stream: "str_decoder", seq: 1, input: 0, size: canvas, scale: 1,
            format: .h264, data: frame.data, width: frame.width, height: frame.height,
            back: false, forward: false, loading: false)
        sourceFrame.refresh = true
        sourceFrame.canvas = canvas
        var transmission = try SurfaceRefreshTransmission(frame: sourceFrame)
        var assembly = SurfaceRefreshAssembly()
        var pending = transmission.start()
        var completed: SurfaceEvent.Frame?
        while !pending.isEmpty {
            let part = pending.removeFirst()
            completed = try assembly.append(frame: part)
            pending += try transmission.progress(offset: try #require(part.offset))
        }
        let assembled = try #require(completed)
        #expect(assembled == sourceFrame)
        #expect(throws: (any Error).self) {
            try decode(frame.data, format: .h264, width: 384, height: 384, canvas: canvas, video: video)
        }
        let decoded = try decode(assembled.data, format: .h264, width: 384, height: 384,
                                 canvas: canvas, video: video, refinement: true)
        #expect(decoded.width == 384 && decoded.height == 384)
        let visible = try pixels(decoded)
        let red = (16 * 384 + 16) * 4
        #expect(visible[red] >= 220 && visible[red + 1] <= 30 && visible[red + 2] <= 30)
    }

    @Test func rejectedRefreshBoundariesLeavePublishedReferenceUsable() throws {
        // Keep the prediction-only fixture independent of the full runner's codec lifetime.
        if try runIsolatedTestIfParallelNow("rejectedRefreshBoundariesLeavePublishedReferenceUsable") { return }
        let encoder = SurfaceVideoEncoder()
        let video = SurfaceVideoDecoder()
        let sharp = try #require(try encoder.encode(image(), width: 65, height: 67, refresh: true))
        _ = try decode(sharp.data, format: .h264, width: sharp.width, height: sharp.height, video: video, refinement: true)
        for data in [Data(), Data(repeating: 0, count: 576 * 1024 + 1)] {
            #expect(throws: (any Error).self) {
                try decode(data, format: .h264, width: sharp.width, height: sharp.height, video: video, refinement: true)
            }
        }
        #expect(throws: (any Error).self) { try decode(png(image()), video: video, refinement: true) }
        for canvas in [CGSize.zero, CGSize(width: -1, height: 67), CGSize(width: CGFloat.infinity, height: 67),
                       CGSize(width: 65.5, height: 67), CGSize(width: 63, height: 67),
                       CGSize(width: 65, height: 65), CGSize(width: 67, height: 67),
                       CGSize(width: 4_000_001, height: 1)] {
            #expect(throws: (any Error).self) {
                try decode(sharp.data, format: .h264, width: sharp.width, height: sharp.height,
                           canvas: canvas, video: video, refinement: true)
            }
        }
        for (width, height) in [(0, 68), (Int.max, Int.max), (65, 68), (66, 67)] {
            #expect(throws: (any Error).self) {
                try decode(sharp.data, format: .h264, width: width, height: height, video: video, refinement: true)
            }
        }
        let predicted = try #require(try encoder.encode(image(redLeftHalf: true), width: 65, height: 67))
        #expect(predicted.data[4] == 0)
        let moved = try decode(predicted.data, format: .h264, width: predicted.width, height: predicted.height, video: video)
        let visible = try pixels(moved)
        let red = (16 * moved.width + 16) * 4
        #expect(visible[red] >= 220 && visible[red + 1] <= 30 && visible[red + 2] <= 30)
    }

    @Test func malformedRefreshInvalidatesPredictionUntilIndependentKeyframe() throws {
        // Keep the prediction-only fixture independent of the full runner's codec lifetime.
        if try runIsolatedTestIfParallelNow("malformedRefreshInvalidatesPredictionUntilIndependentKeyframe") { return }
        let encoder = SurfaceVideoEncoder()
        let video = SurfaceVideoDecoder()
        let sharp = try #require(try encoder.encode(image(), width: 65, height: 67, refresh: true))
        _ = try decode(sharp.data, format: .h264, width: sharp.width, height: sharp.height, video: video, refinement: true)
        #expect(throws: (any Error).self) {
            try decode(Data(sharp.data.prefix(20)), format: .h264, width: sharp.width, height: sharp.height,
                       video: video, refinement: true)
        }
        let predicted = try #require(try encoder.encode(image(redLeftHalf: true), width: 65, height: 67))
        #expect(predicted.data[4] == 0)
        #expect(throws: (any Error).self) {
            try decode(predicted.data, format: .h264, width: predicted.width, height: predicted.height, video: video)
        }
        let recovery = try #require(try SurfaceVideoEncoder().encode(image(redLeftHalf: true), width: 65, height: 67))
        #expect(recovery.data[4] == 1)
        let recovered = try decode(recovery.data, format: .h264, width: recovery.width, height: recovery.height, video: video)
        #expect(recovered.width == 64 && recovered.height == 66)
        let visible = try pixels(recovered)
        let red = (16 * recovered.width + 16) * 4
        #expect(visible[red] >= 220 && visible[red + 1] <= 30 && visible[red + 2] <= 30)
    }

    @Test func canceledDecodedRefreshRecoversOnBothOldAndFreshDecoders() throws {
        let encoder = SurfaceVideoEncoder()
        let mutated = SurfaceVideoDecoder()
        let sharp = try #require(try encoder.encode(image(), width: 65, height: 67, refresh: true))
        _ = try decode(sharp.data, format: .h264, width: sharp.width, height: sharp.height,
                       video: mutated, refinement: true)
        let recovery = try #require(try SurfaceVideoEncoder().encode(image(redLeftHalf: true), width: 65, height: 67))
        #expect(recovery.data[4] == 1)
        for video in [mutated, SurfaceVideoDecoder()] {
            let recovered = try decode(recovery.data, format: .h264, width: recovery.width, height: recovery.height, video: video)
            #expect(recovered.width == 64 && recovered.height == 66)
            let visible = try pixels(recovered)
            let red = (16 * recovered.width + 16) * 4
            #expect(visible[red] >= 220 && visible[red + 1] <= 30 && visible[red + 2] <= 30)
        }
    }

    @Test func stillImagesValidatePayloadDimensions() throws {
        let source = try image()
        let data = try png(source)
        let video = SurfaceVideoDecoder()
        #expect(try pixels(decode(data, video: video, refinement: false)) == pixels(source))
        for (width, height) in [(64, 67), (65, 66)] {
            #expect(throws: (any Error).self) {
                try decode(data, width: width, height: height, video: video, refinement: false)
            }
        }
        #expect(throws: (any Error).self) {
            try decode(Data([1, 2, 3]), format: .jpeg, video: video, refinement: false)
        }
    }

    @Test func fullJPEGAboveLegacyMotionBudgetDecodesLiteralPixels() throws {
        let width = 1024, height = 1024
        var source = [UInt8](repeating: 255, count: width * height * 4)
        var random: UInt32 = 0x7135_4269
        for y in 0..<height {
            for x in 0..<width {
                random = random &* 1_664_525 &+ 1_013_904_223
                let value: UInt8 = x < 64 && y < 64 ? 0 :
                    (x >= 960 && y >= 960 ? 255 : UInt8(truncatingIfNeeded: random >> 24))
                for channel in 0..<3 { source[(y * width + x) * 4 + channel] = value }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(source) as CFData))
        let sourceImage = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, sourceImage,
            [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(encoded.length > 265_627)
        #expect(encoded.length < 16 << 20)
        let decoded = try decode(encoded as Data, format: .jpeg, width: width, height: height,
            canvas: CGSize(width: width, height: height), video: SurfaceVideoDecoder(), refinement: false)
        #expect(decoded.width == 1024)
        #expect(decoded.height == 1024)
        let visible = try pixels(decoded)
        let black = (16 * width + 16) * 4
        let white = (1000 * width + 1000) * 4
        #expect(Array(visible[black..<(black + 4)]) == [0, 0, 0, 255])
        #expect(Array(visible[white..<(white + 4)]) == [255, 255, 255, 255])
        #expect(throws: (any Error).self) {
            try decode(encoded as Data, format: .jpeg, width: width - 1, height: height,
                canvas: CGSize(width: width, height: height), video: SurfaceVideoDecoder(), refinement: false)
        }
    }
}

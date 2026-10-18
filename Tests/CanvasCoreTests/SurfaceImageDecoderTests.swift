import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import CanvasCore

@Suite(.serialized)
struct SurfaceImageDecoderTests {
    private func image(redLeftHalf: Bool = false) throws -> CGImage {
        let width = 65, height = 67
        let colors: [[UInt8]] = [[255, 0, 0], [0, 0, 255], [0, 255, 0], [255, 0, 255], [0, 255, 255], [255, 255, 255]]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = redLeftHalf && x < width / 2 ? colors[0] : colors[(x + y * 3) % colors.count]
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
                        video: SurfaceVideoDecoder, refinement: Bool = true) throws -> CGImage {
        try SurfaceImageDecoder.decode(data, format: format, width: width, height: height,
            canvas: canvas, video: video, refinement: refinement)
    }

    @Test func losslessRefreshPreservesOddCanvasAndMotionReferences() throws {
        let motion = SurfaceVideoEncoder()
        let video = SurfaceVideoDecoder()
        let source = try image()
        let first = try #require(try motion.encode(source, width: 65, height: 67))
        let original = try decode(first.data, format: .h264, width: first.width, height: first.height,
                                  video: video, refinement: false)
        let originalPixels = try pixels(original)
        let settled = try decode(png(source), video: video)
        #expect(settled.width == 65 && settled.height == 67)
        #expect(try pixels(settled) == pixels(source))
        let predicted = try #require(try motion.encode(image(redLeftHalf: true), width: 65, height: 67))
        #expect(predicted.data[4] == 0)
        let moved = try decode(predicted.data, format: .h264, width: predicted.width, height: predicted.height,
                               video: video, refinement: false)
        #expect(moved.width == 64 && moved.height == 66)
        let visible = try pixels(moved)
        #expect(visible[0] >= 220 && visible[1] <= 30 && visible[2] <= 30)
        #expect(try pixels(original) == originalPixels)
        #expect(try pixels(settled) == pixels(source))
    }

    @Test func invalidRefreshCannotPoisonMotionReferences() throws {
        let motion = SurfaceVideoEncoder()
        let video = SurfaceVideoDecoder()
        let source = try image()
        let first = try #require(try motion.encode(source, width: 65, height: 67))
        _ = try decode(first.data, format: .h264, width: first.width, height: first.height,
                       video: video, refinement: false)
        let sharp = try png(source)
        for data in [Data(), Data(sharp.prefix(20)), Data(repeating: 0, count: 576 * 1024 + 1)] {
            #expect(throws: (any Error).self) { try decode(data, video: video) }
        }
        #expect(throws: (any Error).self) {
            try decode(first.data, format: .h264, width: first.width, height: first.height, video: video)
        }
        let predicted = try #require(try motion.encode(image(redLeftHalf: true), width: 65, height: 67))
        let moved = try decode(predicted.data, format: .h264, width: predicted.width, height: predicted.height,
                               video: video, refinement: false)
        let visible = try pixels(moved)
        #expect(visible[0] >= 220 && visible[1] <= 30 && visible[2] <= 30)
        #expect(try pixels(decode(sharp, video: video)) == pixels(source))
    }

    @Test func refreshRequiresExactDeclaredCanvasWithoutResampling() throws {
        let source = try image()
        let sharp = try png(source)
        let video = SurfaceVideoDecoder()
        for canvas in [CGSize.zero, CGSize(width: -1, height: 67), CGSize(width: CGFloat.infinity, height: 67),
                       CGSize(width: 65.5, height: 67), CGSize(width: 63, height: 67),
                       CGSize(width: 65, height: 65), CGSize(width: 67, height: 67),
                       CGSize(width: 4_000_001, height: 1)] {
            #expect(throws: (any Error).self) { try decode(sharp, canvas: canvas, video: video) }
        }
        for (width, height) in [(0, 67), (Int.max, Int.max), (64, 67), (65, 68)] {
            #expect(throws: (any Error).self) { try decode(sharp, width: width, height: height, video: video) }
        }
        #expect(throws: (any Error).self) {
            try decode(Data(repeating: 0, count: 48 * 1024 + 1), format: .h264,
                       width: 64, height: 66, video: video, refinement: false)
        }
        #expect(try pixels(decode(sharp, video: video)) == pixels(source))
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

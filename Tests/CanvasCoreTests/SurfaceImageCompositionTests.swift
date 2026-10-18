import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import CanvasCore

@Suite(.serialized)
struct SurfaceImageCompositionTests {
    private func image(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
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

    private func solid(_ color: [UInt8], width: Int = 32, height: Int = 16) -> [UInt8] {
        Array(repeating: color, count: width * height).flatMap { $0 }
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func syntheticCaretFramesPreserveUnchangedSharpMacroblocks() throws {
        let canvas = CGSize(width: 32, height: 16)
        var raw = solid([255, 255, 255, 255])
        var sharp = raw
        for y in 0..<16 {
            for x in 0..<16 {
                let offset = (y * 32 + x) * 4
                raw.replaceSubrange(offset..<(offset + 4), with: [80, 80, 80, 255])
                sharp.replaceSubrange(offset..<(offset + 4), with: x.isMultiple(of: 2) ? [255, 0, 0, 255] : [0, 0, 255, 255])
            }
        }
        var composition = SurfaceImageComposition()
        _ = try composition.present(image(width: 32, height: 16, pixels: raw), format: .h264, canvas: canvas, refinement: false)
        let settled = try composition.present(image(width: 32, height: 16, pixels: sharp), format: .png,
            canvas: canvas, refinement: true)
        #expect(try pixels(settled) == sharp)
        for blink in 0..<30 {
            var decodedMotion = raw
            var expected = sharp
            if blink.isMultiple(of: 2) {
                for y in 4..<12 {
                    let offset = (y * 32 + 24) * 4
                    decodedMotion.replaceSubrange(offset..<(offset + 4), with: [0, 0, 0, 255])
                    expected.replaceSubrange(offset..<(offset + 4), with: [0, 0, 0, 255])
                }
            }
            let visible = try composition.present(image(width: 32, height: 16, pixels: decodedMotion),
                format: .h264, canvas: canvas, refinement: false)
            #expect(try pixels(visible) == expected)
        }
        #expect(try pixels(settled) == sharp)
    }

    @Test func discardedPNGSnapshotCannotReplaceAcceptedPixelsOrMotionReference() throws {
        let canvas = CGSize(width: 32, height: 16)
        let raw = solid([80, 80, 80, 255])
        let sharp = solid([255, 0, 0, 255])
        var accepted = SurfaceImageComposition()
        _ = try accepted.present(image(width: 32, height: 16, pixels: raw), format: .h264, canvas: canvas, refinement: false)
        _ = try accepted.present(image(width: 32, height: 16, pixels: sharp), format: .png, canvas: canvas, refinement: true)
        var canceled = accepted
        _ = try canceled.present(image(width: 32, height: 16, pixels: solid([0, 0, 255, 255])),
            format: .png, canvas: canvas, refinement: true)
        var moved = raw
        var expected = sharp
        for y in 0..<16 {
            let range = (y * 32 + 16) * 4..<(y * 32 + 32) * 4
            moved.replaceSubrange(range, with: Array(repeating: [0, 255, 0, 255], count: 16).flatMap { $0 })
            expected.replaceSubrange(range, with: Array(repeating: [0, 255, 0, 255], count: 16).flatMap { $0 })
        }
        let visible = try accepted.present(image(width: 32, height: 16, pixels: moved), format: .h264,
            canvas: canvas, refinement: false)
        #expect(try pixels(visible) == expected)
        let canceledVisible = try canceled.present(image(width: 32, height: 16, pixels: raw), format: .h264,
            canvas: canvas, refinement: false)
        #expect(try pixels(canceledVisible) == solid([0, 0, 255, 255]))
    }

    @Test func incompatiblePixelAndCanvasDimensionsResetComposition() throws {
        var composition = SurfaceImageComposition()
        let initialCanvas = CGSize(width: 32, height: 16)
        let raw = try image(width: 32, height: 16, pixels: solid([80, 80, 80, 255]))
        _ = try composition.present(raw, format: .h264, canvas: initialCanvas, refinement: false)
        _ = try composition.present(image(width: 32, height: 16, pixels: solid([255, 0, 0, 255])),
            format: .png, canvas: initialCanvas, refinement: true)
        let smaller = try image(width: 16, height: 16, pixels: solid([0, 255, 0, 255], width: 16))
        let resized = try composition.present(smaller, format: .h264, canvas: initialCanvas, refinement: false)
        #expect(resized.width == 16 && resized.height == 16)
        #expect(try pixels(resized) == solid([0, 255, 0, 255], width: 16))
        let oddCanvas = CGSize(width: 17, height: 17)
        let canvasReset = try composition.present(smaller, format: .h264, canvas: oddCanvas, refinement: false)
        #expect(try pixels(canvasReset) == solid([0, 255, 0, 255], width: 16))
        _ = try composition.present(image(width: 17, height: 17, pixels: solid([0, 0, 255, 255], width: 17, height: 17)),
            format: .png, canvas: oddCanvas, refinement: true)
        let next = try composition.present(smaller, format: .h264, canvas: oddCanvas, refinement: false)
        #expect(next.width == 17 && next.height == 17)
        #expect(try pixels(next) == solid([0, 0, 255, 255], width: 17, height: 17))
        #expect(throws: (any Error).self) {
            try composition.present(raw, format: .png, canvas: oddCanvas, refinement: true)
        }
        let unchanged = try composition.present(smaller, format: .h264, canvas: oddCanvas, refinement: false)
        #expect(try pixels(unchanged) == solid([0, 0, 255, 255], width: 17, height: 17))
    }

    @Test func logicalCanvasChangeResetsEvenWhenMotionPixelDimensionsStayTheSame() throws {
        let canvas = CGSize(width: 32, height: 16)
        let raw = try image(width: 32, height: 16, pixels: solid([80, 80, 80, 255]))
        var composition = SurfaceImageComposition()
        _ = try composition.present(raw, format: .h264, canvas: canvas, refinement: false)
        _ = try composition.present(image(width: 32, height: 16, pixels: solid([255, 0, 0, 255])),
            format: .png, canvas: canvas, refinement: true)
        let visible = try composition.present(raw, format: .h264,
            canvas: CGSize(width: 64, height: 32), refinement: false)
        #expect(visible.width == 32 && visible.height == 16)
        #expect(try pixels(visible) == solid([80, 80, 80, 255]))
    }

    @Test func partialEdgeMacroblockRetainsEveryOtherSharpPixel() throws {
        let width = 21, height = 19
        let canvas = CGSize(width: width, height: height)
        let raw = solid([80, 80, 80, 255], width: width, height: height)
        let sharp = solid([255, 0, 0, 255], width: width, height: height)
        var moved = raw
        var expected = sharp
        for y in 16..<height {
            for x in 16..<width {
                let offset = (y * width + x) * 4
                moved.replaceSubrange(offset..<(offset + 4), with: [0, 255, 0, 255])
                expected.replaceSubrange(offset..<(offset + 4), with: [0, 255, 0, 255])
            }
        }
        var composition = SurfaceImageComposition()
        _ = try composition.present(image(width: width, height: height, pixels: raw),
            format: .h264, canvas: canvas, refinement: false)
        _ = try composition.present(image(width: width, height: height, pixels: sharp),
            format: .png, canvas: canvas, refinement: true)
        let visible = try composition.present(image(width: width, height: height, pixels: moved),
            format: .h264, canvas: canvas, refinement: false)
        #expect(try pixels(visible) == expected)
    }

    @Test func nativeMotionBlocksMapOntoLargerSharpCanvasWithoutOverwritingNeighbors() throws {
        let canvas = CGSize(width: 65, height: 33)
        let raw = solid([80, 80, 80, 255])
        let sharp = solid([255, 0, 0, 255], width: 65, height: 33)
        var moved = raw
        var expected = sharp
        for y in 0..<16 {
            for x in 16..<32 {
                let offset = (y * 32 + x) * 4
                moved.replaceSubrange(offset..<(offset + 4), with: [0, 255, 0, 255])
            }
        }
        for y in 0..<33 {
            for x in 33..<65 {
                let offset = (y * 65 + x) * 4
                expected.replaceSubrange(offset..<(offset + 4), with: [0, 255, 0, 255])
            }
        }
        var composition = SurfaceImageComposition()
        _ = try composition.present(image(width: 32, height: 16, pixels: raw),
            format: .h264, canvas: canvas, refinement: false)
        _ = try composition.present(image(width: 65, height: 33, pixels: sharp),
            format: .png, canvas: canvas, refinement: true)
        let visible = try composition.present(image(width: 32, height: 16, pixels: moved),
            format: .h264, canvas: canvas, refinement: false)
        #expect(visible.width == 65 && visible.height == 33)
        #expect(try pixels(visible) == expected)
        let repeated = try composition.present(image(width: 32, height: 16, pixels: moved),
            format: .h264, canvas: canvas, refinement: false)
        #expect(try pixels(repeated) == expected)
    }

    @Test func partialNativeMotionBlockMapsOntoOddSharpCanvasAtLiteralBounds() throws {
        let canvas = CGSize(width: 43, height: 39)
        let raw = solid([80, 80, 80, 255], width: 21, height: 19)
        let sharp = solid([255, 0, 0, 255], width: 43, height: 39)
        var moved = raw
        var expected = sharp
        for y in 16..<19 {
            for x in 16..<21 {
                let offset = (y * 21 + x) * 4
                moved.replaceSubrange(offset..<(offset + 4), with: [0, 255, 0, 255])
            }
        }
        for y in 33..<39 {
            for x in 33..<43 {
                let offset = (y * 43 + x) * 4
                expected.replaceSubrange(offset..<(offset + 4), with: [0, 255, 0, 255])
            }
        }
        var composition = SurfaceImageComposition()
        _ = try composition.present(image(width: 21, height: 19, pixels: raw),
            format: .h264, canvas: canvas, refinement: false)
        _ = try composition.present(image(width: 43, height: 39, pixels: sharp),
            format: .png, canvas: canvas, refinement: true)
        let visible = try composition.present(image(width: 21, height: 19, pixels: moved),
            format: .h264, canvas: canvas, refinement: false)
        #expect(visible.width == 43 && visible.height == 39)
        #expect(try pixels(visible) == expected)
    }

    @Test func JPEGReturnsOriginalImageAndDoesNotRetainSharpComposition() throws {
        let canvas = CGSize(width: 32, height: 16)
        let motion = try image(width: 32, height: 16, pixels: solid([80, 80, 80, 255]))
        var composition = SurfaceImageComposition()
        _ = try composition.present(motion, format: .h264, canvas: canvas, refinement: false)
        _ = try composition.present(image(width: 32, height: 16, pixels: solid([255, 0, 0, 255])),
            format: .png, canvas: canvas, refinement: true)
        let jpeg = try image(width: 32, height: 16, pixels: solid([0, 0, 255, 255]))
        let shown = try composition.present(jpeg, format: .jpeg, canvas: canvas, refinement: false)
        #expect(try pixels(shown) == solid([0, 0, 255, 255]))
        let next = try composition.present(motion, format: .h264, canvas: canvas, refinement: false)
        #expect(try pixels(next) == solid([80, 80, 80, 255]))
    }

    @Test func actualH264CaretMustRetainEveryUnmodifiedPNGChannelExactly() throws {
        let width = 128, height = 96
        let canvas = CGSize(width: width, height: height)
        let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 0, 255, 255], [0, 255, 0, 255],
                                 [255, 0, 255, 255], [0, 255, 255, 255], [255, 255, 255, 255]]
        var source = [UInt8]()
        source.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width { source.append(contentsOf: colors[(x + y * 3) % colors.count]) }
        }
        let original = try image(width: width, height: height, pixels: source)
        let encoder = SurfaceVideoEncoder()
        let video = SurfaceVideoDecoder()
        var composition = SurfaceImageComposition()
        let initial = try #require(try encoder.encode(original, width: width, height: height))
        let first = try SurfaceImageDecoder.decode(initial.data, format: .h264, width: initial.width,
            height: initial.height, canvas: canvas, video: video, refinement: false)
        _ = try composition.present(first, format: .h264, canvas: canvas, refinement: false)
        let sharp = try SurfaceImageDecoder.decode(png(original), format: .png, width: width,
            height: height, canvas: canvas, video: video, refinement: true)
        let settled = try composition.present(sharp, format: .png, canvas: canvas, refinement: true)
        #expect(try pixels(settled) == source)
        var changed = source
        for y in 80..<90 {
            let offset = (y * width + 120) * 4
            changed.replaceSubrange(offset..<(offset + 4), with: [0, 0, 0, 255])
        }
        let predicted = try #require(try encoder.encode(image(width: width, height: height, pixels: changed),
            width: width, height: height))
        #expect(predicted.data[4] == 0)
        let decoded = try SurfaceImageDecoder.decode(predicted.data, format: .h264, width: predicted.width,
            height: predicted.height, canvas: canvas, video: video, refinement: false)
        let visible = try composition.present(decoded, format: .h264, canvas: canvas, refinement: false)
        try #require(visible.width == 128 && visible.height == 96)
        let actual = try pixels(visible)
        var unchangedChannelMaximumError = 0
        for index in source.indices where source[index] == changed[index] {
            unchangedChannelMaximumError = max(unchangedChannelMaximumError, abs(Int(actual[index]) - Int(source[index])))
        }
        #expect(unchangedChannelMaximumError == 0)
    }
}

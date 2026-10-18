import Foundation
import CoreGraphics

/// A value snapshot of accepted display pixels and their separate decoded motion reference.
public struct SurfaceImageComposition: @unchecked Sendable {
    private enum Failure: Error { case invalidImage }

    private struct Raster {
        static let space = CGColorSpace(name: CGColorSpace.sRGB)!
        static let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let width: Int
        let height: Int
        let pixels: Data

        init(_ image: CGImage) throws {
            let width = image.width
            let height = image.height
            var pixels = Data(count: width * height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: Self.space,
                    bitmapInfo: Self.bitmap) else { throw Failure.invalidImage }
                context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        init(width: Int, height: Int, pixels: Data) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        func image() throws -> CGImage {
            guard let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: Self.space, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmap),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw Failure.invalidImage
            }
            return image
        }
    }

    private var canvas: CGSize?
    private var motion: Raster?
    private var displayed: Raster?
    private var image: CGImage?

    public init() {}

    /// Apply to a copy and commit that copy only if the decoded frame is accepted for display.
    /// A changed motion macroblock replaces all its pixels, including lossy unchanged neighbors.
    /// Native decoded blocks map onto the displayed raster when a PNG has more pixels.
    public mutating func present(_ image: CGImage, format: SurfaceFormat, canvas: CGSize,
                                 refinement: Bool) throws -> CGImage {
        guard image.width > 0, image.height > 0,
              image.width <= SurfaceEvent.Frame.maxPixels / image.height,
              canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0,
              canvas.width.rounded(.towardZero) == canvas.width,
              canvas.height.rounded(.towardZero) == canvas.height,
              canvas.width * canvas.height <= Double(SurfaceEvent.Frame.maxPixels),
              !refinement || (format == .png && image.width == Int(canvas.width) && image.height == Int(canvas.height)) else {
            throw Failure.invalidImage
        }
        if format == .jpeg {
            self = Self()
            return image
        }
        let current = try Raster(image)
        if format == .png {
            if self.canvas != canvas { motion = nil }
            self.canvas = canvas
            displayed = current
            self.image = image
            return image
        }
        guard self.canvas == canvas, let motion, let displayed, let previousImage = self.image,
              motion.width == current.width, motion.height == current.height else {
            self.canvas = canvas
            self.motion = current
            self.displayed = current
            self.image = image
            return image
        }
        var pixels = displayed.pixels
        var changed = false
        var result = previousImage
        current.pixels.withUnsafeBytes { currentBytes in
            motion.pixels.withUnsafeBytes { previousBytes in
                let stride = current.width * 4
                for y in Swift.stride(from: 0, to: current.height, by: 16) {
                    let rows = min(16, current.height - y)
                    for x in Swift.stride(from: 0, to: current.width, by: 16) {
                        let rowBytes = min(16, current.width - x) * 4
                        let offset = y * stride + x * 4
                        let differs = (0..<rows).contains { row in
                            memcmp(currentBytes.baseAddress! + offset + row * stride,
                                   previousBytes.baseAddress! + offset + row * stride, rowBytes) != 0
                        }
                        guard differs else { continue }
                        // Ceiling bounds and floor sampling assign each display pixel to one native block.
                        let left = (x * displayed.width + current.width - 1) / current.width
                        let right = ((x + rowBytes / 4) * displayed.width + current.width - 1) / current.width
                        let top = (y * displayed.height + current.height - 1) / current.height
                        let bottom = ((y + rows) * displayed.height + current.height - 1) / current.height
                        guard left < right, top < bottom else { continue }
                        changed = true
                        pixels.withUnsafeMutableBytes { destination in
                            for row in top..<bottom {
                                let sourceY = row * current.height / displayed.height
                                let destinationStart = (row * displayed.width + left) * 4
                                if current.width == displayed.width {
                                    let sourceStart = (sourceY * current.width + left) * 4
                                    memcpy(destination.baseAddress! + destinationStart,
                                           currentBytes.baseAddress! + sourceStart, (right - left) * 4)
                                } else {
                                    for column in left..<right {
                                        let sourceX = column * current.width / displayed.width
                                        let sourceStart = (sourceY * current.width + sourceX) * 4
                                        let destinationOffset = (row * displayed.width + column) * 4
                                        memcpy(destination.baseAddress! + destinationOffset,
                                               currentBytes.baseAddress! + sourceStart, 4)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if changed {
            let composed = Raster(width: displayed.width, height: displayed.height, pixels: pixels)
            result = try composed.image()
            self.displayed = composed
            self.image = result
        }
        self.motion = current
        return result
    }
}

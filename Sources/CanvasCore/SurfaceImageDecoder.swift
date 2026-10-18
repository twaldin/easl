import Foundation
import CoreGraphics
import ImageIO

public enum SurfaceImageDecoder {
    private enum Failure: Error { case invalidImage }

    public static func decode(_ data: Data, format: SurfaceFormat, width: Int, height: Int,
                              canvas: CGSize, video: SurfaceVideoDecoder, refinement: Bool) throws -> CGImage {
        guard width > 0, height > 0, width <= SurfaceEvent.Frame.maxPixels / height,
              canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0,
              canvas.width.rounded(.towardZero) == canvas.width,
              canvas.height.rounded(.towardZero) == canvas.height,
              canvas.width * canvas.height <= Double(SurfaceEvent.Frame.maxPixels) else { throw Failure.invalidImage }
        let canvasWidth = Int(canvas.width), canvasHeight = Int(canvas.height)
        if refinement {
            guard format == .png, width == canvasWidth, height == canvasHeight else { throw Failure.invalidImage }
        }
        let image: CGImage
        if format == .h264 {
            guard !data.isEmpty,
                  data.count <= 48 * 1024 else { throw Failure.invalidImage }
            image = try video.decode(data, width: width, height: height)
        } else {
            let limit = refinement ? SurfaceImageEncoder.refinementBytes : 16 << 20
            guard format == .jpeg || format == .png, !data.isEmpty, data.count <= limit,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height,
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw Failure.invalidImage
            }
            image = decoded
        }
        guard image.width == width, image.height == height else { throw Failure.invalidImage }
        return image
    }
}

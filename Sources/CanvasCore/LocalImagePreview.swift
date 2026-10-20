import CoreGraphics
import Foundation
import ImageIO

struct LocalImagePreview {
    static func read(root: String, path: String, maxPixels: Int) async throws -> HostImagePreview? {
        try Task.checkCancellation()
        let preview = try await offPool {
            Result {
                let file = try HostLocalFile(HostFileRequest(source: .directory(root), policy: .boardImage(path))).read()
                return try make(file, maxPixels: maxPixels)
            }
        }.get()
        try Task.checkCancellation()
        return preview
    }

    private static func make(_ file: HostFile, maxPixels: Int) throws -> HostImagePreview? {
        let data = file.data
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        let type = source.flatMap { CGImageSourceGetType($0) as String? }
        guard let source, type == "public.png" || type == "public.jpeg" else {
            if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]) || data.starts(with: [0xff, 0xd8]) {
                throw HostFileError.unreadable
            }
            return nil
        }
        guard CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let naturalWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let naturalHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              naturalWidth > 0, naturalHeight > 0 else { throw HostFileError.unreadable }
        let animated = type == "public.png" ? try animatedPNG(data) : false
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard naturalWidth <= HostImagePreview.maxNaturalPixels / naturalHeight,
              !animated, orientation == 1, max(naturalWidth, naturalHeight) > maxPixels else { return nil }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw HostFileError.unreadable
        }
        let size = HostImagePreview.dimensions(width: naturalWidth, height: naturalHeight, maxPixels: maxPixels)
        let image: CGImage
        if thumbnail.width == size.width, thumbnail.height == size.height {
            image = thumbnail
        } else {
            guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw HostFileError.unreadable
            }
            context.interpolationQuality = .high
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            guard let scaled = context.makeImage() else { throw HostFileError.unreadable }
            image = scaled
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw HostFileError.unreadable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw HostFileError.unreadable }
        guard output.length < data.count else { return nil }
        return HostImagePreview(data: output as Data, image: image, naturalWidth: naturalWidth, naturalHeight: naturalHeight,
                                width: size.width, height: size.height, version: file.version)
    }

    static func animatedPNG(_ data: Data) throws -> Bool {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 8 else { throw HostFileError.unreadable }
            var offset = 8
            while bytes.count - offset >= 12 {
                let length = Int(UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
                                 UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3]))
                guard length <= bytes.count - offset - 12 else { throw HostFileError.unreadable }
                let type = UInt32(bytes[offset + 4]) << 24 | UInt32(bytes[offset + 5]) << 16 |
                    UInt32(bytes[offset + 6]) << 8 | UInt32(bytes[offset + 7])
                if type == 0x6163544c { return true }
                if type == 0x49444154 { return false }
                offset += length + 12
            }
            throw HostFileError.unreadable
        }
    }
}

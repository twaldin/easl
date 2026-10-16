import AppKit
import ImageIO

/// Image files on disk shown by image tiles, notes (`![alt](path)`) and HTML tiles (`<img src>`):
/// where a path points, whether a page may read it, and the image's natural size.
///
/// An image tile shows whatever file its `path` names (the agent or user chose it). Notes and HTML
/// pages are authored content that may carry any path, so they only reach images in the board root
/// or the temp directories (where agents save scratch charts): `sandboxed(_:root:)`.
public enum LocalImage {
    /// Formats the tiles decode (`NSImage`: bitmaps, SVG, a PDF's first page).
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "pdf"]
    /// Widest an image tile gets from `size: "fit"` (and a create without a frame) unless a width is given.
    public static let defaultMaxWidth: CGFloat = 960
    /// Height of the one-line caption strip under the image (`props.caption`).
    public static let captionHeight: CGFloat = 24

    /// The file an image tile's `path` names: board-relative, absolute, `~/…`, or a `file://` URL.
    public static func tileFile(_ path: String, root: URL) -> URL {
        if let url = URL(string: path), url.isFileURL { return url.standardizedFileURL }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return root.appendingPathComponent(path).standardizedFileURL
    }

    /// The image a note or page may show for `source` (a path, `file://` URL, or a page's request
    /// path): board-relative inside the root, or absolute inside the root or a temp directory, even
    /// after symlinks resolve, with an image extension. Nil for anything else (other schemes,
    /// `..` escapes, files elsewhere on disk).
    public static func sandboxed(_ source: String, root: URL, tempDirectories: [String] = FollowFilter.tempDirectories) -> URL? {
        guard let path = candidate(source, root: root.path) else { return nil }
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard extensions.contains(resolved.pathExtension.lowercased()) else { return nil }
        let allowed = [root.path] + tempDirectories
        guard allowed.contains(where: { contains(URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path, resolved.path) }) else { return nil }
        return resolved
    }

    /// A page's `<img src>` request (`canvas-kit://html/<path>`): the board file at that path, else
    /// the absolute path itself (the study's `<img src="/tmp/…/chart.png">`), each by `sandboxed`.
    public static func pageFile(requestPath: String, root: URL) -> URL? {
        let relative = String(requestPath.drop(while: { $0 == "/" }))
        if let file = sandboxed(relative, root: root), FileManager.default.fileExists(atPath: file.path) { return file }
        return sandboxed(requestPath, root: root)
    }

    static func candidate(_ source: String, root: String) -> String? {
        let decoded = source.removingPercentEncoding ?? source
        guard !decoded.isEmpty, !decoded.contains("\0") else { return nil }
        if let url = URL(string: source), let scheme = url.scheme {
            guard scheme == "file" else { return nil }
            return url.path
        }
        if decoded.hasPrefix("/") { return decoded }
        guard !decoded.hasPrefix("~") else { return nil }
        return root + "/" + decoded
    }

    public static func hostPageFile(requestPath: String, source: HostFileRequest.Source, temps: [String]) -> HostFileRequest? {
        let relative = String(requestPath.drop(while: { $0 == "/" }))
        let relativePath = candidate(relative, root: "/")
        let absolute = candidate(requestPath, root: "/")
        guard relativePath != nil || absolute != nil else { return nil }
        return HostFileRequest(source: source, policy: .pageImage(
            relative: relativePath.map { String($0.drop(while: { $0 == "/" })) },
            absolute: absolute, temps: temps))
    }

    /// Natural size in points: one point per pixel for bitmaps (a 1280×960 chart is 1280×960 pt),
    /// the document size for SVG and a PDF's first page. Reads only the header of a bitmap. Nil when
    /// the file isn't a readable image. Blocking: call off the main thread.
    nonisolated public static func naturalSize(of url: URL) -> CGSize? {
        let type = url.pathExtension.lowercased()
        if type != "svg", type != "pdf", let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Double, let height = properties[kCGImagePropertyPixelHeight] as? Double,
           width > 0, height > 0 {
            // EXIF orientations 5–8 are rotated a quarter turn.
            let rotated = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            return rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image.size
    }

    /// The file's bytes and natural size, read off the main thread. Nil when unreadable.
    public static func read(_ url: URL) async -> (data: Data, size: CGSize)? {
        await offPool {
            guard let data = try? Data(contentsOf: url), let size = naturalSize(of: url) else { return nil }
            return (data, size)
        }
    }

    /// The image's size scaled down (never up) to `maxWidth`, whole points.
    public static func fitted(_ natural: CGSize, maxWidth: CGFloat) -> CGSize {
        let width = min(natural.width, maxWidth)
        return CGSize(width: max(1, width.rounded()), height: max(1, (natural.height * width / natural.width).rounded()))
    }

    /// `path` is `directory` or inside it (a name prefix isn't containment).
    private static func contains(_ directory: String, _ path: String) -> Bool {
        directory == "/" || path == directory || path.hasPrefix(directory + "/")
    }
}

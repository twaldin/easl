import AppKit
import Foundation
import ImageIO
import Testing
import CanvasCore

/// Image tiles, and the images notes and HTML pages may show.
@MainActor
final class ImageTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-img-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
    var root: URL { dir.appendingPathComponent("root") }

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A `width`×`height` pixel PNG at `url`.
    func png(_ url: URL, width: Int, height: Int) throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func notesAndPagesReachImagesOnlyInTheBoardRootOrTheTempDirectory() throws {
        let scratch = dir.appendingPathComponent("scratch")
        let elsewhere = dir.appendingPathComponent("elsewhere")
        for directory in [scratch, elsewhere] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try png(root.appendingPathComponent("out/chart.png"), width: 4, height: 2)
        try png(scratch.appendingPathComponent("fig.png"), width: 4, height: 2)
        try png(elsewhere.appendingPathComponent("secret.png"), width: 4, height: 2)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"), withDestinationURL: elsewhere.appendingPathComponent("secret.png"))
        try "x".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        func allowed(_ source: String) -> Bool { LocalImage.sandboxed(source, root: root, tempDirectories: [scratch.path]) != nil }

        #expect(allowed("out/chart.png"))
        #expect(allowed("./out/chart.png"))
        #expect(allowed(root.appendingPathComponent("out/chart.png").path))
        #expect(allowed("file://" + root.appendingPathComponent("out/chart.png").path))
        #expect(allowed(scratch.appendingPathComponent("fig.png").path))
        // Outside both, by path, `..`, `file://`, or a symlink that leads out.
        #expect(!allowed(elsewhere.appendingPathComponent("secret.png").path))
        #expect(!allowed("../elsewhere/secret.png"))
        #expect(!allowed("file://" + elsewhere.appendingPathComponent("secret.png").path))
        #expect(!allowed("link.png"))
        // Not an image, or not a file.
        #expect(!allowed("notes.txt"))
        #expect(!allowed("https://example.com/chart.png"))
        #expect(!allowed("data:image/png;base64,AAAA"))

        // A page's request path is board-relative first, else the absolute path it spells.
        #expect(LocalImage.pageFile(requestPath: "/out/chart.png", root: root) == root.appendingPathComponent("out/chart.png"))
        #expect(LocalImage.pageFile(requestPath: "/obj_01ABC", root: root) == nil)
        #expect(LocalImage.pageFile(requestPath: "/Library/Desktop Pictures/x.png", root: root) == nil)
    }

    @Test func anImageFitsItsPictureCappedAtItsWidth() async throws {
        try png(root.appendingPathComponent("out/chart.png"), width: 1200, height: 675)
        func size(_ props: JSONValue, width: Double? = nil) async throws -> CGSize {
            try await ObjectMeasure.size(type: .image, props: props, width: width, root: root)
        }
        let title = RenderMath.tileTitleHeight
        // One point per pixel, scaled down to 960 by default; the caption strip adds its line.
        #expect(try await size(.object(["path": "out/chart.png"])) == CGSize(width: 960, height: title + 540))
        #expect(try await size(.object(["path": "out/chart.png", "caption": "Figure 1"])) == CGSize(width: 960, height: title + 540 + LocalImage.captionHeight))
        #expect(try await size(.object(["path": "out/chart.png"]), width: 400) == CGSize(width: 400, height: title + 225))
        // Never scaled up past its pixels.
        #expect(try await size(.object(["path": "out/chart.png"]), width: 2000) == CGSize(width: 1200, height: title + 675))
        await #expect(throws: ObjectMeasure.Failure.self) { try await size(.object(["path": "out/missing.png"])) }
    }

    @Test func inMemoryBitmapSizeUsesPixelsAndEXIFOrientationRatherThanDPI() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4,
                                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = try #require(rep.cgImage)
        for orientation in 1...8 {
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, "public.tiff" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyOrientation: orientation,
                kCGImagePropertyDPIWidth: 144,
                kCGImagePropertyDPIHeight: 144,
            ] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            let expected = orientation >= 5 ? CGSize(width: 12, height: 30) : CGSize(width: 30, height: 12)
            #expect(LocalImage.naturalSize(of: data as Data) == expected, "EXIF orientation \(orientation)")
        }
    }

    @Test func inMemoryVectorImagesKeepTheirDocumentSize() throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="240" height="90" viewBox="0 0 24 9"><rect width="24" height="9" fill="red"/></svg>"#.utf8)
        #expect(LocalImage.naturalSize(of: svg) == CGSize(width: 240, height: 90))

        let pdf = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: pdf as CFMutableData))
        var page = CGRect(x: 0, y: 0, width: 180, height: 72)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &page, nil))
        context.beginPDFPage(nil)
        context.fill(page)
        context.endPDFPage()
        var secondPage = CGRect(x: 0, y: 0, width: 300, height: 200)
        let secondBox = NSData(bytes: &secondPage, length: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: secondBox] as CFDictionary)
        context.fill(secondPage)
        context.endPDFPage()
        context.closePDF()
        #expect(LocalImage.naturalSize(of: pdf as Data) == CGSize(width: 180, height: 72))
        #expect(LocalImage.naturalSize(of: Data("not an image".utf8)) == nil)
    }

    @Test func aNoteGrowsToShowItsImage() async throws {
        try png(root.appendingPathComponent("out/chart.png"), width: 600, height: 300)
        func height(_ markdown: String) async throws -> CGFloat {
            try await ObjectMeasure.size(type: .note, props: .object(["markdown": .string(markdown)]), width: 400, root: root).height
        }
        let plain = try await height("Chart:\n\n![chart](out/missing.png)")
        let shown = try await height("Chart:\n\n![chart](out/chart.png)")
        // The picture is scaled to the note's text width (about 380 of its 600 pixels): ~190 pt tall.
        #expect(shown - plain > 150)
        #expect(shown - plain < 220)
    }

    @Test func aMentionedImagePointNamesThePixelAndTheImageSize() async throws {
        try png(root.appendingPathComponent("out/chart.png"), width: 1200, height: 675)
        let board = Board(id: "brd_test", root: root)
        let tile = board.create(type: .image, props: .object(["path": "out/chart.png"]), frame: Frame(x: 0, y: 0, w: 960, h: 566))
        let mention = try board.stage(.image(object: tile.id, path: "out/chart.png", x: 600, y: 337))
        #expect(mention.label == "out/chart.png at (600, 337)")
        let context = await board.drain().context
        #expect(context.contains("[1] image out/chart.png · pixel (600, 337) of 1200×675, from its top-left · tile \(tile.id)"), "\(context)")
    }
}

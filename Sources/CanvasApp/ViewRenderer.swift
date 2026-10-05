import AppKit
import CanvasCore

/// `view.render`: part of the board drawn offscreen at a fixed scale, independent of the
/// viewport (which it never touches). Everything is drawn from models into one bitmap:
/// the canvas background, groups, tiles (chrome here, content from each tile's `render`), then
/// shapes and arrows. App chrome (toolbar, tray, hints, rings, attention markers) never is.
extension CanvasView {
    private struct TileJob {
        let object: CanvasObject
        let content: any TileContent
        let request: TileRenderRequest
    }

    func render(_ request: RenderRequest, format: ImageFormat) async throws -> RenderOutput {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let deadline = ContinuousClock.now + request.timeout
        let excluded = request.exclude
        let origin = CanvasDocumentView.origin

        // Routes as the next frame draws them (a new `avoid` arrow's, not its provisional line):
        // an arrow's outline can decide the region.
        board.settleArrows?()
        // Targets first: with `full` their rendered content decides the region.
        var renders: [ObjectID: TileRender] = [:]
        var outlines: [ObjectID: Frame] = [:]
        let region: Frame
        switch request.target {
        case .rect(let rect):
            region = RenderMath.snapped(rect, padding: request.padding)
        case .objects(let ids):
            let scale = RenderMath.fittedScale(request.scale, for: RenderMath.union(ids.compactMap { outline(of: $0) }) ?? Frame(x: 0, y: 0, w: 1, h: 1))
            let jobs = ids.compactMap { id in tileJob(id, scale: scale, full: request.full, appearance: appearance) }
            renders = await renderTiles(jobs, deadline: deadline)
            for id in ids {
                guard var frame = outline(of: id) else { continue }
                if let object = board.objects[id], let render = renders[id], request.full {
                    // Grown in the content's own points, then zoomed like the tile's body.
                    let grown = RenderMath.extended(object.naturalFrame, body: RenderMath.body(of: object), content: render.image?.size ?? render.contentSize)
                    let size = ObjectZoom.zoomed(CGSize(width: grown.w, height: grown.h), zoom: object.zoom)
                    frame = Frame(x: frame.x, y: frame.y, w: size.width, h: size.height)
                }
                outlines[id] = frame
            }
            // An arrow between two targets is part of what they show: the region takes its whole
            // route, so a detour around a tile is never cropped to a stub beside them.
            let targets = Set(ids)
            let between = board.objects.values.filter { object in
                guard object.type == .arrow, !targets.contains(object.id), !excluded.hides(object), let spec = ArrowSpec(object.props) else { return false }
                return [spec.from.objectID, spec.to.objectID].allSatisfy { $0.map(targets.contains) ?? false }
            }
            guard let union = RenderMath.union(Array(outlines.values) + between.compactMap { outline(of: $0.id) }) else {
                throw ApiRouter.Failure("not_found", "nothing to render: the targets have no area")
            }
            region = RenderMath.snapped(union, padding: request.padding)
        }
        let scale = RenderMath.fittedScale(request.scale, for: region)
        let docRegion = NSRect(x: region.x + origin.x, y: region.y + origin.y, width: region.w, height: region.h)

        // Everything else under the region.
        let others = board.objects.values.filter { object in
            TileFactory.hasTile(object.type) && renders[object.id] == nil && !excluded.hides(object)
                && object.frame.intersects(region)
        }
        let otherRenders = await renderTiles(others.compactMap { tileJob($0.id, scale: scale, full: false, appearance: appearance) }, deadline: deadline)
        renders.merge(otherRenders) { first, _ in first }

        let size = RenderMath.pixelSize(region, scale: scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size.width, pixelsHigh: size.height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmap = NSGraphicsContext(bitmapImageRep: rep) else {
            throw ApiRouter.Failure("unavailable", "cannot allocate a \(size.width)×\(size.height) image")
        }
        let context = NSGraphicsContext(cgContext: bitmap.cgContext, flipped: true)
        let cg = context.cgContext
        // Document coordinates → image pixels, top-left origin.
        cg.translateBy(x: 0, y: CGFloat(size.height))
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -docRegion.minX, y: -docRegion.minY)

        var drawn: [RenderedObject] = []
        func record(_ object: CanvasObject, _ frame: Frame, _ render: TileRender? = nil) {
            // Content lays out in its own points; the report is in canvas points, like `frame`.
            let zoom = CGFloat(object.zoom), natural = RenderMath.body(of: object)
            let body = CGSize(width: natural.width * zoom, height: natural.height * zoom)
            let content = render.map { CGSize(width: $0.contentSize.width * zoom, height: $0.contentSize.height * zoom) }
            drawn.append(RenderedObject(
                id: object.id, type: object.type, pixelRect: RenderMath.pixelRect(frame, in: region, scale: scale),
                state: render?.state ?? .rendered, reason: render?.reason,
                contentSize: content, overflow: content.flatMap { RenderMath.overflow(content: $0, body: body) }))
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            if request.chrome {
                CanvasDocumentView.drawBackground(in: docRegion, pointsPerUnit: scale, pixelsPerPoint: 1)
            } else {
                NSColor.underPageBackgroundColor.setFill()
                docRegion.fill()
            }

            for group in board.objects.values.filter({ $0.type == .group && !excluded.hides($0) }).sorted(by: { $0.z < $1.z }) {
                guard let rect = groupRegion(group), rect.intersects(docRegion) else { continue }
                guard let view = GroupView(object: group) else { continue }
                view.show(region: rect)
                view.author = request.chrome ? authorName(of: group) : nil
                cg.saveGState()
                cg.translateBy(x: rect.minX, y: rect.minY)
                view.draw(view.bounds)
                cg.restoreGState()
                record(group, Frame(x: rect.minX - origin.x, y: rect.minY - origin.y, w: rect.width, h: rect.height))
            }

            // `full` targets extend past their frames over whatever lies there, so they paint last,
            // above drawn objects too.
            let extended = request.full ? Set(outlines.keys) : []
            let tiled = board.objects.values.filter { renders[$0.id] != nil }.sorted { $0.z < $1.z }
            @MainActor func paint(_ object: CanvasObject) {
                guard let render = renders[object.id] else { return }
                let frame = outlines[object.id] ?? object.frame
                // Chrome at 1×, the content at the tile's zoom inside the body.
                cg.saveGState()
                cg.translateBy(x: frame.x + origin.x, y: frame.y + origin.y)
                drawTile(object, render: render, in: NSRect(x: 0, y: 0, width: frame.w, height: frame.h), zoom: CGFloat(object.zoom), chrome: request.chrome)
                cg.restoreGState()
                record(object, frame, render)
            }
            for object in tiled where !extended.contains(object.id) { paint(object) }

            if let layer = shapeLayer as? ShapeLayer {
                for (object, bounds) in layer.renderItems(in: cg, docRect: docRegion, excluding: excluded) {
                    record(object, Frame(x: bounds.minX - origin.x, y: bounds.minY - origin.y, w: bounds.width, h: bounds.height))
                }
            }
            for object in tiled where extended.contains(object.id) { paint(object) }
        }
        NSGraphicsContext.restoreGraphicsState()

        // Encoding a large image takes hundreds of milliseconds; the finished pixels are immutable,
        // so it runs off the main thread and the canvas keeps responding meanwhile.
        guard let image = rep.cgImage else { throw ApiRouter.Failure("internal", "image encoding failed") }
        let encoded = await offPool { Self.encode(image, format: format) }
        guard let encoded else { throw ApiRouter.Failure("internal", "image encoding failed") }
        return RenderOutput(image: encoded, format: format, width: size.width, height: size.height, canvasRect: region, scale: scale, objects: drawn)
    }

    /// Encodes finished pixels; call off the main thread (a large PNG takes hundreds of ms).
    nonisolated static func encode(_ image: CGImage, format: ImageFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    /// Canvas-space outline: a tile's frame, a drawn object's painted bounds, a group's region.
    func outline(of id: ObjectID) -> Frame? {
        guard let object = board.objects[id] else { return nil }
        let origin = CanvasDocumentView.origin
        let doc: NSRect?
        switch object.type {
        case .group: doc = groupRegion(object)
        case .shape, .arrow: doc = shapeOutline?(id) ?? CanvasView.docRect(object.frame)
        default: return object.frame
        }
        return doc.map { Frame(x: $0.minX - origin.x, y: $0.minY - origin.y, w: $0.width, h: $0.height) }
    }

    /// A group's region: its frame wraps its members, padding, and title band.
    private func groupRegion(_ group: CanvasObject) -> NSRect? {
        group.frame.w > 0 && group.frame.h > 0 ? CanvasView.docRect(group.frame) : nil
    }

    /// A tile's content at its natural size, at enough pixels per point for its zoom.
    private func tileJob(_ id: ObjectID, scale: Double, full: Bool, appearance: NSAppearance) -> TileJob? {
        guard let object = board.objects[id], let tile = tiles[id] else { return nil }
        let request = TileRenderRequest(size: RenderMath.body(of: object), scale: scale * object.zoom, full: full, appearance: appearance)
        return TileJob(object: object, content: tile.content, request: request)
    }

    /// Renders tiles concurrently (interleaved on the main actor); one that misses the deadline
    /// is cancelled and reported as a placeholder.
    private func renderTiles(_ jobs: [TileJob], deadline: ContinuousClock.Instant) async -> [ObjectID: TileRender] {
        let running = jobs.map { job in (job.object.id, Task { await Self.render(job, deadline: deadline) }) }
        var results: [ObjectID: TileRender] = [:]
        for (id, task) in running { results[id] = await task.value }
        return results
    }

    /// At the deadline the render is cancelled (tiles then return what they have); one that
    /// still hasn't answered a second later is reported without it.
    private static func render(_ job: TileJob, deadline: ContinuousClock.Instant) async -> TileRender {
        await withCheckedContinuation { (continuation: CheckedContinuation<TileRender, Never>) in
            let once = Once()
            let work = Task {
                let render = await job.content.render(job.request)
                if once.claim() { continuation.resume(returning: render) }
            }
            Task {
                try? await Task.sleep(until: deadline)
                work.cancel()
                try? await Task.sleep(for: .seconds(1))
                if once.claim() { continuation.resume(returning: .placeholder(job.request, "timed out")) }
            }
        }
    }

    /// Tile chrome as `TileFrameView` draws it live (rounded card, title bar, lifecycle badge,
    /// content zoom percentage, close glyph, border) around the content image drawn at `zoom`,
    /// or a labelled stand-in without one. Without `chrome`, as Hide Board Chrome shows it: no
    /// author mark or close glyph.
    private func drawTile(_ object: CanvasObject, render: TileRender, in rect: NSRect, zoom: CGFloat, chrome: Bool) {
        let title = TileFrameView.titleHeight
        let card = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        let bar = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: title)
        NSColor.controlBackgroundColor.setFill()
        bar.fill()
        if object.type == .terminal, let state = object.props["lifecycle"]?["state"]?.string {
            let badge = TileFrameView.badgeColor(state)
            if badge != .clear {
                badge.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 10, y: rect.minY + (title - 10) / 2, width: 10, height: 10), xRadius: 5, yRadius: 5).fill()
            }
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let name = tiles[object.id]?.title ?? TileFrameView.title(for: object)
        let author = chrome ? tiles[object.id]?.author : nil
        // At 100% whatever this client's chrome text scale is: a render is the same for every client.
        let zoomLabel = TileFrameView.zoomLabelFrame(width: rect.width, zoom: Double(zoom), scale: 1)
        let frames = TileFrameView.titleFrames(width: rect.width - (zoomLabel.map { $0.width + 4 } ?? 0), title: name, author: author, scale: 1)
        (name as NSString).draw(in: frames.title.offsetBy(dx: rect.minX, dy: rect.minY), withAttributes: [
            .font: TileFrameView.titleFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
        if let author, let mark = frames.author {
            let tail = NSMutableParagraphStyle()
            tail.lineBreakMode = .byTruncatingTail
            tail.alignment = .right
            // Inset like a label cell's text.
            (AuthorMark.label(author) as NSString).draw(in: mark.offsetBy(dx: rect.minX, dy: rect.minY).insetBy(dx: 2, dy: 0), withAttributes: [
                .font: TileFrameView.authorFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: tail,
            ])
        }
        if let zoomLabel {
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            (ObjectZoom.percent(Double(zoom)) as NSString).draw(in: zoomLabel.offsetBy(dx: rect.minX, dy: rect.minY + 2), withAttributes: [
                .font: TileFrameView.zoomLabelFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered,
            ])
        }
        if chrome {
            ("✕" as NSString).draw(at: NSPoint(x: rect.maxX - 22, y: rect.minY + 5), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        }
        let body = NSRect(x: rect.minX, y: rect.minY + title, width: rect.width, height: rect.height - title)
        if let image = render.image {
            image.drawUpright(in: NSRect(origin: body.origin, size: CGSize(width: min(body.width, image.size.width * zoom), height: min(body.height, image.size.height * zoom))))
        } else {
            NSColor.quaternaryLabelColor.setFill()
            body.fill()
        }
        if render.state != .rendered {
            let label = render.state == .failed ? "render failed" : "not rendered"
            let text = "\(label): \(render.reason ?? "unknown")" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
            let size = text.boundingRect(with: NSSize(width: body.width - 24, height: 200), options: [.usesLineFragmentOrigin], attributes: attributes).size
            let pill = NSRect(x: body.minX + 8, y: body.minY + 8, width: min(body.width - 16, size.width + 16), height: size.height + 10)
            NSColor.systemOrange.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            text.draw(with: pill.insetBy(dx: 8, dy: 5), options: [.usesLineFragmentOrigin], attributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()
    }

    // MARK: view.snapshot metadata

    /// Objects at least partly visible, bottom to top, in `view.snapshot` image pixels.
    func visibleObjects(pixelsPerPoint: Double) -> [RenderedObject] {
        let region = viewport.rect
        let scale = pixelsPerPoint * magnification
        var objects: [(z: (Int, Double), object: CanvasObject, frame: Frame)] = []
        for object in board.objects.values {
            guard let frame = outline(of: object.id), frame.intersects(region) else { continue }
            let layer = object.type == .group ? 0 : TileFactory.hasTile(object.type) ? 1 : 2
            objects.append(((layer, object.z), object, frame))
        }
        return objects.sorted { $0.z < $1.z }.map { entry in
            RenderedObject(id: entry.object.id, type: entry.object.type, pixelRect: RenderMath.pixelRect(entry.frame, in: region, scale: scale), state: .rendered)
        }
    }
}

/// First caller wins (a render or its deadline).
@MainActor
private final class Once {
    private var claimed = false

    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}

import AppKit
import CanvasCore

/// Pointer and keyboard handling for the drawing tools.
extension ShapeLayer {
    static let minimumDrag: CGFloat = 6
    static let defaultShapeSize = NSSize(width: 160, height: 100)

    // MARK: Keyboard

    /// Tool shortcuts only when the canvas itself has the keyboard, never while a terminal, text
    /// view, or other tile content is first responder.
    var canvasHasKeyboard: Bool {
        guard let window else { return false }
        let responder = window.firstResponder
        if responder == nil || responder === window { return true }
        return responder === canvas || responder === canvas.contentView || responder === canvas.document
    }

    /// The layer is never first responder, so tool keys arrive here: the window offers key downs
    /// to its views as potential key equivalents (verified with real posted key events).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKey(event) || super.performKeyEquivalent(with: event)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, canvasHasKeyboard, editor == nil else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 53 {  // Escape: ends a drawing gesture or tool; otherwise the canvas's (deselect, exit group)
            guard gesture != nil || tool != .select else { return false }
            cancelGesture()
            tool = .select
            return true
        }
        // A selected changes tile's keys are its own (r discards there, never the rectangle tool).
        if canvas.selectedChangesTile != nil, ChangesTile.isOwnKey(event) { return false }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), let match = Tool.allCases.first(where: { $0.key == key }) else { return false }
        tool = match
        return true
    }

    // MARK: Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let handle = handle(at: point), let item = items[handle.id] {
            gesture = .resize(id: handle.id, anchor: handle.anchor, frame: item.frame)
            return
        }
        switch tool {
        case .select:
            // Single clicks select and move through the scene; it passes double-clicks on drawn
            // objects through to here for editing.
            guard event.clickCount >= 2, let item = item(at: point) else { return }
            beginEditing(item.object)
        case .rect, .ellipse:
            gesture = .box(tool: tool, start: point, current: point)
        case .arrow:
            gesture = .arrow(from: binding(at: point), start: point, current: point)
        case .ink:
            let pressured = event.subtype == .tabletPoint
            gesture = .ink(points: [inkPoint(point, event, pressured)], pressured: pressured)
        case .text:
            // Clicking a text shape edits it; a click elsewhere starts a growing text, a drag
            // one that wraps at the dragged width (on release).
            if let item = item(at: point), item.shape?.kind == .text {
                beginEditing(item.object)
            } else {
                gesture = .box(tool: .text, start: point, current: point)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let current = gesture else { return }
        let before = gestureBounds
        switch current {
        case .box(let tool, let start, _):
            gesture = .box(tool: tool, start: start, current: point)
        case .arrow(let from, let start, _):
            gesture = .arrow(from: from, start: start, current: point)
        case .ink(var points, let pressured):
            points.append(inkPoint(point, event, pressured))
            gesture = .ink(points: points, pressured: pressured)
        case .resize(let id, let anchor, _):
            guard let object = board.objects[id] else { break }
            if ShapeSpec(object.props)?.kind == .text {
                // A text shape's corner scales it: box and font together.
                let scaled = Self.scaledText(object, anchor: anchor, to: point)
                gesture = .resize(id: id, anchor: anchor, frame: scaled.frame)
                refresh(scaled.object, frameOverride: scaled.frame)
            } else {
                let resized = Self.rect(anchor, point)
                gesture = .resize(id: id, anchor: anchor, frame: resized)
                refresh(object, frameOverride: resized)
            }
            reroute(boundTo: id)
        }
        invalidate(before.union(gestureBounds))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let finished = gesture else { return }
        invalidate(gestureBounds)
        gesture = nil
        switch finished {
        case .box(let tool, let start, _):
            var rect = Self.rect(start, point)
            if tool == .text {
                let dragged = rect.width >= Self.minimumDrag * 2
                // A click sets where the first line sits, like a text cursor.
                let size = DrawingStyle.textPointSize
                beginText(at: dragged ? rect.origin : NSPoint(x: start.x, y: start.y - size * 0.7), wrapWidth: dragged ? rect.width : nil)
                return
            }
            if rect.width < Self.minimumDrag && rect.height < Self.minimumDrag {
                rect = NSRect(x: start.x - Self.defaultShapeSize.width / 2, y: start.y - Self.defaultShapeSize.height / 2,
                              width: Self.defaultShapeSize.width, height: Self.defaultShapeSize.height)
            }
            let spec = ShapeSpec(kind: tool == .rect ? .rect : .ellipse, color: color, fill: fill)
            created(board.create(type: .shape, props: spec.props, frame: Self.canvasFrame(rect)))
        case .arrow(let from, let start, _):
            let to = binding(at: point)
            let distinctObjects = from.objectID != nil && to.objectID != nil && from.objectID != to.objectID
            guard hypot(point.x - start.x, point.y - start.y) >= Self.minimumDrag * 2 || distinctObjects else { return }
            createArrow(ArrowSpec(from: from, to: to, color: color))
        case .ink(let points, _):
            createInk(points)
        case .resize(let id, let anchor, let frame):
            if let object = board.objects[id], ShapeSpec(object.props)?.kind == .text {
                let scaled = Self.scaledText(object, anchor: anchor, to: point)
                if scaled.frame != Self.docRect(object.frame) {
                    board.transaction { _ = try? board.update(id, frame: Self.canvasFrame(scaled.frame), props: .object(["textSize": .number(ShapeSpec.textSize(of: scaled.object.props))])) }
                } else {
                    refresh(object)
                    reroute(boundTo: id)
                }
            } else if frame.width >= 4, frame.height >= 4, board.objects[id] != nil {
                board.transaction { _ = try? board.update(id, frame: Self.canvasFrame(frame)) }
            } else if let object = board.objects[id] {
                refresh(object)
                reroute(boundTo: id)
            }
        }
    }

    func cancelGesture() {
        guard gesture != nil else { return }
        invalidate(gestureBounds)
        if case .resize(let id, _, _) = gesture, let object = board.objects[id] {
            gesture = nil
            refresh(object)
            reroute(boundTo: id)
        }
        gesture = nil
    }

    private func inkPoint(_ point: NSPoint, _ event: NSEvent, _ pressured: Bool) -> InkPoint {
        InkPoint(x: point.x, y: point.y, pressure: pressured ? Double(event.pressure) : nil)
    }

    static func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// A text shape resized by a corner drag from `anchor` (the corner that stays put) to `point`:
    /// the drag projected on the box's diagonal gives the ratio, so the box keeps its proportions
    /// and the font (`props.textSize`) grows with it, within `ShapeSpec.textSizeRange`.
    static func scaledText(_ object: CanvasObject, anchor: NSPoint, to point: NSPoint) -> (object: CanvasObject, frame: NSRect) {
        let start = docRect(object.frame)
        let from = ShapeSpec.textSize(of: object.props)
        let diagonal = (x: Double(start.width), y: Double(start.height))
        let drag = (x: Double(abs(point.x - anchor.x)), y: Double(abs(point.y - anchor.y)))
        let projected = (drag.x * diagonal.x + drag.y * diagonal.y) / max(diagonal.x * diagonal.x + diagonal.y * diagonal.y, 1)
        let textSize = min(max(from * projected, ShapeSpec.textSizeRange.lowerBound), ShapeSpec.textSizeRange.upperBound)
        let ratio = textSize / from
        let size = NSSize(width: start.width * ratio, height: start.height * ratio)
        // Grow away from the anchor, toward the dragged corner.
        let x = anchor.x > start.midX ? anchor.x - size.width : anchor.x
        let y = anchor.y > start.midY ? anchor.y - size.height : anchor.y
        var scaled = object
        scaled.props = object.props.merging(.object(["textSize": .number(textSize)]))
        return (scaled, NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    /// How far outside an object an arrow end still binds to it, in screen points: a release
    /// just short of a box's edge means that box.
    static let arrowSnap: CGFloat = 16

    func binding(at point: NSPoint) -> ArrowBinding {
        let snap = Self.arrowSnap / max(canvas.magnification, 0.1)
        var best: (id: ObjectID, z: Double, distance: CGFloat)?
        func consider(_ id: ObjectID, z: Double, frame: NSRect, padding: CGFloat) {
            let distance = frame.insetBy(dx: -padding, dy: -padding).contains(point) ? 0
                : hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
            guard distance <= snap else { return }
            if let previous = best {
                guard distance < previous.distance || distance == previous.distance && (z, id) > (previous.z, previous.id) else { return }
            }
            best = (id, z, distance)
        }
        for item in items.values where item.shape != nil {
            consider(item.object.id, z: item.object.z, frame: item.frame, padding: tolerance)
        }
        for tile in canvas.tiles.values where !tile.isHidden {
            consider(tile.objectID, z: tile.z, frame: tile.frame, padding: 0)
        }
        return best.map { .object($0.id) } ?? .point(Self.canvasPoint(point))
    }

    // MARK: Creation

    private func created(_ object: CanvasObject) {
        tool = .select
        canvas.select(object.id, extend: false)
    }

    private func createArrow(_ spec: ArrowSpec) {
        let route = DrawingGeometry.route(from: arrowEnd(spec.from), to: arrowEnd(spec.to))
        let rect = Self.rect(route.start, route.end)
        created(board.create(type: .arrow, props: spec.props, frame: Self.canvasFrame(rect)))
    }

    private func arrowEnd(_ binding: ArrowBinding) -> DrawingGeometry.ArrowEnd {
        switch binding {
        case .point(let point): .point(Self.docPoint(point))
        case .object(let id, _, _, _): outline(of: id).map { .bound($0) } ?? .point(.zero)
        }
    }

    /// Ink keeps its points object-local; the frame is the stroke's painted bounds.
    private func createInk(_ points: [InkPoint]) {
        guard !points.isEmpty else { return }
        let outline = DrawingInk.outline(points)
        let xs = outline.map(\.x) + points.map { CGFloat($0.x) }
        let ys = outline.map(\.y) + points.map { CGFloat($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let bounds = NSRect(x: floor(minX), y: floor(minY), width: ceil(maxX - floor(minX)), height: ceil(maxY - floor(minY)))
        let local = points.map { point in
            InkPoint(x: (point.x - bounds.minX).rounded(toPlaces: 2), y: (point.y - bounds.minY).rounded(toPlaces: 2), pressure: point.pressure.map { $0.rounded(toPlaces: 3) })
        }
        board.create(type: .shape, props: ShapeSpec(kind: .ink, points: local, color: color).props, frame: Self.canvasFrame(bounds))
    }

    // MARK: Gesture preview

    var gestureBounds: NSRect {
        switch gesture {
        case .box(_, let start, let current):
            return Self.rect(start, current).insetBy(dx: -12, dy: -12)
        case .arrow(_, let start, let current):
            var bounds = Self.rect(start, current).insetBy(dx: -20, dy: -20)
            // The highlight around what the end would bind to.
            if let id = binding(at: current).objectID, let outline = outline(of: id) { bounds = bounds.union(outline.bounds.insetBy(dx: -8, dy: -8)) }
            return bounds
        case .ink(let points, _):
            let xs = points.map { CGFloat($0.x) }
            let ys = points.map { CGFloat($0.y) }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -DrawingGeometry.inkSize * 2, dy: -DrawingGeometry.inkSize * 2)
        case .resize(_, _, let frame):
            return handleArea(frame)
        case nil:
            return .zero
        }
    }

    func drawGesture(in context: CGContext) {
        let ink = inkColor(color, over: gestureBounds)
        switch gesture {
        case .box(let tool, let start, let current):
            let rect = Self.rect(start, current)
            if tool == .text {
                // The text's wrap width being dragged out: a dashed box, as the editor will be.
                context.saveGState()
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1.5 / max(canvas.magnification, 0.1))
                context.setLineDash(phase: 0, lengths: [6 / max(canvas.magnification, 0.1), 4 / max(canvas.magnification, 0.1)])
                context.addRect(rect)
                context.strokePath()
                context.restoreGState()
                return
            }
            context.setStrokeColor(ink.cgColor)
            if tool == .rect { context.addRect(rect) } else { context.addEllipse(in: rect) }
            context.strokePath()
        case .arrow(_, let start, let current):
            let target = binding(at: current)
            if let id = target.objectID, let outline = outline(of: id) {
                // What the end binds to if released here.
                context.saveGState()
                context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor)
                context.setLineWidth(2.5 / max(canvas.magnification, 0.1))
                context.addPath(CGPath(roundedRect: outline.bounds.insetBy(dx: -4, dy: -4), cornerWidth: 6, cornerHeight: 6, transform: nil))
                context.strokePath()
                context.restoreGState()
            }
            let (left, right) = DrawingGeometry.arrowhead(start: start, end: current)
            context.setStrokeColor(ink.cgColor)
            context.move(to: start)
            context.addLine(to: current)
            context.move(to: left)
            context.addLine(to: current)
            context.addLine(to: right)
            context.strokePath()
        case .ink(let points, _):
            if let path = DrawnItem.smoothPolygon(DrawingInk.outline(points, options: {
                var options = DrawingInk.options(for: points)
                options.complete = false
                return options
            }())) {
                context.setFillColor(ink.cgColor)
                context.addPath(path)
                context.fillPath()
            }
        case .resize, nil:
            break
        }
    }

    // MARK: Editing

    /// A new text shape whose text starts at `point`; `wrapWidth` from a drag, nil to grow.
    func beginText(at point: NSPoint, wrapWidth: CGFloat?) {
        editor?.commit()
        let editor = ShapeTextEditor(layer: self, origin: point, wrapWidth: wrapWidth, editing: nil, text: "")
        attach(editor)
    }

    /// Double-click: text shapes and shape labels edit in place; arrows edit label and relation.
    func beginEditing(_ object: CanvasObject) {
        editor?.commit()
        switch object.type {
        case .arrow:
            guard let item = items[object.id], let arrow = item.arrow else { return }
            let at = item.labelRect.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSPoint(x: (arrow.start.x + arrow.end.x) / 2, y: (arrow.start.y + arrow.end.y) / 2)
            attach(ArrowLabelEditor(layer: self, arrow: object, spec: arrow.spec, at: at))
        case .shape:
            guard let spec = ShapeSpec(object.props), spec.kind != .ink else { return }
            let frame = Self.docRect(object.frame)
            attach(ShapeTextEditor(layer: self, origin: frame.origin, editing: object, text: spec.text ?? ""))
        default:
            break
        }
    }

    private func attach(_ editor: ShapeEditing) {
        self.editor = editor
        editor.begin()
        if let id = editor.editing, let item = items[id] { invalidate(item) }
    }

    /// Called by an editor after it committed or cancelled.
    func editorEnded(_ editor: ShapeEditing) {
        guard self.editor === editor else { return }
        self.editor = nil
        if let id = editor.editing, let item = items[id] { invalidate(item) }
        if tool == .text { tool = .select }
    }
}

private extension Double {
    /// Ink points are stored in props; two decimals is well below a device pixel.
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}

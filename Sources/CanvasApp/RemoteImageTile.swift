import AppKit
import CanvasCore

/// A remote board's code, changes, HTML, browser, image or diagram tile (docs/design.md "Client
/// mode"): the host's own drawing of it (`view.render` `inline`, the body below the title bar),
/// redrawn when the host changes the object and on demand (the badge's ↻), with a badge saying
/// it is read-only and drawn by the host. It reads no files, loads no page and keeps nothing on disk.
@MainActor
final class RemoteImageTile: NSView, TileContent {
    private var object: CanvasObject
    private let remote: RemoteSource
    private let picture = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let refresh = NSButton()
    private let badgeRow: NSStackView
    /// The host's last drawing of the body.
    private var image: NSImage?
    private var rendering = false
    /// Asked again while a render ran: one more once it's done.
    private var again = false
    private var scheduled: DispatchWorkItem?

    init(object: CanvasObject, remote: RemoteSource) {
        self.object = object
        self.remote = remote
        badgeRow = NSStackView(views: [badge, refresh])
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        picture.frame = bounds
        picture.autoresizingMask = [.width, .height]
        picture.imageScaling = .scaleAxesIndependently
        picture.imageAlignment = .alignTopLeft
        addSubview(picture)
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.lineBreakMode = .byTruncatingTail
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Redraw on \(remote.host.name)")
        refresh.bezelStyle = .inline
        refresh.isBordered = false
        refresh.controlSize = .small
        refresh.target = self
        refresh.action = #selector(refreshPressed)
        refresh.toolTip = "Ask \(remote.host.name) to draw this tile again"
        badgeRow.orientation = .horizontal
        badgeRow.spacing = 4
        badgeRow.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
        badgeRow.wantsLayer = true
        badgeRow.layer?.cornerRadius = 9
        badgeRow.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        badgeRow.layer?.borderWidth = 1
        badgeRow.layer?.borderColor = NSColor.separatorColor.cgColor
        badgeRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeRow)
        NSLayoutConstraint.activate([
            badgeRow.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            badgeRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badgeRow.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        showBadge(nil)
        draw()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    /// "Read-only · drawn on <host>", or why the last drawing failed.
    private func showBadge(_ problem: String?) {
        badge.stringValue = problem ?? "Read-only · drawn on \(remote.host.name)"
        badge.textColor = problem == nil ? .secondaryLabelColor : .systemRed
        setAccessibilityLabel("\(object.type.rawValue) tile, read-only, drawn on \(remote.host.name)" + (problem.map { ": \($0)" } ?? ""))
    }

    @objc private func refreshPressed() { draw() }

    /// Asks the host for the tile's drawing now (one at a time; a request meanwhile runs after).
    private func draw() {
        scheduled?.cancel()
        scheduled = nil
        guard !rendering else {
            again = true
            return
        }
        rendering = true
        refresh.isEnabled = false
        let id = object.id
        let scale = Double(window?.backingScaleFactor ?? 2)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.rendering = false
                self.refresh.isEnabled = true
                if self.again {
                    self.again = false
                    self.draw()
                }
            }
            do {
                let render = try await self.remote.mirror.render(id, scale: scale)
                guard let image = Self.body(of: render) else {
                    return self.showBadge("\(self.remote.host.name) sent an image this Mac can't read")
                }
                self.image = image
                self.picture.image = image
                self.showBadge(nil)
            } catch {
                self.showBadge("Not drawn: \(BoardMirror.reason(error))")
            }
        }
    }

    /// The part of the host's render under the tile's body (below its title bar, which the tile
    /// frame here draws itself), by where the host had the object when it drew it: the whole
    /// image (the object alone) when the host didn't say.
    static func body(of render: BoardMirror.Render) -> NSImage? {
        guard let source = NSBitmapImageRep(data: render.image)?.cgImage else { return nil }
        let scale = render.scale, title = RenderMath.tileTitleHeight * scale
        let object = render.pixels ?? Frame(x: 0, y: 0, w: Double(source.width), h: Double(source.height))
        let crop = CGRect(x: object.x, y: object.y + title, width: object.w, height: max(scale, object.h - title)).integral
        let cropped = source.cropping(to: crop.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))) ?? source
        return NSImage(cgImage: cropped, size: NSSize(width: Double(cropped.width) / scale, height: Double(cropped.height) / scale))
    }

    func update(_ object: CanvasObject) {
        let changed = object.props != self.object.props || object.frame.w != self.object.frame.w || object.frame.h != self.object.frame.h
        self.object = object
        guard changed else { return }
        // A burst of host changes (a page loading, an agent writing) draws once.
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.draw() }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func setLive(_ live: Bool) {}

    func render(_ request: TileRenderRequest) async -> TileRender {
        guard let image else { return .placeholder(request, "not drawn by \(remote.host.name) yet") }
        let drawn = request.image { bounds in image.drawUpright(in: bounds) }
        return TileRender(image: drawn, contentSize: request.size, state: drawn == nil ? .failed : .rendered)
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? { .object(object.id) }

    func outline(for target: MentionTarget) -> NSRect? { bounds }

    var takesKeyboardFocus: Bool { false }
}

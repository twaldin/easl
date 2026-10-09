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
    /// The asks for the host's drawing (`RemoteDrawing`: one at a time, a burst of changes draws
    /// once, only while the tile is near the view).
    private lazy var drawing = RemoteDrawing(
        object: object.id, mirror: remote.mirror,
        scale: { [weak self] in Double(self?.window?.backingScaleFactor ?? 2) },
        busy: { [weak self] busy in self?.refresh.isEnabled = !busy },
        drawn: { [weak self] outcome in self?.show(outcome) })

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
        drawing.draw()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    /// "Read-only · drawn on <host>", or why the last drawing failed.
    private func showBadge(_ problem: String?) {
        badge.stringValue = problem ?? "Read-only · drawn on \(remote.host.name)"
        badge.textColor = problem == nil ? .secondaryLabelColor : .systemRed
        setAccessibilityLabel("\(object.type.rawValue) tile, read-only, drawn on \(remote.host.name)" + (problem.map { ": \($0)" } ?? ""))
    }

    @objc private func refreshPressed() { drawing.draw() }

    /// The link to the host dropped and is back (`BoardMirror.onRedraw`): asks for a fresh drawing,
    /// now if the tile is near the view, else once it is. The host's read after the drop announces
    /// only objects that changed, so a tile whose drawing failed or went stale meanwhile gets no
    /// other cue.
    func redraw() { drawing.draw() }

    /// What the host answered: its drawing of the body, or why not.
    private func show(_ outcome: RemoteDrawing.Outcome) {
        switch outcome {
        case .success(let render):
            guard let image = Self.body(of: render) else {
                return showBadge("\(remote.host.name) sent an image this Mac can't read")
            }
            self.image = image
            picture.image = image
            showBadge(nil)
        case .failure(let error):
            showBadge("Not drawn: \(BoardMirror.reason(error))")
        }
    }

    /// The part of the host's drawing under the tile's body: the object's pixels below its title
    /// bar, which the tile frame here draws itself.
    static func body(of render: BoardMirror.Render) -> NSImage? {
        let image = render.image, scale = render.scale, title = RenderMath.tileTitleHeight * scale
        let crop = CGRect(x: 0, y: title, width: Double(image.width), height: max(scale, Double(image.height) - title)).integral
        guard let body = image.cropping(to: crop.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) else { return nil }
        return NSImage(cgImage: body, size: NSSize(width: Double(body.width) / scale, height: Double(body.height) / scale))
    }

    func update(_ object: CanvasObject) {
        let changed = object.props != self.object.props || object.frame.w != self.object.frame.w || object.frame.h != self.object.frame.h
        self.object = object
        guard changed else { return }
        drawing.changed()
    }

    /// Near the view or not (`CanvasView.shouldBeLive`): a tile away from it asks the host for nothing.
    func setLive(_ live: Bool) { drawing.setLive(live) }

    func render(_ request: TileRenderRequest) async -> TileRender {
        guard let image else { return .placeholder(request, "not drawn by \(remote.host.name) yet") }
        let drawn = request.image { bounds in image.drawUpright(in: bounds) }
        return TileRender(image: drawn, contentSize: request.size, state: drawn == nil ? .failed : .rendered)
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? { .object(object.id) }

    func outline(for target: MentionTarget) -> NSRect? { bounds }

    var takesKeyboardFocus: Bool { false }
}

import AppKit
import CanvasCore

/// Notes and shapes in the skeleton: text on a card (notes) or an outlined box (shapes).
/// Browser and HTML tiles also land here until their slices replace them; they show their
/// URL/title rather than pretending to render.
@MainActor
final class CardTile: NSView, TileContent {
    private var object: CanvasObject
    private let label = NSTextField(wrappingLabelWithString: "")

    init(object: CanvasObject) {
        self.object = object
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        label.font = .systemFont(ofSize: 13)
        label.isSelectable = false
        label.frame = bounds.insetBy(dx: 10, dy: 8)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func update(_ object: CanvasObject) {
        self.object = object
        apply()
    }

    private func apply() {
        let props = object.props
        switch object.type {
        case .note:
            layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
            layer?.borderWidth = 0
            label.stringValue = props["markdown"]?.string ?? ""
        case .shape:
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.7).cgColor
            layer?.borderWidth = 2
            layer?.cornerRadius = props["kind"]?.string == "ellipse" ? min(bounds.width, bounds.height) / 2 : 6
            label.stringValue = props["text"]?.string ?? ""
            label.alignment = .center
        case .browser:
            label.stringValue = "\((props["title"] ?? props["pageTitle"])?.string ?? "Browser")\n\(props["url"]?.string ?? "")"
        case .html:
            label.stringValue = props["title"]?.string ?? "HTML tile"
        case .video:
            label.stringValue = "\(props["title"]?.string ?? "Video")\n\(props["path"]?.string ?? "")"
        default:
            label.stringValue = object.type.rawValue
        }
    }

    func setLive(_ live: Bool) {}

    func render(_ request: TileRenderRequest) async -> TileRender {
        let image = request.image(of: self)
        return TileRender(image: image, contentSize: request.size, state: image == nil ? .failed : .rendered)
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? { .object(object.id) }

    func outline(for target: MentionTarget) -> NSRect? { bounds }

    var takesKeyboardFocus: Bool { false }
}

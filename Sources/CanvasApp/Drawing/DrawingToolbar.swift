import AppKit
import CanvasCore

/// Window-space drawing toolbar: tools (with their single-key shortcuts), palette, and fill.
/// Its buttons never take keyboard focus, so picking a tool leaves the prompt terminal focused.
@MainActor
final class DrawingToolbar: NSVisualEffectView {
    private unowned let shapeLayer: ShapeLayer
    private var toolButtons: [ShapeLayer.Tool: NSButton] = [:]
    private var swatches: [(name: String?, button: NSButton)] = []
    private let fillButton = NSButton()

    init(layer: ShapeLayer) {
        shapeLayer = layer
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        self.layer?.cornerRadius = 10
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.separatorColor.cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for tool in ShapeLayer.Tool.allCases {
            let button = Self.button(symbol: tool.symbol, tooltip: tool.title)
            button.setButtonType(.pushOnPushOff)
            button.target = self
            button.action = #selector(pickTool(_:))
            button.tag = ShapeLayer.Tool.allCases.firstIndex(of: tool)!
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(Self.separator())
        for (index, entry) in DrawingStyle.palette.enumerated() {
            let button = Self.button(symbol: "circle.fill", tooltip: entry.name.capitalized)
            button.contentTintColor = entry.color
            button.target = self
            button.action = #selector(pickColor(_:))
            button.tag = index
            swatches.append((index == 0 ? nil : entry.name, button))
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(Self.separator())
        fillButton.bezelStyle = .texturedRounded
        fillButton.isBordered = false
        fillButton.refusesFirstResponder = true
        fillButton.target = self
        fillButton.action = #selector(cycleFill(_:))
        fillButton.toolTip = "Fill for rectangles and ellipses"
        stack.addArrangedSubview(fillButton)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        layer.onToolChange = { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AppShortcuts.didChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private static func button(symbol: String, tooltip: String) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.refusesFirstResponder = true
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The active tool sits on an accent pill, so a drawing tool left on is hard to miss.
    @objc private func refresh() {
        for (tool, button) in toolButtons {
            let shortcut = AppShortcuts.current.binding(for: tool.actionID)?.display
            button.toolTip = shortcut.map { "\(tool.title) (\($0))" } ?? tool.title
            let active = tool == shapeLayer.tool
            button.state = active ? .on : .off
            button.contentTintColor = active ? .white : .secondaryLabelColor
            button.layer?.backgroundColor = active ? NSColor.controlAccentColor.cgColor : nil
        }
        for swatch in swatches {
            let selected = swatch.name == shapeLayer.color
            swatch.button.image = NSImage(systemSymbolName: selected ? "record.circle.fill" : "circle.fill", accessibilityDescription: swatch.button.toolTip)
        }
        let symbol: String
        switch shapeLayer.fill {
        case .none: symbol = "square"
        case .semi: symbol = "square.lefthalf.filled"
        case .solid: symbol = "square.fill"
        }
        fillButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Fill")
    }

    @objc private func pickTool(_ sender: NSButton) {
        shapeLayer.tool = ShapeLayer.Tool.allCases[sender.tag]
        refresh()
    }

    /// Also recolors the selected drawn objects.
    @objc private func pickColor(_ sender: NSButton) {
        let name = swatches[sender.tag].name
        shapeLayer.color = name
        shapeLayer.board.transaction {
            for id in shapeLayer.canvas.selection where shapeLayer.items[id] != nil {
                _ = try? shapeLayer.board.update(id, props: .object(["color": name.map(JSONValue.string) ?? .null]))
            }
        }
    }

    /// Cycles none → semi → solid, applied to new shapes and selected rectangles/ellipses.
    @objc private func cycleFill(_ sender: NSButton) {
        let next: ShapeSpec.Fill
        switch shapeLayer.fill {
        case .none: next = .semi
        case .semi: next = .solid
        case .solid: next = .none
        }
        shapeLayer.fill = next
        shapeLayer.board.transaction {
            for id in shapeLayer.canvas.selection where [.rect, .ellipse].contains(shapeLayer.items[id]?.shape?.kind) {
                _ = try? shapeLayer.board.update(id, props: .object(["fill": next == .none ? .null : .string(next.rawValue)]))
            }
        }
    }
}

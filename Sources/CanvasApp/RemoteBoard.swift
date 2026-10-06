import AppKit
import CanvasCore

/// A remote board's window (docs/design.md "Client mode"): the host it mirrors, and how its tiles
/// reach that host. Terminals attach to the host's zmx sessions over ssh; tiles drawn from the
/// host's files or pages show the host's rendering (`RemoteImageTile`).
@MainActor
final class RemoteSource {
    let host: RemoteHost
    let mirror: BoardMirror

    init(host: RemoteHost, mirror: BoardMirror) {
        self.host = host
        self.mirror = mirror
    }

    /// The window's title: the board's name (its root folder, as a local board's window says it) at the host.
    func title(of board: Board) -> String {
        "\(board.root.lastPathComponent) @ \(host.name)"
    }

    /// What a terminal tile runs to show the host's session for `tile`.
    func attachCommand(for tile: ObjectID) -> [String] {
        host.terminalAttachCommand(session: TerminalTile.sessionName(tile))
    }
}

/// The link to a remote board's host, when it isn't online: a banner at the top of the board,
/// "Reconnecting to <host>…" while the link comes back, "<host> is offline" (with ssh's reason
/// and a Try Again button) once it gave up for now. Tiles stay as last seen under it.
@MainActor
final class ConnectionBanner: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let retry = NSButton(title: "Try Again", target: nil, action: nil)
    var onRetry: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.6).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        retry.bezelStyle = .inline
        retry.controlSize = .small
        retry.target = self
        retry.action = #selector(retryPressed)
        let row = NSStackView(views: [label, retry])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.group)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func retryPressed() { onRetry?() }

    /// Shows the banner for `state` (hidden while online). `problem` is why the link is down.
    func show(_ state: EaslConnection.State, host: String, problem: String?) {
        switch state {
        case .online:
            isHidden = true
            return
        case .connecting:
            label.stringValue = "Reconnecting to \(host)…"
            retry.isHidden = true
        case .offline:
            label.stringValue = "\(host) is offline: the board as last seen" + (problem.map { " (\($0))" } ?? "")
            retry.isHidden = false
        }
        let wasHidden = isHidden
        isHidden = false
        if wasHidden {
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: label.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}

import AppKit
import CanvasCore

/// A remote board's window (docs/design.md "Client mode"): the host it mirrors, and how its tiles
/// reach that host. HTML pages run here; terminals attach over ssh where their sessions run.
/// The remaining file-backed tiles show the host's rendering (`RemoteImageTile`).
@MainActor
final class RemoteSource {
    let host: RemoteHost
    let mirror: BoardMirror
    let files: HostFiles

    init(host: RemoteHost, mirror: BoardMirror) {
        self.host = host
        self.mirror = mirror
        files = HostFiles(host: host, master: .named(host.sshTarget, support: AppPaths.support.path))
    }

    /// The window's title: the board's name (its root folder, as a local board's window says it) at the host.
    func title(of board: Board) -> String {
        "\(board.root.lastPathComponent) @ \(host.name)"
    }

    /// Attaches where the terminal runs, checking the board host's ownership labels.
    func attachCommand(for terminal: CanvasObject) -> [String] {
        host.terminalAttachCommand(for: terminal, board: mirror.sessionBoardID, merged: mirror.mergedBoards)
    }
}

extension ViewerWindow {
    /// `controller`'s window as its board's easld asks it (`CanvasWindowController.serveHost`).
    init(_ controller: CanvasWindowController) {
        let terminal = { [weak controller] (id: ObjectID) -> TerminalTile? in controller?.canvas.tiles[id]?.content as? TerminalTile }
        self.init(
            focused: { [weak controller] in controller?.window?.isKeyWindow == true },
            viewState: { [weak controller] in controller?.canvas.viewState },
            render: { [weak controller] request, format in
                guard let canvas = controller?.canvas else { throw ApiRouter.Failure("unavailable", "this board's window closed") }
                return try await canvas.render(request, format: format, hostPictures: false)
            },
            hostPicture: { [weak controller] id in controller?.canvas.showsHostPicture(id) ?? false },
            measureHTML: { [weak controller] props, width in
                guard let controller, let files = controller.remote?.files else { throw ApiRouter.Failure("unavailable", "this board's window closed") }
                return try await HtmlTile.measure(props: props, width: width, remote: controller.board, files: files)
            },
            reload: { [weak controller] id, caller, timeoutMs in
                guard let content = controller?.canvas.tiles[id]?.content else { throw ApiRouter.Failure("unavailable", "browser tile \(id) isn't shown by this viewer") }
                guard let browser = content as? BrowserTile else {
                    throw ApiRouter.Failure("unavailable", "browser tile \(id) shows the host's page, which this viewer doesn't load")
                }
                do {
                    return try await browser.reloadPage(driver: caller, timeoutMs: timeoutMs)
                } catch let error as CmuxError {
                    throw ApiRouter.Failure(error.code, error.message)
                }
            },
            submit: { id, text in await terminal(id)?.submit(text) ?? false },
            surfaceTail: { id, lines in terminal(id)?.surfaceTail(lines: lines) },
            block: { id, index in
                guard let tile = terminal(id) else { throw ApiRouter.Failure("unavailable", "terminal \(id) isn't shown in a window") }
                return try tile.block(index)
            },
            // Gemini CLI pads its title to a fixed width. The terminal's program and pid are its host's.
            status: { id in terminal(id).map { TerminalStatus(title: $0.oscTitle?.trimmingCharacters(in: .whitespaces), lastCommand: $0.lastCommand, focused: $0.isWatched) } })
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

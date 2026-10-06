import AppKit
import CanvasCore

/// File › Open Remote… (docs/design.md "Remote boards"): a sheet listing the tailnet's Macs that
/// are online and the hosts opened before, or any ssh host typed in; then that host's boards
/// (name, root, open on the host, agents), read over its socket relayed by ssh; then the board,
/// which `open` shows. An unreachable host shows as offline, and a Mac without easl running
/// offers to start it. Only the hosts are remembered (`AppPaths.remoteHosts`), never what their
/// boards hold.
@MainActor
final class OpenRemotePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var shown: OpenRemotePanel?

    /// Shows the sheet on `parent` (a window of its own without one); `open` gets the board.
    static func show(over parent: NSWindow?, open: @escaping (RemoteHost, BoardID) -> Void) {
        if let shown { return shown.panel.makeKeyAndOrderFront(nil) }
        let controller = OpenRemotePanel(open: open)
        shown = controller
        controller.present(over: parent)
    }

    private struct HostRow {
        var name: String
        var target: String
        var detail: String
        var online: Bool
    }

    private let open: (RemoteHost, BoardID) -> Void
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 400), styleMask: [.titled], backing: .buffered, defer: false)

    private let hostTable = NSTableView()
    private let hostField = NSTextField()
    private let hostStatus = OpenRemotePanel.note("")
    private var hosts: [HostRow] = []

    private let boardTitle = NSTextField(labelWithString: "")
    private let boardTable = NSTableView()
    private let boardStatus = OpenRemotePanel.note("")
    private let spinner = NSProgressIndicator()
    private lazy var startButton = button("Start easl", #selector(startEasl(_:)))
    private lazy var retryButton = button("Retry", #selector(retry(_:)))
    /// Each step's Return. AppKit keeps a default button's Return in its window
    /// (`defaultButtonCell`), so swapping steps sets it again (`show`).
    private lazy var connectButton = button("Connect", #selector(connect(_:)), key: "\r")
    private lazy var openButton = button("Open", #selector(openBoard(_:)), key: "\r")
    private var boards: [RemoteBoard] = []

    private lazy var hostStep = makeHostStep()
    private lazy var boardStep = makeBoardStep()

    /// The host being shown: its name and ssh target, and once discovered, the host.
    private var target: (name: String, sshTarget: String)?
    private var host: RemoteHost?
    private var connection: EaslConnection?
    private var work: [Task<Void, Never>] = []

    private init(open: @escaping (RemoteHost, BoardID) -> Void) {
        self.open = open
        super.init()
        panel.title = "Open Remote Board"
        panel.isReleasedWhenClosed = false
    }

    private func present(over parent: NSWindow?) {
        show(hostStep)
        loadHosts()
        panel.initialFirstResponder = hostField
        if let parent {
            // Also ended from outside (the window closing): clean up either way.
            parent.beginSheet(panel) { [weak self] _ in self?.ended() }
        } else {
            panel.styleMask.insert(.closable)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
        panel.makeFirstResponder(hostField)
    }

    private func finish() {
        if let parent = panel.sheetParent { return parent.endSheet(panel) }
        panel.orderOut(nil)
        ended()
    }

    private func ended() {
        stop()
        if Self.shown === self { Self.shown = nil }
    }

    /// Ends the connection and whatever was waiting on it.
    private func stop() {
        work.forEach { $0.cancel() }
        work = []
        connection?.close()
        connection = nil
        host = nil
        target = nil
    }

    private func show(_ step: NSView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 400))
        step.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(step)
        NSLayoutConstraint.activate([
            step.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            step.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            step.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            step.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        panel.contentView = container
        panel.defaultButtonCell = (step === hostStep ? connectButton : openButton).cell as? NSButtonCell
    }

    // MARK: Hosts

    private func makeHostStep() -> NSView {
        hostField.placeholderString = "Or an ssh host: name, user@host, or an ssh config alias"
        hostField.target = self
        hostField.action = #selector(connect(_:))
        let table = Self.scroll(hostTable, columns: [("host", "Host", 220), ("detail", "", 360)], height: 200, owner: self)
        hostTable.doubleAction = #selector(connect(_:))
        let cancel = button("Cancel", #selector(cancel(_:)), key: "\u{1b}")
        return Self.column([
            Self.headline("Open a board on another Mac"),
            Self.note("Macs on your tailnet that are online, and hosts you opened before. easl reaches them over ssh."),
            table,
            hostField,
            hostStatus,
            Self.row([NSView(), cancel, connectButton]),
        ])
    }

    private func loadHosts() {
        let recents = RemoteHost.Recents.load(AppPaths.remoteHosts)
        hosts = recents.map { HostRow(name: $0.name, target: $0.sshTarget, detail: "opened before", online: true) }
        hostTable.reloadData()
        hostStatus.stringValue = "Asking Tailscale for the tailnet's Macs…"
        work.append(Task { [weak self] in
            do {
                let peers = try await Tailnet.peers()
                self?.merge(peers, recents: recents)
            } catch {
                self?.hostStatus.stringValue = Self.message(error)
            }
        })
    }

    /// Online Macs first, then hosts opened before that aren't among them (offline when the
    /// tailnet says so).
    private func merge(_ peers: [TailnetPeer], recents: [RemoteHost]) {
        let used = Set(recents.map(\.sshTarget))
        let macs = peers.filter { $0.isMac && $0.online }
        var rows = macs.map { HostRow(name: $0.name, target: $0.name, detail: "Mac, online" + (used.contains($0.name) ? ", opened before" : ""), online: true) }
        for recent in recents where !macs.contains(where: { $0.name == recent.sshTarget }) {
            let peer = peers.first { $0.name == recent.sshTarget }
            rows.append(HostRow(name: recent.name, target: recent.sshTarget, detail: peer.map { $0.online ? "\($0.os), online, opened before" : "offline" } ?? "opened before",
                                online: peer?.online ?? true))
        }
        let selected = hostTable.selectedRow >= 0 && hostTable.selectedRow < hosts.count ? hosts[hostTable.selectedRow].target : nil
        hosts = rows
        hostTable.reloadData()
        if let selected, let index = hosts.firstIndex(where: { $0.target == selected }) { hostTable.selectRowIndexes([index], byExtendingSelection: false) }
        hostStatus.stringValue = macs.isEmpty ? "No Mac on your tailnet is online. Type an ssh host to connect to one anyway." : ""
    }

    @objc private func connect(_ sender: Any?) {
        let typed = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            showBoards(name: typed.split(separator: "@").last.map(String.init) ?? typed, sshTarget: typed)
        } else if hostTable.selectedRow >= 0, hostTable.selectedRow < hosts.count {
            let row = hosts[hostTable.selectedRow]
            showBoards(name: row.name, sshTarget: row.target)
        } else {
            hostStatus.stringValue = "Choose a host, or type one."
        }
    }

    @objc private func cancel(_ sender: Any?) { finish() }

    // MARK: Boards

    private func makeBoardStep() -> NSView {
        boardTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let table = Self.scroll(boardTable, columns: [("name", "Board", 150), ("root", "Root", 290), ("open", "Open", 60), ("agents", "Agents", 60)], height: 220, owner: self)
        boardTable.doubleAction = #selector(openBoard(_:))
        let back = button("Back", #selector(back(_:)))
        let cancel = button("Cancel", #selector(cancel(_:)), key: "\u{1b}")
        return Self.column([
            boardTitle,
            Self.row([spinner, boardStatus]),
            table,
            Self.row([back, NSView(), startButton, retryButton, cancel, openButton]),
        ])
    }

    private func showBoards(name: String, sshTarget: String) {
        NSLog("easl: Open Remote: connecting to %@", sshTarget)
        stop()
        target = (name, sshTarget)
        boards = []
        boardTable.reloadData()
        boardTitle.stringValue = "Boards on \(name)"
        show(boardStep)
        panel.makeFirstResponder(boardTable)
        discover()
    }

    /// Finds the host's socket and TMPDIR over ssh, then connects to its easl.
    private func discover() {
        guard let target else { return }
        busy("Reaching \(target.name) over ssh…")
        work.append(Task { [weak self] in
            do {
                let host = try await RemoteHost.discover(name: target.name, sshTarget: target.sshTarget, support: AppPaths.devRemoteHome)
                guard !Task.isCancelled else { return }
                self?.connect(to: host)
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("easl: Open Remote: %@ unreachable: %@", target.sshTarget, Self.message(error))
                self?.idle("\(target.name) is offline: \(Self.message(error))", retry: true)
            }
        })
    }

    private func connect(to host: RemoteHost) {
        self.host = host
        RemoteHost.Recents.remember(host, in: AppPaths.remoteHosts)
        let connection = host.connection()
        self.connection = connection
        work.append(Task { [weak self] in
            for await state in connection.states() {
                guard let self, self.connection === connection else { return }
                switch state {
                case .connecting: self.busy("Connecting to easl on \(host.name)…")
                case .online: await self.loadBoards(connection, on: host)
                case .offline: self.offline(connection, host: host)
                }
            }
        })
    }

    /// Why `connection` is offline, in the user's terms: ssh couldn't reach the host (status
    /// 255), or it could and nothing answers on easl's socket there.
    private func offline(_ connection: EaslConnection, host: RemoteHost) {
        let problem = connection.problem ?? "no answer"
        // Reasons and counts only: never what the host's boards hold.
        NSLog("easl: Open Remote: %@ offline (relay status %@): %@", host.sshTarget, connection.relayStatus.map(String.init) ?? "none", problem)
        switch connection.relayStatus {
        case 255?: idle("\(host.name) is offline: \(problem)", retry: true)
        case nil: idle("easl on \(host.name) doesn't answer: \(problem)", retry: true)
        default: idle("easl isn't running on \(host.name).", retry: true, start: host.isMac)
        }
    }

    private func loadBoards(_ connection: EaslConnection, on host: RemoteHost) async {
        busy("Reading \(host.name)'s boards…")
        do {
            async let list = connection.request("board.list", timeout: .seconds(20))
            async let agents = connection.request("agent.list", timeout: .seconds(20))
            let rows = RemoteBoard.list(boards: try await list, agents: (try? await agents) ?? .null)
            guard self.connection === connection else { return }
            boards = rows
            boardTable.reloadData()
            if !rows.isEmpty { boardTable.selectRowIndexes([0], byExtendingSelection: false) }
            panel.makeFirstResponder(boardTable)
            let open = rows.filter(\.open).count
            NSLog("easl: Open Remote: %@ online, %d boards, %d open, %d agents", host.sshTarget, rows.count, open, rows.reduce(0) { $0 + $1.agents })
            idle(rows.isEmpty ? "\(host.name) has no boards." : "\(rows.count) board\(rows.count == 1 ? "" : "s"), \(open) open on \(host.name).")
        } catch {
            guard self.connection === connection else { return }
            idle("Couldn't read \(host.name)'s boards: \(Self.message(error))", retry: true)
        }
    }

    @objc private func startEasl(_ sender: Any?) {
        guard let host, let connection else { return }
        busy("Starting easl on \(host.name)…")
        startButton.isHidden = true
        work.append(Task { [weak self] in
            let command = host.startCommand
            let result = await RemoteHost.run(command[0], Array(command.dropFirst()), timeout: 30)
            guard !Task.isCancelled else { return }
            guard result.status == 0 else {
                self?.idle("Couldn't start easl on \(host.name): \(RemoteHost.lastLine(result.errors) ?? "ssh exited with status \(result.status)")", retry: true, start: true)
                return
            }
            // The app takes a few seconds to open its socket: try each second, not on the backoff.
            for _ in 0..<30 where connection.state != .online {
                connection.reconnect()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        })
    }

    @objc private func retry(_ sender: Any?) {
        if let connection { connection.reconnect() } else { discover() }
    }

    @objc private func back(_ sender: Any?) {
        stop()
        show(hostStep)
        panel.makeFirstResponder(hostField)
    }

    @objc private func openBoard(_ sender: Any?) {
        guard let host, boardTable.selectedRow >= 0, boardTable.selectedRow < boards.count else { return }
        let board = boards[boardTable.selectedRow].id
        finish()
        open(host, board)
    }

    private func busy(_ status: String) {
        boardStatus.stringValue = status
        spinner.startAnimation(nil)
        startButton.isHidden = true
        retryButton.isHidden = true
    }

    private func idle(_ status: String, retry: Bool = false, start: Bool = false) {
        boardStatus.stringValue = status
        spinner.stopAnimation(nil)
        retryButton.isHidden = !retry
        startButton.isHidden = !start
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === hostTable ? hosts.count : boards.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        var dim = false
        if tableView === hostTable {
            let host = hosts[row]
            text = column == "host" ? host.name : host.detail
            dim = column == "detail" || !host.online
        } else {
            let board = boards[row]
            switch column {
            case "name": text = board.name + (board.archived ? " (archived)" : "")
            case "root": text = board.root
            case "open": text = board.open ? "open" : "closed"
            default: text = board.open ? "\(board.agents)" : "–"
            }
            dim = board.archived || (column != "name" && column != "root")
        }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let label = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }()
        label.stringValue = text
        label.textColor = dim ? .secondaryLabelColor : .labelColor
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Picking a host in the list is choosing it over what was typed.
        if notification.object as? NSTableView === hostTable, hostTable.selectedRow >= 0 { hostField.stringValue = "" }
    }

    // MARK: Building

    private func button(_ title: String, _ action: Selector, key: String = "") -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        return button
    }

    private static func headline(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        return label
    }

    private static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private static func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private static func scroll(_ table: NSTableView, columns: [(id: String, title: String, width: CGFloat)], height: CGFloat, owner: OpenRemotePanel) -> NSScrollView {
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = owner
        table.delegate = owner
        table.target = owner
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private static func message(_ error: Error) -> String {
        (error as? EaslConnection.Failure)?.message ?? error.localizedDescription
    }
}

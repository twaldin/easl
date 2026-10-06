import AppKit
import CanvasCore

/// One line of the Go to… navigator.
struct NavigatorRow {
    enum Target: Equatable {
        /// Zoom to Fit.
        case allContent
        case object(ObjectID)
        /// A file, relative to the checkout Go to lists (`Board.workingRoot`: the board root, or
        /// its place in the worktree the board was opened from) or absolute, at `lines` when the
        /// query named a line or the row is a symbol: opens a code tile for it.
        case file(String, lines: LineRange?)
        /// A note's heading, by its markdown line: the note shown from there.
        case heading(ObjectID, line: Int)
        /// A line that says what's going on ("Searching symbols…"); choosing it does nothing.
        case status
    }

    let target: Target
    let title: String
    /// The object type, shown small at the trailing edge.
    let kind: String
    /// A terminal's agent lifecycle color (`TileFrameView.badgeColor`).
    let dot: NSColor?
    /// Why the row needs the user (a blocked agent, a marker, a done agent not seen yet): listed
    /// first, flagged.
    var needs: NeedsYouItem.Reason? = nil
    /// Tells rows with the same title apart (terminals: name, command, or directory; code: caption
    /// or group title).
    var subtitle: String? = nil
    /// Also matched by typing, shown or not: a code tile's caption, a terminal's name.
    var terms: [String] = []
    var toolTip: String? = nil
    /// Listed only once something is typed: a note's headings, which would bury the tiles.
    var searchOnly = false

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return !searchOnly }
        return title.localizedCaseInsensitiveContains(query) || kind.localizedCaseInsensitiveContains(query)
            || subtitle?.localizedCaseInsensitiveContains(query) == true || terms.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension CanvasView {
    /// Tiles that need the user first (blocked agents, marked tiles, then done agents not seen
    /// yet: `NeedsYouItem`, flagged, and found by "blocked", "marked", "done", "needs"), then the
    /// Recent locations navigation landed on (`recentNavigatorRows`), then "All content", then
    /// groups, then the other tiles, each in reading order (top to bottom, then left to right),
    /// a note followed by its headings (listed while typing: a long note's sections are
    /// reachable by name). Drawn objects (shapes, arrows) aren't listed.
    func navigatorRows() -> [NavigatorRow] {
        var groups: [(NSRect, NavigatorRow)] = []
        var tiles: [(NSRect, NavigatorRow)] = []
        let needs = NeedsYouItem.all(board.objects, attention: board.attention)
        let needed = Dictionary(needs.enumerated().map { ($0.element.id, ($0.offset, $0.element)) }, uniquingKeysWith: { first, _ in first })
        for object in board.objects.values {
            // Hidden groups (no members left) have no frame.
            guard let rect = docFrame(object.id) else { continue }
            if object.type == .group {
                let title = object.props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled group"
                groups.append((rect, NavigatorRow(target: .object(object.id), title: title, kind: "Group", dot: nil)))
            } else if let tile = self.tiles[object.id] {
                var row = Self.navigatorRow(for: object, shownTitle: tile.title)
                row.terms += [Self.nonEmpty(object.props["caption"]).map(CodeCaption.text), Self.nonEmpty(object.props["name"])].compactMap { $0 }
                tiles.append((rect, row))
            }
        }
        func readingOrder(_ lhs: (NSRect, NavigatorRow), _ rhs: (NSRect, NavigatorRow)) -> Bool {
            lhs.0.minY != rhs.0.minY ? lhs.0.minY < rhs.0.minY : lhs.0.minX < rhs.0.minX
        }
        let titleCounts = Dictionary(tiles.map { ($0.1.title, 1) }, uniquingKeysWith: +)
        var first: [(Int, NavigatorRow)] = []
        var rest: [(NSRect, NavigatorRow)] = []
        for (rect, var row) in tiles {
            guard case .object(let id) = row.target else { continue }
            if titleCounts[row.title, default: 0] > 1 { row.subtitle = distinguishing(id) }
            guard let (rank, item) = needed[id] else {
                rest.append((rect, row))
                continue
            }
            row.needs = item.reason
            if let message = item.message, !message.isEmpty { row.subtitle = message }
            switch item.reason {
            case .blocked: row.terms += ["blocked", "needs you"]
            case .question: row.terms += ["question", "ask", "needs you"]
            case .marked: row.terms += ["marked", "needs you", "attention"]
            case .done: row.terms += ["done", "finished", "needs you"]
            }
            first.append((rank, row))
        }
        let all = NavigatorRow(target: .allContent, title: "All content", kind: "Zoom to Fit", dot: nil)
        func withHeadings(_ row: NavigatorRow) -> [NavigatorRow] {
            guard case .object(let id) = row.target, let object = board.objects[id], object.type == .note else { return [row] }
            return [row] + Self.headingRows(of: object, in: row.title)
        }
        return first.sorted { $0.0 < $1.0 }.flatMap { withHeadings($0.1) } + recentNavigatorRows() + [all] + groups.sorted(by: readingOrder).map(\.1)
            + rest.sorted(by: readingOrder).flatMap { withHeadings($0.1) }
    }

    /// A note's headings as rows that go to them, found by their text or the note's title (the
    /// heading the note's row is already named after isn't listed again).
    private static func headingRows(of note: CanvasObject, in title: String) -> [NavigatorRow] {
        NoteMarkdown.headings(in: NoteMarkdown.parse(note.props["markdown"]?.string ?? "")).filter { $0.title != title }.map { heading in
            NavigatorRow(target: .heading(note.id, line: heading.line), title: heading.title, kind: "Heading", dot: nil, subtitle: title, searchOnly: true)
        }
    }

    private static func nonEmpty(_ value: JSONValue?) -> String? { value?.string.flatMap { $0.isEmpty ? nil : $0 } }

    /// What tells two tiles with the same title apart. A terminal: its name, else the command it
    /// was started with, else its directory. Anything else: its caption, else the title of the
    /// group that lists it directly.
    private func distinguishing(_ id: ObjectID) -> String? {
        guard let object = board.objects[id] else { return nil }
        if object.type == .terminal {
            if let name = Self.nonEmpty(object.props["name"]) { return name }
            let command = object.props["command"]?.array?.compactMap(\.string).joined(separator: " ") ?? ""
            if !command.isEmpty { return command }
            return Self.nonEmpty(object.props["cwd"]).map { ($0 as NSString).abbreviatingWithTildeInPath }
        }
        // Pages with one title: their addresses, without the scheme.
        if object.type == .browser, let url = Self.nonEmpty(object.props["url"]) {
            return url.replacingOccurrences(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, with: "", options: .regularExpression)
        }
        if let caption = Self.nonEmpty(object.props["caption"]) { return CodeCaption.plain(caption) }
        let group = board.objects.values.first { $0.type == .group && GroupSpec($0.props)?.members.contains(id) == true }
        return group.flatMap { Self.nonEmpty($0.props["title"]) }
    }

    private static func navigatorRow(for object: CanvasObject, shownTitle: String) -> NavigatorRow {
        let props = object.props
        switch object.type {
        case .terminal:
            let title = shownTitle.isEmpty ? TileFrameView.title(for: object) : shownTitle
            let color = TileFrameView.badgeColor(props["lifecycle"]?["state"]?.string)
            return NavigatorRow(target: .object(object.id), title: title, kind: "Terminal", dot: color == .clear ? nil : color)
        case .code:
            var title = TileFrameView.title(for: object)
            if let start = props["range"]?["start"]?.int {
                let end = props["range"]?["end"]?.int ?? start
                title += end > start ? " · L\(start)–\(end)" : " · L\(start)"
            }
            // Excerpts of one file (a references layout, an agent's call sites) differ by caption.
            return NavigatorRow(target: .object(object.id), title: title, kind: "Code", dot: nil,
                                subtitle: nonEmpty(props["caption"]).map(CodeCaption.plain), toolTip: props["path"]?.string)
        case .note:
            let markdown = props["markdown"]?.string ?? ""
            let line = markdown.split(whereSeparator: \.isNewline).lazy
                .map(NoteMarkdown.plainText(ofLine:))
                .first { !$0.isEmpty }
            let title = props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return NavigatorRow(target: .object(object.id), title: title ?? line ?? "Empty note", kind: "Note", dot: nil)
        case .html:
            return NavigatorRow(target: .object(object.id), title: TileFrameView.title(for: object), kind: "HTML", dot: nil)
        case .changes:
            // The board root's names its branch, known once listed (`Changes: main`).
            return NavigatorRow(target: .object(object.id), title: shownTitle.isEmpty ? TileFrameView.title(for: object) : shownTitle, kind: "Changes", dot: nil)
        case .image:
            // Found by its file too; the caption says which chart it is.
            let path = nonEmpty(props["path"])
            return NavigatorRow(target: .object(object.id), title: TileFrameView.title(for: object), kind: "Image", dot: nil,
                                subtitle: nonEmpty(props["caption"]), terms: path.map { [$0] } ?? [], toolTip: path)
        case .browser:
            // Found by its address too ("localhost"); the host (and port) says which site it is.
            let url = nonEmpty(props["url"])
            let host = url.flatMap(URLComponents.init(string:)).flatMap { parts in parts.host.map { host in parts.port.map { "\(host):\($0)" } ?? host } }
            return NavigatorRow(target: .object(object.id), title: TileFrameView.title(for: object), kind: "Browser", dot: nil,
                                subtitle: host, terms: url.map { [$0] } ?? [], toolTip: url)
        case .question:
            // The question is what it is found by; its title bar names who asks.
            let spec = QuestionSpec(props)
            return NavigatorRow(target: .object(object.id), title: spec.question.isEmpty ? "Question" : spec.question, kind: "Question", dot: nil,
                                subtitle: spec.status == .open ? TileFrameView.title(for: object) : spec.status.rawValue.capitalized, terms: ["question", "ask"])
        default:
            return NavigatorRow(target: .object(object.id), title: TileFrameView.title(for: object), kind: object.type.rawValue.capitalized, dot: nil)
        }
    }
}

/// Go to… (⌘P): a floating search-and-list panel over the board, in the window like the drawing
/// toolbar (not a separate window, never modal). Typing filters, ↑/↓ move, Return or a click
/// goes, Esc or a click anywhere else closes, and so does the field losing the keyboard, so
/// typing never goes anywhere else while the panel shows. Keyboard focus returns to whoever had it.
@MainActor
final class NavigatorPanel: NSVisualEffectView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 28
    static let visibleRows = 10
    private static let fieldHeight: CGFloat = 40

    private let field = NSTextField()
    private let table = NavigatorTable()
    private let list = NSScrollView()
    private let separator = NSBox()
    /// Under the list: why symbols are missing (a language server not installed, with its
    /// install hint). A note, never a row: it isn't somewhere to go.
    private let footer = NSTextField(labelWithString: "")
    private var height: NSLayoutConstraint!
    private var footerHeight: NSLayoutConstraint!
    private var allRows: [NavigatorRow] = []
    private var rows: [NavigatorRow] = []
    private var files = FileIndex(paths: [])
    /// File rows listed below the object rows at most.
    static let maxFileRows = 50
    private weak var previousResponder: NSResponder?
    private var clickMonitor: Any?
    /// Workspace symbols for the current query, once the language servers answered.
    private var symbolRows: (query: String, answer: SymbolAnswer)?
    private var symbolSearch: Task<Void, Never>?

    /// A symbol search's rows, and why there are none when a language server couldn't answer.
    struct SymbolAnswer {
        var rows: [NavigatorRow]
        var note: String? = nil
    }

    var onGo: ((NavigatorRow.Target) -> Void)?
    /// Workspace symbols matching a name (`@name`, or a query nothing else matched).
    var searchSymbols: ((String) async -> SymbolAnswer)?
    var isOpen: Bool { !isHidden }

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        isHidden = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = "Go to…"
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        separator.boxType = .separator
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.wrapAsNote()
        footer.isHidden = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        column.resizingMask = .autoresizingMask
        table.style = .inset
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        // The search field keeps the keyboard; clicks still select and go.
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.onClick = { [weak self] row in self?.go(row) }
        list.documentView = table
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true

        for view in [icon, field, separator, list, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        height = heightAnchor.constraint(equalToConstant: Self.fieldHeight)
        footerHeight = footer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: Self.fieldHeight),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            footerHeight,
            height,
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Open / close

    /// `files`: the board root's files, listed below the objects once something is typed.
    func open(rows: [NavigatorRow], files: FileIndex) {
        guard let window else { return }
        allRows = rows
        self.files = files
        field.stringValue = ""
        isHidden = false
        previousResponder = window.firstResponder
        window.makeFirstResponder(field)
        filter()
        // A press anywhere outside the panel closes it and still does what it does.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
    }

    /// ⌘P while open: the field keeps the keyboard, its text selected to type over. (It always
    /// has it: losing it closes the panel.)
    func focusField() {
        guard isOpen, let window else { return }
        if field.currentEditor() == nil { window.makeFirstResponder(field) }
        field.currentEditor()?.selectAll(nil)
    }

    /// The field lost the keyboard (a terminal or tile took it, Tab moved on): the panel closes
    /// rather than stay open while typing goes elsewhere.
    func controlTextDidEndEditing(_ notification: Notification) {
        close()
    }

    /// Hides the panel and gives the keyboard back to whoever had it before (a terminal through
    /// its own focus path; `CanvasView.returnKeyboard`), unless something else took it meanwhile.
    /// Whether the field had it is read before hiding: hiding the panel takes the focus from its
    /// field, which left the terminal without the keyboard.
    func close() {
        guard isOpen else { return }
        let hadKeyboard = (window?.firstResponder as? NSText)?.delegate === field
        isHidden = true
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        allRows = []
        rows = []
        files = FileIndex(paths: [])
        symbolSearch?.cancel()
        symbolSearch = nil
        pendingSymbols = nil
        symbolRows = nil
        table.reloadData()
        if hadKeyboard, let window { CanvasView.returnKeyboard(to: previousResponder, in: window) }
        previousResponder = nil
    }

    private func go(_ row: Int) {
        guard rows.indices.contains(row), rows[row].target != .status else { return }
        let target = rows[row].target
        close()
        onGo?(target)
    }

    // MARK: Filtering and keys

    /// A newer file listing arrived while open: re-filter, keeping the highlighted row.
    func update(files: FileIndex) {
        guard isOpen else { return }
        self.files = files
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].target : nil
        filter(keeping: selected)
    }

    /// Objects whose title, type, subtitle, caption, or name contain the query, then the files
    /// it fuzzily matches (`FileIndex`), at the line it names (`core.py:1428`). `@name`, or a
    /// name nothing else matched, lists the language servers' workspace symbols instead.
    private func filter(keeping selected: NavigatorRow.Target? = nil) {
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        let query = GoToQuery.parse(raw)
        var found: [NavigatorRow] = []
        if !query.symbol {
            found = allRows.filter { $0.matches(raw) } + files.search(query.text, limit: Self.maxFileRows).map { path in
                let at = query.lines.map { $0.end > $0.start ? ":\($0.start)-\($0.end)" : ":\($0.start)" } ?? ""
                return NavigatorRow(target: .file(path, lines: query.lines), title: path + at, kind: "Open File", dot: nil, toolTip: path)
            }
        }
        let wantsSymbols = !query.text.isEmpty && query.lines == nil && searchSymbols != nil && (query.symbol || found.isEmpty)
        var note: String?
        if wantsSymbols {
            if let symbols = symbolRows, symbols.query == query.text {
                let none = query.symbol ? "No symbols named “\(query.text)”" : "No matches"
                found += symbols.answer.rows.isEmpty ? [NavigatorRow(target: .status, title: none, kind: "", dot: nil)] : symbols.answer.rows
                note = symbols.answer.note
            } else {
                found.append(NavigatorRow(target: .status, title: "Searching symbols…", kind: "", dot: nil))
                lookUpSymbols(named: query.text)
            }
        } else {
            symbolSearch?.cancel()
            symbolSearch = nil
            pendingSymbols = nil
        }
        rows = found
        table.reloadData()
        // The first row that goes somewhere is highlighted; a status line ("No matches") never is.
        let row = selected.flatMap { target in rows.firstIndex { $0.target == target } } ?? rows.firstIndex { $0.target != .status }
        if let row {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        // The inset table style pads above the first row; keep the same room below the last.
        let shown = min(rows.count, Self.visibleRows)
        let listHeight = shown > 0 ? table.rect(ofRow: shown - 1).maxY + table.rect(ofRow: 0).minY : 0
        footer.stringValue = note ?? ""
        footer.wrapAsNote()
        footer.isHidden = note == nil
        // The panel is 560 wide unless the window is narrower; before its first layout, assume 560.
        footerHeight.constant = note == nil ? 0 : max(18, footer.height(atWidth: (bounds.width > 0 ? bounds.width : 560) - 28))
        let footerRoom: CGFloat = note == nil ? 0 : footerHeight.constant + 4
        height.constant = Self.fieldHeight + 1 + (shown > 0 ? listHeight + 8 : 0) + footerRoom
        list.isHidden = rows.isEmpty
        separator.isHidden = rows.isEmpty && note == nil
    }

    /// The name a symbol search is running (or waiting) for.
    private var pendingSymbols: String?

    /// Asks the language servers once typing pauses; the answer re-filters.
    private func lookUpSymbols(named name: String) {
        guard pendingSymbols != name, let searchSymbols else { return }
        symbolSearch?.cancel()
        pendingSymbols = name
        symbolSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let rows = await searchSymbols(name)
            guard let self, !Task.isCancelled, self.isOpen, self.pendingSymbols == name else { return }
            self.pendingSymbols = nil
            self.symbolSearch = nil
            self.symbolRows = (name, rows)
            let selected = self.rows.indices.contains(self.table.selectedRow) ? self.rows[self.table.selectedRow].target : nil
            self.filter(keeping: selected == .status ? nil : selected)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.insertNewline(_:)): go(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func moveSelection(_ step: Int) {
        let goes = rows.indices.filter { rows[$0].target != .status }
        guard let first = goes.first, let last = goes.last else { return }
        let current = table.selectedRow
        let row = step > 0 ? goes.first { $0 > current } ?? last : goes.last { $0 < current } ?? first
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NavigatorCell.identifier, owner: nil) as? NavigatorCell ?? NavigatorCell()
        cell.show(rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        NavigatorRowView()
    }
}

/// Selection stays accent-colored although the table never holds the keyboard.
private final class NavigatorRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class NavigatorCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("navigator.cell")

    private let dot = NSView()
    /// "Blocked" (orange), "Marked" (pink), or "Done" (green): the row needs the user
    /// (`NavigatorRow.needs`).
    private let flag = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let kind = NSTextField(labelWithString: "")
    private var titleAfterFlag: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        flag.font = .systemFont(ofSize: 10, weight: .bold)
        flag.textColor = AttentionStyle.ink
        flag.alignment = .center
        flag.wantsLayer = true
        flag.layer?.cornerRadius = 4
        flag.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 12)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 1), for: .horizontal)
        kind.font = .systemFont(ofSize: 11)
        kind.alignment = .right
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [dot, flag, title, detail, kind] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleAfterFlag = title.leadingAnchor.constraint(equalTo: flag.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            flag.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            flag.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleAfterFlag,
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            kind.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 12),
            kind.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            kind.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// A status line ("Searching symbols…") is quieter than a row that goes somewhere.
    private var muted = false

    func show(_ row: NavigatorRow) {
        muted = row.target == .status
        applyColors()
        title.stringValue = row.title
        title.font = row.target == .allContent ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
        detail.stringValue = row.subtitle ?? ""
        detail.isHidden = detail.stringValue.isEmpty
        toolTip = row.toolTip
        kind.stringValue = row.kind
        dot.layer?.backgroundColor = (row.dot ?? .clear).cgColor
        let color: NSColor? = row.needs.map { needs in
            switch needs {
            case .blocked: AttentionStyle.blocked.color
            case .question: NSColor.controlAccentColor
            case .marked: AttentionStyle.marker.color
            case .done: TileFrameView.badgeColor(LifecycleState.done.rawValue)
            }
        }
        flag.stringValue = row.needs.map { needs in
            switch needs {
            case .blocked: " Blocked "
            case .question: " Ask "
            case .marked: " Marked "
            case .done: " Done "
            }
        } ?? ""
        flag.layer?.backgroundColor = color?.cgColor
        flag.isHidden = color == nil
        titleAfterFlag.constant = color == nil ? 0 : 6
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : muted ? .secondaryLabelColor : .labelColor
        kind.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        detail.textColor = kind.textColor
    }
}

/// Shown at the bottom center while the board has objects but none is in view (panned far
/// away): one button back to them (Zoom to Fit).
@MainActor
final class NothingHerePill: NSVisualEffectView {
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        isHidden = true
        let label = NSTextField(labelWithString: "Nothing here ·")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let button = NSButton(title: "Back to content", target: self, action: #selector(back))
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .controlAccentColor
        button.refusesFirstResponder = true
        let stack = NSStackView(views: [label, button])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func back() {
        onBack?()
    }
}

/// Go to's list: a click on a row (press and release on it) goes there, also while the window
/// isn't key (the first click back from another app, replayed input). The table takes the click
/// itself, never a row's label, and tracks it without AppKit's table tracking, which selected
/// nothing and sent no action for such a click (persona study B18: "Clicking a row in ⌘P Go to…
/// did nothing; arrows + Return worked").
private final class NavigatorTable: NSTableView {
    var onClick: ((Int) -> Void)?
    private var pressed: Int?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        pressed = row >= 0 ? row : nil
        if let pressed { selectRowIndexes([pressed], byExtendingSelection: false) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, row(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        onClick?(pressed)
    }
}

import AppKit
import CanvasCore

@MainActor
final class ChangesTile: NSView, TileContent, NSSearchFieldDelegate, NSViewToolTipOwner {
    private(set) var object: CanvasObject
    private let board: Board
    /// A click on a line opened (`created`) or re-aimed this code tile.
    var onOpenedCode: ((ObjectID, _ created: Bool) -> Void)?
    /// With every listing of the board's own checkout: the branch checked out there (nil when
    /// detached), which the title names.
    var onBranch: ((String?) -> Void)?

    private var set: ChangeSet?
    private var painter: ChangesPainter?
    private var collapsed: Set<String> = []
    /// Files listed before: a deleted or viewed file starts folded the first time it shows up,
    /// and stays as the user leaves it after that.
    private var seen: Set<String> = []
    /// Files folded because they were marked Viewed: they unfold when their diff changes.
    private var viewedFolded: Set<String> = []
    /// The hunk the keys act on, by file and index.
    private var current: (file: Int, hunk: Int)?
    /// Lines picked in one hunk (with the other half of each edited line, `pairedRows`), and
    /// the line a ⇧-click or drag extends from.
    private var selection: (file: Int, hunk: Int, lines: Set<Int>)?
    private var anchor: (file: Int, hunk: Int, line: Int)?
    /// A line pressed and not yet dragged: releasing it opens the line.
    private var pressed: (file: Int, hunk: Int, line: Int)?
    private var dragged = false
    private var filter = ""
    private var listOpen = true
    private var scroll: CGFloat = 0
    private var message: String?
    private var messageWork: DispatchWorkItem?
    private let cache = ChangesLineCache()
    private var filterField: NSSearchField?
    /// Who a trackpad gesture scrolls, decided by its first movement and kept to its end
    /// (momentum included): the tile never hands a gesture to the canvas halfway.
    private var gestureOwner: GestureOwner?
    private enum GestureOwner { case tile, canvas }
    private var toolTipWork: DispatchWorkItem?
    /// The rows of the last painter and what they were laid out for: stepping through hunks or
    /// selecting lines doesn't rewrap every line.
    private var laidOut: (key: LayoutKey, rows: ChangeRows, names: [String])?
    private struct LayoutKey: Equatable {
        var version: Int
        var collapsed: Set<String>
        var columns: Int
        var filter: String
        var listOpen: Bool
    }
    /// Bumped with every listing installed.
    private var setVersion = 0
    /// The base field and its popover while it is open (`askForBase`).
    private weak var baseField: NSTextField?
    private weak var basePopover: NSPopover?

    private var isLive = true
    private var needsLoad = true
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var events: FileEvents?
    private var reloadWork: DispatchWorkItem?
    /// The FSEvents id current when the last load started: that listing already shows every
    /// event up to it (the tile's own Stage or Discard, reloaded at once), so they reload nothing.
    private var loadedThrough: FSEventStreamEventId = 0
    /// The repository this tile holds in the git engine while live, as code tiles do: its bases
    /// stay resolved and watched across listings.
    private var heldRepository: String?
    /// A Stage or Discard is being applied; others wait for it (they'd be built from old rows).
    private var acting = false
    /// The listing after an action: its current hunk scrolls into view.
    private var revealAfterLoad = false

    private let git: HostGit?
    private var hostWatch: HostFileWatch?
    private var hostRetry: Task<Void, Never>?
    private var hostListing: HostChangesLoad?
    private var hostRefShas: [String: String] = [:]

    static let tooltip = reviewTooltip(undo: "Every Stage, Unstage, and Discard is one ⌘Z.")

    static let remoteTooltip = reviewTooltip(undo: "Stage, Unstage, and Discard act on the host's repository; ⌘Z doesn't undo them from here.")

    private static func reviewTooltip(undo: String) -> String {
        """
        Click a line to open it in a code tile; drag over lines, ⇧-click or ⌘-click to select lines (an edited line brings its old version), then Stage, Unstage, or Discard just those; \
        Hyper-click (⌃⌥⇧⌘) a line or hunk header to mention it; click a file's header to fold it, its Viewed box to fold it until it changes; click the summary to pick the base.
        Keys once the tile has the keyboard (↩ or a click): j or ↓ next hunk, k or ↑ previous hunk, J or ] next file, K or [ previous file, \
        / filter files, Return open the hunk in a code tile, s stage, u unstage, r then ⌘⌫ discard, m mention (the selected lines, else the hunk), Esc back to the board.
        Discard asks first: click it again, or press ⌘⌫ after r, to throw the change away; any other key keeps it. \(undo) \
        Discard only puts back work not committed yet: committed hunks have none.
        """
    }

    /// The tooltip of a tile comparing two commits: reading keys only.
    static let readingTooltip = """
    Two commits compared, read from git objects: nothing to stage, unstage, or discard. Click a line to open it in a code tile pinned to its side's commit \
    (a removed line at the base, anything else at the head); drag, ⇧-click or ⌘-click to select lines; Hyper-click (⌃⌥⇧⌘) a line or hunk header to mention it; \
    click a file's header to fold it, its Viewed box to fold it until either side of it changes; click the summary to pick the base.
    Keys once the tile has the keyboard (↩ or a click): j or ↓ next hunk, k or ↑ previous hunk, J or ] next file, K or [ previous file, \
    / filter files, Return open the hunk in a code tile, m mention (the selected lines, else the hunk), Esc back to the board.
    """

    init(object: CanvasObject, board: Board, git: HostGit? = nil) {
        self.object = object
        self.board = board
        self.git = git
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let center = NotificationCenter.default
        if git == nil {
            center.addObserver(self, selector: #selector(repositoryChanged(_:)), name: .gitDiffBaseChanged, object: nil)
            center.addObserver(self, selector: #selector(repositoryChanged(_:)), name: .reviewPatchApplied, object: nil)
        }
        center.addObserver(self, selector: #selector(patchFailed(_:)), name: .reviewPatchFailed, object: object.id)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        if let heldRepository { Task { await GitDiffEngine.shared.release(heldRepository) } }
    }

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        pickHunk(revealing: false)
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        dropDiscardQuestion()
        needsDisplay = true
        return true
    }

    private var hasKeyboard: Bool { window?.firstResponder === self }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if git != nil, window == nil {
            generation += 1
            loadTask?.cancel()
            loadTask = nil
            hostWatch?.cancel()
            hostWatch = nil
            hostRetry?.cancel()
            hostRetry = nil
            reloadWork?.cancel()
            reloadWork = nil
            needsLoad = true
        }
        if window != nil, isLive, needsLoad { load() }
        installFilterField()
        refreshToolTips()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { refreshPainter() }
        layoutFilterField()
        clampScroll()
        scheduleToolTips()
        needsDisplay = true
    }

    private var spec: ChangesSpec { ChangesSpec(object.props) }

    /// Posted off the main thread by the git engine, or on it after a patch applied. The tile's
    /// own stream sees HEAD and ref moves of its repository, so the engine's word on them only
    /// counts while it has none.
    @objc nonisolated private func repositoryChanged(_ note: Notification) {
        let path = note.object as? String, baseMoved = note.name == .gitDiffBaseChanged
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, path == nil || path == self.set?.repository?.path || self.set?.repository == nil else { return }
                if baseMoved, self.events != nil, path != nil, path == self.heldRepository { return }
                self.scheduleReload(after: 0.05)
            }
        }
    }

    @objc nonisolated private func patchFailed(_ note: Notification) {
        let text = note.userInfo?["message"] as? String
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.show(message: text ?? "couldn't apply") }
        }
    }

    // MARK: Loading

    func update(_ object: CanvasObject) {
        var old = ChangesSpec(self.object.props), new = ChangesSpec(object.props)
        let oldViewed = self.object.props["viewed"]
        self.object = object
        // The tile's own `refSha` write-back follows a listing; it asks for none.
        (old.refSha, new.refSha) = (nil, nil)
        if new != old { return load() }
        if object.props["viewed"] != oldViewed { syncViewed(from: oldViewed) }
        refreshPainter()
    }

    /// `props.viewed` changed under the tile (⌘Z of a Viewed check, an agent): files that
    /// became viewed fold, files that stopped being viewed unfold.
    private func syncViewed(from old: JSONValue?) {
        guard let set else { return }
        let viewed = object.props["viewed"]
        for file in set.files {
            let was = file.isViewed(in: old), now = file.isViewed(in: viewed)
            if now, !was {
                collapsed.insert(file.boardPath)
                viewedFolded.insert(file.boardPath)
            } else if was, !now, viewedFolded.remove(file.boardPath) != nil {
                collapsed.remove(file.boardPath)
            }
        }
    }

    /// Lists and diffs the changes (git and parsing off the main thread) and installs them.
    /// Deferred until the tile is live.
    private func load() {
        guard isLive, git == nil || window != nil else {
            needsLoad = true
            return
        }
        needsLoad = false
        if let git { return loadFromHost(git) }
        generation += 1
        loadedThrough = FSEventsGetCurrentEventId()
        let current = generation, root = board.root, spec = spec
        loadTask = Task { [weak self] in
            let set = await ChangeSet.load(root: root, spec: spec)
            let engine = GitDiffEngine.shared
            var held: String?
            if let repository = set.repository { held = await engine.retain(containing: repository.appendingPathComponent(".canvas-changes")) }
            await MainTurns.next()
            guard let self, current == self.generation, self.isLive else {
                if let held { await engine.release(held) }
                return
            }
            self.loadTask = nil
            if let previous = self.heldRepository { Task { await engine.release(previous) } }
            self.heldRepository = held
            let previous = self.set
            self.install(set)
            self.watch(set.repository, refsOnly: set.comparesCommits)
            self.growIfFitted(from: previous, to: set)
            if spec.root == nil, spec.head == nil, spec.ref == nil { self.onBranch?(set.branch) }
            if let ref = spec.ref, let sha = set.refSha { self.board.recordRefSha(self.object.id, ref: ref, sha: sha) }
        }
    }

    private func loadFromHost(_ git: HostGit) {
        generation += 1
        loadTask?.cancel()
        hostRetry?.cancel()
        hostRetry = nil
        let current = generation, boardRoot = board.root.path, spec = spec
        let read = hostSpec(spec)
        loadTask = Task { [weak self] in
            let result: Result<HostChangesLoad, Error>
            do {
                result = .success(try await git.changes(boardRoot: boardRoot, spec: read))
            } catch is CancellationError {
                return
            } catch {
                result = .failure(error)
            }
            await MainTurns.next()
            guard let self, current == self.generation, self.isLive else { return }
            self.loadTask = nil
            switch result {
            case .success(let load): self.installHost(load, spec: spec, git: git)
            case .failure(let error): self.hostLoadFailed(Self.hostReason(error))
            }
        }
    }

    private func hostSpec(_ spec: ChangesSpec) -> ChangesSpec {
        var read = spec
        if let ref = spec.ref, let sha = hostRefShas[ref] { read.refSha = sha }
        return read
    }

    private func installHost(_ load: HostChangesLoad, spec: ChangesSpec, git: HostGit) {
        hostListing = load
        if let ref = spec.ref, let sha = load.set.refSha { hostRefShas[ref] = sha }
        let previous = set
        install(load.set)
        growIfFitted(from: previous, to: load.set)
        if spec.root == nil, spec.head == nil, spec.ref == nil { onBranch?(load.set.branch) }
        hostWatch?.cancel()
        hostWatch = load.probe.map { probe in
            HostFileWatch(baseline: load.baseline, probe: { await git.stamp(probe) }) { [weak self] _ in self?.scheduleReload(after: 0.05) }
        }
    }

    private func hostLoadFailed(_ reason: String) {
        let text = "host unavailable: \(reason)"
        if set != nil {
            show(message: text)
        } else {
            install(ChangeSet(notice: text))
        }
        let current = generation
        hostRetry = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(2))) != nil, let self, current == self.generation, self.isLive, self.window != nil else { return }
            self.hostRetry = nil
            self.load()
        }
    }

    private static func hostReason(_ error: Error) -> String {
        if case .unavailable(let why)? = error as? HostFileError { return why }
        return "\(error)"
    }

    /// A new listing: the current hunk stays the same file and position (the next one when it
    /// went, e.g. discarded), folds stay folded, a selection stays while its hunk does, and the
    /// scroll stays put (after an action, the current hunk scrolls into view).
    private func install(_ set: ChangeSet) {
        let previous = current.flatMap { current in self.set.map { ($0.files[current.file].boardPath, current.hunk) } }
        let picked = selection.flatMap { selection in self.set.map { ($0.files[selection.file].hunks[selection.hunk].id, selection.lines) } }
        self.set = set
        setVersion += 1
        cache.removeAll()
        let viewed = object.props["viewed"]
        for file in set.files {
            let isViewed = file.isViewed(in: viewed)
            if seen.insert(file.boardPath).inserted {
                if file.status == .deleted || isViewed { collapsed.insert(file.boardPath) }
                if isViewed { viewedFolded.insert(file.boardPath) }
            } else if viewedFolded.contains(file.boardPath), !isViewed {
                // Its diff changed since it was marked: show it again.
                viewedFolded.remove(file.boardPath)
                collapsed.remove(file.boardPath)
            }
        }
        if let (path, hunk) = previous {
            if let file = set.files.firstIndex(where: { $0.boardPath == path }), !set.files[file].hunks.isEmpty {
                current = (file, min(hunk, set.files[file].hunks.count - 1))
            } else {
                current = set.hunkOrder.first { set.files[$0.file].boardPath > path }.map { ($0.file, $0.hunk) } ?? set.hunkOrder.last.map { ($0.file, $0.hunk) }
            }
        }
        selection = nil
        anchor = nil
        if let (id, lines) = picked {
            for (fileIndex, file) in set.files.enumerated() {
                if let hunk = file.hunks.firstIndex(where: { $0.id == id }), lines.allSatisfy({ $0 < file.hunks[hunk].lines.count }) {
                    selection = (fileIndex, hunk, lines)
                }
            }
        }
        refreshPainter()
        if revealAfterLoad, let current {
            revealAfterLoad = false
            reveal(file: current.file, hunk: current.hunk)
        }
    }

    private func refreshPainter() {
        guard let set else {
            painter = nil
            needsDisplay = true
            return
        }
        let key = LayoutKey(version: setVersion, collapsed: collapsed, columns: ChangesMetrics.textColumns(width: bounds.width, digits: ChangesMetrics.digits(set)),
                            filter: filter, listOpen: listOpen)
        var painter = makePainter(for: set, width: bounds.width, laidOut: laidOut.flatMap { $0.key == key ? ($0.rows, $0.names) : nil })
        laidOut = (key, painter.rows, painter.names)
        painter.focused = hasKeyboard
        painter.drawsFilter = filterField == nil
        self.painter = painter
        clampScroll()
        scheduleToolTips()
        needsDisplay = true
    }

    /// A painter for `set` as the tile shows it: its folds, filter, list, Viewed checks, current
    /// hunk, selection, header message, and a Discard asking to be pressed again.
    private func makePainter(for set: ChangeSet, width: CGFloat, laidOut: (rows: ChangeRows, names: [String])? = nil) -> ChangesPainter {
        var painter = ChangesPainter(set: set, canPickBase: git != nil || set.repository != nil, collapsed: collapsed, width: width, filter: filter, listOpen: listOpen, laidOut: laidOut)
        painter.viewed = object.props["viewed"]
        painter.current = current
        painter.selection = selection
        painter.message = message
        painter.undoable = git == nil
        if let asked = discard.target, let hint = discard.hint, let file = set.files.firstIndex(where: { $0.boardPath == asked.path }) {
            let hunk = asked.hunk.flatMap { id in set.files[file].hunks.firstIndex { $0.id == id } }
            if asked.hunk == nil || hunk != nil { painter.discardAsked = (file, hunk, hint) }
        }
        return painter
    }

    /// A tile fitted to its diff (its height is what `size: "fit"` gave the last listing, or
    /// Review Changes' compact "No changes" tile) grows with it when hunks are added
    /// (`ChangesMetrics.grown`): the user's up to the default size, an agent's up to the fit
    /// maximum; one the user or an agent sized otherwise keeps its size. It grows into free space
    /// only (`Board.growFitted`), never over its neighbours.
    private func growIfFitted(from old: ChangeSet?, to new: ChangeSet) {
        let natural = object.naturalFrame
        let cap = object.createdBy == .user ? Board.defaultSize(.changes) : nil
        guard let size = ChangesMetrics.grown(CGSize(width: natural.w, height: natural.h), from: old, to: new, viewed: object.props["viewed"],
                                              cap: cap.map { CGSize(width: $0.w, height: $0.h) }) else { return }
        let grown = ObjectZoom.zoomed(size, zoom: object.zoom)
        board.growFitted(object.id, toward: CGSize(width: grown.width.rounded(.up), height: grown.height.rounded(.up)))
    }

    /// Working-tree writes, and the index, HEAD, and refs in the git directory, reload the
    /// listing (debounced); objects, logs, and lock files don't. A linked worktree's own index
    /// and HEAD live in the common git directory, which is watched too. Two commits compared
    /// (`refsOnly`) only move with refs: just the common git directory, and only its refs.
    private func watch(_ repository: URL?, refsOnly: Bool) {
        guard let repository else { return events = nil }
        let worktree = GitWorktree.containing(repository.path)
        var directories = [FileEvents.canonical(repository.path)]
        let common = worktree.map { FileEvents.canonical($0.commonDir) }
        if refsOnly, let common {
            directories = [common]
        } else if let worktree, !worktree.gitDir.hasPrefix(directories[0] + "/") {
            directories.append(FileEvents.canonical(worktree.gitDir))
        }
        guard events?.directories != directories else { return }
        let commonDir = refsOnly ? common : nil
        events = FileEvents(directories: directories, latency: 0.3) { [weak self] paths in
            guard let self else { return }
            let moved = paths.contains { path in commonDir.map { Self.movesRefs(path, commonDir: $0) } ?? Self.matters(path) }
            guard moved, (self.events?.latestEventId ?? .max) > self.loadedThrough else { return }
            self.scheduleReload(after: 0.2)
        }
    }

    /// A ref written in the common git directory (`refs/…`, `packed-refs`; not a lock).
    nonisolated static func movesRefs(_ path: String, commonDir: String) -> Bool {
        guard path.hasPrefix(commonDir + "/"), !path.hasSuffix(".lock") else { return false }
        let inside = path.dropFirst(commonDir.count + 1)
        return inside.hasPrefix("refs/") || inside == "packed-refs"
    }

    nonisolated static func matters(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else { return !path.hasSuffix("/.git") }
        var inside = path[range.upperBound...]
        if inside.hasSuffix(".lock") { return false }
        if inside.hasPrefix("worktrees/"), let slash = inside.dropFirst("worktrees/".count).firstIndex(of: "/") {
            inside = inside[inside.index(after: slash)...]
        }
        return inside == "index" || inside == "HEAD" || inside.hasPrefix("refs/") || inside == "packed-refs"
    }

    private func scheduleReload(after delay: TimeInterval) {
        guard isLive else {
            needsLoad = true
            return
        }
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadWork = nil
                self?.load()
            }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let perfStart = DevPerf.mark()
        defer { DevPerf.record("draw.ChangesTile", since: perfStart) }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard var painter else {
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            ("loading changes…" as NSString).draw(at: NSPoint(x: 12, y: 8), withAttributes: attributes)
            return
        }
        painter.focused = hasKeyboard
        painter.draw(in: context, size: bounds.size, scroll: scroll, cache: cache)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cache.removeAll()
        needsDisplay = true
    }

    private var viewportHeight: CGFloat { max(0, bounds.height - ChangesMetrics.headerHeight) }
    private var contentHeight: CGFloat { (painter?.contentHeight ?? 0) - ChangesMetrics.headerHeight }

    private func clampScroll() {
        scroll = min(max(0, scroll), max(0, contentHeight - viewportHeight)).rounded()
    }

    private func setScroll(_ value: CGFloat) {
        let before = scroll
        scroll = value
        clampScroll()
        guard scroll != before else { return }
        scheduleToolTips()
        needsDisplay = true
    }

    /// A refusal or failure in the header for a few seconds. Anything said drops a Discard
    /// question (`askToDiscard`): the user did something else.
    private func show(message text: String, for duration: TimeInterval = 6) {
        message = text
        discard.drop()
        refreshPainter()
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.message = nil
                self?.refreshPainter()
            }
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: Filter

    /// The header's filter field, live only (cards and renders draw its text).
    private func installFilterField() {
        guard window != nil, isLive, filterField == nil else { return }
        let field = NSSearchField()
        field.placeholderString = "Filter files"
        field.controlSize = .small
        field.font = NSFont.systemFont(ofSize: 11)
        field.stringValue = filter
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        addSubview(field)
        filterField = field
        layoutFilterField()
        refreshPainter()
    }

    private func removeFilterField() {
        guard let field = filterField else { return }
        if window?.firstResponder === field.currentEditor() { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
        filterField = nil
    }

    private func layoutFilterField() {
        filterField?.frame = ChangesPainter.filterRect(width: bounds.width)
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSSearchField, field === filterField else { return }
        filter = field.stringValue
        selection = nil
        refreshPainter()
    }

    /// Return and Esc in the filter give the keyboard back to the tile (Esc clears it first); in
    /// the base field (`askForBase`) Return compares with what was typed, Esc leaves the base.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let isReturn = selector == #selector(NSResponder.insertNewline(_:))
        guard isReturn || selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if control === baseField {
            let choice = isReturn ? ChangesBaseChoice(typed: control.stringValue) : nil
            basePopover?.close()
            if let choice { setBase(choice) }
        } else if control === filterField {
            if isReturn || filter.isEmpty {
                window?.makeFirstResponder(self)
            } else {
                filterField?.stringValue = ""
                filter = ""
                refreshPainter()
            }
        } else {
            return false
        }
        return true
    }

    private func focusFilter() {
        guard let field = filterField else { return }
        window?.makeFirstResponder(field)
    }

    // MARK: Tooltips

    private func scheduleToolTips() {
        toolTipWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshToolTips() } }
        toolTipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// One tooltip area per thing that says something (the header; each visible header row's
    /// label, Viewed box, and buttons; each line), answered by `view(_:stringForToolTip:…)`.
    private func refreshToolTips() {
        removeAllToolTips()
        guard isLive, window != nil, let painter else { return }
        if let lead = painter.headerLayout(width: bounds.width).lead { addToolTip(lead.rect, owner: self, userData: nil) }
        addToolTip(NSRect(x: 0, y: 0, width: bounds.width, height: ChangesMetrics.headerHeight), owner: self, userData: nil)
        var areas: [NSRect] = []
        for index in painter.rows.visible(from: scroll, to: scroll + viewportHeight) {
            let rect = painter.rect(ofRow: index, width: bounds.width, scroll: scroll)
            switch painter.rows.rows[index] {
            case .file(let file) where painter.set.files[file].notice == nil:
                let buttons = painter.buttons(inRow: rect, file: file, hunk: nil).map(\.1)
                let viewed = painter.viewedRect(inRow: rect)
                areas += [NSRect(x: 0, y: rect.minY, width: viewed.minX, height: rect.height), viewed] + buttons
            case .hunk(let file, let hunk):
                let buttons = painter.buttons(inRow: rect, file: file, hunk: hunk).map(\.1)
                areas += [NSRect(x: 0, y: rect.minY, width: buttons.first?.minX ?? rect.maxX, height: rect.height)] + buttons
            default:
                areas.append(rect)
            }
        }
        let body = NSRect(x: 0, y: ChangesMetrics.headerHeight, width: bounds.width, height: viewportHeight)
        for area in areas {
            let clipped = area.intersection(body)
            if !clipped.isEmpty { addToolTip(clipped, owner: self, userData: nil) }
        }
    }

    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { painter?.tooltip(at: point, width: bounds.width, scroll: scroll) ?? "" }
    }

    // MARK: Mouse

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= CodeMetrics.rowHeight
            dy *= CodeMetrics.rowHeight
        }
        let scrollable = contentHeight > viewportHeight + 0.5
        let gesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        guard gesture else {
            // A mouse wheel notch or a replayed step: each one on its own.
            guard scrollable, abs(dy) >= abs(dx), dy != 0 else { return super.scrollWheel(with: event) }
            return setScroll(scroll - dy)
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { gestureOwner = nil }
        if gestureOwner == nil, dx != 0 || dy != 0 {
            gestureOwner = scrollable && abs(dy) >= abs(dx) ? .tile : .canvas
        }
        switch gestureOwner {
        case .tile?:
            if dy != 0 { setScroll(scroll - dy) }
        case .canvas?:
            super.scrollWheel(with: event)
        case nil:
            // A gesture's first event without movement: the canvas mustn't start tracking a
            // gesture that may turn out to scroll the tile.
            if !scrollable { super.scrollWheel(with: event) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let painter, let set else { return }
        let point = convert(event.locationInWindow, from: nil)
        pressed = nil
        dragged = false
        if let lead = painter.headerLayout(width: bounds.width).lead, lead.rect.contains(point) {
            baseMenu(below: lead.rect).popUp(positioning: nil, at: NSPoint(x: lead.rect.minX, y: lead.rect.maxY), in: self)
            return
        }
        let hit = painter.hit(at: point, width: bounds.width, scroll: scroll)
        // A press anywhere but on a Discard button is the user moving on from its question.
        if case .button(.revert, _, _)? = hit {} else { dropDiscardQuestion() }
        guard let hit else { return }
        switch hit {
        case .button(let action, let file, let hunk):
            let lines = hunk.flatMap { hunk in selection.flatMap { $0.file == file && $0.hunk == hunk ? $0.lines : nil } }
            if let hunk { current = (file, hunk) }
            act(action, file: file, hunk: hunk, lines: lines, input: .click)
        case .viewed(let file):
            toggleViewed(file)
        case .file(let file):
            let path = set.files[file].boardPath
            if collapsed.remove(path) == nil { collapsed.insert(path) }
            refreshPainter()
            keepHeaderInView(file)
        case .list:
            listOpen.toggle()
            refreshPainter()
        case .listed(let file):
            jump(toFile: file)
        case .hunk(let file, let hunk):
            current = (file, hunk)
            if selection.map({ $0.file != file || $0.hunk != hunk }) ?? false { selection = nil }
            refreshPainter()
        case .line(let file, let hunk, let line):
            current = (file, hunk)
            let flags = event.modifierFlags
            if flags.contains(.command) {
                // ⌘-click adds or removes one line (and its pair).
                var lines = selection.flatMap { $0.file == file && $0.hunk == hunk ? $0.lines : nil } ?? []
                let pair = set.files[file].hunks[hunk].pairedRows([line])
                if lines.isSuperset(of: pair) { lines.subtract(pair) } else { lines.formUnion(pair) }
                selection = lines.isEmpty ? nil : (file, hunk, lines)
                anchor = (file, hunk, line)
            } else if flags.contains(.shift) {
                let from = anchor.flatMap { $0.file == file && $0.hunk == hunk ? $0.line : nil } ?? line
                select(file: file, hunk: hunk, from: from, to: line)
                anchor = anchor ?? (file, hunk, line)
            } else {
                pressed = (file, hunk, line)
                anchor = (file, hunk, line)
            }
            refreshPainter()
        }
    }

    /// A right-click on the header's lead is the base picker too; elsewhere, the tile's menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let lead = painter?.headerLayout(width: bounds.width).lead, lead.rect.contains(point) { return baseMenu(below: lead.rect) }
        return super.menu(for: event)
    }

    /// Dragging over a hunk's lines selects them (within that hunk).
    override func mouseDragged(with event: NSEvent) {
        guard let pressed, let painter else { return }
        let point = convert(event.locationInWindow, from: nil)
        var line: Int?
        if case .line(let file, let hunk, let over)? = painter.hit(at: point, width: bounds.width, scroll: scroll), file == pressed.file, hunk == pressed.hunk {
            line = over
        } else if let row = painter.rows.index(ofHunk: pressed.file, pressed.hunk) {
            // Past the hunk's first or last line: its end.
            let y = point.y - ChangesMetrics.headerHeight + scroll
            let count = painter.set.files[pressed.file].hunks[pressed.hunk].lines.count
            line = y < painter.rows.tops[row] ? 0 : count - 1
        }
        guard let line else { return }
        dragged = dragged || line != pressed.line
        guard dragged else { return }
        select(file: pressed.file, hunk: pressed.hunk, from: pressed.line, to: line)
        refreshPainter()
    }

    /// The hunk's lines from one row to another, with the other half of each edited line.
    private func select(file: Int, hunk: Int, from: Int, to: Int) {
        guard let set else { return }
        selection = (file, hunk, set.files[file].hunks[hunk].pairedRows(Set(min(from, to)...max(from, to))))
    }

    /// A click (no drag) on a line opens it and drops any selection.
    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            dragged = false
        }
        guard let pressed, !dragged else { return }
        if selection != nil {
            selection = nil
            refreshPainter()
        }
        open(file: pressed.file, hunk: pressed.hunk, line: pressed.line)
    }

    // MARK: Keyboard

    private static func modifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    /// The tile's own key a press is (`ChangesKey`).
    private static func key(_ event: NSEvent) -> ChangesKey? {
        guard event.type == .keyDown else { return nil }
        let modifiers = Self.modifiers(event)
        return ChangesKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, shift: modifiers.contains(.shift),
                          command: modifiers.contains(.command), other: !modifiers.subtracting([.shift, .command]).isEmpty)
    }

    /// Whether the canvas leaves a key to the tile while it is the one selected: its keys other
    /// than Return (which enters it) and ⌘⌫ (Delete Selection), `r` included, which would pick
    /// the rectangle tool.
    static func isOwnKey(_ event: NSEvent) -> Bool {
        key(event).map { $0 != .open && $0 != .confirmDiscard } ?? false
    }

    /// One of the tile's keys pressed while it is only selected (the canvas has the keyboard):
    /// like a code tile's rows and a terminal, the tile acts on keys only once it has the
    /// keyboard, so the header says how to give it that, and the canvas does nothing with it.
    func keyWhileSelected(_ event: NSEvent) -> Bool {
        guard Self.isOwnKey(event) else { return false }
        show(message: "press ↩ first to use the tile's keys", for: 3)
        return true
    }

    func enterKeyboard() -> Bool {
        guard window?.makeFirstResponder(self) == true else { return false }
        pickHunk(revealing: true)
        return true
    }

    /// Taking the keyboard with no hunk picked picks the first one in view
    /// (`ChangeRows.firstHunk`), so `s` stages what the user is looking at instead of asking
    /// for a pick. With none in view, only Return (`revealing`) picks the first hunk and scrolls
    /// to it; a click on a file header or the list leaves the content where it is.
    private func pickHunk(revealing: Bool) {
        guard current == nil, let painter, let first = painter.rows.firstHunk(inView: scroll, scroll + viewportHeight),
              first.inView || revealing else { return }
        current = (first.file, first.hunk)
        refreshPainter()
        if !first.inView { reveal(file: first.file, hunk: first.hunk) }
    }

    /// Keys only with the keyboard in the tile, so typing elsewhere can never stage or discard;
    /// any key but r and ⌘⌫ drops a Discard question (`DiscardByKey`).
    override func keyDown(with event: NSEvent) {
        let key = Self.key(event)
        if DiscardByKey.step(key, asked: discard.target != nil) == .drop { dropDiscardQuestion() }
        if event.keyCode == 53, Self.modifiers(event).isEmpty {
            if selection != nil {
                selection = nil
                refreshPainter()
            } else {
                (enclosingScrollView as? CanvasView)?.leaveTile(object.id)
            }
            return
        }
        guard let key else { return super.keyDown(with: event) }
        switch key {
        case .next: step(1)
        case .previous: step(-1)
        case .nextFile: stepFile(1)
        case .previousFile: stepFile(-1)
        case .open: openCurrent()
        case .stage: actOnCurrent(.stage)
        case .unstage: actOnCurrent(.unstage)
        case .askDiscard: actOnCurrent(.revert)
        case .confirmDiscard: confirmDiscard()
        case .filter: focusFilter()
        case .mention: mentionCurrent()
        }
    }

    /// ⌘⌫ is a key equivalent (Edit › Delete Selection's): while a Discard question shows and
    /// the tile has the keyboard, it answers the question instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, DiscardByKey.step(Self.key(event), asked: discard.target != nil) == .discard else {
            return super.performKeyEquivalent(with: event)
        }
        confirmDiscard()
        return true
    }

    /// s, u and r: on the selected lines, else the current hunk (refused when two commits are
    /// compared).
    private func actOnCurrent(_ action: ChangesAction) {
        if set?.comparesCommits == true { return show(message: ChangesFailure.readOnly.message) }
        guard let target = keyTarget else { return show(message: Self.pickFirst) }
        act(action, file: target.file, hunk: target.hunk, lines: target.lines, input: .key)
    }

    /// A header button or its key: Discard asks first (`askToDiscard`), Stage and Unstage act at
    /// once; two commits compared have nothing to act on and say so.
    private func act(_ action: ChangesAction, file: Int, hunk: Int?, lines: Set<Int>?, input: DiscardQuestion.Input) {
        if set?.comparesCommits == true { return show(message: ChangesFailure.readOnly.message) }
        if action == .revert { return askToDiscard(file: file, hunk: hunk, lines: lines, input: input) }
        perform(action, file: file, hunk: hunk, lines: lines)
    }

    /// What s, u, r and m act on: the selected lines, else the current hunk.
    private var keyTarget: (file: Int, hunk: Int, lines: Set<Int>?)? {
        if let selection { return (selection.file, selection.hunk, selection.lines) }
        return current.map { ($0.file, $0.hunk, nil) }
    }

    private static let pickFirst = "pick a hunk first (j/k or click)"

    /// A Discard asked about (`r`, or a first click on a Discard button) and its hint: one
    /// state, painted as the button's "Discard?" and the header's hint together.
    private var discard = DiscardQuestion()

    /// The user moved on (another press or key in the tile, the keyboard left it): the question
    /// and its hint go together.
    private func dropDiscardQuestion() {
        guard discard.target != nil else { return }
        discard.drop()
        refreshPainter()
    }

    /// Discard asks first (`DiscardQuestion`): `r` or a first click turns the button into
    /// "Discard?" with a hint, which stays until answered or until the user does something else
    /// (`dropDiscardQuestion`). A second click answers; from the keyboard only ⌘⌫ does
    /// (`confirmDiscard`), never a second `r`, so text typed into the tile (a prompt meant for an
    /// agent) never throws work away. A committed hunk has nothing to discard and says so at once.
    private func askToDiscard(file: Int, hunk: Int?, lines: Set<Int>?, input: DiscardQuestion.Input) {
        guard let set, set.files.indices.contains(file), hunk.map(set.files[file].hunks.indices.contains) ?? true else {
            return show(message: Self.pickFirst)
        }
        let changed = set.files[file]
        guard ChangesAction.revert.applies(to: changed, hunk: hunk) else { return show(message: ChangesAction.revert.refusal) }
        let target = DiscardQuestion.Target(path: changed.boardPath, hunk: hunk.map { changed.hunks[$0].id }, lines: lines)
        messageWork?.cancel()
        message = nil
        let answer = discard.press(target, by: input)
        refreshPainter()
        if answer == .confirmed { perform(.revert, file: file, hunk: hunk, lines: lines) }
    }

    /// ⌘⌫ while a question shows: discards what it asked about.
    private func confirmDiscard() {
        guard let asked = discard.target, let set, let file = set.files.firstIndex(where: { $0.boardPath == asked.path }) else { return }
        let hunk = asked.hunk.flatMap { id in set.files[file].hunks.firstIndex { $0.id == id } }
        guard asked.hunk == nil || hunk != nil else { return dropDiscardQuestion() }
        askToDiscard(file: file, hunk: hunk, lines: asked.lines, input: .confirm)
    }

    /// The next or previous hunk of an unfolded, listed file becomes current and scrolls into view.
    private func step(_ delta: Int) {
        guard let set, let painter else { return }
        let shown = Set(painter.rows.shown)
        let order = set.hunkOrder.filter { shown.contains($0.file) && !collapsed.contains(set.files[$0.file].boardPath) }
        guard !order.isEmpty else { return }
        let index = current.flatMap { current in order.firstIndex { $0 == current } }.map { min(max(0, $0 + delta), order.count - 1) } ?? (delta > 0 ? 0 : order.count - 1)
        let target = order[index]
        current = (target.file, target.hunk)
        refreshPainter()
        reveal(file: target.file, hunk: target.hunk)
    }

    /// The next or previous listed file: its header at the top, its first hunk current.
    private func stepFile(_ delta: Int) {
        guard let painter else { return }
        let shown = painter.rows.shown
        guard !shown.isEmpty else { return }
        let from: Int? = current?.file ?? painter.row(at: CGPoint(x: 1, y: ChangesMetrics.headerHeight + 1), width: bounds.width, scroll: scroll).flatMap { painter.rows.rows[$0].file }
        let position = from.flatMap { shown.firstIndex(of: $0) }
        let next = position.map { min(max(0, $0 + delta), shown.count - 1) } ?? (delta > 0 ? 0 : shown.count - 1)
        jump(toFile: shown[next], unfold: false)
    }

    /// Scrolls a file's header to the top (unfolding it when asked) and makes its first hunk current.
    private func jump(toFile file: Int, unfold: Bool = true) {
        guard let set else { return }
        let path = set.files[file].boardPath
        if unfold { collapsed.remove(path) }
        if !set.files[file].hunks.isEmpty, !collapsed.contains(path) { current = (file, 0) }
        refreshPainter()
        guard let painter, let row = painter.rows.index(ofFile: file) else { return }
        setScroll(painter.rows.tops[row])
    }

    /// Scrolls the hunk into the tile's view (below the pinned file header), its header near
    /// the top when it doesn't all fit; nothing when all of it shows already. The canvas never moves.
    private func reveal(file: Int, hunk: Int) {
        guard let painter, let row = painter.rows.index(ofHunk: file, hunk), let bottom = painter.rows.bottom(ofHunk: file, hunk) else { return }
        let top = painter.rows.tops[row]
        let covered = ChangesMetrics.fileHeight
        if top < scroll + covered || bottom > scroll + viewportHeight {
            setScroll(bottom - top <= viewportHeight - covered && top >= scroll + covered ? bottom - viewportHeight : top - covered)
        }
    }

    // MARK: Actions

    private func openCurrent() {
        guard let current, let set, let line = set.openLine(file: current.file, hunk: current.hunk) else { return }
        openCode(file: current.file, line: line, side: set.files[current.file].status == .deleted ? .old : .new)
    }

    /// A clicked line in a code tile beside this one: its working-tree line (a removed line's
    /// place in the working tree; a deleted file's base line). Two commits compared: the line on
    /// its own side (a removed line in the base).
    private func open(file: Int, hunk: Int, line: Int) {
        guard let set, let location = set.location(file: file, hunk: hunk, line: line) else { return }
        if set.comparesCommits { return openCode(file: file, line: location.line, side: location.side) }
        let target = location.side == .old && set.files[file].status != .deleted ? set.openLine(file: file, hunk: hunk) ?? location.line : location.line
        openCode(file: file, line: target, side: set.files[file].status == .deleted ? .old : .new)
    }

    /// The line in a code tile beside this one: this tile's preview, re-aimed while the user
    /// hasn't kept it, else a plain code tile in view showing the file, else a new one
    /// (`Board.openForNavigation`); one step of Navigate Back. Two commits compared: pinned to
    /// the commit of `side` (the base's merge-base for the old side, the head for the new), at
    /// the file's name there.
    private func openCode(file: Int, line: Int, side: DiffSide) {
        guard let set else { return }
        let changed = set.files[file]
        let pin = set.comparesCommits ? (side == .old ? set.base : set.head) : nil
        let path = pin != nil && side == .old ? changed.oldBoardPath ?? changed.boardPath : changed.boardPath
        let aim = CodeAim(path: path, range: LineRange(start: line, end: line), pinnedCommit: pin)
        let open = { [self] () -> CodeReaim? in
            let opened = board.openForNavigation(aim, from: object.id, preview: true, extra: pin == nil ? ["diffBase": .string(spec.baseProp)] : [:])
            onOpenedCode?(opened.id, opened.created)
            return opened.reaim
        }
        guard let canvas = enclosingScrollView as? CanvasView else {
            _ = open()
            return
        }
        canvas.navigating(landing: aim, open)
    }

    /// Marks a file Viewed for its current diff (folding it) or unmarks it (unfolding it):
    /// `props.viewed`, one ⌘Z step; entries for diffs that changed since are dropped with it.
    private func toggleViewed(_ file: Int) {
        guard let set else { return }
        let changed = set.files[file]
        let current = object.props["viewed"]
        var viewed: [String: JSONValue] = [:]
        for other in set.files where other.boardPath != changed.boardPath && other.isViewed(in: current) {
            viewed[other.boardPath] = .string(other.fingerprint)
        }
        if changed.isViewed(in: current) {
            viewedFolded.remove(changed.boardPath)
            collapsed.remove(changed.boardPath)
        } else {
            viewed[changed.boardPath] = .string(changed.fingerprint)
            viewedFolded.insert(changed.boardPath)
            collapsed.insert(changed.boardPath)
            if self.current?.file == file { self.current = nil }
        }
        _ = try? board.update(object.id, props: .object(["viewed": viewed.isEmpty ? .null : .object(viewed)]))
        refreshPainter()
        keepHeaderInView(file)
    }

    /// After a fold from a pinned header: that header at the top, where it was.
    private func keepHeaderInView(_ file: Int) {
        guard let painter, let row = painter.rows.index(ofFile: file), painter.rows.tops[row] < scroll else { return }
        setScroll(painter.rows.tops[row])
    }

    /// Stage, unstage, or discard one hunk (nil: the whole file), or some of its lines: the patch
    /// is built, applied, and recorded as one undo step; a refusal shows in the header and
    /// changes nothing. Discard only ever puts back work not committed yet: a committed hunk is
    /// refused, and against a base older than HEAD (`ChangeSet.includesCommits`) the patch is
    /// built from HEAD, so a hunk mixing committed and uncommitted lines loses only the latter.
    private func perform(_ action: ChangesAction, file: Int, hunk: Int?, lines: Set<Int>?) {
        if let git { return performOnHost(git, action, file: file, hunk: hunk, lines: lines) }
        guard !acting, let set, let repository = set.repository, set.files.indices.contains(file) else { return }
        let changed = set.files[file]
        let target = hunk.map { changed.hunks[$0] }
        guard action.applies(to: changed, hunk: hunk) else { return show(message: action.refusal) }
        acting = true
        let tile = object.id, board = board, includesCommits = set.includesCommits
        Task { [weak self] in
            defer { self?.acting = false }
            do {
                let hunks = target.map { [$0] }
                let patch: ReviewPatch
                switch action {
                case .stage: patch = try await ReviewPatch.stage(hunks, of: changed, in: repository, lines: lines)
                case .unstage: patch = try await ReviewPatch.unstage(hunks, of: changed, in: repository, lines: lines)
                case .revert:
                    patch = includesCommits ? try await ReviewPatch.discardUncommitted(hunks, of: changed, in: repository, lines: lines)
                        : try ReviewPatch.revert(hunks ?? changed.hunks, of: changed, in: repository, lines: lines)
                }
                try await ReviewGit.shared.apply(patch)
                let entry = ReviewPatch.entry(action.entryName, file: changed, hunk: target, lines: lines, patch: patch)
                try board.recordReview(tile: tile, entry: entry, patch: patch)
                // Files changing shows nowhere on the board: say what went and how to get it back.
                if action == .revert { (self?.enclosingScrollView as? CanvasView)?.showNotice(ReviewPatch.discardNotice(of: entry)) }
                self?.revealAfterLoad = true
                // The lines were picked for this action: done with them (Esc leaves right away).
                if lines != nil, let self {
                    self.selection = nil
                    self.anchor = nil
                    self.refreshPainter()
                }
            } catch let failure as ChangesFailure {
                self?.show(message: "\(action.rawValue) refused: \(failure.message)")
            } catch {
                self?.show(message: "\(action.rawValue) failed: \(error)")
            }
        }
    }

    private func performOnHost(_ git: HostGit, _ action: ChangesAction, file: Int, hunk: Int?, lines: Set<Int>?) {
        guard !acting, let set, let listing = hostListing, let checkout = listing.checkout, set.files.indices.contains(file) else { return }
        let changed = set.files[file]
        let target = hunk.map { changed.hunks[$0] }
        guard action.applies(to: changed, hunk: hunk) else { return show(message: action.refusal) }
        guard let sides = listing.sides[changed.path] else { return show(message: "\(action.rawValue) refused: too large to show") }
        acting = true
        let tile = object.id, board = board, includesCommits = set.includesCommits, boardRoot = board.root.path
        Task { [weak self] in
            defer { self?.acting = false }
            do {
                let hunks = target.map { [$0] }
                let patch: ReviewPatch
                switch action {
                case .stage: patch = try await ReviewPatch.stage(hunks, of: changed, sides: sides, onHost: checkout, lines: lines)
                case .unstage: patch = try await ReviewPatch.unstage(hunks, of: changed, sides: sides, onHost: checkout, lines: lines)
                case .revert:
                    patch = includesCommits ? try await ReviewPatch.discardUncommitted(hunks, of: changed, sides: sides, onHost: checkout, lines: lines)
                        : try ReviewPatch.revert(hunks ?? changed.hunks, of: changed, onHost: checkout, lines: lines)
                }
                try await git.apply(patch, to: changed, sides: sides, boardRoot: boardRoot)
                let entry = ReviewPatch.entry(action.entryName, file: changed, hunk: target, lines: lines, patch: patch)
                try board.recordReview(tile: tile, entry: entry, patch: patch)
                if action == .revert { (self?.enclosingScrollView as? CanvasView)?.showNotice(ReviewPatch.discardNotice(of: entry, host: git.hostName)) }
                guard let self else { return }
                self.revealAfterLoad = true
                if lines != nil {
                    self.selection = nil
                    self.anchor = nil
                    self.refreshPainter()
                }
                self.load()
            } catch let failure as ChangesFailure {
                self?.show(message: "\(action.rawValue) refused: \(failure.message)")
            } catch {
                self?.show(message: "\(action.rawValue) failed: \(error)")
            }
        }
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live {
            installFilterField()
            refreshToolTips()
            if needsLoad || (git == nil ? events == nil : hostWatch == nil) { load() }
        } else {
            loadTask?.cancel()
            loadTask = nil
            reloadWork?.cancel()
            reloadWork = nil
            // Nothing watched, held, laid out, or tracked while the card covers the tile.
            events = nil
            if let heldRepository { Task { await GitDiffEngine.shared.release(heldRepository) } }
            heldRepository = nil
            hostWatch?.cancel()
            hostWatch = nil
            hostRetry?.cancel()
            hostRetry = nil
            needsLoad = true
            cache.removeAll()
            removeFilterField()
            layer?.contents = nil
            removeAllToolTips()
            toolTipWork?.cancel()
        }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let painter else { return nil }
        switch painter.hit(at: point, width: bounds.width, scroll: scroll) {
        case .line(let file, let hunk, let line)?: return mention(file: file, hunk: hunk, lines: [line])
        case .hunk(let file, let hunk)?, .button(_, let file, let hunk?)?: return mention(file: file, hunk: hunk, lines: nil)
        default: return nil
        }
    }

    /// Edit › Mention and `m`: the selected lines, else the current hunk (also while the tile is
    /// only selected: the hunk picked while it had the keyboard).
    func keyboardMention(hasKeyboard: Bool) async -> MentionTarget? {
        currentMention
    }

    private var currentMention: MentionTarget? {
        keyTarget.flatMap { mention(file: $0.file, hunk: $0.hunk, lines: $0.lines) }
    }

    /// `m` with the keyboard in the tile: stages the selected lines, else the current hunk, as a
    /// Hyper-click on them would (a second `m` unstages it).
    private func mentionCurrent() {
        guard let target = currentMention else { return show(message: Self.pickFirst) }
        if case .unstaged(let mention) = board.toggle(target) { show(message: TrayChips.unstagedNotice(mention)) }
    }

    /// A mention names the lines on their side and the base they were diffed against, so the
    /// prompt quotes them however the tile changes before the tray drains, and says what they
    /// are in the diff (`ChangeSet.mention`).
    private func mention(file: Int, hunk: Int, lines: Set<Int>?) -> MentionTarget? {
        guard let set, let found = set.mention(file: file, hunk: hunk, lines: lines) else { return nil }
        let symbol = set.files[file].symbol(lines: found.lines, side: found.side)
        if set.comparesCommits, found.side == .new {
            // The head's lines, as that commit has them (no working tree in this diff).
            return .code(object: object.id, path: found.path, lines: found.lines, side: nil, symbol: symbol, commit: set.head, diff: found.detail)
        }
        return .code(object: object.id, path: found.path, lines: found.lines, side: set.base == nil ? nil : found.side.rawValue, symbol: symbol, commit: set.base, diff: found.detail)
    }

    func scrollToMention(_ target: MentionTarget) {
        guard case .code(let id, let path, let lines, let side, _, _, _) = target, id == object.id, let set else { return }
        let wanted = side ?? DiffSide.new.rawValue
        // A folded file shows no lines: unfold the one the mention is in.
        if let file = set.files.firstIndex(where: { $0.boardPath == path || $0.oldBoardPath == path }), collapsed.contains(set.files[file].boardPath) {
            collapsed.remove(set.files[file].boardPath)
            refreshPainter()
        }
        guard let painter else { return }
        for index in painter.rows.rows.indices {
            guard case .line(let file, let hunk, let line) = painter.rows.rows[index], let location = set.location(file: file, hunk: hunk, line: line),
                  location.path == path, location.side.rawValue == wanted, lines.start <= location.line, location.line <= lines.end else { continue }
            reveal(file: file, hunk: hunk)
            let rect = painter.rect(ofRow: index, width: bounds.width, scroll: scroll)
            let shown = NSRect(x: 0, y: ChangesMetrics.headerHeight + ChangesMetrics.fileHeight, width: bounds.width, height: viewportHeight - ChangesMetrics.fileHeight)
            if !shown.contains(rect) { setScroll(painter.rows.tops[index] - ChangesMetrics.fileHeight - 2 * rect.height) }
            return
        }
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(let id, let path, let lines, let side, _, _, _) = target, id == object.id, let painter, let set else { return nil }
        var union: NSRect?
        for index in painter.rows.visible(from: scroll, to: scroll + viewportHeight) {
            guard case .line(let file, let hunk, let line) = painter.rows.rows[index], let location = set.location(file: file, hunk: hunk, line: line),
                  location.path == path, location.side.rawValue == (side ?? DiffSide.new.rawValue), lines.start <= location.line, location.line <= lines.end else { continue }
            let rect = painter.rect(ofRow: index, width: bounds.width, scroll: scroll)
            union = union.map { $0.union(rect) } ?? rect
        }
        return union?.intersection(NSRect(x: 0, y: ChangesMetrics.headerHeight, width: bounds.width, height: viewportHeight))
    }

    var takesKeyboardFocus: Bool { false }

    /// Whether `set` is the listing as it is now: a live tile watches its worktree and git
    /// directory, and nothing is pending. Off screen or zoomed out nothing is watched (and a
    /// props change waits for the tile to be live), so a render lists afresh.
    private var listingIsCurrent: Bool {
        isLive && !needsLoad && loadTask == nil && reloadWork == nil && (git == nil ? events != nil : hostWatch != nil) && set != nil
    }

    func render(_ request: TileRenderRequest) async -> TileRender {
        var loaded = set
        if !listingIsCurrent {
            let spec = spec
            let fresh: ChangeSet
            var hostLoad: HostChangesLoad?
            if let git {
                do {
                    let load = try await git.changes(boardRoot: board.root.path, spec: hostSpec(spec))
                    hostLoad = load
                    fresh = load.set
                } catch {
                    return .placeholder(request, Task.isCancelled || error is CancellationError ? "cancelled" : "host unavailable: \(Self.hostReason(error))")
                }
            } else {
                fresh = await ChangeSet.load(root: board.root, spec: spec)
            }
            guard !Task.isCancelled else { return .placeholder(request, "cancelled") }
            guard spec == self.spec else { return .placeholder(request, "the tile changed while loading") }
            if let ref = spec.ref, let sha = hostLoad?.set.refSha { hostRefShas[ref] = sha }
            // A live tile's own load installs (and grows a fitted frame); one that isn't live
            // keeps this listing for its card and revalidates the next time it is.
            if !isLive || set == nil {
                if let hostLoad { hostListing = hostLoad }
                install(fresh)
                if !isLive { needsLoad = true }
            }
            loaded = fresh
        }
        guard let loaded else { return .placeholder(request, "not loaded") }
        var painter = makePainter(for: loaded, width: request.size.width)
        painter.discardAsked = nil
        let content = CGSize(width: request.size.width, height: painter.contentHeight)
        let size = request.full ? CGSize(width: request.size.width, height: max(request.size.height, content.height)) : request.size
        let scrollY = request.full ? 0 : scroll
        let image = request.image(size: size) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            painter.draw(in: context, size: rect.size, scroll: scrollY, cache: nil)
        }
        guard let image else { return TileRender(image: nil, contentSize: content, state: .failed, reason: "could not allocate the bitmap") }
        return TileRender(image: image, contentSize: content, state: .rendered, reason: nil)
    }
}

// MARK: Base picker

extension ChangesTile {
    /// The header's base picker: the uncommitted changes, everything the branch changed (against
    /// the merge-base with the default branch), the commit or ref typed in before, or another one
    /// typed into a small field. A pick is `props.base`, one ⌘Z step.
    fileprivate func baseMenu(below rect: NSRect) -> NSMenu {
        let current = ChangesBaseChoice(prop: spec.baseProp)
        let defaultBranch: String?
        if git != nil {
            defaultBranch = hostListing?.defaultBranch
        } else {
            let directory = spec.directory(boardRoot: board.root)
            defaultBranch = GitWorktree.containing(directory.path)?.defaultBranch
        }
        let menu = NSMenu()
        // Two commits compared have no uncommitted work to pick.
        for choice in ChangesBaseChoice.choices(current: current) where !(choice == .uncommitted && (spec.head != nil || set?.comparesCommits == true)) {
            let item = MenuAction.item(choice.title(defaultBranch: defaultBranch)) { [weak self] in self?.setBase(choice) }
            item.state = choice == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Commit or Ref…") { [weak self] in self?.askForBase(below: rect) })
        return menu
    }

    fileprivate func setBase(_ choice: ChangesBaseChoice) {
        guard choice.prop != spec.baseProp else { return }
        _ = try? board.update(object.id, props: .object(["base": .string(choice.prop)]))
    }

    /// A field under the header for a commit, branch, or tag (`HEAD~3`, `origin/main`, `v1.2`):
    /// Return compares with it, Esc or a click elsewhere leaves the base as it is. A name git
    /// doesn't know shows as the tile's notice, and the picker is still there to fix it.
    fileprivate func askForBase(below rect: NSRect) {
        let field = NSTextField(string: "")
        field.placeholderString = "commit, branch, or tag (HEAD~3, origin/main, v1.2)"
        field.font = .systemFont(ofSize: 12)
        field.frame = NSRect(x: 10, y: 10, width: 300, height: 22)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
        content.view.addSubview(field)
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        field.delegate = self
        baseField = field
        basePopover = popover
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(field)
    }
}

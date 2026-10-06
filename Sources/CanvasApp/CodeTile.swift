import AppKit
import CanvasCore

/// Read-only code tile: the whole current file, scrolled to the object's `range` (tinted), with
/// gitsigns against the diff base in the gutter (green bar added, blue bar modified, red wedge
/// deleted; clicking a sign peeks the base lines inline). Rows are drawn straight from the
/// model, only those on screen (`CodeRowsView`); git and parsing run off the main thread and
/// only while the tile is live; file changes reload after a short debounce, and the rows a
/// write changed flash. Follow tiles hold still while the user works in them (`FollowLock`).
@MainActor
final class CodeTile: NSView, TileContent {
    typealias Aim = CodeHeaderBar.Location

    private(set) var object: CanvasObject
    private let board: Board
    private let header = CodeHeaderBar(frame: .zero)
    private let rowsView = CodeRowsView(frame: .zero)

    /// What the tile shows, which the user may hold behind the props' aim.
    private var lock: FollowLock<Aim>
    private var displayed: Aim
    private var propsAim: Aim
    private var resumeWork: DispatchWorkItem?

    private var document: CodeDocument?
    /// What the document was loaded from (diff base or pinned commit).
    private var loadedSource: Source?
    private var peeked: Set<Int> = []
    private var flash: (lines: [Range<Int>], start: TimeInterval)?
    private var flashTimer: Timer?

    private var isLive = true
    private var needsLoad = true
    private var loadTask: Task<Void, Never>?
    /// Bumped by every load; only the newest load installs its result.
    private var generation = 0
    /// Repository this tile holds in the git engine while live (bases watched).
    private var heldRepository: String?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    /// Dispatch sources must be resumed before they are released, so suspension is tracked.
    private var watcherSuspended = false
    private var reloadWork: DispatchWorkItem?
    private var navigation: CodeNavigation?
    private var findBar: CodeFindBar?
    /// Who had the keyboard before ⌘F, to get it back on Esc.
    private weak var findPreviousResponder: NSResponder?
    /// Pending recheck of a file that vanished (`fileVanished`).
    private var vanishCheck: Task<Void, Never>?
    /// Where the follow tile stepped back to after its file was deleted: no edit flash there.
    private var steppedBackTo: String?
    /// The repository whose default branch the base picker last read, and that branch.
    private var knownDefaultBranch: (repository: String, branch: String?)?

    static let flashDuration: TimeInterval = 3

    init(object: CanvasObject, board: Board) {
        self.object = object
        self.board = board
        let aim = Self.aim(object.props) ?? Aim(path: "", range: nil)
        displayed = aim
        propsAim = aim
        lock = FollowLock(showing: aim)
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        addSubview(rowsView)
        rowsView.onScroll = { [weak self] in
            self?.navigation?.contentChanged()
            self?.rowsMoved()
        }
        addSubview(header)
        rowsView.onSign = { [weak self] sign in self?.togglePeek(sign) }
        rowsView.onInteract = { [weak self] in self?.userInteracted() }
        rowsView.onEditHere = { [weak self] point in self?.editHere(at: point) }
        rowsView.onEscape = { [weak self] in
            guard let self else { return }
            (self.enclosingScrollView as? CanvasView)?.leaveTile(self.object.id)
        }
        header.onBase = { [weak self] base in self?.setBase(base) }
        header.onChange = { [weak self] forward in self?.jumpToChange(forward: forward) }
        header.onPin = { [weak self] in self?.pin() }
        header.onCatchUp = { [weak self] in self?.catchUp() }
        header.onLocation = { [weak self] location in self?.userAim(location) }
        NotificationCenter.default.addObserver(self, selector: #selector(baseChanged), name: .gitDiffBaseChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refsMoved(_:)), name: .gitRefsMoved, object: nil)
        header.show(caption: object.props["caption"]?.string)
        refreshHeader()
        resizeSubviews(withOldSize: .zero)
        navigation = CodeNavigation(host: self, board: board, tile: object.id, accessories: header, reservedWidth: CodeHeaderBar.reservedTrailing)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// The first load waits until the tile is in a window, live: one created as a card (in a
    /// batch, zoomed out or offscreen) loads when it first becomes live instead.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, isLive, needsLoad { load() }
    }

    deinit {
        loadTask?.cancel()
        vanishCheck?.cancel()
        if watcherSuspended { watcher?.resume() }
        watcher?.cancel()
        if let heldRepository { Task { await GitDiffEngine.shared.release(heldRepository) } }
        MainActor.assumeIsolated {
            reloadWork?.cancel()
            resumeWork?.cancel()
            flashTimer?.invalidate()
        }
    }

    /// Posted off the main thread by the git engine when a commit, checkout, or fetch moved a base.
    @objc nonisolated private func baseChanged() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    /// A branch-anchored tile re-resolves when refs or worktrees of the repository it reads move:
    /// a worktree checking its branch out or going away, the branch merged or deleted.
    @objc nonisolated private func refsMoved(_ notification: Notification) {
        let toplevel = notification.object as? String
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.source.ref != nil, toplevel == self.heldRepository else { return }
                self.scheduleReload()
            }
        }
    }

    nonisolated override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let height = header.height
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        // The find bar gets a strip of its own above the rows, so it never covers a match.
        let top = height + findStrip
        rowsView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        rewrap()
        layoutFindBar()
        rowsMoved()
    }

    /// Rows wrap at the tile's width: when a resize changes the columns, rewrap and keep the
    /// line at the top where it was. Selections are logical, so they survive.
    private func rewrap() {
        guard let document, showsCurrent, let rows = rowsView.painter?.rows,
              rows.columns != CodeMetrics.textColumns(width: rowsView.bounds.width, lineCount: document.gutterLineCount) else { return }
        let top = rows.segment(rowsView.topRow)
        refreshPainter(keepSelection: true)
        guard let top, let rewrapped = rowsView.painter?.rows else { return }
        let row = min(rewrapped.rows(ofEntry: top.entry).lowerBound + top.part, rewrapped.rows(ofEntry: top.entry).upperBound - 1)
        rowsView.scroll(toY: CodePainter.rowTop(row) - CodeMetrics.verticalPadding)
    }

    /// Where an arrow bound to `line` attaches, in the tile's own points from the top of its
    /// frame (the title bar above this view included) for a natural frame `frameHeight` tall: the
    /// line's row as scrolled now, clamped to the rows (`CodeMetrics.lineY`). Before the file
    /// has loaded, the row it will show when aimed.
    func lineY(_ line: Int, frameHeight: CGFloat) -> CGFloat {
        let rowsTop = CodeMetrics.titleHeight + rowsView.frame.minY
        guard showsCurrent, let rows = rowsView.painter?.rows else {
            return CodeMetrics.naturalLineY(line: line, frameHeight: frameHeight, props: object.props, rows: nil)
        }
        return CodeMetrics.lineY(line: line, rows: rows, scroll: rowsView.bounds.origin.y, rowsTop: rowsTop, frameHeight: frameHeight)
    }

    /// Rows moved under the tile's frame (scroll, peeks, a new file, header height): arrows bound
    /// to its lines re-attach.
    private func rowsMoved() {
        NotificationCenter.default.post(name: Self.rowsMoved, object: self)
    }

    static let rowsMoved = Notification.Name("CodeTile.rowsMoved")

    // MARK: Props

    /// Where `props` (the tile's, or a follow history entry) aim, without a symbol.
    private static func aim(_ props: JSONValue) -> Aim? {
        CodeAim(props: props).map { Aim(path: $0.path, range: $0.range) }
    }

    var path: String { displayed.path }
    private var diffBaseProp: String { object.props["diffBase"]?.string ?? "merge-base" }
    private var diffBase: DiffBase { DiffBase(prop: object.props["diffBase"]?.string) }
    /// A commit the tile shows the file at instead of the working tree (read-only, no diff).
    private var pinnedCommit: String? { object.props["pinnedCommit"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    /// What a load reads: the file against its diff base, at its pinned commit, or where its
    /// branch (`props.ref`) is now; a pinned commit wins over a ref.
    private var source: Source { Source(base: diffBase, pinned: pinnedCommit, ref: pinnedCommit == nil ? RefSource.ref(of: object.props) : nil) }

    private struct Source: Equatable {
        var base: DiffBase
        var pinned: String?
        var ref: String?

        /// Where the file is read from: `url` (the path on the board), or for a ref the file in the
        /// worktree that has it checked out, else in the board's checkout at the ref's commit.
        struct Located: Sendable {
            var file: URL
            var ref: RefSource?
            var failure: String?
        }

        func locate(url: URL, path: String, boardRoot: URL, refSha: String?) async -> Located {
            guard let ref else { return Located(file: url) }
            do {
                let source = try await RefSource.resolve(ref: ref, lastKnownSha: refSha, boardRoot: boardRoot)
                return Located(file: source.url(for: path), ref: source)
            } catch {
                return Located(file: url, failure: RefSource.describe(error, ref: ref))
            }
        }

        func document(path: String, located: Located, boardRoot: URL) async -> CodeDocument {
            let engine = GitDiffEngine.shared
            if let failure = located.failure {
                let diff = FileDiff(state: .pinUnavailable, base: nil, baseLabel: failure, old: SideText(""), new: SideText(""), hunks: [])
                return CodeDocument(path: path, diff: diff, ref: ref)
            }
            let diff: FileDiff = if let pinned {
                await engine.pinned(file: located.file, revision: pinned)
            } else if let commit = located.ref?.commit {
                await engine.pinned(file: located.file, revision: commit)
            } else {
                await engine.diff(file: located.file, base: base)
            }
            let readPath = located.ref.map { _ in Board.relativePath(located.file.path, root: boardRoot) }
            return await offPool { CodeDocument(path: path, diff: diff, readPath: readPath, ref: located.ref?.label) }
        }
    }
    private var followOf: ObjectID? { object.props["followOf"]?.string }
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func update(_ object: CanvasObject) {
        let old = self.object
        self.object = object
        header.show(caption: object.props["caption"]?.string)
        let aim = Self.aim(object.props) ?? Aim(path: "", range: nil)
        if aim != propsAim {
            propsAim = aim
            if let shown = lock.aim(aim, at: Self.now) {
                apply(shown)
            } else {
                scheduleResume()
            }
        }
        if old.props["diffBase"] != object.props["diffBase"] || old.props["pinnedCommit"] != object.props["pinnedCommit"] || old.props["ref"] != object.props["ref"] { load() }
        if old.props["range"] != object.props["range"] || old.props["anchor"] != object.props["anchor"] {
            if documentIsCurrent {
                reanchor()
            } else {
                reanchorPending = true
                if !isLive { needsLoad = true }
                if staleReason != nil {
                    staleReason = nil
                    refreshPainter(keepSelection: true)
                }
            }
        }
        refreshHeader()
        resizeSubviews(withOldSize: bounds.size)
    }

    /// Show an aim: another file loads it; the same file only moves the range.
    private func apply(_ aim: Aim) {
        let previous = displayed
        displayed = aim
        navigation?.contentChanged()
        if aim.path != previous.path {
            // The load may install the very file already there (re-aimed away and back before
            // the other file loaded), which keeps the scroll: it must still show this range.
            rangePending = true
            load()
        } else if aim.range != previous.range {
            refreshPainter(keepSelection: true)
            showRange()
        }
        refreshHeader()
    }

    /// Whether the rows are the file the tile shows; while a reload changes it, mentions and
    /// navigation wait for it.
    private var showsCurrent: Bool { document?.path == displayed.path }

    // MARK: Follow lock

    /// The user scrolled, clicked, or selected in the tile: a ⌘-click preview becomes a tile
    /// they keep (`Board.keepCode`); a follow tile holds its re-aims.
    private func userInteracted() {
        board.keepCode(object.id)
        guard followOf != nil else { return }
        lock.interact(at: Self.now)
        scheduleResume()
    }

    /// One pending check at the end of the hold; interactions push the end out, so the check
    /// re-arms until it has really lapsed.
    private func scheduleResume() {
        guard resumeWork == nil, let until = lock.until else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resumeWork = nil
                if let aim = self.lock.resume(at: Self.now) {
                    self.apply(aim)
                } else if self.lock.until != nil {
                    self.scheduleResume()
                }
                self.refreshHeader()
            }
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, until - Self.now), execute: work)
    }

    private func catchUp() {
        if let aim = lock.catchUp() { apply(aim) }
        refreshHeader()
    }

    /// The user picked a location (history strip): shown at once, as navigation (no undo step).
    private func userAim(_ aim: Aim) {
        lock.userAimed(aim)
        apply(aim)
        board.reaimForNavigation(object.id, to: CodeAim(path: aim.path, range: aim.range, pinnedCommit: pinnedCommit, ref: RefSource.ref(of: object.props)))
    }

    // MARK: Loading

    /// Diff the file against its base, or read it at its pinned commit (git, off the main
    /// thread), build the model off the main thread, and install it. Deferred until the tile is live.
    private func load() {
        guard isLive else {
            needsLoad = true
            return
        }
        needsLoad = false
        let path = displayed.path
        let url = board.absoluteURL(path)
        let source = source, boardRoot = board.root, refSha = object.props["refSha"]?.string
        if source.ref == nil { watch(url) }
        generation += 1
        let current = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let engine = GitDiffEngine.shared
            let located = await source.locate(url: url, path: path, boardRoot: boardRoot, refSha: refSha)
            if source.ref != nil, let self, current == self.generation {
                // Its worktree deleted, the file goes, and the reload finds the ref's objects.
                self.watch(located.file)
                if let resolved = located.ref { self.board.recordRefSha(self.object.id, ref: resolved.ref, sha: resolved.resolution.sha) }
            }
            let held = await engine.retain(containing: located.file)
            let document = await source.document(path: path, located: located, boardRoot: boardRoot)
            // Tiles loading together (a batch) install one per wake of the main thread.
            await MainTurns.next()
            guard let self, !Task.isCancelled, current == self.generation, self.isLive else {
                if let held { await engine.release(held) }
                return
            }
            self.loadTask = nil
            if let previous = self.heldRepository { Task { await engine.release(previous) } }
            self.heldRepository = held
            self.install(document, source: source)
        }
    }

    /// Whether `document` is the file as it is now: a live tile watches its file and bases, and
    /// nothing is pending. Off screen or zoomed out nothing is watched, so a render or card
    /// reloads (a view.render of an offscreen tile must show the file on disk, never the last
    /// thing drawn).
    private var documentIsCurrent: Bool {
        isLive && !needsLoad && loadTask == nil && reloadWork == nil && showsCurrent && loadedSource == source && document != nil
    }

    /// The model without holding the repository, for renders and cards of tiles that aren't live.
    private func loadOffscreen() async -> CodeDocument? {
        if documentIsCurrent, let document { return document }
        let path = displayed.path, source = source, boardRoot = board.root
        let located = await source.locate(url: board.absoluteURL(path), path: path, boardRoot: boardRoot, refSha: object.props["refSha"]?.string)
        if let resolved = located.ref { board.recordRefSha(object.id, ref: resolved.ref, sha: resolved.resolution.sha) }
        let document = await source.document(path: path, located: located, boardRoot: boardRoot)
        await MainTurns.next()
        guard path == displayed.path, source == self.source else { return nil }
        if !showsCurrent || loadedSource != source || reanchorPending || self.document?.text != document.text || self.document?.signs != document.signs {
            install(document, source: source)
            // Not live: the next time it is, revalidate against the watched file and bases.
            if !isLive { needsLoad = true }
        }
        return document
    }

    /// A re-aim to another file is waiting for its load to scroll to the range.
    private var rangePending = false

    private func install(_ document: CodeDocument, source: Source) {
        let previous = self.document
        let revealRange = rangePending && document.path == displayed.path
        if revealRange { rangePending = false }
        let sameSource = loadedSource == source
        self.document = document
        loadedSource = source
        reanchor()
        rowsView.canEdit = document.side == .new && !document.isPinned
        // Laid-out lines are keyed by line number, which a new text reassigns.
        rowsView.cache.removeAll()
        // Another pinned commit is another text, not an edit.
        let sameFile = previous.map { sameSource && $0.path == document.path && $0.side == document.side } ?? false
        if sameFile, let previous, let edit = CodeEdits.changes(from: previous.text, to: document.text) {
            peeked = []
            refreshPainter(keepSelection: false)
            startFlash(edit.lines)
            if revealRange {
                showRange()
            } else if followOf != nil, !lock.isHeld(at: Self.now) {
                scroll(toRow: rowsView.painter?.rows.index(ofLine: edit.first) ?? 0)
            }
        } else if sameFile, let previous {
            let sameSigns = previous.signs == document.signs
            if !sameSigns { peeked = [] }
            refreshPainter(keepSelection: sameSigns)
            if revealRange { showRange() }
        } else {
            peeked = []
            refreshPainter(keepSelection: false)
            showRange()
            flashFollowedEdit(in: document)
        }
        navigation?.contentChanged()
        refreshHeader()
        if document.diff.state == .missing, document.path == displayed.path { fileVanished(document.path) }
    }

    /// The file is on neither the disk nor the diff base (an agent wrote a scratch file and
    /// removed it): a follow tile steps back through its history, a ⌘-click preview closes
    /// (`Board.codeFileVanished`; the user's own tiles stay). Checked again a moment later, so
    /// a save that deletes and re-creates the file isn't taken for a delete.
    private func fileVanished(_ path: String) {
        guard vanishCheck == nil else { return }
        let url = board.absoluteURL(path)
        let candidates = FollowFallback.candidates(object.props["history"]?.array ?? [], vanished: path).map { ($0, board.absoluteURL($0)) }
        vanishCheck = Task { [weak self] in
            // Cancellation (tile removed/offscreen) must not continue into filesystem work.
            guard (try? await Task.sleep(for: .milliseconds(600))) != nil else { return }
            let found = await offPool { () -> (gone: Bool, existing: Set<String>) in
                let files = FileManager.default
                return (!files.fileExists(atPath: url.path), Set(candidates.filter { files.fileExists(atPath: $0.1.path) }.map(\.0)))
            }
            guard !Task.isCancelled, let self else { return }
            self.vanishCheck = nil
            guard found.gone, self.document?.path == path, self.document?.diff.state == .missing, self.displayed.path == path else { return }
            if case .steppedBack(let back) = self.board.codeFileVanished(self.object.id, path: path, existing: found.existing) {
                self.steppedBackTo = back
            }
        }
    }

    /// An agent's edit to a file the tile wasn't showing has no earlier load to compare with:
    /// flash the lines the edit reported changing (`lastChanges`, every hunk), else the change
    /// around the reported line (a whole new file for writes). Not when the tile stepped back to
    /// it because the file it showed was deleted.
    private func flashFollowedEdit(in document: CodeDocument) {
        if let back = steppedBackTo, back == document.path {
            steppedBackTo = nil
            return
        }
        guard followOf != nil, displayed == propsAim, let action = object.props["lastAction"]?.string, action == "edit" || action == "write" else { return }
        let lineCount = document.text.lineCount
        let changed = (object.props["lastChanges"]?.array ?? []).compactMap { change -> Range<Int>? in
            guard let start = change["start"]?.int, let end = change["end"]?.int, start >= 1, start <= lineCount else { return nil }
            return start..<(min(max(start, end), lineCount) + 1)
        }
        if !changed.isEmpty {
            startFlash(changed)
        } else if let line = displayed.range?.start, let sign = document.sign(at: line), !document.signs[sign].lines.isEmpty {
            startFlash([document.signs[sign].lines])
        } else if displayed.range == nil, document.diff.state == .added || document.diff.state == .noBase, document.text.lineCount > 0 {
            startFlash([1..<(document.text.lineCount + 1)])
        } else if displayed.range == nil, let first = document.signs.first(where: { !$0.lines.isEmpty }) {
            startFlash([first.lines])
            scroll(toRow: rowsView.painter?.rows.index(ofLine: first.lines.lowerBound) ?? 0)
        }
    }

    /// Rebuild what the rows view draws from the document, peeks, range, and flash.
    private func refreshPainter(keepSelection: Bool) {
        guard let document, showsCurrent else {
            rowsView.painter = nil
            return
        }
        var painter = CodePainter(document: document, rows: document.rows(peeked: peeked, width: rowsView.bounds.width))
        painter.rangeLines = tintedRange.flatMap(document.lines(for:))
        painter.flash = flash.map { ($0.lines, flashStrength($0.start)) }
        painter.selection = keepSelection ? rowsView.painter?.selection : nil
        if let findBar, !findBar.isHidden {
            let previous = rowsView.painter?.find?.current
            var find = CodeFind(query: findBar.field.stringValue, rows: painter.rows) { painter.text(ofEntry: $0) }
            find.current = find.matches.isEmpty ? nil : min(previous ?? 0, find.matches.count - 1)
            painter.find = find
            findBar.show(status: find.status)
        }
        rowsView.painter = painter
        rowsMoved()
        selectGoToLines()
    }

    /// Lines Go to landed on (`select(lines:)`), selected once the rows show the file.
    private var goToLines: LineRange?

    /// Go to (⌘P) landed on `lines` here: they are selected, as a drag over them would, so ⇧⌘M
    /// mentions them and ⌘C copies them, not the whole tile (`KeyboardMention.goToLines`); a
    /// re-aim to another file selects them once it has loaded.
    func select(lines: LineRange) {
        goToLines = lines
        selectGoToLines()
    }

    private func selectGoToLines() {
        guard let lines = goToLines, showsCurrent, let painter = rowsView.painter, painter.rows.entryCount > 0 else { return }
        goToLines = nil
        let first = painter.rows.entry(ofLine: lines.start), last = painter.rows.entry(ofLine: max(lines.start, lines.end))
        rowsView.painter?.selection = (CodeRows.Position(entry: first, offset: 0), CodeRows.Position(entry: last, offset: painter.text(ofEntry: last).length))
    }

    // MARK: Anchoring

    /// The range as last found, its file, and the text it held then, which re-finds it after the
    /// file changes.
    private var anchored: (path: String, range: LineRange, lines: [String])?
    /// Why the range's code can't be found: the header says so instead of tinting other lines.
    private var staleReason: String?

    /// The range the rows tint: none while it is stale.
    private var tintedRange: LineRange? { staleReason == nil ? displayed.range : nil }

    /// A tile showing a range keeps it on the code it showed, as note fences do (`CodeAnchor`,
    /// `NoteAnchor`): with the file loaded or the range changed, the range is re-found by the
    /// text it held (else `props.anchor`, its first line) and, moved or resized by lines
    /// inserted or removed above or inside it, written back with its first line as bookkeeping
    /// (`Board.reanchor`). Code that is gone leaves the range where it was, marked stale. Only
    /// against the file as it is now: a range set while the tile's text may be behind the disk
    /// (not live, or a reload pending) waits for the next load (`reanchorPending`), or it would
    /// be anchored to whatever line that old text had there.
    private func reanchor() {
        reanchorPending = false
        let wasStale = staleReason
        defer {
            if staleReason != wasStale {
                refreshPainter(keepSelection: true)
                refreshHeader()
            }
        }
        guard let document, showsCurrent, document.side == .new, document.text.lineCount > 0,
              let fence = CodeAnchor.fence(object.props), fence.path == displayed.path, fence.lines == displayed.range, let written = fence.lines else {
            staleReason = nil
            return
        }
        let source = NoteSource.lines(of: document.text.text)
        let captured = anchored.flatMap { $0.path == displayed.path && $0.range == written ? $0.lines : nil }
        let resolution = NoteAnchor.resolve(fence, in: source, captured: captured)
        guard let range = resolution.range else {
            if case .stale(let reason) = resolution.status { staleReason = reason }
            return
        }
        staleReason = nil
        anchored = (displayed.path, range, Array(source[(range.start - 1)..<range.end]))
        let anchor = CodeAnchor.anchor(of: range, in: source)
        if range != written || anchor != fence.anchor {
            try? board.reanchor(object.id, range: range, anchor: anchor)
        }
    }

    /// `object.get`'s `rangeStatus`: the range resolved against the file as it is now (loaded
    /// first unless the tile is current, which re-anchors it) with the text the tile last found
    /// there, so a first line repeated elsewhere doesn't pass for the code it showed. Nil for a
    /// tile whose range doesn't anchor.
    func rangeStatus() async -> NoteExcerpt? {
        guard CodeAnchor.fence(object.props) != nil, let document = await loadOffscreen(),
              let fence = CodeAnchor.fence(object.props), let path = fence.path, let written = fence.lines else { return nil }
        guard document.side == .new, document.diff.state != .missing else {
            return NoteExcerpt(path: path, range: nil, lines: [], status: .stale("no file \(path)"), missing: true)
        }
        let source = NoteSource.lines(of: document.text.text)
        let captured = anchored.flatMap { $0.path == path && $0.range == written ? $0.lines : nil }
        let resolution = NoteAnchor.resolve(fence, in: source, captured: captured)
        let lines = resolution.range.map { Array(source[($0.start - 1)..<$0.end]) } ?? []
        return NoteExcerpt(path: path, range: resolution.range, lines: lines, status: resolution.status, fileLineCount: source.count)
    }

    /// The range or anchor changed while the text wasn't known to be current: the next install
    /// (a load, or the reload before a render) re-finds it.
    private var reanchorPending = false

    // MARK: Find

    /// ⌘F: the find bar above the rows, seeded with a one-line selection, holding the keyboard
    /// until Esc gives it back to whoever had it.
    func showFind() {
        let bar = findBar ?? makeFindBar()
        if let text = rowsView.selectedText, !text.isEmpty, !text.contains("\n") { bar.field.stringValue = text }
        if !bar.holdsKeyboard { findPreviousResponder = window?.firstResponder }
        if bar.isHidden {
            bar.isHidden = false
            resizeSubviews(withOldSize: bounds.size)
        }
        window?.makeFirstResponder(bar.field)
        bar.field.currentEditor()?.selectAll(nil)
        findChanged()
    }

    /// The strip the visible find bar takes above the rows.
    private var findStrip: CGFloat {
        guard let findBar, !findBar.isHidden else { return 0 }
        return CodeFindBar.size.height + 8
    }

    private func makeFindBar() -> CodeFindBar {
        let bar = CodeFindBar(frame: NSRect(origin: .zero, size: CodeFindBar.size))
        bar.onChange = { [weak self] in self?.findChanged() }
        bar.onStep = { [weak self] backward in self?.stepFind(backward: backward) }
        bar.onClose = { [weak self] in self?.closeFind() }
        addSubview(bar)
        findBar = bar
        return bar
    }

    private func layoutFindBar() {
        guard let findBar else { return }
        let size = CodeFindBar.size
        findBar.frame = NSRect(x: max(0, bounds.width - size.width - 8), y: header.height + 4, width: min(size.width, bounds.width), height: size.height)
    }

    /// The query changed: match again, the current match the first at or below the top row.
    private func findChanged() {
        guard let findBar, let painter = rowsView.painter else { return }
        var find = CodeFind(query: findBar.field.stringValue, rows: painter.rows) { painter.text(ofEntry: $0) }
        let top = painter.rows.segment(rowsView.topRow)?.entry ?? 0
        find.current = find.matches.isEmpty ? nil : (find.matches.firstIndex { $0.entry >= top } ?? 0)
        rowsView.painter?.find = find
        findBar.show(status: find.status)
        revealCurrentMatch()
    }

    /// Return / ⇧Return: the next or previous match, wrapping around.
    private func stepFind(backward: Bool) {
        guard let find = rowsView.painter?.find, !find.matches.isEmpty else { return }
        let count = find.matches.count
        let current = find.current.map { backward ? ($0 - 1 + count) % count : ($0 + 1) % count } ?? (backward ? count - 1 : 0)
        rowsView.painter?.find?.current = current
        findBar?.show(status: rowsView.painter?.find?.status ?? "")
        revealCurrentMatch()
    }

    /// Scrolls the current match's row into view when it isn't (a follow tile then holds still).
    private func revealCurrentMatch() {
        guard let painter = rowsView.painter, let find = painter.find, let current = find.current else { return }
        let match = find.matches[current]
        let rows = painter.rows.rows(ofEntry: match.entry)
        let row = rows.first { painter.rows.segment($0)?.end.map { match.start < $0 } ?? true } ?? rows.lowerBound
        userInteracted()
        let top = CodePainter.rowTop(row)
        let visible = rowsView.bounds.insetBy(dx: 0, dy: CodeMetrics.verticalPadding)
        if top < visible.minY || top + CodeMetrics.rowHeight > visible.maxY { scroll(toRow: row) }
    }

    /// Esc: the bar goes, the highlights with it, and the keyboard returns to whoever had it
    /// before ⌘F (the rows, the canvas, a terminal), unless something else took it meanwhile.
    private func closeFind() {
        guard let findBar, !findBar.isHidden else { return }
        let hadKeyboard = findBar.holdsKeyboard
        findBar.isHidden = true
        rowsView.painter?.find = nil
        resizeSubviews(withOldSize: bounds.size)
        if hadKeyboard, let window { CanvasView.returnKeyboard(to: findPreviousResponder, in: window) }
        findPreviousResponder = nil
    }

    /// The code as VoiceOver's text area: the range's lines (else those in view), each after its
    /// number, labelled with the lines it holds.
    private(set) lazy var accessibleText: AccessibleTextElement? = AccessibleTextElement(view: rowsView, label: { [weak self] in
        self?.rowsView.accessibleLines.map { $0.count == 1 ? "line \($0.lowerBound)" : "lines \($0.lowerBound)–\($0.upperBound)" }
    }, read: { [weak self] in self?.rowsView.accessibleText() })
}

// MARK: Presentation

extension CodeTile {
    /// Bring the range into view (a few rows below the top), or the top of a new file.
    private func showRange() {
        guard showsCurrent, let rows = rowsView.painter?.rows else { return }
        guard let range = displayed.range else { return scroll(toRow: 0) }
        let first = rows.index(ofLine: range.start)
        scroll(toRow: first, count: rows.rows(ofLine: range.end).upperBound - first)
    }

    /// The frame was resized by someone other than the user dragging it (an agent's
    /// `object.update` frame or `size: "fit"`, undo): show the range by the tile's rule again, so
    /// a tile fitted to its range shows exactly it. The user's own resizes and scrolls keep the
    /// line at the top where it was (`rewrap`).
    func resizedElsewhere() {
        showRange()
    }

    /// Scroll `row` near the top with up to three rows of context above it, fewer when the tile
    /// can't show that context and all `count` rows too (`CodeMetrics.scrollOffset`: the rule
    /// line-bound arrows and offscreen routing assume).
    private func scroll(toRow row: Int, count: Int = 1) {
        let offset = CodeMetrics.scrollOffset(toRow: row, count: count, viewport: rowsView.bounds.height, totalRows: rowsView.painter?.rows.count)
        rowsView.scroll(toY: offset)
    }

    private func startFlash(_ lines: [Range<Int>]) {
        guard !lines.isEmpty, isLive else { return }
        flash = (lines, Self.now)
        rowsView.painter?.flash = (lines, 1)
        guard flashTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            // A tile freed mid-flash must not leave the timer waking the main thread forever.
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.flashTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    private func flashStrength(_ start: TimeInterval) -> CGFloat {
        let t = min(1, (Self.now - start) / Self.flashDuration)
        return CGFloat(1 - t * t)
    }

    private func flashTick() {
        guard let flash, Self.now - flash.start < Self.flashDuration else { return stopFlash() }
        rowsView.painter?.flash = (flash.lines, flashStrength(flash.start))
    }

    private func stopFlash() {
        flashTimer?.invalidate()
        flashTimer = nil
        flash = nil
        rowsView.painter?.flash = nil
    }

    private func refreshHeader() {
        showHeader(for: showsCurrent ? document : nil)
    }

    private func showHeader(for document: CodeDocument?) {
        // A pinned tile, or one reading its ref's objects, has no diff base to pick.
        let warning = [staleReason.map { "stale: \($0)" }, document?.warning].compactMap { $0 }.joined(separator: " · ")
        let readOnly = pinnedCommit != nil || (source.ref != nil && document.map { $0.isPinned || $0.diff.state == .pinUnavailable } ?? true)
        header.show(diffBase: readOnly ? nil : diffBaseProp, defaultBranch: defaultBranch(for: document), baseDescription: document?.baseDescription,
                    status: document?.status ?? "loading…", warning: warning.isEmpty ? nil : warning, changes: !(document?.signs.isEmpty ?? true), follow: followOf != nil, missed: lock.missed)
        let before = header.height
        let history = followOf == nil ? [] : self.history
        header.show(history: history.map(\.aim), edited: history.map(\.edited), current: displayed)
        if header.height != before { resizeSubviews(withOldSize: bounds.size) }
    }

    /// The default branch the base picker names (`Branch vs origin/main`): the one the
    /// merge-base was taken with, else as the repository's files say (read once per repository).
    private func defaultBranch(for document: CodeDocument?) -> String? {
        guard let diff = document?.diff, let repository = diff.repository else { return nil }
        if let branch = diff.baseLabel.flatMap(GitDiffEngine.ResolvedBase.mergeBaseBranch) { return branch }
        if let known = knownDefaultBranch, known.repository == repository { return known.branch }
        let branch = GitWorktree.containing(repository)?.defaultBranch
        knownDefaultBranch = (repository, branch)
        return branch
    }

    /// The follow history, newest first, each location with whether the agent edited it there.
    private var history: [(aim: Aim, edited: Bool)] {
        (object.props["history"]?.array ?? []).compactMap { entry in
            Self.aim(entry).map { ($0, Board.isEdit(entry["action"]?.string)) }
        }
    }

    // MARK: Actions

    private func setBase(_ base: String) {
        guard base != diffBaseProp else { return }
        _ = try? board.update(object.id, props: .object(["diffBase": .string(base)]))
    }

    private func togglePeek(_ sign: Int) {
        guard let document, showsCurrent, document.signs.indices.contains(sign), document.signs[sign].peekable else { return }
        if peeked.remove(sign) == nil { peeked.insert(sign) }
        refreshPainter(keepSelection: false)
    }

    /// Scroll to the change after (or before) the line a few rows below the top.
    private func jumpToChange(forward: Bool) {
        guard let document, showsCurrent, let rows = rowsView.painter?.rows else { return }
        userInteracted()
        let anchorRow = rowsView.topRow + 3
        let line: Int
        switch rows.row(min(anchorRow, rows.count - 1)) {
        case .line(let number)?: line = number
        case .peek(_, let sign)?: line = document.signs[sign].lines.lowerBound
        case nil: line = 1
        }
        if let target = document.changeLine(after: line, forward: forward) {
            scroll(toRow: rows.index(ofLine: target))
        }
    }

    /// Keep what the follow tile shows as a permanent code tile beside it.
    private func pin() {
        _ = try? board.pin(object.id, path: displayed.path, range: displayed.range)
    }

    /// Open the user's editor (`$VISUAL`/`$EDITOR` from the login shell, else nvim or vi) at the
    /// clicked line in a terminal tile beside this one, in view (`CanvasView.openForUser`).
    private func editHere(at point: NSPoint) {
        guard let document, showsCurrent, document.side == .new, !document.isPinned else { return }
        board.keepCode(object.id)
        let line = displayedLine(atY: point.y) ?? displayed.range?.start ?? 1
        let path = document.readPath
        Task { [weak self] in
            // The login shell is a blocking subprocess (once, then cached).
            let argv = await offPool {
                let shell = LoginShell.shared
                let editor = shell.editor
                let fallback = editor == nil && shell.resolve("nvim") == nil ? "vi" : "nvim"
                return EditorCommand.argv(editor: editor, fallback: fallback, line: line, path: path)
            }
            guard let self, let canvas = self.enclosingScrollView as? CanvasView else { return }
            canvas.openForUser(.terminal, props: .object([
                "cwd": .string(self.board.root.path),
                "command": .array(argv.map(JSONValue.string)),
            ]), near: self.object.id)
        }
    }

    /// Displayed line of a row; peek rows map to the line their change sits at.
    private func displayedLine(atY y: CGFloat) -> Int? {
        guard let document, let rows = rowsView.painter?.rows else { return nil }
        switch rows.row(CodePainter.row(atY: y)) {
        case .line(let line)?: return line
        case .peek(_, let sign)?: return min(document.signs[sign].lines.lowerBound, max(1, document.text.lineCount))
        case nil: return nil
        }
    }

    // MARK: File watching

    /// Reload (debounced) when the file is written or replaced; editors and agents often rename
    /// over it. A missing file watches its directory so creating it shows up.
    private func watch(_ url: URL) {
        var target = url.path
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory) {
            target = url.deletingLastPathComponent().path
        }
        guard target != watchedPath else { return }
        if watcherSuspended { watcher?.resume() }
        watcher?.cancel()
        watcher = nil
        watcherSuspended = false
        watchedPath = target
        let fd = open(target, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !source.data.intersection([.rename, .delete]).isEmpty { self.watchedPath = nil }
                self.scheduleReload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadWork = nil
                self?.load()
            }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

// MARK: TileContent

extension CodeTile {
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live {
            if watcherSuspended { watcher?.resume() }
            watcherSuspended = false
            addSubview(rowsView)
            addSubview(header)
            navigation?.setActive(true)
            if needsLoad { load() }
        } else {
            if !watcherSuspended { watcher?.suspend() }
            watcherSuspended = watcher != nil
            // A cancelled load or a pending debounced reload must run when the tile comes back.
            if loadTask != nil || reloadWork != nil { needsLoad = true }
            reloadWork?.cancel()
            reloadWork = nil
            loadTask?.cancel()
            loadTask = nil
            stopFlash()
            vanishCheck?.cancel()
            vanishCheck = nil
            // Nothing with tracking areas, tooltips, or a backing store stays in the window: the
            // card covers the tile, and pans would otherwise update them every frame.
            navigation?.setActive(false)
            rowsView.releaseCaches()
            rowsView.removeFromSuperview()
            header.removeFromSuperview()
            if let heldRepository {
                Task { await GitDiffEngine.shared.release(heldRepository) }
                self.heldRepository = nil
                // Bases aren't watched while offscreen, so revalidate on return.
                needsLoad = true
            }
        }
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? {
        guard let document, showsCurrent, let painter = rowsView.painter, rowsView.superview === self, rowsView.frame.contains(point) else { return nil }
        let local = rowsView.convert(point, from: self)
        let segment = painter.rows.segment(CodePainter.row(atY: local.y))
        if let selected = rowsView.selectedEntries, let segment, selected.contains(segment.entry) {
            return target(entries: selected, painter: painter, document: document)
        }
        if rowsView.isInGutter(local), let sign = painter.sign(atY: local.y), !painter.rows.peekedSigns.contains(sign) {
            let change = document.signs[sign]
            if change.lines.isEmpty {
                return code(LineRange(start: change.old.lowerBound, end: change.old.upperBound - 1), side: .old, in: document)
            }
            return code(LineRange(start: change.lines.lowerBound, end: change.lines.upperBound - 1), side: document.side, in: document)
        }
        // A continuation row mentions its whole line.
        guard let segment else { return nil }
        return target(entries: segment.entry...segment.entry, painter: painter, document: document)
    }

    /// Edit › Mention: the selected text's lines; else, with the keyboard in the rows, the range
    /// the tile shows (nil without one: the whole tile).
    func keyboardMention(hasKeyboard: Bool) async -> MentionTarget? {
        guard let document, showsCurrent, let painter = rowsView.painter else { return nil }
        if let selected = rowsView.selectedEntries { return target(entries: selected, painter: painter, document: document) }
        guard hasKeyboard, let range = displayed.range, let lines = document.lines(for: range) else { return nil }
        return code(LineRange(start: lines.lowerBound, end: lines.upperBound), side: document.side, in: document)
    }

    /// The lines a run of entries shows: displayed lines when there are any, else peeked base
    /// lines.
    private func target(entries: ClosedRange<Int>, painter: CodePainter, document: CodeDocument) -> MentionTarget? {
        var lines: [Int] = []
        var old: [Int] = []
        for entry in entries {
            switch painter.rows.entryRow(entry) {
            case .line(let line)?: lines.append(line)
            case .peek(let line, _)?: old.append(line)
            case nil: break
            }
        }
        if let first = lines.min(), let last = lines.max() {
            return code(LineRange(start: first, end: last), side: document.side, in: document)
        }
        guard let first = old.min(), let last = old.max() else { return nil }
        return code(LineRange(start: first, end: last), side: .old, in: document)
    }

    /// Mentions carry the diff base while the tile shows changes against it, so the prompt can
    /// quote base lines and name the base however the tile changes before the tray drains.
    private func code(_ lines: LineRange, side: DiffSide, in document: CodeDocument) -> MentionTarget {
        let commit = side == .old ? document.diff.base : document.mentionCommit
        return .code(object: object.id, path: document.readPath, lines: lines, side: commit == nil || document.isPinned ? nil : side.rawValue,
                     symbol: document.enclosingSymbol(lines: lines, side: side), commit: commit)
    }

    func scrollToMention(_ target: MentionTarget) {
        guard case .code(_, let path, let lines, let side, _, _, _) = target, let document, showsCurrent, path == document.path,
              let rows = rowsView.painter?.rows else { return }
        if side == DiffSide.old.rawValue, document.side == .new {
            guard let sign = document.signs.firstIndex(where: { $0.old.contains(lines.start) }) else { return }
            scroll(toRow: rows.peekedSigns.contains(sign) ? rows.index(ofPeek: sign, old: lines.start) ?? 0 : rows.edgeRow(ofLine: document.signs[sign].lines.lowerBound))
        } else {
            let first = rows.index(ofLine: lines.start)
            scroll(toRow: first, count: max(1, rows.rows(ofLine: lines.end).upperBound - first))
        }
    }

    func outline(for target: MentionTarget) -> NSRect? {
        guard case .code(_, let path, let lines, let side, _, _, _) = target, let document, showsCurrent, path == document.path,
              let rows = rowsView.painter?.rows else { return nil }
        let first: Int?, last: Int?
        if side == DiffSide.old.rawValue, document.side == .new {
            let sign = document.signs.firstIndex { $0.old.contains(lines.start) }
            if let sign, rows.peekedSigns.contains(sign) {
                first = rows.index(ofPeek: sign, old: lines.start)
                last = rows.entry(ofPeek: sign, old: min(lines.end, document.signs[sign].old.upperBound - 1)).map { rows.rows(ofEntry: $0).upperBound - 1 }
            } else if let sign {
                // An unpeeked deletion: its wedge.
                let edge = CodePainter.rowTop(rows.edgeRow(ofLine: document.signs[sign].lines.lowerBound))
                let rect = NSRect(x: rowsView.bounds.minX, y: edge - 3, width: rowsView.bounds.width, height: 6)
                return convert(rect, from: rowsView).intersection(rowsView.frame)
            } else {
                return nil
            }
        } else {
            first = rows.index(ofLine: lines.start)
            last = rows.rows(ofLine: lines.end).upperBound - 1
        }
        guard let first, let last else { return nil }
        let rect = NSRect(x: rowsView.bounds.minX, y: CodePainter.rowTop(first), width: rowsView.bounds.width,
                          height: CGFloat(last - first + 1) * CodeMetrics.rowHeight)
        return convert(rect, from: rowsView).intersection(rowsView.frame)
    }

    var takesKeyboardFocus: Bool { false }

    var headerHeight: CGFloat { header.height }

    /// Hidden canvas chrome: the header's first row goes and the rows move up into its place
    /// (`CodeHeaderBar.presenting`); arrows bound to lines re-attach (`rowsMoved`).
    func setPresenting(_ presenting: Bool) {
        guard header.presenting != presenting else { return }
        header.presenting = presenting
        resizeSubviews(withOldSize: bounds.size)
    }

    /// Return on the selected tile: the rows take the keyboard (arrows, pages, Home/End scroll;
    /// ⌘F finds; Esc goes back to the canvas).
    func enterKeyboard() -> Bool {
        window?.makeFirstResponder(rowsView) == true
    }

    enum KeyboardNavigation { case definition, definitionInNewTile, references, outline }

    /// Go to Definition, Find References and Outline from the menu bar, where no pointer names a
    /// symbol: at the selection's start, else the first name that isn't a keyword from the tile's
    /// anchor line (the first line of its range, else the top row) down through its range and the
    /// rows in view (`CodeSubject.first`: a tile aimed at a closing brace or a comment means the
    /// next name below it). With no name there, a message in the tile says to select one. False
    /// when there is nothing to act on (a deleted file, nothing loaded yet).
    @discardableResult
    func navigate(_ action: KeyboardNavigation) -> Bool {
        guard let navigation, let document, showsCurrent, let painter = rowsView.painter else { return false }
        let topRow = rowsView.topRow
        if action == .outline {
            navigation.showOutline(anchor: NSPoint(x: painter.gutterWidth + 8, y: CodePainter.rowTop(topRow)))
            return true
        }
        guard document.side == .new else { return false }
        var subject: (line: Int, character: Int)?
        if let selection = painter.selection, selection.start < selection.end, case .line(let line)? = painter.rows.entryRow(selection.start.entry) {
            subject = (line, selection.start.offset)
        } else {
            let shown = painter.visibleRows(rowsView.bounds).compactMap { row -> Int? in
                if case .line(let line)? = painter.rows.row(row) { line } else { nil }
            }
            if let anchor = displayed.range?.start ?? shown.min(),
               let found = CodeSubject.first(from: anchor, through: max(displayed.range?.end ?? anchor, shown.max() ?? anchor), line: { document.text(of: .line($0)) }) {
                subject = (found.line, found.character)
            }
        }
        guard let subject else {
            navigation.showMessage("Nothing named here to act on: select a name first", anchor: NSPoint(x: painter.gutterWidth + 8, y: CodePainter.rowTop(topRow)))
            return true
        }
        reveal(line: subject.line)
        let row = painter.rows.index(ofLine: subject.line)
        let anchor = NSPoint(x: painter.gutterWidth + 8, y: CodePainter.rowTop(row))
        switch action {
        case .definition: navigation.goToDefinition(at: subject, anchor: anchor, newTile: false)
        case .definitionInNewTile: navigation.goToDefinition(at: subject, anchor: anchor, newTile: true)
        case .references: navigation.findReferences(at: subject, anchor: anchor)
        case .outline: break
        }
        return true
    }

    /// Whether `navigate` has anything to act on (menu validation).
    var canNavigate: Bool { document != nil && showsCurrent && rowsView.painter != nil }

    // MARK: Offscreen drawing

    /// The body (header, caption, history, rows) for renders and cards. Rows are drawn from the
    /// model, never from live views, so it works offscreen, not live, and on any Space; the header
    /// is the tile's own header view drawn offscreen, showing `document` when it isn't on screen,
    /// so a card looks exactly like the live tile. The content is the range (the whole file
    /// without one): its rows and longest line under the header, what `size: "fit"` shows (the
    /// caption's own width is `layout.check`'s `truncated`, not content). `full` draws all of
    /// it, scrolled to the range by the tile's rule.
    private func image(of document: CodeDocument, size: CGSize, scale: CGFloat, full: Bool, appearance: NSAppearance) -> (image: NSImage?, content: CGSize) {
        // Wrapped at the tile's width, exactly as the live rows are.
        let rows = document.rows(peeked: showsCurrent ? peeked : [], width: size.width)
        var painter = CodePainter(document: document, rows: rows)
        painter.rangeLines = tintedRange.flatMap(document.lines(for:))
        // Off screen, the header shows this document; on screen it already shows the live one.
        if header.window == nil {
            showHeader(for: document)
            if header.frame.width != size.width { header.frame.size.width = size.width }
        }
        header.prepareForSnapshot()
        let headerHeight = header.height
        let headerImage = TileRenderRequest(size: header.bounds.size, scale: scale, full: false, appearance: appearance).image(of: header)
        let content = document.content(range: displayed.range, rows: rows, width: size.width, headerHeight: headerHeight)
        var fullScroll: CGFloat = 0
        if let lines = displayed.range.flatMap(document.lines(for:)) {
            let first = rows.index(ofLine: lines.lowerBound)
            let count = rows.rows(ofLine: lines.upperBound).upperBound - first
            fullScroll = CodeMetrics.scrollOffset(toRow: first, count: count, viewport: max(size.height, content.height) - headerHeight, totalRows: rows.count)
        }
        var imageSize = full ? CGSize(width: size.width, height: max(size.height, content.height)) : size
        // One bitmap dimension stays within what Core Graphics and memory allow.
        let maxPoints = 16_384 / max(scale, 0.1)
        imageSize = CGSize(width: min(imageSize.width, maxPoints), height: min(imageSize.height, maxPoints))
        let width = Int((imageSize.width * scale).rounded(.up)), height = Int((imageSize.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bitmap = NSGraphicsContext(bitmapImageRep: rep) else { return (nil, content) }
        rep.size = imageSize
        let scrollY = full ? fullScroll : (showsCurrent && document.path == self.document?.path ? rowsView.bounds.minY : 0)
        appearance.performAsCurrentDrawingAppearance {
            let cg = bitmap.cgContext
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: 0, y: imageSize.height)
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            headerImage?.drawUpright(in: NSRect(x: 0, y: 0, width: header.bounds.width, height: headerHeight))
            let rowsRect = CGRect(x: 0, y: scrollY, width: imageSize.width, height: max(0, imageSize.height - headerHeight))
            cg.saveGState()
            cg.clip(to: CGRect(x: 0, y: headerHeight, width: imageSize.width, height: rowsRect.height))
            cg.translateBy(x: 0, y: headerHeight - scrollY)
            painter.draw(in: cg, rect: rowsRect, cache: nil)
            cg.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            cg.restoreGState()
        }
        let image = NSImage(size: imageSize)
        image.addRepresentation(rep)
        return (image, content)
    }

    func render(_ request: TileRenderRequest) async -> TileRender {
        guard let document = await loadOffscreen(), !Task.isCancelled else {
            return .placeholder(request, Task.isCancelled ? "cancelled" : "the tile changed while loading")
        }
        let drawn = image(of: document, size: request.size, scale: request.scale, full: request.full, appearance: request.appearance)
        guard let image = drawn.image else { return TileRender(image: nil, contentSize: drawn.content, state: .failed, reason: "could not allocate the bitmap") }
        return TileRender(image: image, contentSize: drawn.content, state: .rendered, reason: nil)
    }

    /// Cards requested together (a pinch out over a dozen live tiles) render one per wake:
    /// drawn back to back in the liveness pass, ~5 ms each held the first frame after the pinch
    /// for ~45 ms. The live view stays up until its card arrives.
    func cardSnapshot(_ deliver: @escaping @MainActor (NSImage?) -> Void) {
        let appearance = effectiveAppearance
        let size = bounds.size
        Task { [weak self] in
            await MainTurns.next()
            guard let self else { return deliver(nil) }
            if self.documentIsCurrent, let document = self.document {
                return deliver(self.image(of: document, size: size, scale: TileFrameView.cardPixelsPerPoint, full: false, appearance: appearance).image)
            }
            guard let document = await self.loadOffscreen() else { return deliver(nil) }
            deliver(self.image(of: document, size: size, scale: TileFrameView.cardPixelsPerPoint, full: false, appearance: appearance).image)
        }
    }
}

// MARK: Code navigation (CodeNavigationHost)

extension CodeTile: CodeNavigationHost {
    var navigationPath: String { showsCurrent ? document?.readPath ?? displayed.path : displayed.path }

    var navigationView: NSView { rowsView }

    var navigationLineHeight: CGFloat { CodeMetrics.rowHeight }

    /// 1-based line and 0-based UTF-16 column of the working-tree file at a point in the rows
    /// view (a continuation row maps into its line past the wrap); nil over peeked base rows,
    /// the gutter, below the last row, and deleted files.
    func sourcePosition(atViewPoint point: NSPoint) -> (line: Int, character: Int)? {
        guard let document, showsCurrent, document.side == .new, !rowsView.isInGutter(point),
              case .line(let line)? = rowsView.painter?.rows.row(CodePainter.row(atY: point.y)),
              let position = rowsView.position(at: point) else { return nil }
        return (line, position.offset)
    }

    /// The http(s) URL written under a point in the rows view (a comment, a string, a Markdown
    /// link), whichever side of a diff the line is on; nil over the gutter, below the last row,
    /// and anywhere else.
    func webLink(atViewPoint point: NSPoint) -> URL? {
        guard !rowsView.isInGutter(point), let painter = rowsView.painter, case .line? = painter.rows.row(CodePainter.row(atY: point.y)),
              let position = rowsView.position(at: point) else { return nil }
        return WebLink.match(in: painter.text(ofEntry: position.entry) as String, at: position.offset)?.url
    }

    func reveal(line: Int) {
        guard showsCurrent, let rows = rowsView.painter?.rows else { return }
        scroll(toRow: rows.index(ofLine: line))
    }
}

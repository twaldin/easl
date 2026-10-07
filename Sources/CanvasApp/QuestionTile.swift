import AppKit
import CanvasCore

/// A question an agent asks the user (`type: question`, `QuestionSpec`): the question, its
/// options as buttons (the recommended one marked, each with its why), an optional note, links
/// to the context (opened beside the tile), and who asks. Number keys pick, Return answers
/// (`Board.answerQuestion`, which hands the answer to an asking terminal). Once closed it
/// collapses to the outcome: the answer and who gave it when, or that it was cancelled or
/// expired (dimmed); Return in it then archives it. Its text scales with the chrome text size,
/// like the title bar's. The question's text selects with a drag and copies (⌘C, Copy), and its
/// web links open beside the tile on a click (`PaintedText`, `TextPress`). VoiceOver reads the
/// whole question (`accessibleText`) and presses its painted controls (`QuestionControlElement`).
@MainActor
final class QuestionTile: NSView, TileContent, NSTextFieldDelegate {
    private var object: CanvasObject
    private let board: Board
    private var spec: QuestionSpec
    /// The option picked with a click or its number key, waiting for Return or Answer.
    private var picked: String?
    private let scroll = NSScrollView()
    private let page = QuestionPage()
    private let note = NSTextField()
    private var painter: QuestionPainter?
    /// The question's text selected by a drag, for ⌘C and the context menu's Copy; kept while
    /// the tile has the keyboard.
    private var selection: NSRange?
    /// A press on the question's text until its release: a click on a link, or a drag selecting.
    private var press: TextPress?
    /// The painted controls for accessibility, the same element for a control across layouts
    /// (VoiceOver stays on an option a pick lays the page out again around).
    fileprivate private(set) var controlElements: [QuestionControlElement] = []

    /// A context link opened: code (the tile, whether it was already on the board), a web page,
    /// or an object on the board to go to.
    var onOpenedCode: ((ObjectID, Bool) -> Void)?
    var onOpenedLink: ((ObjectID) -> Void)?
    var onGoTo: ((ObjectID) -> Void)?

    init(object: CanvasObject, board: Board) {
        self.object = object
        self.board = board
        spec = QuestionSpec(object.props)
        super.init(frame: NSRect(origin: .zero, size: RenderMath.body(of: object)))
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        scroll.documentView = page
        addSubview(scroll)
        page.tile = self
        note.placeholderString = "Add a note (optional)"
        note.bezelStyle = .roundedBezel
        note.delegate = self
        note.cell?.sendsActionOnEndEditing = false
        page.addSubview(note)
        NotificationCenter.default.addObserver(self, selector: #selector(relayout), name: ChromeText.didChange, object: nil)
        relayout()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    nonisolated override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        relayout()
    }

    /// Lays the page out at the tile's width and chrome text scale; the note field sits where
    /// the painter left room for it while the question is open.
    @objc private func relayout() {
        let width = max(120, scroll.contentSize.width)
        let painter = QuestionPainter(spec: spec, object: object, board: board, width: width, scale: ChromeText.scale, picked: picked,
                                      noting: !note.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        self.painter = painter
        let previous = controlElements
        controlElements = painter.controls.map { control in
            guard let element = previous.first(where: { $0.control.hit == control.hit }) else { return QuestionControlElement(page: page, control: control) }
            element.control = control
            return element
        }
        page.frame = NSRect(x: 0, y: 0, width: width, height: max(painter.height, scroll.contentSize.height))
        note.isHidden = painter.noteRect == nil
        if let rect = painter.noteRect {
            note.frame = rect
            note.font = ChromeText.font(QuestionPainter.noteFont)
        } else if window?.firstResponder === note.currentEditor() {
            window?.makeFirstResponder(self)
        }
        // The pointing hand follows the controls and the links in the text as they move.
        window?.invalidateCursorRects(for: page)
        page.needsDisplay = true
    }

    fileprivate func paint(in rect: NSRect) {
        painter?.draw(in: rect, noteDrawn: false, selection: selection)
    }

    // MARK: Acting

    /// Picks `id` (a click or its number key); picking the picked one again unpicks it.
    private func pick(_ id: String) {
        guard spec.status == .open else { return }
        picked = picked == id ? nil : id
        relayout()
    }

    /// Answers with the picked option and the note; nothing until one of them is given.
    private func confirm() {
        let text = note.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard spec.status == .open, picked != nil || !text.isEmpty else { return }
        do {
            try board.answerQuestion(object.id, option: picked, note: text.isEmpty ? nil : text)
            picked = nil
            note.stringValue = ""
            leave()
        } catch {
            NSSound.beep()
        }
    }

    private func dismiss() {
        _ = try? board.cancelQuestion(object.id)
        leave()
    }

    /// Hides the closed question (`Board.archiveQuestion`). Its tile goes, so the keyboard, when it
    /// is here, goes back to the canvas first.
    private func archive() {
        leave()
        if (try? board.archiveQuestion(object.id)) == nil { NSSound.beep() }
    }

    /// The keyboard back to the canvas, the tile still selected.
    private func leave() {
        guard window?.firstResponder === self || window?.firstResponder === note.currentEditor() else { return }
        (enclosingCanvas)?.leaveTile(object.id)
    }

    private var enclosingCanvas: CanvasView? {
        var view: NSView? = superview
        while let current = view, !(current is CanvasView) { view = current.superview }
        return view as? CanvasView
    }

    /// Context links, and the web links in the question's text, open beside the tile: code with
    /// `Board.openForNavigation`, web pages with `Board.openLink`; an object is gone to where it is.
    private func open(_ context: QuestionSpec.Context) {
        switch context {
        case .object(let id):
            guard board.objects[id] != nil else { return NSSound.beep() }
            onGoTo?(id)
        case .url(let text):
            guard let url = URL(string: text) else { return NSSound.beep() }
            if WebLink.isWeb(url) {
                onOpenedLink?(board.openLink(url, near: object.id, caller: nil).object.id)
            } else {
                ExternalOpen.open(url, because: "question \(object.id) context")
            }
        case .path(let path, let lines):
            let opened = board.openForNavigation(CodeAim(path: board.boardPath(path, linkRoot: board.root), range: lines), from: object.id)
            onOpenedCode?(opened.id, opened.existing)
        }
    }

    /// A press on the page: on the question's text it selects or follows a link once it is
    /// released or dragged (`TextPress`); on a control it acts at once. Anywhere on an open
    /// question it gives the tile the keyboard, for its number keys and Return.
    fileprivate func pressed(_ event: NSEvent, at point: NSPoint) {
        if let text = painter?.question, text.rect.contains(point) {
            if takesKeyboardFocus { window?.makeFirstResponder(self) }
            let offset = text.offset(at: point)
            var press = TextPress(at: event.locationInWindow, offset: offset, on: text.link(at: point),
                                  extending: event.modifierFlags.contains(.shift) ? selection : nil)
            // A plain press clears the selection; a ⇧-press extends it at once.
            select(press.move(to: event.locationInWindow, offset: offset, in: text.string))
            self.press = press
            return
        }
        if let hit = painter?.hit(point) {
            perform(hit)
        } else if takesKeyboardFocus {
            window?.makeFirstResponder(self)
        }
    }

    fileprivate func dragged(_ event: NSEvent, at point: NSPoint) {
        guard var press, let text = painter?.question else { return }
        let range = press.move(to: event.locationInWindow, offset: text.offset(at: point), in: text.string)
        self.press = press
        if let range { select(range) }
    }

    /// A click on a link (no drag) follows it.
    fileprivate func released() {
        guard let press else { return }
        self.press = nil
        if let link = press.follows { perform(.link(link)) }
    }

    /// What a control does, clicked or pressed through accessibility.
    fileprivate func perform(_ hit: QuestionPainter.Hit) {
        switch hit {
        case .option(let id):
            window?.makeFirstResponder(self)
            pick(id)
        case .context(let context): open(context)
        case .link(let link): open(.url(link.url.absoluteString))
        case .answer: confirm()
        case .dismiss: dismiss()
        case .archive: archive()
        }
    }

    // MARK: Selecting

    /// `range` of the question's text selected (nil or empty: nothing, which a press on the text
    /// starts with). A selection takes the keyboard, so ⌘C reaches it, a closed question's too.
    private func select(_ range: NSRange?) {
        let range = range.flatMap { $0.length > 0 ? $0 : nil }
        if range != nil, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard range != selection else { return }
        selection = range
        page.needsDisplay = true
    }

    fileprivate var selectedText: String? {
        guard let selection, let text = painter?.question, NSMaxRange(selection) <= (text.string as NSString).length else { return nil }
        return (text.string as NSString).substring(with: selection)
    }

    /// ⌘C, and Copy in the context menu: the selected text (private on a remote board's
    /// question, as its other copies are).
    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return NSSound.beep() }
        NSPasteboard.general.clear(privately: board.isRemote)
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The selection lasts while the tile has the keyboard: once ⌘C would go elsewhere, it goes.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            press = nil
            select(nil)
        }
        return resigned
    }

    // MARK: Keyboard

    /// Open or closed, Return gives it the keyboard (`enterKeyboard`), and so does selecting its
    /// text (for ⌘C); a click on its body or going to it (⌘J, Go to) only while open
    /// (`takesKeyboardFocus`).
    override var acceptsFirstResponder: Bool { true }

    /// Open: 1–9 pick the options in order, Return answers, Tab goes to the note. Closed: Return
    /// archives. Esc gives the keyboard back to the canvas.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return super.keyDown(with: event) }
        let open = spec.status == .open
        switch event.keyCode {
        case 53: return leave()
        case 36, 76: return open ? confirm() : archive()
        case 48 where open:
            window?.makeFirstResponder(note)
            return
        default: break
        }
        if open, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit), digit <= spec.options.count {
            pick(spec.options[digit - 1].id)
        } else {
            super.keyDown(with: event)
        }
    }

    /// In the note: Return answers, Esc goes back to the options.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            confirm()
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            window?.makeFirstResponder(self)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        // The Answer button turns on with the first character of a note.
        relayout()
    }

    // MARK: TileContent

    func setLive(_ live: Bool) {}

    func render(_ request: TileRenderRequest) async -> TileRender {
        let painter = QuestionPainter(spec: spec, object: object, board: board, width: request.size.width, scale: 1, picked: picked,
                                      noting: !note.stringValue.isEmpty, note: note.stringValue)
        let content = CGSize(width: request.size.width, height: painter.height)
        let size = request.full ? CGSize(width: request.size.width, height: max(request.size.height, content.height)) : request.size
        let image = request.image(size: size) { bounds in
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            painter.draw(in: bounds, noteDrawn: true)
        }
        guard let image else { return TileRender(image: nil, contentSize: content, state: .failed, reason: "bitmap allocation failed") }
        return TileRender(image: image, contentSize: content, state: .rendered)
    }

    func mentionTarget(at point: NSPoint) -> MentionTarget? { .object(object.id) }

    func outline(for target: MentionTarget) -> NSRect? { bounds }

    /// A click on its body, or going to it, gives an open question the keyboard; a closed one
    /// takes it only by Return or a selection in its text (its Return archives, so no arrival
    /// should hand it a Return).
    var takesKeyboardFocus: Bool { spec.status == .open }

    /// The keyboard to the question: open, for its number keys, note and Return (answers);
    /// closed, for Return (archives).
    func enterKeyboard() -> Bool {
        window?.makeFirstResponder(self) == true
    }

    /// What VoiceOver reads in the tile: the question, its options, context, asker and status
    /// with the answer (`QuestionPainter.readout`).
    private(set) lazy var accessibleText: AccessibleTextElement? = AccessibleTextElement(view: self, label: { "question" }, read: { [weak self] in
        guard let self, let painter = self.painter else { return nil }
        return AccessibleText(painter.readout(object: self.object, board: self.board))
    })

    func update(_ object: CanvasObject) {
        let closing = spec.status == .open && QuestionSpec.status(of: object.props) != .open
        let asked = spec.question
        self.object = object
        spec = QuestionSpec(object.props)
        if let picked, spec.option(picked) == nil || spec.status != .open { self.picked = nil }
        // Reworded: the selection's offsets were into the old text.
        if spec.question != asked {
            press = nil
            select(nil)
        }
        // Closed while it had the keyboard (answered here, or cancelled or expired meanwhile): the
        // canvas takes the keyboard back, so a Return meant to answer never archives instead.
        if closing { leave() }
        relayout()
    }
}

/// The scrolling page a question tile paints on; clicks go to the tile.
@MainActor
private final class QuestionPage: NSView {
    weak var tile: QuestionTile?

    nonisolated override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        tile?.paint(in: bounds)
    }

    /// A click on an option, a button or a link acts even while the window isn't key, as a note's
    /// links do; a drag on the question's text selects it then too.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        tile?.pressed(event, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        tile?.dragged(event, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        tile?.released()
    }

    /// The tile's menu, led by Copy while the question's text is selected.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tile, tile.selectedText != nil else { return super.menu(for: event) }
        var view = superview
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        let items = menu ?? NSMenu()
        if items.numberOfItems > 0 { items.insertItem(.separator(), at: 0) }
        let copy = NSMenuItem(title: "Copy", action: #selector(QuestionTile.copy(_:)), keyEquivalent: "")
        copy.target = tile
        items.insertItem(copy, at: 0)
        return items
    }

    override func resetCursorRects() {
        // Buttons and links (context chips, web links in the text) show they act.
        for rect in tile?.clickableRects ?? [] { addCursorRect(rect, cursor: .pointingHand) }
    }

    /// The note field with the painted controls around it, in reading order: the options and
    /// links above it, the buttons below.
    override func accessibilityChildren() -> [Any]? {
        let views = super.accessibilityChildren() ?? []
        guard let tile else { return views }
        let noteTop = tile.noteTop
        let elements = tile.controlElements
        return elements.filter { $0.control.rect.minY < noteTop } + views + elements.filter { $0.control.rect.minY >= noteTop }
    }
}

extension QuestionTile: NSMenuItemValidation {
    fileprivate var clickableRects: [NSRect] { painter?.clickable ?? [] }
    fileprivate var noteTop: CGFloat { painter?.noteRect?.minY ?? .greatestFiniteMagnitude }

    /// Copy (⌘C) only with question text selected.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(copy(_:)) ? selectedText != nil : true
    }
}

/// A question's painted control (an option, a context link, a web link in its text, Answer,
/// Dismiss, Archive) for VoiceOver and Full Keyboard Access: over its rect on the page, saying
/// what it says there, and pressed as it is clicked (`QuestionTile.perform`). An option is a radio
/// button, on when picked.
@MainActor
private final class QuestionControlElement: NSAccessibilityElement {
    private weak var page: QuestionPage?
    var control: QuestionPainter.Control

    init(page: QuestionPage, control: QuestionPainter.Control) {
        self.page = page
        self.control = control
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        onMain { element in
            switch element.control.hit {
            case .option: .radioButton
            case .context, .link: .link
            case .answer, .dismiss, .archive: .button
            }
        }
    }
    override func accessibilityLabel() -> String? { onMain { $0.control.label } }
    override func accessibilityValue() -> Any? {
        onMain { element in
            guard case .option = element.control.hit else { return nil }
            return NSNumber(value: element.control.picked ? 1 : 0)
        }
    }
    override func isAccessibilityEnabled() -> Bool { onMain { $0.control.enabled } }
    override func accessibilityParent() -> Any? { onMain { $0.page.flatMap { NSAccessibility.unignoredAncestor(of: $0) } } }
    override func accessibilityFrame() -> NSRect {
        onMain { element in
            guard let page = element.page, page.window != nil else { return .zero }
            return NSAccessibility.screenRect(fromView: page, rect: element.control.rect)
        }
    }
    override func accessibilityPerformPress() -> Bool {
        onMain { element in
            guard element.control.enabled, let tile = element.page?.tile else { return false }
            tile.perform(element.control.hit)
            return true
        }
    }

    /// AppKit declares the accessibility methods nonisolated but calls them on the main thread.
    private nonisolated func onMain<T>(_ body: @MainActor (QuestionControlElement) -> T) -> T {
        nonisolated(unsafe) let element = self
        nonisolated(unsafe) var result: T?
        MainActor.assumeIsolated { result = body(element) }
        return result!
    }
}

/// A question tile's layout and drawing, live and for renders: everything is placed once per
/// width, scale and state, then drawn and hit-tested from the same rects.
@MainActor
struct QuestionPainter {
    enum Hit: Equatable {
        case option(String), context(QuestionSpec.Context), link(WebLink.Match), answer, dismiss, archive
    }

    /// Something on the page that acts: where it is, what it does, and what it says, for
    /// accessibility (`QuestionControlElement`).
    struct Control {
        let rect: NSRect
        let hit: Hit
        /// An option's number, label, recommendation and why; a link's or a button's title.
        let label: String
        /// Answer before anything is picked or noted is drawn but takes no click.
        var enabled = true
        /// An option that is picked.
        var picked = false
        /// Where it takes a click when that isn't all of `rect`: a web link in the question's
        /// text, a rect per line it runs over (`rect` holds them all).
        var areas: [NSRect] = []

        var clickable: [NSRect] { areas.isEmpty ? [rect] : areas }
    }

    static let questionFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let whyFont = NSFont.systemFont(ofSize: 11.5)
    static let metaFont = NSFont.systemFont(ofSize: 11)
    static let keyFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    static let noteFont = NSFont.systemFont(ofSize: 13)

    private let spec: QuestionSpec
    private let scale: CGFloat
    private let width: CGFloat
    private let picked: String?
    private let noting: Bool
    /// Drawn in the note field's place by renders (live, the field draws itself).
    private let noteText: String
    private var items: [(rect: NSRect, draw: () -> Void)] = []
    private(set) var controls: [Control] = []
    private(set) var noteRect: NSRect?
    private(set) var height: CGFloat = 0
    /// The question's text, which selects and holds web links, and its index in `items`.
    private(set) var question: PaintedText?
    private var questionItem: Int?

    var clickable: [NSRect] { controls.filter(\.enabled).flatMap(\.clickable) }

    init(spec: QuestionSpec, object: CanvasObject, board: Board, width: CGFloat, scale: Double, picked: String?, noting: Bool, note: String = "") {
        self.spec = spec
        self.scale = CGFloat(scale)
        self.width = width
        self.picked = picked
        self.noting = noting
        noteText = note
        layout(object: object, board: board)
    }

    private func font(_ base: NSFont) -> NSFont { ChromeText.font(base, scale: Double(scale)) }
    private func points(_ base: CGFloat) -> CGFloat { (base * scale).rounded() }

    private func text(_ string: String, _ base: NSFont, _ color: NSColor, truncating: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncating ? .byTruncatingTail : .byWordWrapping
        return NSAttributedString(string: string, attributes: [.font: font(base), .foregroundColor: color, .paragraphStyle: style])
    }

    private static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        let rect = text.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// Adds `text` at `y` wrapped to `width` from `x`; returns the y below it.
    private mutating func place(_ text: NSAttributedString, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let size = Self.measure(text, width: width)
        let rect = NSRect(x: x, y: y, width: width, height: size.height)
        items.append((rect, { text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading]) }))
        return rect.maxY
    }

    /// Adds the question's text at `y`, its web links (`WebLink.matches`) in link color and each a
    /// control (`PaintedText`); returns the y below it.
    private mutating func placeQuestion(_ base: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let links = WebLink.matches(in: spec.question)
        let string = NSMutableAttributedString(attributedString: text(spec.question, base, color))
        for link in links { string.addAttribute(.foregroundColor, value: NSColor.linkColor, range: link.range) }
        let question = PaintedText(string, links: links, in: NSRect(x: x, y: y, width: width, height: Self.measure(string, width: width).height))
        self.question = question
        questionItem = items.count
        items.append((question.rect, { question.draw() }))
        for link in question.links {
            controls.append(Control(rect: link.areas.reduce(NSRect.null) { $0.union($1) }, hit: .link(link.match),
                                    label: (spec.question as NSString).substring(with: link.match.range), areas: link.areas))
        }
        return question.rect.maxY
    }

    /// A terminal as people name it: its `name`, else what its header shows.
    private func terminal(_ id: ObjectID, board: Board) -> String {
        guard let object = board.objects[id] else { return "terminal \(id)" }
        return object.props["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? board.terminalLabel?(id) ?? "terminal"
    }

    private func who(_ actor: Actor?, board: Board) -> String {
        switch actor {
        case .agent(let tile)?: terminal(tile, board: board)
        case .user?, nil: "you"
        }
    }

    private func asker(board: Board) -> String {
        guard let asker = spec.asker else { return "someone" }
        if let name = asker.name { return asker.host.map { "\(name)@\($0)" } ?? name }
        return asker.tile.map { terminal($0, board: board) } ?? "someone"
    }

    private static func when(_ date: Date) -> String {
        let format = DateFormatter()
        format.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        format.timeStyle = .short
        return format.string(from: date)
    }

    private mutating func layout(object: CanvasObject, board: Board) {
        let inset = points(14), inner = max(40, width - 2 * inset)
        var y = inset
        let secondary = NSColor.secondaryLabelColor
        if spec.status == .open {
            var meta = "Asked by \(asker(board: board))"
            if let expires = spec.expiresAt { meta += " · expires \(Self.when(expires))" }
            y = place(text(meta, Self.metaFont, secondary, truncating: true), x: inset, y: y, width: inner) + points(4)
            y = placeQuestion(Self.questionFont, .labelColor, x: inset, y: y, width: inner) + points(10)
            for (index, option) in spec.options.enumerated() {
                y = placeOption(option, index: index, x: inset, y: y, width: inner) + points(6)
            }
            y = placeContext(x: inset, y: y + points(2), width: inner, board: board)
            let field = NSRect(x: inset, y: y + points(2), width: inner, height: points(24))
            noteRect = field
            if !noteText.isEmpty {
                let note = text(noteText, Self.noteFont, .labelColor, truncating: true)
                items.append((field, {
                    NSColor.separatorColor.setStroke()
                    NSBezierPath(roundedRect: field.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
                    note.draw(with: field.insetBy(dx: 6, dy: 4), options: [.usesLineFragmentOrigin])
                }))
            }
            y = field.maxY + points(10)
            y = placeFooter(x: inset, y: y, width: inner)
        } else {
            y = placeQuestion(Self.labelFont, secondary, x: inset, y: y, width: inner) + points(8)
            y = placeOutcome(object: object, board: board, x: inset, y: y, width: inner)
        }
        height = y + inset
    }

    private mutating func placeOption(_ option: QuestionSpec.Option, index: Int, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let pad = points(9), key = points(20)
        let recommended = option.id == spec.recommended
        let isPicked = option.id == picked
        let badge = recommended ? text("Recommended", Self.metaFont, .controlAccentColor) : nil
        let badgeSize = badge.map { Self.measure($0, width: 200) } ?? .zero
        let textX = x + pad + key + points(8)
        let textWidth = max(20, width - (textX - x) - pad - (badge == nil ? 0 : badgeSize.width + points(8)))
        let label = text(option.label, Self.labelFont, .labelColor)
        let why = option.why.map { text($0, Self.whyFont, .secondaryLabelColor) }
        let labelSize = Self.measure(label, width: textWidth)
        let whySize = why.map { Self.measure($0, width: textWidth) } ?? .zero
        let rowHeight = max(key, labelSize.height + (why == nil ? 0 : points(2) + whySize.height)) + 2 * pad
        let row = NSRect(x: x, y: y, width: width, height: rowHeight)
        let number = index < 9 ? "\(index + 1)" : ""
        let keyText = text(number, Self.keyFont, isPicked ? .white : .secondaryLabelColor)
        let keyRect = NSRect(x: x + pad, y: y + pad, width: key, height: key)
        items.append((row, {
            let shape = NSBezierPath(roundedRect: row.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            (isPicked ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).setFill()
            shape.fill()
            (isPicked || recommended ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            shape.lineWidth = isPicked ? 2 : 1
            shape.stroke()
            let circle = NSBezierPath(roundedRect: keyRect, xRadius: key / 2, yRadius: key / 2)
            (isPicked ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor.withAlphaComponent(0.25)).setFill()
            circle.fill()
            let size = keyText.size()
            keyText.draw(at: NSPoint(x: keyRect.midX - size.width / 2, y: keyRect.midY - size.height / 2))
            label.draw(with: NSRect(x: textX, y: y + pad, width: textWidth, height: labelSize.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
            why?.draw(with: NSRect(x: textX, y: y + pad + labelSize.height + (why == nil ? 0 : 2), width: textWidth, height: whySize.height),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
            badge?.draw(at: NSPoint(x: row.maxX - pad - badgeSize.width, y: y + pad + 2))
        }))
        controls.append(Control(rect: row, hit: .option(option.id), label: Self.optionLabel(option, number: index + 1, recommended: recommended), picked: isPicked))
        return row.maxY
    }

    private mutating func placeContext(x: CGFloat, y: CGFloat, width: CGFloat, board: Board) -> CGFloat {
        guard !spec.context.isEmpty else { return y }
        let lead = text("Context:", Self.metaFont, .secondaryLabelColor)
        let leadSize = Self.measure(lead, width: width)
        items.append((NSRect(x: x, y: y + 2, width: leadSize.width, height: leadSize.height), { lead.draw(at: NSPoint(x: x, y: y + 2)) }))
        var cursor = x + leadSize.width + points(6), line = y
        let chipHeight = points(20), gap = points(6)
        for context in spec.context {
            let title = Self.contextTitle(context, board: board)
            let label = text(title, Self.metaFont, .linkColor, truncating: true)
            let chipWidth = min(Self.measure(label, width: 400).width + 2 * gap, width)
            if cursor + chipWidth > x + width, cursor > x + leadSize.width + points(6) {
                cursor = x
                line += chipHeight + points(4)
            }
            let chip = NSRect(x: cursor, y: line, width: chipWidth, height: chipHeight)
            items.append((chip, {
                NSColor.linkColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
                label.draw(with: chip.insetBy(dx: gap, dy: 3), options: [.usesLineFragmentOrigin])
            }))
            controls.append(Control(rect: chip, hit: .context(context), label: title))
            cursor = chip.maxX + gap
        }
        return line + chipHeight + points(6)
    }

    private static func objectTitle(_ object: CanvasObject) -> String {
        let title = TileFrameView.title(for: object)
        return title.count > 40 ? String(title.prefix(39)) + "…" : title
    }

    /// A context link's text: an object's title (or that it is gone), else the URL or path as stored.
    private static func contextTitle(_ context: QuestionSpec.Context, board: Board) -> String {
        guard case .object(let id) = context else { return context.label }
        return board.objects[id].map(objectTitle) ?? "\(id) (gone)"
    }

    /// An option as accessibility says it: "2. Later (recommended): the freeze is Friday".
    private static func optionLabel(_ option: QuestionSpec.Option, number: Int, recommended: Bool) -> String {
        "\(number). \(option.label)" + (recommended ? " (recommended)" : "") + (option.why.map { ": \($0)" } ?? "")
    }

    private mutating func button(_ title: String, prominent: Bool, enabled: Bool, right: CGFloat, y: CGFloat, hit: Hit) -> NSRect {
        let label = text(title, Self.labelFont, prominent ? (enabled ? .white : .tertiaryLabelColor) : (enabled ? .labelColor : .tertiaryLabelColor))
        let size = Self.measure(label, width: 300)
        let rect = NSRect(x: right - size.width - points(24), y: y, width: size.width + points(24), height: points(26))
        items.append((rect, {
            let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            if prominent {
                (enabled ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor.withAlphaComponent(0.25)).setFill()
                shape.fill()
            } else {
                NSColor.separatorColor.setStroke()
                shape.stroke()
            }
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }))
        controls.append(Control(rect: rect, hit: hit, label: title, enabled: enabled))
        return rect
    }

    private mutating func placeFooter(x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let answer = button("Answer", prominent: true, enabled: picked != nil || noting, right: x + width, y: y, hit: .answer)
        let dismiss = button("Dismiss", prominent: false, enabled: true, right: answer.minX - points(8), y: y, hit: .dismiss)
        let count = min(spec.options.count, 9)
        let hint = count == 0 ? "↩ answer" : count == 1 ? "1 picks · ↩ answers" : "1–\(count) pick · ↩ answers"
        let label = text(hint, Self.metaFont, .tertiaryLabelColor, truncating: true)
        let hintWidth = max(0, dismiss.minX - x - points(8))
        let size = Self.measure(label, width: hintWidth)
        let rect = NSRect(x: x, y: answer.midY - size.height / 2, width: hintWidth, height: size.height)
        items.append((rect, { label.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }))
        return answer.maxY
    }

    private mutating func placeOutcome(object: CanvasObject, board: Board, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        var y = y
        let headline: String
        var byline: String
        switch spec.status {
        case .answered:
            let answer = spec.answer
            headline = "✓ " + (spec.option(answer?.option).map(\.label) ?? answer?.option ?? "Answered")
            byline = "Answered by \(who(answer?.by, board: board))"
            if let at = answer?.at { byline += " · \(Self.when(at))" }
        case .cancelled:
            headline = "Cancelled"
            byline = "Cancelled · \(Self.when(object.updatedAt))"
        case .expired:
            headline = "Expired"
            byline = "Expired · \(Self.when(spec.expiresAt ?? object.updatedAt))"
        case .open:
            headline = ""
            byline = ""
        }
        byline += " · asked by \(asker(board: board))"
        y = place(text(headline, Self.questionFont, spec.status == .answered ? .labelColor : .secondaryLabelColor), x: x, y: y, width: width) + points(4)
        if spec.status == .answered, let note = spec.answer?.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            y = place(text("“\(note)”", Self.noteFont, .labelColor), x: x, y: y, width: width) + points(6)
        }
        let archive = button("Archive", prominent: false, enabled: true, right: x + width, y: y, hit: .archive)
        let label = text(byline, Self.metaFont, .secondaryLabelColor, truncating: true)
        let bylineWidth = max(0, archive.minX - x - points(8))
        let size = Self.measure(label, width: bylineWidth)
        let rect = NSRect(x: x, y: archive.midY - size.height / 2, width: bylineWidth, height: size.height)
        items.append((rect, { label.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }))
        return archive.maxY
    }

    /// The question as VoiceOver reads it (`QuestionTile.accessibleText`), a line each: the
    /// question, each option as its control says it, the context, who asks (and until when), and
    /// where it stands: open, or the answer with its note, who gave it and when, or the outcome.
    func readout(object: CanvasObject, board: Board) -> String {
        var lines = [spec.question]
        for (index, option) in spec.options.enumerated() {
            lines.append(Self.optionLabel(option, number: index + 1, recommended: option.id == spec.recommended))
        }
        if !spec.context.isEmpty {
            lines.append("Context: " + spec.context.map { Self.contextTitle($0, board: board) }.joined(separator: ", "))
        }
        var asked = "Asked by \(asker(board: board))"
        if spec.status == .open, let expires = spec.expiresAt { asked += ", expires \(Self.when(expires))" }
        lines.append(asked)
        switch spec.status {
        case .open:
            lines.append("Open")
        case .answered:
            let answer = spec.answer
            var line = (spec.option(answer?.option)?.label ?? answer?.option).map { "Answered: \($0)" } ?? "Answered"
            if let note = answer?.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { line += ", note: \(note)" }
            line += ", by \(who(answer?.by, board: board))"
            if let at = answer?.at { line += ", \(Self.when(at))" }
            lines.append(line)
        case .cancelled:
            lines.append("Cancelled, \(Self.when(object.updatedAt))")
        case .expired:
            lines.append("Expired, \(Self.when(spec.expiresAt ?? object.updatedAt))")
        }
        return lines.joined(separator: "\n")
    }

    func hit(_ point: NSPoint) -> Hit? {
        controls.last { $0.enabled && $0.clickable.contains { $0.contains(point) } }?.hit
    }

    /// Draws the page; a cancelled or expired question dimmed. `noteDrawn`: the note field is
    /// drawn here (renders), not by its own view. `selection`: the question's text selected
    /// (live only), highlighted as a text view highlights it.
    func draw(in bounds: NSRect, noteDrawn: Bool, selection: NSRange? = nil) {
        let dimmed = spec.status == .cancelled || spec.status == .expired
        let context = NSGraphicsContext.current?.cgContext
        if dimmed {
            context?.saveGState()
            context?.setAlpha(0.5)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        for (index, item) in items.enumerated() where item.rect.intersects(bounds) {
            if !noteDrawn, item.rect == noteRect { continue }
            if index == questionItem, let question {
                question.draw(selected: selection)
            } else {
                item.draw()
            }
        }
        if noteDrawn, let noteRect, noteText.isEmpty {
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: noteRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
            text("Add a note (optional)", Self.noteFont, .placeholderTextColor).draw(at: NSPoint(x: noteRect.minX + 6, y: noteRect.minY + 4))
        }
        if dimmed {
            context?.endTransparencyLayer()
            context?.restoreGState()
        }
    }
}

/// The board's open asks, beside the drawing toolbar: how many questions wait on the user
/// (`Board.waitingQuestions`); a click goes to the next one. Hidden when none waits.
@MainActor
final class AsksChip: NSButton {
    var onGo: (() -> Void)?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        refusesFirstResponder = true
        image = NSImage(systemSymbolName: "questionmark.bubble", accessibilityDescription: nil)
        imagePosition = .imageLeading
        contentTintColor = .controlAccentColor
        target = self
        action = #selector(go)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + ChromeText.scaled(16), height: ChromeText.scaled(28))
    }

    /// `count` waiting questions; the tooltip lists the first few.
    func show(_ waiting: [CanvasObject]) {
        isHidden = waiting.isEmpty
        guard !waiting.isEmpty else { return }
        let text = waiting.count == 1 ? "1 open ask" : "\(waiting.count) open asks"
        attributedTitle = NSAttributedString(string: " " + text, attributes: [
            .font: ChromeText.font(NSFont.systemFont(ofSize: 12, weight: .medium)), .foregroundColor: NSColor.controlAccentColor,
        ])
        toolTip = waiting.prefix(5).map { "• " + QuestionSpec($0.props).question }.joined(separator: "\n") + "\nClick to go to the next one (⌘J visits them with the rest)"
        invalidateIntrinsicContentSize()
    }

    @objc private func go() { onGo?() }
}

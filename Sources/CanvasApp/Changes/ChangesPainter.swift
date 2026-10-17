import AppKit
import CanvasCore

/// A button drawn in a changes tile's file or hunk header.
enum ChangesAction: String {
    case stage = "Stage"
    case unstage = "Unstage"
    case revert = "Discard"

    /// What `props.reviewed` calls it.
    var entryName: String {
        switch self {
        case .stage: "stage"
        case .unstage: "unstage"
        case .revert: "revert"
        }
    }

    var tooltip: String {
        switch self {
        case .stage: "Mark as ready to commit (git add)"
        case .unstage: "Take it out of what's staged (git restore --staged); your files stay as they are"
        case .revert: "Discard this uncommitted change from your files"
        }
    }

    /// Whether it has something to act on in a file's hunk (nil: the whole file): Stage while
    /// some of it isn't staged, Unstage while some of it is, Discard while some of it isn't
    /// committed (`HunkStatus`).
    func applies(to file: ChangedFile, hunk: Int?) -> Bool {
        let status = hunk.map { file.hunks[$0].status }
        switch self {
        case .stage: return status?.stageable ?? file.stageable
        case .unstage: return status?.unstageable ?? file.hunks.contains { $0.status.unstageable }
        case .revert: return status?.discardable ?? file.discardable
        }
    }

    /// What the header says when it doesn't (`applies`).
    var refusal: String {
        switch self {
        case .stage: "already staged"
        case .unstage: "not staged"
        case .revert: ChangesFailure.committed.message
        }
    }
}

/// What a point in a changes tile's body is over.
enum ChangesHit: Equatable {
    case button(ChangesAction, file: Int, hunk: Int?)
    case viewed(file: Int)
    case file(Int)
    case list
    case listed(Int)
    case hunk(file: Int, hunk: Int)
    case line(file: Int, hunk: Int, line: Int)
}

/// Laid-out diff rows on screen, keyed by what they show; each draw keeps only what it drew.
@MainActor
final class ChangesLineCache {
    struct Key: Hashable {
        var file: Int
        var side: DiffSide
        var line: Int
        /// Which visual row of a wrapped line, at which wrap width.
        var part: Int
        var columns: Int?
    }

    private var lines: [Key: CTLine] = [:]
    private var drawn: [Key: CTLine] = [:]

    func line(_ key: Key, make: () -> CTLine) -> CTLine {
        if let line = drawn[key] ?? lines[key] {
            drawn[key] = line
            return line
        }
        let line = make()
        drawn[key] = line
        return line
    }

    func commit() {
        lines = drawn
        drawn = [:]
    }

    func removeAll() {
        lines = [:]
        drawn = [:]
    }
}

/// Draws a changes tile's body in a flipped context: the header strip (summary, keys, the filter
/// box), then the rows scrolled by `scroll`: the file list, file headers with Viewed, Stage and
/// Discard, hunk headers with theirs, and unified-diff lines highlighted with a diff palette
/// (`CodeTheme.color`), soft-wrapped at the tile's width; the header of the file being read
/// stays pinned at the top. The live view, cards, and `view.render` all draw through this.
@MainActor
struct ChangesPainter {
    let set: ChangeSet
    let rows: ChangeRows
    let collapsed: Set<String>
    /// `props.viewed`: files marked Viewed (checked while their diff is the one marked).
    var viewed: JSONValue?
    /// The hunk j/k, Return, s and r act on.
    var current: (file: Int, hunk: Int)?
    /// Lines picked in one hunk (indices into its `lines`): s/r and its buttons act on them.
    var selection: (file: Int, hunk: Int, lines: Set<Int>)?
    /// A refusal or failure, shown in the header in place of the summary.
    var message: String?
    /// The Discard button asking to be pressed again (a file's when `hunk` is nil): it reads
    /// "Discard?" and the header shows `hint` (how to go on), the two always together.
    var discardAsked: (file: Int, hunk: Int?, hint: String)?
    /// The tile holds the keyboard: the header says which keys work.
    var focused = false
    var undoable = true
    /// The filter's text; `drawsFilter` draws its box (cards and renders, where no field is).
    let filter: String
    var drawsFilter = true
    /// Each file as the rows name it (`name(_:)`), worked out once.
    let names: [String]

    /// `laidOut`: rows and names worked out for the same set, folds, width, filter, and list
    /// (the live tile keeps them while only the current hunk or selection changes).
    init(set: ChangeSet, collapsed: Set<String>, width: CGFloat, filter: String, listOpen: Bool, laidOut: (rows: ChangeRows, names: [String])?) {
        self.set = set
        self.collapsed = collapsed
        self.filter = filter
        names = laidOut?.names ?? set.files.map(Self.name)
        rows = laidOut?.rows ?? ChangeRows(set, collapsed: collapsed, columns: ChangesMetrics.textColumns(width: width, digits: ChangesMetrics.digits(set)), filter: filter, listOpen: listOpen)
    }

    var digits: Int { ChangesMetrics.digits(set) }
    var gutterWidth: CGFloat { ChangesMetrics.gutterWidth(digits: digits) }
    var contentHeight: CGFloat { ChangesMetrics.headerHeight + rows.height + ChangesMetrics.bottomPadding }

    // MARK: Geometry

    /// A row's rect in body coordinates at `scroll`.
    func rect(ofRow index: Int, width: CGFloat, scroll: CGFloat) -> CGRect {
        CGRect(x: 0, y: ChangesMetrics.headerHeight + rows.tops[index] - scroll, width: width, height: rows.height(ofRow: index))
    }

    /// The pinned header of the file being read, when its own has scrolled away, and the space
    /// it covers under it (a sliver of the file's last row above the next file's header).
    func stickyRect(width: CGFloat, scroll: CGFloat) -> (file: Int, rect: CGRect, covered: CGRect)? {
        guard let sticky = rows.stickyFile(scroll: scroll) else { return nil }
        let rect = CGRect(x: 0, y: ChangesMetrics.headerHeight + sticky.offset, width: width, height: ChangesMetrics.fileHeight)
        return (sticky.file, rect, CGRect(x: 0, y: rect.minY, width: width, height: sticky.height))
    }

    /// The filter box in the header strip.
    static func filterRect(width: CGFloat) -> CGRect {
        let w = min(ChangesMetrics.filterWidth, max(80, width / 3))
        return CGRect(x: width - ChangesMetrics.trailingPadding + 4 - w, y: 3, width: w, height: ChangesMetrics.headerHeight - 6)
    }

    /// The row under a body point (the pinned file header over the rows it covers), nil over
    /// the header strip.
    func row(at point: CGPoint, width: CGFloat, scroll: CGFloat) -> Int? {
        guard point.y >= ChangesMetrics.headerHeight else { return nil }
        if let sticky = stickyRect(width: width, scroll: scroll), sticky.covered.contains(point) { return rows.index(ofFile: sticky.file) }
        return rows.index(atY: point.y - ChangesMetrics.headerHeight + scroll)
    }

    /// The rect a row is drawn in: the pinned one for a file header pinned at the top.
    func drawnRect(ofRow index: Int, width: CGFloat, scroll: CGFloat) -> CGRect {
        if case .file(let file) = rows.rows[index], let sticky = stickyRect(width: width, scroll: scroll), sticky.file == file { return sticky.rect }
        return rect(ofRow: index, width: width, scroll: scroll)
    }

    /// The two button places in a file or hunk header row, right-aligned: Stage's, then Discard's.
    static func buttonSlots(inRow rect: CGRect) -> (stage: CGRect, revert: CGRect) {
        let width = ChangesMetrics.buttonWidth, gap = ChangesMetrics.buttonGap
        let height = min(18, rect.height - 6)
        let y = rect.minY + (rect.height - height) / 2
        let revert = CGRect(x: rect.maxX - ChangesMetrics.trailingPadding - width, y: y, width: width, height: height)
        return (revert.offsetBy(dx: -(width + gap), dy: 0), revert)
    }

    /// The buttons a file (`hunk` nil) or hunk header row shows: Stage, or Unstage in its place
    /// once everything there is staged, and Discard unless all of it is committed (a branch
    /// reviewed against its merge-base: Discard never rewrites commits). None for two commits
    /// compared (`ChangedFile.readOnly`).
    func buttons(inRow rect: CGRect, file: Int, hunk: Int?) -> [(ChangesAction, CGRect)] {
        let changed = set.files[file]
        guard !changed.readOnly else { return [] }
        let slots = Self.buttonSlots(inRow: rect)
        let stage: ChangesAction = (hunk.map { changed.hunks[$0].status == .staged } ?? changed.unstageable) ? .unstage : .stage
        return ChangesAction.revert.applies(to: changed, hunk: hunk)
            ? [(stage, slots.stage), (.revert, slots.revert)] : [(stage, slots.stage)]
    }

    /// The file header's Viewed check, left of its buttons (at the right edge without them).
    func viewedRect(inRow rect: CGRect) -> CGRect {
        let slots = Self.buttonSlots(inRow: rect)
        let right = set.comparesCommits ? slots.revert.maxX : slots.stage.minX - 10
        return CGRect(x: right - ChangesMetrics.viewedWidth, y: slots.stage.minY, width: ChangesMetrics.viewedWidth, height: slots.stage.height)
    }

    func hit(at point: CGPoint, width: CGFloat, scroll: CGFloat) -> ChangesHit? {
        guard let index = row(at: point, width: width, scroll: scroll) else { return nil }
        let rect = drawnRect(ofRow: index, width: width, scroll: scroll)
        func button(_ file: Int, _ hunk: Int?) -> ChangesAction? {
            buttons(inRow: rect, file: file, hunk: hunk).first { $0.1.insetBy(dx: -2, dy: -2).contains(point) }?.0
        }
        switch rows.rows[index] {
        case .list: return .list
        case .listed(let file): return .listed(file)
        case .file(let file):
            guard set.files[file].notice == nil else { return .file(file) }
            if let action = button(file, nil) { return .button(action, file: file, hunk: nil) }
            if viewedRect(inRow: rect).insetBy(dx: -2, dy: -2).contains(point) { return .viewed(file: file) }
            return .file(file)
        case .hunk(let file, let hunk):
            if let action = button(file, hunk) { return .button(action, file: file, hunk: hunk) }
            return .hunk(file: file, hunk: hunk)
        case .line(let file, let hunk, let line): return .line(file: file, hunk: hunk, line: line)
        case .notice(let file): return .file(file)
        case .message, .omitted: return nil
        }
    }

    /// What the header, a button, a check, or a hunk header says when hovered.
    func tooltip(at point: CGPoint, width: CGFloat, scroll: CGFloat) -> String? {
        if point.y < ChangesMetrics.headerHeight {
            if Self.filterRect(width: width).contains(point) { return "Filter the files by path (/ from the keyboard)" }
            if let lead = headerLayout(width: width).lead, lead.rect.contains(point) {
                let what = set.comparesCommits ? "Click to compare with another base: everything the head changed since the default branch, or a commit or ref"
                    : "Click to compare with another base: the uncommitted changes, everything the branch changed, or a commit or ref"
                return [set.baseDescription ?? set.lead, what].joined(separator: "\n")
            }
            return [set.baseDescription, set.comparesCommits ? ChangesTile.readingTooltip : undoable ? ChangesTile.tooltip : ChangesTile.remoteTooltip].compactMap { $0 }.joined(separator: "\n")
        }
        switch hit(at: point, width: width, scroll: scroll) {
        case .button(let action, let file, let hunk)?:
            if hunk != nil, let selection, selection.file == file, selection.hunk == hunk { return action.tooltip + " (the selected lines)" }
            return action.tooltip + (hunk == nil ? " (the whole file)" : "")
        case .viewed?: return "Viewed: fold the file until its changes change"
        case .hunk(let file, let hunk)?:
            let target = set.files[file].hunks[hunk]
            let state: String
            switch target.status {
            case .unstaged: state = "not staged"
            case .partial: state = "partly staged: the index holds an earlier version of some of it"
            case .staged: state = "staged"
            case .committed: state = set.comparesCommits ? "in \(set.branch ?? "the head")" : "committed since the base (nothing to discard)"
            }
            return "\(target.header) · +\(target.added) −\(target.removed) · \(state)"
        case .file(let file)?: return set.files[file].oldBoardPath.map { "\($0) → \(set.files[file].boardPath)" } ?? set.files[file].boardPath
        case .list?: return "Click to fold or unfold the file list"
        case .listed(let file)?: return "Jump to \(set.files[file].boardPath)"
        case .line?:
            return set.comparesCommits ? "Click to open the line in a code tile pinned to its side's commit · drag, ⇧-click, or ⌘-click to select lines to mention"
                : "Click to open in a code tile · drag, ⇧-click, or ⌘-click to select lines (an edited line brings its old version), then Stage, Unstage, or Discard"
        case nil: return nil
        }
    }

    // MARK: Drawing

    /// Draws the body `size` points big with the rows scrolled by `scroll`.
    func draw(in context: CGContext, size: CGSize, scroll: CGFloat, cache: ChangesLineCache?) {
        let bounds = CGRect(origin: .zero, size: size)
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        context.saveGState()
        let body = CGRect(x: 0, y: ChangesMetrics.headerHeight, width: size.width, height: max(0, size.height - ChangesMetrics.headerHeight))
        context.clip(to: body)
        let visible = rows.visible(from: scroll, to: scroll + size.height - ChangesMetrics.headerHeight)
        for index in visible {
            drawRow(index, in: context, rect: rect(ofRow: index, width: size.width, scroll: scroll), cache: cache)
        }
        if let sticky = stickyRect(width: size.width, scroll: scroll) {
            NSColor.textBackgroundColor.setFill()
            sticky.covered.fill()
            drawFile(sticky.file, rect: sticky.rect)
            NSColor.separatorColor.setFill()
            CGRect(x: 0, y: sticky.covered.maxY - 0.5, width: size.width, height: 0.5).fill()
        }
        context.restoreGState()
        cache?.commit()
        drawHeader(width: size.width)
        drawScrollIndicator(size: size, scroll: scroll)
    }

    /// What the header strip shows and where: the lead (what is compared with what, `▾`: a click
    /// picks the base) and the counts, or a message or the line selection in their place, and
    /// the key hint when it fits beside all of that (a narrow header drops the hint before it
    /// cuts the summary).
    struct HeaderLayout {
        var lead: (text: String, rect: CGRect)?
        var rest: (text: String, rect: CGRect)
        var color: NSColor
        var hint: (text: String, rect: CGRect)?
    }

    static let headerFont = NSFont.systemFont(ofSize: 11)

    func headerLayout(width: CGFloat) -> HeaderLayout {
        let font = Self.headerFont, height = ChangesMetrics.headerHeight
        func measure(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let right = Self.filterRect(width: width).minX - 10
        let available = max(0, right - 10)
        var lead: String?
        let rest: String
        let color: NSColor
        if let hint = discardAsked?.hint ?? message {
            rest = hint
            color = .systemOrange
        } else if let selection, set.files.indices.contains(selection.file) {
            rest = "\(selection.lines.count) line\(selection.lines.count == 1 ? "" : "s") selected · " + (set.comparesCommits ? "m mention" : "s stage · u unstage · r ⌘⌫ discard · m mention")
            color = .controlAccentColor
        } else {
            lead = set.repository == nil ? nil : set.lead + " ▾"
            rest = lead == nil ? set.summary : set.counts.isEmpty ? "" : " · " + set.counts
            color = .secondaryLabelColor
        }
        let leadWidth = lead.map { ceil(measure($0)) } ?? 0, restWidth = ceil(measure(rest))
        var hint: (text: String, rect: CGRect)?
        var room = available
        if let text = ChangesMetrics.hint(ChangesMetrics.hints(focused: focused, actionable: set.actionable), available: available, summary: leadWidth + restWidth, width: measure) {
            let hintWidth = measure(text)
            hint = (text, CGRect(x: right - hintWidth, y: 0, width: hintWidth, height: height))
            room -= hintWidth + ChangesMetrics.hintGap
        }
        // Too long even alone: the lead and the counts share the room, the counts taking up to half.
        let restShown = lead == nil ? min(restWidth, room) : min(restWidth, max(room / 2, room - leadWidth))
        let leadShown = min(leadWidth, max(0, room - restShown))
        return HeaderLayout(lead: lead.map { ($0, CGRect(x: 10, y: 0, width: leadShown, height: height)) },
                            rest: (rest, CGRect(x: 10 + leadShown, y: 0, width: lead == nil ? room : restShown, height: height)),
                            color: color, hint: hint)
    }

    private func drawHeader(width: CGFloat) {
        let strip = CGRect(x: 0, y: 0, width: width, height: ChangesMetrics.headerHeight)
        NSColor.windowBackgroundColor.setFill()
        strip.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: strip.maxY - 0.5, width: width, height: 0.5).fill()
        let small = Self.headerFont
        let filterBox = Self.filterRect(width: width)
        if drawsFilter {
            let path = NSBezierPath(roundedRect: filterBox, xRadius: 5, yRadius: 5)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            let text = filter.isEmpty ? "Filter files" : filter
            drawText(text, at: CGPoint(x: filterBox.minX + 7, y: filterBox.minY), height: filterBox.height, width: filterBox.width - 14,
                     attributes: [.font: small, .foregroundColor: filter.isEmpty ? NSColor.placeholderTextColor : NSColor.labelColor])
        }
        let layout = headerLayout(width: width)
        if let hint = layout.hint {
            // The keys in the link blue while the keyboard is here (the accent read 4.2:1).
            drawText(hint.text, at: hint.rect.origin, height: hint.rect.height, width: hint.rect.width + 1,
                     attributes: [.font: small, .foregroundColor: focused ? NSColor.linkColor : CodeTheme.lineNumber])
        }
        if let lead = layout.lead {
            drawText(lead.text, at: lead.rect.origin, height: lead.rect.height, width: lead.rect.width + 1, attributes: [.font: small, .foregroundColor: NSColor.labelColor])
        }
        drawText(layout.rest.text, at: layout.rest.rect.origin, height: layout.rest.rect.height, width: layout.rest.rect.width + 1,
                 attributes: [.font: small, .foregroundColor: layout.color])
    }

    private func drawRow(_ index: Int, in context: CGContext, rect: CGRect, cache: ChangesLineCache?) {
        switch rows.rows[index] {
        case .list(let open): drawList(open: open, rect: rect)
        case .listed(let file): drawListed(file, rect: rect)
        case .file(let file): drawFile(file, rect: rect)
        case .hunk(let file, let hunk): drawHunk(file: file, hunk: hunk, rect: rect)
        case .line(let file, let hunk, let line): drawLine(file: file, hunk: hunk, line: line, wrap: rows.wraps[index], rect: rect, context: context, cache: cache)
        case .notice(let file):
            drawText(set.files[file].notice ?? "", at: CGPoint(x: gutterWidth, y: rect.minY), height: rect.height, width: rect.width - gutterWidth,
                     attributes: [.font: NSFont.systemFont(ofSize: 11).withTraits(.italic), .foregroundColor: NSColor.secondaryLabelColor])
        case .message(let text):
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: max(12, (rect.width - size.width) / 2), y: rect.minY + (rect.height - size.height) / 2), withAttributes: attributes)
        case .omitted(let count):
            drawText("… \(count) more changed file\(count == 1 ? "" : "s") (limit \(ChangeSet.maxFiles); narrow it with paths)", at: CGPoint(x: 12, y: rect.minY), height: rect.height,
                     width: rect.width - 24, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    private func drawList(open: Bool, rect: CGRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill()
        rect.fill()
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let count = rows.shown.count == set.files.count ? "\(set.files.count) files" : "\(rows.shown.count) of \(set.files.count) files"
        let viewedCount = set.files.filter { $0.isViewed(in: viewed) }.count
        let text = "\(open ? "▾" : "▸")  \(count)" + (viewedCount > 0 ? " · \(viewedCount) viewed" : "")
        drawText(text, at: CGPoint(x: 10, y: rect.minY), height: rect.height, width: rect.width - 20, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
    }

    private func drawListed(_ index: Int, rect: CGRect) {
        let file = set.files[index]
        let small = NSFont.systemFont(ofSize: 11)
        let isViewed = file.isViewed(in: viewed)
        var x: CGFloat = 26
        let (letter, color) = Self.badge(file.status)
        x += drawText(letter, at: CGPoint(x: x, y: rect.minY), height: rect.height, width: 14,
                      attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: color]) + 6
        let counts = Self.counts(file, size: 10)
        let countWidth = counts.size().width
        let check = isViewed ? "✓ " : ""
        let name = check + names[index]
        let drawn = drawText(name, at: CGPoint(x: x, y: rect.minY), height: rect.height, width: max(0, rect.width - x - countWidth - 24),
                             attributes: [.font: small, .foregroundColor: isViewed ? NSColor.secondaryLabelColor : NSColor.labelColor])
        counts.draw(at: CGPoint(x: x + drawn + 10, y: rect.minY + (rect.height - counts.size().height) / 2))
    }

    /// `+added −removed` in the diff's colors.
    private static func counts(_ file: ChangedFile, size: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let counts = NSMutableAttributedString(string: "+\(file.added)", attributes: [.font: font, .foregroundColor: CodeTheme.added])
        counts.append(NSAttributedString(string: " −\(file.removed)", attributes: [.font: font, .foregroundColor: CodeTheme.deleted]))
        return counts
    }

    private func drawFile(_ index: Int, rect: CGRect) {
        let file = set.files[index]
        NSColor.controlBackgroundColor.blended(withFraction: 0.5, of: NSColor.windowBackgroundColor)?.setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: rect.minY, width: rect.width, height: 0.5).fill()
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        var x: CGFloat = 8
        let chevron = collapsed.contains(file.boardPath) ? "▸" : "▾"
        x += drawText(chevron, at: CGPoint(x: x, y: rect.minY), height: rect.height, width: 14, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]) + 4
        let (letter, color) = Self.badge(file.status)
        let badge = CGRect(x: x, y: rect.midY - 8, width: 16, height: 16)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        let badgeAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: color]
        let letterSize = (letter as NSString).size(withAttributes: badgeAttributes)
        (letter as NSString).draw(at: CGPoint(x: badge.midX - letterSize.width / 2, y: badge.midY - letterSize.height / 2), withAttributes: badgeAttributes)
        x = badge.maxX + 8
        let actionable = file.notice == nil
        let right = (actionable ? viewedRect(inRow: rect).minX : rect.maxX) - 10
        let counts = Self.counts(file, size: 11)
        let countWidth = counts.size().width
        let name = names[index]
        let nameWidth = drawText(name, at: CGPoint(x: x, y: rect.minY), height: rect.height, width: max(0, right - x - countWidth - 12),
                                 attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        x += nameWidth + 10
        if x + countWidth < right { counts.draw(at: CGPoint(x: x, y: rect.minY + (rect.height - counts.size().height) / 2)) }
        // Binary, oversized, and mode-only files have no lines to patch.
        guard actionable else { return }
        drawViewed(file.isViewed(in: viewed), in: viewedRect(inRow: rect))
        drawButtons(buttons(inRow: rect, file: index, hunk: nil), file: index, hunk: nil)
    }

    private func drawViewed(_ checked: Bool, in frame: CGRect) {
        let box = CGRect(x: frame.minX, y: frame.midY - 6.5, width: 13, height: 13)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        (checked ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (checked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        if checked {
            let mark = NSBezierPath()
            mark.move(to: CGPoint(x: box.minX + 3, y: box.midY))
            mark.line(to: CGPoint(x: box.minX + 5.5, y: box.maxY - 3))
            mark.line(to: CGPoint(x: box.maxX - 2.5, y: box.minY + 3))
            mark.lineWidth = 1.8
            NSColor.white.setStroke()
            mark.stroke()
        }
        drawText("Viewed", at: CGPoint(x: box.maxX + 5, y: frame.minY), height: frame.height, width: frame.width - 18,
                 attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: checked ? NSColor.labelColor : NSColor.secondaryLabelColor])
    }

    private func drawHunk(file: Int, hunk: Int, rect: CGRect) {
        let changed = set.files[file], target = changed.hunks[hunk]
        let isCurrent = current.map { $0 == (file, hunk) } ?? false
        (isCurrent ? NSColor.controlAccentColor.withAlphaComponent(0.22) : NSColor.systemBlue.withAlphaComponent(0.06)).setFill()
        rect.fill()
        if isCurrent { drawCurrentBar(rect) }
        var text = target.label
        let side: DiffSide = target.mappings.allSatisfy(\.modified.isEmpty) ? .old : .new
        let line = side == .old ? target.mappings.first?.original.lowerBound ?? 1 : target.modified.lowerBound
        if let symbol = changed.symbol(lines: LineRange(start: line, end: line), side: side) { text += " · \(symbol)" }
        let buttons = buttons(inRow: rect, file: file, hunk: hunk)
        var right = (buttons.first?.1.minX ?? rect.maxX) - 10
        if !changed.readOnly, let pill = Self.pill(target.status) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: pill.color]
            let size = (pill.text as NSString).size(withAttributes: attributes)
            let frame = CGRect(x: right - size.width - 10, y: rect.midY - 8, width: size.width + 10, height: 16)
            pill.color.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
            (pill.text as NSString).draw(at: CGPoint(x: frame.minX + 5, y: frame.midY - size.height / 2), withAttributes: attributes)
            right = frame.minX - 8
        }
        if let selection, selection.file == file, selection.hunk == hunk {
            let note = "\(selection.lines.count) selected"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]
            let size = (note as NSString).size(withAttributes: attributes)
            (note as NSString).draw(at: CGPoint(x: right - size.width, y: rect.midY - size.height / 2), withAttributes: attributes)
            right -= size.width + 8
        }
        drawText(text, at: CGPoint(x: 12, y: rect.minY), height: rect.height, width: max(0, right - 12),
                 attributes: [.font: NSFont.systemFont(ofSize: 11, weight: isCurrent ? .semibold : .regular), .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.secondaryLabelColor])
        drawButtons(buttons, file: file, hunk: hunk)
    }

    static func pill(_ status: HunkStatus) -> (text: String, color: NSColor)? {
        switch status {
        case .unstaged: nil
        case .partial: ("partly staged", .systemOrange)
        case .staged: ("staged", CodeTheme.added)
        case .committed: ("committed", .secondaryLabelColor)
        }
    }

    /// The current hunk's marker: a bold accent bar down its left edge.
    private func drawCurrentBar(_ rect: CGRect) {
        NSColor.controlAccentColor.setFill()
        CGRect(x: 0, y: rect.minY, width: 5, height: rect.height).fill()
    }

    private func drawButtons(_ buttons: [(ChangesAction, CGRect)], file: Int, hunk: Int?) {
        for (action, frame) in buttons {
            let enabled = action != .stage || action.applies(to: set.files[file], hunk: hunk)
            let asking = action == .revert && discardAsked.map { $0.file == file && $0.hunk == hunk } == true
            (asking ? NSColor.systemRed : NSColor.controlColor).setFill()
            let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            let tint: NSColor = asking ? .white : !enabled ? .tertiaryLabelColor : action == .revert ? .systemRed : .labelColor
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: asking ? .semibold : .regular), .foregroundColor: tint]
            let title = asking ? "Discard?" : action.rawValue
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func drawLine(file: Int, hunk: Int, line: Int, wrap: ChangeRows.Wrap?, rect: CGRect, context: CGContext, cache: ChangesLineCache?) {
        let changed = set.files[file]
        let row = changed.hunks[hunk].lines[line]
        switch row.kind {
        case .added:
            CodeTheme.added.withAlphaComponent(0.14).setFill()
            rect.fill()
        case .removed:
            CodeTheme.deleted.withAlphaComponent(0.14).setFill()
            rect.fill()
        case .context: break
        }
        if let selection, selection.file == file, selection.hunk == hunk, selection.lines.contains(line) {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55).setFill()
            rect.fill()
        }
        if let current, current == (file, hunk) {
            NSColor.controlAccentColor.withAlphaComponent(0.05).setFill()
            rect.fill()
            drawCurrentBar(rect)
        }
        let advance = CodeMetrics.charAdvance
        let columns = CGFloat(digits) * advance
        let numbers: [NSAttributedString.Key: Any] = [.font: CodeTheme.font, .foregroundColor: CodeTheme.lineNumber.cgColor]
        let oldRight = ChangesMetrics.gutterLeading + columns, newRight = oldRight + ChangesMetrics.numberGap / 2 + columns
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (number, right) in [(row.old, oldRight), (row.new, newRight)] {
            guard let number else { continue }
            let label = String(number)
            context.textPosition = CGPoint(x: right - CGFloat(label.count) * advance, y: rect.minY + CodeMetrics.baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: numbers)), context)
        }
        let sign = row.kind == .added ? "+" : row.kind == .removed ? "−" : ""
        let signX = newRight + ChangesMetrics.numberGap / 2 + 3
        if !sign.isEmpty {
            let color = row.kind == .added ? CodeTheme.added : CodeTheme.deleted
            context.textPosition = CGPoint(x: signX, y: rect.minY + CodeMetrics.baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: sign, attributes: [.font: CodeTheme.font, .foregroundColor: color.cgColor])), context)
        }
        let side: DiffSide = row.kind == .removed ? .old : .new
        let text = side == .old ? changed.old : changed.new
        if let number = side == .old ? row.old : row.new, number >= 1, number <= text.lineCount {
            let whole = text.line(number)
            let length = whole.utf16.count
            let starts = [0] + (wrap?.breaks ?? [])
            for (part, start) in starts.enumerated() {
                let end = part + 1 < starts.count ? starts[part + 1] : length
                let top = rect.minY + CGFloat(part) * ChangesMetrics.lineHeight
                let x = gutterWidth + (part > 0 ? CGFloat(wrap?.indent ?? 0) * advance : 0)
                if part > 0 {
                    let hook = CTLineCreateWithAttributedString(NSAttributedString(string: "↪", attributes: [.font: CodeTheme.font, .foregroundColor: NSColor.quaternaryLabelColor.cgColor]))
                    context.textPosition = CGPoint(x: signX - 2, y: top + CodeMetrics.baseline)
                    CTLineDraw(hook, context)
                }
                let key = ChangesLineCache.Key(file: file, side: side, line: number, part: part, columns: wrap == nil ? nil : rows.columns)
                let make = { makeLine(changed, side: side, line: number, whole: whole, start: start, end: end) }
                let laid = cache?.line(key, make: make) ?? make()
                context.saveGState()
                context.clip(to: CGRect(x: gutterWidth, y: top, width: max(0, rect.width - gutterWidth), height: ChangesMetrics.lineHeight))
                context.textPosition = CGPoint(x: x, y: top + CodeMetrics.baseline)
                CTLineDraw(laid, context)
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    /// One visual row of a side's line (UTF-16 `start..<end` of it), tabs expanded against the
    /// whole line, highlighted by its syntax runs.
    private func makeLine(_ file: ChangedFile, side: DiffSide, line: Int, whole: String, start: Int, end: Int) -> CTLine {
        let units = Array(whole.utf16)
        let slice = String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
        let startColumn = start > 0 && units[..<end].contains(0x09) ? CodeMetrics.columns(units: units[..<start]) : 0
        let row = CodeRowText(line: slice, start: start, startColumn: startColumn)
        let string = NSMutableAttributedString(string: row.display, attributes: [.font: CodeTheme.font, .foregroundColor: NSColor.labelColor.cgColor])
        for run in (side == .old ? file.oldSyntax : file.newSyntax).runs(line: line) {
            let lower = max(Int(run.start), start), upper = min(Int(run.end), end)
            guard lower < upper else { continue }
            let from = row.display(ofOffset: lower), to = row.display(ofOffset: upper)
            guard from < to else { continue }
            string.addAttribute(.foregroundColor, value: CodeTheme.color(run.style).cgColor, range: NSRange(location: from, length: to - from))
        }
        return CTLineCreateWithAttributedString(string)
    }

    private func drawScrollIndicator(size: CGSize, scroll: CGFloat) {
        let viewport = size.height - ChangesMetrics.headerHeight
        let content = contentHeight - ChangesMetrics.headerHeight
        guard content > viewport + 0.5, viewport > 0 else { return }
        let length = max(24, viewport * viewport / content)
        let y = ChangesMetrics.headerHeight + (viewport - length) * scroll / (content - viewport)
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: CGRect(x: size.width - 5, y: y + 2, width: 3, height: length - 4), xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// Text on one line, vertically centered in `height` from `origin.y`, truncated to `width`;
    /// returns the width drawn.
    @discardableResult
    private func drawText(_ text: String, at origin: CGPoint, height: CGFloat, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        guard width > 4 else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        var attributes = attributes
        attributes[.paragraphStyle] = style
        let size = (text as NSString).size(withAttributes: attributes)
        let drawn = min(size.width, width)
        (text as NSString).draw(with: CGRect(x: origin.x, y: origin.y + (height - size.height) / 2, width: drawn + 1, height: size.height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        return drawn
    }

    /// A file as its header and the list name it: its path in the reviewed worktree (another
    /// worktree's files aren't prefixed with its directory on every row: the title names it),
    /// `old → new` for a rename.
    static func name(_ file: ChangedFile) -> String {
        func shown(_ boardPath: String, _ path: String) -> String { boardPath.hasPrefix("/") ? path : boardPath }
        let path = shown(file.boardPath, file.path)
        return file.oldBoardPath.map { "\(shown($0, file.oldPath ?? $0)) → \(path)" } ?? path
    }

    static func badge(_ status: ChangeStatus) -> (String, NSColor) {
        switch status {
        case .added: ("A", CodeTheme.added)
        case .modified: ("M", CodeTheme.modified)
        case .deleted: ("D", CodeTheme.deleted)
        case .renamed: ("R", .systemPurple)
        }
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }
}

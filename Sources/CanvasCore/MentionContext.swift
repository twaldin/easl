import Foundation

/// The page elements under part of a browser or HTML tile (a shape drawn over it), as the page
/// lays them out now: the outermost elements it mostly covers, else the smallest one it touches.
public struct PageElements: Equatable, Sendable {
    public struct Element: Equatable, Sendable {
        /// As a DOM mention's selector (`WebMentions`).
        public var selector: String
        public var text: String

        public init(selector: String, text: String) {
            self.selector = selector
            self.text = text
        }
    }

    public var url: String
    public var elements: [Element]
    /// Elements under it past `elements`.
    public var more: Int

    public init(url: String, elements: [Element], more: Int = 0) {
        self.url = url
        self.elements = elements
        self.more = more
    }
}

/// Turns staged mentions into the `<canvas-mentions>` prompt block (docs/contracts.md).
@MainActor
public enum MentionContext {
    public struct Resolved: Codable, Equatable, Sendable {
        public var id: MentionID
        public var ref: String
        public var label: String
        public var summary: String
    }

    static let maxExcerptLines = 12
    static let contextLines = 3
    /// A whole note mention carries the note up to this many lines and characters.
    static let maxNoteLines = 80
    static let maxNoteCharacters = 4000
    /// Terminal text in a mention: at most `terminalHead + terminalTail` lines of anything
    /// longer, its failures before its middle (`TerminalExcerpt.trim`).
    static let terminalHead = 10
    static let terminalTail = 30

    public static func label(for target: MentionTarget, on board: Board) -> String {
        switch target {
        case .code(_, let path, let lines, let side, let symbol, _, _):
            let range = lines.start == lines.end ? "\(lines.start)" : "\(lines.start)-\(lines.end)"
            let file = PathLabel.short(path)
            let location = side == DiffSide.old.rawValue ? "\(file):\(range) (old)" : "\(file):\(range)"
            return symbol.map { "\(location) \($0)" } ?? location
        case .dom(let object, _, let selector, let text, let point):
            // What a person recognizes first; the CSS path last, where the chip truncates.
            var parts = text.map { ["\"\(clip($0, 24))\""] } ?? []
            if let tag = tag(ofSelector: selector) { parts.append(tag) }
            if let point { parts.append("pixel \(point.x),\(point.y)") }
            if let tile = board.objects[object] { parts.append(clip(title(of: tile, on: board), 24)) }
            parts.append(selector)
            return parts.joined(separator: " · ")
        case .terminal(_, let text, let part, let command):
            if part == .command {
                let status = command.flatMap(\.status).map { " · \($0)" } ?? ""
                return command?.command.map { "$ \(clip($0, 28))\(status)" } ?? "command output\(status)"
            }
            let shown = part == .rows ? text.split(separator: "\n").first { $0.hasPrefix(">") }.map { String($0.dropFirst(2)) } ?? text : text
            return "terminal \"\(clip(shown.trimmingCharacters(in: .whitespaces), 28))\""
        case .group(let objects, let name):
            return name ?? "\(objects.count) objects"
        case .image(_, let path, let x, let y):
            return "\(PathLabel.short(path)) at (\(x), \(y))"
        case .note(let object, let item):
            // Short enough that the chip shows it whole: the item's words matter most.
            let note = board.objects[object].map { clip(title(of: $0, on: board), 14) } ?? object
            let summary = item.summary
            return "note \(note) › \(summary.isEmpty ? item.kind.noun : clip(summary, 24))"
        case .object(let id):
            guard let object = board.objects[id] else { return id }
            let name = object.type == .code ? PathLabel.short(title(of: object, on: board)) : title(of: object, on: board)
            return name == object.type.rawValue ? name : "\(object.type.rawValue) \(clip(name, 28))"
        case .console(_, _, let entry):
            return "\(entry.noun) \"\(clip(entry.text, 32))\"" + (entry.shortSource.map { " · \($0)" } ?? "")
        }
    }

    /// `caller`: the terminal this context goes to. A mention of it says `(your terminal)`, one of
    /// another terminal names it, so an agent never takes "this terminal" for its own by guess.
    public static func resolve(_ mention: Mention, index: Int, on board: Board, caller: ObjectID? = nil) async -> Resolved {
        let edited = mention.edited ? " (edited)" : ""
        var lines: [String] = []
        switch mention.target {
        case .code(let object, let path, let range, let side, let symbol, let commit, let diff):
            let symbolText = symbol.map { " (symbol \($0))" } ?? ""
            let diffText = diff.map { " · \($0)" } ?? ""
            lines.append("[\(index)] code \(path):\(range.start)-\(range.end)\(symbolText) · tile \(object)\(provenance(of: object, side: side, commit: commit, explicit: diff != nil, on: board))\(diffText)\(edited)")
            let text = await codeText(path, side: side, commit: commit, on: board)
            lines.append(contentsOf: text.text.map { excerpt($0, range) } ?? [text.failure])
        case .dom(let object, let url, let selector, let text, let point):
            let textPart = text.map { " \"\(clip($0, 80))\"" } ?? ""
            let pointPart = point.map { " · pixel (\($0.x), \($0.y)) of \($0.w)×\($0.h), from its top-left" } ?? ""
            lines.append("[\(index)] dom \(url) · \(selector)\(textPart)\(pointPart) · \(board.objects[object]?.type.rawValue ?? "browser") tile \(object)\(edited)")
        case .terminal(let object, let text, let part, let command):
            let name = terminalName(object, on: board, caller: caller)
            switch part {
            case .selection:
                lines.append("[\(index)] terminal tile \(object)\(name) · selected text\(edited)")
            case .rows:
                lines.append("[\(index)] terminal tile \(object)\(name) · screen rows around the click (> marks it)\(edited)")
            case .command:
                var parts = [command?.command.map { "command `\(clip($0, 120))`" } ?? "command output"]
                if let exit = command?.exit { parts.append("exit \(exit)") }
                if let duration = command?.durationMs { parts.append(TerminalCommand.duration(duration)) }
                // Which block it is now: the terminal's log counts from its newest command.
                let read = command.flatMap { board.terminalBlockIndex?(object, $0) }.map { " · read it: easl agent.read --target \(object) --block \($0)" } ?? ""
                lines.append("[\(index)] \(parts.joined(separator: " · ")) · output of terminal tile \(object)\(name)\(read)\(edited)")
            }
            lines.append(contentsOf: terminalLines(part == .rows ? text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) : TerminalExcerpt.lines(text)))
        case .group(let objects, let name):
            lines.append(contentsOf: await groupLines(objects, name: name, index: index, edited: edited, on: board, caller: caller))
        case .image(let object, let path, let x, let y):
            let file = LocalImage.tileFile(path, root: board.root)
            let size = await offPool { LocalImage.naturalSize(of: file) }
            let extent = size.map { " of \(Int($0.width))×\(Int($0.height))" } ?? " (file unreadable)"
            lines.append("[\(index)] image \(path) · pixel (\(x), \(y))\(extent), from its top-left · tile \(object)\(edited)")
        case .note(let object, let item):
            lines.append(contentsOf: noteItemLines(item, of: object, index: index, edited: edited, on: board))
        case .console(let object, let url, let entry):
            lines.append(contentsOf: consoleLines(entry, of: object, url: url, index: index, edited: edited, on: board))
        case .object(let id):
            if let object = board.objects[id] {
                lines.append("[\(index)] \(describe(object, on: board, caller: caller))\(edited)")
                if object.type == .note, let markdown = object.props["markdown"]?.string {
                    lines.append(contentsOf: noteLines(markdown, of: id))
                }
                if object.type == .question { lines.append(contentsOf: QuestionSpec.mentionLines(object.props)) }
                if object.type == .terminal, let screen = await board.terminalScreen?(id) {
                    let shown = TerminalExcerpt.lines(screen.text)
                    // What the user is looking at: the rows they scrolled back to, saying so.
                    let heading = screen.scrolledBack > 0 ? "the rows its view shows, scrolled back \(screen.scrolledBack) rows from its live screen:" : "its screen now:"
                    lines.append(shown.isEmpty ? "    (its screen is empty)" : "    \(heading)")
                    lines.append(contentsOf: terminalLines(shown))
                }
                lines.append(contentsOf: await pageLines(under: object, on: board, indent: "    "))
            } else {
                lines.append("[\(index)] object \(id) (deleted)")
            }
        }
        let rev = mention.target.objectIDs.first.flatMap { board.objects[$0]?.rev }.map { "@rev\($0)" } ?? ""
        return Resolved(id: mention.id, ref: "canvas:\(mention.id)\(rev)", label: mention.label, summary: lines.joined(separator: "\n"))
    }

    /// The block around the mentions. The closing hint names the calls that read more of what
    /// was mentioned: `agent.read` for terminals, `get`/`render` for everything else.
    /// `from`/`header`: mentions another agent attached to its `agent.prompt` (`Handoff`) name
    /// the sending terminal in the tag and say who attached them on the first line.
    public static func render(_ resolved: [Resolved], board: Board, targets: [MentionTarget] = [], from: ObjectID? = nil, header: String? = nil) -> String {
        guard !resolved.isEmpty else { return "" }
        var out = ["<canvas-mentions board=\"\(board.id)\" root=\"\(board.root.path)\"\(from.map { " from=\"\($0)\"" } ?? "")>"]
        if let header { out.append(header) }
        out.append(contentsOf: resolved.map(\.summary))
        let terminal = targets.map { target in
            switch target {
            case .terminal: true
            case .object(let id): board.objects[id]?.type == .terminal
            default: false
            }
        }
        if terminal.contains(false) || targets.isEmpty {
            out.append("Read more with the easl SDK or CLI: easl get <id> --as graph; look with easl render <id>")
        }
        if terminal.contains(true) {
            out.append("Read more of a terminal: easl agent.read --target <id> (--block -1: its last command's output, -2 the one before)")
        }
        out.append("</canvas-mentions>")
        return out.joined(separator: "\n")
    }

    /// Terminal text as mention lines: indented, the middle of a long text left out.
    static func terminalLines(_ lines: [String]) -> [String] {
        TerminalExcerpt.trim(lines, head: terminalHead, tail: terminalTail).map { "    \($0)" }
    }

    /// A group mention carries at most this many lines past its first. Every member's line comes
    /// before any member's text; the block says what it left out.
    static let maxGroupLines = 120
    /// Lines of each code or note member's text in a group mention, and how long one may run.
    static let groupExcerptLines = 6
    static let groupLineCharacters = 200
    static let maxGroupArrows = 40

    /// A group: each member (a nested group's members under it) as a mention of it alone leads,
    /// cut short (code: the lines it shows; a note: its first lines; a page: its URL), then the
    /// arrows among the members, which carry the diagram's meaning.
    static func groupLines(_ objects: [ObjectID], name: String?, index: Int, edited: String, on board: Board, caller: ObjectID?) async -> [String] {
        let group = board.objects.values.first { $0.type == .group && GroupMention.target($0.id, on: board)?.objectIDs == objects }
        var lines = ["[\(index)] group \(name.map { "\"\($0)\" " } ?? "")of \(objects.count) objects\(group.map { " · group \($0.id)" } ?? "")\(edited)"]
        var entries: [(object: CanvasObject, depth: Int)] = []
        var seen: Set<ObjectID> = []
        func walk(_ ids: [ObjectID], depth: Int) {
            for id in ids where seen.insert(id).inserted {
                guard let object = board.objects[id] else { continue }
                entries.append((object, depth))
                if object.type == .group, let spec = GroupSpec(object.props) { walk(spec.members, depth: depth + 1) }
            }
        }
        walk(objects, depth: 0)
        let order = Dictionary(entries.enumerated().map { ($0.element.object.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        // Arrow members, and every arrow with both ends on members.
        let arrows = board.objects.values.compactMap { arrow -> (arrow: CanvasObject, spec: ArrowSpec)? in
            guard arrow.type == .arrow, let spec = ArrowSpec(arrow.props) else { return nil }
            let between = spec.from.objectID.flatMap { order[$0] } != nil && spec.to.objectID.flatMap { order[$0] } != nil
            return order[arrow.id] != nil || between ? (arrow, spec) : nil
        }.sorted { a, b in
            func key(_ arrow: (arrow: CanvasObject, spec: ArrowSpec)) -> (Int, Int, ObjectID) {
                (arrow.spec.from.objectID.flatMap { order[$0] } ?? .max, arrow.spec.to.objectID.flatMap { order[$0] } ?? .max, arrow.arrow.id)
            }
            return key(a) < key(b)
        }
        let arrowIDs = Set(arrows.map(\.arrow.id))
        var arrowLines = arrows.prefix(maxGroupArrows).map { "      \(arrowLine($0.arrow, $0.spec, on: board))" }
        if arrows.count > maxGroupArrows { arrowLines.append("      … \(arrows.count - maxGroupArrows) more arrows") }
        let budget = max(maxGroupLines - arrowLines.count - 1, maxGroupLines / 2)
        let listed = entries.filter { !arrowIDs.contains($0.object.id) }
        let shown = listed.prefix(budget)
        var room = budget - shown.count
        var cutTexts = 0
        for (object, depth) in shown {
            let indent = "    " + String(repeating: "  ", count: depth)
            let detail = await memberDetail(object, indent: indent, on: board)
            lines.append("\(indent)- \(describe(object, on: board, caller: caller, omittingArrows: arrowIDs))\(detail.suffix)")
            if detail.lines.count <= room {
                lines.append(contentsOf: detail.lines.map { clip($0, groupLineCharacters) })
                room -= detail.lines.count
            } else {
                cutTexts += 1
            }
        }
        let cutMembers = listed.count - shown.count
        if !arrowLines.isEmpty {
            lines.append("    arrows among them:")
            lines.append(contentsOf: arrowLines)
        }
        var cut: [String] = []
        if cutTexts > 0 { cut.append("the text of \(cutTexts) member\(cutTexts == 1 ? "" : "s")") }
        if cutMembers > 0 { cut.append("\(cutMembers) more member\(cutMembers == 1 ? "" : "s")") }
        if !cut.isEmpty {
            let more = group.map { "easl get \($0.id) --as graph" } ?? "easl get <id>"
            lines.append("    (left out to keep this short: \(cut.joined(separator: " and ")); read them with \(more))")
        }
        return lines
    }

    /// What a group mention adds to a member's line (`suffix`) and under it: a code tile's lines
    /// (as a code mention of them reads), a note's first lines past its title, a page's URL, the
    /// page under a drawn shape, a nested group's size.
    static func memberDetail(_ object: CanvasObject, indent: String, on board: Board) async -> (suffix: String, lines: [String]) {
        switch object.type {
        case .code:
            if case .code(_, let path, let range, let side, _, let commit, _)? = try? HandoffMention(object: object.id).target(on: board) {
                let text = await codeText(path, side: side, commit: commit, on: board)
                let suffix = " · lines \(range.start)-\(range.end)\(provenance(of: object.id, side: side, commit: commit, on: board))"
                return (suffix, text.text.map { excerpt($0, range, limit: groupExcerptLines, indent: indent) } ?? [indent + text.failure])
            }
            // The whole file: its first lines.
            guard let path = object.props["path"]?.string, !path.isEmpty else { return ("", []) }
            let commit = object.props["pinnedCommit"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            let text = await codeText(path, side: nil, commit: commit, on: board)
            guard let file = text.text else { return ("", [indent + text.failure]) }
            return ("", excerpt(file, LineRange(start: 1, end: max(1, file.lineCount)), limit: groupExcerptLines, indent: indent))
        case .note:
            guard let markdown = object.props["markdown"]?.string else { return ("", []) }
            // Its first line is the title the member's line already shows; blank lines only
            // spread the few lines it gets.
            let source = NoteSource.lines(of: markdown)
            let titled = source.first.map { NoteMarkdown.plainText(ofLine: $0) == title(of: object, on: board) } == true
            let body = source.dropFirst(titled ? 1 : 0).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return ("", noteLines(body.joined(separator: "\n"), of: object.id, limit: groupExcerptLines, characters: groupExcerptLines * groupLineCharacters, indent: indent + "  "))
        case .browser:
            guard let url = object.props["url"]?.string, !url.isEmpty, url != title(of: object, on: board) else { return ("", []) }
            return (" · \(url)", [])
        case .shape:
            return ("", await pageLines(under: object, on: board, indent: indent + "  "))
        case .group:
            return (" of \(GroupSpec(object.props)?.members.count ?? 0) objects", [])
        default:
            return ("", [])
        }
    }

    /// An arrow among a group's members: `from "title" → to "title" · "label" (relation) · arrow id`.
    static func arrowLine(_ arrow: CanvasObject, _ spec: ArrowSpec, on board: Board) -> String {
        func end(_ binding: ArrowBinding) -> String {
            let name = binding.objectID.flatMap { board.objects[$0] }.map { title(of: $0, on: board) } ?? ""
            return endName(binding) + (name.isEmpty ? "" : " \"\(clip(name, 40))\"")
        }
        let label = spec.label.flatMap { $0.isEmpty ? nil : " · \"\(clip($0, 60))\"" } ?? ""
        let relation = spec.relation.map { " (\($0))" } ?? ""
        return "\(end(spec.from)) → \(end(spec.to))\(label)\(relation) · arrow \(arrow.id)"
    }

    /// What a Hyper-click on a drawn object mentions: the whole selection when the object is
    /// part of a selection of several; else every drawing of its group when the group holds only
    /// drawings (a sketch made of strokes, a box and its note); else the object alone.
    public static func drawingTarget(_ id: ObjectID, selection: Set<ObjectID>, on board: Board) -> MentionTarget {
        if selection.contains(id), selection.count > 1 { return .group(objects: selection.sorted(), name: nil) }
        let drawings = board.objects.values
            .filter { $0.type == .group }
            .compactMap { group in GroupSpec(group.props).map { (group: group, spec: $0) } }
            .filter { $0.spec.members.contains(id) && $0.spec.members.count > 1 }
            .filter { $0.spec.members.allSatisfy { [.shape, .arrow].contains(board.objects[$0]?.type) } }
            .min { $0.group.frame.w * $0.group.frame.h < $1.group.frame.w * $1.group.frame.h }
        if let drawings { return .group(objects: drawings.spec.members, name: drawings.spec.title.flatMap { $0.isEmpty ? nil : $0 }) }
        return .object(id)
    }

    /// What a drawn shape lies on: the topmost object under it that contains it, else the
    /// topmost one holding more than half of it (`partly`), with the part over it (canvas
    /// coordinates).
    static func host(of object: CanvasObject, on board: Board) -> (host: CanvasObject, region: CGRect, partly: Bool)? {
        guard object.type == .shape else { return nil }
        let region = object.frame.rect
        let under = board.objects.values.filter { $0.type != .arrow && $0.type != .group && $0.id != object.id && $0.z < object.z }
        if let host = under.filter({ $0.frame.rect.contains(region) }).max(by: { $0.z < $1.z }) { return (host, region, false) }
        let area = region.width * region.height
        guard area > 0 else { return nil }
        let partial = under.filter { candidate in
            let part = candidate.frame.rect.intersection(region)
            return !part.isNull && part.width * part.height > area / 2
        }.max { $0.z < $1.z }
        return partial.map { ($0, $0.frame.rect.intersection(region), true) }
    }

    /// The page elements under a shape drawn on a browser or HTML tile, from the page as it is
    /// now (`Board.pageElements`): nothing when the page can't answer quickly.
    static func pageLines(under object: CanvasObject, on board: Board, indent: String) async -> [String] {
        guard let (host, region, _) = host(of: object, on: board), host.type == .browser || host.type == .html,
              let query = board.pageElements, let page = await query(host.id, region), !page.elements.isEmpty else { return [] }
        var lines = ["\(indent)page elements under it (\(page.url)):"]
        for element in page.elements {
            lines.append("\(indent)  \(element.selector)\(element.text.isEmpty ? "" : " \"\(clip(element.text, 80))\"")")
        }
        if page.more > 0 { lines.append("\(indent)  … \(page.more) more") }
        return lines
    }

    /// One-line description with spatial relations: what a shape encloses, what it's drawn on, and its arrows.
    /// `omittingArrows`: arrows said elsewhere (a group mention's arrows among its members).
    static func describe(_ object: CanvasObject, on board: Board, caller: ObjectID? = nil, omittingArrows: Set<ObjectID> = []) -> String {
        let author = object.createdBy == .user ? "drawn by user" : "by agent"
        var parts = ["\(object.type.rawValue) \(object.id)"]
        let title = title(of: object, on: board)
        // A shape's text is the user's note to the agent: all of it.
        if !title.isEmpty { parts.append("\"\(object.type == .shape ? title.replacingOccurrences(of: "\n", with: "\\n") : clip(title, 60))\"") }
        if object.type == .terminal, object.id == caller { parts.append("(your terminal)") }
        if object.type == .shape { parts.append("(\(author))") }
        if object.type == .shape {
            let enclosed = board.enclosed(by: object).map(\.id)
            if !enclosed.isEmpty { parts.append("· encloses \(enclosed.joined(separator: ", "))") }
            for (_, spec) in board.arrows(enclosedBy: object) {
                let relation = spec.relation.map { " (\($0))" } ?? ""
                parts.append("· inner arrow \(endName(spec.from)) → \(endName(spec.to))\(relation)")
            }
            // A shape drawn on top of something (a tile region, a bigger box) points at part of
            // it: name the topmost object underneath that contains it (or most of it), and where,
            // in its local units (a tile's content points, starting below its title bar, at its
            // zoom).
            if let (host, region, partly) = host(of: object, on: board) {
                let zoom = host.zoom
                let title = RenderMath.isTile(host.type) ? RenderMath.tileTitleHeight : 0
                let local = CGRect(x: (region.minX - host.frame.x) / zoom, y: (region.minY - host.frame.y - title) / zoom,
                                   width: region.width / zoom, height: region.height / zoom)
                parts.append(String(format: "· %@over %@ %@ at (%.0f, %.0f) %.0f×%.0f", partly ? "partly " : "", host.type.rawValue, host.id,
                                    Double(local.minX), Double(local.minY), Double(local.width), Double(local.height)))
            }
        }
        for arrow in board.objects.values where arrow.type == .arrow && !omittingArrows.contains(arrow.id) {
            let relation = arrow.props["relation"]?.string.map { " (\($0))" } ?? ""
            if arrow.props["from"]?["object"]?.string == object.id, let to = arrow.props["to"]?["object"]?.string {
                parts.append("· arrow → \(to)\(relation)")
            } else if arrow.props["to"]?["object"]?.string == object.id, let from = arrow.props["from"]?["object"]?.string {
                parts.append("· arrow ← \(from)\(relation)")
            }
        }
        if object.type == .arrow, let spec = ArrowSpec(object.props) {
            let relation = spec.relation.map { " (\($0))" } ?? ""
            parts.append("· \(endName(spec.from)) → \(endName(spec.to))\(relation)")
        }
        return parts.joined(separator: " ")
    }

    static func endName(_ binding: ArrowBinding) -> String {
        switch binding {
        case .object(let id, let lines, let selector, let node):
            let detail = lines.map { ":\($0.start)-\($0.end)" } ?? node.map { " node \($0)" } ?? selector.map { " \($0)" } ?? ""
            return id + detail
        case .point(let point):
            // Coordinates are any JSON number; an Int conversion would trap on huge ones.
            return String(format: "(%.0f, %.0f)", Double(point.x), Double(point.y))
        }
    }

    /// ` (your terminal)` for the caller's own terminal, else the terminal's name in quotes.
    static func terminalName(_ id: ObjectID, on board: Board, caller: ObjectID?) -> String {
        if id == caller { return " (your terminal)" }
        guard let terminal = board.objects[id] else { return "" }
        return " \"\(clip(title(of: terminal, on: board), 60))\""
    }

    static func title(of object: CanvasObject, on board: Board) -> String {
        let props = object.props
        func nonEmpty(_ key: String) -> String? { props[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        switch object.type {
        // The user's own name for it first: what "the fees terminal" means; else what its header
        // shows (the program running in it, the title it set).
        case .terminal:
            return nonEmpty("name") ?? board.terminalLabel?(object.id).flatMap { $0.isEmpty ? nil : $0 } ?? nonEmpty("title")
                ?? props["agent"]?["kind"]?.string ?? "terminal"
        case .browser: return nonEmpty("title") ?? nonEmpty("pageTitle") ?? props["url"]?.string ?? ""
        case .code: return props["path"]?.string ?? ""
        case .note:
            // Without a title, its first line, as it reads (a heading without its `#`s or escapes).
            return nonEmpty("title") ?? props["markdown"]?.string?.split(separator: "\n").first.map(NoteMarkdown.plainText(ofLine:)) ?? ""
        case .html: return props["title"]?.string ?? "html"
        case .changes: return props["title"]?.string ?? ChangesSpec(props).name
        case .image: return props["title"]?.string ?? props["path"]?.string ?? "image"
        case .diagram: return DiagramSpec.title(props)
        case .question: return props["question"]?.string ?? "question"
        case .shape: return props["text"]?.string ?? props["kind"]?.string ?? ""
        case .arrow: return props["label"]?.string ?? props["relation"]?.string ?? ""
        case .group: return props["title"]?.string ?? ""
        }
    }

    /// Where the lines come from, from the mention alone: ` · diff vs merge-base 1a2b3c4` (plus
    /// `, old side` for deleted rows), ` · at 1a2b3c4` for a pinned excerpt, nothing for the
    /// working tree. The tile's `diffBase` only names the kind of base. `explicit` (a changes
    /// tile's line) names either side: `, new side (working tree)` or `, old side (base)`.
    static func provenance(of object: ObjectID, side: String?, commit: String?, explicit: Bool = false, on board: Board) -> String {
        guard let commit else { return side == DiffSide.old.rawValue ? " · old side of diff" : "" }
        let sha = commit.prefix(7)
        guard side != nil else { return " · at \(sha)" }
        let kind = board.objects[object].map { tile -> String in
            switch tile.type {
            case .code: DiffBase(prop: tile.props["diffBase"]?.string).name + " "
            case .changes: ChangesSpec(tile.props).base.name + " "
            default: ""
            }
        } ?? ""
        let which = side == DiffSide.old.rawValue ? (explicit ? ", old side (base)" : ", old side") : (explicit ? ", new side (working tree)" : "")
        return " · diff vs \(kind)\(sha)\(which)"
    }

    /// The mentioned lines marked `>`, plus up to `contextLines` unmarked lines on each side while
    /// the whole excerpt fits in `limit` lines, so a one-line mention still reads in context.
    static func excerpt(_ text: SideText, _ range: LineRange, limit: Int = maxExcerptLines, indent: String = "") -> [String] {
        let start = max(1, range.start)
        let end = min(text.lineCount, range.end)
        guard start <= end else { return ["\(indent)    (range \(range.start)-\(range.end) is outside the file)"] }
        let pad = min(contextLines, max(0, limit - (end - start + 1)) / 2)
        let from = max(1, start - pad)
        let to = min(text.lineCount, end + pad, from + limit - 1)
        var lines = (from...to).map { number in
            let marker = (start...end).contains(number) ? "  > " : "    "
            return indent + marker + String(number).padding(toLength: 5, withPad: " ", startingAt: 0) + text.line(number)
        }
        if range.end > to { lines.append("\(indent)    …") }
        return lines
    }

    /// The file a code mention reads: at `commit` when the mention names one (so the excerpt
    /// never depends on what the tile shows now), else the working tree; else why it can't.
    static func codeText(_ path: String, side: String?, commit: String?, on board: Board) async -> (text: SideText?, failure: String) {
        let url = board.absoluteURL(path)
        if let commit, side != DiffSide.new.rawValue {
            return (await GitDiffEngine.shared.text(of: url, at: commit), "    (\(path) is not readable at \(commit.prefix(7)))")
        }
        return ((try? String(contentsOf: url, encoding: .utf8)).map(SideText.init), "    (file unreadable: \(url.path))")
    }

    /// A whole note: its markdown up to `limit` lines and `characters` characters.
    static func noteLines(_ markdown: String, of id: ObjectID, limit: Int = maxNoteLines, characters: Int = maxNoteCharacters, indent: String = "    ") -> [String] {
        var lines: [String] = []
        var count = 0
        let source = NoteSource.lines(of: markdown)
        for line in source.prefix(limit) {
            guard count + line.count <= characters else { break }
            lines.append("\(indent)\(line)")
            count += line.count + 1
        }
        if source.count > lines.count { lines.append("\(indent)… \(source.count - lines.count) more lines (easl get \(id))") }
        return lines
    }

    /// A block of a note, as the note reads now: re-found by its text (it may have moved, or
    /// grown), else as it read when mentioned, saying so.
    static func noteItemLines(_ item: NoteItem, of id: ObjectID, index: Int, edited: String, on board: Board) -> [String] {
        guard let note = board.objects[id] else { return ["[\(index)] note \(id) (deleted)"] }
        let found = NoteItem.find(item.text, near: item.lines.start, in: note.props["markdown"]?.string ?? "")
        let current = found?.item ?? item
        let range = current.lines.start == current.lines.end ? "line \(current.lines.start)" : "lines \(current.lines.start)-\(current.lines.end)"
        let path = current.headings.isEmpty ? "" : " · in \(current.headings.joined(separator: " › "))"
        var lines = ["[\(index)] note \(id) \"\(clip(title(of: note, on: board), 60))\" · \(current.kind.noun), markdown \(range)\(path)\(edited)"]
        switch found {
        case nil: lines.append("    (no longer in the note; as it read when mentioned:)")
        case let found? where !found.unchanged: lines.append("    (changed since it was mentioned; as it reads now:)")
        default: break
        }
        lines.append(contentsOf: NoteSource.lines(of: current.text).map { "    \($0)" })
        if current.omittedLines > 0 { lines.append("    … \(current.omittedLines) more lines (easl get \(id))") }
        return lines
    }

    /// Stack frames a console mention carries.
    static let maxStackLines = 8

    /// A page's console message, error or failed request: what it said, where, and when.
    static func consoleLines(_ entry: PageLogEntry, of id: ObjectID, url: String, index: Int, edited: String, on board: Board) -> [String] {
        let tile = board.objects[id].map { " \"\(clip(title(of: $0, on: board), 60))\"" } ?? ""
        let when = entry.clockTime.map { " · at \($0)" } ?? ""
        var lines = ["[\(index)] page \(entry.noun) · browser tile \(id)\(tile) · page \(url)\(when)\(edited)"]
        lines.append(contentsOf: entry.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxExcerptLines).map { "    \($0)" })
        if let source = entry.source { lines.append("    source: \(source)") }
        let frames = entry.frames
        if !frames.isEmpty { lines.append("    stack:") }
        lines.append(contentsOf: frames.prefix(maxStackLines).map { "      \($0)" })
        if frames.count > maxStackLines { lines.append("      … \(frames.count - maxStackLines) more frames") }
        return lines
    }

    /// `text` on one line, cut to `limit` characters with an ellipsis.
    nonisolated static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// The element's tag from a mention selector (`WebMentions`): the last step of a path
    /// (`… > p:nth-of-type(2)` → `p`) or an attribute selector's element (`a[aria-label="…"]`);
    /// nil for an id selector. Attribute selectors are never part of a path, and their values
    /// may contain ` > `.
    static func tag(ofSelector selector: String) -> String? {
        let last = selector.contains("[") ? selector : selector.components(separatedBy: " > ").last ?? selector
        return last.prefixMatch(of: /[A-Za-z][A-Za-z0-9-]*/).map { String($0.output).lowercased() }
    }
}

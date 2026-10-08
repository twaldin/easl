import Foundation

/// A `path:line` reference in terminal output (an agent's answer, a compiler error, a stack
/// trace): `src/foo.ts:42`, `src/foo.ts:42:7`, `src/foo.ts:42-50` (also with an en or em dash,
/// as Gemini writes ranges), `foo.rs#L10-20`, `/abs/path.swift:3`, `file:///abs/path.ts:3:5`,
/// `~/x.py:9`; a Python traceback frame (`File "src/app.py", line 12, in main`) or a pdb frame
/// (`/src/app.py(12)main()`, as `where` lists them and a stop shows `> …`); a pytest node id
/// (`tests/test_x.py::TestA::test_b[1]`), whose line is its `def`'s, found when it opens; or a
/// source file's name alone (`Applied edit to url.go`), which has no line.
/// ⌘-click opens it as a code tile beside the terminal.
public struct TerminalReference: Equatable, Sendable {
    /// UTF-16 range of the whole reference in the searched text.
    public var range: NSRange
    public var path: String
    /// Nil for a file named without a line: it opens at its top.
    public var lines: LineRange?
    /// A pytest node id's names after the file (`["TestA", "test_b"]`); `lines` is then 1-1.
    public var test: [String]?

    public init(range: NSRange, path: String, lines: LineRange?, test: [String]? = nil) {
        self.range = range
        self.path = path
        self.lines = lines
        self.test = test
    }
}

public enum TerminalReferences {
    /// The path: optional `~`/`.`/`..` root, directories, a name. It needs a slash or a file
    /// extension (checked after matching), so `localhost:3000` and `12:30` never match; the
    /// lookbehind keeps `https://example.com:443` out. A `file://` URL's path counts, with its
    /// scheme part of the reference.
    private static let pathPattern = #"(?<![\w./@:~-])(?:file://)?((?:~|\.{1,2})?/?(?:[\w@.+-]+/)*[\w@+-][\w@.+-]*)"#
    /// A path, then `:line`, `:line:col`, `:start-end`, or `#Lstart`, `#Lstart-end`,
    /// `#Lstart-Lend`; a range's dash may be `-`, `–` or `—`.
    private static let pattern = try! NSRegularExpression(pattern:
        pathPattern + #"(?::(\d+)(?:[-–—](\d+)|:\d+)?|#L(\d+)(?:[-–—]L?(\d+))?)(?![\w/])"#)
    /// A path with no line after it, kept when its extension is a source file's (`sourceExtensions`).
    private static let barePattern = try! NSRegularExpression(pattern: pathPattern + #"(?![\w/#(@.-]|:\d)"#)
    /// Extensions of files worth opening by name alone: source code, and the config and docs
    /// beside it. Anything else named bare (`example.com`, `v1.2`) stays text.
    static let sourceExtensions: Set<String> = [
        "swift", "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "py", "pyi", "go", "rs", "c", "h", "cc", "cpp", "cxx", "hpp", "hh",
        "m", "mm", "java", "kt", "kts", "scala", "rb", "php", "cs", "fs", "lua", "zig", "ex", "exs", "erl", "hs", "ml", "clj", "dart",
        "sh", "bash", "zsh", "fish", "vue", "svelte", "css", "scss", "html", "sql", "proto", "graphql", "json", "toml", "yaml", "yml",
        "md", "gradle", "cmake", "nix", "tf",
    ]
    /// A Python traceback frame: `File "<path>", line <n>`; the quoted path may hold spaces.
    private static let tracebackPattern = try! NSRegularExpression(pattern: #"File "([^"\n]+)", line (\d+)"#)
    /// A pdb frame: a path, the line in parentheses, then the function called (`main()`,
    /// `<module>()`).
    private static let pdbPattern = try! NSRegularExpression(pattern: pathPattern + #"\((\d+)\)(?:[\w<>]+\(\))?"#)
    /// A pytest node id: a `.py` path, `::` and names, maybe a parameter set in brackets.
    private static let nodePattern = try! NSRegularExpression(pattern:
        #"(?<![\w./@:~-])((?:~|\.{1,2})?/?(?:[\w@.+-]+/)*[\w@+-][\w@.+-]*\.py)((?:::[A-Za-z_]\w*)+)(?:\[[^\]\s]*\])?"#)

    public static func find(in text: String) -> [TerminalReference] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func number(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
        }
        let located: [TerminalReference] = pattern.matches(in: text, range: whole).compactMap { match in
            let path = ns.substring(with: match.range(at: 1))
            guard path.contains("/") || hasExtension(path) else { return nil }
            guard let start = number(match, 2) ?? number(match, 4), start >= 1 else { return nil }
            let end = max(start, number(match, 3) ?? number(match, 5) ?? start)
            return TerminalReference(range: match.range, path: path, lines: LineRange(start: start, end: end))
        }
        // The quotes make a traceback's path unambiguous: whether it names a file is `resolve`'s call.
        let frames: [TerminalReference] = tracebackPattern.matches(in: text, range: whole).compactMap { match in
            guard let line = number(match, 2), line >= 1 else { return nil }
            return TerminalReference(range: match.range, path: ns.substring(with: match.range(at: 1)), lines: LineRange(start: line, end: line))
        }
        let stops: [TerminalReference] = pdbPattern.matches(in: text, range: whole).compactMap { match in
            let path = ns.substring(with: match.range(at: 1))
            guard path.contains("/") || hasExtension(path), let line = number(match, 2), line >= 1 else { return nil }
            return TerminalReference(range: match.range, path: path, lines: LineRange(start: line, end: line))
        }
        let nodes = nodePattern.matches(in: text, range: whole).map { match in
            TerminalReference(range: match.range, path: ns.substring(with: match.range(at: 1)), lines: LineRange(start: 1, end: 1),
                              test: ns.substring(with: match.range(at: 2)).components(separatedBy: "::").filter { !$0.isEmpty })
        }
        let withLines = located + frames + stops + nodes
        // A source file named alone (a sentence's full stop after it isn't part of it), where no
        // reference above covers it.
        let bare: [TerminalReference] = barePattern.matches(in: text, range: whole).compactMap { match in
            var path = ns.substring(with: match.range(at: 1))
            var range = match.range
            while path.hasSuffix(".") {
                path.removeLast()
                range.length -= 1
            }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            guard hasExtension(name), sourceExtensions.contains((name as NSString).pathExtension.lowercased()),
                  !withLines.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return nil }
            return TerminalReference(range: range, path: path, lines: nil)
        }
        return (withLines + bare).sorted { $0.range.location < $1.range.location }
    }

    /// The reference covering UTF-16 offset `offset` of `text`.
    public static func reference(in text: String, at offset: Int) -> TerminalReference? {
        find(in: text).first { NSLocationInRange(offset, $0.range) }
    }

    /// `name.ext` with an extension starting with a letter (`v1.2` is a version, not a file).
    private static func hasExtension(_ path: String) -> Bool {
        let name = path.split(separator: "/").last ?? ""
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return ext.first?.isLetter == true && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// The existing file `path` names: `~/` paths as they are, relative ones against
    /// `directories` in order (the terminal's reported cwd, its `props.cwd`, the board root).
    /// Diff prefixes (`a/`, `b/`) are tried without the prefix too. When no directory has it, a
    /// relative path is looked up among the board root's `listed` files as a file name or a
    /// trailing part of a path (`core.py`, `click/core.py:10`, as agents write before they know
    /// better). An absolute path is itself when it exists; else (a deploy path in a production
    /// stack trace, `/srv/app/server/routes/claims.ts`) its longest trailing part that names
    /// listed files, at least a directory and the name (`server/routes/claims.ts`). One match is
    /// it; of several, the one nearest `cwd` (fewest directories up and down), unless two are
    /// equally near. Nil when nothing resolves.
    public static func resolve(_ path: String, directories: [String], home: String, isFile: (String) -> Bool,
                               listed: (root: String, files: FileIndex)? = nil, near cwd: String? = nil) -> String? {
        func standard(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        func matches(ending suffix: String, in listed: (root: String, files: FileIndex)) -> [String] {
            var found: [String] = []
            for match in listed.files.paths(endingWith: suffix) {
                let candidate = standard((listed.root as NSString).appendingPathComponent(match))
                if !found.contains(candidate), isFile(candidate) { found.append(candidate) }
            }
            return found
        }
        if path.hasPrefix("~/") {
            let candidate = standard(home + path.dropFirst())
            return isFile(candidate) ? candidate : nil
        }
        if path.hasPrefix("/") {
            let candidate = standard(path)
            if isFile(candidate) { return candidate }
            guard let listed else { return nil }
            let parts = candidate.split(separator: "/")
            for count in stride(from: parts.count - 1, through: 2, by: -1) {
                let found = matches(ending: parts.suffix(count).joined(separator: "/"), in: listed)
                if !found.isEmpty { return nearest(found, to: cwd) }
            }
            return nil
        }
        var relatives = [path]
        if path.hasPrefix("a/") || path.hasPrefix("b/") { relatives.append(String(path.dropFirst(2))) }
        for relative in relatives {
            for directory in directories where !directory.isEmpty {
                let candidate = standard((directory as NSString).appendingPathComponent(relative))
                if isFile(candidate) { return candidate }
            }
        }
        guard let listed else { return nil }
        var found: [String] = []
        // A diff's `a/` or `b/` prefix is dropped only when the path as written matches nothing.
        for relative in relatives where found.isEmpty {
            var suffix = Substring(relative)
            while suffix.hasPrefix("./") { suffix = suffix.dropFirst(2) }
            guard !suffix.split(separator: "/").contains("..") else { continue }
            found = matches(ending: String(suffix), in: listed)
        }
        return nearest(found, to: cwd)
    }

    /// The one of `files`, else the one nearest `cwd` (fewest directories up and down) unless
    /// two are equally near; nil for none.
    private static func nearest(_ files: [String], to cwd: String?) -> String? {
        guard files.count > 1 else { return files.first }
        guard let cwd else { return nil }
        // /tmp and /private/tmp are one directory; a shell may report either.
        func real(_ path: String) -> [Substring] { URL(fileURLWithPath: path).resolvingSymlinksInPath().path.split(separator: "/") }
        let here = real(cwd)
        func distance(_ file: String) -> Int {
            let folder = real(file).dropLast()
            let shared = zip(here, folder).prefix { $0 == $1 }.count
            return (here.count - shared) + (folder.count - shared)
        }
        let ranked = files.map { ($0, distance($0)) }.sorted { $0.1 < $1.1 }
        return ranked[0].1 < ranked[1].1 ? ranked[0].0 : nil
    }

    /// True for an existing regular file (or a symlink to one).
    public static func isFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }
}

extension TerminalReferences {
    /// A reference drawn in a terminal's viewport, resolved to a file.
    public struct Hit: Equatable, Sendable {
        public var file: String
        /// Nil for a file named without a line.
        public var lines: LineRange?
        /// Where it is drawn: one run per viewport row it covers.
        public var runs: [TerminalTextRows.Run]
        /// A pytest node id's names (`TerminalReference.test`): the line is its `def`'s.
        public var test: [String]?

        public init(file: String, lines: LineRange?, runs: [TerminalTextRows.Run], test: [String]? = nil) {
            self.file = file
            self.lines = lines
            self.runs = runs
            self.test = test
        }
    }

    /// How many rows above and below the clicked one a reference is followed onto.
    static let joinedRows = 2

    /// The reference drawn in cell (`row`, `column`) of a viewport `columns` wide (`read` gives a
    /// row's text, nil past the screen) that `resolve` finds a file for. A reference may go on
    /// from one row to the next in two ways:
    /// - wrapped: the row fills the terminal to its last column (the terminal soft-wrapped it, or
    ///   a program's newline fell exactly there; the two read the same), so the next row
    ///   continues it directly;
    /// - broken by a TUI that wraps its own text with hard newlines inside its margins
    ///   (opencode's `src/dir_entry.` then `rs:100-103`): the row's text ends, before trailing
    ///   blanks and box-drawing borders, in an unfinished reference (`src/dir_entry.`,
    ///   `walk.rs:661-`, a bare word), and the next row continues it from its first non-blank.
    /// Joins are guesses (the word before a reference on the row above joins too), so the
    /// longest run of joined rows is tried first, then shorter ones around the row, down to the
    /// row alone: the first reference under the cell that resolves wins.
    public static func hit(row: Int, column: Int, columns: Int, read: (Int) -> String?, resolve: (String) -> String?) -> Hit? {
        var cache: [Int: String?] = [:]
        func line(_ index: Int) -> String? {
            if let cached = cache[index] { return cached }
            let text = index < 0 ? nil : read(index)
            cache[index] = text
            return text
        }
        guard line(row) != nil else { return nil }
        // joins[r]: how row r goes on into row r + 1.
        var joins: [Int: TerminalTextRows.Join] = [:]
        for upper in stride(from: row - 1, through: row - joinedRows, by: -1) {
            guard let text = line(upper), let next = line(upper + 1), let join = TerminalTextRows.join(text, next, columns: columns) else { break }
            joins[upper] = join
        }
        for upper in row..<(row + joinedRows) {
            guard let text = line(upper), let next = line(upper + 1), let join = TerminalTextRows.join(text, next, columns: columns) else { break }
            joins[upper] = join
        }
        var first = row, last = row
        while joins[first - 1] != nil { first -= 1 }
        while joins[last] != nil { last += 1 }
        let spans = (first...row).flatMap { top in (row...last).map { (top, $0) } }
            .sorted { ($0.1 - $0.0, $0.0) > ($1.1 - $1.0, $1.0) }
        for (top, bottom) in spans {
            let rows = TerminalTextRows((top...bottom).map { index in
                TerminalTextRows.Segment(row: index, text: line(index) ?? "",
                                         leading: index > top ? joins[index - 1]!.leading : 0,
                                         trailing: index < bottom ? joins[index]!.trailing : 0)
            })
            guard let offset = rows.offset(row: row, column: column),
                  let reference = reference(in: rows.text, at: offset),
                  let file = resolve(reference.path) else { continue }
            return Hit(file: file, lines: reference.lines, runs: rows.runs(reference.range), test: reference.test)
        }
        return nil
    }
}

/// Consecutive viewport rows of a terminal's text as one string, with each UTF-16 unit's cell,
/// so a reference that goes on from one row to the next is found whole and underlined per row.
public struct TerminalTextRows {
    public struct Run: Equatable, Sendable {
        public var row: Int
        public var column: Int
        public var width: Int

        public init(row: Int, column: Int, width: Int) {
            self.row = row
            self.column = column
            self.width = width
        }
    }

    /// One row's part of the text: all of `text` but `leading` characters at its start and
    /// `trailing` at its end (a TUI's margin and border around a broken reference).
    struct Segment {
        var row: Int
        var text: String
        var leading = 0
        var trailing = 0
    }

    /// How a row goes on into the next (`TerminalReferences.hit`): directly when it fills the
    /// terminal's width, else past the `trailing` blanks and border of the upper row and the
    /// `leading` ones of the lower (a TUI's margins).
    struct Join {
        var trailing = 0
        var leading = 0
    }

    public private(set) var text = ""
    /// Per UTF-16 unit of `text`: its viewport row and first cell column.
    private var cells: [(row: Int, column: Int, width: Int)] = []

    init(_ segments: [Segment]) {
        for segment in segments {
            var column = 0
            let characters = Array(segment.text)
            for (index, character) in characters.enumerated() {
                let width = TerminalStyledTail.cellWidth(character)
                defer { column += width }
                guard index >= segment.leading, index < characters.count - segment.trailing else { continue }
                for _ in character.utf16 { cells.append((segment.row, column, width)) }
                text.append(character)
            }
        }
    }

    /// The UTF-16 offset of the character drawn in cell (`row`, `column`).
    public func offset(row: Int, column: Int) -> Int? {
        cells.firstIndex { $0.row == row && column >= $0.column && column < $0.column + max($0.width, 1) }
    }

    /// The cells `range` covers, one run per row.
    public func runs(_ range: NSRange) -> [Run] {
        var runs: [Run] = []
        for index in range.location..<min(NSMaxRange(range), cells.count) {
            let cell = cells[index]
            if let last = runs.last, last.row == cell.row {
                runs[runs.count - 1].width = max(last.width, cell.column + max(cell.width, 1) - last.column)
            } else {
                runs.append(Run(row: cell.row, column: cell.column, width: max(cell.width, 1)))
            }
        }
        return runs
    }

    /// How `upper` goes on into `lower` in a terminal `columns` wide; nil when it doesn't. A row
    /// whose text reaches the last column goes on directly, unless it is a separator a program
    /// padded to the width (`TerminalTail.isRule`); one that ends in blanks or a border
    /// (a TUI's margin and scrollbar, even when they fill the row) only after an unfinished word,
    /// or inside a table cell: a reference that looks whole (`checkouts.ts:1383-13` before the
    /// cell's `│`) goes on when the row below holds nothing in its cells but digits (`92`).
    static func join(_ upper: String, _ lower: String, columns: Int) -> Join? {
        guard !TerminalTail.isRule(upper) else { return nil }
        let above = Array(upper), below = Array(lower)
        var end = above.count
        while end > 0, TerminalTail.isEdge(above[end - 1]) { end -= 1 }
        if end == above.count, TerminalStyledTail.width(upper) >= columns { return Join() }
        var start = end
        while start > 0, isPathCharacter(above[start - 1]) { start -= 1 }
        guard start < end else { return nil }
        var lead = 0
        while lead < below.count, TerminalTail.isEdge(below[lead]) { lead += 1 }
        guard lead < below.count, isPathCharacter(below[lead]) else { return nil }
        if isUnfinished(String(above[start..<end])) { return Join(trailing: above.count - end, leading: lead) }
        let inCell = above[end...].contains(where: isBorder) && above[end - 1].isNumber
        let digits = below[lead...].prefix { $0.isNumber }
        guard inCell, !digits.isEmpty, below[(lead + digits.count)...].allSatisfy(TerminalTail.isEdge) else { return nil }
        return Join(trailing: above.count - end, leading: lead)
    }

    /// A box-drawing character: a table's or a TUI's border.
    private static func isBorder(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) }
    }

    private static func isPathCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_@.+-/~:#–—".contains(character)
    }

    /// A row's last word that isn't a whole reference with a line by itself: `src/dir_entry.`,
    /// `walk.rs:661-`, `walk.rs` (its `:661` may be on the next row).
    private static func isUnfinished(_ word: String) -> Bool {
        let length = (word as NSString).length
        return !TerminalReferences.find(in: word).contains { $0.lines != nil && NSMaxRange($0.range) == length }
    }
}

extension Board {
    /// A reference the user ⌘-clicked in terminal `tile`. `path` is absolute; it is stored
    /// board-relative when it lives under the root. Like an editor's preview tab, the terminal
    /// has one preview tile that each ⌘-click re-aims, so clicking down a list of hits doesn't
    /// pile up tiles:
    /// - a code tile already showing `path` at `lines` (`tileShowing`: exactly, or a captioned
    ///   tile whose range holds them; follow tiles excluded, they belong to their agent) is the
    ///   answer anywhere on the board (`existing`: the canvas goes to it);
    /// - else the tile the terminal's last ⌘-click opened is re-aimed, while nobody has changed
    ///   it since (moved, resized, re-based, re-aimed: its `rev`) and the user hasn't kept it
    ///   (`keepCode`: scrolled, clicked or selected in it, opened it in an editor), as
    ///   navigation (`reaimForNavigation`: not an undo step, Back re-aims it back);
    /// - else a new tile opens beside the terminal (`place(near:)`), as wide as its file's lines
    ///   need (`newCodeSize`) and only its height cut down, to `followMinimumSize`'s, to land in
    ///   view, and becomes the terminal's preview.
    /// `newTile` (⌥⌘-click) always opens a new tile, which the user keeps.
    @discardableResult
    public func openCode(path: String, lines: LineRange?, beside tile: ObjectID, newTile: Bool = false) -> CodeOpened {
        let stored = relativePath(path)
        // A file named without a line opens at its top.
        let range = lines?.json ?? .null
        if !newTile {
            if let existing = tileShowing(CodeAim(path: stored, range: lines), near: objects[tile]?.frame) {
                return CodeOpened(id: existing, created: false, reaim: nil, existing: true)
            }
            if let preview = codePreviews[tile], let object = objects[preview.tile], object.rev == preview.rev,
               let reaim = reaimForNavigation(object.id, to: CodeAim(path: stored, range: lines)) {
                return CodeOpened(id: object.id, created: false, reaim: reaim)
            }
        }
        let props: JSONValue = .object(["path": .string(stored), "range": range].filter { $0.value != .null })
        let size = newCodeSize(props)
        let created = create(type: .code, props: props, frame: place(width: size.w, height: size.h, near: tile, shrinkingTo: (size.w, Self.followMinimumSize.h)))
        if !newTile { codePreviews[tile] = (created.id, created.rev) }
        return CodeOpened(id: created.id, created: true, reaim: nil)
    }

    /// The user kept code tile `id` (scrolled, clicked or selected in it, opened it in an
    /// editor): no terminal's ⌘-click re-aims it any more.
    public func keepCode(_ id: ObjectID) {
        guard codePreviews.values.contains(where: { $0.tile == id }) else { return }
        codePreviews = codePreviews.filter { $0.value.tile != id }
    }
}

/// How a terminal whose session is gone (after a reboot) resumes the agent it recorded
/// (`props.agent`, from `agent.report_session`: its `kind`, and `session(of:)`: omp's session
/// file, any other agent's session id) with the options of the tile's own `command` when that
/// runs the same agent, so a restart keeps the user's flags
/// (Codex's `-c` trust override, Claude's `--model` or `--dangerously-skip-permissions`, omp's
/// `-e`). What would pick or start another conversation is left out: the command's own session
/// selectors (`--resume`, `--continue`, Codex's `resume <id>`) and its prompt (positional words,
/// `--prompt`), which the session already holds. easld resumes the terminals it owns the same way
/// (`session.ResumeArgv`, a port of `argv`): Tests/Fixtures/agent-resume.json holds the cases
/// both are checked against.
public enum AgentResume {
    /// How one agent's command line reads. Options not listed take no value; `--name=value`
    /// always carries its own.
    struct Grammar {
        /// The executable's name (`argv[0]`'s last path component).
        var program: String
        /// Options taking one value.
        var values: Set<String> = []
        /// Options taking every following word up to the next option (`<tools...>`).
        var lists: Set<String> = []
        /// Options whose value is optional: the next word unless it is an option.
        var optional: Set<String> = []
        /// Options left out of the resumed command, with their values.
        var dropped: Set<String> = []
        /// Positional words are kept (opencode's `[project]`); otherwise they are a prompt or a
        /// subcommand (Codex's `resume <id>`) and left out.
        var keepsPositionals = false
        /// The resumed command from the kept arguments and the session.
        var resume: (_ program: String, _ kept: [String], _ session: String) -> [String]
    }

    static func grammar(_ kind: String) -> Grammar? {
        switch kind {
        case "omp":
            Grammar(program: "omp",
                    values: ["--model", "--smol", "--slow", "--plan", "--prewalk-into", "--plan-yolo-into", "--provider", "--api-key", "--system-prompt",
                             "--system-prompt-template", "--append-system-prompt", "--profile", "--alias", "--cwd", "--mode", "--config", "--add-dir",
                             "--session-dir", "--models", "--tools", "--thinking", "--service-tier", "--hook", "-e", "--extension", "--skills",
                             "--export", "--max-time"],
                    optional: ["-r", "--resume"],
                    dropped: ["-r", "--resume", "-c", "--continue", "--from-claude", "--from-codex"],
                    resume: { [$0] + $1 + ["--resume=\($2)"] })
        case "claude":
            Grammar(program: "claude",
                    values: ["--agent", "--agents", "--append-system-prompt", "--append-system-prompt-file", "--autocompact", "--client-data-url",
                             "--debug-file", "--effort", "--environment", "--fallback-model", "--input-format", "--json-schema", "--max-budget-usd",
                             "--model", "-n", "--name", "--output-format", "--permission-mode", "--permission-prompts", "--permission-prompt-tool",
                             "--plugin-dir", "--plugin-url", "--remote-control-session-name-prefix", "--session-id", "--setting-sources", "--settings",
                             "--system-prompt", "--system-prompt-file", "--system-prompt-snapshot"],
                    lists: ["--add-dir", "--allowedTools", "--allowed-tools", "--betas", "--disallowedTools", "--disallowed-tools", "--file",
                            "--mcp-config", "--tools"],
                    optional: ["-d", "--debug", "--cloud", "--prompt-suggestions", "--remote-control", "-w", "--worktree", "-r", "--resume",
                               "--from-pr", "--teleport"],
                    dropped: ["-r", "--resume", "-c", "--continue", "--session-id", "--fork-session", "--from-pr", "--teleport"],
                    resume: { [$0] + $1 + ["--resume", $2] })
        case "codex":
            // `codex resume` takes the same options as `codex`; given after `resume` they are the
            // ones Codex keeps (its `-c` is a global clap option: the deepest level that has any wins).
            Grammar(program: "codex",
                    values: ["-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env", "-m", "--model", "--local-provider",
                             "-p", "--profile", "-s", "--sandbox", "-C", "--cd", "--add-dir", "-a", "--ask-for-approval"],
                    lists: ["-i", "--image"],
                    dropped: ["--last", "--all", "--include-non-interactive"],
                    resume: { [$0, "resume"] + $1 + [$2] })
        case "gemini":
            Grammar(program: "gemini",
                    values: ["-m", "--model", "--approval-mode", "-o", "--output-format", "-p", "--prompt", "-i", "--prompt-interactive", "-r", "--resume"],
                    lists: ["-e", "--extensions", "--include-directories", "--allowed-mcp-server-names", "--allowed-tools"],
                    dropped: ["-p", "--prompt", "-i", "--prompt-interactive", "-r", "--resume"],
                    resume: { [$0] + $1 + ["--resume", $2] })
        case "opencode":
            Grammar(program: "opencode",
                    values: ["--log-level", "--port", "--hostname", "--mdns-domain", "-m", "--model", "-s", "--session", "--prompt", "--agent"],
                    lists: ["--cors"],
                    dropped: ["-s", "--session", "-c", "--continue", "--fork", "--prompt"],
                    keepsPositionals: true,
                    resume: { [$0] + $1 + ["--session", $2] })
        default: nil
        }
    }

    /// What a new session of terminal `object` runs before dropping to a login shell (easld's
    /// `session.InitialArgv` too): after a reboot, the agent session it recorded resumed with the
    /// options of its own `command` (`argv`); otherwise its `command`; nil for neither. A hosted
    /// terminal's session file is on its host, where the Mac can't look: its recorded path is
    /// kept, as agent.restart keeps it, so one omp's /move renamed there resumes by that stale
    /// path (only the host could choose, and `session.spawn` carries one command).
    public static func initialArgv(_ object: CanvasObject,
                                   exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]? {
        let command = object.props["command"]?.array?.compactMap(\.string) ?? []
        let resume = HostedTerminal.host(of: object) == nil
            ? argv(agent: object.props["agent"], command: command, exists: exists)
            : argv(agent: object.props["agent"], command: command, exists: { _ in true })
        return resume ?? (command.isEmpty ? nil : command)
    }

    /// The command resuming the session `agent` recorded (`props.agent`: `rebootSession(of:)` of
    /// its `kind`); nil for an agent that can't be resumed or recorded no session. `command` is the
    /// tile's own (`props.command`): its options are kept when its program is that agent (by name,
    /// any directory).
    public static func argv(agent: JSONValue?, command: [String] = [],
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]? {
        guard let kind = agent?["kind"]?.string, let grammar = grammar(kind),
              let session = rebootSession(of: agent, exists: exists) else { return nil }
        let (program, kept) = options(of: command, grammar)
        return grammar.resume(program, kept, session)
    }

    /// The session a new session of the terminal resumes (`argv`, easld's
    /// `session.RebootSession`): `session(of:)`'s, with omp's session file only while `exists`
    /// finds it (an empty path is none: omp's /move renames the file without a new report, and omp
    /// 18.8 refuses a path with no file), else the session id, which omp finds in any project. A
    /// hosted tile's file is on its host, so the Mac resumes it by id. Nil for none.
    static func rebootSession(of agent: JSONValue?, exists: (String) -> Bool) -> String? {
        let id = agent?["sessionId"]?.string ?? ""
        var session = (agent?["kind"]?.string == "omp" ? agent?["sessionPath"]?.string : nil) ?? id
        if !id.isEmpty, session != id, session.isEmpty || !exists(session) { session = id }
        return session.isEmpty ? nil : session
    }

    /// The program `command` runs the agent as (its own path when it is that agent, else the
    /// agent's name) and the options of it the agent keeps (`Grammar.dropped` and `dropping`
    /// left out with their values, and positional words unless `keepsPositionals`).
    static func options(of command: [String], _ grammar: Grammar, dropping: Set<String> = []) -> (program: String, kept: [String]) {
        guard let first = command.first, (first as NSString).lastPathComponent == grammar.program else { return (grammar.program, []) }
        var kept: [String] = []
        var words = command.dropFirst()[...]
        var positionalOnly = false
        while let word = words.popFirst() {
            if word == "--", !positionalOnly {
                positionalOnly = true
                continue
            }
            if positionalOnly || !word.hasPrefix("-") || word == "-" {
                if grammar.keepsPositionals { kept.append(word) }
                continue
            }
            let name = word.hasPrefix("--") ? String(word.prefix { $0 != "=" }) : word
            var option = [word]
            if !word.contains("=") || !word.hasPrefix("--") {
                if grammar.values.contains(name), let value = words.popFirst() {
                    option.append(value)
                } else if grammar.lists.contains(name) {
                    while let value = words.first, !value.hasPrefix("-") { option.append(value); words.removeFirst() }
                } else if grammar.optional.contains(name), let value = words.first, !value.hasPrefix("-") {
                    option.append(value)
                    words.removeFirst()
                }
            }
            if !grammar.dropped.contains(name), !dropping.contains(name) { kept += option }
        }
        return (first, kept)
    }
}

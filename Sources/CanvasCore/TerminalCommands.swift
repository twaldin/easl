import Foundation

/// A command a terminal tile's shell ran, as Ghostty's shell integration reports it when the
/// command finishes (OSC 133 D: the exit status; Ghostty measures the duration from the
/// command's start, OSC 133 C). `command` is the command line when easl saw it: the title the
/// integration sets while it runs, or for an older block the prompt row above its output.
public struct TerminalCommand: Codable, Equatable, Sendable {
    public var command: String?
    public var exit: Int?
    public var durationMs: Int?

    public init(command: String? = nil, exit: Int? = nil, durationMs: Int? = nil) {
        self.command = command
        self.exit = exit
        self.durationMs = durationMs
    }

    /// A command that ran at least this long raises a marker when it finishes while nobody looks.
    public static let noticeAfterMs = 30_000
    /// A successful command shows its duration in the tile's header from this long.
    public static let showAfterMs = 10_000

    /// `exit 1 · 42 s`: what the header shows after a command that failed or ran long; nil after a
    /// quick success, so a terminal that works stays quiet.
    public var status: String? {
        let failed = (exit ?? 0) != 0
        let long = (durationMs ?? 0) >= Self.showAfterMs
        guard failed || long else { return nil }
        var parts: [String] = []
        if failed, let exit { parts.append("exit \(exit)") }
        if let durationMs, long || durationMs >= 1000 { parts.append(Self.duration(durationMs)) }
        return parts.joined(separator: " · ")
    }

    /// The attention marker's text: `go test ./... exited 1 · 42 s`, `make finished · 3 min 2 s`,
    /// naming the command that ran long (`significant`), not a compound line's setup.
    public var noticeMessage: String {
        let name = command.map { MentionContext.clip(Self.significant($0), 60) } ?? "Command"
        let outcome = switch exit {
        case 0?: "finished"
        case let code?: "exited \(code)"
        case nil: "finished"
        }
        return ([ "\(name) \(outcome)" ] + (durationMs.map { [Self.duration($0)] } ?? [])).joined(separator: " · ")
    }

    /// A bell this soon after a command finished is taken as that command's.
    public static let bellAfterCommand: TimeInterval = 5

    /// A bell's marker text, naming what rang it: the foreground program (`pytest rang the
    /// bell`); at the prompt, the command that just finished (`Bell after \`make test\``), else
    /// the shell itself (`zsh rang the bell`: its line editor beeps at a key it has no use for).
    public static func bellMessage(program: String?, shell: String?, last: TerminalCommandLog.Entry?, at date: Date) -> String {
        if let program { return "\(MentionContext.clip(program, 60)) rang the bell" }
        if let last, let command = last.command.command, date.timeIntervalSince(last.finishedAt) <= bellAfterCommand {
            return "Bell after `\(MentionContext.clip(significant(command), 60))`"
        }
        return "\(shell ?? "The shell") rang the bell"
    }

    /// `0.4 s`, `42 s`, `3 min 2 s`, `1 h 5 min`.
    public static func duration(_ ms: Int) -> String {
        if ms < 10_000 { return String(format: "%.1f s", Double(ms) / 1000) }
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }

    /// The part of a command line a marker names: from its first segment (split at `;`, `&&`,
    /// `||` outside quotes) that isn't setup (`cd`, `export`, `clear`, `source`, `.`, `unset`,
    /// `set`, `sleep`, variable assignments alone), without leading `VAR=value` assignments or an `env`
    /// that only sets them: `cd crates/x && cargo test` → `cargo test`,
    /// `clear; RUST_BACKTRACE=1 cargo test` → `cargo test`. The line itself when all of it is setup.
    public static func significant(_ line: String) -> String {
        let words = Self.words(line)
        var start = 0
        while start < words.count {
            var index = start
            if words[index].text == "env" { index += 1 }
            while index < words.count, words[index].isAssignment { index += 1 }
            let end = words[index...].firstIndex { $0.isSeparator } ?? words.count
            guard index < end else {
                start = end + 1
                continue
            }
            if setupCommands.contains(words[index].text) {
                start = end + 1
                continue
            }
            return String(line[words[index].range.lowerBound...]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private static let setupCommands: Set<String> = ["cd", "pushd", "popd", "export", "clear", "source", ".", "unset", "set", "alias", "true", "sleep"]

    /// A word of a command line as the shell splits it (quotes and backslashes keep blanks and
    /// operators inside), or a list operator (`;`, `&&`, `||`, `&`, a newline).
    private struct Word {
        var text: String
        var range: Range<String.Index>
        var isSeparator = false
        /// `NAME=value`: a variable assignment.
        var isAssignment: Bool {
            guard !isSeparator, let equals = text.firstIndex(of: "="), equals != text.startIndex else { return false }
            let name = text[..<equals]
            return name.first.map { $0 == "_" || ($0.isASCII && $0.isLetter) } == true && name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
        }
    }

    private static func words(_ line: String) -> [Word] {
        func isOperator(_ index: String.Index) -> Bool {
            let character = line[index]
            return character == ";" || character == "\n" || character == "&" || (character == "|" && line[line.index(after: index)...].first == "|")
        }
        var words: [Word] = []
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == " " || character == "\t" {
                index = line.index(after: index)
                continue
            }
            if isOperator(index) {
                var end = line.index(after: index)
                if character == "&" || character == "|", end < line.endIndex, line[end] == character { end = line.index(after: end) }
                words.append(Word(text: String(line[index..<end]), range: index..<end, isSeparator: true))
                index = end
                continue
            }
            let start = index
            var quote: Character?
            while index < line.endIndex {
                let current = line[index]
                if let open = quote {
                    if current == open { quote = nil } else if current == "\\", open == "\"" { index = line.index(after: index) }
                } else if current == "'" || current == "\"" {
                    quote = current
                } else if current == "\\" {
                    index = line.index(after: index)
                } else if current == " " || current == "\t" || isOperator(index) {
                    break
                }
                if index < line.endIndex { index = line.index(after: index) }
            }
            words.append(Word(text: String(line[start..<index]), range: start..<index))
        }
        return words
    }

    /// As the API reports it (`agent.list`, `object.get` `lastCommand`).
    public func json(finishedAt: Date? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let command { fields["command"] = .string(command) }
        fields["exit"] = exit.map { .number(Double($0)) } ?? .null
        if let durationMs { fields["durationMs"] = .number(Double(durationMs)) }
        if let finishedAt { fields["finishedAt"] = .string(finishedAt.formatted(.iso8601)) }
        return .object(fields)
    }
}

/// Which command a terminal is running, from what its shell tells the terminal: Ghostty's shell
/// integration titles the terminal with the command line when it starts (preexec) and with the
/// directory at each prompt. A prompt framework may title it too while it draws the prompt, and
/// the program may retitle it while it runs; so the command is the first title that arrives well
/// after a prompt was drawn (the user pressed Return) and isn't one of that prompt's titles.
public struct TerminalCommandTracker: Sendable {
    /// Titles within this long after a prompt belong to the prompt.
    public static let promptWindow: TimeInterval = 0.3

    private var promptAt: Date?
    private var promptTitles: Set<String> = []
    private var command: String?
    private var program: String?

    public init() {}

    /// The shell drew a prompt: it reported its directory (OSC 7), or a command finished.
    public mutating func prompt(at date: Date) {
        if promptAt.map({ date.timeIntervalSince($0) > Self.promptWindow }) ?? true { promptTitles = [] }
        promptAt = date
    }

    /// The terminal's title changed. `promptTitle`: the title the integration gives a prompt in
    /// the directory the shell reported (`~/src/app`). True when this title is the command the
    /// shell just started. Before the first prompt since easl attached, no title is: the title
    /// a reattached session comes back with is the program's own (`π ! Add Per-Command Help…`),
    /// which the header shows, not a command line it hides.
    @discardableResult
    public mutating func title(_ title: String, at date: Date, promptTitle: String?) -> Bool {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let promptAt else { return false }
        if date.timeIntervalSince(promptAt) <= Self.promptWindow {
            promptTitles.insert(title)
            return false
        }
        guard command == nil, title != promptTitle, !promptTitles.contains(title) else { return false }
        command = title
        return true
    }

    /// The command line the shell is running, as its integration titled the terminal with it;
    /// nil at the prompt or before that title came.
    public var running: String? { command }

    /// The program seen running in the foreground (`TerminalName.program`), for a command whose
    /// title never came (the user turned the integration's `title` feature off).
    public mutating func running(program: String?) {
        if let program { self.program = program }
    }

    /// A command finished (OSC 133 D; Ghostty reports one only after a C, timing it from
    /// there); the tracker starts over for the next one. Only the shell's own marks are
    /// commands: nil, with the tracker left as it was, for a mark while a program holds the
    /// foreground (`shellAtPrompt` false: an agent TUI's own C/D pairs, 0 ms apart, titled with
    /// its spinner) and for any mark while the tile's agent reports a lifecycle (its marks and
    /// titles aren't the user's shell commands). The command the shell ran it from is still
    /// named when the shell's D comes.
    public mutating func finished(exit: Int?, durationNanos: UInt64, at date: Date, shellAtPrompt: Bool, agentReporting: Bool) -> TerminalCommand? {
        guard shellAtPrompt, !agentReporting else { return nil }
        let finished = TerminalCommand(command: command ?? program, exit: exit, durationMs: Int(durationNanos / 1_000_000))
        command = nil
        program = nil
        prompt(at: date)
        return finished
    }

    /// The title Ghostty's integration gives a prompt in `cwd`: zsh's `%~`, the home directory as `~`.
    public static func promptTitle(cwd: String?, home: String) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }
}

/// How `agent.prompt` puts text into a shell at its prompt.
public enum ShellTyping {
    /// Ghostty's `text:` binding action that types `text` as keys, one write with no
    /// bracketed-paste markers: nil unless it is one line of printable text (a newline would run
    /// what came before it, a control character is a key). A paste's `ESC [200~` read in two
    /// parts leaves zsh `[200~…~` to run, which a typed command can't.
    public static func action(_ text: String) -> String? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value) }) else { return nil }
        return "text:" + text.replacingOccurrences(of: "\\", with: "\\\\")
    }
}

/// Terminal text as mentions and `agent.read` hand it to an agent.
public enum TerminalExcerpt {
    /// Lines of terminal text: trailing blanks trimmed off each line (terminals pad rows), blank
    /// lines at either end dropped.
    public static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(TerminalTail.trimmed)
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines
    }

    /// `lines` whole when they fit in `head + tail` lines (one more would only replace a marker).
    /// Else what matters, in order: progress-only rows (pytest's `....F... [ 40%]`, unittest's
    /// dots, a progress bar at some percent) go first; of the rest, the first few lines (what
    /// ran) and the last ones (how it ended: a test run's summary) stay, then failure lines
    /// (`isFailure`: pytest's `E` and `>` lines and section headers, `FAILED`, errors, a
    /// compiler's `-->` location lines, traceback and stack frames) in the order they came, then
    /// the rest of the first `head` lines, then lines back from the end, `head + tail` in all.
    /// Each gap reads `… N lines omitted …` (`progress lines` when that is all it left out); a
    /// gap of one line shows the line.
    public static func trim(_ lines: [String], head: Int, tail: Int) -> [String] {
        guard lines.count > head + tail + 1 else { return lines }
        let progress = Set(lines.indices.filter { isProgress(lines[$0]) })
        let kept = lines.indices.filter { !progress.contains($0) }
        let budget = head + tail
        var chosen = Set<Int>()
        if kept.count <= budget + 1 {
            chosen = Set(kept)
        } else {
            chosen.formUnion(kept.prefix(min(head, 3)))
            chosen.formUnion(kept.suffix(min(tail, 10)))
            for index in kept where chosen.count < budget && isFailure(lines[index]) { chosen.insert(index) }
            for index in kept.prefix(head) where chosen.count < budget { chosen.insert(index) }
            for index in kept.reversed() where chosen.count < budget { chosen.insert(index) }
        }
        var trimmed: [String] = []
        var next = 0
        func gap(to end: Int) {
            let left = next..<end
            if left.count == 1, !progress.contains(next) {
                trimmed.append(lines[next])
            } else if !left.isEmpty {
                let kind = left.allSatisfy(progress.contains) ? "progress " : ""
                trimmed.append("… \(left.count) \(kind)line\(left.count == 1 ? "" : "s") omitted …")
            }
        }
        for index in chosen.sorted() {
            gap(to: index)
            trimmed.append(lines[index])
            next = index + 1
        }
        gap(to: lines.count)
        return trimmed
    }

    /// A test runner's progress row (`tests/test_x.py ....F.. [ 42%]`, unittest's `.....F..`)
    /// or a progress bar at a percent (`━━━━━━━━━━ 45%`): nothing an agent reads there that
    /// the summary doesn't say.
    static func isProgress(_ line: String) -> Bool {
        // rustc's `...` where it leaves out source lines, not three passing tests.
        if line.trimmingCharacters(in: .whitespaces) == "..." { return false }
        let range = NSRange(location: 0, length: (line as NSString).length)
        if let match = outcomes.firstMatch(in: line, range: range) {
            let marks = (line as NSString).substring(with: match.range(at: 1))
            return match.range(at: 2).location != NSNotFound || (marks.count >= 3 && marks.contains("."))
        }
        return bar.firstMatch(in: line, range: range) != nil
    }

    /// A line that says what failed and where: pytest's `E` (the assertion) and `>` (the failing
    /// line) lines and `___ test ___` / `=== FAILURES ===` headers, `FAILED`/`ERROR` lines, an
    /// error or exception, a compiler's `error:` and the location lines under it (rustc's
    /// `--> src/x.rs:9:52` and `::: src/y.rs:2:3`), a Python traceback, a Rust panic, a stack
    /// frame at a `file:line:col` (`at ./tests/t.rs:14:8`, `at run (/srv/app/x.ts:39:5)`).
    static func isFailure(_ line: String) -> Bool {
        failure.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static let outcomes = try! NSRegularExpression(pattern: #"^\s*(?:\S+\.py\s+)?([.FEsxX]+)\s*(\[\s*\d{1,3}%\])?$"#)
    private static let bar = try! NSRegularExpression(pattern: #"[█▉▊▋▌▍▎▏━■░▒▓#]{4,}.*\b\d{1,3}(?:\.\d+)?%"#)
    private static let failure = try! NSRegularExpression(pattern:
        #"^E(?:\s|$)|^>\s|^_{3,} .+ _{3,}$|^={3,} .+ ={3,}$|\b(?:FAILED|FAIL|ERROR)\b|(?:Error|Exception)\b|\berror(?:\[\w+\])?:|Traceback \(most recent call last\)|^\s*File ".+", line \d+|panicked at|^\s*(?:-->|:::)\s+\S+:\d+:\d+|^\s*at\s.*\S:\d+:\d+\)?$"#)

    /// The rows around row `index` of `rows` (a terminal's screen): up to `before` rows above and
    /// `after` below, blank rows at either end dropped, the clicked row marked `>` and the others
    /// indented to match.
    public static func around(_ rows: [String], index: Int, before: Int, after: Int) -> [String] {
        guard rows.indices.contains(index) else { return [] }
        let trimmed = rows.map(TerminalTail.trimmed)
        var from = max(0, index - before), to = min(trimmed.count - 1, index + after)
        while from < index, trimmed[from].isEmpty { from += 1 }
        while to > index, trimmed[to].isEmpty { to -= 1 }
        return (from...to).map { ($0 == index ? "> " : "  ") + trimmed[$0] }
    }
}

/// A command's block on a terminal's screen, as Ghostty's shell integration marks it: the
/// command's output and the prompt row just above it.
public enum TerminalBlocks {
    /// How many rows `text` covers in a terminal `columns` wide (each line at least one row, a
    /// long one wrapped).
    public static func rows(of text: String, columns: Int) -> Int {
        guard columns > 0 else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            total + max(1, (TerminalStyledTail.width(line) + columns - 1) / columns)
        }
    }

    /// The most rows a prompt takes between the last command's output and the cursor (a
    /// two-line prompt, a blank line before it).
    public static let promptRows = 4

    /// `output` without what precedes its command's own line. A block Ghostty found no prompt
    /// above (the first command after easl reattached to the session: the prompt it ran from
    /// came back as plain text, without its mark) starts at the top of the scrollback, so the
    /// command's line, `❯ go test ./...`, is inside it: its output starts after that line.
    public static func output(_ output: String, after command: String?) -> String {
        guard let command = command?.trimmingCharacters(in: .whitespaces), !command.isEmpty else { return output }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let line = lines.lastIndex(where: { isCommandLine(String($0), of: command) }) else { return output }
        return lines[(line + 1)...].joined(separator: "\n")
    }

    /// What a block's output ending on screen row `outputEnd` ran: the shell's `last` command
    /// when this is its block (the shell is back at its prompt, `cursorRow` just below the output,
    /// and the prompt row above the output ends with that command), else just the command line
    /// shown in `promptRow` (`commandLine`), without exit status or duration.
    public static func command(promptRow: String?, outputEnd: Int, cursorRow: Int?, atPrompt: Bool, last: TerminalCommand?) -> TerminalCommand? {
        let shown = promptRow.map(commandLine).flatMap { $0.isEmpty ? nil : $0 }
        if let last, atPrompt, let cursorRow, cursorRow > outputEnd, cursorRow - outputEnd <= promptRows {
            let matches = last.command.map { command in shown.map { isCommandLine($0, of: command) } ?? true } ?? true
            if matches {
                var block = last
                if block.command == nil { block.command = shown }
                return block
            }
        }
        return shown.map { TerminalCommand(command: $0) }
    }

    /// The command on a prompt row: the row without the prompt's own leading symbol (`❯ `, `$ `,
    /// `% `, `➜ `: up to three characters that aren't ASCII letters, digits or a path's start,
    /// then a space). A prompt that shows more than a symbol on that row stays in.
    public static func commandLine(_ row: String) -> String {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return trimmed }
        let head = trimmed[..<space]
        let prompt = head.count <= 3 && head.allSatisfy { !($0.isASCII && ($0.isLetter || $0.isNumber)) && !"./~([!-\"'`".contains($0) }
        return prompt ? trimmed[space...].trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// Whether `line` (terminal text, soft-wrapped rows joined) is `command`'s line: it ends with
    /// the command after a prompt (or holds it alone).
    public static func isCommandLine(_ line: String, of command: String) -> Bool {
        let command = command.trimmingCharacters(in: .whitespaces)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, trimmed.hasSuffix(command) else { return false }
        return trimmed.dropLast(command.count).last.map(\.isWhitespace) ?? true
    }
}

/// The commands a terminal's shell finished since easl attached to it, oldest first. A block
/// is found by its command's line in the terminal's text (`positions`), so it keeps its command,
/// exit status and duration after its prompt row scrolled out of view, and one `clear` wiped
/// (`clear; cargo build`) is the text above the next command's line.
public struct TerminalCommandLog: Sendable {
    public struct Entry: Equatable, Sendable {
        public var command: TerminalCommand
        public var finishedAt: Date

        public init(command: TerminalCommand, finishedAt: Date) {
            self.command = command
            self.finishedAt = finishedAt
        }
    }

    public static let capacity = 200
    public private(set) var entries: [Entry] = []

    public init() {}

    public var last: Entry? { entries.last }

    public mutating func append(_ command: TerminalCommand, at date: Date) {
        entries.append(Entry(command: command, finishedAt: date))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// The entry at `index` from the end (-1 the last).
    public subscript(fromEnd index: Int) -> Entry? {
        index < 0 && -index <= entries.count ? entries[entries.count + index] : nil
    }

    /// The newest command reported as `command` (what ran, its exit status and duration), from
    /// the end (-1 the last).
    public func index(of command: TerminalCommand) -> Int? {
        entries.lastIndex { $0.command == command }.map { $0 - entries.count }
    }

    /// Where the newest commands' lines are in `text` (the terminal's lines from the top of its
    /// scrollback, soft-wrapped rows joined, the last one the prompt's input line), by index
    /// from the end: each the last line above the newer one's that ends with it. The first
    /// command not found ends the search, older ones being gone too; one that clears the screen
    /// (`clear`, `reset` among its words) has line -1: its output starts at the top.
    public func positions(in text: [String]) -> [Int: Int] {
        var found: [Int: Int] = [:]
        var bound = text.count - 1
        for index in stride(from: -1, through: -entries.count, by: -1) {
            let command = entries[entries.count + index].command.command ?? ""
            guard let line = (0..<max(0, bound)).reversed().first(where: { TerminalBlocks.isCommandLine(text[$0], of: command) }) else {
                let words = command.split(whereSeparator: { " ;&|".contains($0) })
                if words.contains("clear") || words.contains("reset") { found[index] = -1 }
                break
            }
            found[index] = line
            bound = line
        }
        return found
    }

    /// The lines of `text` the output of the command at `index` from the end may cover: below its
    /// line, up to the next command's line (the input line for the last one) less the
    /// `promptAbove` lines a prompt shows above its input line. Nil when its line isn't found.
    public func output(_ index: Int, in text: [String], promptAbove: Int, positions: [Int: Int]? = nil) -> Range<Int>? {
        let positions = positions ?? self.positions(in: text)
        guard let line = positions[index] else { return nil }
        let next = index == -1 ? text.count - 1 : positions[index + 1] ?? text.count - 1
        return (line + 1)..<max(line + 1, next - promptAbove)
    }

    /// Which command's output holds line `line` of `text`, from the end (-1 the last).
    public func block(holding line: Int, in text: [String], positions: [Int: Int]? = nil) -> Int? {
        let positions = positions ?? self.positions(in: text)
        return positions.keys.first { index in output(index, in: text, promptAbove: 0, positions: positions)?.contains(line) == true }
    }
}

/// Where the shell integration tiles load comes from (docs/contracts.md "Terminal tile
/// environment"): Ghostty's own `shell-integration-features` stay Ghostty's (`GHOSTTY_SHELL_FEATURES`).
public enum TerminalShellIntegration {
    /// The directory holding Ghostty's `zsh/` and `bash/` integration for tiles to load, from the
    /// user's `shell-integration` setting: `none` turns it off, like in Ghostty; anything else
    /// (`detect`, a shell's name, unset) loads it. Nil when off or not shipped.
    public static func directory(setting: String?, resources: URL?, isDirectory: (String) -> Bool) -> String? {
        guard setting?.trimmingCharacters(in: .whitespaces) != "none", let resources else { return nil }
        let directory = resources.appendingPathComponent("shell-integration").path
        return isDirectory(directory) ? directory : nil
    }
}

/// A pytest node id in test output (`tests/test_cli.py::test_help`,
/// `tests/test_cli.py::TestGroup::test_help[param-1]`): the file and the names in it.
public enum PytestNode {
    /// The line of the last name's `def` (or `class`), inside the classes the names before it
    /// open, by indentation; nil when the file has no such definition.
    public static func line(of names: [String], in source: String) -> Int? {
        guard !names.isEmpty else { return nil }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        /// Only definitions indented deeper than this belong to the class found so far.
        var outer = -1
        var found: Int?
        for (position, name) in names.enumerated() {
            let last = position == names.count - 1
            found = nil
            while index < lines.count {
                let line = lines[index]
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                let body = line.dropFirst(indent)
                index += 1
                if !body.isEmpty, indent <= outer, !body.hasPrefix("#"), !body.hasPrefix(")"), outer >= 0 { return nil }
                // The first name is the module's own; the next ones are members of the class before.
                guard position == 0 ? indent == 0 : indent > outer else { continue }
                let keywords = last ? ["def ", "async def ", "class "] : ["class "]
                guard let keyword = keywords.first(where: { body.hasPrefix($0) }) else { continue }
                let rest = body.dropFirst(keyword.count)
                guard rest.hasPrefix(name), let next = rest.dropFirst(name.count).first, next == "(" || next == ":" else { continue }
                found = index
                outer = indent
                break
            }
            if found == nil { return nil }
        }
        return found
    }
}

/// What a terminal tile knows about itself now (`agent.list`, `agent.read`, `object.get`).
public struct TerminalStatus: Sendable {
    /// The title the program set (OSC 0/2).
    public var title: String?
    /// What runs in the foreground (`TerminalName.program`); nil at the prompt.
    public var program: String?
    /// The last command the shell finished, and when.
    public var lastCommand: TerminalCommandLog.Entry?
    /// The foreground process of the session's shell (the agent, when one runs); nil at the
    /// prompt or before the session's shell is known.
    public var pid: Int32?
    /// The terminal has keyboard focus in the key window while easl is the active app.
    public var focused: Bool

    public init(title: String? = nil, program: String? = nil, lastCommand: TerminalCommandLog.Entry? = nil, pid: Int32? = nil, focused: Bool = false) {
        self.title = title
        self.program = program
        self.lastCommand = lastCommand
        self.pid = pid
        self.focused = focused
    }
}

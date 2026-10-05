import Foundation

/// A question an agent (or a script on another machine) asks the user on the board (`type:
/// question`, schema `QuestionProps`): the question, options to pick from (one recommended),
/// context to look at, who asks, and, once the user answers, the answer. It replaces asking in
/// chat and polling for a pick: the user answers on the board, and the answer reaches the asker as
/// an `object.updated` event (`easl ask --wait`) and, when the asker is a terminal on the board, as
/// a mention on its next prompt (`Board.questionWritten`).
///
/// Lifecycle: open → answered | cancelled | expired, each final. Archiving is not a status:
/// `archived: true` on a closed question hides its tile and keeps how it ended. Validation
/// (`problem`) is the one rule both servers apply, messages included (easld mirrors it).
public struct QuestionSpec: Equatable, Sendable {
    public enum Status: String, Sendable, CaseIterable {
        case open, answered, cancelled, expired
    }

    public struct Option: Equatable, Sendable {
        public var id: String
        public var label: String
        public var why: String?
    }

    public enum Context: Equatable, Sendable {
        case object(ObjectID)
        case url(String)
        case path(String, lines: LineRange?)

        /// How it reads in a mention and on the tile's link: the id, the URL, `path:12-20`.
        public var label: String {
            switch self {
            case .object(let id): id
            case .url(let url): url
            case .path(let path, let lines?): lines.start == lines.end ? "\(path):\(lines.start)" : "\(path):\(lines.start)-\(lines.end)"
            case .path(let path, nil): path
            }
        }
    }

    /// Who asks: a terminal on the board (`tile`), or a name (an agent elsewhere, a script),
    /// optionally on a host.
    public struct Asker: Equatable, Sendable {
        public var tile: ObjectID?
        public var name: String?
        public var host: String?

        /// `cos@mini`, `cos`, `terminal obj_…`, or `cos@mini (terminal obj_…)`.
        public var label: String {
            let named = name.map { name in host.map { "\(name)@\($0)" } ?? name }
            switch (named, tile) {
            case (let named?, let tile?): return "\(named) (terminal \(tile))"
            case (let named?, nil): return named
            case (nil, let tile?): return "terminal \(tile)"
            case (nil, nil): return "someone"
            }
        }
    }

    public struct Answer: Equatable, Sendable {
        public var option: String?
        public var note: String?
        public var at: Date?
        public var by: Actor?
    }

    public var question: String
    public var options: [Option]
    public var recommended: String?
    public var context: [Context]
    public var asker: Asker?
    public var status: Status
    public var expiresAt: Date?
    public var answer: Answer?
    public var archived: Bool

    /// Reads props as stored (validated on the way in); anything unreadable is left out.
    public init(_ props: JSONValue) {
        question = props["question"]?.string ?? ""
        options = (props["options"]?.array ?? []).compactMap { option in
            guard let id = option["id"]?.string, let label = option["label"]?.string else { return nil }
            return Option(id: id, label: label, why: option["why"]?.string)
        }
        recommended = props["recommended"]?.string
        context = (props["context"]?.array ?? []).compactMap(Self.context)
        asker = props["asker"]?.object.map { _ in
            Asker(tile: props["asker"]?["tile"]?.string, name: props["asker"]?["name"]?.string, host: props["asker"]?["host"]?.string)
        }
        status = Self.status(of: props)
        expiresAt = props["expiresAt"]?.string.flatMap(Self.date)
        answer = props["answer"]?.object.map { _ in
            let by = props["answer"]?["by"].flatMap { try? $0.decode(Actor.self) }
            return Answer(option: props["answer"]?["option"]?.string, note: props["answer"]?["note"]?.string,
                          at: props["answer"]?["at"]?.string.flatMap(Self.date), by: by)
        }
        archived = props["archived"]?.bool == true
    }

    /// `props.status`; a question without a status it knows is open.
    public static func status(of props: JSONValue) -> Status {
        props["status"]?.string.flatMap(Status.init) ?? .open
    }

    /// Still waiting on the user at `now`: open, and not past `expiresAt`.
    public func isWaiting(at now: Date) -> Bool {
        status == .open && (expiresAt.map { $0 > now } ?? true)
    }

    public func option(_ id: String?) -> Option? {
        id.flatMap { id in options.first { $0.id == id } }
    }

    // MARK: Validation

    private static let idPattern = "^[a-z]+_[0-9A-Za-z]+$"
    private static let optionKeys: Set<String> = ["id", "label", "why"]
    private static let contextKeys: Set<String> = ["object", "url", "path", "lines"]
    private static let askerKeys: Set<String> = ["tile", "name", "host"]
    /// What a closed question still takes.
    private static let closedKeys: Set<String> = ["archived", "key", "zoom"]

    static let optionsShape = "an array of {id, label, why?}"
    static let answerShape = "an answered question needs answer: {option, note?} or {note}"

    /// `object.create` props of a question as stored: `status` open and, when the call has a
    /// caller and names no asker, the calling terminal as `asker`.
    public static func creating(_ props: JSONValue, caller: ObjectID?) -> JSONValue {
        var fields = props.object ?? [:]
        if fields["status"] == nil || fields["status"] == .null { fields["status"] = .string(Status.open.rawValue) }
        if fields["asker"] == nil || fields["asker"] == .null, let caller { fields["asker"] = .object(["tile": .string(caller)]) }
        return .object(fields)
    }

    /// Why `patch` can't be written: on create (`before` nil) the props as `creating` filled them,
    /// on update the patch of `before`, judged merged. Nil when it can. The rules run in order and
    /// the first that fails is the message (docs/contracts.md "Questions"; easld says the same).
    public static func problem(_ patch: JSONValue, before: CanvasObject?) -> String? {
        if let before {
            let old = before.props["status"]?.string ?? Status.open.rawValue
            if old != Status.open.rawValue, let keys = patch.object?.keys {
                for key in keys.sorted() where !closedKeys.contains(key) {
                    let value = patch[key] ?? .null
                    let same = value == .null ? before.props[key] == nil : before.props[key] == value
                    if !same { return "question \(before.id) is \(old): only archived can change" }
                }
            }
        }
        let props = before.map { $0.props.merging(patch) } ?? patch
        func given(_ key: String) -> JSONValue? {
            guard let value = props[key], value != .null else { return nil }
            return value
        }
        guard let question = given("question")?.string, !trimmed(question).isEmpty else {
            return "a question needs props.question, a non-empty string"
        }
        guard let options = given("options")?.array else { return "a question needs props.options, \(optionsShape)" }
        var ids: [String] = []
        for (index, option) in options.enumerated() {
            guard let fields = option.object else { return "options[\(index)] must be {id, label, why?}" }
            if let unknown = fields.keys.sorted().first(where: { !optionKeys.contains($0) }) {
                return "options[\(index)] has unknown key \"\(unknown)\" (an option is {id, label, why?})"
            }
            guard let id = fields["id"]?.string, !id.isEmpty else { return "options[\(index)] needs an id, a non-empty string" }
            guard let label = fields["label"]?.string, !trimmed(label).isEmpty else { return "options[\(index)] needs a label, a non-empty string" }
            if let why = fields["why"], why != .null, why.string == nil { return "options[\(index)].why must be a string" }
            if ids.contains(id) { return "option id \"\(id)\" is used twice" }
            ids.append(id)
        }
        let idList = ids.isEmpty ? "none" : ids.joined(separator: ", ")
        if let recommended = given("recommended") {
            guard let id = recommended.string else { return "recommended must be an option id (\(idList))" }
            if !ids.contains(id) { return "recommended \"\(id)\" is not an option id (\(idList))" }
        }
        if let context = given("context") {
            guard let items = context.array else { return "props.context must be an array of {object}, {url}, or {path, lines?}" }
            for (index, item) in items.enumerated() where Self.context(item) == nil {
                return "context[\(index)] must be {object: \"obj_…\"}, {url: \"…\"}, or {path: \"…\", lines?: {start, end}}"
            }
        }
        guard let asker = given("asker") else { return "a question needs props.asker, {name, host?}, when no terminal asks it (no caller)" }
        if !validAsker(asker) { return "asker must be {tile: \"obj_…\"} or {name, host?}" }
        guard let status = given("status")?.string.flatMap(Status.init) else { return "status must be open, answered, cancelled, or expired" }
        if before == nil, status != .open { return "a question is created open, not \(status.rawValue)" }
        if let expiresAt = given("expiresAt"), expiresAt.string.flatMap(date) == nil {
            return "expiresAt must be an ISO 8601 date-time, e.g. 2026-10-05T17:00:00Z"
        }
        if status == .answered {
            guard let answer = given("answer"), answer.object != nil else { return answerShape }
            var picked = false
            if let option = answer["option"], option != .null {
                guard let id = option.string else { return "answer.option must be an option id (\(idList))" }
                if !ids.contains(id) { return "answer.option \"\(id)\" is not an option id (\(idList))" }
                picked = true
            }
            var noted = false
            if let note = answer["note"], note != .null {
                guard let text = note.string else { return "answer.note must be a string" }
                noted = !trimmed(text).isEmpty
            }
            if !picked, !noted { return answerShape }
        } else if given("answer") != nil {
            return "answer goes with status answered"
        }
        if let archived = given("archived") {
            guard let flag = archived.bool else { return "archived must be true or false" }
            if flag, status == .open { return "an open question can't be archived: answer or cancel it first" }
        }
        return nil
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isID(_ value: JSONValue?) -> Bool {
        value?.string?.range(of: idPattern, options: .regularExpression) != nil
    }

    private static func validAsker(_ asker: JSONValue) -> Bool {
        guard let fields = asker.object, fields.keys.allSatisfy(askerKeys.contains) else { return false }
        if let tile = fields["tile"], !isID(tile) { return false }
        if let name = fields["name"], name.string?.isEmpty != false { return false }
        if let host = fields["host"], host.string == nil { return false }
        return fields["tile"] != nil || fields["name"] != nil
    }

    /// One `context` item: exactly one of `object` (an id), `url`, or `path` (with `lines` only
    /// beside a path); nil for anything else.
    static func context(_ item: JSONValue) -> Context? {
        guard let fields = item.object, fields.keys.allSatisfy(contextKeys.contains) else { return nil }
        let kinds = ["object", "url", "path"].filter { fields[$0] != nil }
        guard kinds.count == 1 else { return nil }
        if fields["lines"] != nil, kinds[0] != "path" { return nil }
        switch kinds[0] {
        case "object":
            guard isID(fields["object"]), let id = fields["object"]?.string else { return nil }
            return .object(id)
        case "url":
            guard let url = fields["url"]?.string, !url.isEmpty else { return nil }
            return .url(url)
        default:
            guard let path = fields["path"]?.string, !path.isEmpty else { return nil }
            guard let lines = fields["lines"] else { return .path(path, lines: nil) }
            guard let range = lines.object, Set(range.keys) == ["start", "end"],
                  let start = range["start"]?.number, let end = range["end"]?.number,
                  start == start.rounded(), end == end.rounded(), start >= 1, end >= start, end <= Double(Int.max / 2) else { return nil }
            return .path(path, lines: LineRange(start: Int(start), end: Int(end)))
        }
    }

    // MARK: Dates

    // ISO8601DateFormatter is thread-safe once configured (as `PageLog.isoFormatter`).
    nonisolated(unsafe) private static let stampFormat: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format
    }()

    nonisolated(unsafe) private static let fractionalFormat: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    /// An RFC 3339 date-time (`2026-10-05T17:00:00Z`, an offset, fractional seconds); nil otherwise.
    public static func date(_ text: String) -> Date? {
        stampFormat.date(from: text) ?? fractionalFormat.date(from: text)
    }

    /// How easl writes a moment (`answer.at`): UTC, whole seconds.
    public static func stamp(_ date: Date) -> String {
        stampFormat.string(from: date)
    }

    // MARK: Size

    /// A new question tile's width, and the rows its height is counted in: the title bar, the
    /// question, one row per option, the context links, the note field and the footer while it
    /// is open; once closed, the question over its answer (and note) and who answered when.
    public static let width = 460.0
    public static let openBase = 194.0
    public static let optionRow = 50.0
    public static let contextRow = 30.0
    public static let closedBase = 148.0
    public static let noteRow = 40.0

    /// The tile's frame size at 100% for these props (`object.create` without a frame,
    /// `object.measure`, `size: fit`): counted from the props, not measured, so every client
    /// and server agrees. Text that needs more scrolls inside the tile.
    public static func size(_ props: JSONValue) -> (w: Double, h: Double) {
        if status(of: props) == .open {
            let options = Double(props["options"]?.array?.count ?? 0)
            let context = props["context"]?.array?.isEmpty == false ? contextRow : 0
            return (width, openBase + optionRow * options + context)
        }
        let note = props["answer"]?["note"]?.string.map { !trimmed($0).isEmpty } ?? false
        return (width, closedBase + (note ? noteRow : 0))
    }

    // MARK: Mentions

    /// What a mention of the question tells an agent, below its `[n] question obj_… "…"` line:
    /// the whole question, who asked and where it stands, the options (the recommended one
    /// marked), its context, and the answer.
    public static func mentionLines(_ props: JSONValue) -> [String] {
        let spec = QuestionSpec(props)
        var lines = ["    question: \(spec.question.replacingOccurrences(of: "\n", with: "\\n"))"]
        var state = ["asked by \(spec.asker?.label ?? "someone")", spec.status.rawValue]
        if spec.archived { state.append("archived") }
        if spec.status == .open, let expires = props["expiresAt"]?.string { state.append("expires \(expires)") }
        lines.append("    " + state.joined(separator: " · "))
        for option in spec.options {
            let recommended = option.id == spec.recommended ? " (recommended)" : ""
            lines.append("    [\(option.id)] \(option.label)\(recommended)\(option.why.map { ": \($0)" } ?? "")")
        }
        if !spec.context.isEmpty { lines.append("    context: \(spec.context.map(\.label).joined(separator: ", "))") }
        if spec.status == .answered, let answer = spec.answer {
            var parts: [String] = []
            if let id = answer.option { parts.append("[\(id)]" + (spec.option(id).map { " \($0.label)" } ?? "")) }
            if let note = answer.note, !trimmed(note).isEmpty { parts.append("note: \"\(note.replacingOccurrences(of: "\n", with: "\\n"))\"") }
            let at = props["answer"]?["at"]?.string.map { " at \($0)" } ?? ""
            switch answer.by {
            case .agent(let tile)?: parts.append("by terminal \(tile)\(at)")
            case .user?: parts.append("by the user\(at)")
            case nil: if !at.isEmpty { parts.append(String(at.dropFirst())) }
            }
            lines.append("    answer: " + parts.joined(separator: " · "))
        }
        return lines
    }
}

extension Board {
    /// `object.create` props for a question: `QuestionSpec.creating`, then validated.
    public func questionToCreate(_ props: JSONValue, caller: ObjectID?) throws -> JSONValue {
        let props = QuestionSpec.creating(props, caller: caller)
        if let problem = QuestionSpec.problem(props, before: nil) { throw BoardError.invalidParams(problem) }
        return props
    }

    /// What an update of question `id` writes: the patch validated, `answer.at` and `answer.by`
    /// stamped when it answers the question, and, when it closes the question and the call gave no
    /// frame, the frame shrunk to the closed tile (`closedFrame`). Anything else passes through.
    public func questionUpdate(_ id: ObjectID, props patch: JSONValue?, frame: Frame?, caller: ObjectID?, now: Date = Date()) throws -> (props: JSONValue?, frame: Frame?) {
        let before = try object(id)
        guard before.type == .question, var patch else { return (patch, frame) }
        if let problem = QuestionSpec.problem(patch, before: before) { throw BoardError.invalidParams(problem) }
        guard QuestionSpec.status(of: before.props) == .open else { return (patch, frame) }
        let status = QuestionSpec.status(of: before.props.merging(patch))
        if status == .answered, var answer = before.props.merging(patch)["answer"]?.object {
            answer["at"] = .string(QuestionSpec.stamp(now))
            answer["by"] = try JSONValue.encode(Actor(caller: caller))
            patch = patch.merging(.object(["answer": .object(answer)]))
        }
        guard status != .open, frame == nil else { return (patch, frame) }
        return (patch, closedFrame(before, props: before.props.merging(patch)))
    }

    /// The user's answer from the tile: an option and/or a note, as `object.update` would write it.
    @discardableResult
    public func answerQuestion(_ id: ObjectID, option: String?, note: String?) throws -> CanvasObject {
        var answer: [String: JSONValue] = [:]
        if let option { answer["option"] = .string(option) }
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer["note"] = .string(note) }
        return try writeQuestion(id, .object(["status": .string(QuestionSpec.Status.answered.rawValue), "answer": .object(answer)]))
    }

    /// Archives (hides) or brings back a closed question.
    @discardableResult
    public func archiveQuestion(_ id: ObjectID, _ archived: Bool = true) throws -> CanvasObject {
        try writeQuestion(id, .object(["archived": archived ? .bool(true) : .null]))
    }

    /// Closes an open question without an answer (the user dismissed it).
    @discardableResult
    public func cancelQuestion(_ id: ObjectID) throws -> CanvasObject {
        try writeQuestion(id, .object(["status": .string(QuestionSpec.Status.cancelled.rawValue)]))
    }

    private func writeQuestion(_ id: ObjectID, _ patch: JSONValue) throws -> CanvasObject {
        let written = try questionUpdate(id, props: patch, frame: nil, caller: nil)
        return try update(id, frame: written.frame, props: written.props)
    }

    /// A closing question's frame: no taller than the closed tile (at its zoom), where it was.
    /// Nil when it already is.
    func closedFrame(_ before: CanvasObject, props: JSONValue) -> Frame? {
        let size = QuestionSpec.size(props)
        let height = Double(ObjectZoom.zoomed(CGSize(width: size.w, height: size.h), zoom: ObjectZoom.of(props)).height)
        guard height < before.frame.h else { return nil }
        return Frame(x: before.frame.x, y: before.frame.y, w: before.frame.w, h: height)
    }

    /// After a write of a question (`Board.write`): one just answered is handed to its asker's
    /// terminal, when that is a terminal on this board, as a mention of the question delivered
    /// with its next prompt (`handOff`), never typed into what the agent is writing.
    func questionWritten(before: CanvasObject, after: CanvasObject) {
        guard QuestionSpec.status(of: before.props) == .open, QuestionSpec.status(of: after.props) == .answered,
              let tile = after.props["asker"]?["tile"]?.string, objects[tile]?.type == .terminal else { return }
        _ = try? handOff([.object(after.id)], to: tile, from: nil, fromName: nil, header: "Your question \(after.id) was answered (easl ask):")
    }

    /// Open questions whose `expiresAt` is at or before `now` become `expired`, frames shrunk as
    /// a closing question's are, written by the app itself (no undo step). Returns their ids.
    @discardableResult
    public func expireQuestions(now: Date = Date()) -> [ObjectID] {
        let due = objects.values.filter { object in
            guard object.type == .question else { return false }
            let spec = QuestionSpec(object.props)
            return spec.status == .open && spec.expiresAt.map { $0 <= now } == true
        }.map(\.id).sorted()
        for id in due {
            guard let before = objects[id] else { continue }
            let patch: JSONValue = .object(["status": .string(QuestionSpec.Status.expired.rawValue)])
            _ = try? update(id, frame: closedFrame(before, props: before.props.merging(patch)), props: patch, actor: .system)
        }
        return due
    }

    /// Sets the board's expiry timer for its earliest open `expiresAt` (at most a day out, then
    /// again); a question already past it expires on the next turn. Called when the board opens
    /// and whenever a question changes.
    public func scheduleQuestionExpiry(now: Date = Date()) {
        questionExpiry?.cancel()
        questionExpiry = nil
        let next = objects.values.compactMap { object -> Date? in
            guard object.type == .question else { return nil }
            let spec = QuestionSpec(object.props)
            return spec.status == .open ? spec.expiresAt : nil
        }.min()
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.questionExpiry = nil
                self.expireQuestions()
                self.scheduleQuestionExpiry()
            }
        }
        questionExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(max(0, next.timeIntervalSince(now)), 24 * 3600), execute: work)
    }

    /// Questions still waiting on the user, oldest first (the board's open-asks count).
    public func waitingQuestions(at now: Date = Date()) -> [CanvasObject] {
        objects.values.filter { $0.type == .question && QuestionSpec($0.props).isWaiting(at: now) }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}

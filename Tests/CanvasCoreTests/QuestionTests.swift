import Foundation
import Testing
import CanvasCore

/// Question objects through the socket API (validation, transitions, find) and the board seams
/// the app uses (needs-you, expiry, archiving and loading, the answer's hand-off to an asking terminal).
@MainActor
final class QuestionTests {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("cv-\(UUID().uuidString.prefix(8))")
    let registry: BoardRegistry
    let router: ApiRouter
    let server: SocketServer
    let board: Board

    init() async throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("root"), withIntermediateDirectories: true)
        registry = BoardRegistry(store: BoardStore(directory: dir.appendingPathComponent("boards"), debounce: 60))
        board = try await registry.open(root: dir.appendingPathComponent("root"))
        let router = ApiRouter(registry: registry)
        self.router = router
        server = SocketServer(path: dir.appendingPathComponent("s").path) { request, connection in
            await router.handle(request, connection: connection)
        }
        try server.start()
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let client = try LineClient(path: dir.appendingPathComponent("s").path)
        let data = try JSONEncoder().encode(JSONValue.object(["id": "1", "method": .string(method), "params": params]))
        client.send(String(decoding: data, as: UTF8.self))
        return try await client.next()
    }

    func create(_ props: JSONValue, caller: ObjectID? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = ["type": "question", "props": props, "board": .string(board.id)]
        if let caller { params["caller"] = .string(caller) }
        return try await call("object.create", .object(params))
    }

    func update(_ id: ObjectID, _ props: JSONValue, caller: ObjectID? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = ["id": .string(id), "props": props]
        if let caller { params["caller"] = .string(caller) }
        return try await call("object.update", .object(params))
    }

    static let options: JSONValue = .array([
        .object(["id": "now", "label": "Ship now", "why": "the fix is small"]),
        .object(["id": "later", "label": "After #28"]),
    ])

    func question(_ extra: [String: JSONValue] = [:], caller: ObjectID? = nil) async throws -> CanvasObject {
        var props: [String: JSONValue] = ["question": "Ship the tile?", "options": Self.options, "recommended": "now", "asker": .object(["name": "cos", "host": "mini"])]
        for (key, value) in extra { props[key] = value }
        let reply = try await create(.object(props), caller: caller)
        let id = try #require(reply["result"]?["object"]?["id"]?.string, "\(reply)")
        return try board.object(id)
    }

    func message(_ reply: JSONValue) -> String? {
        reply["error"]?["code"] == .string("invalid_params") ? reply["error"]?["message"]?.string : "not invalid_params: \(reply)"
    }

    func isRefusal(_ reply: JSONValue) -> Bool {
        reply["error"]?["code"] == .string("invalid_params")
    }

    /// A question made through the board seams, so a synchronous test never yields to its timer.
    func ask(on board: Board, _ extra: [String: JSONValue] = [:]) throws -> ObjectID {
        var props: [String: JSONValue] = ["question": "Ship?", "options": Self.options, "asker": .object(["name": "cos"])]
        for (key, value) in extra { props[key] = value }
        return board.create(type: .question, props: try board.questionToCreate(.object(props), caller: nil)).id
    }

    // MARK: Create

    @Test func aCreatedQuestionIsOpenSizedByItsOptionsAndAskedByItsCaller() async throws {
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        let reply = try await create(.object(["question": "Which?", "options": Self.options]), caller: terminal)
        let object = try #require(reply["result"]?["object"])
        #expect(object["props"]?["status"] == "open")
        #expect(object["props"]?["asker"] == .object(["tile": .string(terminal)]), "the calling terminal asks")
        #expect(object["frame"]?["w"] == .number(QuestionSpec.width))
        #expect(object["frame"]?["h"] == .number(QuestionSpec.openBase + 2 * QuestionSpec.optionRow))
        #expect(reply["result"]?["warnings"] == nil, "every question prop is known")
        // Without a caller, someone has to be named.
        #expect(message(try await create(.object(["question": "Which?", "options": Self.options]))) == "a question needs props.asker, {name, host?}, when no terminal asks it (no caller)")
    }

    @Test func invalidQuestionsAreRefusedNamingTheRule() async throws {
        let base: [String: JSONValue] = ["question": "Q?", "options": Self.options, "asker": .object(["name": "cos"])]
        func refused(_ change: [String: JSONValue]) async throws -> String? {
            var props = base
            for (key, value) in change { props[key] = value }
            return message(try await create(.object(props)))
        }
        #expect(try await refused(["question": "  "]) == "a question needs props.question, a non-empty string")
        #expect(try await refused(["options": "a, b"]) == "a question needs props.options, an array of {id, label, why?}")
        #expect(try await refused(["options": .array([.object(["id": "a", "label": "A", "description": "x"])])]) == "options[0] has unknown key \"description\" (an option is {id, label, why?})")
        #expect(try await refused(["options": .array([.object(["label": "A"])])]) == "options[0] needs an id, a non-empty string")
        #expect(try await refused(["options": .array([.object(["id": "a", "label": " "])])]) == "options[0] needs a label, a non-empty string")
        #expect(try await refused(["options": .array([.object(["id": "a", "label": "A", "why": 3])])]) == "options[0].why must be a string")
        #expect(try await refused(["options": .array([.object(["id": "a", "label": "A"]), .object(["id": "a", "label": "B"])])]) == "option id \"a\" is used twice")
        #expect(try await refused(["recommended": "soon"]) == "recommended \"soon\" is not an option id (now, later)")
        #expect(try await refused(["options": .array([]), "recommended": "now"]) == "recommended \"now\" is not an option id (none)")
        #expect(try await refused(["context": .array([.object(["path": "a.swift", "url": "https://x"])])])
            == "context[0] must be {object: \"obj_…\"}, {url: \"…\"}, or {path: \"…\", lines?: {start, end}}")
        #expect(try await refused(["context": .array([.object(["path": "a.swift", "lines": .object(["start": 9, "end": 3])])])])?.hasPrefix("context[0] must be") == true)
        #expect(try await refused(["asker": .object(["host": "mini"])]) == "asker must be {tile: \"obj_…\"} or {name, host?}")
        #expect(try await refused(["status": "answered"]) == "a question is created open, not answered")
        #expect(try await refused(["status": "done"]) == "status must be open, answered, cancelled, or expired")
        #expect(try await refused(["expiresAt": "tomorrow"]) == "expiresAt must be an ISO 8601 date-time, e.g. 2026-10-05T17:00:00Z")
        #expect(try await refused(["answer": .object(["option": "now"])]) == "answer goes with status answered")
        #expect(try await refused(["archived": .bool(true)]) == "an open question can't be archived: answer or cancel it first")
        // What the chief of staff posts maps onto the props as it is.
        let cos: JSONValue = .object(["question": "Merge #31?", "options": .array([.object(["id": "y", "label": "Yes", "why": "green"])]), "recommended": "y", "asker": .object(["name": "cos"]),
                                      "context": .array([.object(["object": "obj_01ABC"]), .object(["url": "https://github.com"]), .object(["path": "a.swift", "lines": .object(["start": 3, "end": 9])])]),
                                      "expiresAt": "2030-01-01T00:00:00.5+02:00"])
        #expect(try await create(cos)["ok"] == .bool(true))
    }

    // MARK: Transitions

    @Test func answeringStampsTheAnswerShrinksTheTileAndThenOnlyArchiveChanges() async throws {
        let terminal = board.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        let open = try await question()
        #expect(message(try await update(open.id, .object(["status": "answered"]))) == "an answered question needs answer: {option, note?} or {note}")
        #expect(message(try await update(open.id, .object(["status": "answered", "answer": .object(["option": "soon"])]))) == "answer.option \"soon\" is not an option id (now, later)")
        #expect(message(try await update(open.id, .object(["status": "answered", "answer": .object(["note": "  "])]))) == "an answered question needs answer: {option, note?} or {note}")

        let before = Date().addingTimeInterval(-1)
        let reply = try await update(open.id, .object(["status": "answered", "answer": .object(["option": "later", "at": "1999-01-01T00:00:00Z"])]), caller: terminal)
        let answered = try board.object(open.id)
        #expect(reply["ok"] == .bool(true), "\(reply)")
        #expect(answered.props["answer"]?["by"] == .object(["kind": "agent", "tile": .string(terminal)]), "who answered is the caller")
        let at = try #require(answered.props["answer"]?["at"]?.string.flatMap(QuestionSpec.date))
        #expect(at >= before.addingTimeInterval(-1) && at <= Date(), "the answer's time is the server's, never the caller's")
        #expect(answered.frame.h == QuestionSpec.closedBase, "the tile collapses to the answer")
        #expect(answered.frame.x == open.frame.x && answered.frame.y == open.frame.y && answered.frame.w == open.frame.w)

        #expect(isRefusal(try await update(open.id, .object(["status": "open"]))))
        #expect(isRefusal(try await update(open.id, .object(["question": "Something else?"]))))
        let final = QuestionSpec(try board.object(open.id).props)
        #expect(final.status == .answered && final.question == "Ship the tile?", "an answered question's content is final")
        #expect(message(try await update(open.id, .object(["archived": "yes"]))) == "archived must be true or false")
        #expect(try await update(open.id, .object(["status": "answered", "archived": .bool(true)]))["ok"] == .bool(true), "a value it already has is no change")
        #expect(QuestionSpec(try board.object(open.id).props).archived)
    }

    @Test func cancellingClosesWithoutAnAnswer() async throws {
        let open = try await question()
        #expect(message(try await update(open.id, .object(["status": "cancelled", "answer": .object(["note": "x"])]))) == "answer goes with status answered")
        #expect(try await update(open.id, .object(["status": "cancelled"]))["ok"] == .bool(true))
        #expect(isRefusal(try await update(open.id, .object(["status": "expired"]))))
        #expect(QuestionSpec(try board.object(open.id).props).status == .cancelled, "a cancelled question stays cancelled")
        #expect(try await update(open.id, .object(["archived": .bool(true)]))["ok"] == .bool(true), "a cancelled question can be archived")
    }

    @Test func keepAndArchiveAfterAreKnownAndAClosedQuestionStillTakesThem() async throws {
        let created = try await create(.object(["question": "Keep?", "options": Self.options, "asker": .object(["name": "cos"]), "keep": .bool(true), "archiveAfter": 86400]))
        #expect(created["ok"] == .bool(true), "\(created)")
        #expect(created["result"]?["warnings"] == nil, "both are question props")
        let id = try #require(created["result"]?["object"]?["id"]?.string)
        for invalid: [String: JSONValue] in [["keep": "yes"], ["archiveAfter": -1], ["archiveAfter": .number(86400.5)], ["archiveAfter": "10"]] {
            #expect(isRefusal(try await update(id, .object(invalid))), "\(invalid)")
        }
        #expect(try await update(id, .object(["status": "cancelled"]))["ok"] == .bool(true))
        #expect(try await update(id, .object(["keep": .null, "archiveAfter": 0]))["ok"] == .bool(true), "a closed question takes both")
        let closed = QuestionSpec(try board.object(id).props)
        #expect(!closed.keep && closed.archiveAfter == 0)
    }

    // MARK: Find

    @Test func findListsQuestionsByStatusOldestFirst() async throws {
        let first = try await question()
        let second = try await question()
        let answered = try await question()
        _ = try await update(answered.id, .object(["status": "answered", "answer": .object(["option": "now"])]))
        _ = board.create(type: .note, props: .object(["markdown": "not a question"]))
        func ids(_ params: JSONValue) async throws -> [String]? {
            try await call("object.find", params)["result"]?["objects"]?.array?.compactMap { $0["id"]?.string }
        }
        #expect(try await ids(.object(["type": "question", "status": "open"])) == [first.id, second.id])
        #expect(try await ids(.object(["type": "question"])) == [first.id, second.id, answered.id])
        #expect(message(try await call("object.find", .object(["key": "a", "status": "open"]))) == "object.find takes status only with type (e.g. type question, status open)")
        #expect(message(try await call("object.find", .object(["status": "open"]))) == "object.find takes one of key, keyPrefix, or type")
        #expect(message(try await call("object.find", .object(["type": "question", "keyPrefix": "a"]))) == "object.find takes one of key, keyPrefix, or type")
        #expect(message(try await call("object.find", .object(["type": "questions"]))) == "unknown object type")
    }

    // MARK: Board seams

    @Test func openQuestionsNeedTheUserAfterBlockedAgentsUntilClosedOrPastExpiry() async throws {
        let blocked = board.create(type: .terminal, props: .object(["cwd": .string(dir.path)]), frame: Frame(x: 0, y: 900, w: 100, h: 100)).id
        try board.reportLifecycle(tile: blocked, kind: "omp", state: .blocked, message: "approve Edit?", seq: 1, source: "canvas-omp")
        let marked = board.create(type: .note, props: .object(["markdown": "look"]), frame: Frame(x: 0, y: 0, w: 100, h: 100)).id
        try board.raiseAttention(marked, message: nil, caller: nil)
        let open = try await question()
        let soon = try await question(["expiresAt": .string(QuestionSpec.stamp(Date().addingTimeInterval(3600)))])
        let answered = try await question()
        try board.answerQuestion(answered.id, option: "now", note: nil)

        let items = NeedsYouItem.all(board.objects, attention: board.attention)
        #expect(items.map(\.reason) == [.blocked, .question, .question, .marked])
        #expect(Set(items.filter { $0.reason == .question }.map(\.id)) == [open.id, soon.id])
        #expect(items.first { $0.id == open.id }?.message == "Ship the tile?")
        #expect(!NeedsYouItem.all(board.objects, attention: board.attention, now: Date().addingTimeInterval(7200)).contains { $0.id == soon.id },
                "past its expiry it no longer waits, even before the board marks it")
        #expect(board.waitingQuestions().map(\.id).sorted() == [open.id, soon.id].sorted())
    }

    /// Synchronous on the main actor throughout, so the board's own expiry timer (which would
    /// expire the past-due questions on the next turn) never runs in between.
    @Test func expiryClosesOpenQuestionsPastTheirTimeWithoutAnUndoStep() throws {
        func ask(expiring expiresAt: String) throws -> ObjectID {
            let props: JSONValue = .object(["question": "Ship?", "options": Self.options, "asker": .object(["name": "cos"]), "expiresAt": .string(expiresAt)])
            return board.create(type: .question, props: try board.questionToCreate(props, caller: nil)).id
        }
        let later = try ask(expiring: "2099-01-01T00:00:00Z")
        let due = try ask(expiring: "2021-01-01T00:00:00Z")
        let answered = try ask(expiring: "2021-01-01T00:00:00Z")
        try board.answerQuestion(answered, option: "now", note: "done")
        var updates: [ObjectID] = []
        board.onEvent = { event in if case .objectUpdated(let object) = event { updates.append(object.id) } }

        #expect(board.expireQuestions() == [due])
        let expired = try board.object(due)
        #expect(QuestionSpec(expired.props).status == .expired)
        #expect(expired.frame.h == QuestionSpec.closedBase)
        #expect(QuestionSpec(try board.object(later).props).status == .open)
        #expect(QuestionSpec(try board.object(answered).props).status == .answered, "only open questions expire")
        #expect(updates == [due], "announced like any change")
        board.undo()
        #expect(QuestionSpec(try board.object(answered).props).status == .open, "⌘Z undoes the user's answer, the last step")
        #expect(QuestionSpec(try board.object(due).props).status == .expired, "an expiry is no undo step")
    }

    /// Created open with a future `expiresAt`; nothing but the board's own timer closes it. (Under
    /// a loaded full suite the create alone may take past a second, so no "still open" check.)
    @Test func expiryRunsByItselfOnceTheTimeHasPassed() async throws {
        let due = try await question(["expiresAt": .string(QuestionSpec.stamp(Date().addingTimeInterval(1)))])
        let deadline = Date().addingTimeInterval(15)
        while QuestionSpec(try board.object(due.id).props).status == .open, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(QuestionSpec(try board.object(due.id).props).status == .expired, "the board's timer expired it")
    }

    /// Synchronous on the main actor throughout, so the board's own timer never runs in between.
    @Test func aClosedQuestionArchivesOnceItsDelayHasPassedUnlessKept() throws {
        let delayed = try ask(on: board, ["archiveAfter": 30])
        let kept = try ask(on: board, ["archiveAfter": 30, "keep": .bool(true)])
        let open = try ask(on: board, ["archiveAfter": 0])
        try board.answerQuestion(kept, option: "later", note: nil)
        let answered = try board.answerQuestion(delayed, option: "now", note: "done")
        let steps = board.history.undoSteps.count
        var updates: [ObjectID] = []
        board.onEvent = { event in if case .objectUpdated(let object) = event { updates.append(object.id) } }

        #expect(board.archiveQuestions(now: answered.updatedAt.addingTimeInterval(29)) == [])
        #expect(board.archiveQuestions(now: answered.updatedAt.addingTimeInterval(30)) == [delayed])
        let archived = try board.object(delayed)
        #expect(archived.props == answered.props.merging(.object(["archived": .bool(true)])), "status and answer kept")
        #expect(archived.frame == answered.frame)
        #expect(updates == [delayed], "announced like any change")
        #expect(board.history.undoSteps.count == steps, "an archive is no undo step")
        #expect(board.archiveQuestions(now: .distantFuture) == [], "neither a kept nor an open question archives")
        #expect(!QuestionSpec(try board.object(open).props).archived)

        let unkept = try board.update(kept, props: .object(["keep": .null]))
        #expect(board.archiveQuestions(now: unkept.updatedAt.addingTimeInterval(29)) == [], "its delay runs from that write")
        #expect(board.archiveQuestions(now: unkept.updatedAt.addingTimeInterval(30)) == [kept])
        #expect(board.undo())
        #expect(QuestionSpec(try board.object(kept).props).keep, "⌘Z takes back the user's last change")
        #expect(QuestionSpec(try board.object(delayed).props).archived, "never an archive the app made")
    }

    @Test func aHostsDefaultDelayArchivesOnlyQuestionsThatNameNoDelayOfTheirOwn() async throws {
        let root = dir.appendingPathComponent("thirty")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BoardStore(directory: dir.appendingPathComponent("thirty-boards"), debounce: 60)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let stored = Board(id: BoardStore.boardID(for: root), root: root)
        let existing = try ask(on: stored)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stored.snapshot).write(to: store.url(for: stored.id))
        let configured = BoardRegistry(store: store)
        let hosted = try await configured.open(root: root)
        configured.defaultQuestionArchiveAfter = 30
        #expect(throws: BoardError.self, "a caller's delay is never replaced") {
            try self.ask(on: hosted, ["archiveAfter": -1])
        }
        let own = try ask(on: hosted, ["archiveAfter": 5]), historical = try ask(on: hosted, ["archiveAfter": 10])
        let kept = try ask(on: hosted, ["keep": .bool(true)]), cleared = try ask(on: hosted, ["archiveAfter": .null])
        let unnamed = try ask(on: hosted)
        for id in [own, existing, historical, kept, cleared, unnamed] {
            try hosted.answerQuestion(id, option: "now", note: nil)
        }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = hosted.snapshot
        for index in snapshot.objects.indices { snapshot.objects[index].updatedAt = at }
        let clocked = Board(snapshot: snapshot)

        #expect(clocked.archiveQuestions(now: at.addingTimeInterval(4.999)) == [])
        #expect(clocked.archiveQuestions(now: at.addingTimeInterval(5)) == [own], "its own delay")
        #expect(clocked.archiveQuestions(now: at.addingTimeInterval(9.999)) == [])
        #expect(clocked.archiveQuestions(now: at.addingTimeInterval(10)) == [existing, historical].sorted(), "existing implicit 10 and explicit 10, not the host's 30")
        #expect(clocked.archiveQuestions(now: at.addingTimeInterval(29.999)) == [])
        #expect(clocked.archiveQuestions(now: at.addingTimeInterval(30)) == [cleared, unnamed].sorted(), "none or null: the host's 30")
        #expect(clocked.archiveQuestions(now: .distantFuture) == [], "keep still exempts a question")
    }

    /// The question once the board's own timer archived it, or as it is after 15 seconds.
    func archivedByTheTimer(_ id: ObjectID) async throws -> QuestionSpec {
        let deadline = Date().addingTimeInterval(15)
        while !QuestionSpec(try board.object(id).props).archived, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        return QuestionSpec(try board.object(id).props)
    }

    @Test func theTimerExpiresAQuestionAndThenArchivesIt() async throws {
        let due = try await question(["expiresAt": "2021-01-01T00:00:00Z", "archiveAfter": 0])
        let done = try await archivedByTheTimer(due.id)
        #expect(done.archived && done.status == .expired)
    }

    /// A kept question has no deadline, so the timer runs for it only if dropping `keep` sets it again.
    @Test func droppingKeepFromAClosedQuestionLetsTheTimerArchiveIt() async throws {
        let kept = try await question(["keep": .bool(true), "archiveAfter": 0])
        #expect(try await update(kept.id, .object(["status": "answered", "answer": .object(["option": "now"])]))["ok"] == .bool(true))
        #expect(try await update(kept.id, .object(["keep": .null]))["ok"] == .bool(true))
        let done = try await archivedByTheTimer(kept.id)
        #expect(done.archived && done.status == .answered && done.answer?.option == "now")
    }

    @Test func aFailedBatchThatDroppedKeepLeavesTheQuestionUnarchived() async throws {
        let kept = try await question(["keep": .bool(true), "archiveAfter": 0])
        #expect(try await update(kept.id, .object(["status": "answered", "answer": .object(["option": "now"])]))["ok"] == .bool(true))
        let answered = try board.object(kept.id)
        let reply = try await call("object.batch", .object(["board": .string(board.id), "ops": .array([
            .object(["method": "object.update", "params": .object(["id": .string(kept.id), "props": .object(["keep": .null])])]),
            .object(["method": "object.update", "params": .object(["id": .string(kept.id), "rev": .number(Double(answered.rev)), "props": .object(["archiveAfter": 1])])]),
        ])]))
        #expect(reply["error"]?["code"] == "conflict", "\(reply)")
        try await Task.sleep(for: .milliseconds(300))
        let spec = QuestionSpec(try board.object(kept.id).props)
        #expect(spec.keep && !spec.archived, "the reverted change left no deadline behind")
    }

    @Test func loadingArchivesOnlyStoredQuestionsPastTheirDelayAndChangesNothingElse() async throws {
        let root = dir.appendingPathComponent("stored")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BoardStore(directory: dir.appendingPathComponent("stored-boards"), debounce: 60)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let stored = Board(id: BoardStore.boardID(for: root), root: root)
        let due = try ask(on: stored), kept = try ask(on: stored, ["keep": .bool(true)])
        let recent = try ask(on: stored, ["archiveAfter": 60]), open = try ask(on: stored)
        try stored.answerQuestion(due, option: "now", note: nil)
        try stored.cancelQuestion(kept)
        try stored.answerQuestion(recent, option: "later", note: nil)
        var snapshot = stored.snapshot
        for index in snapshot.objects.indices {
            switch snapshot.objects[index].id {
            case due, kept, open: snapshot.objects[index].updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            case recent: snapshot.objects[index].updatedAt = Date().addingTimeInterval(-50)
            default: break
            }
        }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: store.url(for: stored.id))
        var expected = try decoder.decode(BoardSnapshot.self, from: Data(contentsOf: store.url(for: stored.id)))
        for index in expected.objects.indices where expected.objects[index].id == due {
            expected.objects[index].props = expected.objects[index].props.merging(.object(["archived": .bool(true)]))
        }

        let loaded = try await store.load(root: root)
        #expect(QuestionSpec(try loaded.object(due).props).archived)
        for id in [kept, recent, open] { #expect(!QuestionSpec(try loaded.object(id).props).archived, "\(id)") }
        #expect(loaded.revision == expected.revision)
        for object in expected.objects {
            let live = try loaded.object(object.id)
            #expect(live.rev == object.rev && live.updatedAt == object.updatedAt, "\(object.id)")
        }
        #expect(!loaded.history.canUndo)
        let saved = try decoder.decode(BoardSnapshot.self, from: Data(contentsOf: store.url(for: stored.id)))
        #expect(saved.objects == expected.objects && saved.revision == expected.revision, "only the archive is written")

        let sentinel = Date(timeIntervalSince1970: 1_234_567_890)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: store.url(for: stored.id).path)
        let again = try await store.load(root: root)
        #expect(try store.url(for: stored.id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == sentinel, "a second load writes nothing")
        #expect(again.archiveQuestions(now: Date().addingTimeInterval(15)) == [recent], "what was left of its delay, not a fresh one")
    }

    @Test func theAnswerReachesTheAskingTerminalOnItsNextPrompt() async throws {
        let asker = board.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        let other = board.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        let asked = try await question(["asker": .null, "context": .array([.object(["path": "src/a.ts", "lines": .object(["start": 3, "end": 5])])])], caller: asker)
        #expect(await board.drain(peek: true, caller: asker).context.isEmpty, "nothing until it is answered")
        try board.answerQuestion(asked.id, option: "later", note: "after the perf PR")

        let drained = await board.drain(peek: true, caller: asker)
        #expect(drained.mentions.count == 1)
        #expect(drained.context.contains("Your question \(asked.id) was answered (easl ask):"), "\(drained.context)")
        #expect(drained.context.contains("[1] question \(asked.id) \"Ship the tile?\""), "\(drained.context)")
        #expect(drained.context.contains("    asked by terminal \(asker) · answered\n"))
        #expect(drained.context.contains("    [now] Ship now (recommended): the fix is small\n    [later] After #28\n"))
        #expect(drained.context.contains("    context: src/a.ts:3-5\n"))
        #expect(drained.context.contains("    answer: [later] After #28 · note: \"after the perf PR\" · by the user at "))
        #expect(await board.drain(peek: true, caller: other).context.isEmpty, "only the asker gets it")
        #expect(board.tray.isEmpty, "never in the user's tray")
    }

    @Test func anUndoneAnswerIsTakenBackAndARedoHandsItOffAgain() async throws {
        let asker = board.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        let asked = try await question(["asker": .null], caller: asker)
        let header = "Your question \(asked.id) was answered (easl ask):"

        // ⌘Z before the asker's next prompt: the answer is never delivered.
        try board.answerQuestion(asked.id, option: "later", note: nil)
        #expect(board.undo())
        #expect(QuestionSpec(try board.object(asked.id).props).status == .open)
        #expect(board.handoffs[asker] == nil, "the undone answer's hand-off is withdrawn")
        #expect(await board.drain(peek: false, caller: asker).context.isEmpty)

        // Redo brings the answer back, and with it the hand-off.
        #expect(board.redo())
        let redone = await board.drain(peek: false, caller: asker)
        #expect(redone.mentions.count == 1)
        #expect(redone.context.contains(header), "\(redone.context)")
        #expect(redone.context.contains("    answer: [later] After #28 · by the user at "), "\(redone.context)")

        // Delivered, undone, redone: the restored answer is handed off again.
        #expect(board.undo())
        #expect(await board.drain(peek: true, caller: asker).context.isEmpty)
        #expect(board.redo())
        #expect(await board.drain(peek: true, caller: asker).context.contains(header))
    }

    @Test func aFailedBatchLeavesTheAnswersHandOffAsItWas() async throws {
        let asker = board.create(type: .terminal, props: .object(["cwd": .string(dir.path)])).id
        let asked = try await question(["asker": .null], caller: asker)
        // The answer applies, then the stale rev fails the batch and reverts it.
        let reply = try await call("object.batch", .object(["board": .string(board.id), "ops": .array([
            .object(["method": "object.update", "params": .object(["id": .string(asked.id), "props": .object(["status": "answered", "answer": .object(["option": "now"])])])]),
            .object(["method": "object.update", "params": .object(["id": .string(asked.id), "rev": .number(Double(asked.rev)), "props": .object(["archived": .bool(true)])])]),
        ])]))
        #expect(reply["error"]?["code"] == "conflict", "\(reply)")
        #expect(QuestionSpec(try board.object(asked.id).props).status == .open)
        #expect(board.handoffs[asker] == nil, "the reverted answer's hand-off is withdrawn")
        #expect(await board.drain(peek: true, caller: asker).context.isEmpty, "no answer to deliver")

        // Answered for real, then a batch that deletes the question fails: the answer still waits.
        try board.answerQuestion(asked.id, option: "now", note: nil)
        let failed = try await call("object.batch", .object(["board": .string(board.id), "ops": .array([
            .object(["method": "object.delete", "params": .object(["id": .string(asked.id)])]),
            .object(["method": "object.update", "params": .object(["id": "obj_missing", "props": .object([:])])]),
        ])]))
        #expect(failed["error"]?["code"] == "not_found", "\(failed)")
        let drained = await board.drain(peek: true, caller: asker)
        #expect(drained.mentions.count == 1)
        #expect(drained.context.contains("Your question \(asked.id) was answered (easl ask):"), "\(drained.context)")
    }

    @Test func aWorktreeAgentsContextPathsMeanItsOwnCheckout() async throws {
        let repo = try await TempRepo()
        try await repo.write("src/a.ts", "one\n")
        try await repo.commit("init")
        let worktree = URL(fileURLWithPath: repo.root.path + "-wt/fees")
        try await repo.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        let repoBoard = try await registry.open(root: repo.root)
        let agent = repoBoard.create(type: .terminal, props: .object(["cwd": .string(worktree.appendingPathComponent("src").path), "command": .array([])])).id
        let home = repoBoard.create(type: .terminal, props: .object(["cwd": .string(repo.root.path), "command": .array([])])).id
        func ask(_ context: JSONValue, caller: ObjectID) async throws -> CanvasObject {
            let reply = try await call("object.create", .object(["type": "question", "board": .string(repoBoard.id), "caller": .string(caller),
                                                                 "props": .object(["question": "Review this change?", "options": Self.options, "context": context])]))
            return try repoBoard.object(try #require(reply["result"]?["object"]?["id"]?.string, "\(reply)"))
        }
        let asked = try await ask(.array([
            .object(["path": "src/a.ts", "lines": .object(["start": 3, "end": 5])]), .object(["path": "/etc/hosts"]), .object(["url": "https://example.com"]),
        ]), caller: agent)
        #expect(asked.props["context"] == .array([
            .object(["path": .string(worktree.appendingPathComponent("src/a.ts").path), "lines": .object(["start": 3, "end": 5])]),
            .object(["path": "/etc/hosts"]), .object(["url": "https://example.com"]),
        ]), "a relative path is the asker's checkout's file, stored absolute")
        let inWorktree = worktree.appendingPathComponent("src/b.ts").path
        let updated = try await call("object.update", .object(["id": .string(asked.id), "caller": .string(agent),
                                                               "props": .object(["context": .array([.object(["path": "src/b.ts", "lines": .object(["start": 2, "end": 2])])])])]))
        #expect(updated["result"]?["object"]?["props"]?["context"] == .array([.object(["path": .string(inWorktree), "lines": .object(["start": 2, "end": 2])])]), "\(updated)")
        // From the board's own checkout a relative path stays board-relative.
        #expect(try await ask(.array([.object(["path": "src/a.ts"])]), caller: home).props["context"] == .array([.object(["path": "src/a.ts"])]))

        try repoBoard.answerQuestion(asked.id, option: "now", note: nil)
        let drained = await repoBoard.drain(peek: true, caller: agent)
        #expect(drained.context.contains("    context: \(inWorktree):2\n"), "the mention names the worktree's file: \(drained.context)")
    }
}

extension BoardMirrorTests {
    @Test func aViewerLeavesArchivingTheHostsQuestionsToTheHost() async throws {
        let props = try host.questionToCreate(.object(["question": "Ship?", "options": .array([.object(["id": "y", "label": "Yes"])]),
                                                       "asker": .object(["name": "cos"]), "archiveAfter": 3600]), caller: nil)
        let asked = host.create(type: .question, props: props).id
        let answered = try host.answerQuestion(asked, option: "y", note: nil)
        let (mirror, view) = try await mirror()
        defer { mirror.close() }
        try await eventually { view.objects[asked]?.props["status"] == "answered" }
        let due = answered.updatedAt.addingTimeInterval(3600)
        #expect(view.archiveQuestions(now: due) == [])
        #expect(view.objects[asked]?.props["archived"] == nil, "a viewer changes nothing on its own")
        #expect(host.archiveQuestions(now: due) == [asked])
        try await eventually { view.objects[asked]?.props["archived"] == .bool(true) }
    }
}

import Foundation
import Testing
@testable import CanvasCore

@Suite @MainActor struct BoardSaveTests {
    @Test func inFlightEditsCoalesceAndCheckedSaveWaitsForNewestState() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = SaveWrites(blocking: [1])
        defer { writes.release.signal() }
        let store = store(directory, writes: writes)
        let board = try await store.load(root: directory.appendingPathComponent("root"), id: "brd_save")
        let note = board.create(type: .note, props: .object(["markdown": "first"]))
        let saving = Task { try await store.saveChecked(board) }
        #expect(await writes.waitUntilBlocked())

        _ = try board.update(note.id, props: .object(["markdown": "intermediate"]))
        _ = try board.update(note.id, props: .object(["markdown": "newest"]))
        writes.release.signal()
        try await store.saveChecked(board)
        try await saving.value

        let saved = try #require(BoardFile.read(store.url(for: board.id)))
        #expect(saved.objects.first { $0.id == note.id }?.props["markdown"] == "newest")
        #expect(writes.snapshots.map { $0.objects.first { $0.id == note.id }?.props["markdown"] } == ["first", "newest"])
    }

    @Test func checkedSaveIncludesChangesThatDoNotAdvanceBoardRevision() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = SaveWrites(blocking: [1])
        defer { writes.release.signal() }
        let store = store(directory, writes: writes)
        let board = Board(id: "brd_target", root: directory.appendingPathComponent("root"))
        let target = board.create(type: .terminal, props: .object([:]))
        let newest = board.create(type: .terminal, props: .object([:]))
        let saving = Task { try await store.saveChecked(board) }
        #expect(await writes.waitUntilBlocked())

        let revision = board.revision
        board.promptTarget.choose(target.id)
        #expect(board.revision == revision)
        store.beginFlush([board]) { board.promptTarget.choose(newest.id) }
        writes.release.signal()
        try await saving.value

        let saved = try #require(BoardFile.read(store.url(for: board.id)))
        #expect(saved.promptTarget == PromptTarget.State(focusOrder: [target.id, newest.id], chosen: newest.id))
    }

    @Test func flushIncludesInFlightAndEveryPendingBoardAndLaterEdits() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = SaveWrites(blocking: [1])
        defer { writes.release.signal() }
        let store = store(directory, writes: writes)
        let first = try await store.load(root: directory.appendingPathComponent("one"), id: "brd_one")
        let second = try await store.load(root: directory.appendingPathComponent("two"), id: "brd_two")
        let firstNote = first.create(type: .note, props: .object(["markdown": "one"]))
        let secondNote = second.create(type: .note, props: .object(["markdown": "two"]))
        let saving = Task { try await store.saveChecked(first) }
        #expect(await writes.waitUntilBlocked())

        await withCheckedContinuation { continuation in
            store.beginFlush([first, second]) { continuation.resume() }
            do {
                _ = try first.update(firstNote.id, props: .object(["markdown": "one newest"]))
                _ = try second.update(secondNote.id, props: .object(["markdown": "two newest"]))
            } catch {
                Issue.record(error)
            }
            writes.release.signal()
        }
        try await saving.value
        let savedFirst = try #require(BoardFile.read(store.url(for: first.id)))
        let savedSecond = try #require(BoardFile.read(store.url(for: second.id)))
        #expect(savedFirst.objects.first { $0.id == firstNote.id }?.props["markdown"] == "one newest")
        #expect(savedSecond.objects.first { $0.id == secondNote.id }?.props["markdown"] == "two newest")
    }

    @Test func failedCheckedWritePreservesPreviousFileAndRetryPersistsLatest() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = SaveWrites(blocking: [2], failing: [2])
        defer { writes.release.signal() }
        let store = store(directory, writes: writes)
        let board = try await store.load(root: directory.appendingPathComponent("root"), id: "brd_failure")
        let note = board.create(type: .note, props: .object(["markdown": "durable"]))
        try await store.saveChecked(board)
        let previous = try Data(contentsOf: store.url(for: board.id))
        _ = try board.update(note.id, props: .object(["markdown": "retry me"]))
        let saving = Task { try await store.saveChecked(board) }
        #expect(await writes.waitUntilBlocked())
        #expect(try Data(contentsOf: store.url(for: board.id)) == previous)
        writes.release.signal()
        do {
            try await saving.value
            Issue.record("a checked save swallowed its write failure")
        } catch is SaveWrites.Failure {}
        #expect(try Data(contentsOf: store.url(for: board.id)) == previous)
        #expect(!board.isClosed)

        try await store.saveChecked(board)
        let saved = try #require(BoardFile.read(store.url(for: board.id)))
        #expect(saved.objects.first { $0.id == note.id }?.props["markdown"] == "retry me")
    }

    @Test func closeWaitsForInFlightSaveAndKeepsBoardOpenOnWriteFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = SaveWrites(blocking: [2], failing: [2])
        defer { writes.release.signal() }
        let store = store(directory, writes: writes)
        let registry = BoardRegistry(store: store)
        let board = try await registry.open(root: directory.appendingPathComponent("root"))
        let note = board.create(type: .note, props: .object(["markdown": "previous complete state"]))
        try await store.saveChecked(board)
        _ = try board.update(note.id, props: .object(["markdown": "latest state before close"]))
        var closed = false
        let closing = Task {
            defer { closed = true }
            try await registry.close(board.id)
        }
        #expect(await writes.waitUntilBlocked())
        #expect(!closed)
        #expect(registry.boards[board.id] === board)
        writes.release.signal()
        do {
            try await closing.value
            Issue.record("close accepted a failed in-flight save")
        } catch let failure as ApiRouter.Failure {
            #expect(failure.code == "unavailable")
            #expect(failure.message.hasPrefix("cannot save board"))
        }
        #expect(!board.isClosed)
        #expect(registry.boards[board.id] === board)
        try await registry.close(board.id)
        #expect(board.isClosed)
        #expect(registry.boards[board.id] == nil)
        let reopened = try await registry.open(root: board.root)
        #expect(try reopened.object(note.id).props["markdown"] == "latest state before close")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("easl-save-\(UUID().uuidString)", isDirectory: true)
    }

    private func store(_ directory: URL, writes: SaveWrites) -> BoardStore {
        BoardStore(directory: directory, debounce: 60, write: { try writes.write($0, to: $1, options: $2) })
    }
}

private final class SaveWrites: @unchecked Sendable {
    struct Failure: Error {}
    let release = DispatchSemaphore(value: 0)
    private let entered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let blocking: Set<Int>
    private let failing: Set<Int>
    private var recorded: [BoardSnapshot] = []

    init(blocking: Set<Int>, failing: Set<Int> = []) {
        self.blocking = blocking
        self.failing = failing
    }

    var snapshots: [BoardSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        #expect(!Thread.isMainThread, "disk writes must not run on the main thread")
        let snapshot = try BoardStore.decoder.decode(BoardSnapshot.self, from: data)
        lock.lock()
        recorded.append(snapshot)
        let number = recorded.count
        lock.unlock()
        if blocking.contains(number) {
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw Failure() }
        }
        if failing.contains(number) { throw Failure() }
        try data.write(to: url, options: options)
    }

    func waitUntilBlocked() async -> Bool {
        await Task.detached { self.entered.wait(timeout: .now() + 5) == .success }.value
    }
}

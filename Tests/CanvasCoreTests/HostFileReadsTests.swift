import Darwin
import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct HostFileReadsTests {
    private func start(_ requests: [HostFileRequest], files: HostFiles) -> [Task<HostFile, Error>] {
        requests.map { request in Task { try await files.read(request) } }
    }

    private func values(_ tasks: [Task<HostFile, Error>]) async throws -> [HostFile] {
        defer { for task in tasks { task.cancel() } }
        var files: [HostFile] = []
        for task in tasks { files.append(try await task.value) }
        return files
    }

    private func startBatch(_ paths: [String], fixture: HostFileFixture, files: HostFiles) -> [Task<HostFile, Error>] {
        let reads = HostFileReads()
        return paths.map { path in
            Task { try await reads.read(fixture.request(path), payload: fixture.wireRequest(path), files: files, priority: .visible) }
        }
    }

    private func waitForAttempt(_ fixture: HostFileFixture) async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(20)
        while fixture.attempts.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(fixture.attempts.first)
    }

    @Test func cleanupReadsDoNotWaitForTheMainActorOrBatchCoordinator() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("cleanup.png", Data([0, 255, 128, 10]))
        let files = try fixture.reader(batching: true).cleanup
        let request = fixture.request("cleanup.png")
        let finished = DispatchSemaphore(value: 0)
        let task = Task.detached {
            defer { finished.signal() }
            return try await files.read(request)
        }
        defer { task.cancel() }
        let completed = await MainActor.run { finished.wait(timeout: .now() + 10) }
        #expect(completed == .success)
        #expect(try await task.value.data == Data([0, 255, 128, 10]))
    }

    @Test func concurrentReadsKeepDistinctBinaryBytesAndCallerOrder() async throws {
        let fixture = try HostFileFixture()
        let contents = (0..<70).map { Data([UInt8($0), 0, 255, UInt8(69 - $0), 128, 10]) }
        for (index, bytes) in contents.enumerated() { try fixture.write("binary-\(index).png", bytes) }
        let files = try fixture.reader(batching: true)
        let requests = (0..<70).map { fixture.request("binary-\($0).png") }
        let loaded = try await values(start(requests, files: files))
        #expect(loaded.map(\.data) == contents)
        #expect(loaded.map { URL(fileURLWithPath: $0.path ?? "").lastPathComponent } == (0..<70).map { "binary-\($0).png" })
        #expect(loaded.map(\.size) == Array(repeating: 6, count: 70))
    }

    @Test func missingAndRefusedMembersDoNotPoisonOtherReaders() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("first.png", Data([0, 255, 1]))
        try fixture.write("last.png", Data([128, 0, 2, 10]))
        let files = try fixture.reader(batching: true)
        let source = HostFileRequest.Source.directory(fixture.root.path)
        let requests = [fixture.request("first.png"), fixture.request("missing.png"),
                        HostFileRequest(source: source, policy: .boardImage("../outside.png")), fixture.request("last.png")]
        let tasks = start(requests, files: files)
        defer { for task in tasks { task.cancel() } }
        #expect(try await tasks[0].value.data == Data([0, 255, 1]))
        await #expect(throws: HostFileError.notFound(commit: nil)) { try await tasks[1].value }
        await #expect(throws: HostFileError.refused) { try await tasks[2].value }
        #expect(try await tasks[3].value.data == Data([128, 0, 2, 10]))
    }

    @Test func batchBudgetDefersLargeMembersToIndependentReads() async throws {
        let fixture = try HostFileFixture()
        let first = Data(repeating: 17, count: 3 * 1024 * 1024)
        let second = Data(repeating: 203, count: 3 * 1024 * 1024)
        let large = Data(repeating: 128, count: 4 * 1024 * 1024 + 19)
        try fixture.write("first.png", first)
        try fixture.write("second.png", second)
        try fixture.write("large.png", large)
        let files = try fixture.reader(batching: true)
        let initial = try await files.readBatch([fixture.wireRequest("first.png"), fixture.wireRequest("second.png")], priority: .visible)
        guard case .file(let initialFile) = initial[0], case .deferred = initial[1] else {
            Issue.record("the batch did not defer the member beyond its byte budget")
            return
        }
        #expect(initialFile.data == first)
        let source = HostFileRequest.Source.directory(fixture.root.path)
        let requests = [fixture.request("first.png"), fixture.request("second.png"),
                        HostFileRequest(source: source, policy: .pageImage(relative: "large.png", absolute: nil, temps: [])),
                        HostFileRequest(source: source, policy: .boardImage("large.png"))]
        let tasks = start(requests, files: files)
        defer { for task in tasks { task.cancel() } }
        #expect(try await tasks[0].value.data == first)
        #expect(try await tasks[1].value.data == second)
        #expect(try await tasks[2].value.data == large)
        await #expect(throws: HostFileError.tooLarge(limit: 4 * 1024 * 1024)) { try await tasks[3].value }
    }

    @Test func cancellingOneMemberKeepsTheSharedHostCommandAlive() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("cancel.png", Data([0, 1, 2]))
        try fixture.write("keep.png", Data([255, 128, 0, 10]))
        let release = fixture.directory.appendingPathComponent("release")
        let files = try fixture.recordingReader(body: """
        while [ ! -f \(RemoteHost.quote(release.path)) ]; do /bin/sleep 0.01; done
        exec /bin/sh -c "$command"
        """, batching: true)
        let tasks = startBatch(["cancel.png", "keep.png"], fixture: fixture, files: files)
        defer {
            try? Data().write(to: release)
            for task in tasks { task.cancel() }
        }
        let pid = try await waitForAttempt(fixture)
        tasks[0].cancel()
        await #expect(throws: CancellationError.self) { try await tasks[0].value }
        #expect(kill(pid, 0) == 0)
        #expect(fixture.attempts.count == 1)
        try Data().write(to: release)
        #expect(try await tasks[1].value.data == Data([255, 128, 0, 10]))
        #expect(fixture.attempts.count == 1)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func cancellingTheLastMemberReapsTheSharedHostCommand() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.recordingReader(body: "exec /bin/sleep 30", batching: true)
        let tasks = startBatch(["first.png", "last.png"], fixture: fixture, files: files)
        defer { for task in tasks { task.cancel() } }
        let pid = try await waitForAttempt(fixture)
        tasks[0].cancel()
        await #expect(throws: CancellationError.self) { try await tasks[0].value }
        #expect(kill(pid, 0) == 0)
        tasks[1].cancel()
        await #expect(throws: CancellationError.self) { try await tasks[1].value }
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.attempts.count == 1)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func repeatedBatchesReadMutatedBytesRatherThanCachedResults() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("first.png", Data([0, 255, 1]))
        try fixture.write("second.png", Data([128, 0, 2]))
        let files = try fixture.reader(batching: true)
        let requests = [fixture.request("first.png"), fixture.request("second.png")]
        let original = try await values(start(requests, files: files))
        #expect(original.map(\.data) == [Data([0, 255, 1]), Data([128, 0, 2])])
        try fixture.write("first.png", Data([3, 0, 128]))
        try fixture.write("second.png", Data([255, 4, 0]))
        let changed = try await values(start(requests, files: files))
        #expect(changed.map(\.data) == [Data([3, 0, 128]), Data([255, 4, 0])])
        #expect(changed.map(\.stamp) != original.map(\.stamp))
    }

    @Test func concurrentRangesKeepTheirSelectedBytesAndFullFileSizes() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("movie.mp4", Data([0, 255, 1, 128, 2, 10, 3]))
        try fixture.write("still.png", Data([99, 128, 0]))
        let files = try fixture.reader(batching: true)
        let source = HostFileRequest.Source.directory(fixture.root.path)
        let requests = [fixture.request("movie.mp4"),
                        HostFileRequest(source: source, policy: .boardAsset("movie.mp4"), range: HostFileRange(offset: 2, length: 3)),
                        fixture.request("still.png")]
        let loaded = try await values(start(requests, files: files))
        #expect(loaded.map(\.data) == [Data([0, 255, 1, 128, 2, 10, 3]), Data([1, 128, 2]), Data([99, 128, 0])])
        #expect(loaded.map(\.size) == [7, 7, 3])
        #expect(loaded.map(\.offset) == [0, 2, 0])
    }

    @Test func byteBatchesRefuseGitSourcesWithoutLosingDirectoryMembers() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("file.png", Data([0, 255, 128]))
        let files = try fixture.reader()
        let git: JSONValue = .object([
            "source": .object(["kind": "ref", "root": .string(fixture.root.path), "ref": "main"]),
            "policy": .object(["kind": "board", "relative": "file.png"]), "bytes": .bool(true)
        ])
        let results = try await files.readBatch([fixture.wireRequest("file.png"), git], priority: .visible)
        #expect(results.count == 2)
        guard case .file(let file) = results[0] else {
            Issue.record("directory member did not return its file")
            return
        }
        #expect(file.data == Data([0, 255, 128]))
        guard case .failure(let error) = results[1] else {
            Issue.record("git member did not return its refusal")
            return
        }
        #expect(error == .refused)
    }
}

import Darwin
import Foundation
import Testing
@testable import CanvasCore

@Suite(.serialized)
@MainActor
struct HostFileWatchTests {
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func requests(in log: URL) -> [JSONValue] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    private func recordedReader(_ fixture: HostFileFixture) throws -> (HostFiles, URL) {
        let log = fixture.directory.appendingPathComponent("completed-requests")
        let files = try fixture.reader(body: """
        frame=$(cat)
        printf '%s' "$frame" | /bin/sh -c "$command"
        result=$?
        printf '%s\\n' "$frame" | sed 1d >> \(RemoteHost.quote(log.path))
        exit "$result"
        """)
        return (files, log)
    }

    @Test func pollingContinuesWhileTheMainActorIsBusyAndCancellationDropsChanges() async throws {
        let isolated = try await runIsolatedTestIfParallel("pollingContinuesWhileTheMainActorIsBusyAndCancellationDropsChanges")
        if isolated { return }
        let third = DispatchSemaphore(value: 0)
        let probes = Locked(0)
        var changes: [Int] = []
        let completed = await MainActor.run {
            let watch = HostFileWatch(baseline: 0, interval: .milliseconds(20), probe: {
                let count = probes.withLock { value in
                    value += 1
                    return value
                }
                if count == 3 { third.signal() }
                return count >= 3 ? 1 : 0
            }, changed: { changes.append($0) })
            let completed = third.wait(timeout: .now() + 1)
            watch.cancel()
            return completed
        }
        try #require(completed == .success)
        try await Task.sleep(for: .milliseconds(100))
        #expect(changes == [])
    }

    @Test func nilObservationsPreserveTheBaselineAndContinuePolling() async throws {
        let observations: [Int?] = [0, nil, 0, nil, 1]
        let probes = Locked(0)
        var changes: [Int] = []
        let watch = HostFileWatch(baseline: 0, interval: .milliseconds(20), probe: {
            probes.withLock { index in
                let observation = observations[min(index, observations.count - 1)]
                index += 1
                return observation
            }
        }, changed: { changes.append($0) })
        defer { watch.cancel() }
        try #require(await eventually { !changes.isEmpty })
        #expect(changes == [1])
    }

    @Test func batchHelperFailurePreservesAssetBaselinesWithoutHidingSourceChanges() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("first.js", Data("first".utf8))
        try fixture.write("second.js", Data("second".utf8))
        let failure = fixture.directory.appendingPathComponent("fail-descriptor-reader")
        let failurePath = String(decoding: try JSONEncoder().encode(failure.path), as: UTF8.self)
        let files = try fixture.reader(running: """
        (() => {
          const fs = require('node:fs');
          const cp = require('node:child_process');
          const spawnSync = cp.spawnSync;
          cp.spawnSync = (command, ...args) => {
            if (command === 'python3' && fs.existsSync(\(failurePath))) {
              return { status: 1, stdout: '', stderr: 'descriptor helper failed' };
            }
            return spawnSync(command, ...args);
          };
        })();
        """)
        let requests = ["first.js", "second.js"].map {
            HostFileRequest(source: .directory(fixture.root.path), policy: .boardAsset($0))
        }
        let baseline = try await files.observe(requests)
        try Data().write(to: failure)
        await #expect(throws: HostFileError.self) { try await files.observe(requests) }
        let polls = Locked(0)
        var changes: [[HostFileObservation]] = []
        let watch = HostFileWatch(baseline: baseline, interval: .milliseconds(20), probe: {
            let observation = try? await files.observe(requests)
            polls.withLock { $0 += 1 }
            return observation
        }, changed: { changes.append($0) })
        defer { watch.cancel() }
        try #require(await eventually { polls.withLock { $0 } >= 3 })
        #expect(changes == [])

        try FileManager.default.removeItem(at: failure)
        let recovering = polls.withLock { $0 }
        try #require(await eventually { polls.withLock { $0 } >= recovering + 3 })
        #expect(changes == [])
        #expect(try await files.observe(requests) == baseline)

        try Data("changed first asset".utf8).write(to: fixture.root.appendingPathComponent("first.js"), options: .atomic)
        let edited = try await files.observe(requests)
        #expect(edited[0] != baseline[0])
        #expect(edited[1] == baseline[1])
        try #require(await eventually { changes.count == 1 })
        let settled = polls.withLock { $0 }
        try #require(await eventually { polls.withLock { $0 } >= settled + 3 })
        #expect(changes == [edited])

        let second = fixture.root.appendingPathComponent("second.js")
        try FileManager.default.removeItem(at: second)
        let missing = [edited[0], HostFileObservation.failure(.notFound(commit: nil))]
        try #require(await eventually { changes.count == 2 })
        #expect(changes == [edited, missing])

        let outside = fixture.temp.appendingPathComponent("outside.js")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: outside)
        let refused = [edited[0], HostFileObservation.failure(.refused)]
        try #require(await eventually { changes.count == 3 })
        #expect(changes == [edited, missing, refused])

        try Data("changed while second is refused".utf8).write(to: fixture.root.appendingPathComponent("first.js"), options: .atomic)
        let changedWhileRefused = try await files.observe(requests)
        #expect(changedWhileRefused[0] != edited[0])
        #expect(changedWhileRefused[1] == .failure(.refused))
        try #require(await eventually { changes.count == 4 })
        #expect(changes == [edited, missing, refused, changedWhileRefused])

        let safe = fixture.directory.appendingPathComponent("restored.js")
        try Data("restored second asset".utf8).write(to: safe)
        try #require(rename(safe.path, second.path) == 0)
        let restored = try await files.observe(requests)
        #expect(restored[0] == changedWhileRefused[0])
        #expect(restored[1] == .version(try await files.read(requests[1]).version))
        #expect(try await files.read(requests[1]).data == Data("restored second asset".utf8))
        try #require(await eventually { changes.count == 5 })
        #expect(changes == [edited, missing, refused, changedWhileRefused, restored])
    }

    @Test func nilBaselineUsesMetadataOnlyAndNotifiesOnceForASameSizeEdit() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("chart.png", Data("first".utf8))
        let (files, log) = try recordedReader(fixture)
        let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage("chart.png"))
        var observations: [HostFileObservation] = []
        let watch = HostFileWatch(files: files, request: request, interval: .milliseconds(20)) { observations.append($0) }
        defer { watch.cancel() }
        try #require(await eventually { requests(in: log).count >= 3 })
        #expect(observations == [])
        try Data("other".utf8).write(to: fixture.root.appendingPathComponent("chart.png"), options: .atomic)
        try #require(await eventually { observations.count == 1 })
        let expected = HostFileObservation.version(try await files.read(request).version)
        let completed = requests(in: log).count
        try #require(await eventually { requests(in: log).count >= completed + 3 })
        #expect(observations == [expected])
        let completedRequests = requests(in: log)
        let polls = completedRequests.filter { $0["bytes"] == .bool(false) }
        #expect(polls.count == completedRequests.count - 1)
        #expect(polls.first?["policy"] == .object(["kind": "boardImage", "path": "chart.png"]))
        watch.cancel()
        try fixture.write("chart.png", Data("after cancel".utf8))
        try await Task.sleep(for: .milliseconds(150))
        #expect(observations == [expected])
    }

    @Test func baselineCatchesAnEditBeforeTheFirstPoll() async throws {
        let fixture = try HostFileFixture()
        let files = try fixture.reader()
        try fixture.write("chart.png", Data("old".utf8))
        let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage("chart.png"))
        let baseline = HostFileObservation.version(try await files.read(request).version)
        try fixture.write("chart.png", Data("new image".utf8))
        let expected = HostFileObservation.version(try await files.read(request).version)
        var observations: [HostFileObservation] = []
        let watch = HostFileWatch(files: files, request: request, baseline: baseline, interval: .milliseconds(20)) { observations.append($0) }
        defer { watch.cancel() }
        try #require(await eventually { observations.count == 1 })
        #expect(observations == [expected])
    }

    @Test func missingAndRefusalStatesStayStableAndRecoverToSafeBytes() async throws {
        let fixture = try HostFileFixture()
        let (files, log) = try recordedReader(fixture)
        let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage("chart.png"))
        var observations: [HostFileObservation] = []
        let watch = HostFileWatch(files: files, request: request, baseline: .failure(.notFound(commit: nil)), interval: .milliseconds(20)) { observations.append($0) }
        defer { watch.cancel() }
        try #require(await eventually { requests(in: log).count >= 3 })
        #expect(observations == [])
        let outside = fixture.temp.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        let target = fixture.root.appendingPathComponent("chart.png")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        try #require(await eventually { observations.count == 1 })
        let completed = requests(in: log).count
        try #require(await eventually { requests(in: log).count >= completed + 3 })
        #expect(observations == [.failure(.refused)])
        let safe = fixture.directory.appendingPathComponent("safe.png")
        try Data("safe image".utf8).write(to: safe)
        try #require(rename(safe.path, target.path) == 0)
        try #require(await eventually { observations.count == 2 })
        let read = try await files.read(request)
        #expect(read.data == Data("safe image".utf8))
        #expect(observations == [.failure(.refused), .version(read.version)])
        try FileManager.default.removeItem(at: target)
        try #require(await eventually { observations.count == 3 })
        #expect(observations == [.failure(.refused), .version(read.version), .failure(.notFound(commit: nil))])
        try Data("recreated image".utf8).write(to: target, options: .atomic)
        try #require(await eventually { observations.count == 4 })
        let recreated = try await files.read(request)
        #expect(recreated.data == Data("recreated image".utf8))
        #expect(observations == [.failure(.refused), .version(read.version), .failure(.notFound(commit: nil)), .version(recreated.version)])
    }

    @Test func oversizedImageStateDoesNotTriggerRepeatedReloads() async throws {
        let fixture = try HostFileFixture()
        try fixture.write("chart.png", Data(repeating: 65, count: SourceExcerpt.maxFileBytes + 1))
        let (files, log) = try recordedReader(fixture)
        let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage("chart.png"))
        var observations: [HostFileObservation] = []
        let failure = HostFileObservation.failure(.tooLarge(limit: 4 * 1024 * 1024))
        let watch = HostFileWatch(files: files, request: request, baseline: failure, interval: .milliseconds(20)) { observations.append($0) }
        defer { watch.cancel() }
        try #require(await eventually { requests(in: log).count >= 3 })
        #expect(observations == [])
        try Data("small".utf8).write(to: fixture.root.appendingPathComponent("chart.png"), options: .atomic)
        try #require(await eventually { observations.count == 1 })
        let read = try await files.read(request)
        #expect(read.data == Data("small".utf8))
        #expect(observations == [.version(read.version)])
    }

    @Test func cancelAndDeinitReapInFlightReadsWithoutCallbacks() async throws {
        for release in [false, true] {
            let fixture = try HostFileFixture()
            try fixture.write("chart.png", Data("image".utf8))
            let pidFile = fixture.directory.appendingPathComponent("client-pid")
            let files = try fixture.reader(body: """
            /bin/sh -c "$command"
            echo $$ > \(RemoteHost.quote(pidFile.path))
            exec /bin/sleep 30
            """)
            var observations: [HostFileObservation] = []
            let request = HostFileRequest(source: .directory(fixture.root.path), policy: .boardImage("chart.png"))
            var watch: HostFileWatch? = HostFileWatch(files: files, request: request, baseline: .failure(.notFound(commit: nil)), interval: .milliseconds(20)) { observations.append($0) }
            weak var weakWatch = watch
            defer { watch?.cancel() }
            var started: Int32?
            try #require(await eventually {
                started = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                return started != nil
            })
            let pid = try #require(started)
            #expect(kill(pid, 0) == 0)
            if release {
                watch = nil
                #expect(weakWatch == nil)
            } else {
                watch?.cancel()
                watch?.cancel()
            }
            try #require(await eventually { kill(pid, 0) == -1 && errno == ESRCH })
            try await Task.sleep(for: .milliseconds(100))
            #expect(observations == [])
        }
    }
}

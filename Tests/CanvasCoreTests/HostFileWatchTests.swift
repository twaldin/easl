import Darwin
import Foundation
import Testing
@testable import CanvasCore

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
        eval "set -- $command"
        payload=$6
        /bin/sh -c "$command"
        result=$?
        printf '%s\\n' "$payload" >> \(RemoteHost.quote(log.path))
        exit "$result"
        """)
        return (files, log)
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
        let polls = requests(in: log).filter { $0["bytes"] == .bool(false) }
        #expect(polls.count == requests(in: log).count - 1)
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
        let watch = HostFileWatch(files: files, request: request, baseline: baseline, interval: .seconds(30)) { observations.append($0) }
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
        try fixture.write("chart.png", Data("recreated image".utf8))
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
        try fixture.write("chart.png", Data("small".utf8))
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

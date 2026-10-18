import Foundation
import Testing
@testable import CanvasCore

@MainActor
struct HostMasterTests {
    @MainActor
    private final class Host {
        let directory: URL
        let route: HostRoute
        let processes = RemoteProcesses()
        let master: HostMaster

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-master-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent("ssh").path
            try Self.ssh.write(toFile: executable, atomically: true, encoding: .utf8)
            chmod(executable, 0o755)
            route = HostRoute(target: "host-without-easld", controlPath: directory.appendingPathComponent("control").path, executable: executable)
            master = HostMaster(route: route, processes: processes)
        }

        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func flag(_ name: String) throws { try Data().write(to: URL(fileURLWithPath: route.controlPath + "." + name)) }
        func unflag(_ name: String) throws { try FileManager.default.removeItem(atPath: route.controlPath + "." + name) }
        func pid(_ name: String = "control.pid") -> Int32? {
            (try? String(contentsOf: file(name), encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        var starts: [String] {
            ((try? String(contentsOf: file("control.starts"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        var clients: [Int32] {
            ((try? String(contentsOf: file("clients"), encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { Int32($0) }
        }
        var masters: [Int32] {
            ((try? String(contentsOf: file("masters"), encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { Int32($0) }
        }
        var masterRoutes: [String] {
            ((try? String(contentsOf: file("master-routes"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        var clientRoutes: [String] {
            ((try? String(contentsOf: file("client-routes"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        func release(_ pid: Int32) throws { try Data().write(to: file("release.\(pid)")) }
        func close() {
            master.close()
            processes.terminateAll(grace: 0.05)
            try? FileManager.default.removeItem(at: directory)
        }

        // The master and each mux client are real child processes. Control calls inspect or
        // stop that master, rather than returning a canned success for every invocation.
        private static let ssh = #"""
            #!/bin/sh
            control= operation= master=
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -S) control=$2; shift 2 ;;
                -O) operation=$2; shift 2 ;;
                -M) master=yes; shift ;;
                -o) shift 2 ;;
                -N|-T) shift ;;
                *) shift; break ;;
              esac
            done
            directory=${control%/*}
            case "$operation" in
              exit)
                if [ -f "$control.pid" ]; then read -r pid < "$control.pid"; kill "$pid" 2>/dev/null || :; fi
                rm -f "$control.pid" "$control.ready"
                exit 0 ;;
              check)
                [ ! -f "$control.hold" ] && [ -f "$control.ready" ] && [ -f "$control.pid" ] || exit 1
                read -r pid < "$control.pid"
                kill -0 "$pid" 2>/dev/null
                exit $? ;;
            esac
            if [ "$master" = yes ]; then
              printf '%s\n' "$$" > "$control.pid"
              printf '%s\n' "$$" >> "$control.starts"
              printf '%s\n' "$$" >> "$directory/masters"
              printf '%s\n' "$control" >> "$directory/master-routes"
              if [ -f "$control.fail" ]; then echo 'host refused the connection' >&2; exit 55; fi
              if [ -f "$control.ignore" ]; then trap '' TERM; fi
              : > "$control.ready"
              exec sleep 60
            fi
            [ -f "$control.ready" ] && [ -f "$control.pid" ] || exit 1
            read -r pid < "$control.pid"
            kill -0 "$pid" 2>/dev/null || exit 1
            printf '%s\n' "$$" >> "$directory/clients"
            printf '%s\n' "$control" >> "$directory/client-routes"
            while [ -f "$control.busy" ]; do sleep 0.02; done
            if [ -f "$directory/read-hold" ]; then
              while [ ! -f "$directory/release.$$" ]; do sleep 0.02; done
            fi
            exec /bin/sh -c "$1"
            """#
    }

    private func eventually(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func concurrentReadersShareOneMasterEvenWhenAReaderCancels() async throws {
        let host = try Host()
        defer { host.close() }
        try host.flag("hold")
        let cancelled = Task { try await host.master.ready() }
        let reader = Task { try await host.master.ready() }
        let terminal = Task { try await host.master.ready() }
        #expect(try await eventually { host.pid() != nil })
        cancelled.cancel()
        try host.unflag("hold")
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await reader.value
        try await terminal.value
        #expect(host.starts.count == 1)
        let pid = try #require(host.pid())
        #expect(kill(pid, 0) == 0)
        try Data("host page\n".utf8).write(to: host.file("page.html"))
        let page = try await RemoteHost.run(host.route.executable, host.route.ssh("cat " + RemoteHost.quote(host.file("page.html").path)), timeout: 3)
        #expect(page.status == 0)
        #expect(page.output == "host page\n")
        #expect(host.pid() == pid)
    }

    @Test func aDeadMasterNotifiesItsOwnerAndANewReadStartsOneReplacement() async throws {
        let host = try Host()
        defer { host.close() }
        var ended: [String] = []
        host.master.onEnded = { ended.append($0) }
        try await host.master.ready()
        let first = try #require(host.pid())
        #expect(kill(first, SIGKILL) == 0)
        #expect(try await eventually { kill(first, 0) == -1 && errno == ESRCH })
        try await host.master.ready()
        let second = try #require(host.pid())
        #expect(second != first)
        #expect(kill(second, 0) == 0)
        #expect(host.starts.count == 2)
        #expect(ended.count == 1)
        try await host.master.ready()
        #expect(host.pid() == second)
        #expect(host.starts.count == 2)
    }

    @Test func aFailedStartIsReapedAndDoesNotRetryUntilAskedAgain() async throws {
        let host = try Host()
        defer { host.close() }
        try host.flag("fail")
        await #expect(throws: HostMaster.Failure("host refused the connection")) { try await host.master.ready() }
        let first = try #require(host.pid())
        #expect(kill(first, 0) == -1 && errno == ESRCH)
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.starts.count == 1)
        try host.unflag("fail")
        try await host.master.ready()
        #expect(host.starts.count == 2)
        #expect(kill(try #require(host.pid()), 0) == 0)
    }

    @Test func exitedChildrenAreUntrackedBeforeTheirHandlersFinish() async throws {
        let observed = try await offPool {
            Result {
                let processes = RemoteProcesses()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "exit 0"]
                let started = DispatchSemaphore(value: 0)
                let finish = DispatchSemaphore(value: 0)
                defer {
                    finish.signal()
                    processes.terminateAll(grace: 0.05)
                }
                process.terminationHandler = { _ in
                    started.signal()
                    finish.wait()
                }
                try processes.launch(process)
                try #require(started.wait(timeout: .now() + 10) == .success)
                return (running: process.isRunning, count: processes.count)
            }
        }.get()
        #expect(!observed.running)
        #expect(observed.count == 0)
    }

    @Test func quittingReapsAMasterThatIgnoresTerminationAndRefusesAnotherStart() async throws {
        let host = try Host()
        defer { host.close() }
        try host.flag("ignore")
        try await host.master.ready()
        let pid = try #require(host.pid())
        host.processes.terminateAll(grace: 0.05)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(host.processes.count == 0)
        await #expect(throws: HostMaster.Failure.self) { try await host.master.ready() }
        #expect(host.starts.count == 1)
    }

    @Test func actualFileReadsSerializeAcrossConsumersAndSkipACancelledQueuedRead() async throws {
        let host = try Host()
        defer { host.close() }
        try Data().write(to: host.file("read-hold"))
        let remote = RemoteHost(name: "fixture", sshTarget: "fixture", socketPath: "/unused",
                                tmpdir: host.directory.path, easlBin: "easl")
        let files = HostFiles(host: remote, master: host.master)
        let otherFiles = HostFiles(host: remote, master: host.master)
        let expected = Data([0, 255, 71, 73, 70, 10, 128, 42])
        try expected.write(to: host.file("chart.png"))
        let request = HostFileRequest(source: .directory(host.directory.path), policy: .boardImage("chart.png"))
        let first = Task { try await files.read(request) }
        defer { first.cancel() }
        try #require(try await eventually { host.clients.count == 1 })
        let firstClient = try #require(host.clients.first)
        #expect(kill(firstClient, 0) == 0)
        var entered = false
        let cancelled = Task {
            entered = true
            return try await otherFiles.read(request)
        }
        defer { cancelled.cancel() }
        #expect(try await eventually { entered })
        var waiting = false
        let next = Task {
            waiting = true
            return try await otherFiles.read(request)
        }
        defer { next.cancel() }
        #expect(try await eventually { waiting })
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.clients == [firstClient])
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.clients == [firstClient])
        try host.release(firstClient)
        #expect(try await first.value.data == expected)
        #expect(kill(firstClient, 0) == -1 && errno == ESRCH)
        try #require(try await eventually { host.clients.count == 2 })
        let replacement = try #require(host.clients.last)
        #expect(kill(replacement, 0) == 0)
        var laterWaiting = false
        let later = Task {
            laterWaiting = true
            return try await files.read(request)
        }
        defer { later.cancel() }
        #expect(try await eventually { laterWaiting })
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.clients == [firstClient, replacement])
        try host.release(replacement)
        #expect(try await next.value.data == expected)
        try #require(try await eventually { host.clients.count == 3 })
        let lastClient = try #require(host.clients.last)
        try host.release(lastClient)
        #expect(try await later.value.data == expected)
        #expect(host.clients.count == 3)
        #expect(host.clients.allSatisfy { kill($0, 0) == -1 && errno == ESRCH })
        #expect(host.masters.count == 1)
        #expect(Set(host.clientRoutes) == Set(host.masterRoutes))
        let reader = try #require(host.masters.first)
        #expect(kill(reader, 0) == 0)
        host.master.close()
        #expect(try await eventually { kill(reader, 0) == -1 && errno == ESRCH })
        #expect(host.processes.count == 0)
        await #expect(throws: HostFileError.self) { try await otherFiles.read(request) }
        #expect(host.masters == [reader])
        #expect(host.clients.count == 3)
    }

    @Test func cancellingAnActiveReadReplacesOnlyItsReaderTransport() async throws {
        let host = try Host()
        defer { host.close() }
        try await host.master.ready()
        let persistent = try #require(host.pid())
        try Data().write(to: host.file("read-hold"))
        let remote = RemoteHost(name: "fixture", sshTarget: "fixture", socketPath: "/unused",
                                tmpdir: host.directory.path, easlBin: "easl")
        let files = HostFiles(host: remote, master: host.master)
        try Data("replacement image".utf8).write(to: host.file("chart.png"))
        let request = HostFileRequest(source: .directory(host.directory.path), policy: .boardImage("chart.png"))
        let first = Task { try await files.read(request) }
        defer { first.cancel() }
        try #require(try await eventually { host.clients.count == 1 && host.masters.count == 2 })
        let interrupted = try #require(host.masters.last)
        let firstClient = try #require(host.clients.first)
        let next = Task { try await files.read(request) }
        defer { next.cancel() }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try #require(try await eventually { host.clients.count == 2 && host.masters.count == 3 })
        #expect(kill(firstClient, 0) == -1 && errno == ESRCH)
        #expect(kill(interrupted, 0) == -1 && errno == ESRCH)
        #expect(kill(persistent, 0) == 0)
        try host.release(try #require(host.clients.last))
        #expect(try await next.value.data == Data("replacement image".utf8))
        #expect(kill(persistent, 0) == 0)
        host.master.close()
        #expect(try await eventually { host.processes.count == 0 })
    }

    @Test func persistentChannelCannotStarveFileReadsAndClosingReapsBothMasters() async throws {
        let host = try Host()
        defer { host.close() }
        let remote = RemoteHost(name: "fixture", sshTarget: "fixture", socketPath: "/unused",
                                tmpdir: host.directory.path, easlBin: "easl")
        let files = HostFiles(host: remote, master: host.master)
        let otherFiles = HostFiles(host: remote, master: host.master)
        let expected = Data([137, 80, 78, 71, 0, 255, 10])
        try expected.write(to: host.file("chart.png"))
        let request = HostFileRequest(source: .directory(host.directory.path), policy: .boardImage("chart.png"))
        let busy = host.route.controlPath + ".busy"
        let release = host.file("channel-release")
        let command = try await files.channel(
            #"printf '%s\n' $$ > "$1"; : > "$2"; while [ ! -f "$3" ]; do sleep 0.02; done; rm -f "$2"; printf 'terminal released\n'"#,
            [host.file("channel.pid").path, busy, release.path]
        )
        let channel = Task {
            try await RemoteHost.run(command.executable, command.arguments, timeout: 10)
        }
        defer { channel.cancel() }
        #expect(try await eventually { host.pid("channel.pid") != nil && FileManager.default.fileExists(atPath: busy) })
        let channelPID = try #require(host.pid("channel.pid"))
        var finished = false
        let read = Task {
            let file = try await otherFiles.read(request)
            finished = true
            return file
        }
        defer { read.cancel() }
        #expect(try await eventually(timeout: 3) { finished })
        #expect(kill(channelPID, 0) == 0)
        #expect(host.masters.count == 2)
        #expect(Set(host.masterRoutes).count == 2)
        #expect(host.clientRoutes.first == host.route.controlPath)
        #expect(host.clientRoutes.last != host.route.controlPath)
        try Data().write(to: release)
        #expect(try await read.value.data == expected)
        let result = try await channel.value
        #expect(result.status == 0)
        #expect(result.output == "terminal released\n")
        #expect(kill(channelPID, 0) == -1 && errno == ESRCH)
        #expect(try await files.read(request).data == expected)
        #expect(host.masters.count == 2)
        #expect(host.clientRoutes.suffix(2).allSatisfy { $0 == host.clientRoutes.last })
        let masters = host.masters
        #expect(masters.allSatisfy { kill($0, 0) == 0 })
        host.master.close()
        #expect(try await eventually { masters.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } })
        #expect(host.processes.count == 0)
        let afterClose = HostFiles(host: remote, master: host.master)
        await #expect(throws: HostFileError.self) { try await afterClose.read(request) }
        #expect(host.masters == masters)
        #expect(host.clients.count == 3)
    }
}

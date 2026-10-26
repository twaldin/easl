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

        init(fileConcurrency: Int = 1) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("host-master-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent("ssh").path
            try Self.ssh.write(toFile: executable, atomically: true, encoding: .utf8)
            chmod(executable, 0o755)
            route = HostRoute(target: "host-without-easld", controlPath: directory.appendingPathComponent("control").path, executable: executable)
            master = HostMaster(route: route, processes: processes, fileConcurrency: fileConcurrency)
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
        func read(_ name: String, priority: HostReadPriority = .visible) async throws -> RemoteHost.RunResult {
            let owner = master.fileReader
            let transport = try await owner.fileSession(priority: priority)
            defer { owner.endFileSession(transport) }
            try await transport.ready()
            let interrupt = try transport.interruption()
            return try await RemoteHost.run(
                transport.route.executable,
                transport.route.ssh("cat " + RemoteHost.quote(file(name).path)),
                timeout: 10,
                onStop: interrupt
            )
        }
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
            while [ -f "$control.busy" ]; do
              kill -0 "$pid" 2>/dev/null || exit 255
              sleep 0.02
            done
            if [ -f "$directory/read-hold" ]; then
              while [ ! -f "$directory/release.$$" ]; do
                kill -0 "$pid" 2>/dev/null || exit 255
                sleep 0.02
              done
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

    @Test(arguments: [1, 2, 4, 6])
    func fileTransportLeasesBoundConcurrentCommands(limit: Int) async throws {
        let host = try Host(fileConcurrency: limit)
        defer { host.close() }
        try Data().write(to: host.file("read-hold"))
        let names = (0..<(limit + 2)).map { "file-\($0)" }
        for name in names { try Data(name.utf8).write(to: host.file(name)) }
        let reads = names.map { name in Task { try await host.read(name) } }
        defer { for read in reads { read.cancel() } }
        try #require(try await eventually { host.clients.count == limit })
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.clients.count == limit)
        #expect(Set(host.clientRoutes).count == limit)
        for index in names.indices {
            try #require(try await eventually { host.clients.count > index })
            try host.release(host.clients[index])
        }
        for (name, read) in zip(names, reads) {
            let result = try await read.value
            #expect(result.status == 0)
            #expect(result.output == name)
        }
        #expect(Set(host.clientRoutes).count == limit)
        #expect(host.clients.allSatisfy { kill($0, 0) == -1 && errno == ESRCH })
    }

    @Test func queuedReadsUsePriorityFIFOAndSkipCancellation() async throws {
        let host = try Host(fileConcurrency: 1)
        defer { host.close() }
        try Data().write(to: host.file("read-hold"))
        let names = ["first", "background-1", "cancelled", "background-2", "visible-1", "visible-2", "interactive"]
        for name in names { try Data(name.utf8).write(to: host.file(name)) }
        let first = Task { try await host.read("first") }
        defer { first.cancel() }
        try #require(try await eventually { host.clients.count == 1 })
        var entered: [String] = []
        var completed: [String] = []
        let queued: [(String, HostReadPriority)] = [
            ("background-1", .background), ("cancelled", .background), ("background-2", .background),
            ("visible-1", .visible), ("visible-2", .visible), ("interactive", .interactive)
        ]
        var reads: [Task<RemoteHost.RunResult, Error>] = []
        defer { for read in reads { read.cancel() } }
        for (name, priority) in queued {
            reads.append(Task {
                entered.append(name)
                let result = try await host.read(name, priority: priority)
                completed.append(result.output)
                return result
            })
            try #require(try await eventually { entered.last == name })
        }
        reads[1].cancel()
        await #expect(throws: CancellationError.self) { try await reads[1].value }
        #expect(host.clients.count == 1)
        try host.release(try #require(host.clients.first))
        #expect(try await first.value.output == "first")
        let expected = ["interactive", "visible-1", "visible-2", "background-1", "background-2"]
        for index in expected.indices {
            try #require(try await eventually { host.clients.count == index + 2 })
            try host.release(try #require(host.clients.last))
            try #require(try await eventually { completed.count == index + 1 })
            #expect(completed == Array(expected.prefix(index + 1)))
        }
        for (index, read) in reads.enumerated() where index != 1 {
            #expect(try await read.value.status == 0)
        }
        #expect(host.clients.count == 6)
    }

    @Test func cancellationAfterGrantReturnsTheExactLease() async throws {
        let host = try Host(fileConcurrency: 2)
        defer { host.close() }
        let owner = host.master.fileReader
        let first = try await owner.fileSession()
        try await first.ready()
        defer { owner.endFileSession(first) }
        let second = try await owner.fileSession()
        try await second.ready()
        var entered = false
        let cancelled = Task {
            entered = true
            return try await owner.fileSession()
        }
        defer { cancelled.cancel() }
        try #require(try await eventually { entered })
        owner.endFileSession(second)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try Data("after grant".utf8).write(to: host.file("next"))
        let result = try await host.read("next")
        #expect(result.status == 0)
        #expect(result.output == "after grant")
    }

    @Test func cancellingAnActiveReadLeavesAnotherTransportAndPersistentMasterAlive() async throws {
        let host = try Host(fileConcurrency: 2)
        defer { host.close() }
        try await host.master.ready()
        let persistent = try #require(host.pid())
        try Data().write(to: host.file("read-hold"))
        for name in ["cancelled", "survivor", "replacement"] {
            try Data(name.utf8).write(to: host.file(name))
        }
        let first = Task { try await host.read("cancelled") }
        defer { first.cancel() }
        try #require(try await eventually { host.clients.count == 1 && host.masters.count == 2 })
        let interrupted = try #require(host.masters.last)
        let firstClient = try #require(host.clients.first)
        let other = Task { try await host.read("survivor") }
        defer { other.cancel() }
        try #require(try await eventually { host.clients.count == 2 && host.masters.count == 3 })
        let survivingMaster = try #require(host.masters.last)
        let survivingClient = try #require(host.clients.last)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await eventually { kill(interrupted, 0) == -1 && errno == ESRCH })
        #expect(kill(firstClient, 0) == -1 && errno == ESRCH)
        #expect(kill(persistent, 0) == 0)
        #expect(kill(survivingMaster, 0) == 0)
        #expect(kill(survivingClient, 0) == 0)
        try host.release(survivingClient)
        let survivor = try await other.value
        #expect(survivor.status == 0)
        #expect(survivor.output == "survivor")
        let replacement = Task { try await host.read("replacement") }
        defer { replacement.cancel() }
        try #require(try await eventually { host.clients.count == 3 })
        try host.release(try #require(host.clients.last))
        #expect(try await replacement.value.output == "replacement")
        #expect(kill(persistent, 0) == 0)
        #expect(kill(survivingMaster, 0) == 0)
        #expect(host.masters.count == 4)
    }

    @Test func closingRejectsWaitersAndReapsEveryLeasedTransport() async throws {
        let host = try Host(fileConcurrency: 3)
        defer { host.close() }
        try Data().write(to: host.file("read-hold"))
        let names = ["first", "second", "third"]
        for name in names { try Data(name.utf8).write(to: host.file(name)) }
        let reads = names.map { name in Task { try await host.read(name) } }
        defer { for read in reads { read.cancel() } }
        try #require(try await eventually { host.clients.count == 3 })
        var entered = false
        let waiting = Task {
            entered = true
            return try await host.read("queued")
        }
        defer { waiting.cancel() }
        try #require(try await eventually { entered })
        let masters = host.masters
        #expect(masters.count == 3)
        host.master.close()
        await #expect(throws: HostMaster.Failure("easl is quitting")) { try await waiting.value }
        for read in reads { #expect(try await read.value.status == 255) }
        #expect(try await eventually { masters.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } })
        #expect(host.clients.allSatisfy { kill($0, 0) == -1 && errno == ESRCH })
        #expect(host.processes.count == 0)
        await #expect(throws: HostMaster.Failure("easl is quitting")) { try await host.read("first") }
        #expect(host.clients.count == 3)
        #expect(host.masters == masters)
    }

    @Test func persistentChannelCannotStarveFileReadsAndClosingReapsBothMasters() async throws {
        // The three-second starvation probe must not include unrelated main-actor fixture work.
        let isolated = try await runIsolatedTestIfParallel("persistentChannelCannotStarveFileReadsAndClosingReapsBothMasters")
        if isolated { return }
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
        var cleanupFinished = false
        let cleanup = Task {
            let file = try await otherFiles.cleanup.read(request)
            cleanupFinished = true
            return file
        }
        defer { cleanup.cancel() }
        var finished = false
        let read = Task {
            let file = try await otherFiles.read(request)
            finished = true
            return file
        }
        defer { read.cancel() }
        #expect(try await eventually(timeout: 3) { finished && host.clients.count == 3 })
        #expect(!cleanupFinished)
        #expect(kill(channelPID, 0) == 0)
        #expect(host.masters.count == 2)
        #expect(Set(host.masterRoutes).count == 2)
        #expect(host.clientRoutes.filter { $0 == host.route.controlPath }.count == 2)
        #expect(host.clientRoutes.filter { $0 != host.route.controlPath }.count == 1)
        try Data().write(to: release)
        #expect(try await read.value.data == expected)
        #expect(try await cleanup.value.data == expected)
        let result = try await channel.value
        #expect(result.status == 0)
        #expect(result.output == "terminal released\n")
        #expect(kill(channelPID, 0) == -1 && errno == ESRCH)
        #expect(try await files.read(request).data == expected)
        #expect(host.masters.count == 2)
        let readerRoutes = host.clientRoutes.filter { $0 != host.route.controlPath }
        #expect(readerRoutes.count == 2 && Set(readerRoutes).count == 1)
        let masters = host.masters
        #expect(masters.allSatisfy { kill($0, 0) == 0 })
        host.master.close()
        #expect(try await eventually { masters.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } })
        let pidAbsenceAt = DispatchTime.now().uptimeNanoseconds
        let snapshot = host.processes.diagnosticSnapshot()
        print("HOSTMASTER-DIAGNOSTIC pidAbsenceAt=\(pidAbsenceAt) masters=\(masters)")
        print(snapshot.description)
        #expect(snapshot.count == 0, "\(snapshot.description)")
        if snapshot.count != 0 {
            let ps = try await RemoteHost.run("/bin/ps", ["-o", "pid,ppid,stat,etime,command", "-p", ([getpid()] + masters).map(String.init).joined(separator: ",")], timeout: 3)
            print("HOSTMASTER-DIAGNOSTIC ps status=\(ps.status)\n\(ps.output)\(ps.errors)")
            let cleared = try await eventually { host.processes.count == 0 }
            print("HOSTMASTER-DIAGNOSTIC cleared=\(cleared)\n\(host.processes.diagnosticSnapshot().description)")
            #expect(cleared)
        }
        let afterClose = HostFiles(host: remote, master: host.master)
        await #expect(throws: HostFileError.self) { try await afterClose.read(request) }
        #expect(host.masters == masters)
        #expect(host.clients.count == 4)
    }
}

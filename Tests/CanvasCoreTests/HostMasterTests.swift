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
              if [ -f "$control.fail" ]; then echo 'host refused the connection' >&2; exit 55; fi
              if [ -f "$control.ignore" ]; then trap '' TERM; fi
              : > "$control.ready"
              exec sleep 60
            fi
            [ -f "$control.ready" ] && [ -f "$control.pid" ] || exit 1
            read -r pid < "$control.pid"
            kill -0 "$pid" 2>/dev/null || exit 1
            exec /bin/sh -c "$1"
            """#
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(30)
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
                defer { finish.signal() }
                process.terminationHandler = { _ in
                    started.signal()
                    finish.wait()
                }
                try processes.launch(process)
                started.wait()
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

    @Test func fourFileClientsKeepTheirSlotsWhenAQueuedReaderCancels() async throws {
        let host = try Host()
        defer { host.close() }
        try await host.master.ready()
        func client(_ name: String, entered: @escaping () -> Void = {}) -> Task<Void, Error> {
            Task {
                entered()
                try await host.master.fileSession()
                defer { host.master.endFileSession() }
                let command = "printf '%s\\n' $$ > " + RemoteHost.quote(host.file(name).path) + "; exec sleep 60"
                _ = try await RemoteHost.run(host.route.executable, host.route.ssh(command), timeout: 10)
            }
        }
        let active = (0..<4).map { client("client\($0)") }
        defer { for task in active { task.cancel() } }
        #expect(try await eventually { (0..<4).allSatisfy { host.pid("client\($0)") != nil } })
        let pids = try (0..<4).map { try #require(host.pid("client\($0)")) }
        var entered = false
        let cancelled = client("cancelled", entered: { entered = true })
        #expect(try await eventually { entered })
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!FileManager.default.fileExists(atPath: host.file("cancelled").path))
        var waiting = false
        let next = client("next", entered: { waiting = true })
        defer { next.cancel() }
        #expect(try await eventually { waiting })
        #expect(!FileManager.default.fileExists(atPath: host.file("next").path))
        active[0].cancel()
        await #expect(throws: CancellationError.self) { try await active[0].value }
        #expect(kill(pids[0], 0) == -1 && errno == ESRCH)
        #expect(try await eventually { host.pid("next") != nil })
        let replacement = try #require(host.pid("next"))
        #expect(kill(replacement, 0) == 0)
        for task in active.dropFirst() { task.cancel() }
        next.cancel()
        for task in active.dropFirst() {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        await #expect(throws: CancellationError.self) { try await next.value }
        #expect(pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH })
        #expect(kill(replacement, 0) == -1 && errno == ESRCH)
        #expect(kill(try #require(host.pid()), 0) == 0)
    }
}

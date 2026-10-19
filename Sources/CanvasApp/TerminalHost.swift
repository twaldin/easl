import AppKit
import CanvasCore

/// The terminal-specific connection to a host (`props.host`; `HostedTerminal`), over its shared
/// `HostMaster`. It forwards a loopback port on the host to this instance's `RelayGate`, under a
/// new token each connection, which easld serves as this instance's sockets (`relay.open`).
/// While a hosted tile is open it reconnects after a loss, every 1 s, doubling to 30 s, replays
/// spooled integrations and asks easld to start every open tile's session that isn't running.
@MainActor
final class TerminalHost {
    enum State: Equatable {
        case connecting
        case online
        case offline(String)
    }

    private static var hosts: [String: TerminalHost] = [:]

    static func named(_ target: String) -> TerminalHost {
        if let host = hosts[target] { return host }
        let host = TerminalHost(target: target)
        hosts[target] = host
        return host
    }

    /// The host named `target`, if a hosted tile made this app connect to it; nil otherwise
    /// (nothing here asks a host it never connected to).
    static func existing(_ target: String) -> TerminalHost? { hosts[target] }

    /// Ends every connection (at quit). The tiles' attaches go with them; the sessions don't.
    static func closeAll() {
        for host in hosts.values {
            host.closed = true
            host.connecting?.cancel()
            host.retry?.cancel()
            host.keepAlive?.cancel()
            host.gate?.stop()
        }
        HostMaster.closeAll()
    }

    let target: String
    nonisolated let route: HostRoute
    private let master: HostMaster
    /// This instance on hosts (`HostedTerminal.instance`).
    nonisolated static let instance = HostedTerminal.instance(hostname: localHostname(), support: AppPaths.support.path)

    private(set) var state: State = .connecting
    /// The host's home directory, once a connection has asked.
    private(set) var home: String?
    /// This instance's relayed sockets' directory on the host (`relay.open`), once connected.
    private(set) var run: String?
    /// Where the host's forwarded port lands here; started with the first connection.
    private var gate: RelayGate?
    /// The forwarded port on the host, for `relay.open` again while connected.
    private var port: Int?
    private var keepAlive: Task<Void, Never>?
    /// Why easld couldn't start a tile's session, by tile.
    private(set) var failures: [ObjectID: String] = [:]

    private var masterGeneration: UInt = 0
    private var closed = false
    private var connecting: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var delay: Double = 1
    private let tiles = NSHashTable<TerminalTile>.weakObjects()

    private init(target: String) {
        self.target = target
        master = HostMaster.named(target, support: AppPaths.support.path)
        route = master.route
        master.onEnded = { [weak self] message in self?.masterEnded(message) }
    }

    /// `gethostname`, without the name service lookups `ProcessInfo.hostName` may wait on.
    nonisolated static func localHostname() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "mac" }
        return String(cString: buffer)
    }

    // MARK: Tiles

    /// A hosted tile opened: it follows this host's state, and once the connection is up its
    /// spooled reports replay and its session starts (`catchUp`); on a host already online, at
    /// once.
    func add(_ tile: TerminalTile) {
        tiles.add(tile)
        switch state {
        case .online: Task { await catchUp([tile]) }
        case .connecting: connect()
        case .offline: if retry == nil { connect() }
        }
        tile.hostChanged()
    }

    func remove(_ tile: TerminalTile) {
        tiles.remove(tile)
    }

    /// The tile's Reconnect: try now, and from 1 s again after that.
    func reconnect() {
        delay = 1
        connect()
    }

    private func notify() {
        for tile in tiles.allObjects { tile.hostChanged() }
    }

    // MARK: Connection

    private func connect() {
        guard !closed, connecting == nil, tiles.count > 0 else { return }
        retry?.cancel()
        retry = nil
        state = .connecting
        notify()
        connecting = Task { [weak self] in
            guard let self else { return }
            let result = await self.establish()
            self.connecting = nil
            guard !self.closed else { return }
            switch result {
            case .success(let found):
                self.home = found.home
                self.run = found.run
                self.state = .online
                self.delay = 1
                NSLog("easl: connected to %@ (sockets relayed at %@)", self.target, found.run)
                self.notify()
                await self.catchUp(self.tiles.allObjects)
                self.keepRelayOpen()
            case .failure(let failure):
                self.lost(failure.message)
            }
        }
    }

    private struct Failure: Error { let message: String }

    /// The master up, a loopback port on the host forwarded to the gate, and easld relaying this
    /// instance's sockets to it: the host's home and the sockets' directory. Every attempt gives
    /// the gate a new token before easld hears of the port (`RelayGate.rotate`): after a drop the
    /// old port was free for anyone on the host to listen on, while easld still dialed it.
    private func establish() async -> Result<(home: String, run: String), Failure> {
        let route = route
        do {
            try await master.ready()
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        let generation = masterGeneration
        let probe = await offPool { Self.ssh(route.ssh(HostedTerminal.probe)) }
        guard generation == masterGeneration else { return .failure(Failure(message: "ssh to \(target) disconnected")) }
        guard probe.status == 0, let found = HostedTerminal.parseProbe(probe.output) else {
            return .failure(Failure(message: "\(target) didn't answer as expected: \(probe.errors.isEmpty ? probe.output : probe.errors)"))
        }
        guard found.easld else {
            return .failure(Failure(message: "easld isn't running on \(target): install it with scripts/offload-setup.sh \(target), then start its easld@<user> unit"))
        }
        let gate: RelayGate
        if let existing = self.gate {
            existing.rotate()
            gate = existing
        } else {
            let key = URL(fileURLWithPath: route.controlPath).lastPathComponent.replacingOccurrences(of: "easl-ssh-", with: "")
            gate = RelayGate(path: FileManager.default.temporaryDirectory.appendingPathComponent("easl-gate-\(key).sock").path,
                             targets: ["easl": AppPaths.apiSocket, "cmux": AppPaths.cmuxSocket])
            do { try gate.start() } catch { return .failure(Failure(message: "the relay's socket didn't start: \(error)")) }
            self.gate = gate
        }
        // A dynamic port on the host's loopback; ssh prints the one it got. A master that outlived
        // a failed attempt keeps its forward, which now takes only the new token.
        if port == nil {
            let forward = await offPool { Self.ssh(["-S", route.controlPath, "-O", "forward", "-R", "127.0.0.1:0:\(gate.path)", route.target]) }
            guard generation == masterGeneration else { return .failure(Failure(message: "ssh to \(target) disconnected")) }
            guard forward.status == 0, let forwarded = Int(forward.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return .failure(Failure(message: "ssh couldn't forward a port on \(target) back to easl: \(forward.errors)"))
            }
            port = forwarded
        }
        guard let port else { return .failure(Failure(message: "no forwarded port")) }
        do {
            let relay = try await call("relay.open", .object(["instance": .string(Self.instance), "port": .number(Double(port)), "token": .string(gate.token)]))
            guard generation == masterGeneration else { return .failure(Failure(message: "ssh to \(target) disconnected")) }
            guard let socket = relay["easl"]?.string else { return .failure(Failure(message: "\(target)'s easld didn't say where it relays easl's socket")) }
            return .success((found.home, (socket as NSString).deletingLastPathComponent))
        } catch {
            return .failure(Failure(message: "\(target)'s easld didn't relay easl's sockets: \(error)"))
        }
    }

    private func masterEnded(_ message: String) {
        port = nil
        masterGeneration &+= 1
        NSLog("easl: connection to %@ ended: %@", target, message)
        // While connecting, `establish` sees it go.
        if connecting == nil { lost(message) }
    }

    /// While connected, opens the relay again every 30 s to re-arm a failed connection and fetch
    /// reports spooled during a disarm or easld restart (`catchUp`). easld restores the sockets
    /// itself at startup; a keepalive leaves an open relay's sockets in place.
    private func keepRelayOpen() {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.state == .online, let port = self.port, let gate = self.gate else { return }
                let relay = try? await self.call("relay.open", .object(["instance": .string(Self.instance), "port": .number(Double(port)), "token": .string(gate.token)]))
                if relay?["opened"]?.bool == true {
                    NSLog("easl: %@'s easld relays easl's sockets again", self.target)
                    await self.catchUp(self.tiles.allObjects)
                }
            }
        }
    }

    private func lost(_ reason: String) {
        guard !closed else { return }
        keepAlive?.cancel()
        keepAlive = nil
        state = .offline(reason)
        notify()
        retry?.cancel()
        guard tiles.count > 0 else { retry = nil; return }
        let wait = delay
        delay = min(delay * 2, 30)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            self.connect()
        }
    }

    // MARK: Sessions

    /// Brings `tiles` up to date with the host, in this order: the reports their integrations
    /// spooled there while this instance was away (`replaySpooled`), then their sessions
    /// (`spawn`), started from the objects as those reports left them: an agent the user exited
    /// while the app was away released its tile, so a host that rebooted meanwhile must not
    /// resume it.
    private func catchUp(_ tiles: [TerminalTile]) async {
        guard let run else { return }
        await replaySpooled(tiles, run: run)
        for tile in tiles { await spawn(tile) }
    }

    /// Asks easld to start `tile`'s session unless it runs (`session.spawn`).
    private func spawn(_ tile: TerminalTile) async {
        guard let home, let run, let params = tile.hostedSpawnParams(home: home, run: run),
              let identity = tile.sessionObservation() else { return }
        do {
            let result = try await call("session.spawn", params)
            tile.observeRunningSession(identity)
            failures[tile.objectID] = nil
            if result["created"]?.bool == true { NSLog("easl: %@ started %@ on %@", tile.objectID, result["session"]?.string ?? "", target) }
        } catch let failure as ApiRouter.Failure {
            failures[tile.objectID] = failure.message
            NSLog("easl: %@ couldn't start %@'s session: %@", target, tile.objectID, failure.message)
        } catch {
            failures[tile.objectID] = error.localizedDescription
        }
        tile.hostChanged()
    }

    /// Whether the host has `tile`'s session; nil when its easld can't be asked.
    func hasSession(_ tile: ObjectID) async -> Bool? {
        guard let result = try? await call("session.list", .object([:])), let sessions = result["sessions"]?.array else { return nil }
        return sessions.contains { $0["tile"]?.string == tile }
    }

    /// The tiles whose sessions run on the host, started by this instance (labelled with its
    /// home): agent.list `live` for hosted terminals. Nil while the host isn't online (a listing
    /// never opens a connection) or its easld can't be asked.
    func liveSessions() async -> Set<ObjectID>? {
        guard state == .online, let result = try? await call("session.list", .object([:])), let sessions = result["sessions"]?.array else { return nil }
        return Set(sessions.compactMap { $0["labels"]?["canvas.home"]?.string == TerminalTile.homeLabel ? $0["tile"]?.string : nil })
    }

    /// agent.restart of hosted `tile`: `killing` (which throws to call it off), then easld ends
    /// its session (`session.kill`, only this instance's) and, once it no longer lists it (at most
    /// 3 s), `ended` runs and easld starts the relaunch running `argv` in a new one
    /// (`session.spawn`). Fails `unavailable` while the host isn't online, leaving the session as
    /// it was, and when the host still lists it, before `ended`.
    func restart(_ tile: TerminalTile, running argv: [String], killing: @MainActor () throws -> Void, ended: @MainActor () throws -> Void) async throws {
        let id = tile.objectID
        guard state == .online, let home, let run else {
            throw ApiRouter.Failure("unavailable", "\(target) is offline: terminal \(id)'s session there can't be restarted until it is back")
        }
        try killing()
        try await endSession(id)
        try ended()
        // The session is gone, so merge history cannot matter; older easld accepts this relaunch.
        guard let params = tile.hostedSpawnParams(home: home, run: run, argv: argv, merged: []),
              let identity = tile.sessionObservation() else {
            throw ApiRouter.Failure("not_found", "terminal \(id) was closed")
        }
        let result: JSONValue
        do {
            result = try await call("session.spawn", params)
        } catch {
            failures[id] = (error as? ApiRouter.Failure)?.message ?? error.localizedDescription
            tile.hostChanged()
            throw error
        }
        failures[id] = nil
        tile.hostChanged()
        guard result["created"]?.bool == true else {
            throw ApiRouter.Failure("unavailable", "\(target) started terminal \(id)'s session again before the relaunch could")
        }
        tile.observeRunningSession(identity)
        NSLog("easl: %@ restarted %@ on %@", id, result["session"]?.string ?? "", target)
    }

    func endSession(_ tile: ObjectID) async throws {
        guard state == .online else {
            throw ApiRouter.Failure("unavailable", "\(target) is offline: terminal \(tile)'s session cannot be ended")
        }
        _ = try await call("session.kill", .object(["tile": .string(tile), "home": .string(TerminalTile.homeLabel)]))
        for attempt in 0...30 {
            if await hasSession(tile) == false { return }
            if attempt < 30 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        throw ApiRouter.Failure("unavailable", "\(target) still lists terminal \(tile)'s session, or cannot confirm it is gone, 3 s after ending it")
    }

    /// Replays the reports `tiles`' integrations spooled on the host while they couldn't reach
    /// this instance (`HostedTerminal.spooled`), as a board replays its local spool when it opens
    /// (the staleness rule drops what a live report already overtook), then deletes them there.
    private func replaySpooled(_ tiles: [TerminalTile], run: String) async {
        guard !tiles.isEmpty else { return }
        let route = route, ids = tiles.map(\.objectID)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("easl-spool-\(UUID().uuidString)", isDirectory: true)
        let entries = await offPool { () -> [AgentReportSpool.Entry] in
            guard Self.fetch(route.ssh(HostedTerminal.spooled(run: run, tiles: ids)), into: local) else { return [] }
            return AgentReportSpool.read(from: local, tiles: ids)
        }
        if !entries.isEmpty {
            for tile in tiles { tile.replay(entries.filter { $0.tile == tile.objectID }) }
            let files = entries.map { "\($0.tile)/\($0.file.lastPathComponent)" }
            _ = await offPool { Self.ssh(route.ssh(HostedTerminal.removeSpooled(run: run, files: files))) }
            NSLog("easl: replayed %d report(s) spooled on %@", entries.count, target)
        }
        await offPool { try? FileManager.default.removeItem(at: local) }
    }

    /// One request to the host's easld, through the connection when it is up (`nc` on its
    /// socket, `HostedTerminal.request`: the line kept open until the reply, since easld drops a
    /// client that stopped sending, then ended so nc ends on the host too).
    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let request = try JSONValue.object(["id": .string("1"), "method": .string(method), "params": params]).encodedLine()
        let arguments = route.ssh(HostedTerminal.easldRelay)
        let executable = route.executable
        let reply = await offPool { HostedTerminal.request(executable, arguments, line: request) }
        guard let line = reply.line, let value = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            throw ApiRouter.Failure("unavailable", "\(target)'s easld didn't answer \(method)\(reply.errors.isEmpty ? "" : ": " + reply.errors)")
        }
        guard value["ok"]?.bool == true else {
            throw ApiRouter.Failure(value["error"]?["code"]?.string ?? "internal", value["error"]?["message"]?.string ?? "\(method) failed on \(target)")
        }
        return value["result"] ?? .object([:])
    }

    // MARK: Processes (blocking: call off the main actor)

    /// Runs ssh to its end: its status, standard output and standard error.
    nonisolated private static func ssh(_ arguments: [String]) -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RemoteHost.ssh)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return (-1, "", "ssh didn't start") }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs ssh with `arguments`, its output untarred into `directory`: whether both succeeded.
    nonisolated private static func fetch(_ arguments: [String], into directory: URL) -> Bool {
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return false }
        let ssh = Process(), tar = Process(), pipe = Pipe()
        ssh.executableURL = URL(fileURLWithPath: RemoteHost.ssh)
        ssh.arguments = arguments
        ssh.standardInput = FileHandle.nullDevice
        ssh.standardOutput = pipe
        ssh.standardError = FileHandle.nullDevice
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", "-", "-C", directory.path]
        tar.standardInput = pipe
        tar.standardError = FileHandle.nullDevice
        guard (try? ssh.run()) != nil else { return false }
        guard (try? tar.run()) != nil else {
            ssh.terminate()
            ssh.waitUntilExit()
            return false
        }
        // tar sees the end of the archive only once nothing here holds the pipe open.
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
        ssh.waitUntilExit()
        tar.waitUntilExit()
        return ssh.terminationStatus == 0 && tar.terminationStatus == 0
    }
}

private extension JSONValue {
    /// One request line: JSON and a newline.
    func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

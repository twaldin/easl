import Foundation

/// In-memory authority for one terminal incarnation on one open board, across session restarts.
public struct TerminalSessionIdentity: Equatable, Sendable {
    let board: UUID
    let incarnation: UUID
    let tile: ObjectID
    let createdAt: Date
    let host: String?
    var generation = 0
}

struct TerminalSessionState {
    var identity: TerminalSessionIdentity
    var observedRunning = false
}

extension ApiRouter {
    func stale(_ params: JSONValue) async throws -> JSONValue {
        let board = try board(params)
        let olderThan = try ObjectExpiry.duration(params["olderThan"] ?? .string("7d"))
        let observed = board.objects.filter { $0.value.type == .terminal && board.restartingAgents[$0.key] == nil }
        let identities = observed.compactMapValues { board.terminalSessionIdentity($0.id) }
        let sessions = board.terminalSessionStates
        let generations = board.agentSessions
        let local = board.isRemote ? nil : await terminalSessions?()
        let hosts = Set(observed.values.compactMap { HostedTerminal.host(of: $0) })
        let hosted: [String: Set<ObjectID>] = hosts.isEmpty || board.isRemote ? [:] : await hostedSessions?(hosts.sorted()) ?? [:]
        guard try self.board(.object(["board": .string(board.id)])) === board else {
            throw Failure("not_found", "board \(board.id) was replaced while the request was pending")
        }
        var exited: Set<ObjectID> = []
        for object in board.objects.values where object.type == .terminal {
            guard let before = observed[object.id], before.createdAt == object.createdAt, before.rev == object.rev,
                  let identity = identities[object.id], board.terminalSessionStates[object.id]?.identity == identity,
                  generations[object.id] == board.agentSessions[object.id],
                  board.restartingAgents[object.id] == nil else { continue }
            let running: Bool?
            if let host = identity.host {
                running = hosted[host].map { $0.contains(object.id) }
            } else {
                running = local.map { $0[object.id] != nil }
            }
            if running == true {
                board.observeRunningTerminalSession(identity)
            } else if running == false, sessions[object.id]?.observedRunning == true {
                exited.insert(object.id)
            }
        }
        return board.staleObjects(olderThan: olderThan, exited: exited)
    }
}

extension Board {
    /// A surviving tile can continue after a restart, but never after deletion, replacement, or a host change.
    public func terminalSessionIdentity(_ tile: ObjectID, continuing previous: TerminalSessionIdentity? = nil) -> TerminalSessionIdentity? {
        guard !isClosed, !isRemote, let object = objects[tile], object.type == .terminal else { return nil }
        retainTerminalSessionIdentity(for: object)
        if terminalSessionStates[tile] == nil {
            let identity = TerminalSessionIdentity(board: terminalSessionBoard, incarnation: UUID(), tile: tile,
                                                   createdAt: object.createdAt, host: HostedTerminal.host(of: object))
            terminalSessionStates[tile] = TerminalSessionState(identity: identity)
        }
        guard let identity = terminalSessionStates[tile]?.identity,
              previous == nil || previous?.board == identity.board && previous?.incarnation == identity.incarnation else { return nil }
        return identity
    }

    @discardableResult
    public func observeRunningTerminalSession(_ identity: TerminalSessionIdentity) -> Bool {
        guard !isClosed, !isRemote, restartingAgents[identity.tile] == nil,
              terminalSessionStates[identity.tile]?.identity == identity,
              let object = objects[identity.tile], object.type == .terminal, object.createdAt == identity.createdAt,
              HostedTerminal.host(of: object) == identity.host else { return false }
        terminalSessionStates[identity.tile]?.observedRunning = true
        return true
    }

    func retainTerminalSessionIdentity(for object: CanvasObject) {
        guard let identity = terminalSessionStates[object.id]?.identity else { return }
        if object.type != .terminal || object.createdAt != identity.createdAt || HostedTerminal.host(of: object) != identity.host {
            terminalSessionStates[object.id] = nil
        }
    }

    /// Pending observations of the old process cannot confirm the replacement process started.
    func invalidateTerminalSessionObservation(_ tile: ObjectID) {
        guard terminalSessionStates[tile] != nil else { return }
        terminalSessionStates[tile]?.identity.generation += 1
        terminalSessionStates[tile]?.observedRunning = false
    }

    public func staleObjects(now: Date = Date(), olderThan: TimeInterval = 7 * 86400, exited: Set<ObjectID> = []) -> JSONValue {
        let cutoff = now.addingTimeInterval(-olderThan)
        let entries = objects.values.sorted { $0.id < $1.id }.compactMap { object -> JSONValue? in
            var reasons: [JSONValue] = []
            if case .agent(let tile) = object.createdBy, objects[tile]?.type != .terminal { reasons.append(.string("creator-gone")) }
            if let expires = object.expires, expires.date <= now { reasons.append(.string("expired")) }
            if object.updatedAt < cutoff { reasons.append(.string("untouched")) }
            if object.type == .terminal, exited.contains(object.id) { reasons.append(.string("exited")) }
            guard !reasons.isEmpty else { return nil }
            let title = object.props["title"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                ?? object.props["caption"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                ?? MentionContext.title(of: object, on: self)
            var fields: [String: JSONValue] = [
                "id": .string(object.id), "type": .string(object.type.rawValue),
                "title": .string(String(title.prefix { !$0.isNewline })),
                "createdBy": JSONValue(object.createdBy),
                "updatedAt": .number(object.updatedAt.timeIntervalSinceReferenceDate), "reasons": .array(reasons),
            ]
            if let key = Self.key(object.props) { fields["key"] = .string(key) }
            return .object(fields)
        }
        return .object(["objects": .array(entries)])
    }
}

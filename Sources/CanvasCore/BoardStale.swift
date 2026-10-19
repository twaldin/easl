import Foundation

extension ApiRouter {
    func stale(_ params: JSONValue) async throws -> JSONValue {
        let board = try board(params)
        let olderThan = try ObjectExpiry.duration(params["olderThan"] ?? .string("7d"))
        let observed = board.objects.filter { $0.value.type == .terminal && board.restartingAgents[$0.key] == nil && !board.relaunchedAgents.contains($0.key) }
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
                  generations[object.id] == board.agentSessions[object.id],
                  board.restartingAgents[object.id] == nil, !board.relaunchedAgents.contains(object.id) else { continue }
            if let host = HostedTerminal.host(of: object) {
                if let live = hosted[host], !live.contains(object.id) { exited.insert(object.id) }
            } else if let local, local[object.id] == nil { exited.insert(object.id) }
        }
        return board.staleObjects(olderThan: olderThan, exited: exited)
    }
}

extension Board {
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

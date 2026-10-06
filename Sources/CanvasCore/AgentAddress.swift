import Foundation

/// How agents address a terminal (docs/contracts.md, Agent addresses): `name@board`, a bare
/// `name`, or a tile id; never a host. A board's name is its root folder's name, a terminal's
/// name its `props.name`, which only needs to be unique within its board. A bare name is looked
/// up on the caller's board first, then on every open board; on a board a current name wins over
/// an alias (`Board.aliases`: names a renamed terminal had, until another terminal takes them).
public enum AgentAddress {
    /// A board's name in addresses: its root folder's name, as its window title shows it. Only a
    /// board whose root folder still exists is found by name (an archived one by its id alone).
    public static func boardName(_ root: URL) -> String { root.lastPathComponent }

    /// A terminal's name for addressing: its `props.name`, when it has one.
    public static func name(of terminal: CanvasObject) -> String? {
        terminal.props["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Where a message to `terminal` goes from any board: `name@board` for a named terminal,
    /// else its tile id.
    @MainActor public static func address(of terminal: CanvasObject, on board: Board) -> String {
        name(of: terminal).map { "\($0)@\(boardName(board.root))" } ?? terminal.id
    }

    /// The terminal `target` names among `boards` (the open boards). `caller`, the terminal
    /// asking, puts its own board first for a bare name. Throws `not_found` and `ambiguous`.
    @MainActor
    public static func resolve(_ target: String, caller: ObjectID?, boards: [Board]) throws -> (Board, CanvasObject) {
        let boards = boards.sorted { $0.id < $1.id }
        for board in boards {
            if let object = board.objects[target], object.type == .terminal { return (board, object) }
        }
        if let at = target.lastIndex(of: "@") {
            let name = String(target[..<at]), boardPart = String(target[target.index(after: at)...])
            let live = boards.filter { BoardStore.isDirectory($0.root.path) }
            let named = boards.filter { board in board.id == boardPart || (boardName(board.root) == boardPart && live.contains { $0 === board }) }
            guard let board = named.first else {
                let open = live.map { boardName($0.root) }.sorted().joined(separator: ", ")
                throw ApiRouter.Failure("not_found", "no open board named \(boardPart) (open boards: \(open.isEmpty ? "none" : open))")
            }
            guard named.count == 1 else {
                let listed = named.map { "\(boardName($0.root)) (\($0.id), \($0.root.path))" }.joined(separator: ", ")
                throw ApiRouter.Failure("ambiguous", "\(boardPart) names \(named.count) open boards: \(listed); address the board by its id, \(name)@\(named[0].id)")
            }
            if let found = try lookUp(name, target: target, on: [board]) { return found }
            throw ApiRouter.Failure("not_found", "no terminal tile named \(name) on board \(boardPart)")
        }
        if let caller, let own = boards.first(where: { $0.objects[caller]?.type == .terminal }),
           let found = try lookUp(target, target: target, on: [own]) {
            return found
        }
        if let found = try lookUp(target, target: target, on: boards) { return found }
        throw ApiRouter.Failure("not_found", "no terminal tile named or with id \(target)")
    }

    /// The terminal named `name` on `boards`: current names first, then aliases.
    @MainActor
    private static func lookUp(_ name: String, target: String, on boards: [Board]) throws -> (Board, CanvasObject)? {
        var named: [(Board, CanvasObject)] = []
        for board in boards {
            for object in board.objects.values where object.type == .terminal && Self.name(of: object) == name { named.append((board, object)) }
        }
        if named.isEmpty {
            for board in boards {
                if let id = board.aliases[name], let object = board.objects[id], object.type == .terminal { named.append((board, object)) }
            }
        }
        guard named.count <= 1 else {
            let listed = named.map { "\(address(of: $0.1, on: $0.0)) (\($0.1.id))" }.sorted().joined(separator: ", ")
            throw ApiRouter.Failure("ambiguous", "\(target) matches \(named.count) terminals: \(listed); address one as name@board, or by its tile id")
        }
        return named.first
    }
}

extension Board {
    /// A terminal's `props.name` changed (`commit`): its old name becomes its alias, and the
    /// new one is no other terminal's alias any more (it took it).
    func renamed(_ id: ObjectID, from old: JSONValue?, to new: JSONValue?, type: ObjectType) {
        guard type == .terminal else { return }
        let before = old?["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let after = new?["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        guard before != after else { return }
        if let after { aliases.removeValue(forKey: after) }
        if let before, new != nil { aliases[before] = id }
    }

    /// A deleted terminal's aliases go with it.
    func forgetAliases(of id: ObjectID) {
        aliases = aliases.filter { $0.value != id }
    }

    /// The names that still reach `terminal` besides its own, sorted.
    public func aliases(of terminal: ObjectID) -> [String] {
        aliases.filter { $0.value == terminal }.map(\.key).sorted()
    }
}

/// A successful session listing, separating confirmed running sessions from names that still exist.
public struct TerminalSessions: Equatable, Sendable {
    public var running: [ObjectID: TerminalSession]
    public var unverified: Set<ObjectID>

    public init(running: [ObjectID: TerminalSession] = [:], unverified: Set<ObjectID> = []) {
        self.running = running
        self.unverified = unverified
    }

    public func lists(_ tile: ObjectID) -> Bool {
        running[tile] != nil || unverified.contains(tile)
    }

    public static func zmx(_ output: String, home: String, legacy: [String], foregroundPID: (Int32) -> Int32?) -> TerminalSessions {
        var result = TerminalSessions()
        for line in output.split(whereSeparator: \.isNewline) {
            var fields: [Substring: Substring] = [:]
            for field in line.drop(while: { $0 == " " || $0 == "*" || $0 == "→" }).split(separator: "\t") {
                guard let equals = field.firstIndex(of: "=") else { continue }
                fields[field[..<equals]] = field[field.index(after: equals)...]
            }
            guard let name = fields["name"], name.hasPrefix("canvas-"), fields["status"] != "cleaning up" else { continue }
            let tile = String(name.dropFirst("canvas-".count))
            guard !tile.isEmpty else { continue }
            guard fields["err"] == nil, fields["status"] != "unreachable",
                  fields["canvas.tile"] == name.dropFirst("canvas-".count),
                  let owner = fields["canvas.home"], owner == home || legacy.contains(where: { $0 == owner }) else {
                result.unverified.insert(tile)
                continue
            }
            let shell = fields["pid"].flatMap { Int32($0) }
            result.running[tile] = TerminalSession(board: fields["canvas.board"].map(String.init), pid: shell.flatMap(foregroundPID))
        }
        return result
    }

    public static func hosted(_ entries: [JSONValue], home: String) -> TerminalSessions {
        var result = TerminalSessions()
        for entry in entries {
            guard let name = entry["session"]?.string, name.hasPrefix("canvas-"),
                  entry["status"]?.string != "cleaning up" else { continue }
            let tile = String(name.dropFirst("canvas-".count))
            guard !tile.isEmpty else { continue }
            let labels = entry["labels"]
            guard entry["unreachable"]?.bool != true, entry["err"] == nil,
                  entry["status"]?.string != "unreachable",
                  entry["tile"]?.string == tile, labels?["canvas.tile"]?.string == tile,
                  labels?["canvas.home"]?.string == home else {
                result.unverified.insert(tile)
                continue
            }
            result.running[tile] = TerminalSession(board: labels?["canvas.board"]?.string, pid: nil)
        }
        return result
    }
}

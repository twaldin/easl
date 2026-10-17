import Foundation

/// The Mac a browser tile's page runs on (`BrowserProps.drawingMachine`): that Mac's persistent
/// machine identity (`MachineIdentity`), the only thing calls are routed by, and its name, kept so
/// the tile can still say where its page runs once that Mac is gone.
public struct DrawingMachine: Codable, Equatable, Sendable {
    public var id: String
    public var host: String

    public init(id: String, host: String) {
        self.id = id
        self.host = host
    }

    /// The machine a browser tile's props name; nil when they name none.
    public init?(_ props: JSONValue) {
        guard let fields = props["drawingMachine"]?.object, let id = fields["id"]?.string, let host = fields["host"]?.string else { return nil }
        self.init(id: id, host: host)
    }

    public var json: JSONValue { .object(["id": .string(id), "host": .string(host)]) }

    /// Why `props.drawingMachine` isn't a drawing machine (`object.create`, `object.update`); nil
    /// when it is one, or absent (`null` removes it).
    public static func problem(_ props: JSONValue?) -> String? {
        guard let value = props?["drawingMachine"], value != .null else { return nil }
        guard let fields = value.object, fields.count == 2, let id = fields["id"]?.string, IDs.isID(id), fields["host"]?.string != nil else {
            return "drawingMachine must be {id, host}: a Mac's machine identity (its client.attach identity) and its name"
        }
        return nil
    }

    /// What a browser tile whose page another Mac runs says about it: where the page runs, and
    /// whether that Mac is attached to the board now. `attached`: the machine identities of the
    /// board's attached drawing Macs, nil while not known (the board's link is down).
    public static func status(of props: JSONValue, attached: Set<String>?) -> String {
        guard let machine = DrawingMachine(props) else { return "No drawing Mac yet" }
        guard let attached, !attached.contains(machine.id) else { return "Draws on \(machine.host)" }
        return "Draws on \(machine.host), which is offline"
    }
}

/// This app home's persistent machine identity: its `client.attach` `identity`, which a browser
/// tile's `drawingMachine` names. Made once (`IDs.make("mch")`) and kept in a file of the app's
/// home (`<support>/client-id`), so it outlives relaunches and reconnects and follows neither the
/// hostname nor a connection's `cli_` id.
public enum MachineIdentity {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The identity kept in `file`, made and kept there the first time. Throws when the file can't
    /// be read or written, or holds no id: a Mac without a lasting identity draws no remote board's
    /// browser tile, rather than one that would move with each launch.
    public static func load(from file: URL) throws -> String {
        do {
            let kept = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard IDs.isID(kept) else { throw Failure(description: "\(file.path) holds no machine identity") }
            return kept
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let made = IDs.make("mch")
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((made + "\n").utf8).write(to: file, options: .atomic)
            } catch {
                throw Failure(description: "couldn't keep a machine identity in \(file.path): \(error.localizedDescription)")
            }
            return made
        }
    }
}

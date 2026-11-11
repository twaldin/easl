import Foundation

/// Creation-time attribution, with live terminal resolution for objects saved before snapshots.
public enum AuthorMark {
    /// The terminal whose agent created `object`, when the object carries its mark. None for the
    /// user's objects, terminals, and follow tiles (each belongs to its terminal, sits beside it,
    /// and says so in its title bar), nor once the author terminal is gone from the board.
    public static func author(of object: CanvasObject, in objects: [ObjectID: CanvasObject]) -> CanvasObject? {
        guard case .agent(let tile) = object.createdBy, object.type != .terminal, object.props["followOf"] == nil,
              let terminal = objects[tile], terminal.type == .terminal else { return nil }
        return terminal
    }

    /// A terminal as an author: its `props.name`, else the program in its foreground
    /// (`TerminalName.program`), else its title (`props.title`, then the agent kind), else
    /// "Terminal". Not the live title a program sets: that changes with every spinner frame.
    public static func name(of terminal: CanvasObject, program: String?) -> String {
        [terminal.props["name"]?.string, program, terminal.props["title"]?.string, terminal.props["agent"]?["kind"]?.string]
            .lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Terminal"
    }

    public static func name(of object: CanvasObject, in objects: [ObjectID: CanvasObject], program: (ObjectID) -> String?) -> String? {
        if object.createdBy == .user { return "you" }
        if let name = object.authorName { return name }
        return author(of: object, in: objects).map { name(of: $0, program: program($0.id)) }
    }

    /// The mark's text for an author's name.
    public static func label(_ name: String) -> String { "by \(name)" }
    /// The mark's tooltip.
    public static func toolTip(_ name: String) -> String { "Created by “\(name)”" }

}

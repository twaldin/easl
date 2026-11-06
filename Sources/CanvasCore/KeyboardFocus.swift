/// Selection changes carry their provenance; the native first responder remains the typing owner.
public enum KeyboardFocus {
    public enum SelectionCause: Equatable, Sendable {
        case user
        case boardGesture
        case programmatic
    }

    public enum Handoff: Equatable, Sendable {
        case stay
        case canvas
        case tile(ObjectID)
    }

    public static func afterSelection(_ selection: Set<ObjectID>, cause: SelectionCause) -> Handoff {
        switch cause {
        case .programmatic: return .stay
        case .boardGesture: return .canvas
        case .user:
            guard selection.count == 1, let id = selection.first else { return .canvas }
            return .tile(id)
        }
    }

    /// Return and keypad Enter explicitly re-enter the selected tile.
    public static func entersSelection(keyCode: UInt16) -> Bool {
        keyCode == 36 || keyCode == 76
    }

    /// What Esc does with the canvas holding the keyboard: the innermost thing it can leave.
    public enum Escape: Equatable, Sendable {
        case showChrome, exitGroup, deselect
        /// Close the panel open over the board (Get Started), once nothing else is left to leave.
        case closePanel
        case none
    }

    public static func escape(chromeHidden: Bool, inGroup: Bool, hasSelection: Bool, panelOpen: Bool) -> Escape {
        if chromeHidden { return .showChrome }
        if inGroup { return .exitGroup }
        if hasSelection { return .deselect }
        return panelOpen ? .closePanel : .none
    }

    /// A terminal as the tray names it: its id and its name (`PromptTarget.label`).
    public struct Named: Equatable, Sendable {
        public var id: ObjectID
        public var name: String

        public init(_ id: ObjectID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// What the tray's target line names (`ComposerBar`, after "→"): the target, and, while the
    /// keyboard is in another terminal (a plain shell never takes the target from an agent),
    /// that one too, so where typing goes and where the mentions go never disagree silently (a
    /// prompt typed into a shell while the tray said "→ codex" ran as a shell command). Nil
    /// without a target.
    public static func trayTarget(_ target: Named?, keyboard: Named?) -> String? {
        guard let target else { return nil }
        guard let keyboard, keyboard.id != target.id else { return target.name }
        return "\(target.name) · you're typing in \(keyboard.name)"
    }

    /// The code tile Code ▸ Go to Definition, Find References and Outline act on: the one with
    /// the keyboard, else the one selected tile, else the tile the user last clicked, when that
    /// is a code tile. Nil when none is (the command says so rather than doing nothing).
    public static func codeTarget(focused: ObjectID?, selection: Set<ObjectID>, lastClicked: ObjectID?, isCode: (ObjectID) -> Bool) -> ObjectID? {
        if let focused, isCode(focused) { return focused }
        if selection.count == 1, let selected = selection.first, isCode(selected) { return selected }
        if let lastClicked, isCode(lastClicked) { return lastClicked }
        return nil
    }
}

/// Where the keyboard goes when the user turns to something else, so keys always act on what
/// the user is looking at: Return enters a tile, Esc (⌘Esc in a terminal) leaves it, and
/// selecting another tile never leaves the keyboard behind in the one that had it (`s` staging
/// in a changes tile nobody is looking at).
public enum KeyboardFocus {
    /// The tile holding the keyboard (a terminal, a code tile's rows, a changes tile, a note
    /// being edited, a page).
    public struct Holder: Equatable, Sendable {
        public var id: ObjectID
        public var isTerminal: Bool

        public init(_ id: ObjectID, isTerminal: Bool) {
            self.id = id
            self.isTerminal = isTerminal
        }
    }

    public enum Handoff: Equatable, Sendable {
        /// The keyboard stays where it is.
        case stay
        /// The canvas takes it: Delete, Esc, ⌘W and the arrows act on the selection, Return
        /// enters the one selected tile.
        case canvas
        /// This terminal takes it.
        case terminal(ObjectID)
    }

    /// After any change of the selection (a marquee, a drawing or group label pressed, Go to,
    /// a clicked marker): a tile other than a terminal keeps the keyboard only while it is the
    /// whole selection, so the ring and the keys never part. A terminal keeps it: the user
    /// presses drawings and ⌘-clicks references while talking to the agent (dictation pastes
    /// into it).
    public static func afterSelectionChange(_ selection: Set<ObjectID>, holder: Holder?) -> Handoff {
        guard let holder, !holder.isTerminal, selection != [holder.id] else { return .stay }
        return .canvas
    }

    /// A plain press on a tile's title bar (a click, or the start of a drag): the user turned
    /// to that tile. A terminal takes the keyboard (it types when clicked); anything else leaves
    /// it with the canvas, so Return enters it, unless the tile already has it. Whatever had the
    /// keyboard, a terminal included, loses it.
    public static func afterTitleBarPress(on tile: ObjectID, isTerminal: Bool, holder: Holder?) -> Handoff {
        if holder?.id == tile { return .stay }
        return isTerminal ? .terminal(tile) : .canvas
    }

    /// The keys with which the canvas hands the keyboard to the one selected tile: Return and
    /// keypad Enter. Not Tab, which moves between the canvas and a panel's buttons (Get
    /// Started) and never types into a tile: Tab on the selected practice note put it into
    /// editing, and the next Tab saved a tab character into it.
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

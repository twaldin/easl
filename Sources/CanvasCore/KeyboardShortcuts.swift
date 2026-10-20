import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)
}

public struct ShortcutBinding: Codable, Hashable, Sendable {
    public let key: String
    public let modifiers: ShortcutModifiers

    public init(key: String, modifiers: ShortcutModifiers = .command) {
        self.key = key == "\u{7f}" ? "\u{8}" : key == "\n" ? "\r" : key.lowercased()
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey { case key, modifiers }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try fields.decode(String.self, forKey: .key),
                  modifiers: try fields.decode(ShortcutModifiers.self, forKey: .modifiers))
    }

    private static let symbols: [(ShortcutModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
    private static let names = ["\u{8}": "⌫", "\t": "⇥", "\r": "↩", "\u{1b}": "⎋", " ": "Space",
                                "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→",
                                "\u{f728}": "⌦", "\u{f729}": "Home", "\u{f72b}": "End",
                                "\u{f72c}": "Page Up", "\u{f72d}": "Page Down"]

    public var display: String {
        var prefix = ""
        for (modifier, symbol) in Self.symbols where modifiers.contains(modifier) { prefix += symbol }
        if let scalar = key.unicodeScalars.first, (0xf704...0xf726).contains(scalar.value) {
            return prefix + "F\(scalar.value - 0xf704 + 1)"
        }
        return prefix + (Self.names[key] ?? key.uppercased())
    }

    public var rejectionReason: String? {
        guard modifiers.rawValue & ~15 == 0 else { return "This shortcut has unsupported modifiers." }
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar) || ["\u{8}", "\t", "\r", "\u{1b}"].contains(key)
        else { return "Choose a single key with any modifiers." }
        if modifiers.contains(.command), ["\t", " "].contains(key) {
            return "This shortcut is reserved by macOS for switching apps or input sources and Spotlight."
        }
        if modifiers.contains(.control), (0xf700...0xf703).contains(scalar.value) {
            return "Control-arrow shortcuts are reserved by macOS for Mission Control and Spaces."
        }
        if modifiers.contains([.command, .shift]), ["3", "4", "5", "6"].contains(key) {
            return "This shortcut is reserved by macOS for screenshots and recording."
        }
        if key == "\u{1b}", modifiers.contains([.command, .option]) {
            return "This shortcut is reserved by macOS for Force Quit."
        }
        if key == "q", modifiers == [.command, .control] || modifiers == [.command, .shift] {
            return "This shortcut is reserved by macOS for locking or logging out."
        }
        if key == "h", modifiers == .command || modifiers == [.command, .option] {
            return "This shortcut is reserved by macOS for hiding apps."
        }
        if modifiers.contains(.command), key == "`" || key == "~" && modifiers.contains(.shift) {
            return "This shortcut is reserved by macOS for cycling windows."
        }
        if modifiers.contains(.command), key == "?" || key == "/" && modifiers.contains(.shift) {
            return "This shortcut is reserved by macOS for Help menu search."
        }
        if key == "l", modifiers == .command {
            return "Command-L is reserved for the browser address field."
        }
        if key == "\r", modifiers == .command {
            return "Command-Return is reserved for sending prompts and committing edits."
        }
        if modifiers == [.command, .option], (0xf700...0xf703).contains(scalar.value) {
            return "Option-Command-arrow shortcuts are reserved for moving between tiles."
        }
        return nil
    }
}

public struct ShortcutAction: Equatable, Sendable {
    public let id: String
    public let title: String
    public let group: String
    public let defaultBinding: ShortcutBinding?

    private init(_ id: String, _ title: String, _ group: String, _ key: String? = nil,
                 _ modifiers: ShortcutModifiers = .command) {
        self.id = id
        self.title = title
        self.group = group
        self.defaultBinding = key.map { ShortcutBinding(key: $0, modifiers: modifiers) }
    }

    public static let all: [Self] = [
        .init("showSettings", "Settings…", "easl", ","),
        .init("checkForUpdates", "Check for Updates…", "easl"),
        .init("toggleAutomaticUpdates", "Install Updates Automatically", "easl"),
        .init("retryUpdateRestoration", "Retry Reopening Update Boards", "easl"),
        .init("discardUpdateRecovery", "Discard Update Board Recovery", "easl"),
        .init("toggleBackgroundAttach", "Keep Remote Boards Attached", "easl"),
        .init("clearBrowsingData", "Clear Browsing Data…", "easl"),
        .init("terminate", "Quit easl", "easl", "q"),
        .init("newWindowForTab", "New Board Tab…", "File", "t", [.control, .option, .command]),
        .init("newTerminal", "New Terminal", "File", "t"),
        .init("newNote", "New Note", "File", "n"),
        .init("newBrowserTile", "New Browser Tile…", "File", "b", [.command, .shift]),
        .init("openCodeTile", "Open File as Code Tile…", "File", "o"),
        .init("openBoard", "Open Board…", "File", "o", [.command, .shift]),
        .init("openRemote", "Open Remote…", "File", "o", [.control, .option, .command]),
        .init("newHtmlTile", "New HTML Tile", "File", "h", [.command, .shift]),
        .init("reviewChanges", "Review Changes", "File", "r", [.command, .shift]),
        .init("reviewBranch", "Review Branch", "File", "r", [.control, .option, .command]),
        .init("saveAsPNG", "Export Selection as PNG…", "File", "e", [.command, .shift]),
        .init("saveHTMLTile", "Save HTML Tile as HTML…", "File"),
        .init("openHTMLTileInBrowser", "Open HTML Tile in Browser", "File"),
        .init("openPageInBrowser", "Open Page in Browser", "File"),
        .init("saveNoteAsMarkdown", "Save Note as Markdown…", "File"),
        .init("snapshotPage", "Snapshot Page to Image", "File"),
        .init("printPage", "Print Page…", "File"),
        .init("performClose", "Close", "File", "w"),
        .init("undoCanvas", "Undo", "Edit", "z"),
        .init("redoCanvas", "Redo", "Edit", "z", [.command, .shift]),
        .init("copy", "Copy", "Edit", "c"),
        .init("copyAsImage", "Copy as Image", "Edit", "c", [.command, .shift]),
        .init("copyNoteAsMarkdown", "Copy Note as Markdown", "Edit"),
        .init("paste", "Paste", "Edit", "v"),
        .init("selectAll", "Select All", "Edit", "a"),
        .init("deleteSelection", "Delete Selection", "Edit", "\u{8}"),
        .init("findInPage", "Find in Page…", "Edit", "f"),
        .init("pasteMentions", "Paste Mentions into Terminal", "Edit", "v", [.control, .option, .shift, .command]),
        .init("mentionCurrent", "Mention", "Edit", "m", [.command, .shift]),
        .init("removeLastMention", "Remove Last Mention", "Edit", "m", [.command, .shift, .option]),
        .init("clearMentions", "Clear Mentions", "Edit"),
        .init("focusComposer", "Write Prompt", "Edit", "i"),
        .init("selectTool", "Select", "Drawing", "v", []),
        .init("moveTool", "Move", "Drawing", "m", []),
        .init("rectangleTool", "Rectangle", "Drawing", "r", []),
        .init("ellipseTool", "Ellipse", "Drawing", "o", []),
        .init("arrowTool", "Arrow", "Drawing", "a", []),
        .init("textTool", "Text", "Drawing", "t", []),
        .init("penTool", "Draw", "Drawing", "p", []),
        .init("groupSelection", "Group", "Object", "g"),
        .init("ungroupSelection", "Ungroup", "Object", "g", [.command, .shift]),
        .init("enterGroup", "Enter Group", "Object"),
        .init("bringToFront", "Bring to Front", "Object", "}", [.command, .shift]),
        .init("sendToBack", "Send to Back", "Object", "{", [.command, .shift]),
        .init("zoomContentIn", "Zoom Content In", "Object", "=", [.control, .command]),
        .init("zoomContentOut", "Zoom Content Out", "Object", "-", [.control, .command]),
        .init("zoomContent", "Reset Content Zoom", "Object", "0", [.control, .command]),
        .init("toggleFollowFiles", "Follow Files", "Object"),
        .init("copyObjectIDs", "Copy Object ID", "Object"),
        .init("goToDefinition", "Go to Definition", "Code", "j", [.control, .command]),
        .init("openDefinitionInNewTile", "Open Definition in New Tile", "Code", "j", [.control, .option, .command]),
        .init("findReferences", "Find References", "Code", "r", [.control, .command]),
        .init("showOutline", "Outline", "Code", "o", [.control, .command]),
        .init("showNavigator", "Go to…", "View", "p"),
        .init("goToNextNeedsYou", "Go to Next Needs-You", "View", "j"),
        .init("leaveTile", "Leave Tile", "View", "\u{1b}"),
        .init("navigateBack", "Back", "View", "["),
        .init("navigateForward", "Forward", "View", "]"),
        .init("zoomToActual", "Actual Size", "View", "0"),
        .init("zoomIn", "Zoom In", "View", "="),
        .init("zoomOut", "Zoom Out", "View", "-"),
        .init("zoomToFit", "Zoom to Fit", "View", "9"),
        .init("increaseChromeText", "Increase Chrome Text Size", "View", "=", [.option, .command]),
        .init("decreaseChromeText", "Decrease Chrome Text Size", "View", "-", [.option, .command]),
        .init("resetChromeText", "Reset Chrome Text Size", "View", "0", [.option, .command]),
        .init("clearAttentionMarkers", "Clear Attention Markers", "View"),
        .init("reloadPage", "Reload Page", "View", "r"),
        .init("toggleWebInspector", "Show Web Inspector", "View", "i", [.option, .command]),
        .init("toggleCanvasChrome", "Hide Board Chrome", "View", "t", [.option, .command]),
        .init("toggleLassoSelection", "Lasso Selection", "View"),
        .init("exitGroup", "Exit Group", "View"),
        .init("togglePerformanceHUD", "Performance HUD", "View"),
        .init("performMiniaturize", "Minimize", "Window", "m"),
        .init("performZoom", "Zoom", "Window"),
        .init("arrangeInFront", "Bring All to Front", "Window"),
        .init("toggleGetStarted", "Get Started", "Help"),
        .init("toggleBasics", "easl Basics", "Help", "/", [.option, .command]),
    ]

    fileprivate func rejectionReason(for binding: ShortcutBinding) -> String? {
        if let reason = binding.rejectionReason { return reason }
        if binding.modifiers.subtracting(.shift).isEmpty {
            guard group == "Drawing" else {
                return "Only drawing tools can use a key without Command, Control, or Option."
            }
            guard let scalar = binding.key.unicodeScalars.first,
                  !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  !CharacterSet.controlCharacters.contains(scalar),
                  !(0xf700...0xf8ff).contains(scalar.value) else {
                return "Drawing tools need a printable key. Navigation and editing keys stay with the canvas."
            }
        }
        return nil
    }

    fileprivate static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

public struct KeyboardShortcuts: Codable, Equatable, Sendable {
    private enum Override: Equatable, Sendable {
        case cleared
        case binding(ShortcutBinding)
    }

    private var overrides: [String: Override] = [:]

    public init() {}

    public func binding(for id: String) -> ShortcutBinding? {
        switch overrides[id] {
        case .cleared: return nil
        case .binding(let binding): return binding
        case nil: return ShortcutAction.byID[id]?.defaultBinding
        }
    }

    public func conflict(for binding: ShortcutBinding, excluding id: String) -> ShortcutAction? {
        ShortcutAction.all.first { $0.id != id && self.binding(for: $0.id) == binding }
    }

    public enum Error: LocalizedError, Equatable, Sendable {
        case unknownAction(String)
        case rejected(String)
        case conflict(ShortcutAction)

        public var errorDescription: String? {
            switch self {
            case .unknownAction(let id): return "Unknown keyboard shortcut action: \(id)."
            case .rejected(let reason): return reason
            case .conflict(let action): return "This shortcut is already assigned to \(action.title)."
            }
        }
    }

    public mutating func set(_ binding: ShortcutBinding?, for id: String, swapping: Bool = false) throws {
        guard let action = ShortcutAction.byID[id] else { throw Error.unknownAction(id) }
        if let binding, let reason = action.rejectionReason(for: binding) { throw Error.rejected(reason) }
        if let binding, let other = conflict(for: binding, excluding: id) {
            guard swapping else { throw Error.conflict(other) }
            let previous = self.binding(for: id)
            if let previous, let reason = other.rejectionReason(for: previous) { throw Error.rejected(reason) }
            record(previous, for: other.id)
        }
        record(binding, for: id)
    }

    public mutating func reset(_ id: String, swapping: Bool = false) throws {
        guard let action = ShortcutAction.byID[id] else { throw Error.unknownAction(id) }
        try set(action.defaultBinding, for: id, swapping: swapping)
    }

    public mutating func restoreDefaults() { overrides.removeAll() }

    private mutating func record(_ binding: ShortcutBinding?, for id: String) {
        if binding == ShortcutAction.byID[id]?.defaultBinding {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = binding.map(Override.binding) ?? .cleared
        }
    }

    private enum CodingKeys: String, CodingKey { case overrides }

    private struct ActionKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        self.init()
        guard let fields = try? decoder.container(keyedBy: CodingKeys.self),
              let records = try? fields.nestedContainer(keyedBy: ActionKey.self, forKey: .overrides) else { return }
        for key in records.allKeys {
            guard let action = ShortcutAction.byID[key.stringValue] else { continue }
            if (try? records.decodeNil(forKey: key)) == true {
                record(nil, for: key.stringValue)
            } else if let binding = try? records.decode(ShortcutBinding.self, forKey: key),
                      action.rejectionReason(for: binding) == nil {
                record(binding, for: key.stringValue)
            }
        }
        // Resolve the complete assignment so persisted swaps do not collide with intermediate defaults.
        while true {
            var owners: [ShortcutBinding: [String]] = [:]
            for action in ShortcutAction.all {
                if let binding = binding(for: action.id) { owners[binding, default: []].append(action.id) }
            }
            let rejected = owners.values.filter { $0.count > 1 }.flatMap { $0 }.filter { overrides[$0] != nil }
            guard !rejected.isEmpty else { break }
            for id in rejected { overrides.removeValue(forKey: id) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        var records = fields.nestedContainer(keyedBy: ActionKey.self, forKey: .overrides)
        for (id, override) in overrides {
            guard let key = ActionKey(stringValue: id) else { continue }
            switch override {
            case .cleared: try records.encodeNil(forKey: key)
            case .binding(let binding): try records.encode(binding, forKey: key)
            }
        }
    }
}

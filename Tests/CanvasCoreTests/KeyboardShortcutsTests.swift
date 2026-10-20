import Foundation
import Testing
@testable import CanvasCore

struct KeyboardShortcutsTests {
    @Test func historicalMenuBindingsStayOnTheirOriginalChords() {
        let shortcuts = KeyboardShortcuts()
        let expected: [(String, String, ShortcutModifiers)] = [
            ("terminate", "q", .command),
            ("newTerminal", "t", .command),
            ("newNote", "n", .command),
            ("newBrowserTile", "b", [.command, .shift]),
            ("openCodeTile", "o", .command),
            ("openBoard", "o", [.command, .shift]),
            ("newHtmlTile", "h", [.command, .shift]),
            ("reviewChanges", "r", [.command, .shift]),
            ("saveAsPNG", "e", [.command, .shift]),
            ("performClose", "w", .command),
            ("undoCanvas", "z", .command),
            ("redoCanvas", "z", [.command, .shift]),
            ("copy", "c", .command),
            ("copyAsImage", "c", [.command, .shift]),
            ("paste", "v", .command),
            ("selectAll", "a", .command),
            ("deleteSelection", "\u{8}", .command),
            ("findInPage", "f", .command),
            ("pasteMentions", "v", [.control, .option, .shift, .command]),
            ("mentionCurrent", "m", [.command, .shift]),
            ("removeLastMention", "m", [.command, .shift, .option]),
            ("focusComposer", "i", .command),
            ("groupSelection", "g", .command),
            ("ungroupSelection", "g", [.command, .shift]),
            ("bringToFront", "}", [.command, .shift]),
            ("sendToBack", "{", [.command, .shift]),
            ("zoomContentIn", "=", [.control, .command]),
            ("zoomContentOut", "-", [.control, .command]),
            ("zoomContent", "0", [.control, .command]),
            ("goToDefinition", "j", [.control, .command]),
            ("openDefinitionInNewTile", "j", [.control, .option, .command]),
            ("findReferences", "r", [.control, .command]),
            ("showOutline", "o", [.control, .command]),
            ("showNavigator", "p", .command),
            ("goToNextNeedsYou", "j", .command),
            ("leaveTile", "\u{1b}", .command),
            ("navigateBack", "[", .command),
            ("navigateForward", "]", .command),
            ("zoomToActual", "0", .command),
            ("zoomIn", "=", .command),
            ("zoomOut", "-", .command),
            ("zoomToFit", "9", .command),
            ("increaseChromeText", "=", [.option, .command]),
            ("decreaseChromeText", "-", [.option, .command]),
            ("resetChromeText", "0", [.option, .command]),
            ("reloadPage", "r", .command),
            ("toggleWebInspector", "i", [.option, .command]),
            ("toggleCanvasChrome", "t", [.option, .command]),
            ("performMiniaturize", "m", .command),
            ("toggleBasics", "/", [.option, .command]),
        ]
        for (id, key, modifiers) in expected {
            #expect(shortcuts.binding(for: id) == ShortcutBinding(key: key, modifiers: modifiers), "\(id)")
        }
        let unbound = ["checkForUpdates", "toggleAutomaticUpdates", "retryUpdateRestoration", "discardUpdateRecovery",
                       "toggleBackgroundAttach", "clearBrowsingData", "saveHTMLTile", "openHTMLTileInBrowser",
                       "openPageInBrowser", "saveNoteAsMarkdown", "snapshotPage", "printPage", "copyNoteAsMarkdown",
                       "clearMentions", "enterGroup", "toggleFollowFiles", "copyObjectIDs", "clearAttentionMarkers",
                       "toggleLassoSelection", "exitGroup", "togglePerformanceHUD", "performZoom", "arrangeInFront",
                       "toggleGetStarted"]
        for id in unbound {
            #expect(ShortcutAction.all.contains { $0.id == id }, "\(id) remains customizable")
            #expect(shortcuts.binding(for: id) == nil, "\(id)")
        }
    }

    @Test func addedCreationDefaultsAndDrawingKeysAreAvailableWithoutCollisions() throws {
        var shortcuts = KeyboardShortcuts()
        #expect(shortcuts.binding(for: "showSettings") == ShortcutBinding(key: ","))
        for (id, key) in [("newWindowForTab", "t"), ("openRemote", "o"), ("reviewBranch", "r")] {
            #expect(shortcuts.binding(for: id) == ShortcutBinding(key: key, modifiers: [.control, .option, .command]))
        }
        for (id, key) in [("selectTool", "v"), ("rectangleTool", "r"), ("ellipseTool", "o"),
                          ("arrowTool", "a"), ("textTool", "t"), ("penTool", "p")] {
            #expect(shortcuts.binding(for: id) == ShortcutBinding(key: key, modifiers: []))
            try shortcuts.set(nil, for: id)
            #expect(shortcuts.binding(for: id) == nil)
            try shortcuts.reset(id)
            #expect(shortcuts.binding(for: id) == ShortcutBinding(key: key, modifiers: []))
        }
        let reloaded = try JSONDecoder().decode(KeyboardShortcuts.self, from: JSONEncoder().encode(shortcuts))
        #expect(reloaded == KeyboardShortcuts())
        #expect(Set(ShortcutAction.all.map(\.id)).count == ShortcutAction.all.count)
        var seen: Set<ShortcutBinding> = []
        for action in ShortcutAction.all {
            if let binding = reloaded.binding(for: action.id) {
                #expect(binding.rejectionReason == nil, "\(action.title)")
                #expect(seen.insert(binding).inserted, "\(action.title) must not share an active chord")
                #expect(reloaded.conflict(for: binding, excluding: action.id) == nil)
            }
        }
    }

    @Test func nativePunctuationKeepsItsKeyAndModifiersWhenSaved() throws {
        var shortcuts = KeyboardShortcuts()
        try shortcuts.set(ShortcutBinding(key: "&", modifiers: .command), for: "newNote")
        let reloaded = try JSONDecoder().decode(KeyboardShortcuts.self, from: JSONEncoder().encode(shortcuts))
        let binding = try #require(reloaded.binding(for: "newNote"))
        #expect(binding.key == "&")
        #expect(binding.modifiers == .command)
    }

    @Test func conflictRefusalIsAtomicAndSwapMovesThePreviousBinding() throws {
        var shortcuts = KeyboardShortcuts()
        let terminal = try #require(shortcuts.binding(for: "newTerminal"))
        let before = shortcuts
        #expect(throws: (any Error).self) { try shortcuts.set(terminal, for: "newNote") }
        #expect(shortcuts == before)
        try shortcuts.set(terminal, for: "newNote", swapping: true)
        #expect(shortcuts.binding(for: "newNote") == ShortcutBinding(key: "t"))
        #expect(shortcuts.binding(for: "newTerminal") == ShortcutBinding(key: "n"))
        #expect(try JSONDecoder().decode(KeyboardShortcuts.self, from: JSONEncoder().encode(shortcuts)) == shortcuts)
        #expect(throws: (any Error).self) { try shortcuts.reset("newNote") }
        #expect(shortcuts.binding(for: "newNote") == ShortcutBinding(key: "t"))
        #expect(shortcuts.binding(for: "newTerminal") == ShortcutBinding(key: "n"))
        try shortcuts.reset("newNote", swapping: true)
        #expect(shortcuts == KeyboardShortcuts())
    }

    @Test func swappingFromAnUnboundActionClearsTheConflictingAction() throws {
        for target in ["saveHTMLTile", "newNote"] {
            var shortcuts = KeyboardShortcuts()
            try shortcuts.set(nil, for: target)
            try shortcuts.set(ShortcutBinding(key: "t"), for: target, swapping: true)
            #expect(shortcuts.binding(for: target) == ShortcutBinding(key: "t"))
            #expect(shortcuts.binding(for: "newTerminal") == nil)
            let reloaded = try JSONDecoder().decode(KeyboardShortcuts.self, from: JSONEncoder().encode(shortcuts))
            #expect(reloaded == shortcuts)
            #expect(reloaded.binding(for: "newTerminal") == nil)
        }
    }

    @Test func individualResetAndRestoreDefaultsDiscardCustomAndClearedBindings() throws {
        var shortcuts = KeyboardShortcuts()
        try shortcuts.set(nil, for: "newNote")
        try shortcuts.set(ShortcutBinding(key: "s", modifiers: [.control, .option, .command]), for: "saveHTMLTile")
        try shortcuts.reset("newNote")
        #expect(shortcuts.binding(for: "newNote") == ShortcutBinding(key: "n"))
        #expect(shortcuts.binding(for: "saveHTMLTile") != nil)
        try shortcuts.reset("saveHTMLTile")
        #expect(shortcuts == KeyboardShortcuts())
        try shortcuts.set(nil, for: "newTerminal")
        try shortcuts.set(ShortcutBinding(key: "n", modifiers: [.control, .option, .command]), for: "newNote")
        shortcuts.restoreDefaults()
        #expect(shortcuts == KeyboardShortcuts())
        #expect(shortcuts.binding(for: "newTerminal") == ShortcutBinding(key: "t"))
    }

    @Test func customAndClearedBindingsPersistWithoutReplacingOtherSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = UISettings.Store(url: home.appendingPathComponent("ui-settings.json"))
        try store.update {
            $0.chromeTextScale = 1.3
            $0.backgroundAttach = false
            $0.questionArchiveAfter = 30
            $0.installUpdatesAutomatically = true
        }
        var shortcuts = store.load().keyboardShortcuts
        let custom = ShortcutBinding(key: "n", modifiers: [.control, .option, .command])
        try shortcuts.set(custom, for: "newNote")
        try shortcuts.set(nil, for: "newTerminal")
        try store.update { $0.keyboardShortcuts = shortcuts }
        try store.update { $0.chromeTextScale = 1.5 }
        #expect(store.load() == UISettings(chromeTextScale: 1.5, backgroundAttach: false, questionArchiveAfter: 30,
                                           installUpdatesAutomatically: true, keyboardShortcuts: shortcuts))
        #expect(store.load().keyboardShortcuts.binding(for: "newNote") == custom)
        #expect(store.load().keyboardShortcuts.binding(for: "newTerminal") == nil)
        shortcuts.restoreDefaults()
        try store.update { $0.keyboardShortcuts = shortcuts }
        #expect(store.load() == UISettings(chromeTextScale: 1.5, backgroundAttach: false, questionArchiveAfter: 30,
                                           installUpdatesAutomatically: true))
    }

    @Test func reservedAndMalformedBindingsAreRefusedWithoutChangingAssignments() throws {
        var shortcuts = KeyboardShortcuts()
        let before = shortcuts
        let refused = [ShortcutBinding(key: "\t"), ShortcutBinding(key: "\t", modifiers: [.command, .shift]),
                       ShortcutBinding(key: " "), ShortcutBinding(key: " ", modifiers: [.command, .option]),
                       ShortcutBinding(key: "\u{f700}", modifiers: .control),
                       ShortcutBinding(key: "\u{f702}", modifiers: [.command, .option]),
                       ShortcutBinding(key: "3", modifiers: [.command, .shift]),
                       ShortcutBinding(key: "4", modifiers: [.command, .shift, .control]),
                       ShortcutBinding(key: "5", modifiers: [.command, .shift]),
                       ShortcutBinding(key: "6", modifiers: [.command, .shift]),
                       ShortcutBinding(key: "\u{1b}", modifiers: [.command, .option]),
                       ShortcutBinding(key: "q", modifiers: [.command, .control]),
                       ShortcutBinding(key: "q", modifiers: [.command, .shift]),
                       ShortcutBinding(key: "h"), ShortcutBinding(key: "h", modifiers: [.command, .option]),
                       ShortcutBinding(key: "`"), ShortcutBinding(key: "?", modifiers: [.command, .shift]),
                       ShortcutBinding(key: "\r"), ShortcutBinding(key: "\n"),
                       ShortcutBinding(key: "l"), ShortcutBinding(key: ""), ShortcutBinding(key: "two"),
                       ShortcutBinding(key: "\u{0}"), ShortcutBinding(key: "x", modifiers: .init(rawValue: 16))]
        for binding in refused {
            #expect(binding.rejectionReason != nil)
            #expect(throws: (any Error).self) { try shortcuts.set(binding, for: "newNote", swapping: true) }
            #expect(shortcuts == before)
        }
        for key in ["=", "-", "0"] {
            #expect(ShortcutBinding(key: key, modifiers: [.command, .option]).rejectionReason == nil)
        }
        #expect(throws: KeyboardShortcuts.Error.unknownAction("noSuchAction")) { try shortcuts.set(nil, for: "noSuchAction") }
        #expect(throws: KeyboardShortcuts.Error.unknownAction("noSuchAction")) { try shortcuts.reset("noSuchAction") }
        #expect(shortcuts == before)
        #expect(shortcuts.binding(for: "noSuchAction") == nil)
    }

    @Test func bareTypingKeysAreOnlyAssignableToDrawingToolsIncludingDuringSwap() throws {
        var shortcuts = KeyboardShortcuts()
        let before = shortcuts
        for modifiers in [ShortcutModifiers(), .shift] {
            #expect(throws: (any Error).self) {
                try shortcuts.set(ShortcutBinding(key: "n", modifiers: modifiers), for: "newNote")
            }
            #expect(shortcuts == before)
        }
        #expect(throws: (any Error).self) {
            try shortcuts.set(ShortcutBinding(key: "n"), for: "selectTool", swapping: true)
        }
        #expect(shortcuts == before)
        try shortcuts.set(ShortcutBinding(key: "x", modifiers: []), for: "selectTool")
        let reloaded = try JSONDecoder().decode(KeyboardShortcuts.self, from: JSONEncoder().encode(shortcuts))
        #expect(reloaded.binding(for: "selectTool") == ShortcutBinding(key: "x", modifiers: []))
    }

    @Test func bareDrawingBindingsCannotReplaceCanvasNavigationOrEditingKeys() throws {
        var shortcuts = KeyboardShortcuts()
        let before = shortcuts
        for key in ["\r", "\t", "\u{8}", "\u{1b}", " ", "\u{f700}", "\u{f701}", "\u{f702}", "\u{f703}", "\u{f728}"] {
            for modifiers in [ShortcutModifiers(), .shift] {
                #expect(throws: (any Error).self) {
                    try shortcuts.set(ShortcutBinding(key: key, modifiers: modifiers), for: "rectangleTool")
                }
                #expect(shortcuts == before)
            }
        }
    }

    private func record(_ key: String, _ modifiers: ShortcutModifiers = .command) throws -> Any {
        ["key": key, "modifiers": try JSONSerialization.jsonObject(with: JSONEncoder().encode(modifiers), options: .fragmentsAllowed)]
    }

    private func decode(_ records: [String: Any]) throws -> KeyboardShortcuts {
        let data = try JSONSerialization.data(withJSONObject: ["overrides": records])
        return try JSONDecoder().decode(KeyboardShortcuts.self, from: data)
    }

    @Test func damagedRecordsDoNotDiscardValidOverridesOrActivateUnsafeKeys() throws {
        let custom = ShortcutBinding(key: "n", modifiers: [.control, .option, .command])
        let shortcuts = try decode([
            "newNote": record("n", [.control, .option, .command]),
            "newTerminal": NSNull(),
            "unknownAction": record("x"),
            "saveHTMLTile": ["key": 17],
            "openBoard": record("\t"),
            "saveNoteAsMarkdown": record("n", []),
            "openCodeTile": record("x", .shift),
            "reviewChanges": ["key": "x", "modifiers": ["rawValue": -1]],
            "zoomIn": ["key": ""],
            "selectTool": record("x", []),
        ])
        #expect(shortcuts.binding(for: "newNote") == custom)
        #expect(shortcuts.binding(for: "newTerminal") == nil)
        #expect(shortcuts.binding(for: "unknownAction") == nil)
        #expect(shortcuts.binding(for: "saveHTMLTile") == nil)
        #expect(shortcuts.binding(for: "openBoard") == ShortcutBinding(key: "o", modifiers: [.command, .shift]))
        #expect(shortcuts.binding(for: "saveNoteAsMarkdown") == nil)
        #expect(shortcuts.binding(for: "openCodeTile") == ShortcutBinding(key: "o"))
        #expect(shortcuts.binding(for: "reviewChanges") == ShortcutBinding(key: "r", modifiers: [.command, .shift]))
        #expect(shortcuts.binding(for: "zoomIn") == ShortcutBinding(key: "="))
        #expect(shortcuts.binding(for: "selectTool") == ShortcutBinding(key: "x", modifiers: []))
    }

    @Test func duplicatePersistedAssignmentsFallBackWithoutLeavingCascadingConflicts() throws {
        let duplicates = try decode([
            "newNote": record("x", [.control, .option, .command]),
            "newTerminal": record("x", [.control, .option, .command]),
            "saveHTMLTile": record("}", [.command, .shift]),
            "saveNoteAsMarkdown": record("}", [.command, .shift]),
        ])
        #expect(duplicates == KeyboardShortcuts())
        let cascading = try decode(["newNote": record("t"), "saveHTMLTile": record("n")])
        #expect(cascading == KeyboardShortcuts())
        let swapped = try decode(["newNote": record("t"), "newTerminal": record("n")])
        #expect(swapped.binding(for: "newNote") == ShortcutBinding(key: "t"))
        #expect(swapped.binding(for: "newTerminal") == ShortcutBinding(key: "n"))
        for state in [duplicates, cascading, swapped] {
            let active = ShortcutAction.all.compactMap { state.binding(for: $0.id) }
            #expect(Set(active).count == active.count)
        }
    }

    @Test func oldAndMalformedShortcutFieldsLeaveOtherSettingsReadable() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("shortcuts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = UISettings.Store(url: home.appendingPathComponent("ui-settings.json"))
        #expect(store.load().keyboardShortcuts == KeyboardShortcuts())
        for suffix in ["", #", "keyboardShortcuts": null"#, #", "keyboardShortcuts": []"#,
                       #", "keyboardShortcuts": "broken""#, #", "keyboardShortcuts": {"overrides": 3}"#,
                       #", "keyboardShortcuts": {"overrides": {"newNote": false}}"#] {
            let data = Data(#"{"scale":1.3,"backgroundAttach":false,"questionArchiveAfter":30,"installUpdatesAutomatically":true\#(suffix)}"#.utf8)
            try data.write(to: store.url)
            #expect(store.load() == UISettings(chromeTextScale: 1.3, backgroundAttach: false, questionArchiveAfter: 30,
                                               installUpdatesAutomatically: true))
        }
    }
}

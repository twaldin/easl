import AppKit
import CanvasCore

@MainActor
enum AppShortcuts {
    static private(set) var current = KeyboardShortcuts()
    static let didChange = Notification.Name("easl.keyboardShortcutsChanged")
    static let actionIDs = Set(ShortcutAction.all.map(\.id))
    private static let shifted = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~", "\\": "|"]

    static func configure(_ shortcuts: KeyboardShortcuts) {
        current = shortcuts
        apply(to: NSApp.mainMenu)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func apply(to menu: NSMenu?) {
        for item in menu?.items ?? [] {
            if let id = item.identifier?.rawValue, actionIDs.contains(id) { apply(to: item, id: id) }
            apply(to: item.submenu)
        }
    }

    static func apply(to item: NSMenuItem, id: String) {
        item.identifier = NSUserInterfaceItemIdentifier(id)
        guard let binding = current.binding(for: id) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        // AppKit requires the shifted character as well as the Shift mask.
        item.keyEquivalent = binding.modifiers.contains(.shift) ? shifted[binding.key] ?? binding.key.uppercased() : binding.key
        item.keyEquivalentModifierMask = flags(binding.modifiers)
    }

    static func flags(_ modifiers: ShortcutModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    static func binding(for event: NSEvent) -> ShortcutBinding? {
        guard event.type == .keyDown else { return nil }
        var modifiers: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        let key: String?
        switch event.keyCode {
        case 36, 76: key = "\r"
        case 48: key = "\t"
        case 51: key = "\u{8}"
        case 53: key = "\u{1b}"
        default:
            let characters = event.charactersIgnoringModifiers ?? ""
            if characters.unicodeScalars.contains(where: { $0.value >= 0xf700 && $0.value <= 0xf8ff }) {
                key = characters
            } else {
                key = event.characters(byApplyingModifiers: [])
            }
        }
        guard let key, !key.isEmpty else { return nil }
        return ShortcutBinding(key: key, modifiers: modifiers)
    }

    static func action(for event: NSEvent) -> ShortcutAction? {
        guard let binding = binding(for: event) else { return nil }
        if let action = ShortcutAction.all.first(where: { current.binding(for: $0.id) == binding }) { return action }
        // Keep the existing plus alias for Zoom In without masking an explicit shifted binding.
        if binding.key == "=", binding.modifiers.contains(.shift),
           current.binding(for: "zoomIn") == ShortcutBinding(key: "=", modifiers: binding.modifiers.subtracting(.shift)) {
            return ShortcutAction.all.first { $0.id == "zoomIn" }
        }
        return nil
    }

    static func isEnabled(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, let target = NSApp.target(forAction: action, to: item.target, from: item) else { return false }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return item.isEnabled
    }

    static func systemReservation(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else { return nil }
        for value in hotkeys.values {
            guard let hotkey = value as? [String: Any], (hotkey["enabled"] as? NSNumber)?.boolValue == true,
                  let definition = hotkey["value"] as? [String: Any], let parameters = definition["parameters"] as? [NSNumber], parameters.count >= 3,
                  parameters[1].intValue == Int(event.keyCode),
                  NSEvent.ModifierFlags(rawValue: parameters[2].uintValue).intersection([.command, .shift, .option, .control]) == flags else { continue }
            return "This shortcut is enabled in macOS System Settings. Choose another shortcut or disable the system shortcut first."
        }
        return nil
    }
}

@MainActor
final class KeyboardShortcutSettingsController: NSWindowController, NSWindowDelegate {
    private let store = UISettings.Store(url: AppPaths.uiSettings)
    private var recording: String?
    private var rows: [String: (binding: NSTextField, record: NSButton)] = [:]
    private let status = NSTextField(wrappingLabelWithString: "Select Record, then press a shortcut. Escape cancels recording.")

    init() {
        let window = ShortcutSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 400)
        window.delegate = self
        window.capture = { [weak self] in self?.capture($0) ?? false }
        buildContent(window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func present() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { stopRecording() }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }

    private func buildContent(_ window: NSWindow) {
        let root = NSView()
        window.contentView = root
        let title = NSTextField(labelWithString: "Keyboard Shortcuts")
        title.font = .boldSystemFont(ofSize: 20)
        status.textColor = .secondaryLabelColor
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 16, right: 0)
        scroll.documentView = stack
        var lastGroup: String?
        for action in ShortcutAction.all {
            if lastGroup != action.group {
                let heading = NSTextField(labelWithString: action.group)
                heading.font = .boldSystemFont(ofSize: 14)
                stack.addArrangedSubview(heading)
                lastGroup = action.group
            }
            let label = NSTextField(labelWithString: action.title)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let binding = NSTextField(labelWithString: "")
            binding.alignment = .right
            binding.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            binding.widthAnchor.constraint(equalToConstant: 142).isActive = true
            let record = button("Record", action: #selector(recordShortcut(_:)), id: action.id)
            let clear = button("Clear", action: #selector(clearShortcut(_:)), id: action.id)
            let reset = button("Reset", action: #selector(resetShortcut(_:)), id: action.id)
            let row = NSStackView(views: [label, binding, record, clear, reset])
            row.spacing = 8
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows[action.id] = (binding, record)
        }
        for view in [title, status, scroll, restore] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: restore.topAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            restore.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            restore.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        refresh()
    }

    private func button(_ title: String, action: Selector, id: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        return button
    }

    private func refresh() {
        for (id, row) in rows {
            row.binding.stringValue = AppShortcuts.current.binding(for: id)?.display ?? "None"
            row.record.title = recording == id ? "Cancel" : "Record"
        }
    }

    private func stopRecording() {
        recording = nil
        status.stringValue = "Select Record, then press a shortcut. Escape cancels recording."
        refresh()
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if recording == id { return stopRecording() }
        recording = id
        status.stringValue = "Press a shortcut for \(ShortcutAction.all.first { $0.id == id }?.title ?? id). Escape cancels."
        refresh()
    }

    private func capture(_ event: NSEvent) -> Bool {
        guard let id = recording, event.type == .keyDown else { return false }
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            stopRecording()
            return true
        }
        guard let binding = AppShortcuts.binding(for: event) else { return true }
        if let reason = binding.rejectionReason {
            status.stringValue = reason
            NSSound.beep()
            return true
        }
        if let item = CanvasWindowController.menuItem(for: event, in: NSApp.mainMenu),
           !AppShortcuts.actionIDs.contains(item.identifier?.rawValue ?? "") {
            status.stringValue = "This shortcut is used by \(item.title) and cannot be changed here."
            NSSound.beep()
            return true
        }
        let defaultBinding = ShortcutAction.all.first { $0.id == id }?.defaultBinding
        if binding != defaultBinding, let reason = AppShortcuts.systemReservation(for: event) {
            status.stringValue = reason
            NSSound.beep()
            return true
        }
        stopRecording()
        change(binding, for: id)
        return true
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        stopRecording()
        change(nil, for: id)
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let action = ShortcutAction.all.first(where: { $0.id == id }) else { return }
        stopRecording()
        change(action.defaultBinding, for: id, resetting: true)
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        stopRecording()
        var candidate = AppShortcuts.current
        candidate.restoreDefaults()
        save(candidate)
    }

    private func change(_ binding: ShortcutBinding?, for id: String, resetting: Bool = false, swapping: Bool = false) {
        do {
            var candidate = AppShortcuts.current
            if resetting { try candidate.reset(id, swapping: true) }
            else { try candidate.set(binding, for: id, swapping: true) }
            if !swapping, let binding, let conflict = AppShortcuts.current.conflict(for: binding, excluding: id), let window {
                let title = ShortcutAction.all.first { $0.id == id }?.title ?? id
                let alert = NSAlert()
                alert.messageText = "Shortcut already used by \(conflict.title)"
                alert.informativeText = "Swap shortcuts for \(title) and \(conflict.title)? \(conflict.title) will receive \(title)'s previous shortcut."
                alert.addButton(withTitle: "Swap")
                alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn { self?.change(binding, for: id, resetting: resetting, swapping: true) }
                }
                return
            }
            save(candidate)
        } catch { show(error) }
    }

    private func save(_ candidate: KeyboardShortcuts) {
        do {
            try ClientFiles.sync { try store.update { $0.keyboardShortcuts = candidate } }
            AppShortcuts.configure(candidate)
            refresh()
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }
}

final class ShortcutSettingsWindow: NSWindow {
    var capture: ((NSEvent) -> Bool)?
    private var capturedKey: UInt16?

    func captureKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        if capturedKey == event.keyCode {
            if event.type == .keyUp {
                capturedKey = nil
                return true
            }
            if event.isARepeat { return true }
            capturedKey = nil
        }
        guard event.type == .keyDown, capture?(event) == true else { return false }
        capturedKey = event.keyCode
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        captureKeyEvent(event) || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if captureKeyEvent(event) { return }
        super.sendEvent(event)
    }
}

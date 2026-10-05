import AppKit
import CanvasCore

/// A browser tile's own items in its object menu: its profile and its reload on file changes.
extension CanvasView {
    func browserItems(for id: ObjectID, _ browser: BrowserTile) -> [NSMenuItem] {
        guard let object = board.objects[id] else { return [] }
        let reloading = object.props["reloadOnChange"]?.bool == true
        // Local pages only (`LocalPage`); one that has it on can always turn it off.
        let reload = MenuAction.item("Reload When Files Change", enabled: reloading || browser.servedLocally) { [weak self] in
            _ = try? self?.board.update(id, props: .object(["reloadOnChange": reloading ? .null : .bool(true)]))
        }
        reload.state = reloading ? .on : .off
        reload.toolTip = "Reload this page when a file in the board's folder changes (a file page: its folder)"
        return [.separator(), reload, profileItem(for: id, current: BrowserProfile.name(in: object.props))]
    }

    /// Profile ▸ Default, the profiles tiles on this board use, New Profile…: the tile's page
    /// loads again in the chosen profile's cookies and storage.
    private func profileItem(for id: ObjectID, current: String?) -> NSMenuItem {
        let submenu = NSMenu()
        let names = Set(board.objects.values.filter { $0.type == .browser }.compactMap { BrowserProfile.name(in: $0.props) }).sorted()
        for name in [nil] + names.map(Optional.some) {
            let item = MenuAction.item(name ?? "Default") { [weak self] in self?.setProfile(name, of: id) }
            item.state = name == current ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(MenuAction.item("New Profile…") { [weak self] in self?.askForProfile(of: id) })
        let item = NSMenuItem(title: current.map { "Profile (\($0))" } ?? "Profile", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func setProfile(_ name: String?, of id: ObjectID) {
        _ = try? board.update(id, props: .object(["profile": name.map(JSONValue.string) ?? .null]))
    }

    /// A sheet asking for the new profile's name (a sheet: the sockets keep answering).
    private func askForProfile(of id: ObjectID) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "New Browser Profile"
        alert.informativeText = "A profile has its own cookies, logins and storage. Every browser tile that uses the same name shares them."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Work"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Use Profile")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return NSSound.beep() }
            self?.setProfile(name, of: id)
        }
    }
}

import AppKit
import CanvasCore
import WebKit

/// Safari web extensions in browser tiles: password managers (Bitwarden, 1Password), blockers, a
/// developer's own unpacked build. WebKit hosts them (`WKWebExtension`, macOS 15.4 and later);
/// easl supplies what a browser would: browser tiles are the extensions' tabs and board windows
/// their windows, the address bar has a button for their actions (a password manager's popup is
/// how it unlocks and fills), and sheets ask the user before an extension gets a permission.
///
/// The user adds one from easl › Browser Extensions › Add Extension… (`BrowserExtensionSource`:
/// an app carrying Safari extensions, an `.appex`, or an unpacked folder). What they added, and
/// what they granted, is kept in `browser-extensions.json` in the easl home and loaded at every
/// launch; WebKit keeps each extension's own storage under the browser profile's controller
/// (`ExtensionHost.controller`), so a development instance with its own profile never shares an
/// extension's storage with the user's app.
///
/// This facade has no availability requirement: before macOS 15.4 its calls do nothing and the
/// menu says what's needed.
@MainActor
enum BrowserExtensions {
    /// What changed about a tab, for the extensions' `tabs.onUpdated`.
    enum TabChange {
        case url, title, loading
    }

    /// Loads the installed extensions; called once at launch, before boards open, so pages that
    /// load with them already get their content scripts.
    static func start() {
        guard #available(macOS 15.4, *) else { return }
        ExtensionHost.shared.loadInstalled()
    }

    /// Every browser tile's web view runs the installed extensions (HTML tiles never do).
    static func attach(to configuration: WKWebViewConfiguration) {
        guard #available(macOS 15.4, *) else { return }
        configuration.webExtensionController = ExtensionHost.shared.controller
    }

    /// The tile is on a board in a window: a tab for the extensions. Repeats are ignored.
    static func opened(_ tile: BrowserTile) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionHost.shared.open(tile)
    }

    /// The tile left its window (deleted, or its canvas went away).
    static func closed(_ tile: BrowserTile) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionHost.shared.close(tile, windowIsClosing: false)
    }

    /// The user acted in the tile's page: it is its window's active tab.
    static func activated(_ tile: BrowserTile) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionHost.shared.activate(tile)
    }

    static func changed(_ tile: BrowserTile, _ change: TabChange) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionHost.shared.changed(tile, change)
    }

    /// The address bar's extensions button: the one extension's action icon, or a puzzle piece
    /// for several; nil (hidden) with none running.
    static func button(for tile: BrowserTile) -> (image: NSImage, label: String)? {
        guard #available(macOS 15.4, *) else { return nil }
        return ExtensionHost.shared.button(for: tile)
    }

    /// The button was clicked: the one extension's action runs (its popup shows under the
    /// button); with several, a menu of them under the button picks one.
    static func buttonClicked(_ tile: BrowserTile, anchor: NSView) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionHost.shared.buttonClicked(tile, anchor: anchor)
    }

    /// easl › Browser Extensions: the installed extensions (enable, options, remove) and Add
    /// Extension…, filled each time it opens.
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Browser Extensions", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Browser Extensions")
        menu.delegate = ExtensionsMenu.shared
        item.submenu = menu
        return item
    }
}

/// Fills easl › Browser Extensions as it opens.
@MainActor
private final class ExtensionsMenu: NSObject, NSMenuDelegate {
    static let shared = ExtensionsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard #available(macOS 15.4, *) else {
            let item = NSMenuItem(title: "Needs macOS 15.4 or later", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }
        ExtensionHost.shared.fill(menu)
    }
}

/// One `WKWebExtensionController` for the app, the extensions it runs, and the tabs and windows
/// it shows them.
@available(macOS 15.4, *)
@MainActor
final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    static let shared = ExtensionHost()

    /// Persistent: extensions keep their storage (a password manager's vault cache, its
    /// settings) across launches. Its identifier follows the browser profile's (`BrowserProfile`):
    /// the default location for the user's app, one named by the home for an instance with its
    /// own profile. Extensions read cookies from the same store the tiles use.
    let controller: WKWebExtensionController
    private let store = BrowserExtensionList.Store(url: AppPaths.support.appendingPathComponent("browser-extensions.json"))
    private var list = BrowserExtensionList()
    /// Loaded extensions by entry id, and why the others didn't load.
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var problems: [String: String] = [:]
    /// One tab per browser tile in a window, one window per board window, as handed to WebKit
    /// (it keeps them weakly and asks them everything).
    private var tabs: [ObjectIdentifier: ExtensionTab] = [:]
    private var windows: [ObjectIdentifier: ExtensionWindow] = [:]
    /// Extension pages shown in their own window (options, a tab an extension opens on itself).
    private var pageWindows: [NSWindow] = []

    private override init() {
        let configuration: WKWebExtensionController.Configuration = ProcessInfo.processInfo.environment["EASL_BROWSER_PROFILE"] == "own"
            ? .init(identifier: BrowserProfile.identifier(home: AppPaths.support)) : .default()
        configuration.defaultWebsiteDataStore = BrowserProfile.store
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        for name in [WKWebExtensionContext.permissionsWereGrantedNotification, WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
                     WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification, WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification] {
            center.addObserver(self, selector: #selector(grantsChanged(_:)), name: name, object: nil)
        }
    }

    // MARK: Installed extensions

    func loadInstalled() {
        list = store.load()
        // Entries written by hand get their ids now, so their storage stays theirs.
        save()
        for entry in list.extensions where entry.enabled {
            Task { await load(entry) }
        }
    }

    private func save() {
        do { try store.save(list) } catch { NSLog("easl: cannot save browser extensions: %@", "\(error)") }
    }

    /// Loads one extension. An entry the user hasn't reviewed shows what it asks for first and
    /// loads only once they agree; declining a new one forgets it.
    private func load(_ entry: BrowserExtensionList.Entry) async {
        guard contexts[entry.id] == nil else { return }
        let url = URL(fileURLWithPath: entry.path)
        let context: WKWebExtensionContext
        do {
            let webExtension: WKWebExtension
            if url.pathExtension == "appex" {
                guard let bundle = Bundle(url: url) else { throw BrowserExtensionSource.Failure(message: "\(url.lastPathComponent) isn't a readable bundle") }
                webExtension = try await WKWebExtension(appExtensionBundle: bundle)
            } else {
                webExtension = try await WKWebExtension(resourceBaseURL: url)
            }
            context = WKWebExtensionContext(for: webExtension)
        } catch {
            fail(entry, Self.describe(error))
            return
        }
        // Stable identity: the extension's storage, its `runtime.id`, and its pages' origin.
        context.uniqueIdentifier = entry.id
        if var base = URLComponents(url: context.baseURL, resolvingAgainstBaseURL: false) {
            base.host = entry.id.lowercased()
            base.path = "/"
            if let stable = base.url { context.baseURL = stable }
        }
        // Like the tiles' pages (`isInspectable`): Develop › easl in Safari reaches its pages.
        context.isInspectable = true
        context.inspectionName = context.webExtension.displayName
        var current = entry
        if !entry.reviewed {
            guard let window = CanvasWindowController.frontmost?.window else {
                fail(entry, "waiting for a board window to ask about its permissions")
                return
            }
            guard await review(context, in: window) else {
                if contexts[entry.id] == nil { list.remove(entry.id) }
                save()
                return
            }
            current.reviewed = true
            current.permissions = context.webExtension.requestedPermissions.map(\.rawValue).sorted()
            current.sites = Self.requestedSites(context.webExtension).map(\.string).sorted()
            list.update(entry.id) { $0 = current }
            save()
        }
        context.grantedPermissions = Dictionary(uniqueKeysWithValues: Set(current.permissions).map { (WKWebExtension.Permission(rawValue: $0), Date.distantFuture) })
        context.grantedPermissionMatchPatterns = Dictionary(current.sites.compactMap { try? WKWebExtension.MatchPattern(string: $0) }.map { ($0, Date.distantFuture) },
                                                            uniquingKeysWith: { first, _ in first })
        do {
            try controller.load(context)
        } catch {
            fail(entry, Self.describe(error))
            return
        }
        contexts[entry.id] = context
        problems[entry.id] = nil
        if let name = context.webExtension.displayName, name != current.name {
            list.update(entry.id) { $0.name = name }
            save()
        }
        for error in context.webExtension.errors { NSLog("easl: browser extension %@: %@", entry.path, error.localizedDescription) }
        NSLog("easl: loaded browser extension %@ (%@) from %@", context.webExtension.displayName ?? "?", entry.id, entry.path)
        refreshButtons()
    }

    private func fail(_ entry: BrowserExtensionList.Entry, _ problem: String) {
        problems[entry.id] = problem
        NSLog("easl: browser extension %@ didn't load: %@", entry.path, problem)
    }

    private static func describe(_ error: Error) -> String {
        (error as? BrowserExtensionSource.Failure)?.message ?? error.localizedDescription
    }

    /// The sites an extension needs for what it does: its host permissions and where its
    /// content scripts run (optional ones it asks for later, `promptForPermissionMatchPatterns`).
    private static func requestedSites(_ webExtension: WKWebExtension) -> Set<WKWebExtension.MatchPattern> {
        webExtension.requestedPermissionMatchPatterns.union(webExtension.allRequestedMatchPatterns)
    }

    /// The install sheet: the extension's name, what it may do and where it runs; Add grants
    /// all of it.
    private func review(_ context: WKWebExtensionContext, in window: NSWindow) async -> Bool {
        let webExtension = context.webExtension
        let name = webExtension.displayName ?? "this extension"
        var lines: [String] = []
        if let description = webExtension.displayDescription, !description.isEmpty { lines.append(description) }
        let permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
        lines.append(permissions.isEmpty ? "It asks for no browser permissions." : "It can use: " + permissions.joined(separator: ", ") + ".")
        let sites = Self.sitesText(Self.requestedSites(webExtension))
        lines.append(sites.isEmpty ? "It runs on no websites." : "It can read and change: " + sites + ".")
        return await ask(in: window, title: "Add “\(name)” to browser tiles?", detail: lines.joined(separator: "\n\n"), confirm: "Add",
                         icon: webExtension.icon(for: NSSize(width: 64, height: 64)))
    }

    private static func sitesText(_ patterns: some Collection<WKWebExtension.MatchPattern>) -> String {
        if patterns.contains(where: { $0.matchesAllURLs || $0.matchesAllHosts }) { return "every website" }
        return patterns.map(\.string).sorted().joined(separator: ", ")
    }

    /// A sheet (an app-modal alert would stall every socket request until answered).
    private func ask(in window: NSWindow, title: String, detail: String, confirm: String, icon: NSImage? = nil) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        if let icon { alert.icon = icon }
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    /// WebKit changed what an extension may do (the user's answer to a prompt, the extension's
    /// own `permissions.remove`): the list keeps it for the next launch.
    @objc private func grantsChanged(_ note: Notification) {
        guard let context = note.object as? WKWebExtensionContext, contexts[context.uniqueIdentifier] === context else { return }
        let permissions = context.grantedPermissions.keys.map(\.rawValue).sorted()
        let sites = context.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
        list.update(context.uniqueIdentifier) {
            $0.permissions = permissions
            $0.sites = sites
        }
        save()
    }

    /// Add Extension…: an app, `.appex` or folder from an open panel (a sheet), each Safari web
    /// extension in it added and reviewed.
    @objc func addExtension(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Extension"
        panel.message = "Choose an app with a Safari web extension (like Bitwarden), an .appex, or a folder with a manifest.json."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let chosen: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            guard response == .OK, let url = panel.url else { return }
            self?.install(url)
        }
        if let window = CanvasWindowController.frontmost?.window {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
    }

    private func install(_ url: URL) {
        let sources: [BrowserExtensionSource]
        do {
            sources = try BrowserExtensionSource.resolve(url)
        } catch {
            return notify(Self.describe(error))
        }
        for source in sources {
            let entry = list.add(path: source.url.path)
            save()
            // Already running (picked again): nothing to load.
            if contexts[entry.id] != nil { continue }
            Task {
                await load(entry)
                if let problem = problems[entry.id] { notify("\(source.url.lastPathComponent) didn't load: \(problem)") }
            }
        }
    }

    private func notify(_ message: String) {
        NSLog("easl: %@", message)
        CanvasWindowController.frontmost?.canvas.showNotice(message)
    }

    private func setEnabled(_ id: String, _ enabled: Bool) {
        list.update(id) { $0.enabled = enabled }
        save()
        if enabled {
            guard let entry = list.extensions.first(where: { $0.id == id }) else { return }
            Task { await load(entry) }
        } else {
            unload(id)
        }
    }

    private func unload(_ id: String) {
        problems[id] = nil
        guard let context = contexts.removeValue(forKey: id) else { return }
        do { try controller.unload(context) } catch { NSLog("easl: unloading browser extension %@: %@", id, "\(error)") }
        refreshButtons()
    }

    /// Remove…: after a sheet, the extension stops and its storage (logins it kept, settings) goes.
    private func remove(_ id: String) {
        guard let entry = list.extensions.first(where: { $0.id == id }), let window = CanvasWindowController.frontmost?.window else { return }
        let name = contexts[id]?.webExtension.displayName ?? Self.name(of: entry)
        Task {
            guard await ask(in: window, title: "Remove “\(name)”?", detail: "It stops running in browser tiles, and what it stored in easl (its settings, a signed-in vault) is deleted. The extension's app stays installed.", confirm: "Remove") else { return }
            let context = contexts[id]
            unload(id)
            list.remove(id)
            save()
            guard let context else { return }
            let types = WKWebExtensionController.allExtensionDataTypes
            if let record = await controller.dataRecord(ofTypes: types, for: context) {
                await withCheckedContinuation { continuation in
                    controller.removeData(ofTypes: types, from: [record]) { continuation.resume() }
                }
            }
            NSLog("easl: removed browser extension %@", entry.path)
        }
    }

    /// The name it last loaded with, else its file's.
    private static func name(of entry: BrowserExtensionList.Entry) -> String {
        entry.name ?? URL(fileURLWithPath: entry.path).deletingPathExtension().lastPathComponent
    }

    // MARK: Menu

    func fill(_ menu: NSMenu) {
        for entry in list.extensions {
            let context = contexts[entry.id]
            let item = NSMenuItem(title: context?.webExtension.displayName ?? Self.name(of: entry), action: nil, keyEquivalent: "")
            item.image = context?.webExtension.icon(for: NSSize(width: 16, height: 16))
            item.toolTip = entry.path
            let submenu = NSMenu(title: item.title)
            if entry.enabled, let problem = problems[entry.id] {
                let note = NSMenuItem(title: "Not running: \(problem)", action: nil, keyEquivalent: "")
                note.isEnabled = false
                submenu.addItem(note)
            }
            let enabled = action("Enabled", #selector(toggleEnabled(_:)), entry.id)
            enabled.state = entry.enabled ? .on : .off
            submenu.addItem(enabled)
            if let context, context.webExtension.hasOptionsPage {
                submenu.addItem(action("Options…", #selector(showOptions(_:)), entry.id))
            }
            submenu.addItem(.separator())
            submenu.addItem(action("Remove…", #selector(removeItem(_:)), entry.id))
            item.submenu = submenu
            menu.addItem(item)
        }
        if !list.extensions.isEmpty { menu.addItem(.separator()) }
        let add = NSMenuItem(title: "Add Extension…", action: #selector(addExtension(_:)), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
    }

    private func action(_ title: String, _ selector: Selector, _ id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let entry = list.extensions.first(where: { $0.id == id }) else { return }
        setEnabled(id, !entry.enabled)
    }

    @objc private func showOptions(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let context = contexts[id] else { return }
        openOptions(context)
    }

    @objc private func removeItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        remove(id)
    }

    // MARK: Tabs and windows

    func open(_ tile: BrowserTile) {
        guard tabs[ObjectIdentifier(tile)] == nil, let window = window(of: tile) else { return }
        let tab = ExtensionTab(tile: tile)
        tabs[ObjectIdentifier(tile)] = tab
        controller.didOpenTab(tab)
        if window.active == nil { activate(tile) }
        tile.extensionsChanged()
    }

    func close(_ tile: BrowserTile, windowIsClosing: Bool) {
        guard let tab = tabs.removeValue(forKey: ObjectIdentifier(tile)) else { return }
        for window in windows.values where window.active === tab { window.active = nil }
        controller.didCloseTab(tab, windowIsClosing: windowIsClosing)
    }

    func activate(_ tile: BrowserTile) {
        guard let tab = tabs[ObjectIdentifier(tile)], let window = window(of: tile), window.active !== tab else { return }
        let previous = window.active
        window.active = tab
        controller.didActivateTab(tab, previousActiveTab: previous)
    }

    func changed(_ tile: BrowserTile, _ change: BrowserExtensions.TabChange) {
        guard let tab = tabs[ObjectIdentifier(tile)] else { return }
        let properties: WKWebExtension.TabChangedProperties = switch change {
        case .url: .URL
        case .title: .title
        case .loading: .loading
        }
        controller.didChangeTabProperties(properties, for: tab)
    }

    func tab(for tile: BrowserTile) -> ExtensionTab? { tabs[ObjectIdentifier(tile)] }

    /// The board window's adapter, made (and announced) the first time it's needed.
    func window(of tile: BrowserTile) -> ExtensionWindow? {
        (tile.window?.windowController as? CanvasWindowController).map(window(for:))
    }

    func window(for board: CanvasWindowController) -> ExtensionWindow {
        if let window = windows[ObjectIdentifier(board)] { return window }
        let window = ExtensionWindow(board: board)
        windows[ObjectIdentifier(board)] = window
        controller.didOpenWindow(window)
        return window
    }

    /// The window's browser tiles that are tabs, in a stable order (by object id: a tile keeps
    /// its index while others move around the board).
    func tabs(in window: ExtensionWindow) -> [ExtensionTab] {
        guard let canvas = window.board?.canvas else { return [] }
        return canvas.tiles.keys.sorted().compactMap { id in
            (canvas.tiles[id]?.content as? BrowserTile).flatMap { tabs[ObjectIdentifier($0)] }
        }
    }

    /// Board windows front to back, the one the user is on first.
    private var boardWindows: [ExtensionWindow] {
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? CanvasWindowController }
        let front = CanvasWindowController.frontmost
        return ([front].compactMap { $0 } + ordered.filter { $0 !== front }).map(window(for:))
    }

    @objc private func windowWillClose(_ note: Notification) {
        pageWindows.removeAll { $0 === note.object as? NSWindow }
        guard let board = (note.object as? NSWindow)?.windowController as? CanvasWindowController,
              let window = windows.removeValue(forKey: ObjectIdentifier(board)) else { return }
        for (key, tab) in tabs where tab.tile?.window === board.window {
            tabs[key] = nil
            controller.didCloseTab(tab, windowIsClosing: true)
        }
        controller.didCloseWindow(window)
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard let board = (note.object as? NSWindow)?.windowController as? CanvasWindowController else { return }
        controller.didFocusWindow(window(for: board))
    }

    /// The tile is selected on its board, or its page or address bar has the keyboard.
    func isSelected(_ tile: BrowserTile) -> Bool {
        if let responder = tile.window?.firstResponder as? NSView, responder.isDescendant(of: tile) { return true }
        return sequence(first: tile.superview, next: { $0?.superview }).lazy.compactMap { $0 as? TileFrameView }.first?.isSelected ?? false
    }

    // MARK: The address bar's button

    private var running: [WKWebExtensionContext] {
        contexts.values.sorted { ($0.webExtension.displayName ?? "") < ($1.webExtension.displayName ?? "") }
    }

    func button(for tile: BrowserTile) -> (image: NSImage, label: String)? {
        let running = running
        guard !running.isEmpty else { return nil }
        let puzzle = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Extensions") ?? NSImage()
        guard running.count == 1, let context = running.first else { return (puzzle, "Extensions") }
        let action = context.action(for: tab(for: tile))
        let image = action?.icon(for: NSSize(width: 16, height: 16)) ?? context.webExtension.actionIcon(for: NSSize(width: 16, height: 16)) ?? puzzle
        // The action's badge (a password manager's count of logins for the page) in the label.
        let label = action?.label ?? context.webExtension.displayName ?? "Extension"
        let badge = action?.badgeText ?? ""
        return (image, badge.isEmpty ? label : "\(label) (\(badge))")
    }

    private func refreshButtons() {
        for tab in tabs.values { tab.tile?.extensionsChanged() }
    }

    func buttonClicked(_ tile: BrowserTile, anchor: NSView) {
        let running = running
        if running.count == 1, let context = running.first { return perform(context, in: tile) }
        let menu = NSMenu()
        for context in running {
            // By the extension's name: two actions can share a label ("Fill", "Open").
            let action = context.action(for: tab(for: tile))
            let item = NSMenuItem(title: context.webExtension.displayName ?? action?.label ?? "Extension", action: #selector(performFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.image = action?.icon(for: NSSize(width: 16, height: 16)) ?? context.webExtension.actionIcon(for: NSSize(width: 16, height: 16))
            if let badge = action?.badgeText, !badge.isEmpty { item.badge = NSMenuItemBadge(string: badge) }
            item.representedObject = (context, tile) as (WKWebExtensionContext, BrowserTile)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func performFromMenu(_ sender: NSMenuItem) {
        guard let (context, tile) = sender.representedObject as? (WKWebExtensionContext, BrowserTile) else { return }
        perform(context, in: tile)
    }

    /// Clicking an extension's action is the user choosing this tab: it becomes active (the
    /// popup's `tabs.query({active: true})` finds it) and the action runs with a user gesture
    /// (`activeTab`); WebKit then asks to present its popup (`presentActionPopup`).
    private func perform(_ context: WKWebExtensionContext, in tile: BrowserTile) {
        activate(tile)
        context.performAction(for: tab(for: tile))
    }

    // MARK: Extension pages

    /// An extension's own page (options, a page it opens on itself) in a window of its own,
    /// built from the extension's web view configuration, which is where WebKit gives a page
    /// the extension's APIs.
    private func showPage(_ url: URL, of context: WKWebExtensionContext, title: String) {
        guard let configuration = context.webViewConfiguration else { return }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 560), configuration: configuration)
        webView.isInspectable = true
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentView = webView
        window.center()
        pageWindows.append(window)
        webView.load(URLRequest(url: url))
        window.orderFront(nil)
    }

    private func openOptions(_ context: WKWebExtensionContext) {
        guard let url = context.optionsPageURL else { return }
        showPage(url, of: context, title: "\(context.webExtension.displayName ?? "Extension") Options")
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        boardWindows
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        CanvasWindowController.frontmost.map(window(for:))
    }

    /// `tabs.create`: a browser tile beside the tab it came from (else the window's active tab,
    /// else in view), selected when it should be active. An extension's own page opens in its
    /// own window instead (`showPage`), so no tab comes back for it.
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        if let url = configuration.url, url.scheme == extensionContext.baseURL.scheme {
            showPage(url, of: extensionContext, title: extensionContext.webExtension.displayName ?? "Extension")
            return completionHandler(nil, nil)
        }
        guard let window = (configuration.window as? ExtensionWindow) ?? CanvasWindowController.frontmost.map(window(for:)),
              let canvas = window.board?.canvas else {
            return completionHandler(nil, BrowserExtensionSource.Failure(message: "no board window is open"))
        }
        let anchor = (configuration.parentTab as? ExtensionTab)?.tile?.objectID ?? window.active?.tile?.objectID
        let size = Board.defaultSize(.browser)
        let object = canvas.board.create(type: .browser, props: .object(["url": .string(configuration.url?.absoluteString ?? "about:blank")]),
                                         frame: canvas.board.place(width: size.w, height: size.h, near: anchor))
        if configuration.shouldBeActive { canvas.showNew(object) }
        guard let tile = canvas.tiles[object.id]?.content as? BrowserTile else { return completionHandler(nil, nil) }
        open(tile)
        if configuration.shouldBeActive { activate(tile) }
        completionHandler(tab(for: tile), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        openOptions(extensionContext)
        completionHandler(nil)
    }

    /// The action's popup, under the tile's extensions button (or its address bar, the button
    /// hidden), in WebKit's own popover around the popup's web view.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        let tile = (action.associatedTab as? ExtensionTab)?.tile
            ?? CanvasWindowController.frontmost.flatMap { window(for: $0).active?.tile }
        guard let tile, let popover = action.popupPopover else {
            return completionHandler(BrowserExtensionSource.Failure(message: "no browser tile to show the popup on"))
        }
        let anchor = tile.extensionsAnchor
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        if let tile = (action.associatedTab as? ExtensionTab)?.tile { tile.extensionsChanged() } else { refreshButtons() }
    }

    /// An extension asking for more than it was installed with (`permissions.request`, a site
    /// it needs now): a sheet on the tab's window says what, and Allow grants all of it.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        prompt(extensionContext, tab: tab, detail: "It asks to use: \(names).") { completionHandler($0 ? permissions : [], nil) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.map { $0.host ?? $0.absoluteString }).sorted().joined(separator: ", ")
        prompt(extensionContext, tab: tab, detail: "It asks to read and change: \(hosts).") { completionHandler($0 ? urls : [], nil) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        prompt(extensionContext, tab: tab, detail: "It asks to read and change: \(Self.sitesText(matchPatterns)).") { completionHandler($0 ? matchPatterns : [], nil) }
    }

    private func prompt(_ context: WKWebExtensionContext, tab: (any WKWebExtensionTab)?, detail: String, answer: @escaping (Bool) -> Void) {
        guard let window = (tab as? ExtensionTab)?.tile?.window ?? CanvasWindowController.frontmost?.window else { return answer(false) }
        let name = context.webExtension.displayName ?? "An extension"
        Task { answer(await ask(in: window, title: "Allow “\(name)” more access?", detail: detail, confirm: "Allow",
                                icon: context.webExtension.icon(for: NSSize(width: 64, height: 64)))) }
    }
}

/// A browser tile as the extensions' tab. It holds the tile weakly: the tile's lifecycle opens
/// and closes the tab (`BrowserExtensions.opened`/`closed`).
@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tile: BrowserTile?

    init(tile: BrowserTile) {
        self.tile = tile
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        tile.flatMap { ExtensionHost.shared.window(of: $0) }
    }

    /// Nil while the page is released (`BrowserTile.release`); it comes back from `props.url`.
    func webView(for context: WKWebExtensionContext) -> WKWebView? { tile?.webView }

    func title(for context: WKWebExtensionContext) -> String? {
        tile?.webView?.title ?? tile?.object.props["pageTitle"]?.string
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tile?.pageURL.flatMap(URL.init(string:))
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        tile?.webView?.isLoading != true
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        tile.map { ExtensionHost.shared.isSelected($0) } ?? false
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let tile else { return completionHandler(nil) }
        tile.credit.user()
        tile.load(url.absoluteString)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tile?.credit.user()
        tile?.reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tile?.credit.user()
        tile?.webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tile?.credit.user()
        tile?.webView?.goForward()
        completionHandler(nil)
    }

    /// `tabs.update({active: true})`: the board shows and selects the tile.
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let tile, let canvas = (tile.window?.windowController as? CanvasWindowController)?.canvas else { return completionHandler(nil) }
        canvas.reveal(tile.objectID)
        canvas.setSelection([tile.objectID])
        ExtensionHost.shared.activate(tile)
        completionHandler(nil)
    }

    /// `tabs.remove`: the tile closes as the user's ⌫ closes it (undoable).
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let tile, let canvas = (tile.window?.windowController as? CanvasWindowController)?.canvas else { return completionHandler(nil) }
        canvas.delete([tile.objectID])
        completionHandler(nil)
    }
}

/// A board window as the extensions' window: its browser tiles are its tabs.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var board: CanvasWindowController?
    /// The tab the user last acted in (`ExtensionHost.activate`).
    weak var active: ExtensionTab?

    init(board: CanvasWindowController) {
        self.board = board
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        ExtensionHost.shared.tabs(in: self)
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        active ?? ExtensionHost.shared.tabs(in: self).first
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = board?.window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect { board?.window?.frame ?? .null }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect { board?.window?.screen?.frame ?? .null }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let window = board?.window {
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        completionHandler(nil)
    }
}

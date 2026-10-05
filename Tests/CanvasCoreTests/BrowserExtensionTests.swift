import Foundation
import Testing
@testable import CanvasCore

/// easl › Browser Extensions › Add Extension…: what the user picks resolves to the Safari web
/// extensions WebKit can load, and the installed list keeps one entry per extension.
struct BrowserExtensionTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-ext-\(UUID().uuidString)", isDirectory: true)

    /// An app extension bundle declaring `point` in its Info.plist.
    func appex(_ url: URL, point: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "test.\(url.deletingPathExtension().lastPathComponent)",
                                  "NSExtension": ["NSExtensionPointIdentifier": point]]
        #expect(info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
    }

    @Test func anAppGivesItsSafariWebExtensionsOnly() throws {
        // A password manager's app: its Safari extension beside a share extension.
        let app = root.appendingPathComponent("Vault.app", isDirectory: true)
        let plugIns = app.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        try appex(plugIns.appendingPathComponent("Share.appex"), point: "com.apple.share-services")
        try appex(plugIns.appendingPathComponent("Safari.appex"), point: BrowserExtensionSource.safariExtensionPoint)
        let found = try BrowserExtensionSource.resolve(app)
        #expect(found.map { $0.url.resolvingSymlinksInPath().path } == [plugIns.appendingPathComponent("Safari.appex").resolvingSymlinksInPath().path])
        guard case .appExtension = found.first else { Issue.record("not an app extension: \(found)"); return }
        #expect(throws: BrowserExtensionSource.Failure.self) { try BrowserExtensionSource.resolve(plugIns.appendingPathComponent("Share.appex")) }
    }

    @Test func anAppWithoutOneSaysSo() throws {
        let app = root.appendingPathComponent("Notes.app", isDirectory: true)
        try appex(app.appendingPathComponent("Contents/PlugIns/Widget.appex"), point: "com.apple.widgetkit-extension")
        #expect(throws: BrowserExtensionSource.Failure(message: "Notes.app doesn't contain a Safari web extension.")) {
            try BrowserExtensionSource.resolve(app)
        }
    }

    @Test func aFolderNeedsItsManifest() throws {
        let folder = root.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: BrowserExtensionSource.Failure.self) { try BrowserExtensionSource.resolve(folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        #expect(try BrowserExtensionSource.resolve(folder) == [.folder(folder)])
    }

    @Test func addingTheSameExtensionAgainReenablesItAndKeepsItsIdentity() throws {
        let store = BrowserExtensionList.Store(url: root.appendingPathComponent("browser-extensions.json"))
        // No file yet, or one that isn't a list: nothing installed.
        #expect(store.load() == BrowserExtensionList())
        var list = store.load()
        let first = list.add(path: "/Applications/Vault.app/Contents/PlugIns/Safari.appex")
        list.update(first.id) { $0.enabled = false; $0.reviewed = true }
        try store.save(list)
        var loaded = store.load()
        let again = loaded.add(path: "/Applications/Vault.app/Contents/PlugIns/../PlugIns/Safari.appex")
        #expect(loaded.extensions.count == 1)
        #expect(again.id == first.id && again.enabled && again.reviewed)
        loaded.remove(first.id)
        #expect(loaded.extensions.isEmpty)
    }
}

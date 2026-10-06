import AppKit
import CanvasCore
import UniformTypeIdentifiers

/// Sharing what's on the board: the selection as a picture (drawn by `view.render` as View ›
/// Hide Board Chrome shows it), an HTML tile as a self-contained page, and a note as its
/// markdown.
extension CanvasView {
    /// Pixels per canvas point for exported pictures: sharp on Retina screens and in documents.
    static let exportScale = 2.0

    /// The selection drawn offscreen (tiles, drawings, groups under it) as PNG, without canvas
    /// chrome (`RenderRequest.chrome`: no author marks, close buttons, dot grid or selection),
    /// since it leaves the app; with the groups whose members are all selected
    /// (`SelectionScope.export`), so their titles and borders aren't cut; at a scale that keeps
    /// its longest side within `ExportFile.maxPixels`.
    private func selectionPNG() async throws -> Data {
        guard !selection.isEmpty else { throw ExportFailure("nothing is selected") }
        let ids = SelectionScope.export(selection: selection, groups: selectionGroups).sorted()
        let bounds = RenderMath.union(ids.compactMap { outline(of: $0) })
        let scale = bounds.map { ExportFile.scale(Self.exportScale, for: CGSize(width: $0.w, height: $0.h)) } ?? Self.exportScale
        return try await render(RenderRequest(target: .objects(ids), scale: scale, padding: 0, chrome: false), format: .png).image
    }

    private var selectionGroups: [SelectionScope.Group] {
        board.objects.values.compactMap { object in
            object.type == .group ? GroupSpec(object.props).map { SelectionScope.Group(id: object.id, members: $0.members) } : nil
        }
    }

    /// A file name for the selection: the title of the one object, or of the one group holding
    /// it (a marquee around a group: `SelectionScope.namesake`), else "easl selection"
    /// (`ExportFile.name`).
    private func exportName(_ ext: String) -> String {
        let drawn = Set(selection.filter { [.shape, .arrow].contains(board.objects[$0]?.type) })
        let namesake = SelectionScope.namesake(selection: selection, groups: selectionGroups, drawn: drawn)
        var title = namesake.flatMap { board.objects[$0] }.map { $0.type == .group ? $0.props["title"]?.string ?? "" : TileFrameView.title(for: $0) }
        // An image tile's title is its file name: `chart.png` saves as `chart.png`, not
        // `chart.png.png`; so is a page or a note titled `report.html` or `notes.md`.
        if let name = title, case let known = (name as NSString).pathExtension.lowercased(), LocalImage.extensions.contains(known) || ["html", "md"].contains(known) {
            title = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return ExportFile.name(title, ext: ext)
    }

    private static let exportDirectoryKey = "canvas.exportDirectory"

    /// An export through a save sheet: named for the selection, opening in the folder the user
    /// last saved one into, else Downloads, never the board's directory (`ExportFile.directory`);
    /// then `contents`, made once the user chose where (nil: nothing left to save), written there.
    /// `action` names the export in a failure's sheet, `what` the saved thing in the log.
    private func saveExport(_ action: String, _ type: UTType, ext: String, logging what: String, _ contents: @escaping @MainActor () async throws -> Data?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = exportName(ext)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let last = UserDefaults.standard.string(forKey: Self.exportDirectoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        panel.directoryURL = ExportFile.directory(lastUsed: last, boardRoot: board.root, downloads: downloads) { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
        panel.beginSheetModal(for: window) { [weak self, panel] response in
            guard let self, response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.exportDirectoryKey)
            Task { @MainActor in
                do {
                    guard let data = try await contents() else { return }
                    try await Self.write(data, to: url)
                    NSLog("easl: saved %@ as %@", what, url.path)
                } catch {
                    self.exportFailed(action, error)
                }
            }
        }
    }

    /// Copy as Image: PNG (and TIFF, for apps that only read that) on the general pasteboard.
    func copySelectionAsImage() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let png = try await self.selectionPNG()
                let pasteboard = NSPasteboard.general
                pasteboard.clear(privately: self.board.isRemote)
                pasteboard.addTypes([.png, .tiff], owner: nil)
                pasteboard.setData(png, forType: .png)
                if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
                NSLog("easl: copied %d object(s) as a %d-byte PNG", self.selection.count, png.count)
            } catch {
                self.exportFailed("Copy as Image", error)
            }
        }
    }

    /// Save as PNG…: a save sheet on the window, then the same picture as Copy as Image.
    func saveSelectionAsPNG() {
        saveExport("Save as PNG", .png, ext: "png", logging: "the selection") { [weak self] in try await self?.selectionPNG() }
    }

    /// Save as HTML…: the HTML tile's page as it renders, in one file (`HtmlTile.exportDocument`).
    func saveHTML(_ id: ObjectID) {
        guard let tile = tiles[id]?.content as? HtmlTile else { return }
        saveExport("Save as HTML", .html, ext: "html", logging: "HTML tile \(id)") { Data(try await tile.exportDocument().utf8) }
    }

    /// Open in Browser: the exported page in the temp directory, opened by the default browser.
    /// A development instance that may not activate other apps (`EASL_NO_ACTIVATE`) only logs
    /// the file it would open.
    func openHTMLInBrowser(_ id: ObjectID) {
        guard let tile = tiles[id]?.content as? HtmlTile else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("easl-exports", isDirectory: true)
        let url = directory.appendingPathComponent("\(id)-\(exportName("html"))")
        Task { @MainActor [weak self] in
            do {
                let html = try await tile.exportDocument()
                try await Self.write(Data(html.utf8), to: url)
                if CanvasApplication.neverActivate {
                    NSLog("easl: Open in Browser would open %@ (EASL_NO_ACTIVATE)", url.absoluteString)
                } else {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                self?.exportFailed("Open in Browser", error)
            }
        }
    }

    /// Open in Browser on a browser tile: its page's address in the user's default browser (a
    /// `file:` page too, which the file's own default app might not show as a page). A
    /// development instance that may not activate other apps (`EASL_NO_ACTIVATE`) only logs it.
    func openPageInBrowser(_ id: ObjectID) {
        guard let url = (tiles[id]?.content as? BrowserTile)?.webAddress else { return }
        if CanvasApplication.neverActivate {
            return NSLog("easl: Open in Browser would open %@ (EASL_NO_ACTIVATE)", url.absoluteString)
        }
        guard url.isFileURL, let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Markdown files (`.md`), as the save sheet offers them.
    private static let markdownType = UTType("net.daringfireball.markdown") ?? .plainText

    /// The note's markdown as stored (what `object.get` returns: links, excerpt fences and their
    /// anchors as written), not its rendering.
    private func noteMarkdown(_ id: ObjectID) -> String? {
        guard let note = board.objects[id], note.type == .note else { return nil }
        return note.props["markdown"]?.string ?? ""
    }

    /// Copy as Markdown (a note's menu, Edit › Copy Note as Markdown): the note's markdown as
    /// plain text on the general pasteboard, for a doc, an incident or a chat.
    func copyNoteMarkdown(_ id: ObjectID) {
        guard let markdown = noteMarkdown(id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clear(privately: board.isRemote)
        pasteboard.setString(markdown, forType: .string)
        NSLog("easl: copied note %@ as %d characters of markdown", id, markdown.count)
    }

    /// Save as Markdown… (a note's menu, File › Save Note as Markdown…): the same text in a
    /// `.md` file named after the note, through the export save sheet.
    func saveNoteMarkdown(_ id: ObjectID) {
        guard noteMarkdown(id) != nil else { return }
        saveExport("Save as Markdown", Self.markdownType, ext: "md", logging: "note \(id)") { [weak self] in self?.noteMarkdown(id).map { Data($0.utf8) } }
    }

    /// Snapshot to Image (a browser tile's menu, File › Snapshot Page to Image): the page as it
    /// shows now, frozen as an image tile beside the browser tile at its width, titled with the
    /// page's title and the time and captioned with its address. The PNG is kept with the board
    /// (`AppPaths.pageSnapshots`), never in the temp directory: a before/after pair stays true
    /// after the page changes. Nothing moves and the keyboard stays where it was (a page being
    /// played keeps it); an image that lands out of view gets a notice saying where it is.
    func snapshotPage(_ id: ObjectID) {
        guard let browser = tiles[id]?.content as? BrowserTile, let source = board.objects[id] else { return }
        let taken = Date()
        Task { @MainActor [weak self] in
            do {
                guard let page = await browser.pageImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let png = await offPool({ Self.encode(page, format: .png) }) else { throw ExportFailure("The page has nothing to show yet.") }
                guard let self else { return }
                let stamp = DateFormatter()
                stamp.locale = Locale(identifier: "en_US_POSIX")
                stamp.dateFormat = "yyyyMMdd-HHmmss"
                let url = AppPaths.pageSnapshots(of: self.board.id).appendingPathComponent("\(id)-\(stamp.string(from: taken)).png")
                try await Self.write(png, to: url)
                var props: [String: JSONValue] = [
                    "path": .string(url.path),
                    "title": .string("\(TileFrameView.title(for: source)) · \(DateFormatter.localizedString(from: taken, dateStyle: .none, timeStyle: .short))"),
                ]
                if let address = browser.pageURL, !address.isEmpty { props["caption"] = .string(address) }
                let size = try await ObjectMeasure.size(type: .image, props: .object(props), width: source.frame.w, root: self.board.root)
                let image = self.board.create(type: .image, props: .object(props), frame: self.board.place(width: Double(size.width), height: Double(size.height), near: id))
                if let whereabouts = self.outOfView(image.id) { self.showNotice("Snapshot saved as an image \(whereabouts)") }
                NSLog("easl: snapshot of %@ saved as %@", id, url.path)
            } catch {
                self?.exportFailed("Snapshot to Image", error)
            }
        }
    }

    private static func write(_ data: Data, to url: URL) async throws {
        try await offPool {
            Result { () throws -> Void in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        }.get()
    }

    /// A sheet saying what failed; never app-modal.
    private func exportFailed(_ action: String, _ error: Error) {
        let message = (error as? ExportFailure)?.message ?? (error as? ApiRouter.Failure)?.message ?? error.localizedDescription
        NSLog("easl: %@ failed: %@", action, message)
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "\(action) failed"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}

struct ExportFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension HtmlTile {
    /// The page as one self-contained file, as it renders now: loaded offscreen like a render
    /// (excerpts, Mermaid, and Tailwind settled), then its DOM with images inlined as `data:` URLs,
    /// the kit stylesheet inlined, and scripts dropped (the generated styles, `<canvas-code>` rows
    /// and diagrams are already in the DOM). It opens anywhere: a browser, an email attachment.
    func exportDocument() async throws -> String {
        let (html, reason) = await withOffscreenPage(size: RenderMath.body(of: object), appearance: effectiveAppearance) { web in
            try await web.callAsyncJavaScript(Self.exportScript, arguments: [:], in: nil, contentWorld: .page) as? String
        }
        guard let html = html ?? nil else { throw ExportFailure(reason ?? "the page produced no document") }
        return html
    }

    /// Runs as the body of an async function in the page.
    static let exportScript = """
    const dataURL = async (url) => {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`${response.status}`);
      const blob = await response.blob();
      return await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(blob);
      });
    };
    const images = [...document.querySelectorAll('img')];
    const clone = document.documentElement.cloneNode(true);
    const copies = [...clone.querySelectorAll('img')];
    for (let i = 0; i < copies.length; i++) {
      const source = images[i] && (images[i].currentSrc || images[i].src);
      copies[i].removeAttribute('srcset');
      if (source && !source.startsWith('data:')) {
        try { copies[i].setAttribute('src', await dataURL(source)); } catch (error) {}
      }
    }
    for (const link of [...clone.querySelectorAll('link[rel="stylesheet"]')]) {
      try {
        const style = document.createElement('style');
        style.textContent = await (await fetch(link.href)).text();
        link.replaceWith(style);
      } catch (error) { link.remove(); }
    }
    for (const script of [...clone.querySelectorAll('script')]) script.remove();
    return '<!doctype html>\\n' + clone.outerHTML;
    """
}

extension NSPasteboard {
    /// Empties the pasteboard for a copy. `privately`, for a remote board's content (client mode,
    /// which keeps nothing of it on this Mac): the copy stays off other devices' Universal
    /// Clipboard and carries nspasteboard.org's transient and concealed markers, so clipboard
    /// managers keep no history of it.
    func clear(privately: Bool) {
        guard privately else {
            clearContents()
            return
        }
        prepareForNewContents(with: .currentHostOnly)
        for marker in ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"] {
            setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
    }
}

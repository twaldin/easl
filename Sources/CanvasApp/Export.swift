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
        guard !board.isRemote, let tile = tiles[id]?.content as? HtmlTile else { return }
        saveExport("Save as HTML", .html, ext: "html", logging: "HTML tile \(id)") { Data(try await tile.exportDocument().utf8) }
    }

    /// Open in Browser: the exported page in the temp directory, opened by the default browser.
    /// A development instance that may not activate other apps (`EASL_NO_ACTIVATE`) only logs
    /// the file it would open.
    func openHTMLInBrowser(_ id: ObjectID) {
        guard !board.isRemote, let tile = tiles[id]?.content as? HtmlTile else { return }
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
    /// the kit stylesheet and math fonts inlined, and active content removed (the generated styles,
    /// `<canvas-code>` rows and diagrams are already in the DOM). The file needs no scripts or network.
    func exportDocument(diagnosticsDirectory: URL? = nil) async throws -> String {
        let (result, reason) = await withOffscreenPage(size: RenderMath.body(of: object), appearance: effectiveAppearance) { web in
            try await web.callAsyncJavaScript(Self.exportScript, arguments: ["collectDiagnostics": diagnosticsDirectory != nil],
                                             in: nil, contentWorld: .world(name: "canvas-html-export")) as? [String: Any]
        }
        guard let report = result ?? nil, let html = report["html"] as? String else {
            throw ExportFailure(reason ?? "the page produced no document")
        }
        if let diagnosticsDirectory {
            guard let stylesheets = report["stylesheets"] as? [[String: Any]] else {
                throw ExportFailure("the page produced no stylesheet diagnostics")
            }
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            try Data(html.utf8).write(to: diagnosticsDirectory.appendingPathComponent("export.html"), options: .atomic)
            try JSONSerialization.data(withJSONObject: stylesheets, options: [.prettyPrinted, .sortedKeys])
                .write(to: diagnosticsDirectory.appendingPathComponent("stylesheets.json"), options: .atomic)
        }
        return html
    }

    /// Runs as the body of an async function in the page.
    static let exportScript = #"""
    const stylesheets = collectDiagnostics ? [] : null;
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
    if (document.documentElement?.namespaceURI !== 'http://www.w3.org/1999/xhtml' ||
        document.documentElement.tagName.toLowerCase() !== 'html') throw new Error('The page has no HTML document root.');
    const images = [...document.querySelectorAll('img')];
    const clone = document.implementation.createHTMLDocument('').importNode(document.documentElement, true);
    const copies = [...clone.querySelectorAll('img')];
    for (let i = 0; i < copies.length; i++) {
      const source = images[i] && (images[i].currentSrc || images[i].src);
      copies[i].removeAttribute('srcset');
      if (source) {
        try { copies[i].setAttribute('src', /^data:/i.test(source) ? source : await dataURL(source)); } catch (error) {}
      }
    }
    const styleBases = new WeakMap();
    for (const link of [...clone.querySelectorAll('link[rel="stylesheet"]')]) {
      try {
        const href = new URL(link.getAttribute('href'), document.baseURI).href;
        const style = document.createElement('style');
        style.media = link.media;
        style.textContent = await (await fetch(href)).text();
        styleBases.set(style, href);
        link.replaceWith(style);
      } catch (error) { link.remove(); }
    }
    const htmlNS = 'http://www.w3.org/1999/xhtml';
    const svgNS = 'http://www.w3.org/2000/svg';
    const mathNS = 'http://www.w3.org/1998/Math/MathML';
    const removedElements = new Set([
      'script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'portal', 'base', 'link',
      'animate', 'animatecolor', 'animatemotion', 'animatetransform', 'set', 'discard',
      'noscript', 'noembed', 'noframes', 'xmp', 'plaintext'
    ]);
    const resourceAttributes = new Set([
      'src', 'srcset', 'imagesrcset', 'imagesizes', 'action', 'formaction', 'data', 'poster',
      'background', 'ping', 'srcdoc', 'codebase', 'code', 'archive', 'classid', 'manifest',
      'profile', 'longdesc', 'lowsrc', 'dynsrc', 'datasrc', 'definitionurl', 'base', 'attributionsrc'
    ]);
    const svgCSSAttributes = new Set([
      'fill', 'stroke', 'filter', 'clip-path', 'mask', 'cursor', 'marker', 'marker-start',
      'marker-mid', 'marker-end'
    ]);
    const imageData = (value) => /^data:image\/[a-z0-9.+-]+(?:;[^,]*)?,/i.test(value);
    const fragment = (value) => value.startsWith('#');
    const navigationURL = (value) => {
      if (fragment(value)) return value;
      try {
        const url = new URL(value, document.baseURI);
        return ['http:', 'https:', 'mailto:'].includes(url.protocol) ? url.href : null;
      } catch (error) { return null; }
    };
    const decodeCSS = (value) => value.replace(
      /\\(?:([0-9a-f]{1,6})(?:\r\n|[ \t\n\r\f])?|(\r\n|[\n\r\f])|([\s\S]))/gi,
      (_, hex, newline, character) => {
        if (hex) {
          const point = parseInt(hex, 16);
          return String.fromCodePoint(point && point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff) ? point : 0xfffd);
        }
        return newline ? '' : character;
      }
    );
    const cssURLs = (value) => {
      const decoded = decodeCSS(value);
      const starts = [...decoded.matchAll(/url[ \t\n\r\f]*\(/gi)];
      const urls = [...decoded.matchAll(/url[ \t\n\r\f]*\([ \t\n\r\f]*(?:"([^"]*)"|'([^']*)'|([^'")]*))[ \t\n\r\f]*\)/gi)];
      if (starts.length !== urls.length || (starts.length && value.includes('\\'))) return null;
      return urls.map((match) => (match[1] ?? match[2] ?? match[3]).replace(/^[ \t\n\r\f]+|[ \t\n\r\f]+$/g, ''));
    };
    const safeCSS = (value) => {
      if (/(?:expression|(?:-webkit-)?image-set|image|src|paint)\s*\(/i.test(decodeCSS(value))) return false;
      const urls = cssURLs(value);
      return urls !== null && urls.every((url) => fragment(url) || imageData(url));
    };
    let usesDataFonts = false;
    const sanitizeDeclarations = async (style, base, fontFace = false) => {
      for (const property of [...style]) {
        const value = style.getPropertyValue(property);
        if (fontFace && property === 'src') {
          let source = null;
          for (const url of cssURLs(value) ?? []) {
            try {
              source = await dataURL(new URL(url, base).href);
              break;
            } catch (error) {}
          }
          if (source) {
            style.setProperty('src', `url(${JSON.stringify(source)})`);
            usesDataFonts = true;
          } else {
            style.removeProperty(property);
          }
        } else if (['behavior', '-moz-binding'].includes(property.toLowerCase()) || !safeCSS(value)) {
          style.removeProperty(property);
        }
      }
      if (!fontFace && !safeCSS(style.cssText)) {
        for (const property of [...style]) {
          if (style.getPropertyValue(property) === '') style.removeProperty(property);
        }
      }
    };
    const sanitizeRules = async (container, base) => {
      for (let i = container.cssRules.length - 1; i >= 0; i--) {
        const rule = container.cssRules[i];
        if (rule.type === 10) continue;
        if (rule.type === 3) {
          container.deleteRule(i);
          continue;
        }
        if (rule.style) await sanitizeDeclarations(rule.style, base, rule.type === 5);
        if (rule.cssRules) {
          await sanitizeRules(rule, base);
        } else if (!rule.style && !/^@layer\s+[^{}]+;$/i.test(rule.cssText) &&
                   !(rule.cssText.startsWith('@property ') && safeCSS(rule.cssText))) {
          container.deleteRule(i);
        }
      }
    };
    const sanitizeStyle = async (element, foreign) => {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(element.textContent);
      const base = styleBases.get(element) || document.baseURI;
      await sanitizeRules(sheet, base);
      const before = [...sheet.cssRules].map((rule) => rule.cssText);
      const serialized = before.join('\n');
      const reparsed = new CSSStyleSheet();
      reparsed.replaceSync(serialized);
      await sanitizeRules(reparsed, base);
      const after = [...reparsed.cssRules].map((rule) => rule.cssText);
      const stable = after.join('\n') === serialized;
      if (stylesheets) {
        let firstDifference = null;
        if (!stable) {
          let index = before.findIndex((text, i) => text !== after[i]);
          if (index < 0) index = before.length;
          firstDifference = { index, type: sheet.cssRules[index]?.type ?? null,
                              before: before[index] ?? null, after: after[index] ?? null };
        }
        stylesheets.push({ index: stylesheets.length, base, foreign, kept: stable,
                           rulesBefore: before.length, rulesAfter: after.length, firstDifference });
      }
      if (!stable) {
        element.remove();
        return;
      }
      const text = foreign ? serialized.replace(/&(?=#(?:\d|x[0-9a-f])|[a-z])/gi, '\\26 ') : serialized;
      element.textContent = text.replace(/<(?=[a-z/!?])/gi, '\\3c ');
    };
    const childNodes = Object.getOwnPropertyDescriptor(Node.prototype, 'childNodes').get;
    const sanitize = async (element, foreign = false) => {
      const tag = element.localName.toLowerCase();
      foreign = foreign || tag === 'svg' || tag === 'math' || element.namespaceURI !== htmlNS;
      if (![htmlNS, svgNS, mathNS].includes(element.namespaceURI) || removedElements.has(tag) ||
          (tag === 'meta' && [...element.attributes].some((attribute) => ['http-equiv', 'charset'].includes(attribute.localName.toLowerCase())))) {
        element.remove();
        return;
      }
      for (const attribute of [...element.attributes]) {
        const name = attribute.name.toLowerCase().split(':').pop();
        const value = attribute.value.trim();
        let replacement = null;
        if (name.startsWith('on') || resourceAttributes.has(name)) {
          if (name === 'src' && tag === 'img' && element.namespaceURI === htmlNS && /^data:/i.test(value)) replacement = value;
        } else if (name === 'href') {
          if (tag === 'a' || tag === 'area') replacement = navigationURL(value);
          else if (fragment(value) || (['image', 'feimage'].includes(tag) && element.namespaceURI === svgNS && imageData(value))) replacement = value;
        } else if (name === 'style') {
          const style = document.createElement('span').style;
          style.cssText = attribute.value;
          await sanitizeDeclarations(style, document.baseURI);
          replacement = style.cssText;
        } else if (svgCSSAttributes.has(name)) {
          if (safeCSS(attribute.value)) replacement = attribute.value;
        } else {
          continue;
        }
        if (replacement === null) element.removeAttributeNode(attribute);
        else attribute.value = replacement;
      }
      if (tag === 'style') {
        await sanitizeStyle(element, foreign);
        return;
      }
      if (tag === 'textarea' || tag === 'title') {
        element.textContent = tag === 'textarea' && element.namespaceURI === htmlNS ? element.value : element.textContent;
        return;
      }
      const children = element.localName === 'template' && element.namespaceURI === htmlNS ? element.content : element;
      for (const child of [...childNodes.call(children)]) {
        if (child instanceof Element) await sanitize(child, foreign);
        else if (child.nodeType !== Node.TEXT_NODE) child.remove();
      }
      if (tag === 'form') element.replaceWith(...childNodes.call(element));
    };
    await sanitize(clone);
    let head = [...clone.children].find((element) => element.namespaceURI === htmlNS && element.tagName.toLowerCase() === 'head');
    if (!head) {
      head = document.createElement('head');
    }
    clone.prepend(head);
    const policy = document.createElement('meta');
    policy.setAttribute('http-equiv', 'Content-Security-Policy');
    policy.setAttribute('content', "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; img-src data:; style-src 'unsafe-inline'" + (usesDataFonts ? "; font-src data:" : ""));
    const charset = document.createElement('meta');
    charset.setAttribute('charset', 'utf-8');
    head.prepend(charset);
    head.prepend(policy);
    return { html: '\uFEFF<!doctype html>\n' + clone.outerHTML, stylesheets };
    """#
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

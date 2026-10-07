import AppKit
import CanvasCore
import Security
import WebKit

/// What a page asks of the person in front of it, as Safari asks: JavaScript's alert, confirm
/// and prompt, a file chooser for `<input type=file>`, a login for HTTP authentication, a
/// client certificate, the camera and microphone, and leaving for another app (`zoommtg:`).
/// Each is a sheet on the board's window naming the page's host, never an app-modal panel
/// (that would stall every socket request until answered). Without a window (the tile closed,
/// or a page an agent drives from the stage) the page gets the answer a dismissed dialog gives.
extension BrowserTile {
    /// "localhost:8000", "accounts.google.com": who is asking.
    static func host(of origin: WKSecurityOrigin) -> String {
        let defaultPort = origin.protocol == "https" ? 443 : origin.protocol == "http" ? 80 : 0
        if origin.host.isEmpty { return origin.protocol }
        return origin.port == 0 || origin.port == defaultPort ? origin.host : "\(origin.host):\(origin.port)"
    }

    private func sheet(_ alert: NSAlert, _ done: @escaping @MainActor (NSApplication.ModalResponse?) -> Void) {
        guard let window else { return done(nil) }
        alert.beginSheetModal(for: window) { response in done(response) }
    }

    // MARK: window frame

    /// The page's "window", which WebKit asks the browser for (Safari answers with its window):
    /// `window.outerWidth`/`outerHeight` and `screenX`/`screenY` (a popup the page opens is a new
    /// tile the board places, `openPopup`, whatever it asks). Unanswered, outerWidth and
    /// outerHeight are 0, and Google Docs, which on Safari before 26.4 takes outerWidth /
    /// innerWidth for the browser's zoom (snapped to at least 0.25), drew its text canvases at a
    /// quarter of their resolution: blurry text beside sharp images. The answer is the page area
    /// where the tile shows on screen, at the web view's own size (the page at 100%), not its
    /// on-screen size under the board's and the tile's zoom, so outerWidth / innerWidth is 1.
    /// It's in AppKit's screen space, which WebKit flips itself (`screenY` is the primary
    /// screen's top minus the frame's top), so the frame keeps the page area's top-left corner
    /// where it shows: `screenX`/`screenY` are that corner at any zoom.
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webView(_ webView: WKWebView, getWindowFrameWithCompletionHandler completion: @escaping (CGRect) -> Void) {
        var frame = CGRect(origin: .zero, size: webView.bounds.size)
        if let window = webView.window {
            let shown = window.convertToScreen(webView.convert(webView.bounds, to: nil))
            frame.origin = CGPoint(x: shown.minX, y: shown.maxY - frame.height)
        }
        completion(frame)
    }

    // MARK: alert, confirm, prompt

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(Self.host(of: frame.securityOrigin)) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        sheet(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(Self.host(of: frame.securityOrigin)) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        sheet(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(Self.host(of: frame.securityOrigin)) says"
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        sheet(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    // MARK: File upload

    /// `<input type=file>`: an open panel as a sheet (several files, or folders, when the input
    /// allows them). Cancelling sends the page no files.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        guard let window else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.message = "Choose \(parameters.allowsMultipleSelection ? "files" : "a file") to upload to \(Self.host(of: frame.securityOrigin))"
        panel.prompt = "Upload"
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? DevInput.chosen(in: panel) : nil)
        }
    }

    // MARK: Camera and microphone

    /// Camera and microphone: asked once per site and kind while easl runs (Allow or Don't
    /// Allow), then remembered until quit. Granting here still leaves macOS's own camera and
    /// microphone permission for easl, which macOS asks for the first time.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let site = "\(origin.protocol)://\(Self.host(of: origin))"
        let key = "\(site) \(type.rawValue)"
        if let remembered = MediaDecisions.answers[key] { return decisionHandler(remembered ? .grant : .deny) }
        let what = switch type {
        case .camera: "your camera"
        case .microphone: "your microphone"
        case .cameraAndMicrophone: "your camera and microphone"
        @unknown default: "your camera or microphone"
        }
        let alert = NSAlert()
        alert.messageText = "Allow “\(Self.host(of: origin))” to use \(what)?"
        alert.informativeText = "easl remembers your answer for this site until it quits."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        sheet(alert) { response in
            guard let response else { return decisionHandler(.deny) }
            let allowed = response == .alertFirstButtonReturn
            MediaDecisions.answers[key] = allowed
            NSLog("easl: browser %@ %@ %@ for %@", self.objectID, allowed ? "allowed" : "denied", what, site)
            decisionHandler(allowed ? .grant : .deny)
        }
    }

    // MARK: HTTP authentication and client certificates

    /// Basic, Digest and NTLM logins: a sheet with the site's realm, a user name and a password
    /// (kept for the session). A login the server refused asks again, saying so. Cancel shows the
    /// server's own refusal page. A server asking for a client certificate gets the user's choice
    /// among the keychain identities its certificate authorities issued. Server trust stays
    /// WebKit's (an invalid certificate fails the load). A download from this tile's page asks
    /// the same way (`BrowserDownloads`).
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    func answer(_ challenge: URLAuthenticationChallenge, _ completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            askForLogin(challenge, completionHandler)
        case NSURLAuthenticationMethodClientCertificate:
            askForIdentity(challenge, completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func askForLogin(_ challenge: URLAuthenticationChallenge, _ completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let host = space.port == 0 || space.port == 80 || space.port == 443 ? space.host : "\(space.host):\(space.port)"
        let alert = NSAlert()
        alert.messageText = "Log in to \(host)"
        var lines: [String] = []
        if let realm = space.realm, !realm.isEmpty { lines.append("The site says: “\(realm)”") }
        if challenge.previousFailureCount > 0 { lines.append("The user name or password was wrong.") }
        if !space.receivesCredentialSecurely { lines.append("Your password will be sent unencrypted.") }
        alert.informativeText = lines.joined(separator: "\n")
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "User name"
        user.stringValue = challenge.proposedCredential?.user ?? ""
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        user.nextKeyView = password
        password.nextKeyView = user
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        sheet(alert) { response in
            guard response == .alertFirstButtonReturn else { return completionHandler(.performDefaultHandling, nil) }
            NSLog("easl: browser %@ logging in to %@", self.objectID, host)
            completionHandler(.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
        }
    }

    private func askForIdentity(_ challenge: URLAuthenticationChallenge, _ completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let identities = Self.identities(issuedBy: challenge.protectionSpace.distinguishedNames ?? [])
        guard !identities.isEmpty else { return completionHandler(.performDefaultHandling, nil) }
        let alert = NSAlert()
        alert.messageText = "\(challenge.protectionSpace.host) asks for a certificate"
        alert.informativeText = "Choose the certificate that identifies you to this site."
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        for identity in identities {
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            menu.addItem(withTitle: certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Certificate")
        }
        alert.accessoryView = menu
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        sheet(alert) { response in
            guard response == .alertFirstButtonReturn, menu.indexOfSelectedItem >= 0 else { return completionHandler(.performDefaultHandling, nil) }
            completionHandler(.useCredential, URLCredential(identity: identities[menu.indexOfSelectedItem], certificates: nil, persistence: .forSession))
        }
    }

    /// The keychain's identities (a certificate with its private key) whose issuer is one of
    /// `issuers` (DER-encoded names the server accepts); any identity when the server names none.
    private nonisolated static func identities(issuedBy issuers: [Data]) -> [SecIdentity] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        if !issuers.isEmpty { query[kSecMatchIssuers as String] = issuers }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let found = result as? [Any] else { return [] }
        return found.map { $0 as! SecIdentity }
    }

    // MARK: Other apps' links

    /// A link to another app (`zoommtg:`, `slack:`, `mailto:`, `tel:`) the page navigates to:
    /// asks first, as Safari does ("Open “zoom.us”?"), then hands it to macOS. A scheme no app
    /// opens loads as before (the tile says it can't open it); a subframe's goes nowhere.
    func openInOtherApp(_ url: URL, from frame: WKFrameInfo?) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Open “\(name)”?"
        let site = frame.map { Self.host(of: $0.securityOrigin) } ?? "This page"
        alert.informativeText = "\(site) wants to open \(url.scheme ?? "this"): link in \(name)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        sheet(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            ExternalOpen.open(url, because: "browser \(self.objectID) link to another app")
        }
    }
}

/// Camera and microphone answers by "<site> <kind>", for the app's run.
@MainActor
private enum MediaDecisions {
    static var answers: [String: Bool] = [:]
}

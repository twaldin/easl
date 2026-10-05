import AppKit
import CanvasCore
import WebKit

/// Downloads from browser tiles (`WKDownload`): a link the page marks as a download, a response
/// the page can't show (a zip, a dmg) or one the server sends as an attachment. Each goes
/// straight into ~/Downloads under the name the server suggested (`DownloadName`: a taken name
/// gets " 2", " 3", …), marked as downloaded from the web (quarantine, so Gatekeeper checks
/// what it opens) with the page it came from. The tile's address bar shows it while it runs
/// and once it's done (click: shown in Finder); the Dock's Downloads stack bounces as for
/// Safari's. Downloads outlive their tile's page: they're held here, not by the web view.
///
/// `EASL_DEV_DOWNLOADS` (development instances' tests) names another folder.
@MainActor
final class BrowserDownloads: NSObject, WKDownloadDelegate {
    static let shared = BrowserDownloads()

    /// What a tile's address bar shows of its latest download.
    struct Status: Equatable {
        enum State: Equatable { case running(Double?), finished, failed(String) }
        var name: String
        var file: URL?
        var state: State
    }

    private struct Entry {
        weak var tile: BrowserTile?
        var source: URL?
        var file: URL?
        var name: String
        var progress: NSKeyValueObservation?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["EASL_DEV_DOWNLOADS"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Takes over a download a tile's page started.
    func start(_ download: WKDownload, from tile: BrowserTile) {
        download.delegate = self
        let key = ObjectIdentifier(download)
        entries[key] = Entry(tile: tile, source: download.originalRequest?.url, name: download.originalRequest?.url?.lastPathComponent ?? "download")
        entries[key]?.progress = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(key, .running(fraction)) } }
        }
        NSLog("easl: browser %@ started a download from %@", tile.objectID, download.originalRequest?.url?.absoluteString ?? "?")
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        let folder = Self.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("easl: download folder %@ unavailable: %@", folder.path, error.localizedDescription)
            update(key, .failed("can't write to \(folder.lastPathComponent)"))
            return completionHandler(nil)
        }
        let name = DownloadName.unique(DownloadName.sanitized(suggestedFilename)) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let file = folder.appendingPathComponent(name)
        entries[key]?.name = name
        entries[key]?.file = file
        update(key, .running(nil))
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let entry = entries.removeValue(forKey: key) else { return }
        if let file = entry.file {
            markDownloaded(file, from: entry.source, page: entry.tile?.pageURL.flatMap(URL.init(string:)))
            // The Dock's Downloads stack bounces, as for Safari's downloads.
            DistributedNotificationCenter.default().post(name: NSNotification.Name("com.apple.DownloadFileFinished"), object: file.path)
            NSLog("easl: browser %@ downloaded %@", entry.tile?.objectID ?? "?", file.path)
        }
        entry.tile?.showDownload(Status(name: entry.name, file: entry.file, state: .finished))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let entry = entries.removeValue(forKey: key) else { return }
        NSLog("easl: browser %@ download of %@ failed: %@", entry.tile?.objectID ?? "?", entry.name, error.localizedDescription)
        // A partial file stays only while WebKit writes it; it removes it on failure.
        entry.tile?.showDownload(Status(name: entry.name, file: nil, state: .failed(error.localizedDescription)))
    }

    /// Redirects are followed as Safari does.
    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(.allow)
    }

    private func update(_ key: ObjectIdentifier, _ state: Status.State) {
        guard let entry = entries[key] else { return }
        entry.tile?.showDownload(Status(name: entry.name, file: entry.file, state: state))
    }

    /// The quarantine attributes Safari gives a download: Gatekeeper checks an app or script from
    /// it before it first runs, and Finder's Get Info says where it came from.
    private func markDownloaded(_ file: URL, from source: URL?, page: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "easl",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source { properties[kLSQuarantineDataURLKey as String] = source }
        if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = file
        do {
            try target.setResourceValues(values)
        } catch {
            NSLog("easl: couldn't mark %@ as downloaded: %@", file.path, error.localizedDescription)
        }
    }
}

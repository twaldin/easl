import Foundation
import Testing
import CanvasCore

/// Files a browser tile touches: what a download is saved as, and which local pages reload when
/// which files change.
struct BrowserFilesTests {
    @Test func aDownloadNeverReplacesAFileAlreadyInTheFolder() {
        let taken: Set<String> = ["report.pdf", "report 2.pdf", "build.tar.gz", "Makefile"]
        #expect(DownloadName.unique("report.pdf", taken: taken.contains) == "report 3.pdf")
        #expect(DownloadName.unique("build.tar.gz", taken: taken.contains) == "build 2.tar.gz")
        #expect(DownloadName.unique("Makefile", taken: taken.contains) == "Makefile 2")
        #expect(DownloadName.unique("new.zip", taken: taken.contains) == "new.zip")
    }

    @Test func aNumberedNameStillFitsTheFileSystem() {
        let longest = String(repeating: "x", count: 251) + ".zip"
        let again = DownloadName.unique(longest) { $0 == longest }
        #expect(again.utf8.count == 255 && again.hasSuffix(" 2.zip") && again != longest)
    }

    @Test func aSuggestedNameCanNeitherLeaveTheFolderNorHide() {
        #expect(DownloadName.sanitized("../../etc/passwd") == "-..-etc-passwd")
        #expect(DownloadName.sanitized(".bashrc") == "bashrc")
        #expect(DownloadName.sanitized("a:b\u{7}.txt") == "a-b .txt")
        #expect(DownloadName.sanitized("  ") == "download")
        let long = String(repeating: "x", count: 300) + ".zip"
        let cut = DownloadName.sanitized(long)
        #expect(cut.utf8.count == 255 && cut.hasSuffix(".zip"))
    }

    @Test func onlyPagesServedFromThisMacReloadOnFileChanges() {
        let root = URL(fileURLWithPath: "/repo")
        for local in ["http://localhost:3000/", "https://app.localhost/x", "http://127.0.0.1:8000/a", "http://[::1]:5173/", "file:///repo/site/index.html"] {
            #expect(LocalPage.isLocal(URL(string: local)!), "\(local)")
        }
        for remote in ["https://example.com/", "http://10.0.0.2:3000/", "http://localhost.example.com/", "http://127.example.com/", "http://127.0.0.1.example.com/", "http://127.0.0.256/"] {
            #expect(!LocalPage.isLocal(URL(string: remote)!), "\(remote)")
        }
        #expect(LocalPage.directory(for: URL(string: "http://localhost:3000/")!, boardRoot: root)?.path == "/repo")
        #expect(LocalPage.directory(for: URL(string: "file:///srv/site/index.html")!, boardRoot: root)?.path == "/srv/site")
        #expect(LocalPage.directory(for: URL(string: "https://example.com/")!, boardRoot: root) == nil)
    }

    @Test func hiddenFilesAndDependenciesDoNotReloadThePage() {
        #expect(LocalPage.counts("/repo/src/app.css", under: "/repo"))
        #expect(LocalPage.counts("/repo/index.html", under: "/repo/"))
        #expect(!LocalPage.counts("/repo/.git/index", under: "/repo"))
        #expect(!LocalPage.counts("/repo/src/.app.css.swp", under: "/repo"))
        #expect(!LocalPage.counts("/repo/node_modules/x/index.js", under: "/repo"))
        #expect(!LocalPage.counts("/repository/a.html", under: "/repo"))
    }
}

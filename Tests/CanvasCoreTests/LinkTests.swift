import Foundation
import Testing
import CanvasCore

/// Web links: reusing the browser tile that already shows an address, and finding addresses in text.
@MainActor
struct LinkTests {
    let board = Board(id: "brd_links", root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("easl-links-\(UUID().uuidString)"))

    func browser(_ url: String, at frame: Frame = Frame(x: 2000, y: 0, w: 600, h: 400), profile: String? = nil) -> CanvasObject {
        var props: [String: JSONValue] = ["url": .string(url)]
        if let profile { props["profile"] = .string(profile) }
        return board.create(type: .browser, props: .object(props), frame: frame)
    }

    func link(_ text: String, near source: ObjectID? = nil, profile: String? = nil) -> (object: CanvasObject, existing: Bool) {
        board.openLink(URL(string: text)!, near: source, caller: source, props: profile.map { ["profile": .string($0)] } ?? [:])
    }

    @Test func aTileShowingTheSameAddressIsReusedHoweverItIsSpelled() {
        let shown = browser("http://example.com/docs")
        for spelling in ["http://example.com/docs", "HTTP://Example.COM/docs", "http://example.com:80/docs"] {
            let opened = link(spelling)
            #expect(opened.existing && opened.object.id == shown.id, "\(spelling)")
        }
        let root = browser("https://example.com:8443/")
        #expect(link("https://EXAMPLE.com:8443").object.id == root.id, "an empty path is /")
        #expect(link("https://example.com").existing == false, "a default port is not 8443")
        #expect(board.objects.values.filter { $0.type == .browser }.count == 3)
    }

    @Test func aDifferentPathQueryOrFragmentIsAnotherPage() {
        let shown = browser("https://app.example.com/page?tab=1")
        for other in ["https://app.example.com/page", "https://app.example.com/page?tab=2", "https://app.example.com/page?tab=1#top", "http://app.example.com/page?tab=1"] {
            let opened = link(other)
            #expect(!opened.existing && opened.object.id != shown.id, "\(other)")
        }
        #expect(board.objects.values.filter { $0.type == .browser }.count == 5)
        #expect(link("https://app.example.com/page?tab=1#top").existing, "a fragment is part of the address")
    }

    @Test func onlyBrowserTilesCountAndOtherProfilesAreOtherPages() {
        board.create(type: .note, props: .object(["markdown": .string("http://example.com/")]), frame: Frame(x: 0, y: 0, w: 300, h: 200))
        board.create(type: .html, props: .object(["url": .string("http://example.com/"), "html": .string("")]), frame: Frame(x: 0, y: 300, w: 300, h: 200))
        let first = link("http://example.com/")
        #expect(!first.existing && first.object.type == .browser, "a note and an HTML tile mentioning it don't show it")

        let work = browser("https://github.com/", profile: "work")
        #expect(!link("https://github.com/").existing, "the default profile is not 'work'")
        #expect(link("https://github.com/", profile: "work").object.id == work.id)
        #expect(!link("https://github.com/", profile: "personal").existing)
    }

    @Test func aNewTileOpensBesideItsSourceCreditedToTheCaller() {
        let terminal = board.create(type: .terminal, props: .object([:]), frame: Frame(x: 0, y: 0, w: 600, h: 400))
        let opened = link("https://example.com/new", near: terminal.id)
        #expect(!opened.existing)
        #expect(opened.object.props["url"]?.string == "https://example.com/new")
        #expect(opened.object.createdBy == Actor(caller: terminal.id))
        let frame = opened.object.frame
        #expect(frame.x >= 600 || frame.y >= 400 || frame.x + frame.w <= 0 || frame.y + frame.h <= 0, "beside the terminal, not over it")
        #expect(abs(frame.x - 600) < 200 || abs(frame.y - 400) < 200, "and close to it")
    }

    @Test func textLinksStopWhereProseDoes() {
        func urls(_ text: String) -> [String] { WebLink.matches(in: text).map(\.url.absoluteString) }
        #expect(urls("// see https://example.com/a/b.") == ["https://example.com/a/b"])
        #expect(urls("(see https://example.com/x), or https://example.org/y;") == ["https://example.com/x", "https://example.org/y"])
        #expect(urls("[docs](https://example.com/docs) and <https://example.com/lt>") == ["https://example.com/docs", "https://example.com/lt"])
        #expect(urls(#"let url = "https://example.com/q?a=1&b=2";"#) == ["https://example.com/q?a=1&b=2"])
        #expect(urls("https://en.wikipedia.org/wiki/Foo_(bar) is one") == ["https://en.wikipedia.org/wiki/Foo_(bar)"])
        #expect(urls("http://localhost:3000/#/route") == ["http://localhost:3000/#/route"])
        #expect(urls("xhttp://nope.com ftp://example.com/file mailto:a@b.c http:// https://").isEmpty)
    }

    @Test func anOffsetFindsTheLinkUnderIt() throws {
        let text = "# docs: https://example.com/a, ok"
        let link = try #require(WebLink.matches(in: text).first)
        #expect(link.range == NSRange(location: 8, length: 21))
        #expect(WebLink.match(in: text, at: 8)?.url == link.url, "its first character")
        #expect(WebLink.match(in: text, at: 28)?.url == link.url, "its last character")
        #expect(WebLink.match(in: text, at: 7) == nil)
        #expect(WebLink.match(in: text, at: 29) == nil, "the comma after it")
    }
}

import Foundation
import Testing
import CanvasCore

private func permitsNetworkURL(_ literal: String, rules: [HostNetworkRule]) -> Bool {
    guard let url = URL(string: literal) else { return false }
    return HostNetworkPolicy.permits(url, rules: rules)
}

struct HostNetworkPolicyTests {
    @Test func parsesExistingGrammarIntoTypedRules() {
        let rules = HostNetworkPolicy.rules(allow: ["LOCALHOST:08123", "*.GitHub.io", "api.private.internal", "192.168.1.20:80"])
        #expect(rules.count == 4)
        #expect(rules[0].host == "localhost")
        #expect(rules[0].port == 8123)
        #expect(!rules[0].subdomains)
        #expect(rules[1].host == "github.io")
        #expect(rules[1].port == nil)
        #expect(rules[1].subdomains)
        #expect(rules[2].host == "api.private.internal")
        #expect(rules[3].host == "192.168.1.20")
        #expect(rules[3].port == 80)
        #expect(permitsNetworkURL("http://localhost:8123/", rules: rules))
        #expect(permitsNetworkURL("https://a.github.io/", rules: rules))
    }

    @Test func rejectsMalformedAllowEntriesWithoutOpeningAnOrigin() {
        let invalid = [
            "https://example.com", "example.com/path", "example.com?query", "example.com#fragment",
            " example.com", "example.com ", "exa mple.com", "a|b.com", "*", "*.", "foo.*.example",
            "host:99999", "host:0", "host:", "host:-1", "host:+80", "host:１２", "host:000080",
            "-bad.com", "bad-.com", "a..b", "example.com.", "user@example.com", "example.com:x@evil.com",
            "::1", "[::1", "[::1]extra", "[::1]:", "[::1]:0", "[::1]:65536", "[::1]:x",
            "[not-an-address]", "[fe80::1%en0]", "*.[::1]", "[1:2:3:4:5:6:7:8:9]"
        ]
        #expect(HostNetworkPolicy.rules(allow: invalid).isEmpty)
        let rules = HostNetworkPolicy.rules(allow: invalid + ["example.com:443"])
        #expect(permitsNetworkURL("https://example.com/", rules: rules))
        #expect(!permitsNetworkURL("http://example.com/", rules: rules))
        #expect(!permitsNetworkURL("http://localhost/", rules: rules))
    }

    @Test func pinsTheWholeAuthorityAndRequiresHTTPWithoutUserinfo() {
        let rules = HostNetworkPolicy.rules(allow: ["allowed.example"])
        for literal in [
            "https://allowed.example/", "HTTP://ALLOWED.EXAMPLE/x?y=1", "http://allowed.example:1/",
            "https://allowed.example:65535/", "https://allowed.example/?next=https://elsewhere.example/"
        ] {
            #expect(permitsNetworkURL(literal, rules: rules), "\(literal)")
        }
        for literal in [
            "https://allowed.example.evil.com/", "https://notallowed.example/", "https://sub.allowed.example/",
            "https://allowed.example@attacker.example/", "https://allowed.example:1@attacker.example/",
            "https://user@allowed.example/", "https://@allowed.example/", "https://:password@allowed.example/",
            "https://user:password@allowed.example/", "https://attacker.example/?next=https://allowed.example/",
            "https://allowed.example%2eevil.com/", "http://allowed.example:0/", "http://allowed.example:65536/",
            "http://allowed.example:/", "http://allowed.example:-1/", "http://allowed.example:abc/",
            "ws://allowed.example/", "wss://allowed.example/", "ftp://allowed.example/",
            "file://allowed.example/path", "canvas-kit://allowed.example/", "data:text/plain,allowed.example"
        ] {
            #expect(!permitsNetworkURL(literal, rules: rules), "\(literal)")
        }
    }

    @Test func wildcardAndExplicitPortRulesStayWithinTheirBoundaries() {
        let rules = HostNetworkPolicy.rules(allow: ["*.allowed.example:8443"])
        for literal in ["https://allowed.example:8443/", "http://a.allowed.example:8443/", "https://a.b.allowed.example:8443/"] {
            #expect(permitsNetworkURL(literal, rules: rules), "\(literal)")
        }
        for literal in [
            "https://allowed.example/", "https://allowed.example:8444/", "http://a.allowed.example:84430/",
            "https://evilallowed.example:8443/", "https://a.allowed.example.evil.com:8443/",
            "https://a.allowed.example:8443@evil.com/", "https://user@a.allowed.example:8443/"
        ] {
            #expect(!permitsNetworkURL(literal, rules: rules), "\(literal)")
        }
        let anyPort = HostNetworkPolicy.rules(allow: ["*.allowed.example"])
        #expect(permitsNetworkURL("http://allowed.example/", rules: anyPort))
        #expect(permitsNetworkURL("https://a.allowed.example:65535/", rules: anyPort))
        #expect(!permitsNetworkURL("https://other.example:65535/", rules: anyPort))
    }

    @Test func explicitDefaultPortsMatchOnlyTheirEffectivePort() {
        let https = HostNetworkPolicy.rules(allow: ["example.com:0443"])
        for literal in ["https://example.com/", "https://example.com:443/", "http://example.com:443/"] {
            #expect(permitsNetworkURL(literal, rules: https), "\(literal)")
        }
        for literal in ["http://example.com/", "http://example.com:80/", "https://example.com:8443/"] {
            #expect(!permitsNetworkURL(literal, rules: https), "\(literal)")
        }
        let http = HostNetworkPolicy.rules(allow: ["example.com:80"])
        #expect(permitsNetworkURL("http://example.com/", rules: http))
        #expect(permitsNetworkURL("http://example.com:80/", rules: http))
        #expect(permitsNetworkURL("https://example.com:80/", rules: http))
        #expect(!permitsNetworkURL("https://example.com/", rules: http))
    }

    @Test func explicitPrivateDNSAndAddressEntriesNeedNoDNSClassification() {
        let rules = HostNetworkPolicy.rules(allow: [
            "intranet", "api.dev.internal", "192.168.20.5:8080", "10.42.0.5", "172.16.0.20", "127.0.0.1:9000",
            "[::1]:8123", "[FD00:0:0:0:0:0:0:ABCD]:8443", "[::ffff:192.168.10.1]"
        ])
        for literal in [
            "http://intranet/", "https://api.dev.internal:444/", "http://192.168.20.5:8080/",
            "http://10.42.0.5/", "https://172.16.0.20/", "http://127.0.0.1:9000/",
            "http://[0:0:0:0:0:0:0:1]:8123/", "https://[fd00::abcd]:8443/", "http://[::ffff:c0a8:a01]/"
        ] {
            #expect(permitsNetworkURL(literal, rules: rules), "\(literal)")
        }
        for literal in [
            "http://other-intranet/", "http://sub.api.dev.internal/", "http://192.168.20.6:8080/",
            "http://192.168.20.5:8081/", "http://10.42.0.6/", "https://172.16.0.21/", "http://127.0.0.2:9000/",
            "http://[::1]:8124/", "https://[fd00::abce]:8443/", "http://[::ffff:c0a8:a02]/"
        ] {
            #expect(!permitsNetworkURL(literal, rules: rules), "\(literal)")
        }
    }

    @Test func canonicalIPv6UsesTheFirstLongestZeroRunAndHexadecimalWords() {
        let rules = HostNetworkPolicy.rules(allow: [
            "[0:0:0:0:0:0:0:0]", "[1:0:2:3:4:5:6:7]", "[1:0:0:2:0:0:3:4]", "[1:2:3:4:5:0:0:0]",
            "[::FFFF:192.168.10.1]"
        ])
        #expect(rules.map(\.host) == ["[::]", "[1:0:2:3:4:5:6:7]", "[1::2:0:0:3:4]", "[1:2:3:4:5::]", "[::ffff:c0a8:a01]"])
        #expect(permitsNetworkURL("http://[1:0:0:2:0:0:3:4]/", rules: rules))
        #expect(!permitsNetworkURL("http://[1:0:0:2:0:0:3:5]/", rules: rules))
    }

    @Test func serializedRulesRetainTheHostRedirectContract() throws {
        let rules = HostNetworkPolicy.rules(allow: ["*.PRIVATE.internal:08123", "[::1]"])
        let encoder = JSONEncoder()
        let bytes = try encoder.encode(rules)
        let decoded = try JSONDecoder().decode([HostNetworkRule].self, from: bytes)
        #expect(permitsNetworkURL("http://api.private.internal:8123/data", rules: decoded))
        #expect(permitsNetworkURL("https://[::1]:8443/", rules: decoded))
        #expect(!permitsNetworkURL("http://api.private.internal:8124/data", rules: decoded))
        #expect(!permitsNetworkURL("http://api.private.internal.evil:8123/data", rules: decoded))
    }
}

struct HostURLMapTests {
    @Test func grantsAreRandomPerOriginAndReuseEquivalentDefaultPorts() throws {
        var map = HostURLMap(allow: ["private.internal", "other.internal"])
        let httpURL = map.proxyURL(for: URL(string: "http://private.internal/first")!)
        let httpDefaultURL = map.proxyURL(for: URL(string: "HTTP://PRIVATE.INTERNAL:80/second")!)
        let httpsURL = map.proxyURL(for: URL(string: "https://private.internal/secure")!)
        let httpsDefaultURL = map.proxyURL(for: URL(string: "https://private.internal:443/another")!)
        let otherPortURL = map.proxyURL(for: URL(string: "http://private.internal:8080/port")!)
        let otherHostURL = map.proxyURL(for: URL(string: "http://other.internal/host")!)
        let http = try #require(httpURL)
        let httpDefault = try #require(httpDefaultURL)
        let https = try #require(httpsURL)
        let httpsDefault = try #require(httpsDefaultURL)
        let otherPort = try #require(otherPortURL)
        let otherHost = try #require(otherHostURL)
        let host = try #require(http.host)
        #expect(http.scheme == "canvas-kit")
        #expect(host.range(of: #"^p-[0-9a-f]{32}$"#, options: .regularExpression) != nil)
        #expect(httpDefault.host == host)
        #expect(httpsDefault.host == https.host)
        #expect(Set([http, https, otherPort, otherHost].compactMap(\.host)).count == 4)
        #expect(map.contains(host: host.uppercased()))
        #expect(!map.contains(host: "html"))
        #expect(map.originalURL(for: httpDefault)?.absoluteString == "http://private.internal/second")
        #expect(map.originalURL(for: httpsDefault)?.absoluteString == "https://private.internal/another")
        #expect(map.originalURL(for: otherPort)?.absoluteString == "http://private.internal:8080/port")

        var separateView = HostURLMap(allow: ["private.internal"])
        let separateURL = separateView.proxyURL(for: URL(string: "http://private.internal/first")!)
        let separate = try #require(separateURL)
        #expect(separate.host != host)
        #expect(separateView.originalURL(for: http) == nil)
        #expect(map.originalURL(for: separate) == nil)
    }

    @Test func preservesPercentEncodedPathsQueriesAndFragmentsInBothDirections() throws {
        var map = HostURLMap(allow: ["private.internal:8443"])
        let original = URL(string: "https://PRIVATE.internal:8443/a%2Fb/%25/%2e%2E/space%20here/%3F%23?x=a%2Fb&literal=%252F&plus=a+b&empty=#frag%2Fpiece")!
        let mapped = map.proxyURL(for: original)
        let proxy = try #require(mapped)
        let components = try #require(URLComponents(url: proxy, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/a%2Fb/%25/%2e%2E/space%20here/%3F%23")
        #expect(components.percentEncodedQuery == "x=a%2Fb&literal=%252F&plus=a+b&empty=")
        #expect(components.percentEncodedFragment == "frag%2Fpiece")
        #expect(components.port == nil)
        #expect(map.originalURL(for: proxy)?.absoluteString == "https://private.internal:8443/a%2Fb/%25/%2e%2E/space%20here/%3F%23?x=a%2Fb&literal=%252F&plus=a+b&empty=#frag%2Fpiece")

        let emptyPathURL = map.proxyURL(for: URL(string: "https://private.internal:8443?empty=")!)
        let emptyPath = try #require(emptyPathURL)
        #expect(URLComponents(url: emptyPath, resolvingAgainstBaseURL: false)?.percentEncodedPath == "")
        #expect(map.originalURL(for: emptyPath)?.absoluteString == "https://private.internal:8443?empty=")
    }

    @Test func rootRelativeAndDirectoryRelativeResourcesKeepDistinctOrigins() throws {
        var map = HostURLMap(allow: ["private.internal:8123", "api.internal:9443", "[::1]:8123"])
        let firstURL = map.proxyURL(for: URL(string: "http://private.internal:8123/docs/index.html")!)
        let secondURL = map.proxyURL(for: URL(string: "https://api.internal:9443/app/index.html")!)
        let ipv6URL = map.proxyURL(for: URL(string: "http://[::1]:8123/start")!)
        let first = try #require(firstURL)
        let second = try #require(secondURL)
        let ipv6 = try #require(ipv6URL)
        let firstRoot = URL(string: "/api/items?key=a%2Fb", relativeTo: first)!.absoluteURL
        let secondRoot = URL(string: "/api/items?key=a%2Fb", relativeTo: second)!.absoluteURL
        #expect(map.originalURL(for: firstRoot)?.absoluteString == "http://private.internal:8123/api/items?key=a%2Fb")
        #expect(map.originalURL(for: secondRoot)?.absoluteString == "https://api.internal:9443/api/items?key=a%2Fb")
        #expect(map.originalURL(for: URL(string: "next.js", relativeTo: first)!.absoluteURL)?.absoluteString == "http://private.internal:8123/docs/next.js")
        #expect(map.originalURL(for: URL(string: "/data", relativeTo: ipv6)!.absoluteURL)?.absoluteString == "http://[::1]:8123/data")
    }

    @Test func refusesUnknownForgedOrDecoratedGrantsAndUnallowedOrigins() throws {
        var map = HostURLMap(allow: ["private.internal:8123"])
        let mapped = map.proxyURL(for: URL(string: "http://private.internal:8123/allowed")!)
        let proxy = try #require(mapped)
        let host = try #require(proxy.host)
        #expect(map.originalURL(for: proxy)?.absoluteString == "http://private.internal:8123/allowed")
        for literal in [
            "canvas-kit://p-00000000000000000000000000000000/allowed", "canvas-kit://html/\(host)/allowed",
            "canvas-kit://\(host).evil/allowed", "canvas-kit://user@\(host)/allowed", "canvas-kit://@\(host)/allowed",
            "canvas-kit://user:password@\(host)/allowed", "canvas-kit://\(host):80/allowed",
            "canvas-kit://\(host):443/allowed", "canvas-kit://\(host):8123/allowed", "canvas-kit://\(host):/allowed",
            "https://\(host)/allowed", "http://\(host)/allowed"
        ] {
            let forged = try #require(URL(string: literal))
            #expect(map.originalURL(for: forged) == nil, "\(literal)")
        }
        for literal in [
            "http://private.internal/", "http://private.internal:8124/", "http://other.internal:8123/",
            "http://user@private.internal:8123/", "https://private.internal:8123@evil.internal/",
            "file://private.internal:8123/path", "wss://private.internal:8123/socket"
        ] {
            let refused = map.proxyURL(for: URL(string: literal)!)
            #expect(refused == nil, "\(literal)")
        }
        #expect(!map.contains(host: "p-00000000000000000000000000000000"))
        #expect(!map.contains(host: host + ":80"))
    }

    @Test func rewritesOnlyAuthorizedUnescapedAbsoluteLiterals() throws {
        var map = HostURLMap(allow: ["localhost:8123", "assets.internal:443"])
        let localURL = map.proxyURL(for: URL(string: "http://localhost:8123/")!)
        let assetsURL = map.proxyURL(for: URL(string: "https://assets.internal/")!)
        let local = try #require(localURL?.host)
        let assets = try #require(assetsURL?.host)
        let text = #"""
        🙂 <img src="http://localhost:8123/a%2Fb.png?x=%2F&amp;y=1">
        <style>.icon { background: url(https://assets.internal/image.png) }</style>
        <script>const data = 'HTTP://LOCALHOST:8123/data?x=a%2Bb'; const denied = 'http://evil.internal/?next=http://localhost:8123/';</script>
        <img src="http://localhost:8124/denied"><img src="//localhost:8123/relative">
        <script>const escaped = "http:\/\/localhost:8123/missed"; const computed = "http" + "://localhost:8123/missed";</script>
        <a href="ftp://localhost:8123/file">nothttps://assets.internal/missed</a>
        """#
        let expected = """
        🙂 <img src="canvas-kit://\(local)/a%2Fb.png?x=%2F&amp;y=1">
        <style>.icon { background: url(canvas-kit://\(assets)/image.png) }</style>
        <script>const data = 'HTTP://LOCALHOST:8123/data?x=a%2Bb'; const denied = 'http://evil.internal/?next=http://localhost:8123/';</script>
        <img src="http://localhost:8124/denied"><img src="//localhost:8123/relative">
        <script>const escaped = "http:\\/\\/localhost:8123/missed"; const computed = "http" + "://localhost:8123/missed";</script>
        <a href="ftp://localhost:8123/file">nothttps://assets.internal/missed</a>
        """
        let rewritten = map.rewriteHTML(in: text)
        #expect(rewritten == expected)
        let displayed = map.rewriteHTML(in: "<p>http://localhost:8123/ is the source</p>")
        #expect(displayed == "<p>http://localhost:8123/ is the source</p>")
        #expect(map.originalURL(for: URL(string: "canvas-kit://\(local)/data?x=a%2Bb")!)?.absoluteString == "http://localhost:8123/data?x=a%2Bb")
    }

    @Test func stylesheetRewritingPreservesCommentsAndDisplayedStrings() throws {
        var map = HostURLMap(allow: ["localhost:8123"])
        let mapped = map.proxyURL(for: URL(string: "http://localhost:8123/")!)
        let host = try #require(mapped?.host)
        let css = #"""
        /* url(http://localhost:8123/comment.png) */
        .note::after { content: "http://localhost:8123/source"; }
        .image { background: url("http://localhost:8123/image.png"); }
        @import 'http://localhost:8123/theme.css';
        """#
        let expected = """
        /* url(http://localhost:8123/comment.png) */
        .note::after { content: "http://localhost:8123/source"; }
        .image { background: url("canvas-kit://\(host)/image.png"); }
        @import 'canvas-kit://\(host)/theme.css';
        """
        let rewritten = map.rewriteCSS(in: css)
        #expect(rewritten == expected)
        let inline = #"<div style='background: url(http://localhost:8123/image.png); content: "http://localhost:8123/source"'>http://localhost:8123/source</div>"#
        let transformed = map.rewriteHTML(in: inline)
        #expect(transformed.contains("url(canvas-kit://\(host)/image.png)"))
        #expect(transformed.contains("content: \"http://localhost:8123/source\""))
        #expect(transformed.hasSuffix(">http://localhost:8123/source</div>"))
    }

    @Test func dataOperandsAndRawElementContentsArePreserved() {
        var map = HostURLMap(allow: ["localhost:8123"])
        for html in [
            #"<img src="data:text/plain,http://localhost:8123/source">"#,
            #"<img srcset="data:text/plain,http://localhost:8123/source 1x">"#,
            #"<script>const tag = '<img src="http://localhost:8123/source">';</script id="end">"#,
            #"<script>const tag = '<img src="http://localhost:8123/source">';"#,
            #"<textarea><img src="http://localhost:8123/source"></textarea id="end">"#,
            #"<title><img src="http://localhost:8123/source">"#,
            #"<!-- <img src="http://localhost:8123/source">"#,
        ] {
            let rewritten = map.rewriteHTML(in: html)
            #expect(rewritten == html)
        }
        let css = #"a { background: url("data:text/plain,http://localhost:8123/source"); }"#
        let rewritten = map.rewriteCSS(in: css)
        #expect(rewritten == css)
    }

    @Test func srcsetDescriptorsAndWhitespaceDoNotLoseCandidates() throws {
        var map = HostURLMap(allow: ["localhost:8123"])
        let mapped = map.proxyURL(for: URL(string: "http://localhost:8123/")!)
        let host = try #require(mapped?.host)
        let html = #"<img src=" http://localhost:8123/fallback " srcset="http://localhost:8123/a 1x,http://localhost:8123/b 2x, data:text/plain,http://localhost:8123/payload 3x">"#
        let expected = #"<img src="canvas-kit://"# + host + #"/fallback" srcset="canvas-kit://"# + host + #"/a 1x,canvas-kit://"# + host + #"/b 2x, data:text/plain,http://localhost:8123/payload 3x">"#
        let rewritten = map.rewriteHTML(in: html)
        #expect(rewritten == expected)
    }
}

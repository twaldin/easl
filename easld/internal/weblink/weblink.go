// Package weblink is WebLink.swift: which text is a web address, and when two spellings are the
// same page. Text is read as Foundation reads it (URL(string:) and URLComponents, rfc3986.go), so
// the `url` a browser tile gets and the addresses tiles are compared by are the app's.
package weblink

import (
	"strconv"
	"strings"
	"unicode"
)

// Parse is WebLink.parse: the http(s) URL text is, with a host, spelled as URL.absoluteString
// spells it (characters a URL can't hold percent-encoded, a non-ASCII host IDNA-encoded); false
// for anything else (other schemes, relative paths, bare hosts). Surrounding white space is
// ignored.
func Parse(text string) (string, bool) {
	u, ok := urlFromString(strings.TrimFunc(text, unicode.IsSpace))
	if !ok || !isWeb(u) {
		return "", false
	}
	return u.s, true
}

// Address is WebLink.address of URL(string: url): the address as browser tiles are compared
// (Board.openLink), with the scheme and host lowercased, a default port dropped and an empty
// path `/`. The query and the fragment stay as written (a single-page app's `#/route` is another
// page). False for a URL that isn't http(s), or whose host Foundation can't spell again.
func Address(url string) (string, bool) {
	u, ok := urlFromString(url)
	if !ok || !isWeb(u) {
		return "", false
	}
	// URLComponents(url:resolvingAgainstBaseURL: false) reads the URL's string again.
	parsed, ok := parseEncoding(u.s, false)
	if !ok {
		return "", false
	}
	c := components{info: parsed, percentEncodedHost: strings.Contains(parsed.get(parsed.host), "%")}
	scheme := strings.ToLower(parsed.get(parsed.scheme))
	c.setScheme(scheme)
	host, ok := c.decodedHost()
	c.setHost(swiftLowercased(host), ok)
	defaultPort := 80
	if scheme == "https" {
		defaultPort = 443
	}
	if port, ok := c.port(); ok && port == defaultPort {
		c.portCleared = true
	}
	if c.percentEncodedPath() == "" {
		path := "/"
		c.path = &path
	}
	return c.string()
}

// isWeb is WebLink.isWeb: an http or https URL with a host (URL.host: percent-decoded, an IP
// literal without its brackets).
func isWeb(u parseInfo) bool {
	if scheme := strings.ToLower(u.get(u.scheme)); !u.scheme.ok || (scheme != "http" && scheme != "https") {
		return false
	}
	if !u.host.ok {
		return false
	}
	host := u.get(u.host)
	if u.ipLiteral {
		host = host[1 : len(host)-1]
	}
	if strings.Contains(host, "%") {
		decoded, ok := percentDecode(host)
		return ok && decoded != ""
	}
	return host != ""
}

// swiftLowercased is String.lowercased(): Unicode's full lowercase mapping, which differs from
// the simple one Go applies only for İ (U+0130), "i̇".
func swiftLowercased(s string) string {
	if !strings.ContainsRune(s, 'İ') {
		return strings.ToLower(s)
	}
	var b strings.Builder
	for _, r := range s {
		if r == 'İ' {
			b.WriteString("i\u0307")
		} else {
			b.WriteRune(unicode.ToLower(r))
		}
	}
	return b.String()
}

// swiftInt is Int(String) for a port: decimal digits that fit an Int.
func swiftInt(s string) (int, bool) {
	n, err := strconv.ParseInt(s, 10, 64)
	return int(n), err == nil
}

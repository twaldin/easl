package weblink

import "testing"

// The expectations are Foundation's (URL(string:), URLComponents) on macOS 26.

// A tile's `url` is the address as the app spells it: as written where that is a URL, characters
// a URL can't hold percent-encoded, a non-ASCII host in punycode.
func TestParseSpellsAWebLinkAsTheAppStoresIt(t *testing.T) {
	for text, want := range map[string]string{
		"HTTP://Example.COM:80/Docs?Q=1#Top":      "HTTP://Example.COM:80/Docs?Q=1#Top",
		"  http://example.com/a  \n":              "http://example.com/a",
		"http://example.com/a b?q=a b#f g":        "http://example.com/a%20b?q=a%20b#f%20g",
		"http://example.com/%7e/%zz":              "http://example.com/%257e/%25zz",
		"http://a.b/c?d#e#f":                      "http://a.b/c?d#e%23f",
		"http://user:p@ss@example.com/":           "http://user:p%40ss@example.com/",
		"http://bücher.de/ü":                      "http://xn--bcher-kva.de/%C3%BC",
		"http://ＥＸＡＭＰＬＥ.com/":                     "http://example.com/",
		"http://example.com:0080/a b":             "http://example.com:80/a%20b",
		"http://[::1%en0]:8080/":                  "http://[::1%25en0]:8080/",
		"https://localhost:3000/#/route?x=1":      "https://localhost:3000/#/route?x=1",
		"http://example.com:99999999999999999999": "http://example.com:99999999999999999999",
	} {
		if got, ok := Parse(text); !ok || got != want {
			t.Errorf("Parse(%q) = %q, %v; want %q", text, got, ok, want)
		}
	}
}

func TestOnlyHTTPAddressesWithAHostAreWebLinks(t *testing.T) {
	for _, text := range []string{
		"", "not a url", "example.com", "/tmp/x.html", "file:///etc/hosts", "mailto:a@b.c", "ftp://127.0.0.1/file",
		"http://", "https:///path", "http:example.com", "http://user@/", "http://[]/", "http://%FF/",
		"http://exa mple.com/", "http://ex%ample.com/", "http://[::1", "http://[::1]x/", "http://example.com:abc/",
		"http://example.com:8080:90/", "http://example.com\\path", "http://a\u200db.com/", "1http://x.com",
	} {
		if got, ok := Parse(text); ok {
			t.Errorf("Parse(%q) = %q, want no web link", text, got)
		}
	}
}

// Two spellings are the same page when scheme, host, port, path, query and fragment are, with
// the scheme's and the host's case, a default port and an empty path not counting.
func TestAddressIsTheSameForTheSamePage(t *testing.T) {
	for url, want := range map[string]string{
		"HTTP://Example.COM/docs":           "http://example.com/docs",
		"http://example.com:80/docs":        "http://example.com/docs",
		"http://example.com:0080/docs":      "http://example.com/docs",
		"https://EXAMPLE.com:8443":          "https://example.com:8443/",
		"https://example.com:443?q#f":       "https://example.com/?q#f",
		"http://example.com:443/":           "http://example.com:443/",
		"http://example.com:/x":             "http://example.com/x",
		"HtTpS://Example.Com/A/B?C=D#E":     "https://example.com/A/B?C=D#E",
		"http://EXAM%70LE.com/%7E":          "http://example.com/%7E",
		"http://[FE80::1%25EN0]:80/":        "http://[fe80::1%25en0]/",
		"http://xn--NICODE-2ya.com/":        "http://xn--nicode-2ya.com/",
		"http://User:PW@Example.com/":       "http://User:PW@example.com/",
		"http://localhost:3000/#/route":     "http://localhost:3000/#/route",
		"https://www.Example.com/../a/./b/": "https://www.example.com/../a/./b/",
	} {
		if got, ok := Address(url); !ok || got != want {
			t.Errorf("Address(%q) = %q, %v; want %q", url, got, ok, want)
		}
	}
	for _, url := range []string{"ftp://example.com/", "example.com", "http://%20/", "http://a%00b/"} {
		if got, ok := Address(url); ok {
			t.Errorf("Address(%q) = %q, want none", url, got)
		}
	}
}

package weblink

import (
	"strings"
	"unicode/utf16"

	"golang.org/x/net/idna"
)

// Hosts are IDNA-coded as Foundation's UIDNAHookICU codes them: ICU's UTS #46, nontransitional,
// with the Bidi and ContextJ checks and without STD3's ASCII rules (so `_` stays valid). x/net
// does the mapping, punycode and those checks; ICU's label rules it doesn't share are checked
// here (aceLabelsOK, hyphensOK, lengthsOK).
var (
	idnaProfile = idna.New(idna.MapForLookup(), idna.StrictDomainName(false), idna.Transitional(false), idna.BidiRule(), idna.CheckHyphens(false), idna.CheckJoiners(true))
	idnaMapping = idna.New(idna.MapForLookup(), idna.StrictDomainName(false), idna.Transitional(false), idna.ValidateLabels(false))
)

// maxIDNAHost is the longest host Foundation codes.
const maxIDNAHost = 2048

// idnaEncode is RFC3986Parser.IDNAEncodeHost: the host's ASCII (punycode) spelling, false on any
// IDNA error.
func idnaEncode(host string) (string, bool) {
	if host == "" {
		return "", true
	}
	if len(host) > maxIDNAHost || !aceLabelsOK(mapped(host)) {
		return "", false
	}
	// ICU maps the host from the first label it can't take as plain ASCII to the end as a name of
	// its own, whose first label may not map to nothing (`a.` and a soft hyphen).
	if start := unicodeStart(host); start > 0 && mapped(host[start:]) == "" {
		return "", false
	}
	if unicode, err := idnaProfile.ToUnicode(host); err != nil || !hyphensOK(unicode) {
		return "", false
	}
	out, err := idnaProfile.ToASCII(host)
	if err != nil || out == "" || !lengthsOK(out) {
		return "", false
	}
	return sameUnlessChanged(host, out), true
}

// unicodeStart is where ICU's ASCII fast path ends: the start of the first label holding a
// non-ASCII character or `--` third and fourth (0 for none).
func unicodeStart(host string) int {
	start := 0
	for _, label := range strings.Split(host, ".") {
		if len(label) >= 4 && label[2] == '-' && label[3] == '-' {
			return start
		}
		for i := range len(label) {
			if label[i] >= 0x80 {
				return start
			}
		}
		start += len(label) + 1
	}
	return 0
}

// idnaDecode is RFC3986Parser.IDNADecodeHost: the host's Unicode spelling; ICU's errors for empty
// labels, lengths and hyphens are let through, any other fails.
func idnaDecode(host string) (string, bool) {
	if host == "" {
		return "", true
	}
	if len(host) > maxIDNAHost || !aceLabelsOK(mapped(host)) {
		return "", false
	}
	out, err := idnaProfile.ToUnicode(host)
	if err != nil || out == "" {
		return "", false
	}
	return sameUnlessChanged(host, out), true
}

// mapped is the host after UTS #46 mapping (case folded, compatibility forms and full stops
// mapped, ignorables dropped), its `xn--` labels as written.
func mapped(host string) string {
	var b strings.Builder
	for _, r := range host {
		switch {
		case 'A' <= r && r <= 'Z':
			b.WriteRune(r + 'a' - 'A')
		case r < 0x80:
			b.WriteRune(r)
		default:
			// One character never maps to an `xn--` label, so it isn't decoded.
			m, _ := idnaMapping.ToUnicode(string(r))
			b.WriteString(m)
		}
	}
	return b.String()
}

// aceLabelsOK: no `xn--` label ICU refuses before decoding it: one with nothing after the prefix
// or ending in `-` (an ASCII label spelled as punycode), or one holding anything but ASCII.
func aceLabelsOK(mapped string) bool {
	for _, label := range strings.Split(mapped, ".") {
		if !strings.HasPrefix(label, "xn--") {
			continue
		}
		if len(label) == 4 || len(label) > 5 && label[len(label)-1] == '-' {
			return false
		}
		for i := range len(label) {
			if label[i] >= 0x80 {
				return false
			}
		}
	}
	return true
}

// hyphensOK: no Unicode label starting or ending with `-`, or with `--` third and fourth, counted
// in UTF-16 code units as ICU counts them.
func hyphensOK(unicode string) bool {
	for _, label := range strings.Split(unicode, ".") {
		units := utf16.Encode([]rune(label))
		if len(units) == 0 {
			continue
		}
		if units[0] == '-' || units[len(units)-1] == '-' || len(units) >= 4 && units[2] == '-' && units[3] == '-' {
			return false
		}
	}
	return true
}

// lengthsOK: no empty label but a final one (the root), labels of at most 63 bytes, and at most
// 253 bytes before the root's dot (ICU's EMPTY_LABEL, LABEL_TOO_LONG, DOMAIN_NAME_TOO_LONG).
func lengthsOK(ascii string) bool {
	labels := strings.Split(ascii, ".")
	for i, label := range labels {
		if label == "" && (i != len(labels)-1 || i == 0) || len(label) > 63 {
			return false
		}
	}
	return len(strings.TrimSuffix(ascii, ".")) <= 253
}

// sameUnlessChanged: the host as it was given when coding only lowercased its ASCII letters.
func sameUnlessChanged(in, out string) string {
	if len(in) != len(out) {
		return out
	}
	for i := range len(in) {
		c := in[i]
		if 'A' <= c && c <= 'Z' {
			c += 'a' - 'A'
		}
		if in[i] != out[i] && c != out[i] {
			return out
		}
	}
	return in
}

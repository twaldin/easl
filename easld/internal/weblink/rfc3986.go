package weblink

import (
	"strconv"
	"strings"
	"unicode/utf8"
)

// The URL reading of swift-foundation's RFC3986Parser and URLComponents, as far as web links
// need it: URL(string:) encodes the characters a URL can't hold, IDNA-encodes a non-ASCII host,
// and gives up on a host it can't spell; URLComponents re-spells what is set on it. Two cases
// Foundation special-cases are left out because no web link reaches them: schemes whose host
// is percent-encoded instead of IDNA-encoded (tel:, imap:, http+unix:, …) and addressbook:'s
// free-form port.

// span is a component's byte range in the parsed string; ok is whether the component exists
// (an empty query `?` exists, a missing one doesn't).
type span struct {
	lo, hi int
	ok     bool
}

// parseInfo is URLParseInfo: a URL string and its components' ranges.
type parseInfo struct {
	s                                                         string
	scheme, user, password, host, port, path, query, fragment span
	ipLiteral                                                 bool
}

func (p parseInfo) get(c span) string { return p.s[c.lo:c.hi] }

// urlFromString is URL(string:): nil for the empty string, and an empty scheme or port is
// allowed, as NSURL allows them.
func urlFromString(s string) (parseInfo, bool) {
	if s == "" {
		return parseInfo{}, false
	}
	return parseEncoding(s, true)
}

// parseEncoding is RFC3986Parser.parse(urlString:encodingInvalidCharacters: true): every
// component holding a character it may not is percent-encoded whole (a `%` that began a valid
// escape too), a host that isn't valid as written is IDNA-encoded, and the result read again.
func parseEncoding(s string, allowEmptyScheme bool) (parseInfo, bool) {
	info, ok := parse(s, allowEmptyScheme)
	if !ok {
		return info, false
	}
	userOK := !info.user.ok || validate(info.get(info.user), userinfoMask)
	passwordOK := !info.password.ok || validate(info.get(info.password), userinfoMask)
	hostOK := !info.host.ok || validHost(info.get(info.host), info.ipLiteral)
	pathOK := validate(info.get(info.path), pathMask)
	queryOK := !info.query.ok || validate(info.get(info.query), queryMask)
	fragmentOK := !info.fragment.ok || validate(info.get(info.fragment), queryMask)
	if userOK && passwordOK && hostOK && pathOK && queryOK && fragmentOK {
		return info, true
	}
	var b strings.Builder
	if info.scheme.ok {
		b.WriteString(info.get(info.scheme))
		b.WriteByte(':')
	}
	if info.user.ok || info.password.ok || info.host.ok || info.port.ok {
		b.WriteString("//")
	}
	if info.user.ok {
		b.WriteString(encodedUnless(userOK, info.get(info.user), userinfoMask))
		if info.password.ok {
			b.WriteByte(':')
			b.WriteString(encodedUnless(passwordOK, info.get(info.password), userinfoMask))
		}
		b.WriteByte('@')
	}
	if info.host.ok {
		host := info.get(info.host)
		switch {
		case hostOK:
			b.WriteString(host)
		case info.ipLiteral || looksLikeIPLiteral(host):
			encoded, ok := percentEncodeHost(host)
			if !ok || (info.ipLiteral && !validHost(encoded, true)) {
				return parseInfo{}, false
			}
			b.WriteString(encoded)
		default:
			encoded, ok := idnaEncode(host)
			if !ok || !validHost(encoded, false) {
				return parseInfo{}, false
			}
			b.WriteString(encoded)
		}
	}
	// The port is written as the number it is: leading zeros go, and one too large for an Int
	// (or empty) is dropped.
	if info.port.ok {
		if port, ok := swiftInt(info.get(info.port)); ok {
			b.WriteByte(':')
			b.WriteString(strconv.Itoa(port))
		}
	}
	if pathOK {
		b.WriteString(info.get(info.path))
	} else {
		b.WriteString(percentEncodePath(info.get(info.path)))
	}
	if info.query.ok {
		b.WriteByte('?')
		b.WriteString(encodedUnless(queryOK, info.get(info.query), queryMask))
	}
	if info.fragment.ok {
		b.WriteByte('#')
		b.WriteString(encodedUnless(fragmentOK, info.get(info.fragment), queryMask))
	}
	return parse(b.String(), allowEmptyScheme)
}

func encodedUnless(valid bool, s string, m mask) string {
	if valid {
		return s
	}
	return percentEncode(s, m)
}

// parse is RFC3986Parser.parse(buffer:): the components by their delimiters, nothing encoded.
// False when the scheme, an IP literal's end or the port is malformed.
func parse(s string, allowEmptyScheme bool) (parseInfo, bool) {
	info := parseInfo{s: s}
	n := len(s)
	if n == 0 {
		info.path = span{0, 0, true}
		return info, true
	}
	i := 0
	for i != n {
		v := s[i]
		if v == ':' {
			// A scheme is at least one character, otherwise this is a relative reference.
			if i != 0 || allowEmptyScheme {
				info.scheme = span{0, i, true}
				i++
				if i == n {
					if !validScheme(s[:info.scheme.hi], allowEmptyScheme) {
						return info, false
					}
					info.path = span{n, n, true}
					return info, true
				}
			}
			break
		}
		// "[", "]" and "@" say the text before them is meant as an authority.
		if strings.IndexByte("/?#[]@", v) >= 0 {
			i = 0
			break
		}
		i++
	}
	if info.scheme.ok && !validScheme(s[:info.scheme.hi], allowEmptyScheme) {
		return info, false
	}
	if i == n {
		i = 0
	}
	if i+1 < n && s[i] == '/' && s[i+1] == '/' {
		i += 2
		start := i
		for i != n && s[i] != '/' && s[i] != '?' && s[i] != '#' {
			i++
		}
		if start == i {
			// The host exists, empty; nothing else of the authority does.
			info.host = span{start, i, true}
		} else {
			if !parseAuthority(s, start, i, &info, allowEmptyScheme) {
				return info, false
			}
			if info.port.ok && strings.Trim(info.get(info.port), "0123456789") != "" {
				return info, false
			}
		}
	}
	start := i
	for i != n && s[i] != '?' && s[i] != '#' {
		i++
	}
	info.path = span{start, i, true}
	if i == n {
		return info, true
	}
	if s[i] == '?' {
		if pound := strings.IndexByte(s[i+1:], '#'); pound >= 0 {
			info.query = span{i + 1, i + 1 + pound, true}
			info.fragment = span{i + 2 + pound, n, true}
		} else {
			info.query = span{i + 1, n, true}
		}
	} else {
		info.fragment = span{i + 1, n, true}
	}
	return info, true
}

// parseAuthority is RFC3986Parser.parseAuthority: user and password before the last `@`, then
// the host (an IP literal in brackets) and the port after its `:`.
func parseAuthority(s string, lo, hi int, info *parseInfo, allowEmptyScheme bool) bool {
	hostStart, hostEnd := lo, hi
	if at := strings.LastIndexByte(s[lo:hi], '@'); at >= 0 {
		at += lo
		if colon := strings.IndexByte(s[lo:at], ':'); colon >= 0 {
			info.user = span{lo, lo + colon, true}
			info.password = span{lo + colon + 1, at, true}
		} else {
			info.user = span{lo, at, true}
		}
		hostStart = at + 1
	}
	if end := strings.IndexByte(s[hostStart:hi], ']'); hostStart != hi && s[hostStart] == '[' && end >= 0 {
		info.ipLiteral = true
		hostEnd = hostStart + end + 1
		if hostEnd != hi {
			if s[hostEnd] != ':' {
				return false
			}
			info.port = span{hostEnd + 1, hi, true}
		}
	} else if colon := strings.IndexByte(s[hostStart:hi], ':'); colon >= 0 {
		hostEnd = hostStart + colon
		// RFC 3986 drops an empty port's `:`; NSURL keeps it.
		if hostEnd+1 != hi || allowEmptyScheme {
			info.port = span{hostEnd + 1, hi, true}
		}
	}
	info.host = span{hostStart, hostEnd, true}
	return true
}

// mask is URLComponentAllowedMask: the ASCII characters a component may hold as they are, bit c
// for character c.
type mask struct{ lo, hi uint64 }

func (m mask) has(c byte) bool {
	switch {
	case c < 64:
		return m.lo>>c&1 == 1
	case c < 128:
		return m.hi>>(c-64)&1 == 1
	}
	return false
}

// The masks of RFC 3986's grammar, as Foundation spells them: unreserved = ALPHA DIGIT "-._~",
// sub-delims = "!$&'()*+,;=", pchar = unreserved sub-delims ":@". The user and the password are
// split at the first `:`, so only a password can hold one.
var (
	schemeMask       = mask{hi: 0x07fffffe07fffffe, lo: 0x03ff680000000000} // ALPHA DIGIT "+-."
	userinfoMask     = mask{hi: 0x47fffffe87fffffe, lo: 0x2fff7fd200000000} // unreserved sub-delims ":" (also an IP literal's address)
	regNameMask      = mask{hi: 0x47fffffe87fffffe, lo: 0x2bff7fd200000000} // unreserved sub-delims: a host
	zoneIDMask       = mask{hi: 0x47fffffe87fffffe, lo: 0x03ff600000000000} // unreserved
	pathMask         = mask{hi: 0x47fffffe87ffffff, lo: 0x2fffffd200000000} // pchar "/"
	pathFirstSegMask = mask{hi: 0x47fffffe87ffffff, lo: 0x2bffffd200000000} // pchar "/" without ":"
	queryMask        = mask{hi: 0x47fffffe87ffffff, lo: 0xafffffd200000000} // pchar "/?" (also the fragment's)
)

func validScheme(s string, allowEmpty bool) bool {
	if s == "" {
		return allowEmpty
	}
	return s[0] >= 'A' && allowed(s, schemeMask)
}

// allowed: every byte of s is one m allows (no escapes).
func allowed(s string, m mask) bool {
	for i := range len(s) {
		if !m.has(s[i]) {
			return false
		}
	}
	return true
}

// validate is RFC3986Parser.validate(buffer:component:): every byte one m allows, or a `%`
// followed by two hex digits.
func validate(s string, m mask) bool {
	hexRequired := 0
	for i := range len(s) {
		v := s[i]
		switch {
		case v >= 128:
			return false
		case v == '%':
			if hexRequired != 0 {
				return false
			}
			hexRequired = 2
		case !m.has(v):
			return false
		case hexRequired > 0:
			if !isHex(v) {
				return false
			}
			hexRequired--
		}
	}
	return hexRequired == 0
}

func isHex(c byte) bool {
	return '0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F'
}

func looksLikeIPLiteral(host string) bool {
	return len(host) > 0 && host[0] == '[' && host[len(host)-1] == ']'
}

// validHost is RFC3986Parser.validate(host:): a reg-name, or an IP literal whose zone ID (after
// its delimiter, which must be written `%25`) is unreserved characters and escapes.
func validHost(host string, knownIPLiteral bool) bool {
	if !knownIPLiteral && !looksLikeIPLiteral(host) {
		return validate(host, regNameMask)
	}
	inner := host[1 : len(host)-1]
	percent := strings.IndexByte(inner, '%')
	if percent < 0 {
		return allowed(inner, userinfoMask)
	}
	if !strings.HasPrefix(inner[percent:], "%25") {
		return false
	}
	return allowed(inner[:percent], userinfoMask) && validate(inner[percent+3:], zoneIDMask)
}

// percentEncode is addingPercentEncoding(forURLComponent:): every byte m doesn't allow, `%`
// included, as %XX.
func percentEncode(s string, m mask) string {
	var b strings.Builder
	for i := range len(s) {
		if v := s[i]; m.has(v) {
			b.WriteByte(v)
		} else {
			b.WriteByte('%')
			b.WriteByte("0123456789ABCDEF"[v>>4])
			b.WriteByte("0123456789ABCDEF"[v&0xF])
		}
	}
	return b.String()
}

// percentEncodePath keeps a `:` out of a relative path's first segment, where it would read as a
// scheme.
func percentEncodePath(path string) string {
	slash := strings.IndexByte(path, '/')
	switch {
	case slash < 0:
		return percentEncode(path, pathFirstSegMask)
	case slash == 0:
		return percentEncode(path, pathMask)
	}
	return percentEncode(path[:slash], pathFirstSegMask) + percentEncode(path[slash:], pathMask)
}

// percentEncodeHost is RFC3986Parser.percentEncodeHost: an IP literal keeps its address and has
// only its zone ID encoded (false when the address isn't valid); a reg-name is encoded whole.
func percentEncodeHost(host string) (string, bool) {
	if host == "" || !looksLikeIPLiteral(host) {
		return percentEncode(host, regNameMask), true
	}
	percent := strings.IndexByte(host, '%')
	if percent < 0 {
		return host, validHost(host, true)
	}
	return host[:percent] + percentEncode(host[percent:len(host)-1], zoneIDMask) + "]", true
}

// percentDecode is removingPercentEncoding: false for a malformed escape or bytes that aren't
// UTF-8.
func percentDecode(s string) (string, bool) {
	if !strings.Contains(s, "%") {
		return s, true
	}
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] != '%' {
			b = append(b, s[i])
			continue
		}
		if i+2 >= len(s) || !isHex(s[i+1]) || !isHex(s[i+2]) {
			return "", false
		}
		v, _ := strconv.ParseUint(s[i+1:i+3], 16, 8)
		b = append(b, byte(v))
		i += 2
	}
	return string(b), utf8.Valid(b)
}

// components is URLComponents built from a string, with what WebLink.address sets on it: the
// scheme, the host, the port cleared and the path.
type components struct {
	info   parseInfo
	scheme string
	// hostSet: the host was set (the parsed one no longer counts); host is what was set (nil
	// for none).
	hostSet bool
	host    *string
	// percentEncodedHost: the host is spelled with escapes rather than IDNA (didPercentEncodeHost).
	percentEncodedHost bool
	// invalidHost: a host was set that has no valid spelling, so there is no string.
	invalidHost bool
	portCleared bool
	path        *string
}

// setScheme also sets the host again, as it decodes, so that it is spelled for the scheme.
func (c *components) setScheme(scheme string) {
	c.scheme = scheme
	if _, ok := c.encodedHost(); ok {
		host, ok := c.decodedHost()
		c.setHost(host, ok)
	}
}

func (c *components) encodedHost() (string, bool) {
	if c.host != nil {
		return *c.host, true
	}
	if !c.hostSet && c.info.host.ok {
		return c.info.get(c.info.host), true
	}
	_, hasPort := c.port()
	_, hasUser := c.user()
	return "", hasPort || hasUser
}

// decodedHost is URLComponents.host: escapes or IDNA undone.
func (c *components) decodedHost() (string, bool) {
	host, ok := c.encodedHost()
	if !ok || host == "" {
		return "", ok
	}
	if c.percentEncodedHost {
		return percentDecode(host)
	}
	return idnaDecode(host)
}

// setHost is URLComponents.host's setter: kept as it is when valid, else an IP literal's zone ID
// percent-encoded, else IDNA-encoded; a host none of those spell leaves no string.
func (c *components) setHost(host string, ok bool) {
	c.hostSet, c.host, c.percentEncodedHost, c.invalidHost = true, nil, false, false
	switch {
	case !ok:
	case validHost(host, false):
		c.host = &host
		c.percentEncodedHost = strings.Contains(host, "%")
	case looksLikeIPLiteral(host):
		if encoded, ok := percentEncodeHost(host); ok {
			c.host, c.percentEncodedHost = &encoded, true
		} else {
			c.invalidHost = true
		}
	default:
		if encoded, ok := idnaEncode(host); ok && validHost(encoded, false) {
			c.host = &encoded
			return
		}
		encoded, _ := percentEncodeHost(host)
		c.host, c.percentEncodedHost, c.invalidHost = &encoded, true, true
	}
}

func (c *components) port() (int, bool) {
	if c.portCleared || !c.info.port.ok {
		return 0, false
	}
	return swiftInt(c.info.get(c.info.port))
}

func (c *components) user() (string, bool) {
	if c.info.user.ok {
		return c.info.get(c.info.user), true
	}
	return "", c.info.password.ok
}

func (c *components) percentEncodedPath() string {
	if c.path != nil {
		return *c.path
	}
	return c.info.get(c.info.path)
}

// string is URLComponents.string once a component was set: rebuilt from the components; false
// when the host has no valid spelling or the path can't follow what precedes it.
func (c *components) string() (string, bool) {
	if c.invalidHost {
		return "", false
	}
	host, hasHost := c.encodedHost()
	port, hasPort := c.port()
	user, hasUser := c.user()
	path := c.percentEncodedPath()
	var b strings.Builder
	b.WriteString(c.scheme)
	b.WriteByte(':')
	if hasHost || hasPort || hasUser {
		if path != "" && path[0] != '/' {
			return "", false
		}
		b.WriteString("//")
	} else if strings.HasPrefix(path, "//") {
		return "", false
	}
	if hasUser {
		b.WriteString(user)
	}
	if c.info.password.ok {
		b.WriteByte(':')
		b.WriteString(c.info.get(c.info.password))
	}
	if hasUser {
		b.WriteByte('@')
	}
	b.WriteString(host)
	if hasPort {
		b.WriteByte(':')
		b.WriteString(strconv.Itoa(port))
	} else if !c.portCleared && c.info.port.ok {
		// A port that isn't an Int (empty, or too large) stays as written.
		b.WriteByte(':')
		b.WriteString(c.info.get(c.info.port))
	}
	b.WriteString(path)
	if c.info.query.ok {
		b.WriteByte('?')
		b.WriteString(c.info.get(c.info.query))
	}
	if c.info.fragment.ok {
		b.WriteByte('#')
		b.WriteString(c.info.get(c.info.fragment))
	}
	return b.String(), true
}

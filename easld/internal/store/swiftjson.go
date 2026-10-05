package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"sort"
	"strconv"
	"unicode/utf8"
)

// The board file is written as Swift's JSONEncoder writes it, so a board saved by easld and one
// saved by the app read the same: keys sorted, `/` escaped as `\/` (unless withoutEscapingSlashes),
// non-ASCII left as is, and prettyPrinted output indented by two spaces with ` : ` between a key
// and its value (an empty container's lines are blank).

type swiftJSON struct {
	pretty      bool
	escapeSlash bool
	buf         bytes.Buffer
	err         error
}

// EncodeSwift writes v (generic JSON values) as Swift's JSONEncoder would with sortedKeys. Like
// JSONEncoder it fails on NaN and infinities (NonFinite) and then writes nothing.
func EncodeSwift(v any, pretty, escapeSlashes bool) ([]byte, error) {
	e := &swiftJSON{pretty: pretty, escapeSlash: escapeSlashes}
	e.value(v, 0)
	if e.err != nil {
		return nil, e.err
	}
	return e.buf.Bytes(), nil
}

// NonFinite is JSONEncoder's EncodingError.invalidValue for a NaN or infinite Double. Error() is
// its localizedDescription (Cocoa's coderInvalidValue), which board.export reports.
type NonFinite struct{ Value float64 }

func (NonFinite) Error() string {
	return "The data couldn’t be written because it isn’t in the correct format."
}

// Debug is the encoder's debugDescription of the value.
func (n NonFinite) Debug() string {
	what := "Double.nan"
	switch {
	case math.IsInf(n.Value, 1):
		what = "Double.infinity"
	case math.IsInf(n.Value, -1):
		what = "-Double.infinity"
	}
	return "Unable to encode " + what + " directly in JSON."
}

func (e *swiftJSON) indent(depth int) {
	e.buf.WriteByte('\n')
	for range depth {
		e.buf.WriteString("  ")
	}
}

func (e *swiftJSON) value(v any, depth int) {
	switch x := v.(type) {
	case nil:
		e.buf.WriteString("null")
	case bool:
		if x {
			e.buf.WriteString("true")
		} else {
			e.buf.WriteString("false")
		}
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			e.fail(NonFinite{x})
			return
		}
		e.buf.WriteString(swiftNumber(x))
	case int:
		e.buf.WriteString(strconv.Itoa(x))
	case string:
		e.str(x)
	case []any:
		e.buf.WriteByte('[')
		if len(x) == 0 {
			if e.pretty {
				e.buf.WriteByte('\n')
				e.indent(depth)
			}
			e.buf.WriteByte(']')
			return
		}
		for i, item := range x {
			if i > 0 {
				e.buf.WriteByte(',')
			}
			if e.pretty {
				e.indent(depth + 1)
			}
			e.value(item, depth+1)
		}
		if e.pretty {
			e.indent(depth)
		}
		e.buf.WriteByte(']')
	case map[string]any:
		e.buf.WriteByte('{')
		if len(x) == 0 {
			if e.pretty {
				e.buf.WriteByte('\n')
				e.indent(depth)
			}
			e.buf.WriteByte('}')
			return
		}
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for i, k := range keys {
			if i > 0 {
				e.buf.WriteByte(',')
			}
			if e.pretty {
				e.indent(depth + 1)
			}
			e.str(k)
			if e.pretty {
				e.buf.WriteString(" : ")
			} else {
				e.buf.WriteByte(':')
			}
			e.value(x[k], depth+1)
		}
		if e.pretty {
			e.indent(depth)
		}
		e.buf.WriteByte('}')
	default:
		// Typed values: round-trip through encoding/json into generic form.
		data, err := json.Marshal(x)
		if err != nil {
			// encoding/json names the unsupported float as "+Inf", "-Inf" or "NaN".
			var unsupported *json.UnsupportedValueError
			if errors.As(err, &unsupported) {
				if f, perr := strconv.ParseFloat(unsupported.Str, 64); perr == nil {
					err = NonFinite{f}
				}
			}
			e.fail(err)
			return
		}
		var generic any
		_ = json.Unmarshal(data, &generic)
		e.value(generic, depth)
	}
}

func (e *swiftJSON) fail(err error) {
	if e.err == nil {
		e.err = err
	}
}

func (e *swiftJSON) str(s string) {
	const hex = "0123456789abcdef"
	e.buf.WriteByte('"')
	for i := 0; i < len(s); {
		c := s[i]
		if c >= utf8.RuneSelf {
			r, size := utf8.DecodeRuneInString(s[i:])
			e.buf.WriteRune(r)
			i += size
			continue
		}
		switch c {
		case '"':
			e.buf.WriteString(`\"`)
		case '\\':
			e.buf.WriteString(`\\`)
		case '/':
			if e.escapeSlash {
				e.buf.WriteString(`\/`)
			} else {
				e.buf.WriteByte('/')
			}
		case '\n':
			e.buf.WriteString(`\n`)
		case '\r':
			e.buf.WriteString(`\r`)
		case '\t':
			e.buf.WriteString(`\t`)
		case '\b':
			e.buf.WriteString(`\b`)
		case '\f':
			e.buf.WriteString(`\f`)
		default:
			if c < 0x20 {
				e.buf.WriteString(`\u00`)
				e.buf.WriteByte(hex[c>>4])
				e.buf.WriteByte(hex[c&0xf])
			} else {
				e.buf.WriteByte(c)
			}
		}
		i++
	}
	e.buf.WriteByte('"')
}

// swiftNumber formats a Double as JSONEncoder does: integral values without a fraction, others
// in their shortest round-tripping form.
func swiftNumber(f float64) string {
	if f == math.Trunc(f) && math.Abs(f) < 1e16 {
		return strconv.FormatFloat(f, 'f', -1, 64)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

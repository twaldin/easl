// Package swiftjson writes JSON as Swift's JSONEncoder does, so what easld writes (board files,
// socket replies and events) reads the same as what the app writes: keys sorted, `/` escaped as
// `\/` (unless withoutEscapingSlashes), non-ASCII left as is, numbers as Swift formats a Double,
// and prettyPrinted output indented by two spaces with ` : ` between a key and its value (an
// empty container's lines are blank).
package swiftjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"sort"
	"strconv"
	"unicode/utf8"
)

type encoder struct {
	pretty      bool
	escapeSlash bool
	buf         bytes.Buffer
	err         error
}

// Encode writes v (generic JSON values; typed ones go through encoding/json first) as Swift's
// JSONEncoder would with sortedKeys. Like JSONEncoder it fails on NaN and infinities (NonFinite)
// and then writes nothing.
func Encode(v any, pretty, escapeSlashes bool) ([]byte, error) {
	e := &encoder{pretty: pretty, escapeSlash: escapeSlashes}
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

func (e *encoder) indent(depth int) {
	e.buf.WriteByte('\n')
	for range depth {
		e.buf.WriteString("  ")
	}
}

func (e *encoder) value(v any, depth int) {
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
		e.number(x)
	case int:
		e.number(float64(x)) // Swift holds every JSON number as a Double
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

func (e *encoder) fail(err error) {
	if e.err == nil {
		e.err = err
	}
}

func (e *encoder) str(s string) {
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

func (e *encoder) number(v float64) {
	var scratch [32]byte
	e.buf.Write(AppendNumber(scratch[:0], v))
}

// Number is how JSONEncoder writes a Double: Double.description without a trailing `.0`, so
// decimal (`3`, `0.5`, `1234567.5`, `9007199254740992`) from 1e-4 up to 2^53 in magnitude and
// exponential outside that (`9.1e+15`, `1e+16`, `1e-05`), always the shortest digits that read
// back as the same Double.
func Number(v float64) string {
	var scratch [32]byte
	return string(AppendNumber(scratch[:0], v))
}

// AppendNumber appends Number(v) to dst.
func AppendNumber(dst []byte, v float64) []byte {
	if v == 0 {
		if math.Signbit(v) {
			return append(dst, "-0"...)
		}
		return append(dst, '0')
	}
	if abs := math.Abs(v); abs > 1<<53 || abs < 1e-4 {
		return strconv.AppendFloat(dst, v, 'e', -1, 64) // two exponent digits at least, as Swift
	}
	return strconv.AppendFloat(dst, v, 'f', -1, 64)
}

// Description is Double.description, which Swift interpolates into messages: Number with `.0`
// on an integral decimal (`3.0`, `9007199254740992.0`), and `nan`, `inf`, `-inf`.
func Description(v float64) string {
	switch {
	case math.IsNaN(v):
		return "nan"
	case math.IsInf(v, 1):
		return "inf"
	case math.IsInf(v, -1):
		return "-inf"
	}
	var scratch [32]byte
	s := AppendNumber(scratch[:0], v)
	if bytes.IndexAny(s, ".e") < 0 {
		s = append(s, ".0"...)
	}
	return string(s)
}

package measure

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// DecodingError is a Swift JSONDecoder failure, its Error() the text `String(describing:)` gives
// it (Swift 6.3 Foundation), which the API reports as an `invalid_params` message.
type DecodingError struct{ Text string }

func (e *DecodingError) Error() string { return e.Text }

// CodingPath is where a value sits in what is decoded: keys, and array indexes.
type CodingPath []string

func (p CodingPath) key(k string) CodingPath {
	return append(append(CodingPath{}, p...), k)
}

func (p CodingPath) index(i int) CodingPath {
	return append(append(CodingPath{}, p...), "["+strconv.Itoa(i)+"]")
}

func (p CodingPath) text() string {
	var b strings.Builder
	for i, part := range p {
		if i > 0 && !strings.HasPrefix(part, "[") {
			b.WriteByte('.')
		}
		b.WriteString(part)
	}
	return b.String()
}

func (p CodingPath) suffix() string {
	if len(p) == 0 {
		return ""
	}
	return " Path: " + p.text() + "."
}

func found(v any) string {
	switch v.(type) {
	case float64:
		return "number"
	case string:
		return "a string"
	case bool:
		return "bool"
	case []any:
		return "an array"
	case map[string]any:
		return "a dictionary"
	}
	return "null"
}

func typeMismatch(want string, v any, path CodingPath) error {
	return &DecodingError{fmt.Sprintf("DecodingError.typeMismatch: expected value of type %s.%s Debug description: Expected to decode %s but found %s instead.", want, path.suffix(), want, found(v))}
}

func valueNotFound(want string, path CodingPath) error {
	detail := "Cannot get value of type " + want + " -- found null value instead"
	switch want {
	case "Array<Any>":
		detail = "Cannot get unkeyed decoding container -- found null value instead"
	case "Dictionary<String, Any>":
		detail = "Cannot get keyed decoding container -- found null value instead"
	}
	return &DecodingError{fmt.Sprintf("DecodingError.valueNotFound: Expected value of type %s but found null instead.%s Debug description: %s", want, path.suffix(), detail)}
}

// DataCorrupted is `DecodingError.dataCorruptedError(forKey:in:debugDescription:)` at path.
func DataCorrupted(path CodingPath, description string) error {
	return &DecodingError{fmt.Sprintf("DecodingError.dataCorrupted: Data was corrupted.%s Debug description: %s", path.suffix(), description)}
}

func keyNotFound(key string, path CodingPath) error {
	return &DecodingError{fmt.Sprintf("DecodingError.keyNotFound: Key '%s' not found in keyed decoding container.%s Debug description: No value associated with key CodingKeys(stringValue: \"%s\", intValue: nil) (\"%s\").", key, path.suffix(), key, key)}
}

func notRepresentable(n float64) error {
	text := SwiftJSONNumber(n)
	return &DecodingError{fmt.Sprintf("DecodingError.dataCorrupted: Data was corrupted. Debug description: The given data was not valid JSON.. Underlying error: Error Domain=NSCocoaErrorDomain Code=3840 \"Number %s is not representable in Swift.\" UserInfo={NSDebugDescription=Number %s is not representable in Swift.}", text, text)}
}

// SwiftJSONNumber is how Swift's JSONEncoder writes a Double: its shortest description, decimal
// from 1e-4 up to 2^53 and exponential (`1e+16`, `1e-06`) outside that, without a `.0`.
func SwiftJSONNumber(v float64) string {
	if v == 0 {
		if math.Signbit(v) {
			return "-0"
		}
		return "0"
	}
	abs := math.Abs(v)
	if abs >= 1<<53 || abs < 1e-4 {
		s := strconv.FormatFloat(v, 'e', -1, 64) // 1e+16, 1.5e-07
		return s
	}
	s := strconv.FormatFloat(v, 'f', -1, 64)
	return strings.TrimSuffix(s, ".0")
}

// Keyed is a keyed decoding container over a JSON object.
type Keyed struct {
	M    map[string]any
	Path CodingPath
}

// DecodeKeyed opens v (at path) as a keyed container.
func DecodeKeyed(v any, path CodingPath) (Keyed, error) {
	switch m := v.(type) {
	case map[string]any:
		return Keyed{M: m, Path: path}, nil
	case nil:
		return Keyed{}, valueNotFound("Dictionary<String, Any>", path)
	}
	return Keyed{}, typeMismatch("Dictionary<String, Any>", v, path)
}

func (k Keyed) present(key string) (any, bool) {
	v, ok := k.M[key]
	return v, ok && v != nil
}

func (k Keyed) required(key string) (any, error) {
	v, ok := k.M[key]
	if !ok {
		return nil, keyNotFound(key, k.Path)
	}
	return v, nil
}

// DecodeString decodes a String at path.
func DecodeString(v any, path CodingPath) (string, error) {
	switch s := v.(type) {
	case string:
		return s, nil
	case nil:
		return "", valueNotFound("String", path)
	}
	return "", typeMismatch("String", v, path)
}

// DecodeInt decodes an Int at path: an integral number within Int64.
func DecodeInt(v any, path CodingPath) (int, error) {
	switch n := v.(type) {
	case float64:
		if n != math.Trunc(n) || n >= 9223372036854775808.0 || n < -9223372036854775808.0 {
			return 0, notRepresentable(n)
		}
		return int(n), nil
	case nil:
		return 0, valueNotFound("Int", path)
	}
	return 0, typeMismatch("Int", v, path)
}

// DecodeBool decodes a Bool at path.
func DecodeBool(v any, path CodingPath) (bool, error) {
	switch b := v.(type) {
	case bool:
		return b, nil
	case nil:
		return false, valueNotFound("Bool", path)
	}
	return false, typeMismatch("Bool", v, path)
}

// DecodeArray opens v as an unkeyed container.
func DecodeArray(v any, path CodingPath) ([]any, error) {
	switch a := v.(type) {
	case []any:
		return a, nil
	case nil:
		return nil, valueNotFound("Array<Any>", path)
	}
	return nil, typeMismatch("Array<Any>", v, path)
}

func (k Keyed) String(key string) (string, error) {
	v, err := k.required(key)
	if err != nil {
		return "", err
	}
	return DecodeString(v, k.Path.key(key))
}

// StringIfPresent is decodeIfPresent(String.self): nil for an absent or null key.
func (k Keyed) StringIfPresent(key string) (*string, error) {
	v, ok := k.present(key)
	if !ok {
		return nil, nil
	}
	s, err := DecodeString(v, k.Path.key(key))
	if err != nil {
		return nil, err
	}
	return &s, nil
}

func (k Keyed) Int(key string) (int, error) {
	v, err := k.required(key)
	if err != nil {
		return 0, err
	}
	return DecodeInt(v, k.Path.key(key))
}

func (k Keyed) IntIfPresent(key string) (*int, error) {
	v, ok := k.present(key)
	if !ok {
		return nil, nil
	}
	n, err := DecodeInt(v, k.Path.key(key))
	if err != nil {
		return nil, err
	}
	return &n, nil
}

func (k Keyed) BoolIfPresent(key string) (*bool, error) {
	v, ok := k.present(key)
	if !ok {
		return nil, nil
	}
	b, err := DecodeBool(v, k.Path.key(key))
	if err != nil {
		return nil, err
	}
	return &b, nil
}

// Nested opens a required nested keyed container.
func (k Keyed) Nested(key string) (Keyed, error) {
	v, err := k.required(key)
	if err != nil {
		return Keyed{}, err
	}
	return DecodeKeyed(v, k.Path.key(key))
}

// NestedIfPresent opens an optional nested keyed container; ok false when absent or null.
func (k Keyed) NestedIfPresent(key string) (Keyed, bool, error) {
	v, ok := k.present(key)
	if !ok {
		return Keyed{}, false, nil
	}
	nested, err := DecodeKeyed(v, k.Path.key(key))
	return nested, err == nil, err
}

// Strings decodes a required [String].
func (k Keyed) Strings(key string) ([]string, error) {
	v, err := k.required(key)
	if err != nil {
		return nil, err
	}
	path := k.Path.key(key)
	items, err := DecodeArray(v, path)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(items))
	for i, item := range items {
		s, err := DecodeString(item, path.index(i))
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, nil
}

// Enum decodes a required String-backed enum named typeName (its Swift type name).
func (k Keyed) Enum(key, typeName string, cases ...string) (string, error) {
	s, err := k.String(key)
	if err != nil {
		return "", err
	}
	return checkCase(s, typeName, cases, k.Path.key(key))
}

// EnumIfPresent decodes an optional String-backed enum.
func (k Keyed) EnumIfPresent(key, typeName string, cases ...string) (*string, error) {
	s, err := k.StringIfPresent(key)
	if err != nil || s == nil {
		return nil, err
	}
	c, err := checkCase(*s, typeName, cases, k.Path.key(key))
	if err != nil {
		return nil, err
	}
	return &c, nil
}

func checkCase(s, typeName string, cases []string, path CodingPath) (string, error) {
	for _, c := range cases {
		if c == s {
			return s, nil
		}
	}
	return "", DataCorrupted(path, "Cannot initialize "+typeName+" from invalid String value "+s)
}

// LineRange decodes a required LineRange ({start, end}).
func (k Keyed) LineRange(key string) (start, end int, err error) {
	nested, err := k.Nested(key)
	if err != nil {
		return 0, 0, err
	}
	return DecodeLineRangeIn(nested)
}

// DecodeLineRangeIn decodes LineRange's fields from its container.
func DecodeLineRangeIn(k Keyed) (start, end int, err error) {
	if start, err = k.Int("start"); err != nil {
		return 0, 0, err
	}
	if end, err = k.Int("end"); err != nil {
		return 0, 0, err
	}
	return start, end, nil
}

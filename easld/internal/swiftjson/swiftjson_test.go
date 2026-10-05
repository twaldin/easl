package swiftjson

import (
	"math"
	"testing"
)

// Ground truth printed by Swift 6 on macOS 26: `v.description` and `JSONEncoder().encode([v])`.
var swiftDoubles = []struct {
	v                 float64
	description, json string
}{
	{0, "0.0", "0"},
	{math.Copysign(0, -1), "-0.0", "-0"},
	{1, "1.0", "1"},
	{-1, "-1.0", "-1"},
	{0.5, "0.5", "0.5"},
	{0.1, "0.1", "0.1"},
	{1234567.5, "1234567.5", "1234567.5"},
	{-1234567.5, "-1234567.5", "-1234567.5"},
	{123456789.5, "123456789.5", "123456789.5"},
	{72.33333333333333, "72.33333333333333", "72.33333333333333"},
	{1e6, "1000000.0", "1000000"},
	{1e15, "1000000000000000.0", "1000000000000000"},
	{999999999999999.9, "999999999999999.9", "999999999999999.9"},
	{9007199254740991, "9007199254740991.0", "9007199254740991"},
	{9007199254740992, "9007199254740992.0", "9007199254740992"},
	{-9007199254740992, "-9007199254740992.0", "-9007199254740992"},
	{9007199254740994, "9.007199254740994e+15", "9.007199254740994e+15"},
	{9.1e15, "9.1e+15", "9.1e+15"},
	{1e16, "1e+16", "1e+16"},
	{1.2e16, "1.2e+16", "1.2e+16"},
	{1e21, "1e+21", "1e+21"},
	{9223372036854775807, "9.223372036854776e+18", "9.223372036854776e+18"},
	{1e100, "1e+100", "1e+100"},
	{1.7976931348623157e308, "1.7976931348623157e+308", "1.7976931348623157e+308"},
	{1e-4, "0.0001", "0.0001"},
	{-1e-4, "-0.0001", "-0.0001"},
	{0.00012, "0.00012", "0.00012"},
	{9.99e-5, "9.99e-05", "9.99e-05"},
	{0.00009999999999999999, "9.999999999999999e-05", "9.999999999999999e-05"},
	{1e-6, "1e-06", "1e-06"},
	{1.5e-7, "1.5e-07", "1.5e-07"},
	{1.23e-18, "1.23e-18", "1.23e-18"},
	{5e-324, "5e-324", "5e-324"},
}

func TestNumbersAsSwiftWritesThem(t *testing.T) {
	for _, c := range swiftDoubles {
		if got := Number(c.v); got != c.json {
			t.Errorf("Number(%v) = %s, Swift's JSONEncoder writes %s", c.v, got, c.json)
		}
		if got := Description(c.v); got != c.description {
			t.Errorf("Description(%v) = %s, Swift's Double.description is %s", c.v, got, c.description)
		}
	}
	for v, want := range map[float64]string{math.NaN(): "nan", math.Inf(1): "inf", math.Inf(-1): "-inf"} {
		if got := Description(v); got != want {
			t.Errorf("Description(%v) = %s, want %s", v, got, want)
		}
	}
}

func TestEncodeMatchesJSONEncoder(t *testing.T) {
	// JSONEncoder with .sortedKeys: {"a\/b":[1234567.5,3,9.1e+15,-0]}
	got, err := Encode(map[string]any{"a/b": []any{1234567.5, 3, 9.1e15, math.Copysign(0, -1)}}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"a\/b":[1234567.5,3,9.1e+15,-0]}`; string(got) != want {
		t.Errorf("got %s, want %s", got, want)
	}
	if _, err := Encode(map[string]any{"x": math.NaN()}, false, true); err == nil {
		t.Error("NaN encoded; JSONEncoder throws")
	}
}

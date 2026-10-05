package route

import "math"

// hypot is Darwin libm's hypot, which Swift's `hypot` calls: √(fma(y, y, x²)) with x the larger
// magnitude (matched bit for bit against libm over 10⁶ samples, scaled at the extremes). Go's
// math.Hypot (p·√(1+(q/p)²)) differs by an ulp about a third of the time, and routes are reported
// unrounded (an arrow's frame is its path's bounds), so the ulp would show.
func hypot(x, y float64) float64 {
	x, y = math.Abs(x), math.Abs(y)
	switch {
	case math.IsInf(x, 0) || math.IsInf(y, 0):
		return math.Inf(1)
	case math.IsNaN(x) || math.IsNaN(y):
		return math.NaN()
	}
	if x < y {
		x, y = y, x
	}
	switch {
	case x > 0x1p500:
		x, y = x*0x1p-600, y*0x1p-600
		return math.Sqrt(math.FMA(y, y, float64(x*x))) * 0x1p600
	case x < 0x1p-500:
		x, y = x*0x1p600, y*0x1p600
		return math.Sqrt(math.FMA(y, y, float64(x*x))) * 0x1p-600
	}
	return math.Sqrt(math.FMA(y, y, float64(x*x)))
}

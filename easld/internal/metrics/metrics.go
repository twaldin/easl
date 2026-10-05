// Package metrics keeps easld's own counters behind `app.metrics` (Sources/CanvasCore/Metrics.swift
// in the app): per-method API requests, events sent, board writes and saves, each kept for three
// windows (since start or the last reset, the last 60 s, the last 10 min); current levels
// (gauges); the top writers; and the process's CPU and memory. Recording is a lock and a map
// update, so hooks sit on per-request and per-write paths. easld has no main thread, window,
// terminals or WebKit, so the app's `main.*`, `api.main.*`, `html.*` and `live.*` entries and
// the process's wakeups, energy and helpers have no counterpart here.
package metrics

import (
	"math"
	"runtime"
	"sort"
	"sync"
	"syscall"
	"time"
)

// Tally is one window of a counter: how many, how long (ms, and the longest), how many bytes.
type Tally struct {
	N     int
	Ms    float64
	MaxMs float64
	Bytes int
}

func (t *Tally) add(o Tally) {
	t.N += o.N
	t.Ms += o.Ms
	t.MaxMs = math.Max(t.MaxMs, o.MaxMs)
	t.Bytes += o.Bytes
}

func (t Tally) json() map[string]any {
	out := map[string]any{"n": float64(t.N)}
	if t.Ms > 0 {
		out["ms"] = tenths(t.Ms)
		out["maxMs"] = tenths(t.MaxMs)
	}
	if t.Bytes > 0 {
		out["bytes"] = float64(t.Bytes)
	}
	return out
}

func tenths(v float64) float64 { return math.Round(v*10) / 10 }

// series is a counter: its total, and per-second and per-10-second buckets for the recent
// windows (each bucket stamped with the second or ten it holds, so stale ones are skipped).
type series struct {
	total        Tally
	seconds      [60]Tally
	secondStamps [60]int64
	tens         [60]Tally
	tenStamps    [60]int64
}

func newSeries() *series {
	s := &series{}
	for i := range s.secondStamps {
		s.secondStamps[i], s.tenStamps[i] = -1, -1
	}
	return s
}

func (s *series) add(t Tally, now float64) {
	s.total.add(t)
	second := int64(now)
	if i := second % 60; s.secondStamps[i] != second {
		s.secondStamps[i], s.seconds[i] = second, Tally{}
	}
	s.seconds[second%60].add(t)
	ten := second / 10
	if i := ten % 60; s.tenStamps[i] != ten {
		s.tenStamps[i], s.tens[i] = ten, Tally{}
	}
	s.tens[ten%60].add(t)
}

func (s *series) window(seconds int64, now float64) Tally {
	var out Tally
	second := int64(now)
	if seconds <= 60 {
		for i, stamp := range s.secondStamps {
			if stamp > second-seconds {
				out.add(s.seconds[i])
			}
		}
		return out
	}
	ten := second / 10
	for i, stamp := range s.tenStamps {
		if stamp > ten-seconds/10 {
			out.add(s.tens[i])
		}
	}
	return out
}

type offender struct {
	n  int
	ms float64
}

// Metrics is one process's counters; safe from any goroutine.
type Metrics struct {
	mu        sync.Mutex
	start     time.Time // monotonic: windows count seconds from here
	since     float64   // seconds after start of the last reset
	series    map[string]*series
	gauges    map[string]float64
	offenders map[string]map[string]*offender
	process   sampler
}

// Shared is easld's counters (the app's Metrics.shared).
var Shared = New()

// New is an empty set of counters; the process's CPU is counted from now, its recent windows
// sampled from the first read on.
func New() *Metrics {
	m := &Metrics{start: time.Now(), series: map[string]*series{}, gauges: map[string]float64{}, offenders: map[string]map[string]*offender{}}
	m.process.now = m.now
	base := m.process.sample()
	m.process.base = &base
	return m
}

func (m *Metrics) now() float64 { return time.Since(m.start).Seconds() }

// Record adds one occurrence of name, with its duration (ms) and size (bytes) when it has them.
func (m *Metrics) Record(name string, ms float64, bytes int) {
	now := m.now()
	m.mu.Lock()
	s := m.series[name]
	if s == nil {
		s = newSeries()
		m.series[name] = s
	}
	s.add(Tally{N: 1, Ms: ms, MaxMs: ms, Bytes: bytes}, now)
	m.mu.Unlock()
}

// Since is milliseconds from t to now, for Record.
func Since(t time.Time) float64 { return float64(time.Since(t).Microseconds()) / 1000 }

// Gauge sets a level (event subscribers).
func (m *Metrics) Gauge(name string, value float64) {
	m.mu.Lock()
	m.gauges[name] = value
	m.mu.Unlock()
}

// Offender counts key in the top list `list` (who wrote most).
func (m *Metrics) Offender(list, key string, ms float64) {
	m.mu.Lock()
	entries := m.offenders[list]
	if entries == nil {
		entries = map[string]*offender{}
		m.offenders[list] = entries
	}
	o := entries[key]
	if o == nil {
		o = &offender{}
		entries[key] = o
	}
	o.n++
	o.ms += ms
	m.mu.Unlock()
}

// Reset clears every counter and the top lists; gauges (current levels) stay.
func (m *Metrics) Reset() {
	now := m.now()
	m.mu.Lock()
	m.series = map[string]*series{}
	m.offenders = map[string]map[string]*offender{}
	m.since = now
	m.mu.Unlock()
	m.process.reset()
}

// Watching samples the process every second for the next 3 s (a client polling each second).
func (m *Metrics) Watching() { m.process.watch(3 * time.Second) }

// Snapshot is everything, as `app.metrics` returns it.
func (m *Metrics) Snapshot() map[string]any {
	now := m.now()
	m.mu.Lock()
	counters := make(map[string]any, len(m.series))
	for name, s := range m.series {
		counters[name] = map[string]any{"total": s.total.json(), "last60s": s.window(60, now).json(), "last10m": s.window(600, now).json()}
	}
	gauges := make(map[string]any, len(m.gauges))
	for name, v := range m.gauges {
		gauges[name] = v
	}
	top := make(map[string]any, len(m.offenders))
	for list, entries := range m.offenders {
		keys := make([]string, 0, len(entries))
		for k := range entries {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(i, j int) bool {
			a, b := entries[keys[i]], entries[keys[j]]
			if a.n != b.n {
				return a.n > b.n
			}
			return keys[i] < keys[j]
		})
		if len(keys) > 5 {
			keys = keys[:5]
		}
		out := make([]any, len(keys))
		for i, k := range keys {
			entry := map[string]any{"key": k, "n": float64(entries[k].n)}
			if entries[k].ms > 0 {
				entry["ms"] = tenths(entries[k].ms)
			}
			out[i] = entry
		}
		top[list] = out
	}
	since := m.since
	m.mu.Unlock()
	return map[string]any{
		"uptimeS":  math.Round(now),
		"sinceS":   math.Round(now - since),
		"counters": counters,
		"gauges":   gauges,
		"top":      top,
		"process":  m.process.snapshot(),
	}
}

// sampler keeps the process's CPU time every 10 s (every second while watched) for the
// recent windows' CPU share.
type sampler struct {
	now     func() float64
	mu      sync.Mutex
	started bool
	base    *cpuSample
	samples []cpuSample
	fast    time.Time // sample every second until then
	poke    chan struct{}
}

type cpuSample struct {
	at  float64 // seconds after the Metrics' start
	cpu float64 // user and system seconds
}

func (p *sampler) sample() cpuSample {
	var ru syscall.Rusage
	syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	cpu := time.Duration(ru.Utime.Nano() + ru.Stime.Nano()).Seconds()
	return cpuSample{at: p.now(), cpu: cpu}
}

// startLocked starts the sampling goroutine on first use, so a process that never reads its
// metrics never wakes for them.
func (p *sampler) startLocked() {
	if p.started {
		return
	}
	p.started = true
	p.poke = make(chan struct{}, 1)
	go p.loop()
}

func (p *sampler) loop() {
	for {
		p.mu.Lock()
		interval := 10 * time.Second
		if time.Now().Before(p.fast) {
			interval = time.Second
		}
		p.mu.Unlock()
		select {
		case <-time.After(interval):
		case <-p.poke:
		}
		s := p.sample()
		p.mu.Lock()
		p.samples = append(p.samples, s)
		cut := 0
		for cut < len(p.samples) && p.samples[cut].at < s.at-660 {
			cut++
		}
		p.samples = p.samples[cut:]
		p.mu.Unlock()
	}
}

func (p *sampler) watch(d time.Duration) {
	p.mu.Lock()
	p.startLocked()
	p.fast = time.Now().Add(d)
	p.mu.Unlock()
	select {
	case p.poke <- struct{}{}:
	default:
	}
}

func (p *sampler) reset() {
	s := p.sample()
	p.mu.Lock()
	p.startLocked()
	p.base = &s
	p.samples = nil
	p.mu.Unlock()
}

func (p *sampler) snapshot() map[string]any {
	current := p.sample()
	p.mu.Lock()
	p.startLocked()
	base := *p.base
	samples := append([]cpuSample(nil), p.samples...)
	p.mu.Unlock()
	// The oldest sample within each window (a window is as long as the samples reach).
	oldest := func(seconds float64) *cpuSample {
		for i := range samples {
			if current.at-samples[i].at <= seconds+5 {
				return &samples[i]
			}
		}
		return nil
	}
	windows := map[string]any{}
	for _, w := range []struct {
		name string
		from *cpuSample
	}{{"total", &base}, {"last60s", oldest(60)}, {"last10m", oldest(600)}} {
		if w.from == nil || current.at-w.from.at < 0.5 {
			continue
		}
		windows[w.name] = map[string]any{"cpuPercent": tenths((current.cpu - w.from.cpu) / (current.at - w.from.at) * 100)}
	}
	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)
	var ru syscall.Rusage
	syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	peak := float64(ru.Maxrss) // bytes on macOS, KiB on Linux
	if runtime.GOOS != "darwin" {
		peak *= 1024
	}
	return map[string]any{
		// What the Go runtime holds from the OS and hasn't returned (easld allocates nothing else).
		"footprintMB":     math.Round(float64(mem.Sys-mem.HeapReleased) / (1 << 20)),
		"peakFootprintMB": math.Round(peak / (1 << 20)),
		"windows":         windows,
	}
}

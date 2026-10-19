package router

import (
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/twaldin/easl/easld/internal/board"
)

var cleanupDuration = regexp.MustCompile(`^[0-9]+(?:\.[0-9]+)?[smhd]$`)
var expiryTimestamp = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:[Zz]|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$`)

func parseCleanupDuration(value any, name string) (time.Duration, error) {
	text, ok := value.(string)
	if !ok || !cleanupDuration.MatchString(text) {
		return 0, invalid("%s must be a duration string such as 30s, 10m, 2h or 7d", name)
	}
	unit := 1.0
	switch text[len(text)-1] {
	case 'm':
		unit = 60
	case 'h':
		unit = 3600
	case 'd':
		unit = 86400
	}
	amount, err := strconv.ParseFloat(text[:len(text)-1], 64)
	seconds := amount * unit
	if err != nil || math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds >= float64(math.MaxInt64)/1e9 {
		return 0, invalid("%s duration overflows", name)
	}
	return time.Duration(seconds * 1e9), nil
}

func parseExpiryTimestamp(value any) (time.Time, error) {
	text, ok := value.(string)
	if !ok || !expiryTimestamp.MatchString(text) {
		return time.Time{}, invalid("expires must be an RFC3339 timestamp with a timezone, or null")
	}
	at, err := time.Parse(time.RFC3339Nano, strings.ToUpper(text))
	if err != nil {
		return time.Time{}, invalid("expires must be an RFC3339 timestamp with a timezone, or null")
	}
	return at.UTC(), nil
}

func normalizedExpiry(p map[string]any, now time.Time) (map[string]any, error) {
	value, absolute := p["expires"]
	relative, hasRelative := p["expiresIn"]
	if absolute && hasRelative {
		return nil, invalid("expires and expiresIn cannot be used together")
	}
	if !absolute && !hasRelative {
		return p, nil
	}
	var at time.Time
	if hasRelative {
		duration, err := parseCleanupDuration(relative, "expiresIn")
		if err != nil {
			return nil, err
		}
		at = now.Add(duration).UTC()
	} else if value != nil {
		var err error
		at, err = parseExpiryTimestamp(value)
		if err != nil {
			return nil, err
		}
	}
	out := copyParams(p)
	delete(out, "expiresIn")
	out["expires"] = nil
	if hasRelative || value != nil {
		if at.Year() < 0 || at.Year() > 9999 {
			return nil, invalid("expires timestamp overflows")
		}
		out["expires"] = at.Format(time.RFC3339Nano)
	}
	return out, nil
}

func expiryOf(p map[string]any) ([]board.Expiry, error) {
	value, present := p["expires"]
	if !present {
		return nil, nil
	}
	if value == nil {
		return []board.Expiry{{}}, nil
	}
	at, err := parseExpiryTimestamp(value)
	if err != nil {
		return nil, err
	}
	return []board.Expiry{{At: &at}}, nil
}

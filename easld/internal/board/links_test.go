package board

import (
	"math"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/weblink"
)

// Ported from LinkTests.swift: reusing the browser tile that already shows an address.

func browser(b *Board, url, profile string) model.Object {
	props := map[string]any{"url": url}
	if profile != "" {
		props["profile"] = profile
	}
	return b.Create(model.Browser, props, frame(2000, 0, 600, 400), "", "")
}

func link(t *testing.T, b *Board, text, source, profile string) (model.Object, bool) {
	t.Helper()
	url, ok := weblink.Parse(text)
	if !ok {
		t.Fatalf("%s is no web link", text)
	}
	var props map[string]any
	if profile != "" {
		props = map[string]any{"profile": profile}
	}
	return b.OpenLink(url, source, source, props)
}

func browsers(b *Board) int {
	n := 0
	for _, o := range b.Objects() {
		if o.Type == model.Browser {
			n++
		}
	}
	return n
}

func TestATileShowingTheSameAddressIsReusedHoweverItIsSpelled(t *testing.T) {
	b := New("brd_links", t.TempDir())
	shown := browser(b, "http://example.com/docs", "")
	for _, spelling := range []string{"http://example.com/docs", "HTTP://Example.COM/docs", "http://example.com:80/docs"} {
		if o, existing := link(t, b, spelling, "", ""); !existing || o.ID != shown.ID {
			t.Errorf("%s: opened %s (existing %v), want %s", spelling, o.ID, existing, shown.ID)
		}
	}
	root := browser(b, "https://example.com:8443/", "")
	if o, _ := link(t, b, "https://EXAMPLE.com:8443", "", ""); o.ID != root.ID {
		t.Errorf("an empty path is /: opened %s, want %s", o.ID, root.ID)
	}
	if _, existing := link(t, b, "https://example.com", "", ""); existing {
		t.Error("a default port is not 8443")
	}
	if n := browsers(b); n != 3 {
		t.Errorf("%d browser tiles, want 3", n)
	}
}

func TestADifferentPathQueryOrFragmentIsAnotherPage(t *testing.T) {
	b := New("brd_links", t.TempDir())
	shown := browser(b, "https://app.example.com/page?tab=1", "")
	for _, other := range []string{"https://app.example.com/page", "https://app.example.com/page?tab=2", "https://app.example.com/page?tab=1#top", "http://app.example.com/page?tab=1"} {
		if o, existing := link(t, b, other, "", ""); existing || o.ID == shown.ID {
			t.Errorf("%s reused %s", other, o.ID)
		}
	}
	if n := browsers(b); n != 5 {
		t.Errorf("%d browser tiles, want 5", n)
	}
	if _, existing := link(t, b, "https://app.example.com/page?tab=1#top", "", ""); !existing {
		t.Error("a fragment is part of the address")
	}
}

func TestOnlyBrowserTilesCountAndOtherProfilesAreOtherPages(t *testing.T) {
	b := New("brd_links", t.TempDir())
	b.Create(model.Note, map[string]any{"markdown": "http://example.com/"}, frame(0, 0, 300, 200), "", "")
	b.Create(model.HTML, map[string]any{"url": "http://example.com/", "html": ""}, frame(0, 300, 300, 200), "", "")
	if o, existing := link(t, b, "http://example.com/", "", ""); existing || o.Type != model.Browser {
		t.Errorf("a note and an HTML tile mentioning it don't show it: opened %s %s (existing %v)", o.Type, o.ID, existing)
	}

	work := browser(b, "https://github.com/", "work")
	if _, existing := link(t, b, "https://github.com/", "", ""); existing {
		t.Error("the default profile is not 'work'")
	}
	if o, _ := link(t, b, "https://github.com/", "", "work"); o.ID != work.ID {
		t.Errorf("profile work opened %s, want %s", o.ID, work.ID)
	}
	if _, existing := link(t, b, "https://github.com/", "", "personal"); existing {
		t.Error("profile personal reused another profile's tile")
	}
}

func TestANewTileOpensBesideItsSourceCreditedToTheCaller(t *testing.T) {
	b := New("brd_links", t.TempDir())
	terminal := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 600, 400), "", "")
	o, existing := link(t, b, "https://example.com/new", terminal.ID, "")
	if existing {
		t.Fatal("reused a tile on an empty board")
	}
	if o.Props["url"] != "https://example.com/new" {
		t.Errorf("url %v", o.Props["url"])
	}
	if o.CreatedBy != model.ActorFor(terminal.ID) {
		t.Errorf("created by %v, want the terminal", o.CreatedBy)
	}
	f := o.Frame
	if !(f.X >= 600 || f.Y >= 400 || f.X+f.W <= 0 || f.Y+f.H <= 0) {
		t.Errorf("frame %v over the terminal, not beside it", f)
	}
	if !(math.Abs(f.X-600) < 200 || math.Abs(f.Y-400) < 200) {
		t.Errorf("frame %v not close to the terminal", f)
	}
}

// Several tiles showing one address: the one nearest the source, then the lowest id.
func TestTheNearestOfSeveralTilesShowingTheAddressIsReused(t *testing.T) {
	b := New("brd_links", t.TempDir())
	terminal := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 600, 400), "", "")
	b.Create(model.Browser, map[string]any{"url": "https://example.com/"}, frame(5000, 0, 600, 400), "", "")
	near := b.Create(model.Browser, map[string]any{"url": "https://example.com/"}, frame(700, 0, 600, 400), "", "")
	if o, _ := link(t, b, "https://example.com", terminal.ID, ""); o.ID != near.ID {
		t.Errorf("reused %s, want the nearer %s", o.ID, near.ID)
	}
	mirror := b.Create(model.Browser, map[string]any{"url": "https://example.com/"}, frame(-700, 0, 600, 400), "", "")
	want := min(near.ID, mirror.ID)
	if o, _ := link(t, b, "https://example.com", terminal.ID, ""); o.ID != want {
		t.Errorf("of two as near, reused %s, want the lower id %s", o.ID, want)
	}
}

package board

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/store"
)

func frame(x, y, w, h float64) *model.Frame { return &model.Frame{X: x, Y: y, W: w, H: h} }

func recorder(b *Board) *[]model.Event {
	var events []model.Event
	b.OnEvent = func(e model.Event) { events = append(events, e) }
	return &events
}

func names(events []model.Event) []string {
	out := make([]string, len(events))
	for i, e := range events {
		out[i] = e.Name
	}
	return out
}

const formatOneBoard = `{"id":"brd_old","revision":5,"root":"\/old","objects":[
{"createdAt":"2025-01-01T00:00:00Z","createdBy":{"kind":"user"},"frame":{"h":100,"w":200,"x":0,"y":0},"id":"obj_note","props":{"markdown":"hi","scale":1.5},"rev":1,"type":"note","updatedAt":"2025-01-01T00:00:00Z","z":1},
{"createdAt":"2025-01-01T00:00:00Z","createdBy":{"kind":"user"},"frame":{"h":20,"w":80,"x":0,"y":300},"id":"obj_text","props":{"kind":"text","text":"t","scale":2},"rev":1,"type":"shape","updatedAt":"2025-01-01T00:00:00Z","z":2},
{"createdAt":"2025-01-01T00:00:00Z","createdBy":{"kind":"user"},"frame":{"h":1,"w":1,"x":0,"y":0},"id":"obj_group","props":{"members":["obj_note"],"name":"Plan"},"rev":1,"type":"group","updatedAt":"2025-01-01T00:00:00Z","z":3},
{"createdAt":"2025-01-01T00:00:00Z","createdBy":{"kind":"user"},"frame":{"h":594,"w":1000,"x":500,"y":0},"id":"obj_term","props":{"lifecycle":{"state":"working","seen":false}},"rev":1,"type":"terminal","updatedAt":"2025-01-01T00:00:00Z","z":4}],
"tray":[{"edited":false,"id":"men_gone","label":"x","stagedAt":"2025-01-01T00:00:00Z","target":{"kind":"object","object":"obj_missing"}},{"edited":false,"id":"men_kept","label":"note hi","stagedAt":"2025-01-01T00:00:00Z","target":{"kind":"object","object":"obj_note"}}],
"finalAnswers":{"obj_term":"answer","obj_missing":"gone"},"lifecycleSeq":{"obj_term|omp":3,"obj_missing|omp":9}}`

func TestFormatOneBoardLoadsMigrated(t *testing.T) {
	snap, err := store.DecodeSnapshot([]byte(formatOneBoard))
	if err != nil {
		t.Fatal(err)
	}
	b := FromSnapshot(snap)
	note := b.Objects()["obj_note"]
	if note.Frame.H != 126 || note.Props["zoom"] != 1.5 || note.Props["scale"] != nil {
		t.Errorf("note: frame %v props %v", note.Frame, note.Props)
	}
	if text := b.Objects()["obj_text"]; text.Frame.H != 20 || text.Props["textSize"] != 2.0 {
		t.Errorf("text shape: frame %v props %v", text.Frame, text.Props)
	}
	group := b.Objects()["obj_group"]
	if group.Props["title"] != "Plan" || group.Props["name"] != nil {
		t.Errorf("group props %v", group.Props)
	}
	// Refit to its member: padding 24 around, 32 title band on top.
	if want := (model.Frame{X: -24, Y: -56, W: 248, H: 206}); group.Frame != want {
		t.Errorf("group frame %v, want %v", group.Frame, want)
	}
	if lc := b.Objects()["obj_term"].Props["lifecycle"].(map[string]any); lc["restored"] != true {
		t.Errorf("working terminal not marked restored: %v", lc)
	}
	if len(b.Tray()) != 1 || b.Tray()[0].ID != "men_kept" {
		t.Errorf("tray %v", b.Tray())
	}
	saved := b.Snapshot()
	if *saved.Format != 2 || !reflect.DeepEqual(saved.FinalAnswers, map[string]string{"obj_term": "answer"}) || !reflect.DeepEqual(saved.LifecycleSeq, map[string]int{"obj_term|omp": 3}) {
		t.Errorf("saved %+v", saved)
	}
	// Loading what was saved changes nothing more (migration is idempotent; format 2 frames stay).
	again := FromSnapshot(saved)
	if !reflect.DeepEqual(again.Snapshot().JSON(), saved.JSON()) {
		t.Error("a second load changed the board")
	}
}

func TestRevisionsChangedSinceAndRevConflicts(t *testing.T) {
	b := New("brd", "/r")
	a := b.Create(model.Note, map[string]any{"markdown": "a"}, frame(0, 0, 100, 100), "", "")
	cursor := b.Revision()
	c := b.Create(model.Note, map[string]any{"markdown": "c"}, frame(300, 0, 100, 100), "", "")
	if got := b.Changed(cursor); !reflect.DeepEqual(got, []string{c.ID}) {
		t.Fatalf("changed since %d: %v", cursor, got)
	}
	stale := 1
	if _, err := b.Update(a.ID, &stale, nil, nil, map[string]any{"markdown": "b"}, "", ""); err != nil {
		t.Fatal(err)
	}
	_, err := b.Update(a.ID, &stale, nil, nil, map[string]any{"markdown": "x"}, "", "")
	var be *Error
	if !errors.As(err, &be) || be.Code != "conflict" || be.Message != "object "+a.ID+" is at rev 2, not 1" {
		t.Fatalf("stale rev: %v", err)
	}
	if err := b.Delete(a.ID, ""); err != nil {
		t.Fatal(err)
	}
	if got := b.Changed(0); !reflect.DeepEqual(got, []string{c.ID}) {
		t.Fatalf("a deleted object is not changed: %v", got)
	}
}

// A terminal's host is where its session runs, fixed for its life: an update that names another
// host, or drops it (or gives a local terminal one), is refused and changes nothing; the same
// host written differently and other props pass.
func TestATerminalsHostCantChange(t *testing.T) {
	b := New("brd", "/r")
	hosted := b.Create(model.Terminal, map[string]any{"host": "deckbox", "command": []any{"omp"}}, frame(0, 0, 100, 100), "", "")
	local := b.Create(model.Terminal, map[string]any{}, frame(200, 0, 100, 100), "", "")
	for name, c := range map[string]struct {
		id    string
		props map[string]any
	}{
		"another host":     {hosted.ID, map[string]any{"host": "mini"}},
		"no host":          {hosted.ID, map[string]any{"host": nil}},
		"empty host":       {hosted.ID, map[string]any{"host": ""}},
		"a local one's":    {local.ID, map[string]any{"host": "deckbox"}},
		"with other props": {hosted.ID, map[string]any{"name": "x", "host": "mini"}},
	} {
		_, err := b.Update(c.id, nil, nil, nil, c.props, "", "")
		var be *Error
		if !errors.As(err, &be) || be.Code != "invalid_params" || !strings.Contains(be.Message, "host can't change") {
			t.Errorf("%s: %v", name, err)
		}
	}
	if got, _ := b.Object(hosted.ID); got.Props["host"] != "deckbox" || got.Props["name"] != nil || got.Rev != hosted.Rev {
		t.Errorf("a refused update changed the terminal: %+v", got)
	}
	if _, err := b.Update(hosted.ID, nil, nil, nil, map[string]any{"host": " deckbox ", "name": "agent"}, "", ""); err != nil {
		t.Errorf("the same host: %v", err)
	}
}

func TestFailedAtomicStepRevertsEverythingAsOneRevision(t *testing.T) {
	b := New("brd", "/r")
	keep := b.Create(model.Note, map[string]any{"markdown": "keep", "key": "K"}, frame(0, 0, 100, 100), "", "")
	before := b.Revision()
	events := recorder(b)
	err := b.Atomically(func() error {
		b.Create(model.Shape, map[string]any{"kind": "rect", "key": "NEW"}, frame(0, 300, 10, 10), "", "")
		if _, err := b.Update(keep.ID, nil, frame(50, 50, 100, 100), nil, map[string]any{"key": nil}, "", ""); err != nil {
			return err
		}
		if err := b.Delete(keep.ID, ""); err != nil {
			return err
		}
		return InvalidParams("boom")
	})
	if err == nil || err.Error() != "boom" {
		t.Fatalf("err %v", err)
	}
	if len(b.Objects()) != 1 {
		t.Fatalf("objects %v", b.Objects())
	}
	back := b.Objects()[keep.ID]
	if back.Frame != keep.Frame || back.Props["key"] != "K" || back.Rev <= 2 {
		t.Fatalf("not restored: %+v", back)
	}
	if o, ok, _ := b.Holder("K"); !ok || o.ID != keep.ID {
		t.Fatal("key K lost")
	}
	if _, ok, _ := b.Holder("NEW"); ok {
		t.Fatal("key of the reverted create remains")
	}
	if b.Revision() != before+1 {
		t.Fatalf("revision %d, want %d (one pinned revision)", b.Revision(), before+1)
	}
	// Reverted newest first: the delete (back as created), the update (back), the create (gone).
	want := []string{EventObjectCreated, EventObjectUpdated, EventObjectDeleted, EventObjectCreated, EventObjectUpdated, EventObjectDeleted}
	if !reflect.DeepEqual(names(*events), want) {
		t.Fatalf("events %v, want %v", names(*events), want)
	}
	page := b.Activity.Query(Since{}, 100, nil)
	last := page.Entries[len(page.Entries)-1]
	if last.Actor != SystemActor || !strings.HasPrefix(last.Summary, "reverted (batch failed): ") {
		t.Fatalf("last entry %+v", last)
	}
}

func TestKeysAreUniqueAndFollowDeletes(t *testing.T) {
	b := New("brd", "/r")
	a := b.Create(model.Note, map[string]any{"markdown": "a", "key": "REL-1"}, frame(0, 0, 100, 100), "", "")
	err := b.CheckKey(map[string]any{"key": "REL-1"}, "")
	if err == nil || err.Error() != `key "REL-1" is held by `+a.ID+` (note "a")` {
		t.Fatalf("conflict: %v", err)
	}
	if err := b.CheckKey(map[string]any{"key": ""}, ""); err == nil || err.Error() != "props.key must be a non-empty string" {
		t.Fatalf("empty: %v", err)
	}
	if err := b.CheckKey(map[string]any{"key": "REL-1"}, a.ID); err != nil {
		t.Fatalf("own key: %v", err)
	}
	b.Create(model.Shape, map[string]any{"kind": "rect", "key": "REL-0"}, frame(0, 200, 10, 10), "", "")
	b.Create(model.Shape, map[string]any{"kind": "rect", "key": "OPS-1"}, frame(0, 300, 10, 10), "", "")
	var keys []any
	for _, o := range b.ObjectsWithKeyPrefix("REL-") {
		keys = append(keys, o.Props["key"])
	}
	if !reflect.DeepEqual(keys, []any{"REL-0", "REL-1"}) {
		t.Fatalf("prefix order %v", keys)
	}
	_ = b.Delete(a.ID, "")
	if _, ok, _ := b.Holder("REL-1"); ok {
		t.Fatal("deleted object still holds its key")
	}
}

func TestGroupsFollowMembersWithOneCascadeEntryPerRevision(t *testing.T) {
	b := New("brd", "/r")
	m1 := b.Create(model.Note, map[string]any{"markdown": "1"}, frame(0, 0, 100, 100), "", "")
	m2 := b.Create(model.Note, map[string]any{"markdown": "2"}, frame(200, 0, 100, 100), "", "")
	g := b.Create(model.Group, map[string]any{"members": []any{m1.ID, m2.ID}, "title": "G"}, nil, "", "")
	if want := (model.Frame{X: -24, Y: -56, W: 348, H: 180}); g.Frame != want {
		t.Fatalf("group frame %v, want %v", g.Frame, want)
	}
	cursor := b.Activity.Cursor()
	if _, err := b.Translate([]string{g.ID}, 10, 20, ""); err != nil {
		t.Fatal(err)
	}
	if got := b.Objects()[g.ID].Frame; got != (model.Frame{X: -14, Y: -36, W: 348, H: 180}) {
		t.Fatalf("group after move %v", got)
	}
	seq := cursor
	page := b.Activity.Query(Since{Seq: &seq}, 100, nil)
	var groupEntries []Entry
	for _, e := range page.Entries {
		if e.ID == g.ID {
			groupEntries = append(groupEntries, e)
		}
	}
	if len(groupEntries) != 1 || groupEntries[0].Cause != GroupRefitCause || groupEntries[0].Summary != `group (2 members): moved (-24, -56) → (-14, -36)` {
		t.Fatalf("group entries %+v", groupEntries)
	}
	_ = b.Delete(m2.ID, "")
	if got := b.Objects()[g.ID].Frame; got != (model.Frame{X: -14, Y: -36, W: 148, H: 180}) {
		t.Fatalf("group after a member left %v", got)
	}
}

func TestDeletingABoundObjectFreesArrowEndsWhereTheyWere(t *testing.T) {
	b := New("brd", "/r")
	a := b.Create(model.Shape, map[string]any{"kind": "rect"}, frame(0, 0, 160, 100), "", "")
	c := b.Create(model.Shape, map[string]any{"kind": "rect"}, frame(400, 0, 160, 100), "", "")
	arrow := b.Create(model.Arrow, map[string]any{"from": map[string]any{"object": a.ID}, "to": map[string]any{"object": c.ID}}, frame(0, 0, 0, 0), "", "")
	path := b.ArrowPaths([]string{arrow.ID})[arrow.ID]
	end := path[len(path)-1]
	if err := b.Delete(c.ID, ""); err != nil {
		t.Fatal(err)
	}
	to := b.Objects()[arrow.ID].Props["to"].(map[string]any)
	if !reflect.DeepEqual(to, map[string]any{"point": []any{end.X, end.Y}}) {
		t.Fatalf("freed end %v, want point %v", to, end)
	}
	if from := b.Objects()[arrow.ID].Props["from"].(map[string]any); from["object"] != a.ID {
		t.Fatalf("other end changed: %v", from)
	}
}

func lifecycle(b *Board, tile string) map[string]any {
	lc, _ := b.Objects()[tile].Props["lifecycle"].(map[string]any)
	return lc
}

func TestLifecycleStalenessApprovalsAndDone(t *testing.T) {
	b := New("brd", "/r")
	term := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 1000, 620), "", "")
	seq := func(n int) *int { return &n }
	call := func(s string) *string { return &s }
	report := func(r Report) {
		t.Helper()
		r.Tile, r.Kind = term.ID, "omp"
		if err := b.ReportLifecycle(r); err != nil {
			t.Fatal(err)
		}
	}
	report(Report{State: "working", Seq: seq(2)})
	report(Report{State: "idle", Seq: seq(1)})
	if lifecycle(b, term.ID)["state"] != "working" {
		t.Fatal("a stale report applied")
	}
	report(Report{State: "blocked", Seq: seq(3), Call: call("c1"), Message: call("Allow rm?")})
	report(Report{State: "blocked", Seq: seq(4), Call: call("c2"), Message: call("Allow push?")})
	report(Report{State: "working", Seq: seq(5), Call: call("c1")})
	if lc := lifecycle(b, term.ID); lc["state"] != "blocked" || lc["message"] != "Allow push?" {
		t.Fatalf("after one approval: %v", lc)
	}
	report(Report{State: "working", Seq: seq(6), Call: call("c2")})
	final := "all done"
	report(Report{State: "idle", Seq: seq(7), Final: &final})
	if lc := lifecycle(b, term.ID); lc["state"] != "done" || lc["seen"] != false {
		t.Fatalf("finished turn: %v", lc)
	}
	if answer, _ := b.FinalAnswer(term.ID); answer != "all done" {
		t.Fatalf("final %q", answer)
	}
	err := b.ReportLifecycle(Report{Tile: term.ID, Kind: "omp", State: "working", Final: &final})
	if err == nil || err.Error() != "final comes only with state idle: the answer of the turn that just ended" {
		t.Fatalf("final with working: %v", err)
	}
	report(Report{State: "working", Seq: seq(8)})
	if _, ok := b.FinalAnswer(term.ID); ok {
		t.Fatal("a new turn kept the last answer")
	}
}

func TestAttentionFromEarlierTurnsClearsOnTheNextMarker(t *testing.T) {
	b := New("brd", "/r")
	term := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 1000, 620), "", "")
	n1 := b.Create(model.Note, map[string]any{"markdown": "1"}, frame(0, 700, 100, 100), "", "")
	n2 := b.Create(model.Note, map[string]any{"markdown": "2"}, frame(200, 700, 100, 100), "", "")
	n3 := b.Create(model.Note, map[string]any{"markdown": "3"}, frame(400, 700, 100, 100), "", "")
	_ = b.ReportLifecycle(Report{Tile: term.ID, Kind: "omp", State: "working"})
	if _, cleared, _ := b.RaiseAttention(n1.ID, nil, term.ID); len(cleared) != 0 {
		t.Fatal("cleared within a turn")
	}
	if _, cleared, _ := b.RaiseAttention(n2.ID, nil, term.ID); len(cleared) != 0 {
		t.Fatal("cleared a marker of the same turn")
	}
	_ = b.ReportLifecycle(Report{Tile: term.ID, Kind: "omp", State: "idle"})
	_ = b.ReportLifecycle(Report{Tile: term.ID, Kind: "omp", State: "working"})
	_, cleared, _ := b.RaiseAttention(n3.ID, nil, term.ID)
	if !reflect.DeepEqual(cleared, sortedPair(n1.ID, n2.ID)) {
		t.Fatalf("cleared %v", cleared)
	}
}

func sortedPair(a, b string) []string {
	if a < b {
		return []string{a, b}
	}
	return []string{b, a}
}

func TestPlacementBesideTheCallerAndStackingAnswers(t *testing.T) {
	b := New("brd", "/r")
	term := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 1000, 620), "", "")
	first := b.Create(model.Note, map[string]any{"markdown": "1"}, nil, "", term.ID)
	if first.Frame != (model.Frame{X: 1024, Y: 0, W: 280, H: 266}) {
		t.Fatalf("first answer at %v", first.Frame)
	}
	second := b.Create(model.Note, map[string]any{"markdown": "2"}, nil, "", term.ID)
	if second.Frame != (model.Frame{X: 1024, Y: 290, W: 280, H: 266}) {
		t.Fatalf("second answer at %v, want below the first", second.Frame)
	}
	nobody := b.Create(model.Note, map[string]any{"markdown": "u"}, nil, "", "")
	for _, o := range []model.Object{term, first, second} {
		if o.Frame.Intersects(model.Frame{X: nobody.Frame.X - 23, Y: nobody.Frame.Y - 23, W: nobody.Frame.W + 46, H: nobody.Frame.H + 46}) {
			t.Fatalf("user's note at %v crowds %v", nobody.Frame, o.Frame)
		}
	}
}

// A follow tile's history is client-writable props: entries that aren't objects are kept as
// they are, never read as one (the trim drops the oldest non-edit entry).
func TestFollowHistoryToleratesEntriesThatArentObjects(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "b.go"), []byte("package b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	b := New("brd", root)
	term := b.Create(model.Terminal, map[string]any{}, frame(0, 0, 1000, 620), "", "")
	history := make([]any, FollowHistoryLimit)
	history[0] = "junk"
	b.Create(model.Code, map[string]any{"path": "a.go", "followOf": term.ID, "history": history}, frame(0, 700, 600, 400), "", "")
	follow, ok, err := b.Follow(term.ID, root+"/b.go", nil, nil, "edit")
	if err != nil || !ok {
		t.Fatal(ok, err)
	}
	got := follow.Props["history"].([]any)
	if len(got) != FollowHistoryLimit || got[0].(map[string]any)["path"] != "b.go" || got[1] != "junk" {
		t.Fatalf("history %v", got)
	}
}

package store

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"
)

// swiftBoard is a board file as BoardStore.encoder writes it (sortedKeys, ISO 8601 dates,
// escaped slashes), with every optional part present.
const swiftBoard = `{"attention":[{"earlierTurn":true,"message":"look at this","object":"obj_01J0000000000000NOTE","raisedAt":"2026-10-01T10:00:00Z","raisedBy":"obj_01J00000000000000TRM"}],"finalAnswers":{"obj_01J00000000000000TRM":"done: see src\/a.ts"},"format":2,"id":"brd_0123456789abcdef0123","lifecycleSeq":{"obj_01J00000000000000TRM|omp":42},"objects":[{"createdAt":"2026-10-01T09:00:00Z","createdBy":{"kind":"user"},"frame":{"h":266,"w":280,"x":0,"y":0},"id":"obj_01J0000000000000NOTE","props":{"key":"REL-1","markdown":"# Plan\n\nShip the parser.","zoom":1.5},"rev":3,"type":"note","updatedAt":"2026-10-01T09:30:00Z","updatedBy":{"kind":"agent","tile":"obj_01J00000000000000TRM"},"z":1},{"createdAt":"2026-10-01T09:01:00Z","createdBy":{"kind":"agent","tile":"obj_01J00000000000000TRM"},"frame":{"h":620,"w":1000,"x":400.5,"y":-20},"id":"obj_01J00000000000000TRM","parent":"obj_01J0000000000000NOTE","props":{"agent":{"kind":"omp","sessionId":"s1"},"cwd":"\/tmp\/x","lifecycle":{"restored":true,"seen":false,"state":"working"},"unknown":[1,null,{"a":"b"}]},"rev":7,"type":"terminal","updatedAt":"2026-10-01T09:31:00Z","z":2}],"promptTarget":{"chosen":"obj_01J00000000000000TRM","focusOrder":["obj_01J00000000000000TRM"]},"repo":{"commonDir":"\/repo\/.git","merged":["brd_legacy"],"worktrees":[{"branch":"feature\/x","path":"\/repo-wt","region":"obj_01J0000000000000NOTE"},{"path":"\/repo-detached"}]},"revision":12,"root":"\/repo","tray":[{"edited":true,"id":"men_01J000000000000001","label":"note Plan","stagedAt":"2026-10-01T09:40:00Z","target":{"kind":"code","lines":{"end":7,"start":5},"object":"obj_01J0000000000000NOTE","path":"src\/app.ts"}}],"turnErrors":{"obj_01J00000000000000TRM":"overloaded_error"}}`

func TestSwiftBoardFileRoundTripsByteForByte(t *testing.T) {
	snap, err := DecodeSnapshot([]byte(swiftBoard))
	if err != nil {
		t.Fatal(err)
	}
	if got := string(encoded(t, snap)); got != swiftBoard {
		t.Fatalf("re-encoded board differs:\n got %s\nwant %s", got, swiftBoard)
	}
}

func TestOlderBoardFileKeepsWhatItLacks(t *testing.T) {
	// Format 1, no tray, no optional parts: written back without inventing them.
	const old = `{"id":"brd_old","objects":[],"revision":0,"root":"\/old"}`
	snap, err := DecodeSnapshot([]byte(old))
	if err != nil {
		t.Fatal(err)
	}
	if snap.Format != nil || snap.HasTray || snap.Repo != nil || snap.PromptTarget != nil {
		t.Fatalf("optional parts appeared: %+v", snap)
	}
	if got := string(encoded(t, snap)); got != old {
		t.Fatalf("got %s want %s", got, old)
	}
}

func TestUnreadableBoardFileIsRejectedWhole(t *testing.T) {
	for name, text := range map[string]string{
		"unknown type":    `{"id":"b","objects":[{"createdAt":"2026-10-01T09:00:00Z","createdBy":{"kind":"user"},"frame":{"h":1,"w":1,"x":0,"y":0},"id":"o","props":{},"rev":1,"type":"spaceship","updatedAt":"2026-10-01T09:00:00Z","z":1}],"revision":0,"root":"\/r"}`,
		"missing rev":     `{"id":"b","objects":[{"createdAt":"2026-10-01T09:00:00Z","createdBy":{"kind":"user"},"frame":{"h":1,"w":1,"x":0,"y":0},"id":"o","props":{},"type":"note","updatedAt":"2026-10-01T09:00:00Z","z":1}],"revision":0,"root":"\/r"}`,
		"bad date":        `{"id":"b","objects":[{"createdAt":"yesterday","createdBy":{"kind":"user"},"frame":{"h":1,"w":1,"x":0,"y":0},"id":"o","props":{},"rev":1,"type":"note","updatedAt":"2026-10-01T09:00:00Z","z":1}],"revision":0,"root":"\/r"}`,
		"agent sans tile": `{"id":"b","objects":[{"createdAt":"2026-10-01T09:00:00Z","createdBy":{"kind":"agent"},"frame":{"h":1,"w":1,"x":0,"y":0},"id":"o","props":{},"rev":1,"type":"note","updatedAt":"2026-10-01T09:00:00Z","z":1}],"revision":0,"root":"\/r"}`,
		"no revision":     `{"id":"b","objects":[],"root":"\/r"}`,
	} {
		if _, err := DecodeSnapshot([]byte(text)); err == nil {
			t.Errorf("%s: decoded", name)
		}
	}
}

func TestAtlasObjectsSurviveAStoreRoundTrip(t *testing.T) {
	data, err := os.ReadFile("../../../Tests/Fixtures/atlas-board.json")
	if err != nil {
		t.Fatal(err)
	}
	var atlas struct {
		Objects []map[string]any `json:"objects"`
	}
	if err := json.Unmarshal(data, &atlas); err != nil {
		t.Fatal(err)
	}
	objects := make([]any, len(atlas.Objects))
	for i, o := range atlas.Objects {
		o["rev"] = float64(1)
		o["createdBy"] = map[string]any{"kind": "user"}
		o["createdAt"] = "2026-10-01T09:00:00Z"
		o["updatedAt"] = "2026-10-01T09:00:00Z"
		objects[i] = o
	}
	file := map[string]any{"id": "brd_atlas", "root": "/atlas", "revision": float64(len(objects)), "objects": objects, "format": float64(2), "tray": []any{}}
	encoded, err := EncodeSwift(file, false, true)
	if err != nil {
		t.Fatal(err)
	}
	snap, err := DecodeSnapshot(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Objects) != len(atlas.Objects) {
		t.Fatalf("%d objects, want %d", len(snap.Objects), len(atlas.Objects))
	}
	dir := t.TempDir()
	s := New(dir, time.Hour, &sync.Mutex{})
	if err := s.Write(snap); err != nil {
		t.Fatal(err)
	}
	again, ok := s.Read("brd_atlas")
	if !ok {
		t.Fatal("not readable")
	}
	if !reflect.DeepEqual(again.JSON(), snap.JSON()) {
		t.Fatal("snapshot changed through the store")
	}
	if again, _ := again.Encode(); string(again) != string(encoded) {
		t.Fatal("bytes changed through the store")
	}
}

func TestDebouncedSaveWritesOnceAndFlushWritesPending(t *testing.T) {
	dir := t.TempDir()
	var mu sync.Mutex
	s := New(dir, 50*time.Millisecond, &mu)
	revision := 0 // guarded by mu, which snap is called under
	snap := func() *Snapshot { return &Snapshot{ID: "brd_x", Root: "/x", Revision: revision, Objects: nil} }
	setRevision := func(n int) { mu.Lock(); revision = n; mu.Unlock() }
	for n := 1; n <= 3; n++ {
		setRevision(n)
		s.ScheduleSave("brd_x", snap)
	}
	if _, err := os.Stat(filepath.Join(dir, "brd_x.json")); err == nil {
		t.Fatal("saved before the debounce")
	}
	time.Sleep(200 * time.Millisecond)
	got, ok := s.Read("brd_x")
	if !ok || got.Revision != 3 {
		t.Fatalf("debounced save: %+v %v", got, ok)
	}
	setRevision(9)
	s.ScheduleSave("brd_x", snap)
	s.Flush()
	if got, _ := s.Read("brd_x"); got.Revision != 9 {
		t.Fatalf("flush wrote revision %d", got.Revision)
	}
}

// Shutdown flushes: a debounced save already under way when Flush is called is on disk by the
// time Flush returns.
func TestFlushWaitsForASaveUnderWay(t *testing.T) {
	dir := t.TempDir()
	s := New(dir, time.Millisecond, &sync.Mutex{})
	started, release := make(chan struct{}), make(chan struct{})
	s.ScheduleSave("brd_x", func() *Snapshot {
		close(started)
		<-release
		return &Snapshot{ID: "brd_x", Root: "/x", Revision: 4}
	})
	<-started
	flushed := make(chan struct{})
	go func() { s.Flush(); close(flushed) }()
	select {
	case <-flushed:
		t.Fatal("Flush returned while a save was under way")
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	<-flushed
	if got, ok := s.Read("brd_x"); !ok || got.Revision != 4 {
		t.Fatalf("after Flush: %+v %v", got, ok)
	}
}

// Saves of one board land in the order their snapshots were taken: a save that lost the race
// to a newer one doesn't replace it.
func TestOlderSnapshotNeverReplacesNewer(t *testing.T) {
	s := New(t.TempDir(), time.Hour, &sync.Mutex{})
	older, newer := s.taken.Add(1), s.taken.Add(1)
	if err := s.save(&Snapshot{ID: "brd_x", Root: "/x", Revision: 2}, newer); err != nil {
		t.Fatal(err)
	}
	if err := s.save(&Snapshot{ID: "brd_x", Root: "/x", Revision: 1}, older); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Read("brd_x"); got.Revision != 2 {
		t.Fatalf("revision %d on disk", got.Revision)
	}
}

// A number JSON can't hold (a frame pushed to infinity) fails the save and the export, as
// JSONEncoder throws, and leaves the files that were there.
func TestNonFiniteBoardKeepsTheFileItHad(t *testing.T) {
	dir := t.TempDir()
	s := New(dir, time.Hour, &sync.Mutex{})
	good, err := DecodeSnapshot([]byte(swiftBoard))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Write(good); err != nil {
		t.Fatal(err)
	}
	exported := filepath.Join(dir, "export", "board.json")
	if err := Export(*good, exported); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(s.Path(good.ID))
	beforeExport, _ := os.ReadFile(exported)
	bad, _ := DecodeSnapshot([]byte(swiftBoard))
	bad.Objects[0].Frame.X = math.Inf(1)
	var nf NonFinite
	if err := s.Write(bad); !errors.As(err, &nf) {
		t.Fatalf("Write: %v", err)
	}
	if err := Export(*bad, exported); err == nil || err.Error() != "The data couldn’t be written because it isn’t in the correct format." {
		t.Fatalf("Export: %v", err)
	}
	after, _ := os.ReadFile(s.Path(good.ID))
	afterExport, _ := os.ReadFile(exported)
	if string(after) != string(before) || string(afterExport) != string(beforeExport) {
		t.Fatal("a failed save replaced the file")
	}
}

func encoded(t *testing.T, snap *Snapshot) []byte {
	t.Helper()
	data, err := snap.Encode()
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestBoardIDsAreTheSwiftHashes(t *testing.T) {
	// BoardStore.hashedID: brd_ + 20 hex digits of SHA-256 of the identity, so the app's board
	// files are found under the same names.
	if HashedID("abc") != "brd_ba7816bf8f01cfea4141" {
		t.Fatalf("got %s", HashedID("abc"))
	}
	if RepoID("/r/.git") != HashedID("/r/.git") || PathID("/tmp/../tmp/x") != HashedID("/tmp/x") {
		t.Fatal("ids aren't the hashed identity")
	}
}

func TestExportIsPrettyAndPersonalStateFree(t *testing.T) {
	snap, err := DecodeSnapshot([]byte(swiftBoard))
	if err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(t.TempDir(), ".easl", "board.json")
	if err := Export(*snap, out); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(out)
	var back map[string]any
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"tray", "attention", "finalAnswers", "turnErrors", "lifecycleSeq", "repo"} {
		if _, ok := back[k]; ok {
			t.Errorf("export kept %s", k)
		}
	}
	text := string(data)
	if text[len(text)-1] != '\n' || !contains(text, "\"format\" : 2") || !contains(text, "\"cwd\" : \"/tmp/x\"") {
		t.Fatalf("not Swift's prettyPrinted shape:\n%s", text)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

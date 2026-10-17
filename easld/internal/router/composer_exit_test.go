package router

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/twaldin/easl/easld/internal/board"
	"github.com/twaldin/easl/easld/internal/model"
	"github.com/twaldin/easl/easld/internal/session"
)

func composerEvents(f *fixture) *[]map[string]any {
	events := []map[string]any{}
	previous := f.board.OnEvent
	f.board.OnEvent = func(e model.Event) {
		if previous != nil {
			previous(e)
		}
		if e.Name == board.EventComposerReturned || e.Name == board.EventComposerSubmitted {
			data := e.Data.(map[string]any)
			events = append(events, map[string]any{"event": e.Name, "terminal": data["terminal"], "viewer": data["viewer"], "ids": data["ids"]})
		}
	}
	return &events
}

func queueExitMention(f *fixture, tile, origin, text string) {
	f.t.Helper()
	note := idOf(f.result("object.create", note(0, map[string]any{"markdown": origin})))
	f.router.reg.Mu.Lock()
	defer f.router.reg.Mu.Unlock()
	f.board.QueueComposerPrompt(text, tile, []model.Mention{{ID: origin, Target: map[string]any{"kind": "object", "object": note}, Label: origin, StagedAt: time.Now()}}, false, testViewer, time.Now())
}

func TestComposerExitReturnsOnlyTheOwnedShellQueueOnce(t *testing.T) {
	f, state := owning(t)
	events := composerEvents(f)
	tiles := map[string]string{}
	for i, name := range []string{"exited", "running", "unknown", "hosted", "foreign", "unreachable"} {
		props := map[string]any{"name": name}
		if name == "hosted" {
			props["host"] = "deckbox"
		}
		tile := f.agentTerminal("", props)
		tiles[name] = tile
		f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working", "protocol": 1.0})
		queueExitMention(f, tile, "men_"+name, "fix "+name)
		labels := f.router.Owns.Labels(f.board.ID(), tile)
		if name == "foreign" {
			labels[session.HomeLabel] = "another-home"
		}
		line := fmt.Sprintf("pid=%d\nlabels=canvas.home=%s canvas.board=%s canvas.tile=%s", 100+i, labels[session.HomeLabel], labels["canvas.board"], tile)
		if name == "unreachable" {
			line += " status=unreachable"
		}
		if err := os.WriteFile(filepath.Join(state, session.Prefix+tile), []byte(line+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	observe := func(pid int) (int, bool) {
		switch pid {
		case 101:
			return 700, true
		case 102:
			return 0, false
		default:
			return 0, true
		}
	}
	f.router.sweepComposerExits(observe)
	f.router.sweepComposerExits(observe)
	want := []map[string]any{{"event": board.EventComposerReturned, "terminal": tiles["exited"], "viewer": testViewer, "ids": []any{"men_exited"}}}
	if !reflect.DeepEqual(*events, want) {
		t.Fatalf("returned events %v, want %v", *events, want)
	}
	if props := f.result("object.get", map[string]any{"id": tiles["exited"]})["object"].(map[string]any)["props"].(map[string]any); props["agent"] != nil || props["lifecycle"] != nil {
		t.Fatalf("exited working agent was not released: %v", props)
	}
	for _, name := range []string{"running", "unknown", "hosted", "foreign", "unreachable"} {
		got := f.result("tray.drain", map[string]any{"caller": tiles[name], "prompt": "fix " + name})
		if mentions := got["mentions"].([]any); len(mentions) != 1 {
			t.Fatalf("%s queue was lost: %v", name, got)
		}
		last := (*events)[len(*events)-1]
		if last["event"] != board.EventComposerSubmitted || !reflect.DeepEqual(last["ids"], []any{"men_" + name}) {
			t.Fatalf("%s did not submit its original mention: %v", name, last)
		}
	}
}

func TestComposerExitObservationCannotReturnAReplacementQueue(t *testing.T) {
	for _, replaceAgent := range []bool{false, true} {
		t.Run(fmt.Sprint(replaceAgent), func(t *testing.T) {
			f, _ := owning(t)
			tile := f.agentTerminal("", map[string]any{"name": "worker"})
			f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working"})
			queueExitMention(f, tile, "men_old", "old prompt")
			events := composerEvents(f)
			f.router.sweepComposerExits(func(int) (int, bool) {
				if replaceAgent {
					f.result("agent.report_session", map[string]any{"tile": tile, "kind": "omp", "sessionId": "replacement"})
				}
				queueExitMention(f, tile, "men_new", "new prompt")
				return 0, true
			})
			got := f.result("tray.drain", map[string]any{"caller": tile, "prompt": "new prompt"})
			if mentions := got["mentions"].([]any); len(mentions) != 1 {
				t.Fatalf("replacement queue was returned by the stale observation: %v", got)
			}
			want := map[string]any{"event": board.EventComposerSubmitted, "terminal": tile, "viewer": testViewer, "ids": []any{"men_new"}}
			if last := (*events)[len(*events)-1]; !reflect.DeepEqual(last, want) {
				t.Fatalf("replacement submission %v, want %v", last, want)
			}
			for _, event := range *events {
				if event["event"] == board.EventComposerReturned && reflect.DeepEqual(event["ids"], []any{"men_new"}) {
					t.Fatalf("replacement mention returned: %v", *events)
				}
			}
		})
	}
}

func TestComposerSubmissionWaitsForItsTurnInsteadOfThePreviousDone(t *testing.T) {
	for _, notifying := range []bool{false, true} {
		t.Run(fmt.Sprint(notifying), func(t *testing.T) {
			f := newFixture(t)
			tile := f.agentTerminal("", map[string]any{"name": "worker"})
			f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working"})
			f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "idle"})
			if notifying {
				f.result("object.update", map[string]any{"id": tile, "props": map[string]any{"lifecycle": map[string]any{"state": "done", "via": "notifications"}}})
			}
			app := &scriptedClient{router: f.router, replies: []map[string]any{{"ok": true, "result": map[string]any{"sent": true}}}}
			attachApp(f, app, map[string]any{"serves": []any{"agent.prompt"}})
			if got := f.result("agent.prompt", map[string]any{"target": tile, "text": "next turn", "composer": true}); got["sent"] != true {
				t.Fatalf("submission result %v", got)
			}
			waiting := &conn{}
			if got := f.on(waiting, "agent.wait", map[string]any{"target": tile, "until": []any{"done"}}); got != nil {
				t.Fatalf("wait completed with the previous turn: %v", got)
			}
			f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "working"})
			f.result("agent.report", map[string]any{"tile": tile, "kind": "omp", "state": "idle", "message": "new answer"})
			replies := waiting.messages()
			if len(replies) != 1 || replies[0]["ok"] != true {
				t.Fatalf("new turn did not complete the wait once: %v", replies)
			}
			agent := replies[0]["result"].(map[string]any)["agent"].(map[string]any)
			lifecycle := agent["lifecycle"].(map[string]any)
			if lifecycle["state"] != "done" || lifecycle["message"] != "new answer" {
				t.Fatalf("wait returned the wrong turn: %v", lifecycle)
			}
		})
	}
}

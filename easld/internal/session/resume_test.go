package session

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

// Every case of the resume fixture Swift's AgentResumeTests checks too
// (Tests/Fixtures/agent-resume.json).
func TestResumeArgvMatchesTheSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../Tests/Fixtures/agent-resume.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Note, Kind, SessionID string
			Command, Argv         []string
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range fixture.Cases {
		if got := ResumeArgv(c.Kind, c.SessionID, c.Command); !reflect.DeepEqual(got, c.Argv) {
			t.Errorf("%s %s %q (%s): got %q, want %q", c.Kind, c.SessionID, c.Command, c.Note, got, c.Argv)
		}
	}
}

// Every case of the relaunch fixture Swift's AgentControlTests checks too
// (Tests/Fixtures/agent-relaunch.json).
func TestRelaunchMatchesTheSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../Tests/Fixtures/agent-relaunch.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Note, Kind, Session, Model, Thinking string
			Command, Args                        []string
			Relaunch                             *Relaunch
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range fixture.Cases {
		got, ok := RelaunchOf(c.Kind, c.Command, c.Session, c.Model, c.Thinking, c.Args)
		if ok != (c.Relaunch != nil) || (ok && !reflect.DeepEqual(got, *c.Relaunch)) {
			t.Errorf("%s %q (%s): got %q (%v), want %+v", c.Kind, c.Command, c.Note, got, ok, c.Relaunch)
		}
	}
}

// A new session resumes the recorded agent session with the tile's options; a released agent
// (no props.agent), one easl can't resume, or one without a session runs the tile's command.
func TestInitialArgvResumesTheRecordedAgentElseRunsTheCommand(t *testing.T) {
	command := []any{"omp", "--model", "opus", 7.0}
	for name, c := range map[string]struct {
		props map[string]any
		want  []string
	}{
		"resumed":     {map[string]any{"command": command, "agent": map[string]any{"kind": "omp", "sessionId": "s1"}}, []string{"omp", "--model", "opus", "--resume=s1"}},
		"released":    {map[string]any{"command": command}, []string{"omp", "--model", "opus"}},
		"no session":  {map[string]any{"command": command, "agent": map[string]any{"kind": "omp"}}, []string{"omp", "--model", "opus"}},
		"unknown":     {map[string]any{"command": []any{"aider"}, "agent": map[string]any{"kind": "aider", "sessionId": "x"}}, []string{"aider"}},
		"no command":  {map[string]any{"agent": map[string]any{"kind": "claude", "sessionId": "u-1"}}, []string{"claude", "--resume", "u-1"}},
		"login shell": {map[string]any{}, nil},
	} {
		if got := InitialArgv(c.props); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: %q, want %q", name, got, c.want)
		}
	}
}

package session

import (
	"encoding/json"
	"maps"
	"os"
	"reflect"
	"testing"
)

// An owned terminal's session gets what a hosted one gets (Tests/Fixtures/terminal-env.json,
// which Swift's HostedTerminalTests checks spawnParams against), with easld's socket, the board's
// root and easld's home as its owner instead of a Mac's relayed sockets and home.
func TestOwnedEnvMatchesTheSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../Tests/Fixtures/terminal-env.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Tile, Board, UserHome string
		Env                   map[string]string
		Owned                 struct {
			EasldHome, Socket, Root string
			Env, Labels             map[string]string
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	owner := Owner{Socket: fixture.Owned.Socket, Home: fixture.Owned.EasldHome, Resources: Resources(fixture.UserHome)}
	want := maps.Clone(fixture.Env)
	maps.Copy(want, fixture.Owned.Env)
	if got := owner.Env(fixture.Board, fixture.Tile, fixture.Owned.Root); !reflect.DeepEqual(got, want) {
		t.Errorf("env\n got %v\nwant %v", got, want)
	}
	if got := owner.Labels(fixture.Board, fixture.Tile); !reflect.DeepEqual(got, fixture.Owned.Labels) {
		t.Errorf("labels %v, want %v", got, fixture.Owned.Labels)
	}
	if got := Label("/Users/tim/Library/Application Support/Easl é"); got != "_Users_tim_Library_Application_Support_Easl___" {
		t.Errorf("label %q: every byte outside [A-Za-z0-9._-] is _", got)
	}
}

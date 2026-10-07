package session

import (
	"encoding/json"
	"maps"
	"os"
	"reflect"
	"slices"
	"strings"
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

	// easld started in an easl tile has that tile's variables: the session gets the fixture's
	// over them, easl's bin before easld's PATH, and none of the tile's cmux variables (its
	// socket, surface, workspace and password), which session.spawn's sessions keep.
	inherited := []string{"PATH=/usr/bin:/bin", "HOME=/home/tim", "EASL_SOCKET=/old/easl.sock", "EASL_TILE_ID=obj_old",
		"CMUX_SOCKET_PATH=/old/cmux.sock", "CMUX_SURFACE_ID=obj_old", "CMUX_WORKSPACE_ID=brd_old", "CMUX_SOCKET_PASSWORD=secret"}
	request := owner.Request(fixture.Board, fixture.Tile, fixture.Owned.Root, "", []string{"omp"})
	if request.Tile != fixture.Tile || request.Cwd != fixture.Owned.Root || !reflect.DeepEqual(request.Command, []string{"omp"}) || !reflect.DeepEqual(request.Labels, fixture.Owned.Labels) {
		t.Errorf("request %+v", request)
	}
	session := map[string]string{}
	for _, kv := range environ(inherited, request.Env, request.Unset) {
		key, value, _ := strings.Cut(kv, "=")
		session[key] = value
	}
	want["PATH"] += ":/usr/bin:/bin"
	want["HOME"] = "/home/tim"
	if !reflect.DeepEqual(session, want) {
		t.Errorf("session's environment\n got %v\nwant %v", session, want)
	}
	if kept := environ(inherited, map[string]string{}, nil); !slices.Contains(kept, "CMUX_SOCKET_PATH=/old/cmux.sock") {
		t.Errorf("session.spawn's environment lost what it inherited: %v", kept)
	}
	if request := owner.Request(fixture.Board, fixture.Tile, fixture.Owned.Root, "/srv/x", nil); request.Cwd != "/srv/x" || request.Command != nil {
		t.Errorf("a given cwd: %+v", request)
	}
}

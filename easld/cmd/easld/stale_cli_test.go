package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestBoardStaleMineListsOnlyTheCallingTilesCreations(t *testing.T) {
	bun, err := exec.LookPath("bun")
	if err != nil {
		t.Skip("Bun is required to exercise the CLI")
	}
	dir := shortDir(t)
	home, root, socket := filepath.Join(dir, "home"), filepath.Join(dir, "root"), filepath.Join(dir, "s.sock")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	done, stderr := start(t, "--home", home, "--socket", socket)
	api := connect(t, socket, stderr)
	defer stop(t, done, syscall.SIGTERM)
	board := api.call(t, "board.open", map[string]any{"root": root})["board"].(string)
	create := func(typ, caller string) string {
		t.Helper()
		params := map[string]any{"board": board, "type": typ, "props": map[string]any{}}
		if caller != "" {
			params["caller"] = caller
		}
		return api.call(t, "object.create", params)["object"].(map[string]any)["id"].(string)
	}
	mine, other := create("terminal", ""), create("terminal", "")
	owned := create("note", mine)
	create("note", other)
	create("note", "")
	cli, err := filepath.Abs("../../../cli/easl.ts")
	if err != nil {
		t.Fatal(err)
	}
	runCLI := func(tile string) ([]byte, error) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, bun, cli, "board.stale", "--mine", "--older-than", "0s")
		for _, value := range os.Environ() {
			if !strings.HasPrefix(value, "EASL_TILE_ID=") && !strings.HasPrefix(value, "EASL_BOARD_ID=") && !strings.HasPrefix(value, "EASL_SOCKET=") {
				cmd.Env = append(cmd.Env, value)
			}
		}
		cmd.Env = append(cmd.Env, "EASL_SOCKET="+socket, "EASL_BOARD_ID="+board)
		if tile != "" {
			cmd.Env = append(cmd.Env, "EASL_TILE_ID="+tile)
		}
		return cmd.CombinedOutput()
	}
	output, err := runCLI(mine)
	if err != nil {
		t.Fatalf("CLI failed: %v: %s", err, output)
	}
	var result struct {
		Objects []struct {
			ID string `json:"id"`
		} `json:"objects"`
	}
	if err := json.Unmarshal(output, &result); err != nil {
		t.Fatalf("CLI returned invalid JSON: %v: %s", err, output)
	}
	if len(result.Objects) != 1 || result.Objects[0].ID != owned {
		t.Fatalf("--mine returned %s, want only %s", output, owned)
	}
	output, err = runCLI("")
	if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 1 || !strings.HasPrefix(strings.TrimSpace(string(output)), "invalid_params:") {
		t.Fatalf("missing caller must be invalid_params with exit 1: %v: %s", err, output)
	}
}

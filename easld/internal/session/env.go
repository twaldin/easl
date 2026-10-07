package session

import "strings"

// Owner is an easld that runs the terminals of its boards itself (`--own-terminals`, docs/contracts.md
// "Owned terminals"): what it puts in their sessions. A hosted terminal's session gets the same,
// pointed at a Mac's relayed sockets instead (HostedTerminal.spawnParams); the shared fixture
// Tests/Fixtures/terminal-env.json holds both to it.
type Owner struct {
	// Socket is easld's own socket (`EASL_SOCKET`): the agents' integrations report there, and
	// spool beside it (`agent-reports/`, which easld replays) while it is away.
	Socket string
	// Home is easld's home, the sessions' `canvas.home` (Label): a session labelled with another
	// home is never taken over or ended.
	Home string
	// Resources is easl's files for agents on this machine (Resources).
	Resources string
}

// Resources is easl's files for agents under the user's `home`, `~/.local/share/easl`
// (HostedTerminal.resources), which scripts/offload-setup.sh installs: bin, clients, extensions,
// skills, Ghostty's shell integration.
func Resources(home string) string { return home + "/.local/share/easl" }

// Env is the variables of terminal `tile`'s session on board `board`, rooted at `root` on this
// machine: HostedTerminal.spawnParams' (with LoginSession.tileShellIntegration of no inherited
// environment, as there; Spawn puts this PATH before easld's own), with easld's socket and the
// board's root, and without the cmux variables (no browser relay reaches an owned session).
// Ghostty's shell integration is always named: the shell scripts load it only if it is there.
func (o Owner) Env(board, tile, root string) map[string]string {
	env := tileShellIntegration(o.Resources)
	env["PATH"] = o.Resources + "/bin"
	for key, value := range map[string]string{
		"EASL_ENV":        "1",
		"EASL_SOCKET":     o.Socket,
		"EASL_TILE_ID":    tile,
		"EASL_BOARD_ID":   board,
		"EASL_BOARD_ROOT": root,
		// zmx's sessions have no xterm-ghostty terminfo of their own here.
		"TERM":      "xterm-256color",
		"COLORTERM": "truecolor",
	} {
		env[key] = value
	}
	env["EASL_GHOSTTY_INTEGRATION"] = o.Resources + "/ghostty/shell-integration"
	return env
}

// Labels are the owner labels of terminal `tile`'s session on board `board` (OwnerLabels).
func (o Owner) Labels(board, tile string) map[string]string {
	return map[string]string{"canvas.board": board, "canvas.tile": tile, HomeLabel: Label(o.Home)}
}

// Label is a path as a zmx label value, which allows only `[A-Za-z0-9._-]`: every other UTF-8
// byte becomes `_` (TerminalTile.label).
func Label(path string) string {
	out := []byte(path)
	for i, c := range out {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			out[i] = '_'
		}
	}
	return string(out)
}

// tileShellIntegration is LoginSession.tileShellIntegration of an empty inherited environment:
// easl's `bin/` first on PATH, its Python client on PYTHONPATH, its zsh integration as ZDOTDIR
// and its bash integration in PROMPT_COMMAND, and its `open` shim as BROWSER.
func tileShellIntegration(resources string) map[string]string {
	bin := resources + "/bin"
	return map[string]string{
		"PATH":           bin + ":/usr/bin:/bin",
		"PYTHONPATH":     resources + "/clients/python",
		"ZDOTDIR":        resources + "/extensions/shell/zsh",
		"BROWSER":        bin + "/open",
		"PROMPT_COMMAND": ". '" + strings.ReplaceAll(resources+"/extensions/shell/bash/easl.bash", "'", `'"'"'`) + "'",
	}
}

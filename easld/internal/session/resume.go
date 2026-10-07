package session

import (
	"path/filepath"
	"strings"
)

// grammar is how one agent's command line reads (AgentResume.Grammar). Options not listed take
// no value; `--name=value` always carries its own.
type grammar struct {
	// program is the executable's name (argv[0]'s last path component).
	program string
	// values are options taking one value; lists, every following word up to the next option;
	// optional, the next word unless it is an option.
	values, lists, optional set
	// dropped are options left out of the resumed command, with their values.
	dropped set
	// keepsPositionals keeps positional words (opencode's `[project]`); otherwise they are a
	// prompt or a subcommand (Codex's `resume <id>`) and left out.
	keepsPositionals bool
	// subcommand comes before the kept arguments (Codex's `resume`); selector after them,
	// followed by the session (as one word when it ends in `=`).
	subcommand, selector string
}

type set map[string]bool

func words(list ...string) set {
	s := set{}
	for _, w := range list {
		s[w] = true
	}
	return s
}

// grammars are AgentResume.grammar's, by agent kind.
var grammars = map[string]grammar{
	"omp": {program: "omp",
		values: words("--model", "--smol", "--slow", "--plan", "--prewalk-into", "--plan-yolo-into", "--provider", "--api-key", "--system-prompt",
			"--system-prompt-template", "--append-system-prompt", "--profile", "--alias", "--cwd", "--mode", "--config", "--add-dir",
			"--session-dir", "--models", "--tools", "--thinking", "--service-tier", "--hook", "-e", "--extension", "--skills",
			"--export", "--max-time"),
		optional: words("-r", "--resume"),
		dropped:  words("-r", "--resume", "-c", "--continue", "--from-claude", "--from-codex"),
		selector: "--resume="},
	"claude": {program: "claude",
		values: words("--agent", "--agents", "--append-system-prompt", "--append-system-prompt-file", "--autocompact", "--client-data-url",
			"--debug-file", "--effort", "--environment", "--fallback-model", "--input-format", "--json-schema", "--max-budget-usd",
			"--model", "-n", "--name", "--output-format", "--permission-mode", "--permission-prompts", "--permission-prompt-tool",
			"--plugin-dir", "--plugin-url", "--remote-control-session-name-prefix", "--session-id", "--setting-sources", "--settings",
			"--system-prompt", "--system-prompt-file", "--system-prompt-snapshot"),
		lists: words("--add-dir", "--allowedTools", "--allowed-tools", "--betas", "--disallowedTools", "--disallowed-tools", "--file",
			"--mcp-config", "--tools"),
		optional: words("-d", "--debug", "--cloud", "--prompt-suggestions", "--remote-control", "-w", "--worktree", "-r", "--resume",
			"--from-pr", "--teleport"),
		dropped:  words("-r", "--resume", "-c", "--continue", "--session-id", "--fork-session", "--from-pr", "--teleport"),
		selector: "--resume"},
	// `codex resume` takes the same options as `codex`; given after `resume` they are the ones
	// Codex keeps (its `-c` is a global clap option: the deepest level that has any wins).
	"codex": {program: "codex",
		values: words("-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env", "-m", "--model", "--local-provider",
			"-p", "--profile", "-s", "--sandbox", "-C", "--cd", "--add-dir", "-a", "--ask-for-approval"),
		lists:      words("-i", "--image"),
		dropped:    words("--last", "--all", "--include-non-interactive"),
		subcommand: "resume"},
	"gemini": {program: "gemini",
		values:   words("-m", "--model", "--approval-mode", "-o", "--output-format", "-p", "--prompt", "-i", "--prompt-interactive", "-r", "--resume"),
		lists:    words("-e", "--extensions", "--include-directories", "--allowed-mcp-server-names", "--allowed-tools"),
		dropped:  words("-p", "--prompt", "-i", "--prompt-interactive", "-r", "--resume"),
		selector: "--resume"},
	"opencode": {program: "opencode",
		values:           words("--log-level", "--port", "--hostname", "--mdns-domain", "-m", "--model", "-s", "--session", "--prompt", "--agent"),
		lists:            words("--cors"),
		dropped:          words("-s", "--session", "-c", "--continue", "--fork", "--prompt"),
		keepsPositionals: true,
		selector:         "--session"},
}

// ResumeArgv is the command resuming session `session` of an agent of `kind` (AgentResume.argv);
// nil for an agent that can't be resumed. `command` is the tile's own (`props.command`): its
// options are kept when its program is that agent (by name, any directory), less what would
// pick or start another conversation (its own session selectors, its prompt).
func ResumeArgv(kind, session string, command []string) []string {
	g, ok := grammars[kind]
	if !ok {
		return nil
	}
	program, kept := g.options(command)
	argv := []string{program}
	if g.subcommand != "" {
		argv = append(argv, g.subcommand)
	}
	argv = append(argv, kept...)
	switch {
	case g.selector == "":
		return append(argv, session)
	case strings.HasSuffix(g.selector, "="):
		return append(argv, g.selector+session)
	default:
		return append(argv, g.selector, session)
	}
}

// options is the program `command` runs the agent as (its own path when it is that agent, else
// the agent's name) and the options of it the agent keeps (AgentResume.options).
func (g grammar) options(command []string) (string, []string) {
	if len(command) == 0 || filepath.Base(command[0]) != g.program {
		return g.program, nil
	}
	kept := []string{}
	rest := command[1:]
	positionalOnly := false
	for len(rest) > 0 {
		word := rest[0]
		rest = rest[1:]
		if word == "--" && !positionalOnly {
			positionalOnly = true
			continue
		}
		if positionalOnly || !strings.HasPrefix(word, "-") || word == "-" {
			if g.keepsPositionals {
				kept = append(kept, word)
			}
			continue
		}
		name := word
		if strings.HasPrefix(word, "--") {
			name, _, _ = strings.Cut(word, "=")
		}
		option := []string{word}
		if !strings.Contains(word, "=") || !strings.HasPrefix(word, "--") {
			switch {
			case g.values[name] && len(rest) > 0:
				option = append(option, rest[0])
				rest = rest[1:]
			case g.lists[name]:
				for len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
					option = append(option, rest[0])
					rest = rest[1:]
				}
			case g.optional[name] && len(rest) > 0 && !strings.HasPrefix(rest[0], "-"):
				option = append(option, rest[0])
				rest = rest[1:]
			}
		}
		if !g.dropped[name] {
			kept = append(kept, option...)
		}
	}
	return command[0], kept
}

// InitialArgv is what a new session of terminal `props` runs before its login shell
// (TerminalTile.initialArgv): the recorded agent session resumed with the options of the tile's
// own `command` (`props.agent`'s `kind` and `sessionId`, which agent.release clears), else the
// tile's `command`; nil for neither.
func InitialArgv(props map[string]any) []string {
	var command []string
	if list, ok := props["command"].([]any); ok {
		for _, x := range list {
			if s, ok := x.(string); ok {
				command = append(command, s)
			}
		}
	}
	if agent, ok := props["agent"].(map[string]any); ok {
		kind, hasKind := agent["kind"].(string)
		session, hasSession := agent["sessionId"].(string)
		if hasKind && hasSession {
			if argv := ResumeArgv(kind, session, command); argv != nil {
				return argv
			}
		}
	}
	return command
}

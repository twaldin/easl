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

// ResumeArgv is the command resuming the session `agent` recorded (`props.agent`,
// AgentResume.argv): ResumedSession of its `kind`; nil for an agent that can't be resumed or
// recorded no session. `command` is the tile's own (`props.command`): its options are kept when
// its program is that agent (by name, any directory), less what would pick or start another
// conversation (its own session selectors, its prompt).
func ResumeArgv(agent map[string]any, command []string) []string {
	kind, _ := agent["kind"].(string)
	g, ok := grammars[kind]
	session := ResumedSession(agent)
	if !ok || session == "" {
		return nil
	}
	program, kept := g.options(command, nil)
	return g.resumed(program, kept, session)
}

// ResumedSession is the session a recorded agent (`props.agent`) is resumed with, by a reboot
// and by agent.restart (AgentResume.session): omp's session file when it reported one (its
// `--resume` takes a path), else the session id; "" for none.
func ResumedSession(agent map[string]any) string {
	session, isPath := "", false
	if agent["kind"] == "omp" {
		session, isPath = agent["sessionPath"].(string)
	}
	if !isPath {
		session, _ = agent["sessionId"].(string)
	}
	return session
}

// resumed is the command running `program` with the kept arguments, resuming session `session`.
func (g grammar) resumed(program string, kept []string, session string) []string {
	argv := []string{program}
	if g.subcommand != "" {
		argv = append(argv, g.subcommand)
	}
	argv = append(argv, kept...)
	if g.selector == "" {
		return append(argv, session)
	}
	return append(argv, flag(g.selector, session)...)
}

// flag is option `name` given `value`: one word when the name ends in `=`.
func flag(name, value string) []string {
	if strings.HasSuffix(name, "=") {
		return []string{name + value}
	}
	return []string{name, value}
}

// setting is how an agent's command line names a model or a thinking level: the options that
// already do (left out when the recorded one replaces them), and the one given.
type setting struct {
	names set
	flag  string
}

// modelSettings are AgentResume.modelOption's, thinkingSettings its thinkingOption's, by agent
// kind. omp 18.6.1 `--help`: `--model=<value>` ("fuzzy match: opus, gpt-5.2, or
// openai/gpt-5.2"), `--thinking=<value>` (off, minimal, low, medium, high, xhigh, max, auto).
var (
	modelSettings = map[string]setting{
		"omp":      {words("--model"), "--model="},
		"claude":   {words("--model"), "--model"},
		"codex":    {words("-m", "--model"), "-m"},
		"gemini":   {words("-m", "--model"), "-m"},
		"opencode": {words("-m", "--model"), "-m"},
	}
	thinkingSettings = map[string]setting{"omp": {words("--thinking"), "--thinking="}}
)

// Relaunch is what agent.restart runs (AgentResume.Relaunch): Argv in the new session, and the
// tile's command from then on (Argv without the session selector), which a reboot reruns,
// resuming the session the new agent records (InitialArgv).
type Relaunch struct {
	Argv, Command []string
}

// RelaunchOf is the relaunch of a terminal whose agent is `kind` and whose tile runs `command`
// (AgentResume.relaunch): with `session`, its agent resuming that session; without, a fresh
// start. The command's options are kept when it runs that agent (its session selectors and
// prompt left out), the recorded `model` and `thinking` level replace any it gave, and `args`
// follow. A terminal with no known agent reruns its `command`, fresh only. False when there is
// nothing to relaunch. "" is none, for kind, session, model and thinking alike.
func RelaunchOf(kind string, command []string, session, model, thinking string, args []string) (Relaunch, bool) {
	g, ok := grammars[kind]
	if !ok {
		if session != "" || len(command) == 0 {
			return Relaunch{}, false
		}
		argv := append(append([]string{}, command...), args...)
		return Relaunch{Argv: argv, Command: argv}, true
	}
	replaced := set{}
	var given []string
	give := func(value string, s setting, known bool) {
		if value == "" || !known {
			return
		}
		for name := range s.names {
			replaced[name] = true
		}
		given = append(given, flag(s.flag, value)...)
	}
	m, known := modelSettings[kind]
	give(model, m, known)
	t, known := thinkingSettings[kind]
	give(thinking, t, known)
	program, kept := g.options(command, replaced)
	words := append(append(kept, given...), args...)
	fresh := append([]string{program}, words...)
	if session == "" {
		return Relaunch{Argv: fresh, Command: fresh}, true
	}
	return Relaunch{Argv: g.resumed(program, words, session), Command: fresh}, true
}

// options is the program `command` runs the agent as (its own path when it is that agent, else
// the agent's name) and the options of it the agent keeps (AgentResume.options): Grammar.dropped
// and `dropping` left out with their values, and positional words unless keepsPositionals.
func (g grammar) options(command []string, dropping set) (string, []string) {
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
		if !g.dropped[name] && !dropping[name] {
			kept = append(kept, option...)
		}
	}
	return command[0], kept
}

// InitialArgv is what a new session of terminal `props` runs before its login shell
// (TerminalTile.initialArgv): the agent session it recorded (`props.agent`, which agent.release
// clears) resumed with the options of the tile's own `command` (ResumeArgv), else the tile's
// `command`; nil for neither.
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
		if argv := ResumeArgv(agent, command); argv != nil {
			return argv
		}
	}
	return command
}

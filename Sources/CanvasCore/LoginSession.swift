/// What a fresh login session starts with before the user's startup files run: what a terminal
/// opened from the Dock gets. Terminal tiles and the login-shell lookups start from it rather
/// than from the app's own environment, which carries whatever launched the app: another
/// terminal's session state, or an agent's tool shell (omp's sets `CI`, `NO_COLOR`, `EDITOR=true`,
/// `GIT_EDITOR=true`, pagers set to `cat`, and `CLAUDECODE`, which makes Claude Code refuse to
/// start). The user's startup files set their own variables again.
public enum LoginSession {
    public static let variables: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"]

    /// Also passed to tiles: the agent that holds the user's SSH keys, and what Ghostty sets on
    /// the child itself (unsetting an inherited `TERM` would undo Ghostty's `xterm-ghostty`).
    static let tilePassthrough: Set<String> = ["SSH_AUTH_SOCK", "TERM", "TERMINFO", "COLORTERM"]
    static let tilePassthroughPrefixes = ["XDG_", "LC_", "GHOSTTY_"]

    /// The variables of `inherited` (the app's environment) to unset for a terminal tile's shell,
    /// sorted: all but the session variables and the passthrough above. `keep` are the tile's
    /// own variables (`PATH`, `EASL_*`, …), set before the unset runs.
    public static func strippedForTile(_ inherited: [String: String], keep: Set<String>) -> [String] {
        inherited.keys.filter { key in
            !keep.contains(key) && !variables.contains(key) && !tilePassthrough.contains(key)
                && !tilePassthroughPrefixes.contains { key.hasPrefix($0) }
        }.sorted()
    }

    /// What a terminal tile's session runs (docs/contracts.md "Terminal tile environment"): its
    /// initial `command` (one command line: a quoted argv, a spawn's or an agent's resume or
    /// relaunch) in a login shell, then an interactive login shell in that one's place; the
    /// interactive login shell alone without a command.
    ///
    /// `path`, when the user's interactive login shell answered (`LoginShell.interactivePath`,
    /// `commandPath`), is the command's PATH: `-l -c` reads `.zprofile` but not `.zshrc` (bash: a
    /// `.bashrc` returns early when not interactive), where PATH is often set, so launched by
    /// launchd (Finder, the Dock, `open`, the updater's relaunch) a bare `omp` was `command not
    /// found` though it ran at the tile's prompt. Only the command gets it: the shell after it reads
    /// the user's files itself. Without one the command has the login shell's own PATH.
    public static func tileStart(shell: String, command: String?, path: String?) -> [String] {
        guard let command else { return [shell, "-l"] }
        let run = path.map { "PATH=" + ShellWords.quote([$0]) + " " + command } ?? command
        return [shell, "-l", "-c", "\(run); exec \(ShellWords.quote([shell])) -l"]
    }

    /// An interactive login shell's PATH (`resolved`) for a tile's command: easl's `bin` first,
    /// where the shell integration puts it after the user's startup files.
    public static func commandPath(_ resolved: String, bin: String?) -> String {
        guard let bin else { return resolved }
        return ([bin] + resolved.split(separator: ":", omittingEmptySubsequences: false).map(String.init).filter { $0 != bin }).joined(separator: ":")
    }
}

extension LoginSession {
    /// A terminal tile's shell-integration variables for the app's resources at `resources`
    /// (docs/contracts.md "Terminal tile environment"): easl's `bin/` first on `PATH`, its
    /// `clients/python` on `PYTHONPATH`, `ZDOTDIR` its zsh integration with the user's own in
    /// `EASL_ZSH_ZDOTDIR`, and its bash integration in `PROMPT_COMMAND`, each before what the
    /// app inherited; `BROWSER` is its `open` shim.
    ///
    /// An app launched from inside an easl tile (an agent's `scripts/dev.sh restart`, `open` in a
    /// tile) inherits that tile's integration, possibly of another bundle: taken as the user's own,
    /// its `ZDOTDIR` made every new tile source easl's startup files instead of the user's
    /// (`_canvas_finish: command not found`, no `~/.zshrc`). So every easl integration found in
    /// `inherited` is taken out first (`canvasResources`), and the user's `ZDOTDIR` is what that
    /// tile kept aside in `EASL_ZSH_ZDOTDIR`, else none (their startup files are in `HOME`).
    public static func tileShellIntegration(resources: String, inherited: [String: String]) -> [String: String] {
        let foreign = canvasResources(in: inherited).union([resources])
        func kept(_ list: String?, dropping entry: (String) -> String) -> [String] {
            let dropped = Set(foreign.map(entry))
            return (list ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init).filter { !dropped.contains($0) }
        }
        let bin = resources + "/bin", python = resources + "/clients/python"
        let path = kept(inherited["PATH"]) { $0 + "/bin" }
        var env = [
            "PATH": ([bin] + (path.isEmpty ? ["/usr/bin", "/bin"] : path)).joined(separator: ":"),
            "PYTHONPATH": ([python] + kept(inherited["PYTHONPATH"]) { $0 + "/clients/python" }).joined(separator: ":"),
            "ZDOTDIR": resources + "/extensions/shell/zsh",
            // Programs that open a web page (`$BROWSER`) reach the tile's `open` shim, which shows
            // http(s) addresses in a browser tile beside the terminal.
            "BROWSER": bin + "/open",
        ]
        let zdotdir = [inherited["ZDOTDIR"], inherited["EASL_ZSH_ZDOTDIR"]].compactMap { $0 }.first { integrationRoot(zsh: $0) == nil }
        if let zdotdir { env["EASL_ZSH_ZDOTDIR"] = zdotdir }
        let bash = bashIntegration(resources)
        let commands = (inherited["PROMPT_COMMAND"] ?? "").components(separatedBy: "; ").filter { !$0.isEmpty && bashIntegrationRoot($0) == nil }
        env["PROMPT_COMMAND"] = ([bash] + commands).joined(separator: "; ")
        return env
    }

    /// What `PROMPT_COMMAND` runs first in a tile: source the bash integration.
    static func bashIntegration(_ resources: String) -> String {
        ". '" + (resources + bashScript).replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static let zshDirectory = "/extensions/shell/zsh"
    private static let bashScript = "/extensions/shell/bash/easl.bash"

    /// The resource directories of the easl integrations `inherited` carries: a tile's
    /// `ZDOTDIR` (kept by non-interactive shells and the programs they start), an `EASL_ZSH_ZDOTDIR`
    /// an older easl set from one, and `PROMPT_COMMAND`'s sourcing of `easl.bash` (kept by every
    /// shell), whichever are there.
    static func canvasResources(in inherited: [String: String]) -> Set<String> {
        var found = Set([inherited["ZDOTDIR"], inherited["EASL_ZSH_ZDOTDIR"]].compactMap { $0.flatMap(integrationRoot(zsh:)) })
        for command in (inherited["PROMPT_COMMAND"] ?? "").components(separatedBy: "; ") {
            if let root = bashIntegrationRoot(command) { found.insert(root) }
        }
        return found
    }

    /// `<resources>` when `dir` is `<resources>/extensions/shell/zsh`, easl's zsh integration.
    static func integrationRoot(zsh dir: String) -> String? {
        let trimmed = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        guard trimmed.hasSuffix(zshDirectory), trimmed.count > zshDirectory.count else { return nil }
        return String(trimmed.dropLast(zshDirectory.count))
    }

    /// `<resources>` when `command` is `bashIntegration(<resources>)`.
    static func bashIntegrationRoot(_ command: String) -> String? {
        guard command.hasPrefix(". '"), command.hasSuffix(bashScript + "'") else { return nil }
        let quoted = command.dropFirst(3).dropLast(bashScript.count + 1)
        let root = quoted.replacingOccurrences(of: "'\"'\"'", with: "'")
        return root.isEmpty ? nil : root
    }
}

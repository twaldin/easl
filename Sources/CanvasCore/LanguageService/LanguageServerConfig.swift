import Foundation

/// How to run one language's server and which files and project roots belong to it.
public struct LanguageServerConfig: Sendable, Equatable {
    /// Registry key, e.g. "swift".
    public var language: String
    /// Binary name found by `LoginShell.locate` (the override variable, the login PATH, then
    /// `directories` and `locators`), or an absolute path.
    public var command: String
    public var arguments: [String]
    /// File extension (lowercased, no dot) → LSP languageId.
    public var languageIDs: [String: String]
    /// Files that mark a project root; the nearest one above a file (within the board root) wins.
    public var rootMarkers: [String]
    public var initializationOptions: JSONValue?
    /// Shown with an empty definition/references answer: why the server may not know yet.
    public var emptyResultHint: String?
    /// How to install the server, shown when it isn't found.
    public var installHint: String?
    /// Install directories to look in when the login PATH lacks `command` (`~` is the home
    /// directory), after `toolDirectories`: installers that don't put their binaries on PATH.
    public var directories: [String]
    /// Shell commands, run in the login shell after the directories, that print the binary's
    /// path (`rustup which rust-analyzer`).
    public var locators: [String]

    public init(language: String, command: String, arguments: [String] = [], languageIDs: [String: String], rootMarkers: [String],
                initializationOptions: JSONValue? = nil, emptyResultHint: String? = nil, installHint: String? = nil,
                directories: [String] = [], locators: [String] = []) {
        self.language = language
        self.command = command
        self.arguments = arguments
        self.languageIDs = languageIDs
        self.rootMarkers = rootMarkers
        self.initializationOptions = initializationOptions
        self.emptyResultHint = emptyResultHint
        self.installHint = installHint
        self.directories = directories
        self.locators = locators
    }

    /// Where editors install servers for any language without putting them on PATH: nvim's mason.
    public static let toolDirectories = ["~/.local/share/nvim/mason/bin"]

    /// The environment variable naming this language's server binary, ahead of any lookup
    /// (`EASL_LSP_RUST=/path/to/rust-analyzer`), read in the login shell, so a line in the
    /// shell profile sets it without putting the binary's directory on PATH.
    public var overrideVariable: String { "EASL_LSP_" + language.uppercased() }

    /// Why the server can't run, for navigation panels: where easl looked, how to install it,
    /// and how to point easl at a binary elsewhere.
    public var notFound: String {
        let places = ["on the login shell's PATH", "in " + (Self.toolDirectories + directories).joined(separator: ", ")] + locators.map { "with `\($0)`" }
        let looked = places.dropLast().joined(separator: ", ") + " and " + places.last!
        return "\(command) not found (easl looked \(looked)). " + (installHint.map { "\($0). " } ?? "") + "Or set \(overrideVariable) to its path in your shell profile."
    }

    public static let defaults: [LanguageServerConfig] = [
        // Background indexing would run `swift build` into the user's repo whenever a code tile
        // opens a Swift file; on a shared machine the index comes from the user's own builds.
        LanguageServerConfig(language: "swift", command: "sourcekit-lsp", languageIDs: ["swift": "swift"],
                             rootMarkers: ["Package.swift", "compile_commands.json", "buildServer.json"],
                             initializationOptions: .object(["backgroundIndexing": .bool(false)]),
                             emptyResultHint: "easl doesn't index Swift projects itself; sourcekit-lsp answers from the index your own builds write (swift build).",
                             installHint: "It comes with Xcode or the Command Line Tools: xcode-select --install"),
        LanguageServerConfig(language: "python", command: "pyright-langserver", arguments: ["--stdio"], languageIDs: ["py": "python", "pyi": "python"],
                             rootMarkers: ["pyrightconfig.json", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"],
                             installHint: "Install it with: npm install -g pyright"),
        LanguageServerConfig(language: "typescript", command: "typescript-language-server", arguments: ["--stdio"],
                             languageIDs: ["ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
                                           "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact"],
                             rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json"],
                             installHint: "Install it with: npm install -g typescript-language-server typescript@5 (TypeScript 7 has no tsserver, which the server needs)"),
        LanguageServerConfig(language: "go", command: "gopls", languageIDs: ["go": "go"], rootMarkers: ["go.work", "go.mod"],
                             installHint: "Install it with: go install golang.org/x/tools/gopls@latest", directories: ["~/go/bin"]),
        // rustup puts a component in its toolchain, reachable on PATH only through ~/.cargo/bin's
        // proxies (whose rust-analyzer fails until the component is added); `rustup which` finds it.
        LanguageServerConfig(language: "rust", command: "rust-analyzer", languageIDs: ["rs": "rust"], rootMarkers: ["Cargo.toml"],
                             installHint: "Install it with: rustup component add rust-analyzer", locators: ["rustup which rust-analyzer"]),
    ]

    public func languageID(for file: URL) -> String? {
        languageIDs[file.pathExtension.lowercased()]
    }

    /// Nearest directory containing a root marker, walking up from the file but never above
    /// `boundary` (the board root); the boundary itself when nothing marks a project. Both are
    /// real paths (`GitDiffEngine.realPath`), kept as they are: standardizing would turn
    /// /private/tmp back into /tmp, a spelling sourcekit-lsp doesn't match to its package's
    /// files (fallback settings: no index answers).
    public func projectRoot(for file: URL, within boundary: URL) -> URL {
        let limit = boundary.path
        var directory = URL(fileURLWithPath: file.deletingLastPathComponent().path)
        let fileManager = FileManager.default
        while directory.path.hasPrefix(limit) {
            if rootMarkers.contains(where: { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return directory }
            if directory.path == limit { break }
            directory = URL(fileURLWithPath: directory.deletingLastPathComponent().path)
        }
        return file.path.hasPrefix(limit + "/") ? URL(fileURLWithPath: limit) : URL(fileURLWithPath: file.deletingLastPathComponent().path)
    }
}

/// GUI apps start with launchd's minimal PATH, while language servers live on the login shell's
/// (Homebrew, npm, pyenv) and some are scripts that need it too (pyright is `#!/usr/bin/env node`).
/// Binaries are looked up through the login shell and cached, and so is that PATH; a binary
/// not found is looked for again after `missRetry`, so installing one needs no restart.
public final class LoginShell: @unchecked Sendable {
    public static let shared = LoginShell()
    public static let missRetry: Duration = .seconds(30)
    /// The longest a terminal's start waits for `interactivePath` (less when `timeout` is).
    public static let spawnTimeout: Duration = .seconds(5)

    private let shell: String
    private let home: String
    private let inherited: [String: String]
    private let timeout: Duration
    private let lock = NSLock()
    private var resolved: [String: (url: URL?, at: ContinuousClock.Instant)] = [:]
    private var cachedPath: String?
    private var cachedEditor: String??
    private var interactivePaths: [String: (path: String?, zdotdir: String?, stamp: [String], at: ContinuousClock.Instant)] = [:]
    /// Held while `interactivePath` asks the shell: a start waiting on the question in flight
    /// (a background retry) takes its answer rather than asking again.
    private let pathProbe = NSLock()

    /// `home` is what a leading `~` in a server's install directories stands for, and where the
    /// user's startup files are; `inherited` is the environment the session variables
    /// (`LoginSession.variables`) of an interactive shell come from.
    public init(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", home: String = NSHomeDirectory(),
                inherited: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = .seconds(10)) {
        self.shell = shell
        self.home = home
        self.inherited = inherited
        self.timeout = timeout
    }

    /// Absolute path of `command` on the login PATH, or nil when it isn't installed.
    public func resolve(_ command: String) -> URL? {
        if command.hasPrefix("/") { return Self.executable(command) }
        return cached("command:\(command)") {
            probe(["$(command -v \(Self.quote(command)))"]).first.flatMap(Self.executable)
        }
    }

    /// A language server's binary: the one its override variable names (`EASL_LSP_RUST`), else
    /// `command` on the login PATH, else in the install directories (`toolDirectories`, then the
    /// language's own), else what its locators print (`rustup which rust-analyzer`). One login
    /// shell answers the variable, PATH, and locators together. Nil when none is executable.
    public func locate(_ config: LanguageServerConfig) -> URL? {
        if config.command.hasPrefix("/") { return Self.executable(config.command) }
        return cached("server:\(config.language):\(config.command)") {
            let probes = ["${\(config.overrideVariable)-}", "$(command -v \(Self.quote(config.command)))"] + config.locators.map { "$(\($0) 2>/dev/null)" }
            let answers = probe(probes)
            let directories = (LanguageServerConfig.toolDirectories + config.directories).map { directory in
                (directory.hasPrefix("~/") ? home + directory.dropFirst() : directory) + "/" + config.command
            }
            return (Array(answers.prefix(2)) + directories + Array(answers.dropFirst(2))).lazy.compactMap(Self.executable).first
        }
    }

    private func cached(_ key: String, _ find: () -> URL?) -> URL? {
        if let known = lock.withLock({ resolved[key] }), known.url != nil || known.at.duration(to: .now) < Self.missRetry { return known.url }
        let found = find()
        lock.withLock { resolved[key] = (found, .now) }
        return found
    }

    private static func executable(_ path: String) -> URL? {
        path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// The app environment with the login shell's PATH, for server processes.
    public var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = lock.withLock { cachedPath } ?? {
            let value = probe(["$PATH"]).first ?? ""
            let path = value.isEmpty ? (environment["PATH"] ?? "/usr/bin:/bin") : value
            lock.withLock { cachedPath = path }
            return path
        }()
        environment["PATH"] = path
        return environment
    }

    /// The editor the user's shell names: `$VISUAL`, else `$EDITOR`; nil when neither is set.
    /// Read once from an interactive login shell, since editors are often exported only in
    /// interactive rc files (.zshrc), started with only the basic session variables, so what the
    /// app inherited from whatever launched it doesn't mask the user's setup. Blocking: call it
    /// off the main thread and out of Swift tasks.
    public var editor: String? {
        if let cached = lock.withLock({ cachedEditor }) { return cached }
        let value = probe(["${VISUAL:-$EDITOR}"], interactive: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]).first ?? ""
        let editor = value.isEmpty ? nil : value
        lock.withLock { cachedEditor = .some(editor) }
        return editor
    }

    /// The PATH the user's interactive login shell sets up when it starts in `cwd` with `path`
    /// (and the user's `zdotdir` as ZDOTDIR), with only the session variables otherwise, as
    /// `editor`: what a command typed at a terminal tile's prompt there is looked up on. A tile's
    /// initial command runs in a non-interactive login shell (`LoginSession.tileStart`), which
    /// reads no `.zshrc` (bash: a `.bashrc` that returns early when not interactive), where
    /// installers put their PATH (bun's, nvm's); an app launched by launchd inherits only
    /// `/usr/bin:/bin:/usr/sbin:/sbin`.
    ///
    /// Nil when the shell failed, or hadn't exited by `spawnTimeout`: the command then keeps the
    /// login shell's own PATH. Cached per `cwd` until a startup file changes (`startupStamp`,
    /// with the ZDOTDIR the shell ended with); a nil is asked again in the background after
    /// `missRetry`. Blocks while the shell is asked, at most `spawnTimeout` (or `timeout`) beyond
    /// a question already in flight.
    public func interactivePath(from path: String, in cwd: String, zdotdir: String? = nil) -> String? {
        let key = [path, cwd, zdotdir ?? ""].joined(separator: "\0")
        if let known = lock.withLock({ interactivePaths[key] }), known.stamp == startupStamp(zdotdir: zdotdir, resolved: known.zdotdir) {
            if known.path == nil, known.at.duration(to: .now) >= Self.missRetry {
                DispatchQueue.global(qos: .utility).async { _ = self.askInteractivePath(key, from: path, in: cwd, zdotdir: zdotdir) }
            }
            return known.path
        }
        return askInteractivePath(key, from: path, in: cwd, zdotdir: zdotdir)
    }

    private func askInteractivePath(_ key: String, from path: String, in cwd: String, zdotdir: String?) -> String? {
        pathProbe.withLock {
            // The question that held the lock may have answered this one.
            if let known = lock.withLock({ interactivePaths[key] }), known.stamp == startupStamp(zdotdir: zdotdir, resolved: known.zdotdir),
               known.path != nil || known.at.duration(to: .now) < Self.missRetry {
                return known.path
            }
            let variables = ["PATH": path].merging(zdotdir.map { ["ZDOTDIR": $0] } ?? [:]) { $1 }
            let values = probe(["$PATH", "$ZDOTDIR"], interactive: variables, in: cwd, timeout: min(timeout, Self.spawnTimeout))
            let found = values.first.flatMap { $0.isEmpty ? nil : $0 }
            let resolved = values.count > 1 && !values[1].isEmpty ? values[1] : nil
            lock.withLock { interactivePaths[key] = (found, resolved, startupStamp(zdotdir: zdotdir, resolved: resolved), .now) }
            return found
        }
    }

    /// What `stat` says of each of the shells' startup files (zsh's in `zdotdir`, `HOME`,
    /// `~/.config/zsh` and the ZDOTDIR the shell ended with (`resolved`: one `~/.zshenv` set),
    /// bash's, fish's under `XDG_CONFIG_HOME`, and what macOS's path_helper reads): one edited,
    /// replaced or repointed (a symlinked `.zshrc`) asks the shell again. Files they source in
    /// turn aren't followed.
    private func startupStamp(zdotdir: String?, resolved: String?) -> [String] {
        let zsh = Set([zdotdir, resolved, home, home + "/.config/zsh"].compactMap { $0 }).sorted()
            .flatMap { directory in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"].map { directory + "/" + $0 } }
        let config = inherited["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        let files = zsh + [".bash_profile", ".bash_login", ".profile", ".bashrc", ".bash_logout"].map { home + "/" + $0 }
            + ["fish/config.fish", "fish/conf.d", "fish/fish_variables"].map { config + "/" + $0 }
            + ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/zlogin", "/etc/profile", "/etc/bashrc", "/etc/paths", "/etc/paths.d"]
        return files.map { file in
            var info = stat()
            guard stat(file, &info) == 0 else { return "-" }
            return "\(info.st_ino) \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        }
    }

    private static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What the login shell expands each of `values` (shell words) to, trimmed: what it printed
    /// between a marker before each and an end marker after it, so what rc files print around them
    /// (a `.zlogout`, an EXIT trap) stays out of the answers; empty when the shell failed or an
    /// answer wasn't ended. `interactive`: asked of an interactive login shell (`-lic`) started
    /// in `cwd` with only the session variables (`fresh`) and these, not the app's environment.
    private func probe(_ values: [String], interactive: [String: String]? = nil, in cwd: String? = nil, timeout: Duration? = nil) -> [String] {
        let (marker, end) = ("__CANVAS_VALUE__", "__CANVAS_END__")
        let script = values.map { "printf '\\n\(marker)%s\(end)' \"\($0)\"" }.joined(separator: "; ")
        let output = run(script, fresh: interactive.map(fresh), in: cwd, timeout: timeout ?? self.timeout)
        return output.components(separatedBy: "\n" + marker).dropFirst().map { answer in
            answer.range(of: end).map { answer[..<$0.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
    }

    /// What a fresh login session's shell starts with: the session variables (`LoginSession.variables`)
    /// and the `XDG_*` and `LC_*` ones a tile keeps, of `inherited`, with `variables` over them.
    private func fresh(_ variables: [String: String]) -> [String] {
        let names = inherited.keys.filter { name in
            variables[name] == nil && (LoginSession.variables.contains(name) || name.hasPrefix("XDG_") || name.hasPrefix("LC_"))
        }
        return (names.sorted().map { "\($0)=\(inherited[$0] ?? "")" }) + variables.keys.sorted().map { "\($0)=\(variables[$0] ?? "")" }
    }

    /// Runs `$SHELL -lc script` in its own process group and reads its output until EOF or the
    /// deadline. At the deadline the whole group is killed and the read abandoned: rc files can
    /// start children that outlive the shell and keep the output pipe open. `fresh`: `-lic`,
    /// with only these variables, not the app's environment; `cwd`: where it starts. Empty when
    /// the shell hadn't exited by the deadline, even after closing its output.
    private func run(_ script: String, fresh variables: [String]?, in cwd: String? = nil, timeout: Duration) -> String {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return "" }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { close(readEnd) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let words: [String] = [shell, variables != nil ? "-lic" : "-lc", script]
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let fresh: [UnsafeMutablePointer<CChar>?] = (variables ?? []).map { strdup($0) } + [nil]
        defer { fresh.forEach { free($0) } }
        let spawned = variables != nil ? posix_spawn(&pid, shell, &actions, &attributes, argv, fresh) : posix_spawn(&pid, shell, &actions, &attributes, argv, environ)
        close(writeEnd)
        guard spawned == 0 else { return "" }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock.now + timeout
        var reaped = false
        var eof = false
        var status: Int32 = 0
        reading: while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            // Short slices: once the shell has exited, what it printed is complete even if a
            // child it started still holds the pipe open.
            var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(100, max(1, remaining.seconds * 1000))))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                if !reaped, waitpid(pid, &status, WNOHANG) == pid { reaped = true }
                if reaped {
                    // Drain what's already buffered, then stop.
                    while poll(&poller, 1, 0) > 0 {
                        let count = read(readEnd, &buffer, buffer.count)
                        guard count > 0 else {
                            eof = true
                            break reading
                        }
                        output.append(contentsOf: buffer[0..<count])
                    }
                    break
                }
                continue
            }
            let count = read(readEnd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 {
                eof = true
                break
            }
            output.append(contentsOf: buffer[0..<count])
        }
        // A shell that closed its output (`exec >/dev/null` in an rc file) and hasn't exited is
        // waited for only until the deadline.
        while eof, !reaped, ContinuousClock.now < deadline {
            let done = waitpid(pid, &status, WNOHANG)
            if done == pid {
                reaped = true
            } else if done < 0, errno != EINTR {
                break
            } else {
                usleep(10_000)
            }
        }
        let exited = reaped
        // Anything in the group still holding the pipe or running (a hung shell, or a child an
        // rc file left behind) is ended with it.
        if !eof || !reaped { kill(-pid, SIGKILL) }
        if !reaped { while waitpid(pid, &status, 0) < 0, errno == EINTR {} }
        return exited ? String(decoding: output, as: UTF8.self) : ""
    }
}

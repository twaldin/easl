import Foundation

public enum ZmxIsolation {
    public struct Layout: Equatable, Sendable {
        public var zmxDir: String
        public var stateHome: String
        public var tmpDir: String
    }

    public enum Decision: Equatable, Sendable {
        case installed
        case isolated(Layout)
        case refuse(String)
    }

    /// `<home>/zmx`, `<home>/state`, `<home>/tmp`. Nil unless `home` is absolute.
    public static func layout(home: String) -> Layout? {
        guard home.hasPrefix("/") else { return nil }
        let root = trimSlash(home)
        return Layout(zmxDir: root + "/zmx", stateHome: root + "/state", tmpDir: root + "/tmp")
    }

    /// No `EASL_HOME`: the installed app, left alone. Otherwise isolate under
    /// that home, or refuse when a path resolves outside the home or into the
    /// installed app's zmx directories (a symlink, not a string prefix).
    public static func decide(environment: [String: String], uid: UInt32, accountHome: String, guiTemp: String?) -> Decision {
        guard let home = environment["EASL_HOME"] else { return .installed }
        guard let layout = layout(home: home) else {
            return .refuse("EASL_HOME is not an absolute path, so zmx state cannot be kept under that home")
        }
        // zmx 0.8.1 allows 103 socket-path bytes; canvas session names need 29.
        guard layout.zmxDir.utf8.count + 1 + 29 <= 103 else {
            return .refuse("home is too long for a zmx socket; choose a shorter EASL_DEV_HOME")
        }
        do {
            let root = try physical(home)
            let installed = try installedPaths(environment: environment, uid: uid, accountHome: accountHome, guiTemp: guiTemp, layout: layout).map(physical)
            for path in [layout.zmxDir, layout.zmxDir + "/logs", layout.stateHome, layout.stateHome + "/zmx/logs", layout.tmpDir, layout.tmpDir + "/zmx-\(uid)"] {
                let resolved = try physical(path)
                guard resolved == root || resolved.hasPrefix(root == "/" ? "/" : root + "/") else {
                    return .refuse("development zmx path \(resolved) is outside its home \(root)")
                }
                if let shared = installed.first(where: { shares(resolved, $0) }) {
                    return .refuse("development zmx path \(resolved) is the installed app's zmx path \(shared)")
                }
            }
            return .isolated(layout)
        } catch {
            return .refuse("cannot resolve development zmx paths: \(error.localizedDescription)")
        }
    }

    /// Installed-app zmx directories: account logs, `/tmp/zmx-<uid>`, the GUI
    /// temp's `zmx-<uid>` when known, and `XDG_RUNTIME_DIR/zmx` when set. A
    /// development override already in `environment` is not treated as installed.
    private static func installedPaths(environment: [String: String], uid: UInt32, accountHome: String, guiTemp: String?, layout: Layout) throws -> [String] {
        var paths: [String] = []
        func add(_ path: String?) {
            guard let path, path.hasPrefix("/") else { return }
            paths.append(path)
        }
        let account = trimSlash(accountHome)
        add(account + "/.local/state/zmx")
        add(account + "/Library/Application Support/Easl")
        add(account + "/.local/state/easl")
        add("/Applications/easl.app")
        add(account + "/Applications/easl.app")
        add(account + "/.local/state/zmx/logs")
        if let home = environment["HOME"], home.hasPrefix("/"), trimSlash(home) != account {
            let root = trimSlash(home)
            add(root + "/.local/state/zmx")
            add(root + "/.local/state/zmx/logs")
        }
        add("/tmp/zmx-\(uid)")
        if let guiTemp, guiTemp.hasPrefix("/") {
            add(trimSlash(guiTemp) + "/zmx-\(uid)")
        }
        if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
            add(runtime + "/zmx")
        }
        if let state = environment["XDG_STATE_HOME"], state.hasPrefix("/"), try physical(state) != physical(layout.stateHome) {
            add(trimSlash(state) + "/zmx")
            add(trimSlash(state) + "/zmx/logs")
        }
        if let zmx = environment["ZMX_DIR"], zmx.hasPrefix("/"), try physical(zmx) != physical(layout.zmxDir) {
            add(zmx)
        }
        return paths
    }

    /// Symlink-free absolute path, including a suffix that does not exist yet.
    /// `..` is applied after the symlink it follows, which a lexical prefix misses.
    static func physical(_ path: String) throws -> String {
        try physical(path, links: 0)
    }

    private static func physical(_ path: String, links: Int) throws -> String {
        guard links < 40 else { throw POSIXError(.ELOOP) }
        guard path.hasPrefix("/") else { throw POSIXError(.EINVAL) }
        var resolved = "/"
        var pending: [String] = []
        for part in path.split(separator: "/") {
            let name = String(part)
            if name == "." || name.isEmpty { continue }
            if name == ".." {
                if pending.isEmpty {
                    if resolved != "/" { resolved = (resolved as NSString).deletingLastPathComponent }
                    if resolved.isEmpty { resolved = "/" }
                } else {
                    pending.removeLast()
                }
                continue
            }
            if pending.isEmpty {
                let candidate = resolved == "/" ? "/" + name : resolved + "/" + name
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                    resolved = try physical(target.hasPrefix("/") ? target : resolved + "/" + target, links: links + 1)
                    continue
                }
                if let real = existingRealpath(candidate) {
                    resolved = real
                    continue
                }
            }
            pending.append(name)
        }
        for name in pending {
            resolved = resolved == "/" ? "/" + name : resolved + "/" + name
        }
        return resolved
    }

    private static func shares(_ a: String, _ b: String) -> Bool {
        if a == b || a == "/" || b == "/" { return true }
        return a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private static func trimSlash(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "/" : value
    }

    private static func existingRealpath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let value = String(cString: resolved)
        return value.isEmpty ? "/" : value
    }
}

import AppKit
import CanvasCore
import Darwin
import GhosttyTerminal

if CommandLine.arguments.dropFirst().first == "--update-swap" {
    guard CommandLine.arguments.count == 4 else {
        FileHandle.standardError.write(Data("easl: --update-swap requires installed and incoming paths\n".utf8))
        exit(2)
    }
    do {
        try AppUpdate.swapBundles(installed: URL(fileURLWithPath: CommandLine.arguments[2]),
                                  incoming: URL(fileURLWithPath: CommandLine.arguments[3]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("easl: bundle exchange failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

_ = AppPaths.isUpdateRelaunch

// An install under an earlier name (Canvas 0.4 or 0.2, Chalkwork 0.3): its boards, settings and browser
// profile, moved once, before anything reads AppPaths or the defaults (LegacyMigration). Never for
// a development home (EASL_HOME, or an earlier name's), and not while an earlier app is running
// (it would still be writing there): the next launch after it quits moves them.
do {
    let environment = ProcessInfo.processInfo.environment
    let account = FileManager.default.homeDirectoryForCurrentUser
    if !([LegacyMigration.current] + LegacyMigration.earlier).contains(where: { environment["\($0.slug.uppercased())_HOME"] != nil }) {
        let migration = LegacyMigration(home: account)
        if !migration.pending(defaults: UserDefaults.standard).isEmpty {
            let others = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() }.compactMap(\.bundleIdentifier)
            if let refusal = migration.refusal(running: others) {
                NSLog("easl: %@", refusal)
            } else {
                migrateLegacyBoards(migration, defaults: UserDefaults.standard)
            }
        }
    } else if let fake = environment["HOME"].map({ URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }), fake != account.standardizedFileURL,
              let home = environment["EASL_HOME"],
              URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL == LegacyMigration(home: fake).support(LegacyMigration.current).standardizedFileURL {
        // An upgrade rehearsal on a throwaway home (docs/testing.md): HOME is that home, EASL_HOME
        // its default support directory. UserDefaults ignores HOME, so the migration reads and writes
        // that home's Library/Preferences plists itself, never the user's; no earlier app writes there.
        migrateLegacyBoards(LegacyMigration(home: fake), defaults: PreferenceFiles(home: fake))
    }
}

@MainActor
func migrateLegacyBoards(_ migration: LegacyMigration, defaults: some DefaultsDomains) {
    let lines = migration.run(defaults: defaults)
    for line in lines { NSLog("easl: %@", line) }
    guard migration.pending(defaults: defaults).isEmpty else {
        let app = CanvasApplication.shared
        app.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "Couldn't migrate saved boards"
        alert.informativeText = lines.joined(separator: "\n")
        alert.runModal()
        exit(1)
    }
}

switch ZmxIsolation.decide(environment: ProcessInfo.processInfo.environment, uid: UInt32(getuid()),
                           accountHome: FileManager.default.homeDirectoryForCurrentUser.path,
                           guiTemp: guiTemporaryDirectory()) {
case .installed:
    break
case .refuse(let reason):
    refuseDevelopmentZmx(reason)
case .isolated(let layout):
    do {
        for path in [layout.zmxDir, layout.stateHome, layout.tmpDir] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    } catch {
        refuseDevelopmentZmx("could not create this development home's zmx paths: \(error.localizedDescription)")
    }
    if setenv("ZMX_DIR", layout.zmxDir, 1) != 0
        || setenv("XDG_STATE_HOME", layout.stateHome, 1) != 0
        || setenv("TMPDIR", layout.tmpDir, 1) != 0 {
        refuseDevelopmentZmx("could not set this development home's zmx paths")
    }
}

func refuseDevelopmentZmx(_ reason: String) -> Never {
    let line = "easl: refusing to start: \(reason)"
    NSLog("%@", line)
    FileHandle.standardError.write(Data((line + "\n").utf8))
    exit(1)
}

func guiTemporaryDirectory() -> String? {
    var buffer = [CChar](repeating: 0, count: 1024)
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    guard length > 1, length <= buffer.count else { return nil }
    return String(cString: buffer)
}

// One instance per support directory: a second would take over the first's sockets. It hands the
// root it was asked to open to the running instance, and exits. After the
// migration, which may move another support directory to this one's place.
guard let instanceLock = InstanceLock.acquire(at: AppPaths.instanceLock) else {
    let holder = InstanceLock.holder(at: AppPaths.instanceLock)
    let requestedRoot = AppDelegate.requestedRoot()
    if let root = requestedRoot {
        do {
            let reply = try InstanceLock.forward(root: root.standardizedFileURL.path, to: AppPaths.apiSocket)
            if reply["ok"]?.bool != true { NSLog("easl: the running instance could not open %@: %@", root.path, "\(reply)") }
        } catch {
            NSLog("easl: could not hand %@ to the running instance (pid %@): %@", root.path, holder.map { "\($0)" } ?? "?", "\(error)")
        }
    }
    // Only a running easl: the pid may be a previous holder's, reused since (`holder`).
    if requestedRoot == nil, !CanvasApplication.neverActivate, let holder, let running = NSRunningApplication(processIdentifier: holder),
       running.executableURL?.lastPathComponent == Bundle.main.executableURL?.lastPathComponent {
        running.activate()
    }
    NSLog("easl: another instance is running on %@; handed over to it", AppPaths.support.path)
    exit(0)
}

if ProcessInfo.processInfo.environment["EASL_TERMINAL_DEBUG"] == "1" {
    TerminalDebugLog.sink = { message in FileHandle.standardError.write(Data((message + "\n").utf8)) }
    TerminalDebugLog.enable([.lifecycle, .actions])
}

let app = CanvasApplication.shared
NoteMermaid.backend = NoteMermaidWeb()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

import Foundation

/// Which of easl's own leftover files can go (docs/contracts.md "On-disk locations"). The app
/// deletes what these choose at launch, off the main thread; ending a tile's session deletes its
/// zmx log at once (`TerminalTile.killSession`). Only names easl itself writes are ever chosen:
/// a file of any other name in the same directory is never touched.
public enum Housekeeping {
    /// A directory entry: its name and when it was last written.
    public struct File: Equatable, Sendable {
        public var name: String
        public var modified: Date

        public init(name: String, modified: Date) {
            self.name = name
            self.modified = modified
        }
    }

    /// How long an easl session's log is left alone after its last write: a session that starts
    /// now may have created its log before `zmx list` shows it.
    public static let logSettle: TimeInterval = 5 * 60
    /// libghostty writes a config file per configuration and reads it once, while loading it
    /// (surfaces take the loaded config, never the file); one this old has been read.
    public static let ghosttyConfigSettle: TimeInterval = 60
    /// Renders and snapshots written without `out` (`ApiRouter.scratchImages`) are kept this long.
    public static let renderAge: TimeInterval = 24 * 60 * 60

    /// zmx's log of an easl tile's session (`canvas-obj_<id>.log`, `<session>.log`):
    /// `$ZMX_DIR/logs` when `ZMX_DIR` is set, else `$XDG_STATE_HOME/zmx/logs`, else
    /// `~/.local/state/zmx/logs`.
    public static func sessionLog(session: String) -> String { session + ".log" }

    /// The session names in `zmx list` output (`name=<session>\t…` per line, the current one
    /// marked with `*`).
    public static func sessionNames(zmxList output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            let name = line.split(separator: "\t").first?.drop(while: { $0 == " " || $0 == "*" })
            return name.flatMap { $0.hasPrefix("name=") ? String($0.dropFirst(5)) : nil }
        })
    }

    /// Logs of easl sessions (`canvas-obj_…`) that aren't in `live` (every running session's
    /// name, any instance's) and haven't been written for `logSettle`.
    public static func deadSessionLogs(_ files: [File], live: Set<String>, now: Date) -> [String] {
        files.filter { file in
            guard file.name.hasSuffix(".log") else { return false }
            let session = String(file.name.dropLast(4))
            return isCanvasSession(session) && !live.contains(session) && now.timeIntervalSince(file.modified) >= logSettle
        }.map(\.name)
    }

    /// libghostty's generated configs (`ghostty-config-<UUID>.conf` in its managed directory,
    /// `$TMPDIR/net.waldin.easl/`) older than `ghosttyConfigSettle`: every instance's have been
    /// read, and only the one libghostty replaces is ever deleted by it.
    public static func staleGhosttyConfigs(_ files: [File], now: Date) -> [String] {
        files.filter { file in
            guard file.name.hasPrefix("ghostty-config-"), file.name.hasSuffix(".conf"),
                  UUID(uuidString: String(file.name.dropFirst(15).dropLast(5))) != nil else { return false }
            return now.timeIntervalSince(file.modified) >= ghosttyConfigSettle
        }.map(\.name)
    }

    /// Renders and snapshots easl named itself (`render-<ms>-<n>.png`, `snapshot-…jpg`), and
    /// `easl browser screenshot`'s (`screenshot-<ms>-<pid>.png`), older than `renderAge`; a file
    /// an agent wrote there under another name stays.
    public static func staleRenders(_ files: [File], now: Date) -> [String] {
        files.filter { file in
            let parts = file.name.split(separator: ".")
            guard parts.count == 2, ["png", "jpg"].contains(parts[1]) else { return false }
            let fields = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 3, ["render", "snapshot", "screenshot"].contains(fields[0]),
                  fields.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return false }
            return now.timeIntervalSince(file.modified) >= renderAge
        }.map(\.name)
    }

    /// An easl tile's session name: `canvas-` and an object id (`obj_` and letters or digits).
    static func isCanvasSession(_ name: String) -> Bool {
        guard name.hasPrefix("canvas-obj_") else { return false }
        let id = name.dropFirst(11)
        return !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

import Foundation

/// Only the tabs open when an update starts, separate from normal startup and background attachments.
public struct UpdateBoardSnapshot: Codable, Equatable, Sendable {
    public enum Board: Codable, Hashable, Sendable {
        case local(root: String)
        case remote(RemoteReopen)
    }

    public struct Group: Codable, Equatable, Sendable {
        public var tabs: [Board]
        public var selected: Int
        public var minimized: Bool

        public init(tabs: [Board], selected: Int, minimized: Bool) {
            self.tabs = tabs
            self.selected = selected
            self.minimized = minimized
        }
    }

    public var groups: [Group]
    public var recoveryReason: String?
    private var version = 1

    public init(groups: [Group]) {
        self.groups = groups
    }

    private func validate() throws {
        guard version == 1 else { throw Failure.invalidSnapshot }
        var seen: Set<Board> = []
        for group in groups {
            guard group.tabs.indices.contains(group.selected) else { throw Failure.invalidSnapshot }
            for board in group.tabs {
                guard seen.insert(board).inserted else { throw Failure.invalidSnapshot }
                switch board {
                case .local(let root):
                    guard RemoteHost.isHome(root) else { throw Failure.invalidSnapshot }
                case .remote(let remote):
                    guard !remote.host.isEmpty, RemoteHost.problem(withHost: remote.sshTarget) == nil,
                          ApiRouter.isBoardID(remote.board), remote.home.map(RemoteHost.isHome) ?? true else {
                        throw Failure.invalidSnapshot
                    }
                }
            }
        }
    }

    public enum Failure: LocalizedError {
        case invalidSnapshot

        public var errorDescription: String? { "The saved update board tabs are invalid." }
    }

    public struct Store: Sendable {
        public let url: URL

        public init(url: URL) {
            self.url = url
        }

        /// Missing means normal startup. Damage is reported, not silently treated as no open tabs.
        public func load() throws -> UpdateBoardSnapshot? {
            do {
                let snapshot = try JSONDecoder().decode(UpdateBoardSnapshot.self, from: Data(contentsOf: url))
                try snapshot.validate()
                return snapshot
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            }
        }

        public func save(_ snapshot: UpdateBoardSnapshot) throws {
            try snapshot.validate()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        }

        /// Removing an aborted preparation never removes a retained recovery.
        public func remove() throws {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return
            }
        }

        /// Claim only this launch's prepared tabs before any asynchronous restoration.
        public func retainForRecovery(in directory: URL) throws -> Store? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let recovery = Store(url: directory.appendingPathComponent("\(UUID().uuidString).json"))
            try FileManager.default.moveItem(at: url, to: recovery.url)
            return recovery
        }

        public static func recoveries(in directory: URL) throws -> [Store] {
            do {
                return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .map { Store(url: $0) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return []
            }
        }
    }
}

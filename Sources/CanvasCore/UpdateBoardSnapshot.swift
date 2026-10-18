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

        /// Call only after every saved tab has been restored. A failed reconnect keeps the snapshot for retry.
        public func remove() throws {
            try FileManager.default.removeItem(at: url)
        }
    }
}

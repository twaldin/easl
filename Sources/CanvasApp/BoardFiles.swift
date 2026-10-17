import Foundation
import CanvasCore

/// A board root's files (`git ls-files`: tracked plus untracked files git doesn't ignore), shared
/// by Go to (⌘P) and terminal references that name a file by its name (`core.py:10`). One per
/// root; listed when a board opens, again on every Go to, and when a reference lookup finds the
/// list older than `staleAfter`.
@MainActor
final class BoardFiles {
    private struct Key: Hashable {
        let source: ObjectIdentifier
        let root: URL
    }
    private static var byRoot: [Key: BoardFiles] = [:]

    static func of(_ root: URL, languages: LanguageService = CodeNavigation.languages) -> BoardFiles {
        let root = root.standardizedFileURL
        let key = Key(source: ObjectIdentifier(languages), root: root)
        if let files = byRoot[key] { return files }
        let files = BoardFiles(root: root, languages: languages)
        byRoot[key] = files
        return files
    }

    /// Paths past this are left out (a monorepo's generated trees).
    nonisolated static let maxListed = 200_000
    static let staleAfter: TimeInterval = 30

    let root: URL
    private let languages: LanguageService
    private(set) var index = FileIndex(paths: [])
    private var listedAt: TimeInterval?
    private var listing: Task<Void, Never>?
    private var waiting: [(FileIndex) -> Void] = []

    private init(root: URL, languages: LanguageService) {
        self.root = root
        self.languages = languages
    }

    /// Lists the files again (joining a listing already running) and hands the new index to
    /// `then`.
    func refresh(then: ((FileIndex) -> Void)? = nil) {
        if let then { waiting.append(then) }
        guard listing == nil else { return }
        let root = root
        let languages = languages
        listing = Task { [weak self] in
            let paths = try? await languages.files(boardRoot: root)
            let index = await offPool { FileIndex(paths: Array((paths ?? []).prefix(Self.maxListed))) }
            guard let self else { return }
            self.listing = nil
            self.listedAt = ProcessInfo.processInfo.systemUptime
            // A failed listing (not a repository, git gone) keeps what was listed before.
            if paths != nil { self.index = index }
            let waiting = self.waiting
            self.waiting = []
            for then in waiting { then(self.index) }
        }
    }

    /// The current index, re-listing in the background when it is older than `staleAfter`.
    func current() -> FileIndex {
        if listedAt.map({ ProcessInfo.processInfo.systemUptime - $0 > Self.staleAfter }) ?? true { refresh() }
        return index
    }
}

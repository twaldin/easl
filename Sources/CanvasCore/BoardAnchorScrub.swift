import Foundation

/// Stored anchors are metadata, not edits, and a live board publishes none the board file
/// policy (`BoardAreas`) hasn't allowed. A load checks what needs no git before the board
/// publishes (`prepare`). Anchors only git can check are held back: the board publishes
/// without them, and gets the allowed ones once git has checked them (`check`,
/// `Board.settleAnchors`).
enum BoardAnchorScrub {
    /// The props that carry an anchor or decide whether it is allowed. A held object whose
    /// carriers changed after publishing (an edit) keeps them: git checked the stored ones.
    static let carrierKeys: Set<String> = ["markdown", "root", "path", "range", "ref", "pinnedCommit", "refSha", "anchor"]

    /// What git checks of a held object.
    enum Anchors: Sendable {
        /// A note's fences, at lines of its stored `markdown`.
        case note(markdown: String, fences: [NoteMarkdown.AnchoredFence])
        /// A code tile's `anchor` on the file at `path`.
        case code(path: String)
    }

    /// An object published without stored anchors only git can check.
    struct Held: Sendable {
        var anchors: Anchors
        /// Its carriers as stored, less the anchors refused before publishing.
        var stored: [String: JSONValue]
        /// Its carriers as published.
        var published: [String: JSONValue]
        var resolution: (ref: String, sha: String)?
    }

    /// A stored board with its anchors checked as far as they go without git.
    struct Prepared: Sendable {
        /// The board to publish: refused anchors removed, and those git checks.
        var published: BoardSnapshot
        /// The stored board, refused anchors removed.
        var stored: BoardSnapshot
        /// `stored` differs from the file.
        var changed: Bool
        var held: [ObjectID: Held]
        /// The board's areas; nil when it has no anchors.
        var areas: BoardAreas?
    }

    /// Reads the files and git files a check needs, but runs no git: off the main actor.
    static func prepare(_ snapshot: BoardSnapshot) -> Prepared {
        let root = URL(fileURLWithPath: snapshot.root)
        var prepared = Prepared(published: snapshot, stored: snapshot, changed: false, held: [:], areas: nil)
        for (index, object) in snapshot.objects.enumerated() {
            guard let props = object.props.object else { continue }
            var stored = props, published = props
            var anchors: Anchors?
            switch object.type {
            case .note:
                guard let markdown = props["markdown"]?.string else { continue }
                let fences = NoteMarkdown.anchoredFences(in: NoteMarkdown.parse(markdown)).filter {
                    NoteFence.tokens($0.key).contains { $0.hasPrefix("anchor=") }
                }
                guard !fences.isEmpty else { continue }
                let areas = prepared.areas ?? BoardAreas(boardRoot: root)
                prepared.areas = areas
                // A `ref` is resolved by git: every fence waits for it.
                var held = fences, refused: [Int] = []
                if RefSource.ref(of: object.props) == nil {
                    let reading = LinkReading.unreferenced(props: object.props, boardRoot: root)
                    held = []
                    for fence in reading.fences(fences) {
                        switch verdict(on: fence.fence, root: reading.root, areas: areas) {
                        case .refused: refused += fence.lines
                        case .allowed: break
                        case .git: held.append(fence)
                        }
                    }
                }
                let kept = NoteMarkdown.removingAnchors(markdown, fenceLines: refused)
                stored["markdown"] = .string(kept)
                published["markdown"] = .string(NoteMarkdown.removingAnchors(kept, fenceLines: held.flatMap(\.lines)))
                if !held.isEmpty { anchors = .note(markdown: kept, fences: held) }
            case .code:
                guard let anchor = props["anchor"], anchor != .null, let path = props["path"]?.string else { continue }
                let areas = prepared.areas ?? BoardAreas(boardRoot: root)
                prepared.areas = areas
                if RefSource.ref(of: object.props) != nil {
                    anchors = .code(path: path)
                } else {
                    switch verdict(on: codeFence(path, props: object.props, reading: LinkReading(root: root)), root: root, areas: areas) {
                    case .refused: stored.removeValue(forKey: "anchor")
                    case .allowed: break
                    case .git: anchors = .code(path: path)
                    }
                }
                published = stored
                if anchors != nil { published.removeValue(forKey: "anchor") }
            default:
                continue
            }
            if stored != props {
                prepared.stored.objects[index].props = .object(stored)
                prepared.changed = true
            }
            if published != props { prepared.published.objects[index].props = .object(published) }
            if let anchors { prepared.held[object.id] = Held(anchors: anchors, stored: carriers(of: .object(stored)), published: carriers(of: .object(published))) }
        }
        return prepared
    }

    /// Each held object's carriers as stored, less the anchors git refuses.
    static func check(_ held: [ObjectID: Held], boardRoot: URL, areas: BoardAreas) async -> [ObjectID: [String: JSONValue]] {
        var checked: [ObjectID: [String: JSONValue]] = [:]
        for (id, object) in held.sorted(by: { $0.key < $1.key }) {
            var carriers = object.stored
            let props = JSONValue.object(object.stored)
            switch object.anchors {
            case .note(let markdown, let fences):
                let reading = await LinkReading.resolve(props: props, boardRoot: boardRoot)
                var lines: [Int] = []
                for fence in reading.fences(fences) {
                    if await refused(fence.fence, root: reading.root, areas: areas) { lines += fence.lines }
                }
                carriers["markdown"] = .string(NoteMarkdown.removingAnchors(markdown, fenceLines: lines))
            case .code(let path):
                let reading: LinkReading
                if RefSource.ref(of: props) != nil {
                    reading = await LinkReading.resolve(props: props, boardRoot: boardRoot)
                } else {
                    reading = LinkReading(root: boardRoot)
                }
                if await refused(codeFence(path, props: props, reading: reading), root: reading.root, areas: areas) { carriers.removeValue(forKey: "anchor") }
            }
            checked[id] = carriers
        }
        return checked
    }

    /// `snapshot` (a held board's) with each held object whose carriers are as published given
    /// its stored ones back, so a save while git checks drops no anchor git may allow.
    static func keepStored(_ held: [ObjectID: Held], in snapshot: inout BoardSnapshot) {
        for index in snapshot.objects.indices {
            guard let object = held[snapshot.objects[index].id], carriers(of: snapshot.objects[index].props) == object.published else { continue }
            snapshot.objects[index].props = replacingCarriers(of: snapshot.objects[index].props, with: object.stored)
        }
    }

    /// The stored board `stored` with the held objects' carriers as git checked them (`check`).
    static func settled(_ stored: BoardSnapshot, _ checked: [ObjectID: [String: JSONValue]]) -> BoardSnapshot {
        var settled = stored
        for index in settled.objects.indices {
            guard let carriers = checked[settled.objects[index].id] else { continue }
            settled.objects[index].props = replacingCarriers(of: settled.objects[index].props, with: carriers)
        }
        return settled
    }

    static func carriers(of props: JSONValue) -> [String: JSONValue] {
        props.object?.filter { carrierKeys.contains($0.key) } ?? [:]
    }

    private static func replacingCarriers(of props: JSONValue, with carriers: [String: JSONValue]) -> JSONValue {
        guard var fields = props.object else { return props }
        for key in carrierKeys { fields[key] = carriers[key] }
        return .object(fields)
    }

    static func restoring(_ object: CanvasObject, held: Held, carriers: [String: JSONValue]) -> CanvasObject {
        guard Self.carriers(of: object.props) == held.published else { return object }
        var restored = object
        restored.props = replacingCarriers(of: object.props, with: carriers)
        return restored
    }

    /// The fence a code tile's anchor is read from, as `reading` reads it.
    private static func codeFence(_ path: String, props: JSONValue, reading: LinkReading) -> NoteFence {
        var fence = NoteFence(path: path, commit: props["pinnedCommit"]?.string.flatMap { $0.isEmpty ? nil : $0 })
        if let source = reading.ref { fence = source.fence(fence) } else if fence.commit == nil { fence.commit = reading.commit }
        return fence
    }

    /// The board file policy on an anchor of `fence` read under `root`, as far as it goes
    /// without git.
    private enum Verdict {
        case refused, allowed
        /// Git tells: whether the file at `path` is a regular file at the fence's commit.
        case git(path: String)
    }

    private static func verdict(on fence: NoteFence, root: URL, areas: BoardAreas) -> Verdict {
        guard areas.permits(root: root) else { return .refused }
        guard let path = fence.path else { return .allowed }
        guard areas.written(Board.hostPath(path, under: root.path)) != nil else { return .refused }
        do {
            switch try areas.preauthorize(path, commit: fence.commit, root: root) {
            case .live(let real):
                close(try BoardAreas.openNoFollow(real))
                return .allowed
            case .committed:
                return .git(path: path)
            }
        } catch NoteSourceError.refused {
            return .refused
        } catch {
            return .allowed
        }
    }

    private static func refused(_ fence: NoteFence, root: URL, areas: BoardAreas) async -> Bool {
        let verdict = await offPool { Self.verdict(on: fence, root: root, areas: areas) }
        switch verdict {
        case .refused:
            return true
        case .allowed:
            return false
        case .git(let path):
            do {
                _ = try await areas.authorize(path, commit: fence.commit, root: root)
                return false
            } catch NoteSourceError.refused {
                return true
            } catch {
                return false
            }
        }
    }
}

extension Board {
    /// The load published object `id` without stored anchors git has yet to check
    /// (`BoardAnchorScrub`): nothing anchors it meanwhile, a missing anchor isn't one to add.
    public func isAnchorScrubPending(_ id: ObjectID) -> Bool {
        heldAnchors[id] != nil
    }

    /// Returns once git has checked the anchors the load held back, the board has the allowed
    /// ones, and the store has written what it writes for them.
    public func waitForAnchorScrub() async {
        await anchorScrub?.value
    }

    /// Ends the load's hold: each held object whose carriers are as published gets them as git
    /// checked them (`checked`). Bookkeeping, and no save: the store writes what it must.
    func settleAnchors(_ checked: [ObjectID: [String: JSONValue]]) {
        let held = heldAnchors
        heldAnchors = [:]
        func restore(_ object: CanvasObject) -> CanvasObject {
            guard let hold = held[object.id], let carriers = checked[object.id] else { return object }
            return BoardAnchorScrub.restoring(object, held: hold, carriers: carriers)
        }
        history.rewriteObjects(restore)
        viewerHistories.rewriteObjects(restore)
        for (id, carriers) in checked.sorted(by: { $0.key < $1.key }) {
            guard let live = objects[id], let published = held[id]?.published, BoardAnchorScrub.carriers(of: live.props) == published else { continue }
            let patch = BoardAnchorScrub.carrierKeys.map { ($0, carriers[$0] ?? .null) }
            commitBookkeeping(live, props: .object(Dictionary(uniqueKeysWithValues: patch)), persisting: false)
        }
        for (id, hold) in held {
            guard let resolution = hold.resolution else { continue }
            recordRefSha(id, ref: resolution.ref, sha: resolution.sha)
        }
    }
}

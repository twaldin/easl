import Foundation

/// A changes tile comparing two commits (`ChangesSpec.head`, or a `ref` no worktree has checked
/// out): everything git objects say, no working tree, index, or checkout involved, and nothing
/// run that could reach the network.
extension ChangeSet {
    /// The files as `head` has them against its merge-base with the base (`git diff
    /// base...head`, a pull request's view: commits the base gained since don't show as
    /// reversed), under `spec.paths`; `headName` is how the header names the head. `merge-base`
    /// is the default branch; `HEAD` with a `ref` is the ref itself (nothing to show: no
    /// worktree has uncommitted work on it). A ref `gone` and merged compares with the merge's
    /// first parent once the base holds it. A ref the repository lacks says how to fetch it.
    static func loadCommits(root: URL, spec: ChangesSpec, head: String, headName: String, gone: Gone? = nil, highlight: Bool) async -> ChangeSet {
        let reviewed = spec.directory(boardRoot: root)
        if let prop = spec.root, !GitWorktree.sameRepository(reviewed.path, root.path) {
            return ChangeSet(notice: "\(prop) is not a worktree of this board's repository", branch: headName)
        }
        let directory = GitDiffEngine.existingAncestor(of: reviewed)
        guard let top = try? await GitRunner.shared.run(["rev-parse", "--path-format=absolute", "--show-toplevel"], in: directory) else {
            return ChangeSet(notice: "not in a git repository", branch: headName)
        }
        let toplevel = URL(fileURLWithPath: String(decoding: top, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let specs: [String]
        do {
            specs = try pathspecs(spec.paths, root: reviewed, toplevel: toplevel)
        } catch {
            return ChangeSet(repository: toplevel, notice: error.message, branch: headName)
        }
        func refused(_ notice: String, label: String = spec.baseProp) -> ChangeSet {
            ChangeSet(repository: toplevel, baseLabel: label, notice: notice, branch: headName)
        }

        let headSHA: String
        switch await commit(head, in: toplevel) {
        case .success(let sha?): headSHA = sha
        case .success(nil): return refused(await missing(headName, in: toplevel))
        case .failure(let failure): return refused(failure.message)
        }
        var label = spec.baseProp
        var tip: String
        switch spec.base {
        case .mergeBase:
            guard let branch = try? await GitDiffEngine.defaultBranch(in: toplevel) else { return refused("no default branch") }
            let name = branch.replacingOccurrences(of: "refs/remotes/", with: "").replacingOccurrences(of: "refs/heads/", with: "")
            label = GitDiffEngine.ResolvedBase.mergeBasePrefix + name
            switch await commit(branch, in: toplevel) {
            case .success(let sha?): tip = sha
            case .success(nil): return refused("no default branch", label: label)
            case .failure(let failure): return refused(failure.message, label: label)
            }
        case .head where spec.head == nil:
            tip = headSHA
        default:
            switch await commit(spec.baseProp, in: toplevel) {
            case .success(let sha?): tip = sha
            case .success(nil): return refused(await missing(spec.baseProp, in: toplevel))
            case .failure(let failure): return refused(failure.message)
            }
        }
        func mergeBase(_ tip: String) async throws -> String {
            // Exit 1: the histories share no commit.
            let data = try await GitRunner.shared.run(["merge-base", tip, headSHA], in: toplevel, allowedStatus: [0, 1])
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var base: String
        do {
            base = try await mergeBase(tip)
            // Merged: the base holds the head now, and the branch's work is what its merge added.
            if case .merged(let merge)? = gone, base == headSHA, merge != headSHA, case .success(let parent?) = await commit(merge + "^1", in: toplevel) {
                tip = parent
                base = try await mergeBase(parent)
            }
        } catch {
            return refused("git failed: \(ChangesFailure.describe(error))", label: label)
        }
        guard !base.isEmpty else { return refused("\(headName) shares no history with \(ChangeSet(baseLabel: label).baseName)", label: label) }
        let commits = Commits(baseTip: tip, gone: gone)
        func listing(_ files: [ChangedFile] = [], omitted: Int = 0, notice: String? = nil) -> ChangeSet {
            ChangeSet(repository: toplevel, base: base, baseLabel: label, files: files, notice: notice, omitted: omitted, head: headSHA, branch: headName, commits: commits)
        }

        let raw: Data
        do {
            raw = try await GitRunner.shared.run(["--literal-pathspecs", "diff", "--raw", "-z", "-M", "--no-abbrev", "--no-color", "--no-ext-diff", "--no-textconv", base, headSHA, "--"] + specs,
                                                 in: toplevel)
        } catch {
            return listing(notice: "git failed: \(ChangesFailure.describe(error))")
        }
        let entries = parseRaw(raw).sorted { $0.path < $1.path }
        let omitted = max(0, entries.count - maxFiles)
        let selected = Array(entries.prefix(maxFiles))
        guard !selected.isEmpty else { return listing() }

        let blobs = await Self.blobs(selected.flatMap { entry in
            [(entry.oldBlob, entry.oldMode), (entry.newBlob, entry.newMode)].compactMap { blob, mode in mode == gitlinkMode ? nil : blob }
        }, in: toplevel)
        // One -U0 diff for the files at the same path on both sides; a renamed file's two blobs
        // are diffed on their own.
        let samePath = selected.filter { $0.status == .modified && $0.oldBlob != $0.newBlob }.map(\.path)
        var changes: [String: [LineRangeMapping]] = [:]
        if !samePath.isEmpty, let output = try? await GitRunner.shared.run(GitDiffEngine.changeRecords + [base, headSHA, "--"] + samePath, in: toplevel, maxOutput: 64 << 20) {
            changes = await offPool { GitDiffEngine.split(output).mapValues { UnifiedDiff.parse($0).mappings } }
        }
        var files: [ChangedFile] = []
        for entry in selected {
            var mappings = changes[entry.path]
            if mappings == nil, entry.status == .renamed, let old = entry.oldBlob, let new = entry.newBlob, old != new,
               let patch = try? await GitRunner.shared.run(GitDiffEngine.changeRecords + [old, new], in: toplevel, maxOutput: 3 * GitDiffEngine.maxFileSize) {
                mappings = await offPool { UnifiedDiff.parse(patch).mappings }
            }
            let known = mappings
            files.append(await offPool { file(entry, blobs: blobs, mappings: known) { Board.relativePath(toplevel.appendingPathComponent($0).path, root: root) } })
        }
        let set = listing(files, omitted: omitted)
        return highlight ? await offPool { set.highlighted() } : set
    }

    static let gitlinkMode = "160000"

    /// One side of a file as git objects have it: its text, or why there is none to show.
    enum Blob: Sendable {
        case text(SideText)
        case binary
        case tooLarge
    }

    /// The blobs `ids` name (at most `GitDiffEngine.maxFileSize` each), by id, read with two
    /// `git cat-file` runs: their sizes, then the ones small enough. A blob the repository lacks
    /// is left out.
    static func blobs(_ ids: [String], in toplevel: URL) async -> [String: Blob] {
        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty else { return [:] }
        let input = Data(unique.map { $0 + "\n" }.joined().utf8)
        guard let checked = try? await GitRunner.shared.run(["cat-file", "--batch-check"], in: toplevel, input: input) else { return [:] }
        var result: [String: Blob] = [:]
        var wanted: [String] = []
        var total = 0
        for line in String(decoding: checked, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 3, fields[1] == "blob", let size = Int(fields[2]) else { continue }
            if size > GitDiffEngine.maxFileSize {
                result[String(fields[0])] = .tooLarge
            } else {
                wanted.append(String(fields[0]))
                total += size
            }
        }
        guard !wanted.isEmpty,
              let output = try? await GitRunner.shared.run(["cat-file", "--batch"], in: toplevel, input: Data(wanted.map { $0 + "\n" }.joined().utf8),
                                                           maxOutput: total + 128 * wanted.count) else { return result }
        let sized = result
        return await offPool {
            var blobs = sized
            for (id, data) in parseBatch(output) {
                blobs[id] = data.prefix(8000).contains(0) ? .binary : .text(SideText(String(decoding: data, as: UTF8.self)))
            }
            return blobs
        }
    }

    /// `git cat-file --batch` output: `<id> <type> <size>\n<content>\n` per object (`<id>
    /// missing\n` for one it lacks).
    static func parseBatch(_ output: Data) -> [(String, Data)] {
        let bytes = [UInt8](output)
        var objects: [(String, Data)] = []
        var index = 0
        while index < bytes.count {
            guard let end = bytes[index...].firstIndex(of: 0x0A) else { break }
            let header = String(decoding: bytes[index..<end], as: UTF8.self).split(separator: " ")
            index = end + 1
            guard header.count == 3, let size = Int(header[2]), index + size <= bytes.count else { continue }
            objects.append((String(header[0]), Data(bytes[index..<(index + size)])))
            index += size + 1
        }
        return objects
    }

    /// A changed file between two commits: its sides' texts from `blobs`, its hunks from
    /// `mappings` (a -U0 diff; none: the file is new or gone, or its content didn't change),
    /// every hunk `committed`, and nothing of it actionable (`ChangedFile.readOnly`).
    static func file(_ entry: Entry, blobs: [String: Blob], mappings: [LineRangeMapping]?, boardPath: (String) -> String) -> ChangedFile {
        func side(_ id: String?) -> Blob? { id.map { blobs[$0] ?? .tooLarge } }
        let oldSide = side(entry.oldBlob), newSide = side(entry.newBlob)
        var old = SideText(""), new = SideText("")
        if case .text(let text)? = oldSide { old = text }
        if case .text(let text)? = newSide { new = text }
        var notice: String?
        var changes: [LineRangeMapping] = []
        if entry.oldMode == gitlinkMode || entry.newMode == gitlinkMode {
            notice = "submodule"
        } else if case .tooLarge? = oldSide {
            notice = "too large to show"
        } else if case .tooLarge? = newSide {
            notice = "too large to show"
        } else if case .binary? = oldSide {
            notice = "binary file"
        } else if case .binary? = newSide {
            notice = "binary file"
        } else {
            switch entry.status {
            case .added: changes = LineRangeMapping.whole(new)
            case .deleted: changes = LineRangeMapping.whole(old, removed: true)
            case .modified, .renamed:
                changes = mappings ?? []
                if changes.isEmpty, entry.status == .modified { notice = "mode changed" }
            }
        }
        var ids: Set<String> = []
        let hunks = UnifiedDiff.hunks(changes).map { hunk -> ChangeHunk in
            var change = ChangeHunk(mappings: hunk.mappings, old: old, new: new, status: .committed)
            let id = ChangeHunk.identity(path: entry.path, unified: change.unified(old: old, new: new))
            var unique = id, count = 1
            while ids.contains(unique) {
                count += 1
                unique = "\(id)-\(count)"
            }
            ids.insert(unique)
            change.id = unique
            return change
        }
        return ChangedFile(path: entry.path, oldPath: entry.oldPath, boardPath: boardPath(entry.path), oldBoardPath: entry.oldPath.map(boardPath),
                           status: entry.status, old: old, new: new, oldMode: entry.oldMode, newMode: entry.newMode, tracked: true, hunks: hunks, notice: notice,
                           blobs: ChangedFile.Blobs(old: entry.oldBlob, new: entry.newBlob))
    }

    /// The commit `revision` names in the repository: nil when it names none (git exits 1).
    static func commit(_ revision: String, in toplevel: URL) async -> Result<String?, ChangesFailure> {
        do {
            let data = try await GitRunner.shared.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(revision)^{commit}"], in: toplevel, allowedStatus: [0, 1])
            let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(sha.isEmpty ? nil : sha)
        } catch {
            return .failure(ChangesFailure("git failed: \(ChangesFailure.describe(error))"))
        }
    }

    /// What a tile says of a ref the repository doesn't have: the exact fetch that brings it
    /// (`fetchCommand`). easl itself never fetches.
    static func missing(_ ref: String, in toplevel: URL) async -> String {
        let remotes = (try? await GitRunner.shared.run(["remote"], in: toplevel)).map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init) } ?? []
        return "no commit \(ref) here; fetch it: \(fetchCommand(for: ref, remotes: remotes))"
    }

    /// The `git fetch` after which `ref` names a commit here: a pull request's head
    /// (`pull/N/head`) into `refs/pull/N/head`; `<remote>/<branch>` from that remote; a commit
    /// id as it is; any other name as a local branch of that name, from `origin` (else the first
    /// remote).
    public static func fetchCommand(for ref: String, remotes: [String]) -> String {
        let remote = remotes.contains("origin") ? "origin" : remotes.first ?? "origin"
        if ref.hasPrefix("pull/") || ref.hasPrefix("refs/pull/") {
            let name = ref.hasPrefix("refs/") ? String(ref.dropFirst("refs/".count)) : ref
            return "git fetch \(remote) \(name):refs/\(name)"
        }
        if ref.hasPrefix("refs/heads/") {
            let branch = ref.dropFirst("refs/heads/".count)
            return "git fetch \(remote) \(branch):refs/heads/\(branch)"
        }
        let tracking = ref.hasPrefix("refs/remotes/") ? String(ref.dropFirst("refs/remotes/".count)) : ref
        if let slash = tracking.firstIndex(of: "/"), remotes.contains(String(tracking[..<slash])) {
            return "git fetch \(tracking[..<slash]) \(tracking[tracking.index(after: slash)...])"
        }
        if (7...40).contains(ref.count), ref.allSatisfy(\.isHexDigit) { return "git fetch \(remote) \(ref)" }
        return "git fetch \(remote) \(ref):refs/heads/\(ref)"
    }
}

extension ChangesFailure {
    /// Why git couldn't answer, in a few words for a header.
    static func describe(_ error: Error) -> String {
        switch error {
        case let failure as ChangesFailure: failure.message
        case is CancellationError: "cancelled"
        case GitError.timedOut: "timed out"
        case GitError.outputTooLarge: "too much output"
        case GitError.launch(let reason): reason
        case GitError.failed(let status, let stderr): stderr.split(separator: "\n").first.map(String.init) ?? "exit \(status)"
        default: "\(error)"
        }
    }
}

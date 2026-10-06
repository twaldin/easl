import Foundation

/// Link roots: the directory a note's or HTML tile's relative paths resolve against (`path:line`
/// links, markdown links, excerpt fences and images in a note; `<canvas-link>`, `<canvas-code>`
/// and `<img>` in a page). `props.root`, absolute or board-relative, like a changes tile's: the
/// board's own checkout or another worktree of its repository (`checkLinkRoot`); none, the board
/// root. An agent working in another worktree than the board's gets its own checkout as the
/// default (`callerCheckout`, `inCallersCheckout`), so it writes `tests/x.ts:16`, not `../wt-x/tests/x.ts:16`.
extension Board {
    public func linkRoot(of object: CanvasObject) -> URL { linkRoot(props: object.props) }

    /// With a `ref`, the board root's place in the worktree that has it checked out, else the
    /// board root (whose repository holds the ref's objects; `linkSource` reads them).
    public func linkRoot(props: JSONValue) -> URL {
        if let ref = RefSource.ref(of: props) { return RefSource.liveRoot(ref: ref, boardRoot: root) ?? root }
        guard let value = props["root"]?.string, !value.isEmpty else { return root }
        return absoluteURL(value).standardizedFileURL
    }

    /// A note or HTML tile's `root` must be an existing directory in the board's checkout or in
    /// another worktree of its repository (inside the board root when the board isn't in git).
    public func checkLinkRoot(_ value: String) throws {
        let url = absoluteURL(value).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BoardError.invalidParams("root \(value) is not a directory")
        }
        if GitWorktree.containing(root.path) != nil {
            guard GitWorktree.sameRepository(url.path, root.path) else {
                throw BoardError.invalidParams("root \(value) is not in this board's repository or one of its worktrees")
            }
        } else {
            let base = root.standardizedFileURL.path
            guard url.path == base || url.path.hasPrefix(base + "/") else { throw BoardError.invalidParams("root \(value) is outside the board root") }
        }
    }

    /// The directory a terminal works in: its program's or shell's as the app last read it
    /// (`terminalWorks(_:in:)`), else `props.cwd`, else the board root.
    public func workingDirectory(of terminal: ObjectID) -> String {
        workingDirectories[terminal] ?? objects[terminal]?.props["cwd"]?.string ?? root.path
    }

    /// The checkout `caller` (an agent's terminal) works in, when that is another worktree of
    /// the board's repository: at the board root's place in it (a board rooted at `packages/app`
    /// maps to `packages/app` of the worktree). Nil when the caller works in the board's own
    /// checkout, or outside it. What the caller's relative paths mean (`inCallersCheckout`).
    public func callerCheckout(for caller: ObjectID?) -> String? {
        guard let caller, objects[caller]?.type == .terminal else { return nil }
        return GitWorktree.counterpart(of: root.path, toward: workingDirectory(of: caller))
    }

    /// The board root, or its counterpart in the other worktree of the board's repository that
    /// `path` (board-relative or absolute) lies in: the project a file in that worktree is read
    /// in (language servers, call graphs).
    public func checkoutRoot(of path: String) -> URL {
        GitWorktree.counterpart(of: root.path, toward: absoluteURL(path).path).map(URL.init(fileURLWithPath:)) ?? root
    }

    /// The props of a tile `caller` creates, or (`existing`: the tile's props) re-aims, with its
    /// relative paths meaning the caller's checkout when it works in another worktree of the
    /// board's repository (`callerCheckout`), as for a note's links: a code, image or diagram
    /// tile's relative `path` becomes absolute there (not a code tile's that reads a `ref` or
    /// `pinnedCommit`), as does a question's relative `context` path, and a changes tile created
    /// without `root`, `ref` or `head`, or a note or HTML tile created without `root`, gets that
    /// checkout as its `root`. From the board's own checkout, or without a caller, the props are
    /// as given.
    public func inCallersCheckout(_ props: JSONValue, type: ObjectType, caller: ObjectID?, existing: JSONValue? = nil) -> JSONValue {
        guard var fields = props.object, let checkout = callerCheckout(for: caller) else { return props }
        let merged = (existing ?? .object([:])).merging(props)
        switch type {
        case .code, .image, .diagram:
            guard let path = fields["path"]?.string, !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { break }
            if type == .code, merged["ref"]?.string?.isEmpty == false || merged["pinnedCommit"]?.string?.isEmpty == false { break }
            fields["path"] = .string(URL(fileURLWithPath: checkout).appendingPathComponent(path).standardizedFileURL.path)
        case .changes, .note, .html:
            guard existing == nil, fields["root"]?.string?.isEmpty != false else { break }
            if type == .changes, fields["ref"]?.string?.isEmpty == false || fields["head"]?.string?.isEmpty == false { break }
            fields["root"] = .string(checkout)
        case .question:
            guard let items = fields["context"]?.array else { break }
            fields["context"] = .array(items.map { item in
                guard var context = item.object, let path = context["path"]?.string, !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return item }
                context["path"] = .string(URL(fileURLWithPath: checkout).appendingPathComponent(path).standardizedFileURL.path)
                return .object(context)
            })
        default: break
        }
        return .object(fields)
    }

    /// `path` (as written in a note or page, or absolute) as the API stores file paths: relative
    /// to the board root when it lies under it, else absolute.
    public func boardPath(_ path: String, linkRoot: URL) -> String {
        relativePath(path.hasPrefix("/") ? path : linkRoot.appendingPathComponent(path).path)
    }
}

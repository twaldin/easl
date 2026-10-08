# One board per repository

A git repository gets one board, whatever worktree or branch it is opened from. Worktrees and branches are attributes of that board, not boards of their own: worktrees are ephemeral (deleted after merge), the board isn't.

## Identity

- **Board id**: `brd_` + the first 20 hex digits of SHA-256 of the repository's **common git directory** (what `git rev-parse --git-common-dir` names; every worktree of a repository shares it), normalized as `GitWorktree` finds it: absolute, symlinks resolved. It is read from the filesystem (`.git` directory, or a linked worktree's `.git` file → `commondir`), so opening a board starts no git process.
- **Non-git directories** keep their old identity: SHA-256 of the standardized directory path. Their board files are never touched until the directory becomes part of a repository; then that repository's board takes the board in (Migration).
- Worktree paths the board records and reports are normalized the same way (`GitWorktree.normalized`), so `/tmp/wt` and git's `/private/tmp/wt` are one worktree.
- Before this change the identity was `<common dir>\n<branch>` (or `<common dir>\n<worktree top level>` on a detached HEAD), so every branch and every detached worktree had its own board. Those files are *legacy boards*; the migration below folds them into their repository's board.

## Canonical root

A repository board has one root, whichever worktree opened it:

1. The directory being opened, when it is its repository's main checkout (its git dir *is* the common dir; this covers submodules, whose common dir is `.git/modules/<name>`).
2. Otherwise the main checkout: the common dir's parent when the common dir is a `.git` directory that parent owns.
3. Otherwise (a bare repository with linked worktrees, e.g. `proj/.bare`) the common dir's parent.

Opening a subdirectory of a repository opens the repository's board at its canonical root: root-relative paths are always relative to the top of the main checkout. `EASL_BOARD_ROOT` is that root.

## Worktrees and branches as attributes

The snapshot gains `repo`:

```json
"repo": {
  "commonDir": "/Users/tim/lindy/.git",
  "worktrees": [{ "path": "/Users/tim/worktrees/lindy/slice-a", "branch": "fm/slice-a", "region": "obj_…" }],
  "merged": ["brd_<legacy id>", …]
}
```

- `worktrees` records every worktree the board has seen: ones it was opened from, ones a terminal tile worked in, and the roots of the legacy boards merged into it. `branch` is the branch last seen checked out there (absent on a detached HEAD); `region` is the group holding what a merged legacy board held.
- `board.list` reports each repository board's `repo` and its `worktrees`: the recorded ones and every live worktree of the repository (from `<common>/worktrees/*/gitdir`), each with `path`, `branch` (live `HEAD` when the worktree exists, else as recorded), `live` (the directory still is a worktree of this repository), `main` (it's the canonical root) and `region` when there is one.
- `board.open --root <worktree>` answers the repository board, plus `worktree: {path, branch, region?}` for the worktree it was opened from. Opening a worktree directory from anywhere (`board.open`, `open -n easl.app --args <worktree>`, the Open Board panel, a saved tab) lands on the repository board; the window's subtitle names the worktree and branch, and when the worktree has a region the view scrolls to it.
- The worktree a board was last opened from is the board's **working worktree** (in memory, not saved). Its checkout, at the canonical root's place in it (`Board.workingRoot`), is what the user works in: New Terminal starts there, Go to (⌘P) lists its files and symbols (a file row opens that worktree's copy), Review Changes reviews it when no terminal says otherwise, and a diagram with nothing else to go by is of it.
- Reading code follows the checkout a file lies in, not the canonical root: a worktree's file is read by a language server rooted in that worktree's project (its own build index), and a diagram of it is computed in that worktree.
- An agent working in a linked worktree writes paths relative to its own checkout: its code, image and diagram tiles' relative paths are stored absolute in that worktree, and its notes, HTML and changes tiles get that worktree as `root` (`Board.inCallersCheckout`; docs/contracts.md "Link roots").
- **Terminal tiles** record the checkout they work in: `props.worktree` (the worktree's top level) and `props.branch` (absent on a detached HEAD), stamped when the tile is created with a `cwd` in the board's repository and kept current as it works elsewhere (`Board.terminalWorks`): the app reads the directory of the terminal's foreground program, else of its shell, from the process table as a program starts and at each prompt, so after `cd ../wt && codex` the terminal and its agent are `wt`'s. A directory outside the repository leaves them as they were. Written as bookkeeping: no rev, undo step or log.

## Per-object `root` and `ref` after the merge

Object paths stay relative to the board root when they lie under it (the canonical root), else absolute; `root` on notes, HTML and changes tiles keeps its meaning (another worktree of the board's repository). Branch-anchored tiles use FeatRef's `ref` (`GitRefs.resolve(repo:ref:lastKnownSha:)`): a tile with `ref: "B"` reads the worktree that has `B` checked out (live), else git objects at `B` (read-only), else its last resolved `refSha`, and says "merged in <sha>" once `B` is merged or deleted. A relative path with `ref` means `<B's worktree or commit>/<the root's place in the repository>/<path>`; `pinnedCommit` on a code tile wins over `ref`; `ref` wins over `root` on notes and HTML.

This is what makes the merge durable: a tile from a branch's worktree is anchored to the branch, so it keeps working after that worktree is deleted.

## Per-branch filter

`board.get --branch B` answers the part of the board that belongs to branch `B`: the objects of every region keyed `branch:B` (members, recursively), objects whose `ref` is `B`, terminal tiles whose `branch` is `B`, and arrows whose two ends are among those. The layout is unchanged; it is a query, not a layer. (A visual layer that dims other branches is left for later.)

## Migration

**When**: at launch, before any board opens (`BoardStore.migrateToRepoBoards`, given the saved tabs and the initial root as repositories to try), and again for one repository when its board first loads in a session (`BoardStore.mergeIntoRepositoryBoard`). That second run takes in legacy boards that couldn't be placed at launch (their repository wasn't known then), when the repository board isn't stored yet, and, stored or not, the boards of directories in the repository that were made before those directories were in git: a folder's board, then `git init` and a commit. **A folder that becomes a repository keeps its board**: its objects become the repository board's, placed as they were when that board is empty. Finding those boards reads the store's board files once a session and looks for `.git` above each path-keyed board's directory; it starts no git process. A board loaded earlier in the same session (still open, so its next save would write its file back) waits for the next launch. Each run writes its report to `boards/pre-repo-migration/migration.json` (below). Later launches only look at the legacy boards the last report left unresolved and at path-keyed boards. One-time and idempotent: a legacy file is merged once, then moved to the backup directory; a repository board lists the legacy ids it merged (`repo.merged`) and a legacy board already listed there is only backed up again, never merged twice.

**easld** has no launch migration. When it loads a repository board (`Registry.load` → `store.Loading`) it takes in path-keyed boards the same way, appending its run to the same report (carrying the last run's unresolved legacy boards forward), and its `Restore` reopens a listed folder board as the repository board that took it in. The owned terminals' running sessions, still labelled with the folder board's id, stay the repository board's (docs/contracts.md "Owned terminals", Merged boards). On a store the app hasn't migrated yet (a legacy per-branch board and no `migration.json`) it takes in nothing: a report it wrote would tell the app that its launch migration had run.

**Classifying a stored board** (files without `repo`):

- Its id is the SHA-256 of its root path and that root is gone or outside git: a non-git board. Unchanged.
- Its id is the SHA-256 of its root path but the root is in a repository: the old store fell back to the path when git named no branch (a repository without a commit yet), or the directory has become a repository (or part of one) since its board was made, so it is that directory's legacy board (`path`), placed as the main checkout's when it is in it.
- Otherwise a legacy git board. Its repository and branch are found by recomputing legacy ids: for a candidate common dir `C` (as git printed it, symlinks resolved, and as `GitWorktree` finds it), the id is one of `C\n<branch>` over the repository's local branches (`refs/heads/**` and `packed-refs`, also as `heads/<branch>` for names git would print ambiguously) or `C\n<top level>` over the root and its parents (detached HEAD). Candidate common dirs: the repository containing the board's root when it still exists, else every repository known at launch (the roots of live stored boards and of the saved open tabs), else, later, the repository whose board is being loaded.
- A board whose root still lies in a repository but matches none of its branches (its branch was deleted) is merged under its worktree's directory name, branch unknown.
- A board whose root is gone and which matches no known repository stays as it is (listed as archived) and is recorded as unresolved.

**Merging a repository's legacy boards**:

1. Target: the repository board if one exists, else a new one at the canonical root.
2. The *base* legacy board is the one whose root is in the main checkout and whose branch is the one checked out there (or the main checkout's path-keyed board); none when there is no such board or the repository board already has objects. It is placed as it was, unwrapped: the board the user knew as "the repo's board" doesn't move. A legacy board of a branch the main checkout no longer has checked out is a region like any other branch's.
3. Every other legacy board becomes a **region**: a group titled with its branch (the worktree's directory name when detached or unknown), `props.key: "branch:<name>"` (`detached:<worktree name>` on a detached HEAD, `worktree:<worktree name>` when the branch is unknown), whose members are the board's top-level objects (objects not inside another of its groups). The whole board is offset right of everything placed so far, top-aligned with it, 200 pt apart, so nothing overlaps. Point-bound arrow ends move with it; ink points are object-local and don't.
4. Object ids, arrows, groups (nested), object `parent`s, `followOf` links, z order (each board's objects keep their order, stacked above the previous board's), the selection tray, attention markers, agents' last answers and turn errors, lifecycle sequence numbers, the prompt target's focus order, terminals' old names (`aliases`, the repository board's own winning a clash) and peer messages not yet taken (`messages`, queued after the repository board's own, their mentions re-rooted as the tray's) all carry over; `revision` is the largest of the boards'. Undo history is in memory only and isn't affected. A legacy board already listed in `repo.merged` (a run interrupted between writing the target and moving the file) is only backed up (`alreadyMerged`); one that isn't listed but brings an object id the target already has is left unmerged and reported (`conflict`). A run that merges and backs up nothing (only conflicts) leaves the target as it was.
5. **Keys** (`props.key`, unique per board): when two merged boards (or the repository board and a merged one) hold one key, the object from the board file saved last keeps it and every other holder's becomes `<key>@<its board's branch>` (`<key>@repo` for an object already on the repository board; `-2`, `-3`… when that is taken too). Every rename is in the report (`keyRenames`).
6. **Re-rooting** a board whose root was `R` (a worktree `W`, at `place` inside it) onto the canonical root `C`:
   - Paths relative to `R` (`code.path`, a follow tile's `history[].path`, `image.path`, a diagram's `path` and its graph's node paths, `changes.paths`, `changes.viewed` keys, `note/html/changes.root`, a terminal's relative `cwd`) are resolved against `R`.
   - `W` is the main checkout: made relative to `C` again (`place/<path>`). A note or HTML tile without `root` gets `root: place` when `place` isn't empty: its relative links meant `R`.
   - `W` is a linked worktree on branch `B`: made relative to `C` as above (the same path in the repository), and code, note, HTML and changes tiles without `root`, `ref` or `pinnedCommit` get `ref: "B"` and `refSha` (the branch's tip, read from `refs/heads`/`packed-refs`: the SHA `GitRefs.resolve` would settle on, without starting git on the main actor at launch; a changes tile without `base` also gets `base: "HEAD"`, since `ref` alone defaults to the merge-base view), so they read `B`'s worktree while it exists and `B`'s commit after. A code tile with `pinnedCommit` keeps reading that commit. A note or HTML tile of a board rooted below `W`'s top (`place` not empty) gets `root: R` instead of `ref`: a `ref` reads from the top. Image and diagram tiles have no `ref`: their paths become absolute in `W`, reported as unanchored when `W` is gone.
   - `W` is detached, or its branch is unknown: paths become absolute in `W` (live while `W` exists), notes/HTML/changes without `root` get `root: R`; reported as unanchored when `W` is gone.
   - A diagram's cached graph (`props.graph`: its aim, root, node ids and paths, edges), the nodes it expanded and arrow ends bound to its nodes (`node`) name nodes `<path>#<symbol>`: their paths move as the diagram's, so its next build finds them again.
   - Absolute paths are left alone. A terminal's `cwd` is made absolute.
7. The target is written (atomically), then each merged legacy file moves to `boards/pre-repo-migration/<id>.json`. Page snapshots stay in `boards/<legacy id>/snapshots/` (image tiles name them by absolute path).

**Notice**: each repository board that gained regions shows a notice when it opens after the launch that merged them, naming the regions and, separately, those from worktrees in a temporary directory (`/tmp`, `/var/folders`: throwaway checkouts, which the user may delete); each of those regions also gets an attention marker saying so, which stays until the user has seen it. The launch log says the same.

**Report** (`migration.json`, and the dry-run): per repository, the target id and root, and per legacy board its id, root, branch or detached/unknown, live/deleted worktree, whether that worktree is temporary, objects before, objects after (+1 for a region group), the region id and offset, and each path that couldn't be anchored (`unanchored`). Plus the key renames, the non-git boards left alone and the unresolved legacy boards. A repository's load that changes nothing (its boards still conflict, the same legacy boards left unresolved) adds no run.

## Compatibility

- **Running terminals survive the migration.** zmx sessions are named by tile id (`canvas-<tileId>`), agent report spools by tile id, and resume ids (`props.agent`) and the tray's target (`promptTarget`) travel with the objects, so every terminal of a merged board reattaches to its running session. What is keyed by the board id: `EASL_BOARD_ID` in the environment of shells started before the migration, so an API call naming a merged legacy board's id is answered by the repository board that merged it (`BoardRegistry.board(id:)`, through `repo.merged`: `board` params, `events.subscribe`, the cmux workspace); the window's saved frame (`Canvas-<boardId>`), which starts at the default once; `boards/<legacy id>/snapshots/`, left in place (image tiles name those files by absolute path). The zmx session's informational `canvas.board` label is rewritten at the next attach.

- `board.list`'s `root` is the canonical root; entries gain `repo` and `worktrees`. Legacy boards still in the store (unresolved) list as before.
- `board.open` still takes an explicit absolute root; its result gains `worktree`.
- A tile's relative paths written by an agent in a linked worktree are made absolute in that worktree unless the agent passes `ref` (FeatRef).

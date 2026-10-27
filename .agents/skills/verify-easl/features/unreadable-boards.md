# Unreadable boards

Users receive a refusal instead of an empty replacement when a saved local board is unreadable or requires a newer format. Existing bytes and recovery copies survive close and quit.

## Sub-features

- `board-refuse` refuses unknown object types, truncated JSON, and newer board formats.
- `board-recovery-copy` preserves one byte-identical copy per distinct unreadable payload.
- `board-restore-refuse` retains failed restore roots without overwriting their boards.
- `board-migration-refuse` refuses unreadable legacy and repository boards before merging or adoption.

## How to get to it (user POV)

Choose File > Open Board… and select a folder with an unreadable saved board. The app reports why it cannot open the file. Startup restore and repository adoption also refuse unreadable inputs.

## Driving it with dev.sh

Preconditions: an isolated development home and disposable board roots. Save a valid board with a unique note first. Record its actual storage path from that home's board directory, board ID, original bytes, and hashes. Stop the app before changing a saved fixture. Never corrupt a production board or a board currently being saved.

1. Make separate fixtures from the saved board: change an object's type to `hologram`, set `format` to 99, and truncate JSON. Also combine newer format and unknown type. Keep an untouched control and a copy of each exact input.
2. Start on the control. Choose File > Open Board… and open each fixture root. Capture the refusal naming the board file and reason. Confirm the rejected root never becomes an empty selected board. Repeat through `board.open --root "$REFUSED_ROOT"`; require an `unavailable` error, not a new board.
3. Retry each root. Compare the original file byte-for-byte with its input. Require one byte-identical sibling named `<board-file>.unreadable-*`, not another copy on every attempt. Close and quit, then compare again.
4. For restore, create a valid restore entry through an ordinary open and quit. Corrupt that saved board while stopped, then relaunch the same home. Capture the restore refusal and confirm the root remains in restore state. Repair it with the retained valid fixture and require its unique note on the next open. Keep the recovery copy unchanged.
5. Exercise repository migration and folder adoption from `Tests/CanvasCoreTests/RepoBoardUnreadableMigrationTests.swift` in separate disposable roots. Require the affected unreadable source or target to remain unchanged, without normalization, path rewrite, or retirement. Readable unrelated boards can still migrate. Include truncated adoption sources as a separate probe; report an empty replacement as a product failure, not an allowed fallback.
6. Qualify old-name migration separately with `Tests/CanvasCoreTests/LegacyMigrationTests.swift`'s unreadable source and destination cases. Ordinary development launches skip it. Follow `docs/testing.md`'s throwaway-account-home rehearsal with its required `HOME`/`EASL_HOME` relationship, inside the guest only. Require "Couldn't migrate saved boards", unchanged affected bytes/locations, and no successful migration marker. A normal board-open refusal does not qualify either migration path.

## Gotchas

- `Sources/CanvasCore/BoardFile.swift` distinguishes missing files from refused files and deduplicates recovery copies by bytes.
- `Sources/CanvasCore/BoardStore.swift` reads before normalization or repository adoption.
- `Sources/CanvasApp/AppDelegate.swift` presents native errors and retains failed restore roots.
- `Sources/CanvasCore/RepoBoardMigration.swift` and `LegacyMigration.swift` refuse unreadable inputs before migration.
- A missing board file is a valid new board, not an unreadable-board case.
- Permission failures can prevent recovery-copy creation. Retain that reported failure; do not call it a successful preserved copy.
- This journey qualifies the Mac host. Do not assume the guest-local Go daemon implements the same recovery-copy policy.

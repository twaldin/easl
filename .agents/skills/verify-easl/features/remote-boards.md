# Remote boards

Users open a host's board through SSH, edit shared objects, and inspect retained content after the host closes the board.

## Sub-features

- `remote-open` opens the exact scratch board through the remote picker and replay entry.
- `remote-discovery` lists an open remote tab through the app socket, resolves its host board ID, and removes the row when the tab closes.
- `remote-sync` shows a committed edit in two independent viewers.
- `remote-terminal` types into the host-owned shell and checks host output.
- `remote-close` retains readable content without admitting new writes after closure.

## How to get to it (user POV)

Choose File > Open Remote…, type the SSH host, and choose its board. The replay entry `input remote` calls the same remote-board open operation but does not qualify the picker UI. This skill permits only the guest-local alias `easl-guest` pointing to scratch easld.

## Driving it with dev.sh

Preconditions: follow the skill's loopback-SSH setup, keep forwarding alive, start `$G/easld --home "$G/host" --own-terminals`, and seed the fixture. Record actual IDs from `$G/tiles.json`. Verify scratch lock ownership and loopback authentication before launch.

- The skill's setup already opened this tab. Close it with `scripts/dev.sh cli board.close --board "$BOARD"`, require its row absent, then save the baseline `board.list`. Open with `scripts/dev.sh cli board.open_remote --host easl-guest --board "$BOARD" --select true`. Require exactly one new row with `remote: true`, `host`, `sshTarget`, the host's `board` and `root`, `title`, the tab's `window`, and `open: true`. Match shared values to the open reply. Require unchanged local rows in their original order, with no `remote` field. Remote rows omit local-only `archived`, `objects`, `updatedAt`, `repo`, and `worktrees`. Capture the new tab by that PID and window.
- Separately exercise `scripts/dev.sh input remote easl-guest "$BOARD" "$G/host"`. An already-open tab is reused; do not expect another discovery row. Require the expected root and capture terminal, HTML, and browser progress. `board.get` alone is not a usable-open endpoint.
- For picker coverage, invoke `input mainmenu "File/Open Remote…"`. Use fresh AX labels to type `easl-guest`, list boards, and choose the seeded board. Capture host and board selection states. Never select a remembered production host or the Start easl action on an unowned machine.
- Start viewer B in `$G/view-b` with the same SSH overrides and frozen app. Open the same board. Edit a unique note in A using native input. Read the host with `EASL_SOCKET="$G/host/easl.sock" bun "$R/cli/easl.ts" object.get --id "$NOTE"`. Capture the committed text in **both** viewers by their own PID/window. The host reply and B's visible pixels are separate endpoints.
- Select the seeded terminal in A, type and submit distinct markers, and capture both viewers. Check host terminal readback and an actual receipt file. A relayed browser requires [the browser journey](browser-tiles.md), not this terminal check.
- For closed-board behavior, close the host board through its socket with `board.close --board "$BOARD" --endSessions true`. Keep the viewer tab. Capture retained content, pan and zoom it, then attempt a native mutation. Host object data and revision must stay unchanged. Reopen the host board and verify ordinary edits work again. Do not claim full closure safety from one note; delayed LSP, terminal links, HTML links, and Changes reads have separate races documented in `docs/testing.md` under the remote-closed-board regression.
- Run `scripts/dev.sh cli view.get --board "$BOARD"`. It returns no window ID. Match its board, selection, and viewport to a fresh native state receipt for the window from the open reply and discovery row. Read `board.get` and `object.find` through the viewer socket with explicit `--board "$BOARD"` and compare objects to the direct scratch-host read.
- Create a unique note through the viewer socket, update it with `object.batch` and an explicit remote board, then render it with `view.render --board "$BOARD" --target "$NOTE" --inline true`. Keep the note for the tray checks before deleting it.
- Stage one host mention and three viewer mentions of that note. Require distinct mention IDs. Run the viewer's tray list and peek drain, then consume separate mentions through unstage, commit, and consuming drain. Require the host tray unchanged. Remove its mention explicitly, then delete the note with viewer `object.batch --board "$BOARD"` and confirm deletion on the host. A viewer `view.open_url` call returns `unsupported` rather than panning the host viewport.
- Close only the viewer tab with `scripts/dev.sh cli board.close --board "$BOARD"`. Require its remote row to disappear, unchanged local rows, and explicit viewer `view.get --board "$BOARD"` to return `not_found`. Require the scratch host board still open. Capture the remaining local tab before closing the host board.
- End all scratch board sessions before stopping the daemon. Stop both viewers before the SSH forward. Export native captures and both app logs.
- Run [remote image previews](image-previews.md) for image tiles. Treat old-host method errors separately from explicit original selection.

## Gotchas

- Two instances viewing different local roots do not prove shared-board synchronization or relay.
- SSH authentication success does not prove the intended easld home. Inspect the private wrapper, stamped remote-home setting, daemon command, lock owner, and board ID.
- Loopback guest shaping qualifies a stated synthetic route, not a physical network or production host.
- Remote contents are memory-only in the viewer. Native cached pixels after closure do not prove fresh host data.
- Never use the older deckbox scratch-server recipe for this skill. Servers stay inside the guest.

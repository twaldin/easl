# Browser tiles

Users browse in native WebKit tiles, automate page controls through the CLI, and interact with a page drawn by another viewer through the relay.

## Sub-features

- `browser-native` creates a browser, enters a URL, navigates history, and types into page controls.
- `browser-cli` locates and drives page elements through the cmux browser subset.
- `browser-relay` forwards native input from viewer B to a page drawn by viewer A.
- `browser-gates` distinguishes first visible response from settled sharp assignment.

## How to get to it (user POV)

Choose File > New Browser Tile… or use the default Shift-Command-B binding. Type an address in the tile's address bar. Use the same native page controls on a scratch remote board. Agents use `easl browser` against the selected instance's cmux socket.

## Driving it with dev.sh

Preconditions: a guest-local HTTP fixture with unique text, a labelled input, a click counter, and a marker that changes color on each click. The seeded one-second browser counter proves liveness but has no click control; do not use it unchanged for click or timing claims. Record fixture bytes and HTTP PID. For CLI calls, clear inherited `CMUX_SOCKET_PATH`, `CMUX_SURFACE_ID`, and `CMUX_SOCKET_PASSWORD` so the selected dev home's cmux socket is used.

- Invoke `scripts/dev.sh input mainmenu "File/New Browser Tile…"`, enter the actual guest-local URL, and confirm with Return. Repeat with `input shortcut b --mods shift+cmd` when qualifying both creation entries. Capture loaded content, not just its address bar. Click a link, go back and forward, reload, and type into a labelled field through native tile input. Require visible state changes.
- Record the browser tile as `BROWSER`. Read `scripts/dev.sh cli browser snapshot "$BROWSER" --interactive`. Find the current ref by its accessible role and name, then run `scripts/dev.sh cli browser click "$BROWSER" --selector "$REF"`. Use `browser fill "$BROWSER" --selector "$FIELD_REF" --text "browser verification"` for the labelled field. Require visible page state and independent readback through `browser eval "$BROWSER" --script 'document.body.innerText'`. Do not count CLI page actions as native hit-testing proof. Browser screenshots and DOM snapshots are supplemental, not WindowServer proof.
- For the relay, attach A to one guest-local scratch board and load the browser in A first. Start B in a different home using the same frozen app, SSH wrapper, and scratch host. Open the **same** board in B. Retain drawing-client and stream identity from host/client diagnostics. Require A to remain the drawing viewer and B to consume its stream. Two local pages with the same URL are not a relay.
- In B, use native `input click` on the fixture button, not `browser click` or page JavaScript. Keep separate before, immediate/intermediate, and settled Cua captures by B's exact PID/window. Require exactly one source counter increment, the changed marker in B, and preserved input focus. Repeat native typing and scrolling. Capture A independently as source control. Missing stream identity means the relay precondition is unproven.
- For response timing, launch with `EASL_DEV_SURFACE_TRACE=1` and use `scripts/perf-browser-gates.py` as [performance](../performance.md) specifies. Gate A ends at the first valid own-NSWindow SCStream marker display with exactly one source increment. Gate B ends at the first `refresh:true` assignment covering the last queued input on the same stream. Keep first input-covering decoded assignment as a third, separate diagnostic. Native presentation, decoded assignment, and RGB quality are not interchangeable.
- Park and restore the browser, then require new page state and native input. A saved card is allowed while parked; the restored live page must not remain a stale picture. Whole-board `view.render` coverage, including unseen browsers assigned to both drawing clients, is a separate contract in `docs/testing.md` and does not replace native relay proof.
- On a fresh board, place a cold browser far outside the viewport. Confirm preview work is deferred until it approaches the viewport. Separately move a previously live browser out of view and require its departure snapshot, then restore it and require advancing page content. These are distinct deferred-preview cases.

## Gotchas

- Relay pixels may arrive before sharp refresh. Never replace an intermediate capture with its settled frame or call PNG completion first-visible latency.
- Gate B is not applicable for matching JPEG or PNG assignments because they have no idle sharp refresh. A later input's JPEG does not excuse a missing refresh for this input.
- Gate A requires macOS 14.4+ and the own-window observer. There is no screenshot-timing fallback. Cua captures audit pixels; their completion timestamps are not the native display endpoint.
- Reuse neither browser snapshot refs nor Cua element tokens after their snapshots change.
- Browser automation uses a separate cmux socket. An inherited cmux path can silently address another instance. Native navigation and CLI automation are separate entries.
- Extensions, uploads, downloads, external links, profiles, and native permission prompts need their own cases when changed. Keep downloads in scratch and external opening in log mode. Never use an installed signed-in profile as seed data.

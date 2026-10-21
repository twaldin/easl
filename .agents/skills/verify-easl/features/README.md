# Easl verification map

Read [verify-easl](../SKILL.md) for guest claims, launch, Doctor, capture, export, and cleanup. Every journey starts in an isolated guest home at the recorded head, with Doctor passing. Native actions go through `scripts/dev.sh input`; CLI actions go through `scripts/dev.sh cli`. Set the correct `EASL_DEV_HOME` on every command. Never use a production board.

## Features

- [Local board basics](local-board.md) covers creation, selection, moving, undo, the Move tool, and drawing.
- [Terminals](terminals.md) covers native creation, typing, persistent sessions, and remote ownership.
- [Composer](composer.md) covers focus, targets, sending, mentions, text editing, history, and delivery receipts.
- [Browser tiles](browser-tiles.md) covers native navigation, browser automation, and a relay between two instances.
- [Remote boards](remote-boards.md) covers scratch easld over guest-loopback SSH, synchronization, and closure.
- [Keyboard shortcuts](keyboard-shortcuts.md) covers native key routing and editable bindings.
- [HTML and video tiles](html-video.md) covers live HTML, native playback, seeking, and remote controls.
- [Questions and expiry](questions-expiry.md) covers CLI creation, native answers, cancellation, expiry, and archive retention.

## Proof and failure reporting

Each feature file lists entry points and sub-feature IDs. Cover every listed entry point before claiming the whole feature works. One acceptance smoke journey does not qualify the rest of the map.

Capture before, action or intermediate, and after states through exact-PID/window CuaDriver requests. Save unique PNGs and receipts, inspect the exported images, and pair them with CLI or filesystem readback. Record the feature ID, entry point, actual head, guest, native identity, and result with each claim. Keep failures and unmet preconditions. Never replace a failed native path with an API mutation and call it a pass.

The map contains recipes, not recorded passing results. The acceptance smoke exercises one journey. Performance claims also require [the performance procedure](../performance.md). After cleanup, confirm that evidence still exists outside scratch.

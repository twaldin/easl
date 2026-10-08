# Material for a Ghostty "Feature Requests, Ideas" discussion (Tim posts it in his own words: Ghostty's AI policy forbids AI-written submissions)

**Title:** libghostty: a way to pause/throttle the renderer that is not `ghostty_surface_set_occlusion`

## Problem

An embedding app (easl, a macOS board of many terminals) wants terminals nobody is watching to
redraw rarely: after a minute of user idle, each surface should present at most a couple of times
a second, and resume at once on input. Ghostty presents from its own display link on every cell
change (a working agent's spinner updates every 80 ms), so with fifteen such terminals a board
costs ~120 window updates/s all night for an empty chair (measured 2026-10-07: easl 15–19 % GPU,
WindowServer ~50 % CPU; pausing the renderer with occlusion pulses cut GPU 38 → 13.5 %).

The only host-side input to the renderer's `visible` flag is `ghostty_surface_set_occlusion`
(`renderer/Thread.zig`: `flags.visible` is set from the `.visible` mailbox message, which
`Surface.occlusionCallback` sends). Since #13494, `occlusionCallback` also sets
`terminal.flags.visible` and, when the program enabled mode 2033 (`report_visibility`), queues
a visibility report (`Surface.zig` at 3c47ca1, `occlusionCallback`). So an embedder that pulses
occlusion to throttle drawing tells a 2033-enabled program it is hidden ~90 % of the time, with
reports at the pulse rate — a protocol-visible side effect of what should be a presentation
decision. (Today no program we run enables 2033; the API shape still conflates two things.)

## Ask

One of:

1. **`ghostty_surface_set_render_paused(surface, bool)`** (or `set_render_throttle(surface,
   max_fps)`): pauses or rate-limits the renderer thread's draws (`drawFrame`) without touching
   `terminal.flags.visible` or the 2033 report. Occlusion keeps its current meaning.
2. **Split the occlusion message:** `.visible` to the renderer and the terminal visibility flag
   remain tied for real occlusion, but a second C entry point sends only the renderer message.

A `max_fps` form would let the embedder say "2 Hz while idle" and avoid the full redraw per
un-occlusion that pulsing costs (each `.visible = true` rebuilds the frame; at 5 pulses/s
across 15 surfaces that was +22 % CPU for the app; 2/s was cost-neutral).

## Context

- Embedder: easl (`twaldin/easl`), libghostty via Lakr233/libghostty-spm, upstream 3c47ca1.
- Measurements: `perf/trial6-result.md`, `perf/trial6b-result.md` on easl's `perf/results` branch.
- The embedder-side pulse implementation: easl PR #83.

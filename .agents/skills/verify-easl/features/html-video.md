# HTML and video tiles

Users view live sandboxed HTML and play native video locally or from a remote host without mistaking retained images for advancing content.

## Sub-features

- `html-live` advances a visible HTML counter and responds to real tile input.
- `html-create` reaches File > New HTML Tile independently of API fixture creation.
- `video-native` plays, pauses, seeks, parks, and restores a native video tile.
- `video-remote` exercises host range reads with silent and audio-bearing controls.

## How to get to it (user POV)

Choose File > New HTML Tile or press Shift-Command-H. Agents can create HTML and video through the CLI. Interact with HTML inside its tile and native video through its player controls. Video has no manual creation menu in the default shortcut table.

## Driving it with dev.sh

Preconditions: the claimed guest is muted, scratch files are guest-local, and the fixture's media paths and hashes are recorded. Use the seeded HTML counter for a ready-to-drive live case. A custom HTML fixture must have a bounded script and a unique object key.

- Reach HTML through `scripts/dev.sh input mainmenu "File/New HTML Tile"`, then separately `input shortcut h --mods shift+cmd` when qualifying both native creation paths. Capture the created tile and retain its object ID. Do not count the API-seeded counter as proof of menu creation.
- In the seeded scratch board, capture the visible **HTML tick** value, wait for at least two increments, and capture again under a new filename. Check actual rendered numbers, not object props. Add a labelled button to a scratch HTML fixture, click through the tile's native input, and require a visible counter change. Hyper-click the element and inspect its staged mention as a separate path.
- Create a native video against the selected scratch socket: `scripts/dev.sh cli object.create --board "$BOARD" --type video --json '{"props":{"path":"silent.mp4","muted":true,"autoplay":true,"startTime":20},"frame":{"x":0,"y":0,"w":300,"h":540}}'`. Record the returned `VIDEO` ID. The file must exist under that board's root, not merely under the controller's working directory.
- Capture native frames before and after playback and read the timeline through the exact-window AX tree. Require both new decoded pictures and advancing time. Pause with the player's native control. Seek backward and forward while paused, verify the requested position, resume, then seek while playing. API control through `object.update --id "$VIDEO" --json '{"props":{"startTime":10,"autoplay":false}}'` is a separate entry point. Exercise both when claiming both.
- Park the tile offscreen and bring it back. Require preserved position and responsive controls. On a scratch remote board, seek during an outstanding host read, then close the host board during playback. Inspect the retained presentation and confirm no video payload was staged on the viewer's disk.
- Repeat with byte-identical local and remote copies, first a silent stream copy, then the original audio-bearing clip muted and unmuted **inside the muted guest only**. Keep HTML `<video controls>` tiles as separate transport/decoder controls. Follow `docs/testing.md`'s native remote video regression for hashes, `ffprobe`, range-starvation cases, and diagnostics.

## Gotchas

- An HTML decoder passing does not qualify native AVKit. A spinner disappearing or `object.get` reporting autoplay does not prove playback.
- Guest audio pipelines have hung in CoreAudio. Retain `sample "$PID" 5 -file ...` and `system_profiler SPAudioDataType -json` on failure. Do not label it guest-only without a permitted physical-Mac control. Home's display is never that control.
- Video and browser capture can throttle when hidden. Native pictures must actually advance.
- A sandboxed HTML page, browser page, and native video are separate paths. Report each tested path by name.

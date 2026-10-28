# Terminals

Users start shells and agents in terminal tiles, type into them, and return to their persistent zmx sessions after app relaunch.

## Sub-features

- `terminal-create` creates through File > New Terminal and Command-T.
- `terminal-input` reaches the real shell through native text and Return.
- `terminal-persist` keeps the shell alive through viewer restart, then cleans it up.
- `terminal-remote` observes a scratch host's real shell rather than a local replacement.
- `terminal-native-activity` distinguishes native-key echo and idle-clock activity from text insertion.

## How to get to it (user POV)

Choose File > New Terminal or press Command-T. Click the terminal body to type. Closing its tile asks for confirmation; choose Close or Command-Delete to end the session. Return and Escape cancel. Quit to preserve sessions. When closing a local board, choose Keep Running rather than End Sessions. Closing a remote viewer leaves host sessions running.

## Driving it with dev.sh

Preconditions: a claimed guest and a selected scratch board. Use a fresh board with no agent secrets. Capture the actual shell prompt before input.

- Run `scripts/dev.sh input mainmenu "File/New Terminal"`. Retain the new tile ID from `scripts/dev.sh cli agent.list`. Capture the shell and verify its working directory belongs to the scratch root. Repeat with `scripts/dev.sh input shortcut t --mods cmd` when qualifying both creation paths.
- Click the measured terminal body with `input click "$X" "$Y" --window "$WINDOW"`. Run `input text "printf 'TERMINAL_A\\n'"`, then `input key return`. Capture visible `TERMINAL_A`. Repeat with a distinct `TERMINAL_B` and an unused capture name. Use `scripts/dev.sh cli agent.read --target "$TERMINAL" --lines 40` as supplemental readback, not pixel proof.
- Type a harmless command that appends a unique line to a file under `G` and prints it. Check the file and native output. Do not count the terminal's echoed command as its execution result.
- For fresh local attachments, send native keys and Return at 50 ms, 100 ms, 1 s, and 5 s after creation, with at least 10 runs per delay. Retain the creation and input timestamps. Require the full marker, including its first character, exactly once in the scratch receipt file and native output. `input text` does not qualify first-key handling.
- Retain attachment identities and lifecycle logs while replacing terminals. Require no stale exit or detached-session recovery for a fresh live attachment. If a key is refused during genuine exited-attachment recovery, require a visible refusal and no automatic replay.
- Retain the terminal session identity and shell PID from the actual session. Run `scripts/dev.sh restart`, rediscover PID/window, and run Doctor. The same shell/session and prior output must return. Send another marker and capture it. Do not use `stop` for this persistence check because it deliberately ends the sessions.
- For remote coverage, use the seeded scratch board's terminal through `input remote easl-guest "$BOARD" "$G/host"`. Drive the viewer and read output against `$G/host/easl.sock`. Check host ownership and files on the guest. A local shell that prints the same string does not qualify the remote path.
- For native-key echo and idle-clock claims, follow the terminal echo procedure in `docs/testing.md`. Use `input key`, not `input text`, for the native key path. Clear idle pinning, retain an idle control, send a native key, and inspect renewed drawing activity. Keep measurements separate from this shell-execution smoke.
- During final cleanup, close the scratch host board with `endSessions:true` and stop each development home. Check that the recorded sessions are gone. Never kill all zmx processes.

## Gotchas

- `input text` only inserts. Return submits through the responder chain.
- A terminal may be parked as a card. Zoom or pan it into view, then prove fresh output in native pixels.
- App restart preserves shells; `dev.sh stop` ends this home's shells. Use the correct operation.
- Never type into an unknown agent's approval dialog. The fixture is an owned shell unless a journey explicitly starts an isolated agent.

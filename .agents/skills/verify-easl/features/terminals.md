# Terminals

Users start shells and agents in terminal tiles, type into them, and return to their persistent zmx sessions after app relaunch.

## Sub-features

- `terminal-create` creates through File > New Terminal and Command-T.
- `terminal-input` reaches the real shell through native text and Return.
- `terminal-persist` keeps the shell alive through viewer restart, then cleans it up.
- `terminal-remote` observes a scratch host's real shell rather than a local replacement.
- `terminal-native-activity` distinguishes native-key echo and idle-clock activity from text insertion.
- `terminal-rekey-focus` preserves keyboard ownership when a remote host replaces a new terminal's provisional ID.

## How to get to it (user POV)

Choose File > New Terminal or press Command-T. A new terminal takes keyboard focus; click an existing terminal body to type. Closing its tile asks for confirmation; choose Close or Command-Delete to end the session. Return and Escape cancel. Quit to preserve sessions. When closing a local board, choose Keep Running rather than End Sessions. Closing a remote viewer leaves host sessions running.

## Driving it with dev.sh

Preconditions: a claimed guest and a selected scratch board. Use a fresh board with no agent secrets. Capture the actual shell prompt before input.

- Run `scripts/dev.sh input mainmenu "File/New Terminal"`. Retain the new tile ID from `scripts/dev.sh cli agent.list`. Capture the shell and verify its working directory belongs to the scratch root. Repeat with `scripts/dev.sh input shortcut t --mods cmd` when qualifying both creation paths.
- Click the measured terminal body with `input click "$X" "$Y" --window "$WINDOW"`. Run `input text "printf 'TERMINAL_A\\n'"`, then `input key return`. Capture visible `TERMINAL_A`. Repeat with a distinct `TERMINAL_B` and an unused capture name. Use `scripts/dev.sh cli agent.read --target "$TERMINAL" --lines 40` as supplemental readback, not pixel proof.
- Type a harmless command that appends a unique line to a file under `G` and prints it. Check the file and native output. Do not count the terminal's echoed command as its execution result.
- Retain the terminal session identity and shell PID from the actual session. Run `scripts/dev.sh restart`, rediscover PID/window, and run Doctor. The same shell/session and prior output must return. Send another marker and capture it. Do not use `stop` for this persistence check because it deliberately ends the sessions.
- For remote coverage, use the seeded scratch board's terminal through `input remote easl-guest "$BOARD" "$G/host"`. Drive the viewer and read output against `$G/host/easl.sock`. Check host ownership and files on the guest. A local shell that prints the same string does not qualify the remote path.
- For `terminal-rekey-focus`, create a remote terminal and type a distinct `echo` marker and Return without clicking at requested delays of 50 ms, 1 s, and 5 s. Require exactly one output line per marker in the host session and unchanged Select-tool pixels. Retain the provisional and canonical selection IDs with fresh native responder observations. Record actual native input call times separately from requested delays.
- Hold only the scratch host's terminal creation reply to exercise pre-ID input. Character keys and Return must show a visible refusal and must not change drawing tools or replay after the canonical ID arrives. In a separate trial, move to the composer before the reply, type a draft, then require the composer and draft to survive replacement and accept another key. Check another tile and another key window with the native runner.
- For native-key echo and idle-clock claims, follow the terminal echo procedure in `docs/testing.md`. Use `input key`, not `input text`, for the native key path. Clear idle pinning, retain an idle control, send a native key, and inspect renewed drawing activity. Keep measurements separate from this shell-execution smoke.
- During final cleanup, close the scratch host board with `endSessions:true` and stop each development home. Check that the recorded sessions are gone. Never kill all zmx processes.

## Gotchas

- `input text` only inserts. Return submits through the responder chain.
- A terminal may be parked as a card. Zoom or pan it into view, then prove fresh output in native pixels.
- App restart preserves shells; `dev.sh stop` ends this home's shells. Use the correct operation.
- Never type into an unknown agent's approval dialog. The fixture is an owned shell unless a journey explicitly starts an isolated agent.

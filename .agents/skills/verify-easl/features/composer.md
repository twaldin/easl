# Composer

Users write prompts without panning back to a terminal, add mentions with Hyper-click, and send to selected terminals while preserving drafts and delivery state.

## Sub-features

- `composer-shell-send` sends one command to an owned shell through the native composer.
- `composer-focus-text` covers Command-I, Return and Shift-Return newlines, Command-Return send, and Escape.
- `composer-targets` covers no target, one target, multiple targets, and target exit during a draft.
- `composer-mentions` stages, removes, clears, undoes, and resolves mentions.
- `composer-history` recalls sent text and distinguishes local persisted drafts from remote memory-only drafts.
- `composer-agent-delivery` checks real omp session receipt through a guest-local model-provider stub.

## How to get to it (user POV)

Choose Edit > Write Prompt or press Command-I. Choose terminal targets from the arrow target button or Edit > Send Mentions To. Hyper-click content, or press Shift-Command-M on focused content, to insert a mention token. Option-Shift-Command-M removes the last mention. Command-Return sends; Escape leaves the composer.

## Driving it with dev.sh

Preconditions: an isolated board, one owned zsh terminal, and a note with unique text. The target must be a live shell, not an agent setup wizard. For remote cells, use the same fixtures on scratch easld and replace CLI model reads through `scripts/dev.sh cli` with `EASL_SOCKET="$G/host/easl.sock" bun "$R/cli/easl.ts"`; native input still goes to the viewer. Use the exact-window AX label **Prompt** to inspect the composer. The current target button's label comes from its fresh AX tree, not a saved coordinate.

- Read `scripts/dev.sh cli agent.list` and record the owned terminal ID. Find its actual **Only …** item in a fresh AX tree, using the terminal's current name or directory title. Escape each literal `/` in that title as `//` and set `TARGET_MENU_TITLE` to the escaped full item, including `Only `. Invoke `scripts/dev.sh input mainmenu "Edit/Send Mentions To/$TARGET_MENU_TITLE"`. Option-key alternate items can be absent from a closed menu's AX tree. In that case, invoke `Only ` plus the current target title, then inspect any `DevInput: no menu item … in [titles]` log line for the exact available title before retrying. Require the target button to name the owned terminal. Do not reuse an old title or assume every terminal has an agent name.
- Press `input shortcut i --mods cmd --window "$WINDOW"`. Run `scripts/dev.sh input text "printf 'COMPOSER_ONCE\\n' | tee -a '$G/composer-received.txt'"`. Capture the **unsent command** and target label. Press `input key return --mods cmd --window "$WINDOW"`. Capture the terminal result and cleared draft with a new filename. Require exactly one `COMPOSER_ONCE` line in the receipt file. Save `agent.read` too. This is the acceptance smoke; it proves shell fallback, not agent mention resolution.
- With no target selected on an empty board, type three lines containing Japanese text and emoji. Return and Shift-Return must insert newlines. Command-Return must preserve the draft without delivery. Escape must return to the prior responder. Capture text and `input state` before and after. Terminate only the recorded owned target in a separate case; its exit must not discard the unsent draft.
- Repeat native Command-Return to fresh local terminals at 50 ms, 100 ms, 1 s, and 5 s after creation, with at least 10 runs per delay. Retain creation and submission timestamps. Require either one complete execution receipt or a visible refusal with the draft retained. A cleared draft alone is not execution proof.
- Exercise attachment exit or replacement between text insertion and Enter. Require a visible failure, the original draft and mentions retained, and a warning that text may already be present. Capture the terminal's partial text separately. Require no automatic replay into the replacement attachment.
- Hyper-click the note using fresh measured content points: `input click "$X" "$Y" --mods hyper --window "$WINDOW"`. Require a `[1]` token and the staged note. Unstage that reference before repeating through focused-content Shift-Command-M; mentioning an already-staged reference toggles it off. Delete a token, undo, redo, and undo again. The text and staged tray must agree. Test removal with `input shortcut m --mods opt+shift+cmd` and `input mainmenu "Edit/Clear Mentions"`. After the referenced tile is deleted, undo must neither resurrect its mention nor crash.
- Send a unique shell prompt, then use Up and Down in the composer to recall and clear history. Keep different local and remote drafts while switching tabs. Reopen and relaunch separately. Local drafts persist; remote drafts are memory-only and clear when their tab closes or the app exits. Record each case separately.
- For multiple targets, select two terminals in the target menu and use a unique receipt file for each. Require one receipt in each and no receipt in an unselected control. No-target behavior is not covered by a successful one-target send.
- For integrated delivery, follow [the isolated omp setup](../omp-provider.md). Start real omp with the repo's easl extension, wait for a live session with the expected model and no draft, then target it through the same native menu and composer. Hyper-click the note and send a unique marker. Inspect the actual session JSONL for exactly one user message and one hidden `canvas.mentions` custom message containing the resolved note text. Capture omp's visible reply. Repeat local and remote; a stub HTTP request count alone is not a session receipt.
- For transport-failure claims, run [prompt delivery after a lost reply](prompt-delivery.md). It covers execution-before-reply-loss, before-dispatch loss, transient reconciliation, and hosts without receipt support. Do not substitute a direct API send for native Command-Return.

## Gotchas

- The historical composer QA matrix at `/home/tim/agents/projects/easl/state/lanes/easl-composer-qa-1/matrix.md` distinguishes local and remote cells. It is a source of cases, not a current pass certificate. Its unauthenticated omp cells and dropped-reply failure were later addressed by the prompt-once lane.
- A shell receipt proves fallback submission, not integration lifecycle or resolved agent context. Never claim one from the other.
- `delivery: "typed"` confirms acceptance of the full text and Enter by the same live attachment, not execution. Keep the running-TUI 80 ms paste-to-Enter delay separate from readiness and delivery checks.
- Native paste, Japanese IME preedit, token undo, narrow windows, themes, and keyboard-only popup navigation are distinct cases. Use the matrix when those paths change. `input text` does not emulate IME composition or pasteboard formats.
- The target popup can remain open after an AXPress timeout. Capture it before retrying so a second press does not hide it.
- Never use a direct `agent.prompt` call or internal draft setter to qualify Command-Return.

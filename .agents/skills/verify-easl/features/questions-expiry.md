# Questions and expiry

Agents post question tiles through the CLI. Users choose an option or write a note, and closed questions archive without losing their answers.

## Sub-features

- `question-answer` posts a CLI question and receives its native answer.
- `question-cancel` closes an unanswered question and ends its waiter with exit 2.
- `question-expire` closes an unanswered question at its expiry.
- `question-archive` hides a closed tile while retaining its answer for CLI reads.
- `object-expiry` deletes an ordinary transient object at the host deadline.
- `question-archive-layout` excludes archived questions from geometry while retaining their answers.
- `board-stale-content` lists content-age cleanup candidates after layout changes and filters them by creator.
- `question-needs-you-refresh` preserves needs-you membership and ordering without decoding closed questions on every board change.

## How to get to it (user POV)

Run `easl ask` against the isolated instance's socket. Use Command-J or the open-question count to reach the tile. Press an option number, add a note, and press Return. There is no manual New Question menu. Archive hides a closed question sooner.

Use [graded questions](graded-questions.md) for `correct`, `askConfidence`, and native confidence entry. Confirm the intended question before answering; Command-J can visit a blocked terminal first.

## Driving it with dev.sh

Preconditions: an isolated local or scratch remote board with a live viewer. Set `API_SOCKET="$EASL_DEV_HOME/easl.sock"` for a local board, or `API_SOCKET="$G/host/easl.sock"` for the scratch remote board. Keep `API_SOCKET` on the host for remote questions. Viewer `--board` routing reaches `ask` without `--wait` and `ask list` only; `--wait`, `ask wait`, `ask get`, and `ask cancel` need the host socket. Supply the actual `BOARD` ID. The fixture asks only a test question; never answer a real approval or decision.

- In a separate owned CLI job, run `EASL_SOCKET="$API_SOCKET" bun "$R/cli/easl.ts" ask "Verification choice?" --board "$BOARD" --option a=Alpha --option b=Beta --recommend a --keep --wait`. Retain command, stdout, stderr, exit code, and the new ID from `ask list --open --board "$BOARD"` against that same socket. Capture the open question and recommendation.
- Reach it with `scripts/dev.sh input shortcut j --mods cmd --window "$WINDOW"`. Press `input shortcut 2`, then `input key tab` to reach the note field. Enter a distinct note and press Return. Require the waiter to return exit 0 with option `b`, label `Beta`, and that exact note. Inspect the answered tile in native pixels and read `EASL_SOCKET="$API_SOCKET" bun "$R/cli/easl.ts" ask get "$QUESTION"`. Repeat by clicking the option's fresh AX-labelled control when qualifying pointer access too.
- Create another question. Start `EASL_SOCKET="$API_SOCKET" bun "$R/cli/easl.ts" ask wait "$QUESTION"` as an owned job before running `EASL_SOCKET="$API_SOCKET" bun "$R/cli/easl.ts" ask cancel "$QUESTION"`. The waiter must end with exit 2 and a cancellation reason, not an answer. Capture the closed state.
- Create a distinct question with `--expires 5s --keep --wait`. Retain the open capture, expiry capture, and waiter exit 2 with the expiry reason. Do not answer it. Use unique capture paths so waiting cannot overwrite the open state.
- Create a question without `--keep`, record its effective `archiveAfter`, answer it, and capture disappearance after that interval. The default is ten seconds unless host settings override it. `ask get` and `ask list` must still return the answer. Also use the tile's native **Archive** control on a kept closed question and check retained answer readback.
- Separately create an ordinary scratch note with `object.create --board "$BOARD" --type note --expires 5s --json '{"props":{"markdown":"Transient verification note"}}'`. Capture it before expiry, then require its disappearance and failed `object.get` after the host deadline. This is deletion, unlike question expiry and archive.
- After archiving, place a note over the question's former frame. Raw rectangles may overlap, but collision, placement, and graph calculations must exclude the archived question. Exercise placement, group collapse, and arrow avoidance using `conformance/scenarios/archived-layout.json` as the fixture recipe. Run both hosts; disappearance alone does not qualify layout exclusion.
- For an in-place upgrade, create a note under v0.3.0 with a deadline long enough to finish the upgrade. Record its absolute expiry, ID, and content. Restart the candidate on the same isolated home. Require unchanged data before the original deadline and deletion afterward, without extending expiry.
- For `board-stale-content`, run `object-cleanup` conformance against the guest app and replay it against scratch easld. Age an authored note past the query threshold, move and resize it, and require `untouched`; editing Markdown must remove that reason. Move a group's members and require the group's content age to stay unchanged. `board.stale --mine` inside a terminal must return only that tile's creations. Close and reopen each host's board and require the same cleanup answer. Open scratch copies with the released app and easld and check that the optional content timestamp is ignored without a format change.

## Check needs-you refresh cost

Run `swift run -j 2 CanvasCoreTests --filter NeedsYouDerivationTests` for the fixed 320-question corpus, seven `now` values around expiry boundaries, terminal and marker precedence, and 100 unrelated remote changes. Its debug-only date observer bounds each derivation to one expiry parse per open question with a string deadline. Closed-question dates and answer dates must not be parsed.

For native proof, follow the guest launch, Doctor, capture, and cleanup procedures. Use release bundles and a 300-question fixture (below) on guest-local scratch easld over loopback SSH.

1. Create all 300 questions with `keep: true` so automatic archiving does not change the fixture. Keep 12 questions open. Split the remaining 288 between answered, cancelled, and expired, and explicitly archive three quarters of those. Retain answer timestamps and fractional future expiry timestamps. Keep one real terminal visible and a second terminal running `/bin/cat` and reporting `blocked`, so the tab shows a dot without a shell prompt clearing the synthetic agent state.
2. Capture the selected remote tab, its needs-you dot, and the window's count. Record the fixture hash, selected window, executable hash, and source revision.
3. Activate only the owned guest app with `open -a "$EASL_DEV_HOME/easl.app"`. Click the terminal body with native input and prove a harmless command reaches the shell before resetting viewer `app.metrics`; a replay receipt alone is not text-delivery proof. Start `scripts/dev.sh input key a --repeat 100 --interval 20 --window "$WINDOW"` inside a harmless shell command. While keys arrive, create 100 unrelated notes through the host socket. Creation refreshes both the title and the open-asks count; updates to existing notes do neither.
4. Require 100 successful host creates, a fresh viewer state containing all 100 notes, the burst-completion log, and exact shell readback of all 100 typed characters. Read metrics after the final turn closes. Retain `main.stretch50` and `main.stretch250` total counts and maxima, `longest`, and key counters. Delete the created notes outside the measured interval.
5. Alternate base and fix for five pairs with identical starting fixture bytes and geometry. Capture outside the measured intervals. Inspect exported native PNGs and confirm unchanged dot and title count. Exercise Command-J and the navigator separately, checking the waiting question's identity against the host readback.

No wall-clock threshold belongs in the permanent core regression. Native stretch counts describe this workload, not every source of main-thread stalls.

## Gotchas

- `ask --expires` closes an unanswered question. Object `--expires` sets a deletion deadline. They are not interchangeable.
- `--keep` keeps a closed question visible; it does not prevent unanswered expiry.
- A waiter queued or a question created is not an answer. Check its result and exit code.
- Keep the CLI waiter PID and stop only that process if the attempt fails. Clean the scratch board, but retain question transcripts and capture receipts.

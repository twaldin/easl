# Questions and expiry

Agents post question tiles through the CLI. Users choose an option or write a note, and closed questions archive without losing their answers.

## Sub-features

- `question-answer` posts a CLI question and receives its native answer.
- `question-cancel` closes an unanswered question and ends its waiter with exit 2.
- `question-expire` closes an unanswered question at its expiry.
- `question-archive` hides a closed tile while retaining its answer for CLI reads.
- `object-expiry` deletes an ordinary transient object at the host deadline.

## How to get to it (user POV)

Run `easl ask` against the isolated instance's socket. Use Command-J or the open-question count to reach the tile. Press an option number, add a note, and press Return. There is no manual New Question menu. Archive hides a closed question sooner.

## Driving it with dev.sh

Preconditions: an isolated local or scratch remote board with a live viewer. Set `API_SOCKET="$EASL_DEV_HOME/easl.sock"` for a local board, or `API_SOCKET="$G/host/easl.sock"` for the scratch remote board. The viewer socket cannot serve remote board objects. Supply the actual `BOARD` ID. The fixture asks only a test question; never answer a real approval or decision.

- In a separate owned CLI job, run `EASL_SOCKET="$API_SOCKET" bun "$R/cli/easl.ts" ask "Verification choice?" --board "$BOARD" --option a=Alpha --option b=Beta --recommend a --keep --wait`. Retain command, stdout, stderr, exit code, and the new ID from `ask list --open --board "$BOARD"` against that same socket. Capture the open question and recommendation.
- Reach it with `scripts/dev.sh input shortcut j --mods cmd --window "$WINDOW"`. Press `input shortcut 2`, then `input key tab` to reach the note field. Enter a distinct note and press Return. Require the waiter to return exit 0 with option `b`, label `Beta`, and that exact note. Inspect the answered tile in native pixels and read `EASL_SOCKET="$API_SOCKET" bun "$R/cli/easl.ts" ask get "$QUESTION"`. Repeat by clicking the option's fresh AX-labelled control when qualifying pointer access too.
- Create another question. Start `EASL_SOCKET="$API_SOCKET" bun "$R/cli/easl.ts" ask wait "$QUESTION"` as an owned job before running `EASL_SOCKET="$API_SOCKET" bun "$R/cli/easl.ts" ask cancel "$QUESTION"`. The waiter must end with exit 2 and a cancellation reason, not an answer. Capture the closed state.
- Create a distinct question with `--expires 5s --keep --wait`. Retain the open capture, expiry capture, and waiter exit 2 with the expiry reason. Do not answer it. Use unique capture paths so waiting cannot overwrite the open state.
- Create a question without `--keep`, answer it, and capture its disappearance after the default 10-second close-to-archive delay. `ask get` and `ask list` must still return the answer. Also use the tile's native **Archive** control on a kept closed question and check retained answer readback. A custom `archiveAfter` changes the delay; record it.
- Separately create an ordinary scratch note with `object.create --board "$BOARD" --type note --expires 5s --json '{"props":{"markdown":"Transient verification note"}}'`. Capture it before expiry, then require its disappearance and failed `object.get` after the host deadline. This is deletion, unlike question expiry and archive.

## Gotchas

- `ask --expires` closes an unanswered question. Object `--expires` sets a deletion deadline. They are not interchangeable.
- `--keep` keeps a closed question visible; it does not prevent unanswered expiry.
- A waiter queued or a question created is not an answer. Check its result and exit code.
- Keep the CLI waiter PID and stop only that process if the attempt fails. Clean the scratch board, but retain question transcripts and capture receipts.

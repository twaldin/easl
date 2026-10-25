# Graded questions

Agents mark a correct option and optionally ask for confidence. Users answer natively, then see grading and the explanation for the correct option.

## Sub-features

- `graded-correct` records a correct native answer.
- `graded-confidence` records an explicit 80% confidence value.
- `graded-wrong` shows incorrect grading and the correct option's explanation.

## How to get to it (user POV)

Post a question with `easl ask --correct <option-id> --confidence`. Use Command-J or the open-question count to reach it. Confirm the intended question is focused before answering; Command-J visits other needs-you items too.

## Driving it with dev.sh

Preconditions: follow Launch and Doctor. Run once on a local board and once on a remote board served by scratch easld. Set `API_SOCKET` to the actual board host socket and record `BOARD`.

1. Start an owned waiter job:

	```sh
	EASL_SOCKET="$API_SOCKET" bun "$R/cli/easl.ts" ask \
	  "Graded verification: what is two plus two?" --board "$BOARD" \
	  --correct a --confidence \
	  --json '{"options":[{"id":"a","label":"Four","why":"Two pairs make four."},{"id":"b","label":"Five","why":"Five is one too many."}]}' \
	  --keep --wait
	```

2. Record its ID with `ask list --open --board "$BOARD"`. Require `correct: "a"` and `askConfidence: true` in `ask get`. Navigate to that fixture, enter its keyboard focus, and capture the open tile. Require no grading marker and unset confidence.
3. Press native `1`, then the right arrow three times. The first adjustment starts from 50%, so three presses select 80%. Capture the selected Four option and visible 80% before pressing Return.
4. Require waiter exit 0 with `option: "a"`, `correct: true`, and `confidence: 0.8`. Require `ask get` to agree. Capture the closed tile's correct marker and 80% confidence text.
5. Post a second distinct question with the same options and correct answer. Focus that fixture, press native `2`, and submit without touching confidence. Require `option: "b"`, `correct: false`, and no confidence value. Capture the incorrect marker and the correct option's explanation, `Two pairs make four.`
6. Save and reopen. Read both answers again and capture their closed states. Do not manufacture native answer evidence with `object.update` or `ask answer`.

## Gotchas

- `recommended` is advice before answering. `correct` grades after answering. They are separate fields.
- Confidence is optional even when requested. An untouched slider leaves `answer.confidence` absent, not 0.5.
- The host computes `answer.correct`. A caller-supplied grading value is not the authority.
- Use [questions and expiry](questions-expiry.md) for cancellation, expiry, archiving, and waiter cleanup.
- Source entry points are `cli/easl.ts`, `Sources/CanvasCore/Question.swift`, `Sources/CanvasApp/QuestionTile.swift`, and `easld/internal/board/question.go`.

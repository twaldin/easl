# HTML and note object links

HTML tiles and notes select and show an open same-board object like a question context link. Navigate Back returns to the source view. This file is a verification recipe, not a passing result.

## Sub-features

- `html-go-to-id` covers `canvasKit.goTo({id})` and `<canvas-object id="…">label</canvas-object>`.
- `html-go-to-key` covers `canvasKit.goTo({key})` and `<canvas-object key="…">label</canvas-object>`, with lookup identical to `object.find`.
- `html-go-to-keyboard` covers link role, focus, accessible label, and native Enter.
- `html-go-to-permit` covers the existing document-bound 1.5-second native permit, single consumption, expiry, and refusal of load/timer/synthetic calls without a fresh permit.
- `html-go-to-refusal` covers missing, closed, other-board, malformed, and unknown-field targets, including `zoom`, without changing the view or selection. Promise rejections appear in the component's title.
- `html-go-to-framing` covers unchanged question-context behavior for visible, far-away, and oversized targets, and Navigate Back.
- `html-go-to-remote` covers viewer-local navigation on a remote board without a host navigation RPC.
- `note-object-link` covers `[label](easl:object/<id>)` and `[label](easl:key/<key>)`, percent-encoded targets, refusal notices, and Navigate Back.
- `html-go-to-performance` covers comparison with main, no new main-thread stall of at least 50 ms, and no new idle timers or polling.

## Driving it with dev.sh

Follow Launch and Doctor in the claimed isolated guest at the recorded head. Use exact-PID/window captures and native `scripts/dev.sh input` actions. CLI setup and readback use `scripts/dev.sh cli`. Keep all receipts and images outside scratch before cleanup.

1. Run `Tests/HtmlGoTo/run.py --bin-path "$BIN"` for native bridge and permit cases. Retain its output. It covers ID/key navigation, selection and Back, native component click and Enter, empty and ambiguous targets, unknown fields including `zoom`, extra arguments, load/timer/synthetic refusal, consumed and expired permits, ordinary typing refusal, missing and other-board targets, oversized fitting, a note key link, and closed boards. Native tests do not replace the live kit journey.
2. Create a local board with an HTML source tile and a far-away note with a stable key. Include actual kit ID and key components, a direct API button that displays its resolved ID or rejection, and a note with both Markdown URL forms. Include a percent-encoded key. Capture the source and record `view.get` plus object frames and IDs before input.
3. Click the real ID component using coordinates from a fresh capture. Capture the selected far-away note and read back the view and selection. Require the same framing as a question context link, without changing object geometry. Invoke Navigate Back with native input, capture the restored source view, and compare it with the before state. Repeat for the key component and direct API button, checking the resolved ID.
4. Focus the real component with native keyboard input and press Enter. Capture focus before activation and the selected target afterward. Inspect its link role, accessible name, and tab order. Inactive `dev.sh` key replay bypasses AppKit's local gesture monitor; if background Enter does not navigate, use CuaDriver's exact-PID/window `press_key` with `delivery_mode: foreground` inside the claimed guest only. Do not change the permit to accommodate the replay route. Synthetic DOM clicks or key events alone must reject and leave view and selection unchanged.
5. Repeat with an already-visible target and an oversized target. Compare their landing with the same target reached from a question context link. Do not introduce a zoom option or change `CanvasView.goToShown`. Confirm Navigate Back after each jump.
6. Click both rendered note URL forms, including the encoded key, and capture before, after, and Back. Exercise missing, other-board, and closed targets independently. Require a clear error, no external URL open, and unchanged view and selection on refusal. Exercise component errors and retain the visible title text.
7. Repeat ID, key, Enter, note-link, and Back navigation on a scratch remote board. Record viewer selection/view readback and host object readback. Require viewer-local movement, unchanged host object geometry, and no host navigation RPC. Close the board and require refusal rather than navigation against cached objects.
8. Follow the performance procedure in `../performance.md` on main and the candidate with the same guest, board, build settings, window, and repeated native journey. Retain raw `app.metrics`, stall records, and captures. Require no new main-thread stall of at least 50 ms. Observe the settled source and target while idle and compare timer activity against main; this feature must add no idle timer or polling. Keep failures and unmet preconditions rather than reporting an unmeasured pass.

## Entry points and limits

The kit entry points are `resources/kit/canvas-kit.js` and `resources/kit/canvas-kit.css`. Native validation is in `Sources/CanvasCore/HtmlMessage.swift`; the shared target is `ObjectTarget`, and notes use `NoteLink.object(ObjectTarget)`. Navigation uses unchanged `CanvasView.goToShown` and existing navigation history. There is no zoom argument or policy, no host navigation RPC, and no second gesture mechanism.

A native permit belongs to the current document and is consumed once. A page-reported gesture is not permission. Do not substitute the shorter HTML keyboard-focus grant for the 1.5-second `HtmlGesturePermit`. Do not replace native clicks, Enter, or Navigate Back with DOM activation or direct view mutation and call that proof.

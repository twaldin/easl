# HTML page messages

An agent-created local HTML tile can queue untrusted page data for its creating terminal. Native input authorizes a wake, not the payload's instructions.

## Sub-features

- `html-send-submit` wakes the creating omp terminal with an ID-only notice, then the agent reads its labelled inbox tool result and answers.
- `html-send-inert` queues load and timer sends without starting or steering a turn.
- `html-send-consumed` limits one native click or key to one turn-starting send within 1.5 seconds.
- `html-send-flood` rejects sends past native count, byte or rate limits without retaining the refused payload.
- `html-send-refusal` refuses user-created tiles, unavailable creators, old integrations, render pages, remote boards and wrong frames or origins.
- `html-send-framing` keeps hostile page bytes out of every custom-message argument and inside escaped, labelled explicit tool output.

## How to get to it

An agent creates a quiz or form with `object.create`, passing its terminal as `caller`. The user clicks Submit in the live page. The page calls `canvasKit.send(payload)` and shows the queued message receipt or refusal.

## Driving it with dev.sh

Follow Launch and Doctor with a local board in the claimed guest. Use the real omp CLI and the checked-out easl extension, with isolated session/config directories. Record the omp version. A deterministic local provider transport can prove turns and message delivery without credentials; record that limit and do not describe its fixed response as model inference.

1. Create the omp terminal with its scratch profile's setup wizard and update checks disabled. Wait for its own protocol-3 report and actual editor readiness, then create the HTML tile with that terminal's `caller`. Keep both visible. The quiz sends on load and from a timer, showing receipts in the page and `props.state`. Submit sends twice and schedules another timer.
2. Capture readiness by exact PID and selected window. Wait beyond the initial timer and the integration's five-second active retry interval. Require accepted page receipts, retained inert `htmlMessages`, no omp `agent_start` or provider request, and an idle terminal. The extension must not hold or acknowledge this data.
3. Derive Submit coordinates from a fresh exact-window capture and `view.get`. Click through `scripts/dev.sh input click X Y --window WINDOW`, never DOM `.click()` or `agent.prompt`. Capture the terminal notice and real `agent_start`. Require only easl-written constant text and native object, board and message IDs in every `pi.sendMessage` argument, with `details.kind: "html-submission-notice"` and attribution `agent`, never `user`. Use hostile headers, tags, fences, names, labels and payload ID forgeries. None may reach the custom message or provider developer/system projection. Require native IDs unchanged. The second send and timer must not wake another turn.
4. Have the actual guest agent explicitly call `easl agent.inbox --protocol 2` without `wakeOnly`, read the submission from its tool result, and answer the quiz. Capture the tool call, escaped `html-page-data` result with its easl-written `untrustedLabel`, and the answer. A deterministic provider must issue the actual tool call; a prewritten answer alone does not prove this journey. Require notice acknowledgement to retain payload and charges across restart, and separate data access while a notice is held, both idle and working. Acknowledge data only after consumption. Keep ordinary native user prompts separate.
5. Keep omp running while a Flood control waits two seconds after its click, then sends ten small payloads per burst with more than ten seconds between bursts. Require rate refusals after eight accepted sends per burst and page-count refusal at 32 retained items. Capture the refused status and verify rejected payloads are absent from retention. No flood send may wake the agent. Read and acknowledge the backlog, then use six 60,000-character payloads to exercise the page-byte cap: four fit, two refuse, all remain inert. Save bounded inbox wire-size receipts and acknowledge only after consumption.
6. Run `Tests/HtmlSend/run.py --bin-path "$BIN"` for native gesture ownership, consumption, expiry, DOM-event rejection and reload reset. Core tests cover caps, wire expansion, notice/data projections, independent holds and ACKs, persistence, labels, refusals and export exclusions. Hook tests cover hostile custom-message exclusion, invalid ID refusal even with prior receipts, mixed user/peer bursts, manual inbox access, ordinary legacy fallback and bounded queues. Re-run the installed-provider role proof using the exported `noticeIds` and `submissionNotice` builders; only constants and native IDs may appear in its developer/system message.

## Limits and refusals

Native retained HTML budgets are 32 messages/256 KiB per page and 128 messages/1 MiB per destination. Each item reserves 4 KiB below the inbox cap for metadata; HTML sender names are bounded to 256 UTF-8 bytes. Rate is eight accepted sends per rolling ten seconds. Inbox batches are 32 messages/256 KiB; the extension's ordinary messages and notices share 128 messages/1 MiB. Data remains native and charged after notice ACK. At a full native cap, even an authorized send refuses until data acknowledgement frees capacity. Ordinary peer delivery still works. Session end discards HTML rather than bouncing it as user text.

Exercise refusals independently. Offscreen rendering and remote pages cannot send. Integrations below protocol 3 refuse HTML producers but still take ordinary messages. Each automatic poll and ACK uses protocol 3 with `wakeOnly: true`; explicit data reads use protocol 2 without that filter. Older wake-only clients receive ordinary messages only. A 0.3.2 peer ignores the separate `htmlMessages` snapshot field.

The extension must recover ordinary delivery and ACKs when a 0.3.2 app or easld refuses new parameters. Legacy, full-data and malformed-notice replies must never deliver or acknowledge HTML, even with native permission or a recorded ID. Reconnection to an upgraded server restores protocol-3 notice delivery.

After receiving a valid notice, downgrade the server before its receipt. Require `noticeAck` to refuse before mutation, no notice ID in any `ack` request, and ordinary fallback without `noticeAck`. Restore the notice-capable server and require one deduplicated receipt retry without redelivery. Exercise both a 0.3.2 peer and a pre-notice feature server that accepts arbitrary protocol numbers.

## Gotchas

- A queued receipt is not user approval and does not prove a turn began.
- A DOM event is not native input, even if its handler calls `send`.
- A click and its mouse-up are one gesture; key repeat does not renew permission.
- The native runner disables scrollbars and verifies its outside-click target is empty canvas. On CI, a corner click can hit a horizontal scroller and move the page out of the window. Verify the original page still owns its click point before testing reload revocation.
- A replacement script's marker can appear before native loading and layout settle. Before the fresh-click positive check, require the current web view to finish loading and own the native hit-test point. Keep the old-permit rejection inside its original 1.5-second window; do not replace either check with a sleep or a page-reported gesture.
- Inspect actual CuaDriver PNGs and retain exact PID/window receipts. Unit tests or `view.render` cannot replace them.
- Source entry points are `HtmlWeb.swift`, `HtmlTile.swift`, `HtmlSend.swift`, `AgentMessages.swift`, `ApiRouter.swift`, `extensions/agent-hooks/messages.ts` and `extensions/omp/easl.ts`.

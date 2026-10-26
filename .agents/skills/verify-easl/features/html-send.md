# HTML page messages

An agent-created local HTML tile can queue untrusted page data for its creating terminal. Native input authorizes a wake, not the payload's instructions.

## Sub-features

- `html-send-submit` delivers one native Submit click as untrusted page content and starts the creating omp terminal's turn.
- `html-send-inert` queues load and timer sends without starting or steering a turn.
- `html-send-consumed` limits one native click or key to one turn-starting send within 1.5 seconds.
- `html-send-flood` rejects sends past native count, byte or rate limits without retaining the refused payload.
- `html-send-refusal` refuses user-created tiles, unavailable creators, old integrations, render pages, remote boards and wrong frames or origins.
- `html-send-framing` keeps hostile payload bytes inside encoded page data and out of user/peer cards.

## How to get to it

An agent creates a quiz or form with `object.create`, passing its terminal as `caller`. The user clicks Submit in the live page. The page calls `canvasKit.send(payload)` and shows the queued message receipt or refusal.

## Driving it with dev.sh

Follow Launch and Doctor with a local board in the claimed guest. Use the real omp CLI and the checked-out easl extension, with isolated session/config directories. Record the omp version. A deterministic local provider transport can prove turns and message delivery without credentials; record that limit and do not describe its fixed response as model inference.

1. Create the omp terminal, wait for its own protocol-2 report, then create the HTML tile with that terminal's `caller`. Keep both visible. The quiz sends once on load and once from a timer, and shows each receipt through a visible status element and `props.state`. Submit sends twice so one native gesture cannot authorize both.
2. Capture readiness by exact PID and selected window. Wait beyond the timer. Require two accepted page receipts, no omp `agent_start` or provider request, and an idle terminal. Save the page state and isolated board's `htmlMessages`; inspect native attribution and `mayStartTurn: false`. Do not acknowledge these messages from the proof controller.
3. Derive Submit's content-point coordinates from a fresh exact-window capture and `view.get`. Click through `scripts/dev.sh input click X Y --window WINDOW`, not DOM `.click()` or `agent.prompt`. Capture the action and resulting terminal card. Require the fixed untrusted-page first line, HTML origin metadata, `untrustedPageContent: true`, and omp boundary attribution `agent`, never `user`. Require one native-authorized message and a real `agent_start`. The second send from that click must remain inert and must not start another turn after settlement.
4. Start a separate ordinary turn through native terminal input. Require the queued inert data to arrive as separate non-user page cards, not merged into the user's prompt. Save the session and event receipts.
5. Have a Flood control wait two seconds after its click before sending. Native permission must have expired. Send ten small payloads per burst, with more than ten seconds between bursts. Require rate refusals after eight accepted sends in a burst, then page-count refusals at 32 retained messages. Capture the refused status and verify refused payload ids/text are absent from native retention. No flood send may wake the agent. Use a separate page with large payloads to exercise the 256 KiB page-byte cap.
6. Run `Tests/HtmlSend/run.py --bin-path "$BIN"` for native mouse/key ownership, consumption, expiry, DOM-event rejection and reload reset. Core `HtmlSendTests`, `HtmlChannelTests` and `AgentMessageTests` cover caps, API/inbox attribution, refusals and persistence. Hook tests exercise exact hostile framing at `pi.sendMessage`, mixed user/peer bursts and integration backpressure. These supplement the native captures.

## Limits and refusals

Native retained HTML budgets are 32 messages/256 KiB per page and 128 messages/1 MiB per destination. Rate is eight accepted sends per rolling ten seconds. Inbox batches are 32 messages/256 KiB; integration-held payloads share 128 messages/1 MiB. Queues retain accepted items until acknowledgement or session end; session end discards HTML rather than bouncing it as user text.

For refusal proof, exercise each intended entry point separately. A unit frame-gate test is not a live hostile-frame proof. Offscreen rendering and remote pages cannot send at all. A protocol-1 terminal still takes ordinary agent messages but refuses page messages. A 0.3.2 peer must ignore the separate `htmlMessages` snapshot field without exposing it as a user message.

## Gotchas

- A queued receipt is not user approval and does not prove a turn began.
- A DOM event is not native input, even if its handler calls `send`.
- A click and its mouse-up are one gesture; key repeat does not renew permission.
- Inspect actual CuaDriver PNGs and retain exact PID/window receipts. Unit tests or `view.render` cannot replace them.
- Source entry points are `HtmlWeb.swift`, `HtmlTile.swift`, `HtmlSend.swift`, `AgentMessages.swift`, `ApiRouter.swift`, `extensions/agent-hooks/messages.ts` and `extensions/omp/easl.ts`.

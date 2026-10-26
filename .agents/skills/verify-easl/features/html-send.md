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

1. Create the omp terminal with its scratch profile's setup wizard and update checks disabled. Wait for its own protocol-2 report and actual editor readiness, then create the HTML tile with that terminal's `caller`. Keep both visible. The quiz sends on load and from a timer, showing receipts in the page and `props.state`. Submit sends twice and schedules another two-second timer; a four-second deterministic response keeps the agent working when that timer fires.
2. Capture readiness by exact PID and selected window. Leave omp running. Wait beyond the initial timer and the integration's five-second active retry interval. Require two accepted page receipts, native `htmlMessages` with `mayStartTurn: false`, no omp `agent_start` or provider request, and an idle terminal. The extension must not hold or acknowledge this data.
3. Derive Submit's content-point coordinates from a fresh exact-window capture and `view.get`. Click through `scripts/dev.sh input click X Y --window WINDOW`, not DOM `.click()` or `agent.prompt`. Capture the resulting terminal card. Require the fixed untrusted-page first line, native HTML origin metadata, `untrustedPageContent: true`, and omp boundary attribution `agent`, never `user`. Require one native-authorized message and a real `agent_start`. The second send and timer remain native and must not start another turn after settlement.
4. While the receiver works and after it settles, read the data through a separate public `agent.inbox` request with `protocol: 2` and no `wakeOnly`. Require HTML attribution and false turn permission, save the received data, then acknowledge after consumption. This is the brief's explicit inbox route, not automatic next-turn projection. Also exercise ordinary native terminal input and keep its user prompt separate from page content.
5. Keep omp running while a Flood control waits two seconds after its click, then sends ten small payloads per burst with more than ten seconds between bursts. Require rate refusals after eight accepted sends per burst and page-count refusal at 32 retained items. Capture the refused status and verify rejected payloads are absent from retention. No flood send may wake the agent. Read and acknowledge the backlog, then use six 60,000-character payloads to exercise the page-byte cap: four fit, two refuse, all remain inert. Save bounded inbox wire-size receipts and acknowledge only after consumption.
6. Run `Tests/HtmlSend/run.py --bin-path "$BIN"` for native mouse/key ownership, consumption, expiry, DOM-event rejection and reload reset. Core `HtmlSendTests`, `HtmlChannelTests`, `AgentMessageTests` and `AgentBoardApiTests` cover caps, wire expansion, title growth, inbox progress, refusals, persistence and export exclusions. Hook tests exercise exact hostile framing at `pi.sendMessage`, mixed user/peer bursts, manual idle/working inbox access, full inert backlogs and bounded active-delivery queues.

## Limits and refusals

Native retained HTML budgets are 32 messages/256 KiB per page and 128 messages/1 MiB per destination. Each item reserves 4 KiB below the inbox cap for metadata; HTML sender names are bounded to 256 UTF-8 bytes. Rate is eight accepted sends per rolling ten seconds. Inbox batches are 32 messages/256 KiB; the extension's eligible payloads share 128 messages/1 MiB. Inert pages stay native and occupy no extension hold. At a full native HTML cap, even a new authorized send explicitly refuses until acknowledgement frees capacity; ordinary peer delivery still works. Session end discards native HTML rather than bouncing it as user text.

For refusal proof, exercise each intended entry point separately. A unit frame-gate test is not a live hostile-frame proof. Offscreen rendering and remote pages cannot send at all. A protocol-1 terminal still takes ordinary agent messages but refuses page messages. Every inbox poll and acknowledgement independently opts into protocol 2; legacy requests must not receive HTML even when the saved terminal reports protocol 2. A 0.3.2 peer must ignore the separate `htmlMessages` snapshot field without exposing it as a user message.

## Gotchas

- A queued receipt is not user approval and does not prove a turn began.
- A DOM event is not native input, even if its handler calls `send`.
- A click and its mouse-up are one gesture; key repeat does not renew permission.
- Inspect actual CuaDriver PNGs and retain exact PID/window receipts. Unit tests or `view.render` cannot replace them.
- Source entry points are `HtmlWeb.swift`, `HtmlTile.swift`, `HtmlSend.swift`, `AgentMessages.swift`, `ApiRouter.swift`, `extensions/agent-hooks/messages.ts` and `extensions/omp/easl.ts`.

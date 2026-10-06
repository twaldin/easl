// easl integration for omp. Active only inside an easl terminal tile (EASL_ENV=1).
//  - drains the selection tray into the prompt you submit (hidden context, two-phase so a
//    prompt omp never prepares loses nothing; steering prompts each get their own)
//  - reports lifecycle (working / blocked / idle), each turn's final answer, and session identity for resume
//  - follow mode: forwards files the agent reads, edits, and writes to its follow tile
//  - takes the messages other agents and scripts send this tile (agent.prompt, agent.inbox) and
//    hands them to omp without touching the editor; `write agent://<name>` that omp doesn't know
//    is delivered through easl (docs/contracts.md, Peer messages)
//  - provides the shipped `easl` skill (skills/easl) to the agent, only inside easl
// Load explicitly with `omp -e /path/to/easl.ts`, or install into ~/.omp/agent/extensions.
import { isAbsolute, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { type AgentMessage, CanvasClient, CanvasError } from "../../clients/ts/src/index";
import { numberedDiffChanges } from "../agent-hooks/follow";
import { COALESCE_MS, deliveryText, PROTOCOL, peerAddress, plan, recordedIds, senderKey, WakeBudget } from "../agent-hooks/messages";
import { release, report, watchCanvasReturn } from "../agent-hooks/report";
import { canvasGuidance } from "../guidance";

const SOURCE = "canvas-omp";
const IDLE_DEBOUNCE_MS = 250;
// The inbox's long poll (agent.inbox `waitMs`), and how long a failed poll waits to try again.
const INBOX_WAIT_MS = 55_000;
const INBOX_RETRY_MS = 2_000;
// A message handed to omp that it hasn't recorded this long after, with nothing running or
// queued, never went in (omp couldn't start its turn).
const RECORD_MS = 5_000;
// The session entries that list the messages omp recorded (`{ ids }`), for a restarted omp.
const RECORDED_ENTRY = "easl.messages";
// Marks our wrapper of omp's UI select with the function it wraps (process-wide, across reloads).
const OMP_SELECT = Symbol.for("canvas-omp.select");

type Staged = { prompt: string; ids: string[]; context: string; committed: boolean };
type ToolCall = { name: string; args: Record<string, unknown> | undefined };
type Details = Record<string, any>;
type Select = (this: unknown, title: unknown, ...rest: unknown[]) => Promise<unknown>;

export default function canvas(pi: ExtensionAPI): void {
  const tile = process.env.EASL_TILE_ID;
  if (process.env.EASL_ENV !== "1" || !tile || !process.env.EASL_SOCKET) return;

  const guidance = canvasGuidance("omp", tile);

  // Short timeouts: a missing, wedged, or restarting app must never stall the user's prompt.
  // Lifecycle reports it isn't there to take are spooled for it to replay (agent-hooks/report.ts).
  const client = new CanvasClient({ timeoutMs: 1500, reconnectTimeoutMs: 0 });
  let seq = Date.now() * 1000;
  let active = false;
  // omp runs subagents in this process with this extension rebound to each, headless (no UI).
  // They share our tile, but only the session with a UI is the tile's agent: a subagent's
  // agent_end is not the tile going idle, and its session id is not the one to resume.
  let reporting = false;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  const blockers = new Map<string, string>();
  let approvals = 0;
  const calls = new Map<string, ToolCall>();
  // What each submitted prompt drained, in submission order, until its context is handed back.
  let staged: Staged[] = [];
  // The last answer of the turn that just ended, sent with its idle report (agent.read final),
  // and the error that turn stopped on, if it didn't finish (an API error, an abort).
  let final: string | undefined;
  let failure: string | undefined;

  const quietly = (work: Promise<unknown>) => work.catch(() => undefined);

  function publish(): void {
    if (!reporting) return;
    clearTimeout(idleTimer);
    const firstBlocker = blockers.values().next().value;
    const state = blockers.size > 0 ? "blocked" : active ? "working" : "idle";
    const settled = state === "idle";
    const send = () =>
      report(client, {
        tile: tile!,
        kind: "omp",
        state,
        message: firstBlocker,
        seq: ++seq,
        source: SOURCE,
        final: settled ? final : undefined,
        error: settled ? failure : undefined,
        protocol: PROTOCOL,
      });
    // Debounce idle so retries and tool-only continuations don't flicker the badge.
    if (state === "idle") idleTimer = setTimeout(send, IDLE_DEBOUNCE_MS);
    else void send();
  }

  // A restarted easl holds our last report as `restored` (and refuses prompts to a restored
  // `working`) until we report again: say where we are as soon as it is back.
  watchCanvasReturn(client.socketPath, publish);

  function reportSession(ctx: ExtensionContext): Promise<unknown> {
    if (!reporting) return Promise.resolve();
    return quietly(client.api.agent.report_session({ tile: tile!, kind: "omp", sessionId: ctx.sessionManager.getSessionId(), sessionPath: ctx.sessionManager.getSessionFile() }));
  }

  // omp asks for every tool approval through its UI's select dialog, titled `Allow tool: <name>`.
  // Its tool_approval_requested event comes only from its registered-tool wrapper: eval preludes
  // (the `browser` and `computer` globals inside eval) prompt without any event.
  // So the tile's UI context is watched instead: each approval dialog blocks the tile until the
  // user answers it (approve, deny, or interrupt). `ctx.ui` is a per-handler proxy (trapping only
  // `get`) over the one UI context omp's tools and preludes prompt with, so property descriptors
  // read and defined through it are that object's. A reload rewraps omp's own select, so only the
  // live extension instance reports.
  function watchApprovals(ui: object): void {
    const current = Object.getOwnPropertyDescriptor(ui, "select");
    if (typeof current?.value !== "function") return;
    const base: Select = current.value[OMP_SELECT] ?? current.value;
    const select = async function (this: unknown, title: unknown, ...rest: unknown[]): Promise<unknown> {
      const tool = typeof title === "string" ? /^Allow tool: (.+)$/.exec(title.split("\n", 1)[0])?.[1] : undefined;
      if (!tool) return base.call(this, title, ...rest);
      const key = `approval:${++approvals}`;
      blockers.set(key, `approve ${tool}?`);
      publish();
      try {
        return await base.call(this, title, ...rest);
      } finally {
        blockers.delete(key);
        publish();
      }
    };
    Object.defineProperty(ui, "select", { ...current, value: Object.assign(select, { [OMP_SELECT]: base }) });
  }

  pi.on("session_start", (_event, ctx) => {
    reporting = ctx.hasUI;
    active = !ctx.isIdle();
    final = undefined;
    failure = undefined;
    blockers.clear();
    staged = [];
    if (reporting) watchApprovals(ctx.ui);
    void reportSession(ctx);
    publish();
    if (reporting) {
      adopt(ctx);
      void pollInbox();
    }
  });

  pi.on("session_switch", async (_event, ctx) => {
    // A new or switched-to session starts settled; the old one's pending continuation is gone.
    active = !ctx.isIdle();
    const reported = reportSession(ctx);
    publish();
    if (!reporting) return;
    // Messages easl offers until it has the new session were the old one's: on that report it
    // bounces what the old session never recorded, so none of them go into this one.
    adopt(ctx);
    switching = true;
    await reported;
    switching = false;
    // What this connection held is gone from easl's queue; the next poll takes this session's.
    inbox.close();
  });

  pi.on("session_shutdown", () => {
    // A debounced idle still pending would land after the release (and replay after it).
    clearTimeout(idleTimer);
    if (reporting) void release(client, { tile: tile!, kind: "omp", source: SOURCE }, ++seq);
    // Nothing reports for the released tile again (an easl coming back) until a session starts.
    reporting = false;
    // Ends the long poll; what this session never recorded bounces with the release.
    inbox.close();
  });

  pi.on("agent_start", () => {
    active = true;
    final = undefined;
    failure = undefined;
    staged = staged.filter((entry) => !entry.committed);
    publish();
    // Messages over their senders' wake bound ride this turn, without interrupting it.
    const riding = nextStart;
    nextStart = [];
    send(riding, "aside");
  });

  // willContinue: omp already scheduled the next run (retry, compaction, todo or session_stop
  // continuation, or background jobs whose results will resume it), so this is not a settle.
  pi.on("agent_end", (event) => {
    active = event.willContinue === true;
    if (!active) {
      final = lastAnswer(event.messages);
      failure = turnError(event.messages);
    }
    publish();
    if (!active) setTimeout(releaseAfterTurn, 0);
  });

  // Out-of-band messages (docs/contracts.md, Peer messages): easl queues `agent.prompt` for this
  // tile instead of typing into it, and the root session takes them with one long poll and hands
  // them to omp as user messages, so the editor (a half-typed draft) and an open question or
  // approval stay as they are. A message is acked once omp has recorded it (the user message
  // carrying its header, `message_end`); until then easl keeps it. Polls and acks go over the
  // inbox connection only: what easl answers is held by that connection, and any call on it
  // that fails closes it, so easl offers what it held again.
  const inbox = new CanvasClient({ timeoutMs: INBOX_WAIT_MS + 15_000, reconnectTimeoutMs: 0 });
  const wakes = new WakeBudget();
  // The session (with a UI) messages go into: whether omp streams, or holds queued messages.
  let session: ExtensionContext | undefined;
  // Messages this session took that omp hasn't recorded yet, by id: held below, or handed to omp
  // (`handed`). One easl offers again (a new connection) is not delivered twice.
  const waiting = new Map<string, AgentMessage>();
  // Handed to omp and not recorded yet: whether that delivery started a turn, and when it went.
  const handed = new Map<string, { started: boolean; at: number }>();
  // What omp recorded in this session (its `easl.messages` entries): offered again (easl never
  // took the ack: a lost connection, a restart), it is acked, not delivered.
  let recorded = new Set<string>();
  // `next-turn` messages that came while a turn ran, delivered once it has ended.
  let afterTurn: AgentMessage[] = [];
  // Messages over their senders' wake bound while nothing streams, riding the next turn that starts.
  let nextStart: AgentMessage[] = [];
  // Acks easl didn't take: sent with the next poll.
  let unacked: string[] = [];
  let polling = false;
  // A session switch whose report easl hasn't answered yet: messages arriving meanwhile were the old session's.
  let switching = false;

  // The session messages go into from now: nothing held is for it (easl bounces what the session
  // before never recorded), and what it recorded is in its entries.
  function adopt(ctx: ExtensionContext): void {
    session = ctx;
    waiting.clear();
    handed.clear();
    afterTurn = [];
    nextStart = [];
    recorded = new Set(
      ctx.sessionManager.getEntries().flatMap((entry) => (entry.type === "custom" && entry.customType === RECORDED_ENTRY ? ((entry.data as { ids?: string[] } | undefined)?.ids ?? []) : [])),
    );
  }

  async function pollInbox(): Promise<void> {
    if (polling) return;
    polling = true;
    while (reporting) {
      const ack = unacked;
      unacked = [];
      let first: AgentMessage[];
      try {
        first = (await inbox.api.agent.inbox({ tile: tile!, waitMs: INBOX_WAIT_MS, ack: ack.length ? ack : undefined })).messages;
      } catch {
        unacked.push(...ack);
        inbox.close();
        if (reporting) await Bun.sleep(INBOX_RETRY_MS);
        continue;
      }
      if (first.length === 0) continue;
      // A burst (several senders, or one sending several) goes in as one delivery; a follow-up
      // that fails loses nothing already here.
      await Bun.sleep(COALESCE_MS);
      const more = await inbox.api.agent.inbox({ tile: tile! }).then(
        (reply) => reply.messages,
        () => {
          inbox.close();
          return [];
        },
      );
      receive([...first, ...more]);
    }
    polling = false;
  }

  function receive(messages: readonly AgentMessage[]): void {
    if (switching) return;
    ack(messages.filter((message) => recorded.has(message.id)).map((message) => message.id), false);
    const fresh = messages.filter((message) => !recorded.has(message.id) && !waiting.has(message.id));
    for (const message of fresh) waiting.set(message.id, message);
    deliver(fresh);
  }

  // `started`: their delivery started a turn (agent.wait waits for it), else it joined one.
  function ack(ids: readonly string[], started: boolean): void {
    if (ids.length === 0) return;
    inbox.api.agent.inbox({ tile: tile!, ack: [...ids], started }).then(
      (reply) => receive(reply.messages),
      () => {
        unacked.push(...ids);
        inbox.close();
      },
    );
  }

  // `now`: a steer while omp works (a question or approval keeps waiting, the message comes after
  // it), else a new turn; `next-turn`: held until the running turn ends. A sender past its wake
  // bound joins the step omp is streaming without interrupting it, or waits for the next turn to
  // start (omp idle, or awaiting background work).
  function deliver(messages: readonly AgentMessage[]): void {
    const steer: AgentMessage[] = [];
    const turn: AgentMessage[] = [];
    const aside: AgentMessage[] = [];
    const streaming = session ? !session.isIdle() : active;
    for (const message of messages) {
      switch (plan(message.when, { turn: active, streaming, mayWake: wakes.allows([senderKey(message)]) })) {
        case "steer":
          steer.push(message);
          break;
        case "turn":
          turn.push(message);
          break;
        case "aside":
          aside.push(message);
          break;
        case "after-turn":
          afterTurn.push(message);
          break;
        case "next-start":
          nextStart.push(message);
          break;
      }
    }
    send(steer, "steer");
    send(turn, "turn");
    send(aside, "aside");
  }

  function send(messages: readonly AgentMessage[], how: "steer" | "turn" | "aside"): void {
    if (messages.length === 0) return;
    if (how !== "aside") wakes.spend(new Set(messages.map(senderKey)));
    // A script's message is on the user's behalf: with one among them, the delivery is the user's.
    const attribution = messages.some((message) => message.attribution === "user") ? "user" : "agent";
    // `aside` at an idle omp starts a turn (and stays non-interrupting should a run start meanwhile).
    pi.sendUserMessage(deliveryText(messages), { deliverAs: how === "steer" ? "steer" : "aside", attribution });
    const at = Date.now();
    for (const message of messages) handed.set(message.id, { started: how === "turn", at });
    recordCheck ??= setTimeout(unrecorded, RECORD_MS);
  }

  // omp recorded a user message: the messages whose headers it carries are in its session now.
  // Their ids go into it too (a restarted omp offered them again acks them), then easl gets the ack.
  pi.on("message_end", (event) => {
    const message = event.message as { role?: unknown; content?: unknown };
    if (message.role !== "user" || waiting.size === 0) return;
    const text = typeof message.content === "string" ? message.content : Array.isArray(message.content) ? message.content.map((part) => (part?.type === "text" ? part.text : "")).join("\n") : "";
    const ids = recordedIds(text).filter((id) => waiting.has(id));
    if (ids.length === 0) return;
    const started = ids.filter((id) => handed.get(id)?.started);
    for (const id of ids) {
      waiting.delete(id);
      handed.delete(id);
      recorded.add(id);
    }
    afterTurn = afterTurn.filter((held) => waiting.has(held.id));
    nextStart = nextStart.filter((held) => waiting.has(held.id));
    pi.appendEntry(RECORDED_ENTRY, { ids });
    ack(started, true);
    ack(ids.filter((id) => !started.includes(id)), false);
  });

  // Handed over RECORD_MS ago and still not recorded, with omp neither streaming nor holding
  // queued messages: it never went in (omp couldn't start the turn: no model, say). It goes in
  // with the next turn that starts, the user told; easl keeps it until then.
  let recordCheck: NodeJS.Timeout | undefined;
  function unrecorded(): void {
    recordCheck = undefined;
    if (handed.size === 0 || !session) return;
    if (session.isIdle() && !session.hasPendingMessages()) {
      const due = Date.now() - RECORD_MS;
      const lost = [...handed].filter(([, sent]) => sent.at <= due).map(([id]) => waiting.get(id)!);
      for (const message of lost) handed.delete(message.id);
      nextStart.push(...lost);
      if (lost.length > 0) {
        const senders = [...new Set(lost.map((message) => message.from.address ?? message.from.name))].join(", ");
        const what = lost.length === 1 ? "the message" : `${lost.length} messages`;
        session.ui.notify(`easl: omp started no turn with ${what} from ${senders}; easl keeps ${lost.length === 1 ? "it" : "them"} for the next turn that starts`, "warning");
      }
    }
    if (handed.size > 0) recordCheck = setTimeout(unrecorded, RECORD_MS);
  }

  // The turn ended: held `next-turn` messages go in as a new turn once omp is idle, unless another
  // turn started first (they wait for that one's end).
  function releaseAfterTurn(): void {
    if (active || afterTurn.length === 0) return;
    if (session && !session.isIdle()) {
      setTimeout(releaseAfterTurn, 100);
      return;
    }
    const held = afterTurn;
    afterTurn = [];
    deliver(held);
  }

  // omp's own `write agent://<name>` reaches only agents in this process. One it doesn't know is
  // resolved through easl (a terminal's name, `name@board`, or tile id) and sent as a message;
  // the result then says delivered, receipts included, so omp's card doesn't show a failure.
  pi.on("tool_result", async (event) => {
    if (event.toolName !== "write" || !event.isError) return;
    const target = peerAddress(String(event.input?.path ?? ""));
    const text = typeof event.input?.content === "string" ? event.input.content.trim() : "";
    if (!target || !text) return;
    const native = event.content.map((part) => (part.type === "text" ? part.text : "")).join("\n");
    if (!native.includes("Unknown agent")) return;
    try {
      const sent = await client.api.agent.prompt({ target, text, caller: tile });
      const address = sent.agent.address;
      const message = (event.details as Details | undefined)?.message;
      const details = Array.isArray(message?.receipts)
        ? { ...(event.details as Details), message: { ...message, receipts: message.receipts.map((receipt: Details) => ({ to: receipt.to, outcome: "injected" })) } }
        : event.details;
      const how =
        sent.delivery === "message"
          ? `It arrives as a message from you; replies come back as messages from ${address}.`
          : `Its agent takes no messages, so the text was typed into its terminal.`;
      return { isError: false, details, content: [{ type: "text", text: `Delivered to ${address}, an agent on an easl board. ${how}` }] };
    } catch (error) {
      const reason = error instanceof CanvasError ? `${error.code}: ${error.message}` : String(error);
      return { content: [{ type: "text", text: `${native}\nNo easl delivery to ${target} either: ${reason}` }] };
    }
  });

  // Tray drain, phase 1: peek the tray when the user actually submits prose. With `prompt`, this
  // is the submission drain: a prompt easl's composer typed here takes its own mentions instead.
  // Each submission keeps what it drained: prompts submitted while omp works (steering) wait in
  // its queue, each with its own.
  pi.on("input", async (event) => {
    if (event.source !== "interactive") return;
    const text = event.text.trim();
    if (!text || /^[/!$]/.test(text)) return; // slash commands and shell escapes aren't prompts
    staged = staged.filter((entry) => !entry.committed);
    try {
      const drained = await client.api.tray.drain({ peek: true, prompt: text });
      if (!drained.context) return;
      const ids = drained.mentions.map((m) => m.id);
      // The tray goes with the latest prompt that peeked it, as one staged prompt did.
      staged = staged.filter((entry) => entry.ids.join() !== ids.join());
      staged.push({ prompt: text, ids, context: drained.context, committed: false });
    } catch {
      // app not running: prompt proceeds untouched
    }
  });

  // Phase 2: attach the staged mentions as hidden, user-attributed context to the prompts they
  // were drained for, and commit them as that context is handed back. omp prepares a queued
  // (steering) prompt through before_agent_start too, joining the queued prompts' text, but takes
  // it inside the running turn with no agent_start (oh-my-pi v18.6.1
  // packages/coding-agent/src/session/agent-session.ts #prepareQueuedUserMessages L7301-L7331, its before_agent_start L7362;
  // packages/agent/src/agent-loop.ts L1317-L1324), so committing at agent_start would leave a
  // steering prompt's mentions uncommitted. A retried preparation gets the same context again.
  pi.on("before_agent_start", (event) => {
    const systemPrompt = [...event.systemPrompt, guidance];
    const delivered = staged.filter((entry) => event.prompt.includes(entry.prompt));
    if (delivered.length === 0) return { systemPrompt };
    const ids = delivered.flatMap((entry) => entry.ids);
    const fresh = delivered.filter((entry) => !entry.committed).flatMap((entry) => entry.ids);
    for (const entry of delivered) entry.committed = true;
    if (fresh.length > 0) void quietly(client.api.tray.commit({ ids: fresh }));
    return {
      systemPrompt,
      message: { customType: "canvas.mentions", content: delivered.map((entry) => entry.context).join("\n"), display: false, attribution: "user", details: { ids } },
    };
  });

  // Follow mode and ask-blocking. Top-level xd:// writes wrap mounted tools such as ask and lsp.
  pi.on("tool_execution_start", (event) => {
    let call: ToolCall = { name: event.toolName, args: event.args as Record<string, unknown> | undefined };
    const path = call.args?.path;
    if (call.name === "write" && typeof path === "string" && path.startsWith("xd://")) {
      try {
        call = { name: path.slice(5), args: JSON.parse(String(call.args?.content)) };
      } catch {
        // help/doc read of a device, not an executable call
      }
    }
    calls.set(event.toolCallId, call);
    if (call.name === "ask") {
      const questions = call.args?.questions as Array<{ question?: string }> | undefined;
      blockers.set(`ask:${event.toolCallId}`, questions?.[0]?.question ?? "waiting for your answer");
      publish();
    }
    if (call.name === "lsp" && typeof call.args?.file === "string") {
      const line = typeof call.args.line === "number" ? call.args.line : undefined;
      follow(call.args.file, line, line, "lsp");
    }
  });

  pi.on("tool_execution_end", (event) => {
    const call = calls.get(event.toolCallId);
    calls.delete(event.toolCallId);
    if (blockers.delete(`ask:${event.toolCallId}`)) publish();
    if (event.isError) return;
    const outer = (event.result as { details?: Details } | undefined)?.details;
    const name: string = outer?.xdev?.tool ?? call?.name ?? event.toolName;
    const details: Details | undefined = outer?.xdev?.inner ?? outer;
    if (!details) return;
    if (name === "read" && !details.isDirectory) {
      const path = details.displayTarget ?? details.resolvedPath ?? (details.meta?.source?.type === "path" ? details.meta.source.value : undefined);
      const numbers = (details.displayContent?.lineNumbers as Array<number | null> | undefined)?.filter((n): n is number => typeof n === "number");
      const start = numbers?.[0] ?? details.displayContent?.startLine;
      if (typeof path === "string") follow(path, start, numbers?.at(-1) ?? start, "read");
    }
    if (name === "edit") {
      for (const file of (details.perFileResults as Details[] | undefined) ?? [details]) {
        if (typeof file.path !== "string" || file.isError) continue;
        // Every hunk, so the tile flashes them all and aims at the largest, not at the first.
        const changes = numberedDiffChanges(file.diff);
        if (changes.length) follow(file.path, undefined, undefined, "edit", changes);
        else follow(file.path, file.firstChangedLine, file.firstChangedLine, "edit");
      }
    }
    // New files and overwrites: the tile jumps to what changed and flashes it.
    const written = call?.args?.path;
    if (name === "write" && typeof written === "string" && !written.startsWith("xd://")) follow(written, undefined, undefined, "write");
  });

  function follow(path: string, start: unknown, end: unknown, action: "read" | "edit" | "write" | "lsp", changes?: Array<{ start: number; end: number }>): void {
    // Subagents' reads (background scouts) would drag the tile's follow view around.
    if (!reporting) return;
    const absolute = isAbsolute(path) ? path : resolve(process.cwd(), path.replace(/:[\d+\-,]+$/, ""));
    const range = typeof start === "number" && start > 0 ? { start, end: typeof end === "number" && end >= start ? end : start } : undefined;
    void quietly(client.api.follow.report({ tile: tile!, path: absolute, range, changes, action }));
  }
}

/** The text of the run's last assistant message (omp's own Stop reading); none when it has no text (an abort). */
function lastAnswer(messages: readonly { role?: unknown; content?: unknown }[]): string | undefined {
  const last = messages.findLast((message) => message.role === "assistant");
  if (!last || !Array.isArray(last.content)) return undefined;
  const text = last.content.filter((part) => part?.type === "text" && typeof part.text === "string").map((part) => part.text).join("");
  return text.trim() ? text : undefined;
}

/** Why the run's last assistant message stopped short: omp's `stopReason` error (with its message), an abort, or the output limit; none for a finished answer. */
function turnError(messages: readonly { role?: unknown; stopReason?: unknown; errorMessage?: unknown }[]): string | undefined {
  const last = messages.findLast((message) => message.role === "assistant");
  switch (last?.stopReason) {
    case "error":
      return typeof last.errorMessage === "string" && last.errorMessage.trim() ? last.errorMessage.trim() : "the model request failed";
    case "aborted":
      return "interrupted";
    case "length":
      return "stopped at the output token limit";
    default:
      return undefined;
  }
}

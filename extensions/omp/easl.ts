// easl integration for omp. Active only inside an easl terminal tile (EASL_ENV=1).
//  - drains the selection tray into the prompt you submit (hidden context, two-phase so a
//    prompt omp never prepares loses nothing; steering prompts each get their own)
//  - reports lifecycle (working / blocked / idle), each turn's final answer, and session identity for resume
//  - reports what agent.restart needs: the model and thinking level, whether the editor holds an
//    unsent draft, and omp's pid
//  - adds the board's standing orders (its note keyed `rules`, read each turn) to the system prompt
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
import { COALESCE_MS, card, EASL_MESSAGE, GUIDANCE_BLOCK, guided, PROTOCOL, peerAddress, plan, recordedIds, renderCard, sender, senderKey, WakeBudget } from "../agent-hooks/messages";
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
// How often the editor, model and thinking level are looked at (agent.report `draft`,
// agent.report_session `model`, `thinking`), and how long an unacknowledged session report waits
// before it is sent again.
const RECONCILE_MS = 500;
const SESSION_RETRY_MS = 10_000;
// When this omp process started: thinking selectors it recorded itself are later than this.
const STARTED_AT = Date.now() - process.uptime() * 1000;
// Process-wide, so it outlives an extension reload: the `--thinking` omp was launched with
// (`--thinking=<v>` or `--thinking <v>`), the session it launched with, and whether the tile's
// agent has switched sessions since. omp runs that option until a change is recorded, and only in
// that first activation: a session switched to (back to the launch one too) runs what it recorded.
const LAUNCH = Symbol.for("canvas-omp.launch");
type Launch = { thinking?: string; session?: string; switched: boolean };
// The board's standing orders: its note with this key, injected up to this many UTF-8 bytes.
const RULES_KEY = "rules";
const RULES_MAX_BYTES = 8192;
// Marks our wrapper of omp's UI select with the function it wraps (process-wide, across reloads).
const OMP_SELECT = Symbol.for("canvas-omp.select");

type Staged = { prompt: string; ids: string[]; context: string; committed: boolean };
type ToolCall = { name: string; args: Record<string, unknown> | undefined };
type Details = Record<string, any>;
type Select = (this: unknown, title: unknown, ...rest: unknown[]) => Promise<unknown>;
// What the agent runs, as agent.report_session `model` and `thinking` say it.
type RunsWith = { model?: string; thinking?: string };
// A `thinking_level_change` entry of omp's session, as the extension reads it.
type ThinkingChange = { timestamp: string; thinkingLevel?: string | null; configured?: string | null };

export default function canvas(pi: ExtensionAPI): void {
  const tile = process.env.EASL_TILE_ID;
  if (process.env.EASL_ENV !== "1" || !tile || !process.env.EASL_SOCKET) return;

  const guidance = canvasGuidance("omp", tile);
  // Messages from other agents and scripts look as omp's own IRC messages (Peer messages, below).
  pi.registerMessageRenderer(EASL_MESSAGE, renderCard);

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
        draft,
        pid: process.pid,
      });
    // Debounce idle so retries and tool-only continuations don't flicker the badge.
    if (state === "idle") idleTimer = setTimeout(send, IDLE_DEBOUNCE_MS);
    else void send();
  }

  // A restarted easl holds our last report as `restored` (and refuses prompts to a restored
  // `working`) until we report again: say where we are as soon as it is back, and what the agent
  // runs, which it may never have taken.
  watchCanvasReturn(client.socketPath, () => {
    publish();
    if (sessionCtx) void reportSession(sessionCtx);
  });

  // agent.restart relaunches the tile's agent with the model and thinking selector it runs
  // (agent.report_session `model`, `thinking`; omp's --model=<provider/id> --thinking=<level>),
  // and refuses while the editor may hold text the user hasn't sent (agent.report `draft`). omp
  // says nothing when they change: its editor is written by keys and by omp itself (a Ctrl+D
  // draft restored after session_start, the external editor's text), and /model and the thinking
  // toggle fire no extension event. So the session's context is looked at every RECONCILE_MS
  // while it runs: a draft that comes or goes reports (publish), and a model or selector easl
  // hasn't acknowledged is sent, again every SESSION_RETRY_MS until easl takes it.
  let sessionCtx: ExtensionContext | undefined;
  let reconciling: NodeJS.Timeout | undefined;
  // Undefined (left out of reports): no editor to look at (no UI, or not omp's TUI).
  let draft: boolean | undefined;
  // What easl acknowledged last (none while a report is out: one may apply without its answer
  // arriving, so what easl has is unknown until one is acknowledged), and what the last session
  // report sent and when.
  let acked: RunsWith | undefined;
  let tried: RunsWith | undefined;
  let triedAt = 0;
  const launch = ((globalThis as unknown as Record<symbol, Launch | undefined>)[LAUNCH] ??= { thinking: launchOption(process.argv, "--thinking"), switched: false });

  function reportSession(ctx: ExtensionContext): Promise<unknown> {
    if (!reporting) return Promise.resolve();
    const runs = runsWith(ctx);
    tried = runs;
    triedAt = Date.now();
    acked = undefined;
    const params = { tile: tile!, kind: "omp", sessionId: ctx.sessionManager.getSessionId(), sessionPath: ctx.sessionManager.getSessionFile(), ...runs };
    return client.api.agent.report_session(params).then(
      () => {
        // A later report's answer is the one that counts.
        if (tried === runs) acked = runs;
      },
      () => undefined,
    );
  }

  /** Starts looking at `ctx`, the session the tile's agent runs now (session start and switch). */
  function watchSession(ctx: ExtensionContext): void {
    sessionCtx = reporting ? ctx : undefined;
    draft = sessionCtx ? editorDraft(sessionCtx) : undefined;
    acked = tried = undefined;
    if (!sessionCtx) return stopWatchingSession();
    if (reconciling) return;
    reconciling = setInterval(reconcile, RECONCILE_MS);
    reconciling.unref();
  }

  function stopWatchingSession(): void {
    clearInterval(reconciling);
    reconciling = undefined;
    sessionCtx = undefined;
    draft = undefined;
  }

  function reconcile(): void {
    const ctx = sessionCtx;
    if (!reporting || !ctx) return;
    const now = editorDraft(ctx);
    if (now !== draft) {
      draft = now;
      publish();
    }
    const runs = runsWith(ctx);
    if (acked?.model === runs.model && acked?.thinking === runs.thinking) return;
    const changed = tried?.model !== runs.model || tried?.thinking !== runs.thinking;
    if (changed || Date.now() - triedAt >= SESSION_RETRY_MS) void reportSession(ctx);
  }

  /** Whether the editor holds anything but whitespace; undefined when there is none to read. */
  function editorDraft(ctx: ExtensionContext): boolean | undefined {
    if (ctx.mode !== "tui") return undefined;
    try {
      return /\S/.test(ctx.ui.getEditorText());
    } catch {
      return undefined;
    }
  }

  function runsWith(ctx: ExtensionContext): RunsWith {
    const model = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
    return { model, thinking: thinkingSelector(ctx) };
  }

  // omp's thinking selector, what `--thinking=` takes, `auto` kept: pi.getThinkingLevel() is the
  // effort auto chose, which as `--thinking` would turn auto off. omp records each change of
  // selector on the session's branch (`thinking_level_change`: `configured`, else
  // `thinkingLevel`), auto's choices included, but not the one a session starts with: the
  // `--thinking` omp was launched with while the launch session is the first one the agent runs
  // (`launch`), else the session's last recorded one. Undefined when nothing says (a new session
  // at omp's default auto, before its first turn): easl keeps what it had, and a relaunch what
  // its command gave.
  function thinkingSelector(ctx: ExtensionContext): string | undefined {
    let last: ThinkingChange | undefined;
    try {
      last = lastThinkingChange(ctx);
    } catch {
      return undefined;
    }
    const recorded = last ? (last.configured ?? last.thinkingLevel ?? undefined) : undefined;
    if (last && Date.parse(last.timestamp) >= STARTED_AT) return recorded;
    if (launch.thinking && !launch.switched && ctx.sessionManager.getSessionId() === launch.session) return launch.thinking;
    return recorded;
  }

  // The branch's newest thinking_level_change as of a leaf (its session and entry id). The branch
  // is read from its leaf back to that change, or to the leaf read last time: a check that finds
  // the same leaf reads nothing, and one after the session grew reads only what was added, so
  // the RECONCILE_MS checks cost the same however long the session is.
  let thinkingScan: { session: string; leaf: string | null; change?: ThinkingChange } | undefined;

  function lastThinkingChange(ctx: ExtensionContext): ThinkingChange | undefined {
    const manager = ctx.sessionManager;
    const session = manager.getSessionId();
    const leaf = manager.getLeafId();
    const known = thinkingScan?.session === session ? thinkingScan : undefined;
    if (known && known.leaf === leaf) return known.change;
    let change: ThinkingChange | undefined;
    for (let entry = manager.getLeafEntry(); entry; entry = entry.parentId ? manager.getEntry(entry.parentId) : undefined) {
      if (known && entry.id === known.leaf) {
        change = known.change;
        break;
      }
      if (entry.type === "thinking_level_change") {
        change = entry;
        break;
      }
    }
    thinkingScan = { session, leaf, change };
    return change;
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
    if (reporting) launch.session ??= ctx.sessionManager.getSessionId();
    watchSession(ctx);
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
    if (reporting) launch.switched = true;
    watchSession(ctx);
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
    stopWatchingSession();
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
      // The next turn is prepared only if omp prepares it; it reads the standing orders afresh.
      prepared = false;
      policy = undefined;
    }
    publish();
    if (!active) setTimeout(releaseAfterTurn, 0);
  });

  // Out-of-band messages (docs/contracts.md, Peer messages): easl queues `agent.prompt` for this
  // tile instead of typing into it, and the root session takes them with one long poll and hands
  // them to omp as cards (easl's own custom messages, drawn as omp draws its IRC messages), so the
  // editor (a half-typed draft) and an open question or approval stay as they are, and the
  // session tells them from the user's prompts. A message is acked once omp has recorded it (the
  // card carrying its id, `message_end`); until then easl keeps it. Polls and acks go over the
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
  // omp starts a turn with a card without preparing it (no before_agent_start: AgentSession
  // #promptAgentInitiatedMessage, and the wake of a card left in its queue at a run's end,
  // #wakeForIrc; oh-my-pi v18.6.1 packages/coding-agent/src/session/agent-session.ts L8209-L8229,
  // L1206-L1268), so with the system prompt as the last prepared turn left it: without the
  // guidance and standing orders that hook adds, or with standing orders since changed. So every
  // card's id is marked, and until omp next prepares a turn, each request of a turn it didn't
  // prepare gets the guidance and the standing orders as they are now (read once a turn) as
  // hidden context, just before the first marked card (`guided`), in the block the standing
  // orders of the system prompt defer to (`standingOrders`, `guidanceBlock`). `prepared`: omp
  // prepared the turn running now; a card that starts a run ends it.
  const marked = new Set<string>();
  let prepared = false;
  let policy: Promise<string> | undefined;
  // omp deep-copies every request's context once any extension listens for it (`context`), so
  // this one listens from the first card on.
  let listening = false;

  // The session messages go into from now: nothing held is for it (easl bounces what the session
  // before never recorded), and what it recorded is in its entries.
  function adopt(ctx: ExtensionContext): void {
    session = ctx;
    waiting.clear();
    handed.clear();
    afterTurn = [];
    nextStart = [];
    marked.clear();
    prepared = false;
    policy = undefined;
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
    const ids = messages.map((message) => message.id);
    // `steer` and `turn` go in as a steer: at the running turn's next step, an interruptible wait
    // cut short. An omp streaming nothing (idle, or awaiting background work) starts a turn with
    // the card instead (`triggerTurn`), one it doesn't prepare: whatever omp prepared before (a
    // turn now paused, a preparation the user cancelled) is over. `aside` joins the step omp
    // streams without interrupting it.
    if (session ? session.isIdle() : !active) {
      prepared = false;
      policy = undefined;
    }
    mark(ids);
    pi.sendMessage(card(messages), how === "aside" ? { deliverAs: "aside" } : { deliverAs: "steer", triggerTurn: true });
    const at = Date.now();
    for (const id of ids) handed.set(id, { started: how === "turn", at });
    recordCheck ??= setTimeout(unrecorded, RECORD_MS);
  }

  // A card may start a turn omp doesn't prepare: now, or by being left in omp's queue at a run's
  // end. Such a turn's requests get the guidance and standing orders before_agent_start would
  // have put in its system prompt, in the block that system prompt's standing orders defer to.
  function mark(ids: readonly string[]): void {
    for (const id of ids) marked.add(id);
    if (listening) return;
    listening = true;
    pi.on("context", async (event) => {
      if (prepared || marked.size === 0) return;
      policy ??= boardRules(client).then((rules) => guidanceBlock(guidance, rules));
      return { messages: guided(event.messages, marked, await policy) };
    });
  }

  // omp recorded a message: the easl messages it carries (a card, or a user message with a card's
  // text omp put back in the editor) are in its session now. Their ids go into it too (a restarted
  // omp offered them again acks them), then easl gets the ack.
  pi.on("message_end", (event) => {
    if (waiting.size === 0) return;
    const ids = [...new Set(recordedIds(event.message))].filter((id) => waiting.has(id));
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
        for (const message of lost) marked.delete(message.id);
        const senders = [...new Set(lost.map(sender))].join(", ");
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
  pi.on("before_agent_start", async (event) => {
    // omp prepares this turn: its system prompt has the guidance and standing orders.
    prepared = true;
    marked.clear();
    policy = undefined;
    const rules = await boardRules(client);
    const systemPrompt = [...event.systemPrompt, guidance, ...(rules ? [standingOrders(rules)] : [])];
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

/**
 * The board's standing orders: the markdown of the note keyed `rules` on this tile's board, read
 * fresh each turn and cut to RULES_MAX_BYTES. null when the board has none (no such note, it
 * isn't a note, or is empty); undefined when easl doesn't say (no board, or the app doesn't answer
 * in time): a prompt never waits on it or fails for it.
 */
async function boardRules(client: CanvasClient): Promise<string | null | undefined> {
  const board = process.env.EASL_BOARD_ID;
  if (!board) return undefined;
  let markdown: unknown;
  try {
    const found = await client.api.object.find({ board, key: RULES_KEY });
    if (found.object?.type !== "note") return null;
    markdown = found.object.props.markdown;
  } catch (error) {
    return error instanceof CanvasError && error.code === "not_found" ? null : undefined;
  }
  return typeof markdown === "string" && markdown.trim() ? capBytes(markdown.trim(), RULES_MAX_BYTES) : null;
}

/**
 * The board's standing orders (`boardRules`) as a system prompt entry. A turn omp starts without
 * preparing it keeps this system prompt, so the entry defers to the `guidanceBlock` easl gives
 * such a turn, which has them as they are then.
 */
function standingOrders(rules: string): string {
  return `Standing orders for this board (its note keyed \`${RULES_KEY}\` as of this prompt; the user and the board's chief of staff edit it). Follow them. A later <${GUIDANCE_BLOCK}> block that gives this board's standing orders, or says it has none, supersedes these.\n\n${rules}`;
}

/**
 * easl's guidance and the board's standing orders as they are now (`boardRules`; nothing about
 * them when easl doesn't answer), in the block the standing orders of a system prompt easl
 * prepared defer to: hidden context for a turn omp didn't prepare.
 */
function guidanceBlock(guidance: string, rules: string | null | undefined): string {
  const orders =
    rules === undefined
      ? ""
      : rules === null
        ? `\n\nThis board has no standing orders now (no note keyed \`${RULES_KEY}\`): any in your system prompt no longer apply.`
        : `\n\nStanding orders for this board (its note keyed \`${RULES_KEY}\` as of now; the user and the board's chief of staff edit it). They supersede any in your system prompt. Follow them:\n\n${rules}`;
  return `<${GUIDANCE_BLOCK}>\n${guidance}${orders}\n</${GUIDANCE_BLOCK}>`;
}

/** `text` cut to at most `max` UTF-8 bytes on a character boundary, with a notice when it was cut. */
function capBytes(text: string, max: number): string {
  const bytes = Buffer.from(text, "utf8");
  if (bytes.length <= max) return text;
  let end = max;
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--; // a continuation byte: its character started before the cut
  return `${bytes.subarray(0, end).toString("utf8")}\n\n[Cut here: the note is ${bytes.length} bytes and only its first ${end} are shown. \`easl object.find --key ${RULES_KEY}\` reads it whole.]`;
}

/** The value of `option` on a command line (`--name=<v>` or `--name <v>`, the last one given, before any `--`); undefined when absent. */
function launchOption(argv: readonly string[], option: string): string | undefined {
  let value: string | undefined;
  for (let i = 0; i < argv.length && argv[i] !== "--"; i++) {
    if (argv[i].startsWith(`${option}=`)) value = argv[i].slice(option.length + 1);
    else if (argv[i] === option && i + 1 < argv.length) value = argv[++i];
  }
  return value || undefined;
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

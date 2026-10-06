// bun test extensions/agent-hooks — omp's extension (extensions/omp/easl.ts) taking peer messages
// (docs/contracts.md, Peer messages) and reporting what agent.restart relaunches with (Agent
// control), driven through its omp seam (a fake `pi` and session) against a fake easl that answers
// agent.inbox on a Unix socket as the app does: a message offered to a connection is held by it
// until acked or until it closes. The clock is fake: it moves only while a test waits for
// something (`until`), so the extension's coalescing, retry, record and reconcile checks run
// without real waits.
import { afterEach, beforeEach, expect, test, vi } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import type { AgentMessage } from "../../clients/ts/src/index";
import canvas from "../omp/easl";

const TILE = "obj_bob";
const ALICE = { tile: "obj_alice", name: "alice", address: "alice@canvas", board: "brd_c" };

type Params = Record<string, any>;
type Wire = { write(data: string): unknown };
type Handler = (event: Params, ctx: unknown) => unknown;

const cleanups: (() => unknown)[] = [];
beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(async () => {
  vi.useRealTimers();
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

let sent = 0;
function message(text: string, from: AgentMessage["from"] = ALICE): AgentMessage {
  return { id: `msg_${++sent}`, text, from, attribution: from.tile ? "agent" : "user", when: "now", queuedAt: new Date().toISOString() };
}

/** One turn of the event loop (socket IO runs; the fake clock stands still). */
async function turn(): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>();
  setImmediate(resolve);
  await promise;
}

/** Lets IO run and the fake clock move 5 ms a turn until `check` holds, failing past `limitMs` of it. */
async function until(check: () => boolean, limitMs = 10_000): Promise<void> {
  for (let waited = 0; !check(); waited += 5) {
    if (waited > limitMs) throw new Error(`still not so after ${limitMs} ms`);
    await turn();
    vi.advanceTimersByTime(5);
  }
}

/** easl's side for one terminal: the queue, which connection holds what, every call and ack. */
function fakeEasl() {
  const dir = mkdtempSync(join(tmpdir(), "easl-omp-"));
  const socketPath = join(dir, "easl.sock");
  const easl = {
    socketPath,
    queue: [] as AgentMessage[],
    calls: [] as { connection: number; method: string; params: Params }[],
    acks: [] as { connection: number; ids: string[]; started: boolean }[],
    closed: [] as number[],
    bounced: [] as AgentMessage[],
    /** Fails the next agent.inbox call it matches, after offering (holding) what waits, as a reply lost to a timeout. */
    failing: undefined as ((params: Params) => boolean) | undefined,
    /** Holds agent.report_session's answer back until it resolves. */
    sessionReported: undefined as Promise<void> | undefined,
    /** Fails the next agent.report_session call it matches after applying it, as a reply lost to a timeout. */
    failingSession: undefined as ((params: Params) => boolean) | undefined,
    send(queued: AgentMessage): void {
      easl.queue.push(queued);
      const waiter = waiters.findIndex((w) => open.has(w.connection));
      if (waiter < 0) return;
      const [w] = waiters.splice(waiter, 1);
      answer(w.socket, w.id, { messages: offer(w.connection) });
    },
    /** A long poll waits for the next message. */
    polling(): boolean {
      return waiters.some((w) => open.has(w.connection));
    },
    /** Connections that sent agent.inbox, and those that sent anything else. */
    connections(inbox: boolean): Set<number> {
      return new Set(easl.calls.filter((call) => (call.method === "agent.inbox") === inbox).map((call) => call.connection));
    },
    /** agent.inbox calls that take messages (long polls, a burst's follow-up), not bare acks. */
    polls(): number {
      return easl.calls.filter((call) => call.method === "agent.inbox" && !(call.params.ack?.length > 0 && !call.params.waitMs)).length;
    },
  };
  const holds = new Map<string, number>();
  const open = new Set<number>();
  let waiters: { connection: number; id: string; socket: Wire }[] = [];
  let sessionId: string | undefined;
  const offer = (connection: number) => {
    const free = easl.queue.filter((queued) => !open.has(holds.get(queued.id) ?? -1));
    for (const queued of free) holds.set(queued.id, connection);
    return free;
  };
  const answer = (socket: Wire, id: string, result: unknown) => socket.write(`${JSON.stringify({ id, ok: true, result })}\n`);
  async function handle(connection: number, socket: Wire, line: string): Promise<void> {
    const { id, method, params } = JSON.parse(line) as { id: string; method: string; params: Params };
    easl.calls.push({ connection, method, params });
    if (method === "agent.report_session") {
      await easl.sessionReported;
      // Another session took the tile: what the old one never took bounces.
      if (sessionId !== undefined && params.sessionId !== sessionId) easl.bounced.push(...easl.queue.splice(0));
      sessionId = params.sessionId;
      if (easl.failingSession?.(params)) {
        easl.failingSession = undefined;
        return void socket.write(`${JSON.stringify({ id, ok: false, error: { code: "timeout", message: "agent.report_session timed out" } })}\n`);
      }
    }
    if (method !== "agent.inbox") return void answer(socket, id, {});
    const acked: string[] = params.ack ?? [];
    if (easl.failing?.(params)) {
      easl.failing = undefined;
      offer(connection);
      return void socket.write(`${JSON.stringify({ id, ok: false, error: { code: "timeout", message: "agent.inbox timed out" } })}\n`);
    }
    if (acked.length > 0) {
      easl.queue = easl.queue.filter((queued) => !acked.includes(queued.id));
      easl.acks.push({ connection, ids: acked, started: params.started === true });
    }
    const offered = offer(connection);
    if (offered.length === 0 && (params.waitMs ?? 0) > 0) waiters.push({ connection, id, socket });
    else answer(socket, id, { messages: offered });
  }
  let connections = 0;
  const lines = new Map<unknown, { connection: number; buffer: string }>();
  const server = Bun.listen({
    unix: socketPath,
    socket: {
      open(socket) {
        lines.set(socket, { connection: ++connections, buffer: "" });
        open.add(connections);
      },
      data(socket, data) {
        const state = lines.get(socket)!;
        const text = state.buffer + data.toString();
        const parts = text.split("\n");
        state.buffer = parts.pop()!;
        for (const line of parts.filter(Boolean)) void handle(state.connection, socket, line);
      },
      // A client that ends its side is gone, as the app treats the end of its input.
      end(socket) {
        socket.end();
      },
      close(socket) {
        const state = lines.get(socket)!;
        open.delete(state.connection);
        easl.closed.push(state.connection);
        waiters = waiters.filter((w) => w.connection !== state.connection);
      },
    },
  });
  cleanups.push(() => {
    server.stop(true);
    rmSync(dir, { recursive: true, force: true });
  });
  return easl;
}

/** omp with the extension loaded, its root session (with a UI) idle until `state` says otherwise. */
function fakeOmp(easl: { socketPath: string }, entries: Params[] = [], sessionId = "ses_1") {
  Object.assign(process.env, { EASL_ENV: "1", EASL_TILE_ID: TILE, EASL_SOCKET: easl.socketPath });
  const handlers = new Map<string, Handler[]>();
  const state = { streaming: false, pending: false, sessionId };
  const omp = {
    state,
    entries,
    delivered: [] as { text: string; deliverAs?: string; attribution?: string }[],
    notices: [] as string[],
    /** Each session's branch, root first (`grow`). */
    branches: {} as Record<string, Params[]>,
    /** The branch of the session omp runs now. */
    branch(): Params[] {
      return (omp.branches[state.sessionId] ??= []);
    },
    ctx: {
      hasUI: true,
      /** What `ctx.model` says now; the extension reads it as it reconciles. */
      model: undefined as { provider: string; id: string } | undefined,
      isIdle: () => !state.streaming,
      hasPendingMessages: () => state.pending,
      sessionManager: {
        getEntries: () => entries,
        getSessionId: () => state.sessionId,
        getSessionFile: () => `/tmp/${state.sessionId}.jsonl`,
        getBranch: (): Params[] => omp.branch(),
      },
      ui: { notify: (text: string) => omp.notices.push(text), select: async () => undefined },
    },
    async emit(event: string, payload: Params = {}): Promise<void> {
      for (const handler of handlers.get(event) ?? []) await handler({ type: event, ...payload }, omp.ctx);
    },
    /** omp records a user message with this text (its `message_end`). */
    record(text: string): Promise<void> {
      return omp.emit("message_end", { message: { role: "user", content: [{ type: "text", text }], attribution: "agent", timestamp: Date.now() } });
    },
  };
  const pi = {
    on: (event: string, handler: Handler) => handlers.set(event, [...(handlers.get(event) ?? []), handler]),
    sendUserMessage: (text: string, options: Params = {}) => omp.delivered.push({ text, ...options }),
    appendEntry: (customType: string, data: unknown) => entries.push({ type: "custom", customType, data }),
  };
  canvas(pi as unknown as ExtensionAPI);
  cleanups.push(() => omp.emit("session_shutdown"));
  return omp;
}

test("a message is acked once omp records it, over the inbox connection; a restarted omp acks one offered again", async () => {
  const easl = fakeEasl();
  const omp = fakeOmp(easl);
  await omp.emit("session_start");
  const sent = message("Check the cache key.");
  easl.send(sent);
  await until(() => omp.delivered.length === 1);
  const [delivered] = omp.delivered;
  expect(delivered.text.startsWith(`[message ${sent.id} from alice@canvas (terminal obj_alice); reply with write agent://alice@canvas]\nCheck the cache key.`)).toBe(true);
  expect(delivered.deliverAs).toBe("aside");
  // Handed over is not recorded: easl keeps it (the poll after the burst's follow-up is out by now).
  await until(() => easl.polls() === 3);
  expect(easl.acks).toEqual([]);
  expect(easl.queue).toEqual([sent]);

  await omp.record(delivered.text);
  await until(() => easl.acks.length === 1);
  expect(easl.acks[0]).toMatchObject({ ids: [sent.id], started: true });
  expect(omp.entries).toContainEqual({ type: "custom", customType: "easl.messages", data: { ids: [sent.id] } });
  // Polls and acks share one connection; reports go over another.
  const inbox = easl.connections(true);
  expect(inbox.size).toBe(1);
  expect([...easl.connections(false)].some((connection) => inbox.has(connection))).toBe(false);

  // omp restarts into the same session before easl took the ack: offered again, it is acked, not delivered.
  await omp.emit("session_shutdown");
  easl.queue.push(sent);
  const restarted = fakeOmp(easl, omp.entries);
  await restarted.emit("session_start");
  await until(() => easl.acks.length === 2);
  expect(easl.acks[1]).toMatchObject({ ids: [sent.id], started: false });
  expect(restarted.delivered).toEqual([]);
});

test("an ack easl doesn't answer closes the inbox connection: what it held is offered again, and the ack retried", async () => {
  const easl = fakeEasl();
  const omp = fakeOmp(easl);
  await omp.emit("session_start");
  const first = message("one");
  easl.send(first);
  await until(() => omp.delivered.length === 1);
  const [connection] = easl.connections(true);
  // The ack's reply is lost after easl offered it what came meanwhile.
  await until(() => easl.polling());
  const second = message("two");
  easl.queue.push(second);
  easl.failing = (params) => params.ack?.length > 0;
  await omp.record(omp.delivered[0].text);

  await until(() => easl.closed.includes(connection));
  await until(() => omp.delivered.length === 2 && easl.acks.length === 1, 5000);
  expect(easl.acks[0]).toMatchObject({ ids: [first.id] });
  expect(easl.acks[0].connection).not.toBe(connection);
  expect(omp.delivered[1].text).toContain(`[message ${second.id} from alice@canvas`);
  expect(easl.queue).toEqual([second]);
});

test("a burst whose follow-up fetch fails delivers what already came", async () => {
  const easl = fakeEasl();
  const omp = fakeOmp(easl);
  await omp.emit("session_start");
  easl.failing = (params) => !params.waitMs && !params.ack;
  const sent = message("Build failed.");
  easl.send(sent);
  await until(() => omp.delivered.length === 1);
  expect(omp.delivered[0].text).toContain(`[message ${sent.id} from`);
  const [connection] = easl.connections(true);
  await until(() => easl.closed.includes(connection));
});

test("a message omp started no turn with waits for the next turn, the user told, and easl keeps it", async () => {
  const easl = fakeEasl();
  const omp = fakeOmp(easl);
  await omp.emit("session_start");
  const sent = message("Look at the failing test.");
  easl.send(sent);
  await until(() => omp.delivered.length === 1);
  // omp never records it (no model to start the turn with).
  await until(() => omp.notices.length === 1, 8000);
  expect(omp.notices[0]).toContain("omp started no turn with the message from alice@canvas");
  expect(easl.queue).toEqual([sent]);
  expect(easl.acks).toEqual([]);

  // The next turn that starts takes it, without being interrupted.
  omp.state.streaming = true;
  await omp.emit("agent_start");
  expect(omp.delivered).toHaveLength(2);
  expect(omp.delivered[1]).toMatchObject({ text: omp.delivered[0].text, deliverAs: "aside" });
  await omp.record(omp.delivered[1].text);
  await until(() => easl.acks.length === 1);
  expect(easl.acks[0]).toMatchObject({ ids: [sent.id], started: false });
});

test("past its wake bound, a sender doesn't wake an omp in its turn that streams nothing (awaiting background work)", async () => {
  const easl = fakeEasl();
  const omp = fakeOmp(easl);
  await omp.emit("session_start");
  for (let i = 1; i <= 20; i++) {
    easl.send(message(`ping ${i}`));
    await until(() => omp.delivered.length === i);
    await omp.record(omp.delivered[i - 1].text);
  }
  // A turn awaiting a background job: omp ended its run but will resume it.
  omp.state.streaming = true;
  await omp.emit("agent_start");
  omp.state.streaming = false;
  await omp.emit("agent_end", { willContinue: true, messages: [] });
  const late = message("one more");
  await until(() => easl.polling());
  const polls = easl.polls();
  easl.send(late);
  // Taken: answered to the long poll, then the burst's follow-up, then the next poll.
  await until(() => easl.polls() === polls + 2);
  expect(omp.delivered).toHaveLength(20);

  omp.state.streaming = true;
  await omp.emit("agent_start");
  expect(omp.delivered).toHaveLength(21);
  expect(omp.delivered[20]).toMatchObject({ deliverAs: "aside" });
  expect(omp.delivered[20].text).toContain(`[message ${late.id} from`);
});

test("messages arriving while omp reports a session switch were the old session's and never go into the new one", async () => {
  const easl = fakeEasl();
  const omp = fakeOmp(easl);
  await omp.emit("session_start");
  await until(() => easl.polling());
  const [connection] = easl.connections(true);
  const reported = Promise.withResolvers<void>();
  easl.sessionReported = reported.promise;
  omp.state.sessionId = "ses_2";
  const switched = omp.emit("session_switch");
  const old = message("for the old session");
  const polls = easl.polls();
  easl.send(old);
  await until(() => easl.polls() === polls + 2);
  reported.resolve();
  await switched;
  await until(() => easl.closed.includes(connection));
  expect(easl.bounced).toEqual([old]);
  expect(omp.delivered).toEqual([]);

  // The new session takes what is sent to it.
  const fresh = message("for the new session");
  easl.send(fresh);
  await until(() => omp.delivered.length === 1, 5000);
  expect(omp.delivered[0].text).toContain(`[message ${fresh.id} from`);
});

/** What the extension sent as `field` with each agent.report_session, in order. */
function reported(easl: { calls: { method: string; params: Params }[] }, field: "model" | "thinking"): unknown[] {
  return easl.calls.filter((call) => call.method === "agent.report_session").map((call) => call.params[field]);
}

/** Appends entries to a session's branch, each a child of the one before, dated before this omp started. */
function grow(branch: Params[], ...added: Params[]): void {
  for (const entry of added) branch.push({ id: `e${branch.length + 1}`, parentId: branch.at(-1)?.id ?? null, timestamp: "2020-01-01T00:00:00.000Z", ...entry });
}

test("a model easl may have taken without answering is sent again when the user switches back", async () => {
  const easl = fakeEasl();
  const omp = fakeOmp(easl);
  omp.ctx.model = { provider: "anthropic", id: "opus" };
  await omp.emit("session_start");
  await until(() => reported(easl, "model").length === 1);
  // /model while idle: sent with no turn; easl applies it, but its answer is lost.
  easl.failingSession = () => true;
  omp.ctx.model = { provider: "openai", id: "gpt" };
  await until(() => reported(easl, "model").length === 2);
  // Back to the model easl acknowledged before: easl may hold the other one now.
  omp.ctx.model = { provider: "anthropic", id: "opus" };
  await until(() => reported(easl, "model").length === 3);
  expect(reported(easl, "model")).toEqual(["anthropic/opus", "openai/gpt", "anthropic/opus"]);
});

test("the --thinking omp was launched with is the launch session's until the agent switches sessions", async () => {
  const argv = process.argv;
  const launch = Symbol.for("canvas-omp.launch");
  const global = globalThis as unknown as Record<symbol, unknown>;
  process.argv = [...argv, "--thinking=auto"];
  delete global[launch];
  cleanups.push(() => {
    process.argv = argv;
    delete global[launch];
  });
  const easl = fakeEasl();
  const omp = fakeOmp(easl);
  // The launch session last recorded high, before this omp started; it runs auto, as launched.
  grow(omp.branch(), { type: "thinking_level_change", thinkingLevel: "high", configured: "high" });
  await omp.emit("session_start");
  await until(() => reported(easl, "thinking").length === 1);
  omp.state.sessionId = "ses_2";
  await omp.emit("session_switch");
  await until(() => reported(easl, "thinking").length === 2);
  // Back to the launch session: omp restores what it recorded there, not the launch option.
  omp.state.sessionId = "ses_1";
  await omp.emit("session_switch");
  await until(() => reported(easl, "thinking").length === 3);
  expect(reported(easl, "thinking")).toEqual(["auto", undefined, "high"]);
});

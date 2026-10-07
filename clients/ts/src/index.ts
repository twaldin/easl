import { existsSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { type Compositions, createCompositions } from "./compositions";
import { bindMethods, type CanvasApi, RESEND_METHODS } from "./generated";

export * from "./compositions";
export * from "./generated";

/**
 * Where the easl server listens when `EASL_SOCKET` is unset. On macOS, the app's support directory.
 * Elsewhere, easld's home as `defaultHome` resolves it (easld/cmd/easld/main.go): `$EASL_HOME`, else
 * `$XDG_STATE_HOME/easl`, else `~/.local/state/easl`. The Python SDK (`easl_sdk.default_socket`) agrees.
 */
export function defaultSocket(platform: string = process.platform, env: Record<string, string | undefined> = process.env, home: string = homedir()): string {
  if (platform === "darwin") return join(home, "Library/Application Support/Easl/easl.sock");
  if (env.EASL_HOME) return join(env.EASL_HOME, "easl.sock");
  return join(env.XDG_STATE_HOME || join(home, ".local/state"), "easl/easl.sock");
}

export const DEFAULT_SOCKET = defaultSocket();
/** The app takes 5-10 s to restart; a request that never left waits this long for it. */
export const RECONNECT_TIMEOUT_MS = 15_000;

export class CanvasError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly data?: unknown,
  ) {
    super(message);
    this.name = "CanvasError";
  }
}

/** Connecting or writing failed before the request left, so it is safe to send again. */
class NotSent extends Error {}

/** The request left but the connection closed before its reply: it may have applied. */
class ReplyLost extends Error {}

/** `end`: the connection's byte count once this request's line (newline last) is queued. */
type Pending = { method: string; resolve: (value: unknown) => void; reject: (error: unknown) => void; timer?: NodeJS.Timeout; end: number };

/** `queued`: bytes handed to the socket so far; minus `socket.writableLength` it is what really left. */
type Connection = { socket: Socket; pending: Map<string, Pending>; buffer: string; queued: number; closed: boolean };

type WireMessage = {
  id?: string;
  ok?: boolean;
  result?: unknown;
  error?: { code: string; message: string; data?: unknown };
  event?: string;
  data?: unknown;
};

export type CanvasClientOptions = {
  /** Default: EASL_SOCKET, else the default socket if it exists; otherwise the constructor throws `unavailable`. */
  socketPath?: string;
  /** Filled in as `caller` when a method takes it and the call omits it. Default: EASL_TILE_ID. */
  tile?: string;
  /** Filled in as `board` when a method takes it and the call omits it. Default: EASL_BOARD_ID. */
  board?: string;
  /** Per-call timeout. Omit for none (agent.wait can legitimately block for minutes). */
  timeoutMs?: number;
  /** How long a call whose request was not sent waits for the socket to come back (app restart). Default 15 s. */
  reconnectTimeoutMs?: number;
  /** Where `compositions` looks; default `~/.easl/compositions`, then the shipped `builtin_compositions/`. */
  compositionsDirs?: string[];
};

function resolveSocket(explicit: string | undefined): string {
  const path = explicit || process.env.EASL_SOCKET || (existsSync(DEFAULT_SOCKET) ? DEFAULT_SOCKET : undefined);
  if (path) return path;
  throw new CanvasError(
    "unavailable",
    `EASL_SOCKET is unset and the default socket ${DEFAULT_SOCKET} does not exist, so this process has no easl connection (it did not inherit the terminal tile's environment). ` +
      "In the easl terminal run `echo $EASL_SOCKET $EASL_TILE_ID $EASL_BOARD_ID`, then pass those values: " +
      "`new CanvasClient({ socketPath, tile, board })` (Python: `easl_sdk.connect(socket=..., tile=..., board=...)`; CLI: export the three variables).",
  );
}

/** Split a newline-delimited JSON stream into messages, keeping any partial trailing line. */
function drainLines(buffer: string, onMessage: (message: WireMessage) => void): string {
  let rest = buffer;
  let newline = rest.indexOf("\n");
  while (newline >= 0) {
    const line = rest.slice(0, newline);
    rest = rest.slice(newline + 1);
    newline = rest.indexOf("\n");
    if (line) onMessage(JSON.parse(line) as WireMessage);
  }
  return rest;
}

/** One persistent connection to the easl API socket; the next call reconnects after an app restart. */
export class CanvasClient {
  readonly socketPath: string;
  readonly tileId: string | undefined;
  readonly boardId: string | undefined;
  readonly api: CanvasApi;
  readonly #timeoutMs: number | undefined;
  readonly #reconnectTimeoutMs: number;
  readonly #compositionsDirs: string[] | undefined;
  #compositions: Compositions | undefined;
  #connection: Promise<Connection> | undefined;
  #nextId = 0;

  constructor(options: CanvasClientOptions = {}) {
    this.socketPath = resolveSocket(options.socketPath);
    this.tileId = options.tile || process.env.EASL_TILE_ID || undefined;
    this.boardId = options.board || process.env.EASL_BOARD_ID || undefined;
    this.#timeoutMs = options.timeoutMs;
    this.#reconnectTimeoutMs = options.reconnectTimeoutMs ?? RECONNECT_TIMEOUT_MS;
    this.#compositionsDirs = options.compositionsDirs;
    this.api = bindMethods((method, params, envKeys) => this.call(method, params, envKeys));
  }

  /** Reusable helpers, loaded on first access: `client.compositions.grid.arrange(ids)`. */
  get compositions(): Compositions {
    this.#compositions ??= createCompositions(this.api, this.#compositionsDirs);
    return this.#compositions;
  }

  /**
   * Send one request. `envKeys` (e.g. ["caller", "board"]) are filled from this client when omitted; a relative `out` resolves against the cwd.
   * A `RESEND_METHODS` read (agent.wait) whose reply the connection lost is sent again once the app is back, with `timeoutMs` reduced by the time already spent.
   */
  async call(method: string, params: object, envKeys: readonly string[] = []): Promise<unknown> {
    const filled: Record<string, unknown> = { ...params };
    const defaults: Record<string, string | undefined> = { caller: this.tileId, board: this.boardId };
    for (const key of envKeys) filled[key] ??= defaults[key];
    if (typeof filled.out === "string") filled.out = resolve(filled.out.replace(/^~(?=\/|$)/, homedir()));
    const resend = RESEND_METHODS.includes(method);
    const started = Date.now();
    const budget = resend && typeof filled.timeoutMs === "number" ? filled.timeoutMs : undefined;
    for (;;) {
      if (budget !== undefined) filled.timeoutMs = Math.max(0, Math.round(budget - (Date.now() - started)));
      try {
        return await this.#deliver(method, filled);
      } catch (error) {
        if (!(error instanceof ReplyLost)) throw error;
        if (!resend) throw new CanvasError("unavailable", error.message);
      }
      // A read: the app restarted mid-call. Wait for it, then ask again with the time left.
      try {
        await this.#connect(this.#reconnectTimeoutMs);
      } catch (error) {
        throw new CanvasError("unavailable", `${(error as Error).message} (${method} was cut off and could not be re-sent)`);
      }
    }
  }

  /** One request; one that was not sent is sent once more on a fresh connection, waiting up to `reconnectTimeoutMs` for the socket. */
  async #deliver(method: string, params: object): Promise<unknown> {
    try {
      return await this.#send(method, params, 0);
    } catch (error) {
      if (!(error instanceof NotSent)) throw error;
    }
    // Stale connection or the app is restarting: nothing was delivered, so send once more.
    try {
      return await this.#send(method, params, this.#reconnectTimeoutMs);
    } catch (error) {
      throw error instanceof NotSent ? new CanvasError("unavailable", `${error.message} (${method} was not sent)`) : error;
    }
  }

  close(): void {
    const connection = this.#connection;
    this.#connection = undefined;
    // `end` half-closes and waits for the app's side; `unref` keeps that wait from holding the
    // process open (Bun 1.4 keeps a half-closed socket alive until the peer closes, so a CLI
    // that had printed its result never exited).
    void connection?.then(
      (c) => {
        c.socket.end();
        c.socket.unref();
      },
      () => undefined,
    );
  }

  async #send(method: string, params: object, waitMs: number): Promise<unknown> {
    const connection = await this.#connect(waitMs);
    const id = String(++this.#nextId);
    const line = `${JSON.stringify({ id, method, params })}\n`;
    connection.queued += Buffer.byteLength(line);
    const { promise, resolve, reject } = Promise.withResolvers<unknown>();
    connection.pending.set(id, { method, resolve, reject, end: connection.queued });
    if (this.#timeoutMs !== undefined) {
      connection.pending.get(id)!.timer = setTimeout(() => fail(connection, id, new CanvasError("timeout", `${method} timed out after ${this.#timeoutMs}ms`)), this.#timeoutMs);
    }
    connection.socket.write(line, (error) => {
      if (error) fail(connection, id, new NotSent(`easl socket ${this.socketPath}: ${error.message}`));
    });
    return promise;
  }

  /** The open connection, or a new one; each caller chains on the previous attempt so concurrent calls share it. */
  #connect(waitMs: number): Promise<Connection> {
    this.#connection = this.#connection?.then((c) => (c.closed ? this.#open(waitMs) : c), () => this.#open(waitMs)) ?? this.#open(waitMs);
    return this.#connection;
  }

  async #open(waitMs: number): Promise<Connection> {
    const deadline = Date.now() + waitMs;
    let missedThere = false;
    for (;;) {
      try {
        return await this.#dial();
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        // A socket this process may not connect to, or can't see although it is there, is a
        // sandbox (Codex's seatbelt answers ENOENT), not a missing app: waiting won't help.
        if (code === "EPERM" || code === "EACCES" || (code === "ENOENT" && existsSync(this.socketPath))) {
          // ENOENT with the file there is also an app binding its socket just after this dial
          // missed it (a restart): only a second one in a row is a sandbox.
          if (code === "ENOENT" && !missedThere) {
            missedThere = true;
            continue;
          }
          throw new NotSent(
            `easl socket ${this.socketPath} exists but connecting to it failed (${code}): a sandbox (e.g. Codex's) may be blocking Unix-socket connections; run this outside the sandbox or allow it`,
          );
        }
        missedThere = false;
        if (Date.now() >= deadline) {
          throw new NotSent(`easl socket ${this.socketPath}: ${(error as Error).message}${waitMs ? ` after waiting ${waitMs / 1000}s for the app` : ""}`);
        }
        await sleep(200);
      }
    }
  }

  #dial(): Promise<Connection> {
    const { promise, resolve, reject } = Promise.withResolvers<Connection>();
    const socket = connect(this.socketPath);
    const connection: Connection = { socket, pending: new Map(), buffer: "", queued: 0, closed: false };
    socket.setEncoding("utf8");
    // Before `connect` this fails the dial; afterwards `close` follows and fails the pending calls.
    socket.on("error", reject);
    socket.once("connect", () => resolve(connection));
    // The app hung up. Bun can leave a socket with unflushed writes half-open after `end`, so close it.
    socket.on("end", () => socket.destroy());
    socket.on("close", () => {
      connection.closed = true;
      // Requests are newline-framed: one whose newline never left was not read by the app, so it
      // is safe to send again; one that fully left may have applied.
      const flushed = connection.queued - socket.writableLength;
      for (const [id, pending] of connection.pending) {
        fail(
          connection,
          id,
          pending.end > flushed
            ? new NotSent(`easl socket ${this.socketPath}: connection closed`)
            : new ReplyLost(`easl connection lost after sending ${pending.method}; it may or may not have applied — re-read before retrying`),
        );
      }
    });
    socket.on("data", (chunk: string) => {
      connection.buffer = drainLines(connection.buffer + chunk, (message) => {
        const pending = message.id === undefined ? undefined : connection.pending.get(message.id);
        if (!pending) return;
        connection.pending.delete(message.id!);
        clearTimeout(pending.timer);
        if (message.ok) pending.resolve(message.result);
        else pending.reject(new CanvasError(message.error?.code ?? "internal", message.error?.message ?? "unknown error", message.error?.data));
      });
    });
    return promise;
  }
}

function fail(connection: Connection, id: string, error: Error): void {
  const pending = connection.pending.get(id);
  if (!pending) return;
  connection.pending.delete(id);
  clearTimeout(pending.timer);
  pending.reject(error);
}

/** Open a dedicated connection that streams `{ event, data }` messages to `onEvent`. Returns a closer. */
export async function subscribe(
  onEvent: (event: string, data: unknown) => void,
  params: { board?: string; events?: string[] } = {},
  socketPath?: string,
): Promise<() => void> {
  const path = resolveSocket(socketPath);
  const socket = connect(path);
  socket.setEncoding("utf8");
  const { promise, resolve, reject } = Promise.withResolvers<void>();
  socket.once("connect", () => resolve());
  socket.on("error", (error) => reject(new CanvasError("unavailable", `easl socket ${path}: ${error.message}`)));
  await promise;
  let buffer = "";
  socket.on("data", (chunk: string) => {
    buffer = drainLines(buffer + chunk, (message) => {
      if (message.event) onEvent(message.event, message.data);
    });
  });
  socket.write(`${JSON.stringify({ id: "subscribe", method: "events.subscribe", params })}\n`);
  return () => socket.end();
}

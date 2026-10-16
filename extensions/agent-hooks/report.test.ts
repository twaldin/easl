// bun test extensions/agent-hooks — lifecycle reports while easl is away (report.ts).
import type { UnixSocketListener } from "bun";
import { afterEach, expect, jest, test } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { CanvasClient, CanvasError } from "../../clients/ts/src/index";
import { release, report, spoolDirectory, watchCanvasReturn } from "./report";

const homes: string[] = [];
afterEach(() => {
  for (const home of homes.splice(0)) rmSync(home, { recursive: true, force: true });
});

function home(): string {
  const dir = mkdtempSync(join(tmpdir(), "canvas-spool-"));
  homes.push(dir);
  return dir;
}

/** A client whose easl is gone, as the real one reports it (`bun test` treats the socket's own ENOENT as uncaught). */
function away(socketPath: string): CanvasClient {
  const fail = () => Promise.reject(new CanvasError("unavailable", `easl socket ${socketPath}: connect ENOENT (not sent)`));
  return { socketPath, api: { agent: { report: fail, release: fail } } } as unknown as CanvasClient;
}

function spooled(socket: string, tile: string): Array<{ seq: number; method: string; params: Record<string, unknown> }> {
  const dir = spoolDirectory(socket, tile);
  return readdirSync(dir)
    .sort()
    .map((name) => JSON.parse(readFileSync(join(dir, name), "utf8")));
}

test("reports easl isn't there to take wait beside its socket, in seq order, with their answer", async () => {
  const socket = join(home(), "easl.sock");
  const client = away(socket);
  await report(client, { tile: "obj_a1", kind: "codex", state: "working", seq: 1_700_000_000_000_001, source: "canvas-codex" });
  await report(client, { tile: "obj_a1", kind: "codex", state: "idle", seq: 1_700_000_000_000_002, source: "canvas-codex", final: "Fixed." });
  await release(client, { tile: "obj_a1", kind: "codex", source: "canvas-codex" }, 1_700_000_000_000_003);
  const entries = spooled(socket, "obj_a1");
  expect(entries.map((entry) => [entry.seq, entry.method, entry.params.state])).toEqual([
    [1_700_000_000_000_001, "agent.report", "working"],
    [1_700_000_000_000_002, "agent.report", "idle"],
    [1_700_000_000_000_003, "agent.release", undefined],
  ]);
  expect(entries[1].params.final).toBe("Fixed.");
  expect(readdirSync(spoolDirectory(socket, "obj_a1")).some((name) => name.startsWith("."))).toBe(false);
});

test("a report easl answered, even with an error, is not kept", async () => {
  const socket = join(home(), "easl.sock");
  const server = Bun.listen({
    unix: socket,
    socket: {
      data(connection, data) {
        for (const line of data.toString().split("\n").filter(Boolean)) {
          const { id } = JSON.parse(line);
          connection.write(`${JSON.stringify({ id, ok: false, error: { code: "not_found", message: "object obj_gone" } })}\n`);
        }
      },
    },
  });
  try {
    const client = new CanvasClient({ socketPath: socket, timeoutMs: 1000, reconnectTimeoutMs: 0 });
    await report(client, { tile: "obj_gone", kind: "omp", state: "idle", seq: 5, source: "canvas-omp" });
    client.close();
    expect(() => readdirSync(spoolDirectory(socket, "obj_gone"))).toThrow();
  } finally {
    server.stop(true);
  }
});

test("a spool that can't be written costs the agent nothing", async () => {
  const dir = home();
  // The socket's directory is a file: nothing can be created under it.
  writeFileSync(join(dir, "blocked"), "");
  const client = away(join(dir, "blocked", "easl.sock"));
  await expect(report(client, { tile: "obj_a1", kind: "omp", state: "idle", seq: 1, source: "canvas-omp" })).resolves.toBeUndefined();
});

test("a Codex Stop hook run while easl is closed spools the turn's end with its answer", async () => {
  const socket = join(home(), "easl.sock");
  const hook = Bun.spawn(["bun", join(import.meta.dir, "hook.ts"), "codex", "Stop"], {
    stdin: new Blob([JSON.stringify({ session_id: "s1", cwd: "/tmp", last_assistant_message: "No blocking findings." })]),
    env: { ...process.env, EASL_ENV: "1", EASL_TILE_ID: "obj_codex1", EASL_SOCKET: socket, EASL_AGENT_HOOKS: "1" },
  });
  expect(await hook.exited).toBe(0);
  const [entry] = spooled(socket, "obj_codex1");
  expect(entry.method).toBe("agent.report");
  expect(entry.params).toMatchObject({ tile: "obj_codex1", kind: "codex", state: "idle", source: "canvas-codex", final: "No blocking findings." });
  expect(entry.seq).toBe(entry.params.seq as number);
});

test("an integration hears easl come back after a quit, and after a restart between two checks", () => {
  const socket = join(home(), "easl.sock");
  const listen = () => Bun.listen({ unix: socket, socket: { data() {} } });
  let server = listen();
  let returns = 0;
  jest.useFakeTimers();
  const stop = watchCanvasReturn(socket, () => returns++, 1000);
  try {
    jest.advanceTimersByTime(3000);
    expect(returns).toBe(0);
    // Quit: the socket goes, and nothing is there to report to.
    server.stop(true);
    rmSync(socket, { force: true });
    jest.advanceTimersByTime(3000);
    expect(returns).toBe(0);
    server = listen();
    jest.advanceTimersByTime(1000);
    expect(returns).toBe(1);
    jest.advanceTimersByTime(3000);
    expect(returns).toBe(1);
    // Restarted faster than a check: retaining the old inode prevents Linux from reusing it.
    server.stop(true);
    rmSync(socket, { force: true });
    server = listen();
    jest.advanceTimersByTime(1000);
    expect(returns).toBe(2);
    jest.advanceTimersByTime(3000);
    expect(returns).toBe(2);
    stop();
    server.stop(true);
    rmSync(socket, { force: true });
    server = listen();
    jest.advanceTimersByTime(3000);
    expect(returns).toBe(2);
  } finally {
    stop();
    jest.useRealTimers();
    server.stop(true);
  }
});

test("return checks tolerate a missing socket directory and notice it once it appears", () => {
  const socket = join(home(), "later", "easl.sock");
  let returns = 0;
  let server: UnixSocketListener<undefined> | undefined;
  const listen = () => Bun.listen({ unix: socket, socket: { data() {} } });
  jest.useFakeTimers();
  const stop = watchCanvasReturn(socket, () => returns++, 1000);
  try {
    jest.advanceTimersByTime(3000);
    expect(returns).toBe(0);
    mkdirSync(dirname(socket));
    server = listen();
    jest.advanceTimersByTime(1000);
    expect(returns).toBe(1);
    server!.stop(true);
    rmSync(socket, { force: true });
    server = listen();
    jest.advanceTimersByTime(1000);
    expect(returns).toBe(2);
    jest.advanceTimersByTime(3000);
    expect(returns).toBe(2);
  } finally {
    stop();
    jest.useRealTimers();
    server?.stop(true);
  }
});

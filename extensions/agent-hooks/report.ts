// Lifecycle reports from the agent integrations (extensions/omp, the hooks, extensions/opencode),
// kept when easl isn't there to take them. A report that can't reach easl (quit, restarting,
// crashed) is written to `agent-reports/<tile>/` beside the socket, and easl replays the
// tile's reports when it opens the tile's board, oldest `seq` first (AgentReportSpool.swift), so
// an agent that finished meanwhile comes back `done` with its answer. Neither sending nor
// spooling ever throws or waits on anything but its own short IO: the agent carries on as if
// there were no hook.
import { randomBytes } from "node:crypto";
import { closeSync, fstatSync, openSync, statSync } from "node:fs";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { CanvasError, type AgentReleaseParams, type AgentReportParams, type CanvasClient } from "../../clients/ts/src/index";

// Linux flags omitted by node:fs. Pin the inode without socket IO or inheritance into child processes.
const O_PATH = 0x200000;
const O_CLOEXEC = 0x80000;

/** Where reports for `tile` wait while easl is away: `agent-reports/<tile>/` beside the socket. */
export function spoolDirectory(socketPath: string, tile: string): string {
  return join(dirname(socketPath), "agent-reports", tile);
}

/** `agent.report`; spooled when easl can't be reached. `params.seq` orders the replay. */
export function report(client: CanvasClient, params: AgentReportParams & { seq: number }): Promise<void> {
  return deliver(client, "agent.report", params, params.seq, () => client.api.agent.report(params));
}

/** `agent.release` (the agent exited); spooled when easl can't be reached, in `seq` order with the reports. */
export function release(client: CanvasClient, params: AgentReleaseParams, seq: number): Promise<void> {
  return deliver(client, "agent.release", params, seq, () => client.api.agent.release(params));
}

async function deliver(client: CanvasClient, method: string, params: { tile: string }, seq: number, send: () => Promise<unknown>): Promise<void> {
  try {
    await send();
  } catch (error) {
    // easl answered (it rejected the report): nothing to keep. Not there, or no answer in
    // time (it may be quitting): keep it; a replay of one it did apply is dropped as stale.
    if (error instanceof CanvasError && error.code !== "unavailable" && error.code !== "timeout") return;
    await spool(client.socketPath, params.tile, { seq, method, params }).catch(() => undefined);
  }
}

/**
 * Calls `onReturn` whenever easl is back at `socketPath` after being away: quit and started
 * again, or restarted between two checks (it binds a new socket file each launch). A restarted
 * easl restores a `working` or `blocked` tile as `restored` and refuses prompts to a restored
 * `working` one until its agent reports again, so an integration that lives as long as its agent
 * (omp's extension, opencode's plugin) re-reports its state from here. Checks every `intervalMs`;
 * the timer never keeps the process alive. On Linux, retains the observed socket's inode so a
 * rebind cannot reuse it between checks. Returns a stop function.
 */
export function watchCanvasReturn(socketPath: string, onReturn: () => void, intervalMs = 2000): () => void {
  let seen = socketIdentity(socketPath, true);
  const timer = setInterval(() => {
    const now = socketIdentity(socketPath);
    if (now?.key === seen?.key) return;
    const next = now && process.platform === "linux" ? socketIdentity(socketPath, true) : now;
    if (next?.key === seen?.key) {
      if (next?.descriptor !== undefined) closeSync(next.descriptor);
      return;
    }
    if (seen?.descriptor !== undefined) closeSync(seen.descriptor);
    seen = next;
    if (next !== undefined) onReturn();
  }, intervalMs);
  timer.unref();
  return () => {
    clearInterval(timer);
    if (seen?.descriptor !== undefined) closeSync(seen.descriptor);
    seen = undefined;
  };
}

type SocketIdentity = { key: string; descriptor?: number };

function socketIdentity(path: string, retain = false): SocketIdentity | undefined {
  let descriptor: number | undefined;
  try {
    if (retain && process.platform === "linux") descriptor = openSync(path, O_PATH | O_CLOEXEC);
    const stat = descriptor === undefined ? statSync(path) : fstatSync(descriptor);
    if (stat.isSocket()) return { key: `${stat.dev}:${stat.ino}:${stat.birthtimeMs}`, descriptor };
  } catch {
    // A missing socket is expected while easl is away.
  }
  if (descriptor !== undefined) closeSync(descriptor);
  return undefined;
}

/** Written under a hidden name, then renamed: easl never reads half a report. */
async function spool(socketPath: string, tile: string, entry: { seq: number; method: string; params: object }): Promise<void> {
  if (!/^[\w-]+$/.test(tile)) return;
  const directory = spoolDirectory(socketPath, tile);
  await mkdir(directory, { recursive: true });
  const name = `${entry.seq}-${process.pid}-${randomBytes(4).toString("hex")}.json`;
  const temporary = join(directory, `.${name}`);
  const text = JSON.stringify(entry);
  // easl removes a tile's folder once its replay empties it; recreate it if that raced us.
  await writeFile(temporary, text).catch(async () => {
    await mkdir(directory, { recursive: true });
    await writeFile(temporary, text);
  });
  await rename(temporary, join(directory, name));
}

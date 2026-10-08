#!/usr/bin/env bun
// A finite supervisor, not a scheduler. Preserve the server's restart guards and unread done.
// bun scripts/rotate-lead.ts --target <tile|name@board> --file <handoff.txt> --out <evidence.json>
// --text replaces --file; --easl selects a CLI executable (default easl); --timeoutMs bounds the
// whole operation (default 30 min). Reserve restart/startup/tell/delivery time before restarting.
import type { Subprocess } from "bun";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import type { Agent, AgentPromptResult, AgentRestartResult } from "../clients/ts/src/generated";

const CLI_TIMEOUT_MS = 30_000;
const RESTART_TIMEOUT_MS = 30_000;
const STARTUP_TIMEOUT_MS = 120_000;
const TELL_TIMEOUT_MS = 30_000;
const DELIVERY_TIMEOUT_MS = 120_000;
const POST_BOUNDARY_BUDGET_MS = RESTART_TIMEOUT_MS + STARTUP_TIMEOUT_MS + TELL_TIMEOUT_MS + DELIVERY_TIMEOUT_MS;

type Step = {
  args: string[]; at: string; code: number; stdout: string; stderr: string; timedOut: boolean;
};
type Evidence = {
  pass: boolean; target: string; mode: "fresh"; force: false; startedAt: string; finishedAt?: string;
  oldAgent?: Agent;
  restart: { status: "not-started" | "restarting" | "restarted" | "ready"; result?: AgentRestartResult; ready?: Agent };
  handoff: {
    status: "not-sent" | "sending" | "queued" | "acknowledged";
    messageId: string; result?: AgentPromptResult; acknowledgedAgent?: Agent; proof?: string;
  };
  steps: Step[]; error?: string;
};

function options(args: string[]) {
  const flags: Record<string, string> = {};
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (!["--target", "--text", "--file", "--out", "--easl", "--timeoutMs"].includes(key) || args[i + 1] === undefined) {
      throw new Error("usage: rotate-lead.ts --target <tile|name@board> (--text <handoff> | --file <path>) --out <evidence.json> [--easl <executable>] [--timeoutMs <ms>]");
    }
    flags[key] = args[++i];
  }
  if (!flags["--target"]?.trim() || !flags["--out"] || (flags["--text"] === undefined) === (flags["--file"] === undefined)) {
    throw new Error("--target and --out are required, with exactly one of --text or --file");
  }
  const timeoutMs = flags["--timeoutMs"] === undefined ? 1_800_000 : Number(flags["--timeoutMs"]);
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 2_147_483_647) {
    throw new Error("--timeoutMs must be a positive integer no larger than 2147483647");
  }
  return {
    target: flags["--target"], out: resolve(flags["--out"]), text: flags["--text"], file: flags["--file"],
    easl: flags["--easl"] ?? "easl", timeoutMs,
  };
}

// Parse the CLI identity into the existing Agent shape once. Optional native fields with the
// wrong JSON type are unproved, just like absent fields; readiness must not accept either.
function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseAgent(value: unknown): Agent {
  if (!isObject(value) || typeof value.tile !== "string" || typeof value.board !== "string"
    || typeof value.root !== "string" || typeof value.address !== "string" || typeof value.kind !== "string"
    || typeof value.open !== "boolean" || typeof value.focused !== "boolean" || !isObject(value.lifecycle)) {
    throw new Error("easl returned an invalid agent identity");
  }
  const lifecycle = value.lifecycle;
  const state = lifecycle.state;
  if (state !== "working" && state !== "blocked" && state !== "idle" && state !== "done" && state !== "unknown") {
    throw new Error("easl returned an invalid agent lifecycle");
  }
  return {
    tile: value.tile, board: value.board, root: value.root, address: value.address, kind: value.kind,
    open: value.open, focused: value.focused,
    lifecycle: {
      state,
      ...(typeof lifecycle.seen === "boolean" ? { seen: lifecycle.seen } : {}),
      ...(typeof lifecycle.message === "string" ? { message: lifecycle.message } : {}),
      ...(lifecycle.restored === true ? { restored: true } : {}),
      ...(lifecycle.via === "notifications" ? { via: "notifications" } : {}),
    },
    ...(typeof value.name === "string" ? { name: value.name } : {}),
    ...(typeof value.sessionId === "string" ? { sessionId: value.sessionId } : {}),
    ...(typeof value.pid === "number" ? { pid: value.pid } : {}),
    ...(typeof value.protocol === "number" ? { protocol: value.protocol } : {}),
    ...(typeof value.live === "boolean" ? { live: value.live } : {}),
    ...(typeof value.draft === "boolean" ? { draft: value.draft } : {}),
    ...(typeof value.model === "string" ? { model: value.model } : {}),
    ...(typeof value.thinking === "string" ? { thinking: value.thinking } : {}),
  };
}

function agentOf(value: unknown, step: string) {
  if (!isObject(value) || !("agent" in value)) throw new Error(`${step} returned no agent`);
  return parseAgent(value.agent);
}

function isLiveNativeOmp(a: Agent) {
  return a.open === true && a.live === true && a.kind === "omp"
    && Number.isSafeInteger(a.protocol) && a.protocol! >= 1
    && Number.isSafeInteger(a.pid) && a.pid! > 0 && a.pid! <= 2_147_483_647
    && typeof a.sessionId === "string" && a.sessionId.length > 0
    && typeof a.model === "string" && a.model.length > 0
    && typeof a.thinking === "string" && a.thinking.length > 0;
}

function isFreshSuccessor(a: Agent, old: Agent) {
  return isLiveNativeOmp(a) && a.tile === old.tile && a.board === old.board && a.root === old.root
    && a.sessionId !== old.sessionId && a.pid !== old.pid && a.kind === old.kind
    && a.model === old.model && a.thinking === old.thinking;
}

function sameSession(a: Agent, b: Agent) {
  return a.tile === b.tile && a.sessionId === b.sessionId && a.pid === b.pid;
}

function atBoundary(a: Agent) {
  return a.lifecycle.state === "idle" || a.lifecycle.state === "done";
}

async function main() {
  const config = options(process.argv.slice(2));
  const deadline = Date.now() + config.timeoutMs;
  const evidence: Evidence = {
    pass: false, target: config.target, mode: "fresh", force: false, startedAt: new Date().toISOString(),
    restart: { status: "not-started" },
    handoff: { status: "not-sent", messageId: `msg_rotation_${randomUUID().replaceAll("-", "")}` }, steps: [],
  };
  await mkdir(dirname(config.out), { recursive: true });
  // No controller scratch, source copy or background process: only the caller's durable evidence.
  const persist = async () => writeFile(config.out, `${JSON.stringify(evidence, null, 2)}\n`);
  await persist();
  let child: Subprocess | undefined;
  let interrupted: string | undefined;
  const onInterrupt = () => { interrupted = "SIGINT"; child?.kill("SIGKILL"); };
  const onTerminate = () => { interrupted = "SIGTERM"; child?.kill("SIGKILL"); };
  process.on("SIGINT", onInterrupt);
  process.on("SIGTERM", onTerminate);
  const external = { ...process.env };
  for (const key of ["EASL_TILE_ID", "EASL_BOARD_ID", "EASL_BOARD_ROOT", "EASL_ENV"]) delete external[key];

  // Only the initial boundary inherits caller identity to resolve --target names.
  async function run(args: string[], until: number, inheritCallerIdentity = false): Promise<unknown> {
    if (interrupted) throw new Error(`rotation interrupted by ${interrupted}`);
    const remaining = Math.min(deadline, until) - Date.now();
    if (remaining <= 0) throw new Error("rotation deadline exceeded");
    const at = new Date().toISOString();
    child = Bun.spawn([config.easl, ...args], {
      env: inheritCallerIdentity ? process.env : external, stdin: "ignore", stdout: "pipe", stderr: "pipe",
    });
    const running = child;
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; running.kill("SIGKILL"); }, remaining);
    let code: number, stdout: string, stderr: string;
    try {
      [code, stdout, stderr] = await Promise.all([
        running.exited, new Response(running.stdout).text(), new Response(running.stderr).text(),
      ]);
    } finally {
      clearTimeout(timer);
      if (running.exitCode === null) {
        running.kill("SIGKILL");
        await running.exited;
      }
      child = undefined;
    }
    evidence.steps.push({ args, at, code, stdout, stderr, timedOut });
    await persist();
    if (interrupted) throw new Error(`rotation interrupted by ${interrupted}`);
    if (timedOut) throw new Error(`easl ${args[0]} exceeded the rotation deadline`);
    if (code !== 0) throw new Error(`easl ${args[0]} failed (${code}): ${stderr.trim() || stdout.trim()}`);
    return JSON.parse(stdout);
  }

  async function targetEntry(tile: string, until: number) {
    const value = await run(["agent.list"], Math.min(until, Date.now() + CLI_TIMEOUT_MS));
    if (!isObject(value) || !Array.isArray(value.agents)) {
      throw new Error("easl agent.list returned no agents array");
    }
    const matches = value.agents.filter((entry) => isObject(entry) && entry.tile === tile);
    if (matches.length !== 1) throw new Error(`target ${tile} is missing or duplicated in agent.list`);
    return parseAgent(matches[0]);
  }

  function requirePostBoundaryBudget() {
    if (deadline - Date.now() < POST_BOUNDARY_BUDGET_MS) {
      evidence.restart.status = "not-started";
      throw new Error("insufficient time for the reserved post-boundary restart and handoff budget");
    }
  }

  try {
    const text = config.file === undefined ? config.text! : await readFile(config.file, "utf8");
    if (!text.trim()) throw new Error("handoff must not be empty");
    requirePostBoundaryBudget();
    const boundaryDeadline = deadline - POST_BOUNDARY_BUDGET_MS;
    const boundary = await run([
      "agent.wait", "--target", config.target, "--until", "idle,done", "--timeoutMs", String(Math.max(1, boundaryDeadline - Date.now())),
    ], boundaryDeadline, true);
    requirePostBoundaryBudget();
    const old = await targetEntry(agentOf(boundary, "safe boundary").tile, boundaryDeadline);
    evidence.oldAgent = old;
    if (!atBoundary(old) || !isLiveNativeOmp(old) || old.draft !== false) {
      throw new Error("old safe idle/done boundary has no live native OOB identity");
    }
    requirePostBoundaryBudget();
    // agent.restart, unforced and unretried, remains authoritative for every guard, including
    // pending prompts/messages, unknown drafts, focus, concurrent restart/paste and re-checks.
    evidence.restart.status = "restarting";
    await persist();
    requirePostBoundaryBudget();
    const restarted = await run(["agent.restart", "--target", old.tile, "--mode", "fresh"], Math.min(deadline, Date.now() + RESTART_TIMEOUT_MS));
    if (!isObject(restarted) || !Array.isArray(restarted.command) || !restarted.command.every((word) => typeof word === "string")) {
      throw new Error("easl returned an invalid restart result");
    }
    const restartAgent = agentOf(restarted, "restart");
    if (restartAgent.tile !== old.tile) throw new Error("restart returned a different target");
    evidence.restart.result = { agent: restartAgent, command: restarted.command };
    evidence.restart.status = "restarted";
    await persist();
    if (!restarted.command.includes(`--model=${old.model}`) || !restarted.command.includes(`--thinking=${old.thinking}`)) {
      throw new Error("restart command did not preserve the recorded model and thinking selectors");
    }

    const startupDeadline = Math.min(deadline, Date.now() + STARTUP_TIMEOUT_MS);
    let ready: Agent | undefined;
    while (Date.now() < startupDeadline) {
      const candidate = await targetEntry(old.tile, startupDeadline);
      // Restart retains protocol/model/thinking; the fresh draft report makes protocol readiness fresh.
      if (isFreshSuccessor(candidate, old) && candidate.draft === false && atBoundary(candidate)) {
        ready = candidate;
        break;
      }
      await Bun.sleep(Math.min(250, Math.max(0, startupDeadline - Date.now())));
    }
    if (!ready) throw new Error("fresh native identity was not ready before the startup deadline (session/PID/live/kind/protocol/model/thinking/draft)");
    // Revalidate immediately before tell. Never resolve the original name again, and never use
    // an idle-only wait: retained done-unseen is a valid boundary, not a failed startup.
    const current = await targetEntry(old.tile, startupDeadline);
    if (!isFreshSuccessor(current, old) || current.draft !== false || !sameSession(current, ready) || !atBoundary(current)) {
      throw new Error("fresh native identity changed before handoff");
    }
    evidence.restart.ready = current;
    evidence.restart.status = "ready";
    evidence.handoff.status = "sending";
    await persist();
    const sent = await run([
      "tell", old.tile, text, "--from", "lead-rotation", "--message", evidence.handoff.messageId,
    ], Math.min(deadline, Date.now() + TELL_TIMEOUT_MS));
    if (!isObject(sent) || sent.delivery !== "message"
      || sent.message !== evidence.handoff.messageId
      || typeof sent.submittedAt !== "string"
      || !("waitable" in sent) || sent.waitable !== true) {
      throw new Error("tell did not acknowledge queueing the exact OOB message");
    }
    const sentAgent = agentOf(sent, "tell");
    if (!sameSession(sentAgent, current)) {
      throw new Error("tell returned a different native identity");
    }
    evidence.handoff.result = { agent: sentAgent, delivery: "message", message: sent.message, submittedAt: sent.submittedAt, waitable: true };
    evidence.handoff.status = "queued";
    await persist();

    const deliveryDeadline = Math.min(deadline, Date.now() + DELIVERY_TIMEOUT_MS);
    // The public wait seam cannot resolve while a message is queued or held. An ACK that starts
    // a turn also waits for working/blocked. This observes delivery, not a completed answer;
    // queueing alone (tell's success) must never set pass:true.
    const delivered = await run([
      "agent.wait", "--target", old.tile, "--until", "working,blocked,idle,done",
      "--timeoutMs", String(Math.max(1, deliveryDeadline - Date.now())),
    ], deliveryDeadline);
    const acknowledged = agentOf(delivered, "delivery wait");
    const live = await targetEntry(old.tile, deliveryDeadline);
    if (!sameSession(acknowledged, current) || !isFreshSuccessor(live, old) || !sameSession(live, current)) {
      throw new Error("native identity changed before delivery could be proved");
    }
    evidence.handoff.acknowledgedAgent = live;
    evidence.handoff.proof = "agent.wait: queue drained and prompt turn observed in the same native session";
    evidence.handoff.status = "acknowledged";
    evidence.pass = true;
  } catch (error) {
    evidence.error = error instanceof Error ? error.message : String(error);
    process.exitCode = interrupted === "SIGINT" ? 130 : interrupted === "SIGTERM" ? 143 : 1;
  } finally {
    process.off("SIGINT", onInterrupt);
    process.off("SIGTERM", onTerminate);
    evidence.finishedAt = new Date().toISOString();
    await persist();
  }
  console.log(JSON.stringify({ pass: evidence.pass, evidence: config.out, restart: evidence.restart.status, handoff: evidence.handoff.status, messageId: evidence.handoff.messageId }));
}

await main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});

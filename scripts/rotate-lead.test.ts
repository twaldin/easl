// bun test scripts/rotate-lead.test.ts — the finite controller through its CLI, not internal helpers.
import { afterEach, expect, test } from "bun:test";
import type { Subprocess } from "bun";
import { chmodSync, mkdtempSync, readFileSync, rmSync, watch, writeFileSync } from "node:fs";
import type { FSWatcher } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Agent } from "../clients/ts/src/generated";

const RESERVE_MS = 300_000, WINDOW_MS = 20_000;
const TEST_TIMEOUT_MS = WINDOW_MS * 1.5;

type FixtureEvidence = {
  pass: boolean; oldAgent: Agent; restart: { status: string; ready: Agent };
  handoff: { status: string; messageId: string };
  steps: { args: string[]; timedOut: boolean }[]; error?: string;
};
type FixtureCall = { args: string[]; pid: number; evidence: FixtureEvidence };
type FixtureState = {
  calls: FixtureCall[]; observed: Agent; acked: string[]; hungPid?: number;
  tells?: { target: string; text: string; id: string; sessionId: string }[];
};
type Fixture = {
  dir: string; cli: string; out: string; state: string; handoff: string; preload?: string;
  env: Record<string, string | undefined>;
};
type FixtureOptions = { fakeClock?: boolean; timeoutMs?: number };

const scratch: string[] = [];
const processes = new Set<Subprocess>();
const watchers = new Set<FSWatcher>();
afterEach(async () => {
  for (const child of processes) child.kill("SIGKILL");
  await Promise.all([...processes].map((child) => child.exited));
  processes.clear();
  for (const watcher of watchers) watcher.close();
  watchers.clear();
  for (const dir of scratch.splice(0)) {
    const state: FixtureState = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
    if (state.hungPid) {
      try { process.kill(state.hungPid, "SIGKILL"); } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
      }
    }
    rmSync(dir, { recursive: true });
  }
});

function fixture(options: Record<string, unknown> = {}, { fakeClock = false }: FixtureOptions = {}): Fixture {
  const dir = mkdtempSync(join(tmpdir(), "easl-rotation-test-"));
  scratch.push(dir);
  const state = join(dir, "state.json");
  const out = join(dir, "evidence.json");
  const handoff = join(dir, "handoff.txt");
  const cli = join(dir, "easl");
  writeFileSync(state, JSON.stringify(options));
  writeFileSync(handoff, "Read the durable handoff.\nDo not rerun completed release proofs.\n");
  // Exec, not a child shell left behind: a timed-out fixture is precisely the process killed.
  const quote = (word: string) => `'${word.replaceAll("'", "'\\''")}'`;
  writeFileSync(cli, `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(join(import.meta.dir, "fixtures/rotation-easl.ts"))} "$@"\n`);
  chmodSync(cli, 0o700);
  const preload = fakeClock ? join(import.meta.dir, "fixtures/rotation-clock.ts") : undefined;
  return {
    dir, cli, out, state, handoff, preload,
    env: {
      ...process.env, ROTATION_FIXTURE_STATE: state, ROTATION_FIXTURE_EVIDENCE: out,
      EASL_TILE_ID: "obj_sender", EASL_BOARD_ID: "brd_sender", EASL_BOARD_ROOT: "/sender", EASL_ENV: "1",
    },
  };
}

function start(f: Fixture, timeoutMs = RESERVE_MS + WINDOW_MS) {
  const child = Bun.spawn([
    process.execPath, ...(f.preload ? ["--preload", f.preload] : []), join(import.meta.dir, "rotate-lead.ts"),
    "--target", "canvas@canvas", "--file", f.handoff, "--out", f.out, "--easl", f.cli,
    "--timeoutMs", String(timeoutMs),
  ], { env: f.env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  processes.add(child);
  const result = Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    .then(([code, stdout, stderr]) => {
      processes.delete(child);
      const evidence: FixtureEvidence = JSON.parse(readFileSync(f.out, "utf8"));
      const state: FixtureState = JSON.parse(readFileSync(f.state, "utf8"));
      return { ...f, result: { code, stdout, stderr }, evidence, state };
    });
  return { child, result };
}

async function rotate(options: Record<string, unknown> = {}, harness: FixtureOptions = {}) {
  return start(fixture(options, harness), harness.timeoutMs).result;
}

function refused(evidence: FixtureEvidence, error: RegExp, restart: string, handoff = "not-sent") {
  expect(evidence.pass).toBe(false);
  expect(evidence.error).toMatch(error);
  expect(evidence.restart.status).toBe(restart);
  expect(evidence.handoff.status).toBe(handoff);
}

test("fresh native identity retaining done receives exactly one external OOB handoff, proved only after ACK", async () => {
  const { result, evidence, state, handoff } = await rotate();
  expect(result.code).toBe(0);
  expect(evidence.pass).toBe(true);
  expect(evidence.oldAgent.sessionId).toBe("01a10fde-f3b3-7671-ac5e-d37b44a78d1d");
  expect(evidence.restart.status).toBe("ready");
  expect(evidence.restart.ready).toMatchObject({
    sessionId: "01a11bbe-54a5-714e-a1cd-108cdde508cc", pid: 85860, kind: "omp", protocol: 1,
    model: "openai-codex/gpt-6.1-sol", thinking: "xhigh", draft: false, live: true,
    lifecycle: { state: "done", seen: false },
  });
  expect(evidence.handoff.status).toBe("acknowledged");
  expect(state.acked).toEqual([evidence.handoff.messageId]);
  expect(state.tells).toEqual([{
    target: "obj_01M4A7Q5ZVFQ6G7AT0", text: readFileSync(handoff, "utf8"),
    id: evidence.handoff.messageId, sessionId: evidence.restart.ready.sessionId,
  }]);
  const beforeAck = state.calls.find((call) => call.evidence.handoff?.status === "queued");
  expect(beforeAck?.evidence.pass).toBe(false);
}, TEST_TIMEOUT_MS);

for (const [name, options] of [
  ["a retained old session", { scenario: "stale-session" }],
  ["an unexpected model", { freshPatch: { model: "another/model" } }],
  ["an unexpected thinking selector", { freshPatch: { thinking: "low" } }],
  ["a new session with an unchanged PID", { freshPatch: { pid: 27105 } }],
  ["a new session with no fresh draft report", { scenario: "stale-protocol" }],
  ["a non-native kind", { freshPatch: { kind: "claude" } }],
  ["an absent native protocol", { freshPatch: { protocol: null } }],
  ["a non-live session", { freshPatch: { live: false } }],
  ["an active draft", { freshPatch: { draft: true } }],
] as const) {
  test(`${name} cannot receive the handoff`, async () => {
    const { result, evidence, state } = await rotate({
      ...options, expireStartup: true, clockOffsets: { startup: RESERVE_MS },
    }, { fakeClock: true });
    expect(result.code).toBe(1);
    refused(evidence, /fresh native identity was not ready before the startup deadline/, "restarted");
    expect(evidence.steps.at(-1)?.args[0]).toBe("agent.list");
    expect(state.tells).toBeUndefined();
  }, TEST_TIMEOUT_MS);
}

test("a server restart conflict leaves the handoff unsent and cannot claim success", async () => {
  const { result, evidence, state } = await rotate({ restartFailure: "prompt pending" });
  expect(result.code).toBe(1);
  refused(evidence, /easl agent.restart failed .*prompt pending/, "restarting");
  expect(evidence.steps.at(-1)?.args[0]).toBe("agent.restart");
  expect(state.tells).toBeUndefined();
}, TEST_TIMEOUT_MS);

test("a native session change before tell prevents the handoff", async () => {
  const { result, evidence, state } = await rotate({ scenario: "identity-before-tell" });
  expect(result.code).toBe(1);
  refused(evidence, /fresh native identity changed before handoff/, "restarted");
  expect(evidence.steps.at(-1)?.args[0]).toBe("agent.list");
  expect(state.tells).toBeUndefined();
}, TEST_TIMEOUT_MS);

test("a tell rejected by easl cannot claim a successful handoff", async () => {
  const { result, evidence, state } = await rotate({ scenario: "tell-failure" });
  expect(result.code).toBe(1);
  refused(evidence, /easl tell failed .*handoff rejected/, "ready", "sending");
  expect(evidence.steps.at(-1)?.args[0]).toBe("tell");
  expect(state.tells).toBeUndefined();
}, TEST_TIMEOUT_MS);

test("a queued handoff without an integration ACK cannot claim success", async () => {
  const { result, evidence, state } = await rotate({ scenario: "ack-timeout" });
  expect(result.code).toBe(1);
  refused(evidence, /easl agent.wait failed .*no integration ACK/, "ready", "queued");
  expect(evidence.steps.at(-1)?.args[0]).toBe("agent.wait");
  expect(state.tells).toHaveLength(1);
  expect(state.acked).toBeUndefined();
}, TEST_TIMEOUT_MS);

test("a session change after tell cannot be mistaken for that handoff's delivery", async () => {
  const { result, evidence, state } = await rotate({ scenario: "identity-after-ack" });
  expect(result.code).toBe(1);
  refused(evidence, /native identity changed before delivery could be proved/, "ready", "queued");
  expect(evidence.steps.at(-1)?.args[0]).toBe("agent.list");
  expect(state.tells).toHaveLength(1);
  expect(state.observed.sessionId).not.toBe(state.tells?.[0].sessionId);
}, TEST_TIMEOUT_MS);

test("a timeout shorter than the post-boundary reserve cannot restart", async () => {
  const { result, evidence, state } = await rotate({}, { timeoutMs: WINDOW_MS });
  expect(result.code).toBe(1);
  refused(evidence, /insufficient time.*post-boundary/, "not-started");
  expect(state.calls ?? []).toHaveLength(0);
  expect(state.tells).toBeUndefined();
}, TEST_TIMEOUT_MS);

for (const scenario of ["late-boundary", "late-old-identity"]) {
  test(`${scenario} cannot consume the reserved handoff budget`, async () => {
    const { result, evidence, state } = await rotate({
      scenario, clockOffsets: { boundary: WINDOW_MS + 1 },
    }, { fakeClock: true });
    expect(result.code).toBe(1);
    refused(evidence, /insufficient time.*post-boundary/, "not-started");
    expect(state.calls.some((call) => call.args[0] === "agent.restart")).toBe(false);
    expect(state.tells).toBeUndefined();
    const wait = state.calls[0].args;
    expect(Number(wait[wait.indexOf("--timeoutMs") + 1])).toBeLessThanOrEqual(WINDOW_MS);
  }, TEST_TIMEOUT_MS);
}

for (const command of [
  ["omp", "--thinking=xhigh"],
  ["omp", "--model=openai-codex/gpt-6.1-sol", "--thinking=low"],
]) {
  test(`a restart command without the recorded model/thinking cannot hand off: ${command.join(" ")}`, async () => {
    const { result, evidence, state } = await rotate({ restartCommand: command });
    expect(result.code).toBe(1);
    refused(evidence, /restart command did not preserve.*model.*thinking/, "restarted");
    expect(evidence.steps.at(-1)?.args[0]).toBe("agent.restart");
    expect(state.tells).toBeUndefined();
  }, TEST_TIMEOUT_MS);
}

test("an odd unrelated closed-board entry cannot prevent the target's rotation", async () => {
  const { result, evidence, state } = await rotate({ unrelatedEntry: { tile: "obj_unrelated", open: false, kind: null } });
  expect(result.code).toBe(0);
  expect(evidence.pass).toBe(true);
  expect(evidence.handoff.status).toBe("acknowledged");
  expect(state.tells).toHaveLength(1);
}, TEST_TIMEOUT_MS);

test("a user draft after delivery does not invalidate an acknowledged handoff", async () => {
  const { result, evidence, state } = await rotate({ scenario: "draft-after-delivery" });
  expect(result.code).toBe(0);
  expect(evidence.pass).toBe(true);
  expect(evidence.handoff.status).toBe("acknowledged");
  expect(state.observed.draft).toBe(true);
  expect(state.tells).toHaveLength(1);
}, TEST_TIMEOUT_MS);

test("a hung external CLI is killed within the boundary deadline and recorded as failure", async () => {
  const { result, evidence, state } = await rotate({ scenario: "hung-cli" }, { timeoutMs: RESERVE_MS + 1_500 });
  expect(result.code).toBe(1);
  refused(evidence, /easl agent.wait exceeded the rotation deadline/, "not-started");
  expect(evidence.steps.at(-1)?.timedOut).toBe(true);
  expect(state.tells).toBeUndefined();
  expect(state.hungPid).toBeDefined();
  expect(() => process.kill(state.hungPid!, 0)).toThrow();
}, TEST_TIMEOUT_MS);

test("a rejected stdout read kills the owned CLI child", async () => {
  // This fault-injection test depends on rotation-clock.ts's rejectStdout branch to exercise run's finally kill.
  const f = fixture({ scenario: "hung-cli", rejectStdout: true }, { fakeClock: true });
  let watcher: FSWatcher;
  const completed = new Promise<FixtureEvidence>((resolve) => {
    watcher = watch(f.dir, (_event, name) => {
      if (name !== "evidence.json") return;
      const text = readFileSync(f.out, "utf8");
      if (!text.endsWith("\n")) return;
      const evidence = JSON.parse(text);
      if (evidence.finishedAt) resolve(evidence);
    });
    watchers.add(watcher);
  });
  const { result: pending } = start(f);
  await Promise.race([completed, pending.then(({ evidence }) => evidence)]);
  watcher!.close();
  watchers.delete(watcher!);
  const state: FixtureState = JSON.parse(readFileSync(f.state, "utf8"));
  let leaked = false;
  try { process.kill(state.hungPid!, 0); leaked = true; } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
  }
  if (leaked) process.kill(state.hungPid!, "SIGKILL");
  const { result, evidence } = await pending;
  expect(result.code).toBe(1);
  refused(evidence, /fixture stdout read rejected/, "not-started");
  expect(state.hungPid).toBeDefined();
  expect(leaked).toBe(false);
}, TEST_TIMEOUT_MS);

test("SIGTERM kills a real owned CLI child and records an interrupted unsent rotation", async () => {
  const f = fixture({ scenario: "hung-cli" });
  let watcher: FSWatcher;
  const hung = new Promise<number>((resolve) => {
    watcher = watch(f.dir, () => {
      const pid = JSON.parse(readFileSync(f.state, "utf8")).hungPid;
      if (pid) resolve(pid);
    });
    watchers.add(watcher);
  });
  const { child, result: pending } = start(f);
  const pid = await Promise.race([hung, pending.then(() => { throw new Error("controller exited before its CLI child hung"); })]);
  watcher!.close();
  watchers.delete(watcher!);
  expect(pid).toBeDefined();
  expect(() => process.kill(pid!, 0)).not.toThrow();
  child.kill("SIGTERM");
  const { result, evidence, state } = await pending;
  expect(result.code).toBe(143);
  refused(evidence, /rotation interrupted by SIGTERM/, "not-started");
  expect(evidence.steps.at(-1)?.args[0]).toBe("agent.wait");
  expect(evidence.steps.at(-1)?.timedOut).toBe(false);
  expect(state.tells).toBeUndefined();
  expect(() => process.kill(pid!, 0)).toThrow();
}, TEST_TIMEOUT_MS);

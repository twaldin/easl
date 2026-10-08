// bun test scripts/rotate-lead.test.ts — the finite controller through its CLI, not internal helpers.
import { afterEach, expect, test } from "bun:test";
import type { Subprocess } from "bun";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Agent } from "../clients/ts/src/generated";

type FixtureEvidence = {
  pass: boolean; oldAgent: Agent; restart: { status: string; ready: Agent };
  handoff: { status: string; messageId: string };
  steps: { timedOut: boolean }[]; error?: string;
};
type FixtureCall = { args: string[]; pid: number; evidence: FixtureEvidence };
type FixtureState = {
  calls: FixtureCall[]; observed: Agent; acked: string[];
  tells?: { target: string; text: string; id: string; sessionId: string }[];
};

const scratch: string[] = [];
const processes = new Set<Subprocess>();
afterEach(async () => {
  for (const process of processes) process.kill("SIGKILL");
  await Promise.all([...processes].map((process) => process.exited));
  processes.clear();
  for (const dir of scratch.splice(0)) rmSync(dir, { recursive: true });
});

function fixture(options: Record<string, unknown> = {}) {
  if (!process.env.TMPDIR) throw new Error("rotation tests require a recorded scratch directory under $TMPDIR");
  const dir = mkdtempSync(join(process.env.TMPDIR, "easl-rotation-test-"));
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
  return {
    dir, cli, out, state, handoff,
    env: {
      ...process.env, ROTATION_FIXTURE_STATE: state, ROTATION_FIXTURE_EVIDENCE: out,
      EASL_TILE_ID: "obj_sender", EASL_BOARD_ID: "brd_sender", EASL_BOARD_ROOT: "/sender", EASL_ENV: "1",
    },
  };
}

async function run(command: string[], env: Record<string, string | undefined>) {
  const process = Bun.spawn(command, { env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  processes.add(process);
  const result = await Promise.all([process.exited, new Response(process.stdout).text(), new Response(process.stderr).text()]);
  processes.delete(process);
  return { code: result[0], stdout: result[1], stderr: result[2] };
}

async function rotate(options: Record<string, unknown> = {}, extra: string[] = []) {
  const f = fixture(options);
  const result = await run([
    process.execPath, join(import.meta.dir, "rotate-lead.ts"),
    "--target", "canvas@canvas", "--file", f.handoff, "--out", f.out, "--easl", f.cli,
    "--timeoutMs", "1500", ...extra,
  ], f.env);
  const evidence: FixtureEvidence = JSON.parse(readFileSync(f.out, "utf8"));
  const state: FixtureState = JSON.parse(readFileSync(f.state, "utf8"));
  return { ...f, result, evidence, state };
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
});

test("a retained old session cannot receive the handoff", async () => {
  const { result, evidence, state } = await rotate({ scenario: "stale-session" });
  expect(result.code).toBe(1);
  expect(evidence.pass).toBe(false);
  expect(evidence.restart.status).toBe("restarted");
  expect(state.tells).toBeUndefined();
});

test("a new session on an unexpected model cannot receive the handoff", async () => {
  const { result, evidence, state } = await rotate({ freshPatch: { model: "another/model" } });
  expect(result.code).toBe(1);
  expect(evidence.pass).toBe(false);
  expect(state.tells).toBeUndefined();
});

test("a server restart conflict leaves the handoff unsent and cannot claim success", async () => {
  const { result, evidence, state } = await rotate({ restartFailure: "prompt pending" });
  expect(result.code).toBe(1);
  expect(evidence.pass).toBe(false);
  expect(evidence.handoff.status).toBe("not-sent");
  expect(state.tells).toBeUndefined();
});

test("a native session change before tell prevents the handoff", async () => {
  const { result, evidence, state } = await rotate({ scenario: "identity-before-tell" });
  expect(result.code).toBe(1);
  expect(evidence.pass).toBe(false);
  expect(state.tells).toBeUndefined();
});

test("a tell rejected by easl cannot claim a successful handoff", async () => {
  const { result, evidence, state } = await rotate({ scenario: "tell-failure" });
  expect(result.code).toBe(1);
  expect(evidence.pass).toBe(false);
  expect(evidence.handoff.status).not.toBe("acknowledged");
  expect(state.tells).toBeUndefined();
});

test("a queued handoff without an integration ACK cannot claim success", async () => {
  const { result, evidence, state } = await rotate({ scenario: "ack-timeout" });
  expect(result.code).toBe(1);
  expect(evidence.pass).toBe(false);
  expect(evidence.restart.status).toBe("ready");
  expect(evidence.handoff.status).toBe("queued");
  expect(state.tells).toHaveLength(1);
  expect(state.acked).toBeUndefined();
});

test("a session change after tell cannot be mistaken for that handoff's delivery", async () => {
  const { result, evidence, state } = await rotate({ scenario: "identity-after-ack" });
  expect(result.code).toBe(1);
  expect(evidence.pass).toBe(false);
  expect(evidence.handoff.status).not.toBe("acknowledged");
  expect(state.tells).toHaveLength(1);
  expect(state.observed.sessionId).not.toBe(state.tells?.[0].sessionId);
});

test("a hung external CLI is killed within the controller deadline and recorded as failure", async () => {
  const { result, evidence, state } = await rotate({ scenario: "hung-cli" }, ["--timeoutMs", "800"]);
  expect(result.code).toBe(1);
  expect(evidence.pass).toBe(false);
  expect(evidence.steps.at(-1).timedOut).toBe(true);
  expect(state.tells).toBeUndefined();
  const pid = state.calls.at(-1).pid;
  expect(() => process.kill(pid, 0)).toThrow();
});

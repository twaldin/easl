// External easl fixture for rotate-lead.test.ts. Each CLI process advances one durable state.
// The identity sequence comes from the 2026-10-08 lead rotation: a successful fresh restart,
// retained done-unseen, and only later the new native session report (never an idle state).
import { readFileSync, renameSync, writeFileSync } from "node:fs";

const file = process.env.ROTATION_FIXTURE_STATE!;
const state = JSON.parse(readFileSync(file, "utf8"));
const args = process.argv.slice(2);
const flag = (name: string) => args[args.indexOf(name) + 1];
const oldSession = "01a10fde-f3b3-7671-ac5e-d37b44a78d1d";
const newSession = "01a11bbe-54a5-714e-a1cd-108cdde508cc";
const oldAgent = {
  tile: "obj_01M4A7Q5ZVFQ6G7AT0", board: "brd_6b395ed3472e5837df80", root: "/fixture/canvas",
  address: "canvas@canvas", name: "canvas", kind: "omp", protocol: 1,
  sessionId: oldSession, pid: 27105, model: "openai-codex/gpt-6.1-sol", thinking: "xhigh",
  open: true, live: true, focused: false, draft: false, lifecycle: { state: "done", seen: false },
};
const fresh = () => ({
  ...oldAgent, sessionId: newSession, pid: 85860,
  lifecycle: { state: state.acked?.length ? "working" : "done", seen: false },
  ...state.freshPatch,
});
const evidence = process.env.ROTATION_FIXTURE_EVIDENCE;
state.calls ??= [];
state.calls.push({
  args, pid: process.pid,
  evidence: evidence ? JSON.parse(readFileSync(evidence, "utf8")) : null,
});
function save() {
  writeFileSync(`${file}.next`, JSON.stringify(state));
  renameSync(`${file}.next`, file);
}
function reply(value: unknown): never {
  save();
  console.log(JSON.stringify(value));
  process.exit(0);
}
function fail(message: string): never {
  save();
  console.error(message);
  process.exit(1);
}
switch (args[0]) {
  case "agent.wait": {
    if (state.scenario === "hung-cli") {
      state.hungPid = process.pid;
      save();
      await Bun.sleep(60_000);
    }
    const until = flag("--until").split(",");
    if (!state.restarted) {
      if (!until.includes("done")) fail("timeout: old done-unseen did not reach the requested boundary");
      if (state.scenario === "late-boundary") state.clockOffsetMs = state.clockOffsets.boundary;
      reply({ agent: oldAgent });
    }
    if (!state.message) {
      // Replaying the archived idle-only wait makes the fresh identity available, but done
      // never becomes idle. A controller must inspect identity instead of changing the badge.
      state.stage = 3;
      state.observed = fresh();
      if (!until.includes("done")) fail("timeout: retained done-unseen did not reach idle in time");
      reply({ agent: fresh() });
    }
    if (state.scenario === "ack-timeout") fail("timeout: handoff is still queued, no integration ACK");
    if (!until.includes("working")) fail("timeout: ACK started a turn which is still working");
    state.acked = [state.message];
    reply({ agent: state.scenario === "draft-after-delivery" ? { ...fresh(), draft: true } : fresh() });
  }
  case "agent.restart": {
    if (flag("--mode") !== "fresh") fail("fixture requires a fresh restart");
    if (state.restartFailure) fail(`conflict: ${state.restartFailure}`);
    state.restarted = true;
    state.stage = 0;
    const { sessionId, pid, draft, live, ...inherited } = oldAgent;
    reply({ agent: inherited, command: state.restartCommand ?? ["omp", `--model=${oldAgent.model}`, "--thinking=xhigh"] });
  }
  case "agent.list": {
    const unrelated = state.unrelatedEntry ? [state.unrelatedEntry] : [];
    if (!state.restarted) {
      if (state.scenario === "late-old-identity") state.clockOffsetMs = state.clockOffsets.boundary;
      reply({ agents: [...unrelated, oldAgent] });
    }
    const stage = state.stage++;
    let agent: Record<string, unknown>;
    if (stage === 0) {
      const { sessionId, pid, draft, ...inherited } = oldAgent;
      agent = inherited;
    } else if (stage === 1 || state.scenario === "stale-session") {
      agent = oldAgent;
    } else if (stage === 2 || state.scenario === "stale-protocol") {
      const { draft, ...withoutDraft } = fresh();
      agent = withoutDraft;
    } else {
      agent = fresh();
    }
    if (state.expireStartup && stage >= 3) state.clockOffsetMs = state.clockOffsets.startup;
    if ((state.scenario === "identity-before-tell" && stage >= 4)
      || (state.scenario === "identity-after-ack" && state.acked?.length)) {
      agent = { ...agent, sessionId: "another-session", pid: 85861 };
    }
    if (state.scenario === "draft-after-delivery" && state.acked?.length) agent = { ...agent, draft: true };
    state.observed = agent;
    reply({ agents: [...unrelated, agent] });
  }
  case "tell": {
    if (["EASL_TILE_ID", "EASL_BOARD_ID", "EASL_BOARD_ROOT", "EASL_ENV"].some((key) => process.env[key] !== undefined)) {
      fail("invalid_params: external sender still carries a terminal identity");
    }
    if (flag("--from") !== "lead-rotation") fail("invalid_params: missing script sender label");
    const agent = state.observed;
    if (state.scenario === "tell-failure") fail("unavailable: handoff rejected");
    state.message = flag("--message");
    state.tells ??= [];
    state.tells.push({ target: args[1], text: args[2], id: state.message, sessionId: agent.sessionId });
    reply({
      agent, submittedAt: "2026-10-08T13:40:21.000Z", waitable: true,
      delivery: "message", message: state.message,
    });
  }
  default:
    fail(`unsupported fixture command: ${args.join(" ")}`);
}

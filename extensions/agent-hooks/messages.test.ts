// bun test extensions/agent-hooks — how an integration hands out-of-band messages to its agent.
import { expect, test } from "bun:test";
import type { AgentMessage } from "../../clients/ts/src/index";
import { deliveryText, header, peerAddress, plan, WakeBudget } from "./messages";

const message = (from: AgentMessage["from"], text = "hi", context?: string): AgentMessage => ({
  id: "msg_1",
  text,
  from,
  attribution: from.tile ? "agent" : "user",
  when: "now",
  queuedAt: "2026-10-06T00:00:00Z",
  ...(context ? { context } : {}),
});

test("omp's agent:// paths name easl addresses; the broadcast and other paths don't", () => {
  expect(peerAddress("agent://reviewer")).toBe("reviewer");
  expect(peerAddress("agent://reviewer@lindy/")).toBe("reviewer@lindy");
  expect(peerAddress("agent://lead%20agent@canvas")).toBe("lead agent@canvas");
  expect(peerAddress("agent://obj_01ABC")).toBe("obj_01ABC");
  expect(peerAddress("agent://all")).toBeUndefined();
  expect(peerAddress("agent://a@b@c")).toBeUndefined();
  expect(peerAddress("local://notes.md")).toBeUndefined();
});

test("the header names the sender and how to reply; a script has no reply address", () => {
  expect(header(message({ tile: "obj_l", name: "lead", address: "lead@canvas", board: "brd_c" }))).toBe(
    "[message from lead@canvas (terminal obj_l); reply with write agent://lead@canvas]",
  );
  expect(header(message({ tile: "obj_l", name: "Terminal", address: "obj_l", board: "brd_c" }))).toBe("[message from terminal obj_l; reply with write agent://obj_l]");
  expect(header(message({ tile: "obj_gone", name: "obj_gone" }))).toBe("[message from terminal obj_gone, closed since it sent this; no reply address]");
  expect(header(message({ name: "machine-watch" }))).toBe("[message from machine-watch, a script; no reply address]");
});

test("a burst is one text: each message under its header, its mentions after its text", () => {
  const lead = { tile: "obj_l", name: "lead", address: "lead@canvas", board: "brd_c" };
  const text = deliveryText([message(lead, "  Check the key.\n", "<canvas-mentions>…</canvas-mentions>"), message({ name: "ci" }, "Build failed.")]);
  expect(text).toBe(
    [
      "[message from lead@canvas (terminal obj_l); reply with write agent://lead@canvas]",
      "Check the key.",
      "<canvas-mentions>…</canvas-mentions>",
      "",
      "[message from ci, a script; no reply address]",
      "Build failed.",
    ].join("\n"),
  );
});

test("now steers a working agent and starts a turn when idle; next-turn never joins a running turn", () => {
  expect(plan("now", true, true)).toBe("steer");
  expect(plan("now", false, true)).toBe("turn");
  expect(plan("next-turn", true, true)).toBe("after-turn");
  expect(plan("next-turn", false, true)).toBe("turn");
  // Past the wake bound: no steer and no new turn.
  expect(plan("now", true, false)).toBe("aside");
  expect(plan("now", false, false)).toBe("next-start");
  expect(plan("next-turn", true, false)).toBe("after-turn");
});

test("each sender wakes the agent at most 20 times an hour, others unaffected", () => {
  const budget = new WakeBudget();
  const start = 1_000_000;
  for (let i = 0; i < 20; i++) {
    expect(budget.allows(["obj_a"], start + i)).toBe(true);
    budget.spend(["obj_a"], start + i);
  }
  expect(budget.allows(["obj_a"], start + 30)).toBe(false);
  expect(budget.allows(["obj_b"], start + 30)).toBe(true);
  expect(budget.allows(["obj_a", "obj_b"], start + 30)).toBe(false);
  // An hour after the first wake it may wake once more.
  expect(budget.allows(["obj_a"], start + 3_600_000)).toBe(true);
});

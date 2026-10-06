// bun test extensions/agent-hooks — how an integration hands out-of-band messages to its agent.
import { expect, test } from "bun:test";
import type { AgentMessage } from "../../clients/ts/src/index";
import { deliveryText, header, peerAddress, plan, recordedIds, WakeBudget } from "./messages";

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

test("the header names the message, its sender and how to reply; a script has no reply address", () => {
  expect(header(message({ tile: "obj_l", name: "lead", address: "lead@canvas", board: "brd_c" }))).toBe(
    "[message msg_1 from lead@canvas (terminal obj_l); reply with write agent://lead@canvas]",
  );
  expect(header(message({ tile: "obj_l", name: "Terminal", address: "obj_l", board: "brd_c" }))).toBe("[message msg_1 from terminal obj_l; reply with write agent://obj_l]");
  expect(header(message({ tile: "obj_gone", name: "obj_gone" }))).toBe("[message msg_1 from terminal obj_gone, closed since it sent this; no reply address]");
  expect(header(message({ name: "machine-watch" }))).toBe("[message msg_1 from machine-watch, a script; no reply address]");
});

test("the reply URI encodes the name and board, and omp's write path decodes back to the address", () => {
  for (const address of ["lead agent@My Project", "a/b@c@d", "100%@x", "obj_01ABC"]) {
    const line = header(message({ tile: "obj_l", name: "lead", address, board: "brd_c" }));
    const uri = /reply with write (\S+)\]$/.exec(line)?.[1];
    expect(uri).toBeDefined();
    expect(peerAddress(uri!)).toBe(address);
  }
  expect(header(message({ tile: "obj_l", name: "lead agent", address: "lead agent@My Project", board: "brd_c" }))).toEndWith("reply with write agent://lead%20agent@My%20Project]");
});

test("a recorded user message names the messages it carries by their headers' ids", () => {
  const lead = { tile: "obj_l", name: "lead", address: "lead@canvas", board: "brd_c" };
  const text = deliveryText([
    { ...message(lead, "See [message msg_quoted from x] above."), id: "msg_01A" },
    { ...message({ name: "ci" }, "Build failed."), id: "msg_01B" },
  ]);
  expect(recordedIds(text)).toEqual(["msg_01A", "msg_01B"]);
  expect(recordedIds("Nothing from easl here.")).toEqual([]);
});

test("a burst is one text: each message under its header, its mentions after its text", () => {
  const lead = { tile: "obj_l", name: "lead", address: "lead@canvas", board: "brd_c" };
  const text = deliveryText([message(lead, "  Check the key.\n", "<canvas-mentions>…</canvas-mentions>"), message({ name: "ci" }, "Build failed.")]);
  expect(text).toBe(
    [
      "[message msg_1 from lead@canvas (terminal obj_l); reply with write agent://lead@canvas]",
      "Check the key.",
      "<canvas-mentions>…</canvas-mentions>",
      "",
      "[message msg_1 from ci, a script; no reply address]",
      "Build failed.",
    ].join("\n"),
  );
});

test("now steers a working agent and starts a turn when idle; next-turn never joins a running turn", () => {
  const busy = { turn: true, streaming: true, mayWake: true };
  const idle = { turn: false, streaming: false, mayWake: true };
  expect(plan("now", busy)).toBe("steer");
  expect(plan("now", idle)).toBe("turn");
  expect(plan("next-turn", busy)).toBe("after-turn");
  expect(plan("next-turn", idle)).toBe("turn");
  // Past the wake bound: no steer and no new turn.
  expect(plan("now", { ...busy, mayWake: false })).toBe("aside");
  expect(plan("now", { ...idle, mayWake: false })).toBe("next-start");
  expect(plan("next-turn", { ...busy, mayWake: false })).toBe("after-turn");
});

test("past the wake bound, a turn that streams nothing (omp awaiting background work) is not woken", () => {
  // An aside into an omp that isn't streaming starts a turn, so it waits for the next one to start.
  expect(plan("now", { turn: true, streaming: false, mayWake: false })).toBe("next-start");
  expect(plan("now", { turn: true, streaming: false, mayWake: true })).toBe("steer");
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

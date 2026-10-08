// bun test extensions/agent-hooks — the SessionEnd hook (hook.ts, run as the agents run it)
// releases the tile only when the agent can say its user ended the session: a release clears
// the agent the tile resumes after a reboot (props.agent). easl is away here, so what the hook
// sends is spooled for it to replay (report.ts), where the test reads it.
import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spoolDirectory } from "./report";

const HOOK = join(import.meta.dir, "hook.ts");
const TILE = "obj_t";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** How many agent.release calls `kind`'s SessionEnd hook spooled, given the agent's `input`. */
function releases(kind: string, input: object): number {
  const dir = mkdtempSync(join(tmpdir(), "easl-session-end-"));
  dirs.push(dir);
  const socket = join(dir, "easl.sock");
  const run = Bun.spawnSync([process.execPath, HOOK, kind, "SessionEnd"], {
    stdin: Buffer.from(JSON.stringify(input)),
    env: { ...process.env, EASL_ENV: "1", EASL_TILE_ID: TILE, EASL_SOCKET: socket, EASL_AGENT_HOOKS: "1" },
  });
  expect(run.exitCode).toBe(0);
  const spool = spoolDirectory(socket, TILE);
  if (!existsSync(spool)) return 0;
  return readdirSync(spool).filter((name) => JSON.parse(readFileSync(join(spool, name), "utf8")).method === "agent.release").length;
}

test("Claude's session ended by a hangup or SIGTERM keeps the tile's agent; one its user ended releases it; Codex and Gemini CLI can't tell", () => {
  // Claude Code's SIGHUP and SIGTERM handlers end the session with `other`; its /exit with `prompt_input_exit`.
  expect(releases("claude", { session_id: "u-1", reason: "other" })).toBe(0);
  for (const reason of ["prompt_input_exit", "clear", "resume", "logout"]) {
    expect({ reason, released: releases("claude", { session_id: "u-1", reason }) }).toEqual({ reason, released: 1 });
  }
  // Codex sends `other` and Gemini CLI `exit` for every end, a hangup's too.
  expect(releases("codex", { session_id: "t-1", reason: "other" })).toBe(1);
  expect(releases("gemini", { session_id: "g-1", reason: "exit" })).toBe(1);
});

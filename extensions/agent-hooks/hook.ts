// easl integration for Claude Code, Codex and Gemini CLI, run as their lifecycle hooks:
//   bun hook.ts <claude|codex|gemini> <HookEvent>   (the agent's hook JSON on stdin)
// and for opencode's plugin (extensions/opencode), `opencode SessionEnd` as opencode exits.
// The claude/codex/gemini wrappers in bin/ install these hooks for one session (Claude: the
// plugin in extensions/claude; Codex: `-c hooks=…` from extensions/codex/config.ts; Gemini: a
// system settings layer from extensions/gemini/settings.ts) and only inside an easl terminal
// tile. Mirrors extensions/omp/easl.ts:
//  - lifecycle (working / blocked / idle), each turn's final answer, and session identity for resume
//  - the canvas-awareness block (extensions/guidance.ts) as session context
//  - the selection tray drained into the prompt you submit, as hidden context
//  - follow mode: files the agent reads, edits, and writes re-aim its follow tile
// A hook never fails or stalls the agent: every easl call has a short timeout, errors are
// swallowed, and the process exits by a hard deadline. Lifecycle reports easl isn't there to
// take are spooled for it to replay (./report.ts).
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, realpathSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { CanvasClient } from "../../clients/ts/src/index";
import { canvasGuidance } from "../guidance";
import { askedQuestion, QUEUED_ASK_TOOL, toolCall, unansweredQuestion } from "./calls";
import { codexStartupQuestion } from "./codex-trust";
import { absolute, editLocation, type Location, patchLocation, readLocation, structuredPatchChanges } from "./follow";
import { release, report as spooled } from "./report";
import { thread } from "./threads";

type Kind = "claude" | "codex" | "gemini" | "opencode";
type Json = Record<string, unknown>;

const HARD_DEADLINE_MS = 2500;

const kind = process.argv[2];
const event = process.argv[3] ?? "";
const tile = process.env.EASL_TILE_ID;
if ((kind === "claude" || kind === "codex" || kind === "gemini" || kind === "opencode") && process.env.EASL_ENV === "1" && tile && process.env.EASL_SOCKET && process.env.EASL_AGENT_HOOKS !== "0") {
  setTimeout(() => process.exit(0), HARD_DEADLINE_MS).unref();
  try {
    const text = await Bun.stdin.text();
    const input = (text.trim() ? JSON.parse(text) : {}) as Json;
    const output = await handle(kind, tile, event, input);
    if (output) await Bun.write(Bun.stdout, output);
  } catch {
    // easl unreachable or unexpected input: the agent carries on as if there were no hook.
  }
}
process.exit(0);

async function handle(kind: Kind, tile: string, event: string, input: Json): Promise<string | undefined> {
  const source = `canvas-${kind}`;
  const client = new CanvasClient({ timeoutMs: 1000, reconnectTimeoutMs: 0 });
  const quietly = (work: Promise<unknown>) => work.catch(() => undefined);
  // Hooks are separate processes that can finish out of order (async ones especially); the
  // process start time orders their reports the way the agent fired them.
  const seq = Math.floor(performance.timeOrigin * 1000);
  const report = (state: "working" | "blocked" | "idle", message?: string, call?: string, final?: string, serial?: boolean) =>
    spooled(client, { tile, kind, state, message, seq, source, call, final, serial });
  const context = (text: string) => JSON.stringify({ hookSpecificOutput: { hookEventName: event, additionalContext: text } });
  // Only the tile's own session owns its lifecycle, session id and tray (./threads.ts). A
  // subagent's approvals and finished calls still count (the tile waits on them); nothing of
  // Codex's internal sessions does.
  const from = thread(kind, input);
  if (from === "internal") return undefined;
  const subagent = from === "subagent";
  if (subagent && event !== "PreToolUse" && event !== "PermissionRequest" && event !== "PostToolUse" && event !== "PostToolUseFailure" && event !== "Notification") return undefined;
  switch (event) {
    case "Launch": {
      // bin/codex, as Codex starts (its arguments after the event): it fires SessionStart only
      // with the first prompt, and none of its hooks while it asks about the folder first.
      const question = codexStartupQuestion(process.argv.slice(4), process.cwd());
      await (question ? report("blocked", question) : report("idle"));
      // Answering it fires no hook: codex-trust.ts watches Codex's config for the answer.
      const codex = process.env.EASL_CODEX_PID;
      if (question && codex) {
        spawn(process.execPath, [resolve(import.meta.dir, "codex-trust.ts"), tile, String(seq + 1), codex, ...process.argv.slice(4)], { detached: true, stdio: "ignore" }).unref();
      }
      return undefined;
    }
    case "SessionStart": {
      const sessionId = str(input.session_id);
      const started = str(input.source);
      await Promise.all([
        sessionId ? quietly(client.api.agent.report_session({ tile, kind, sessionId, sessionPath: str(input.transcript_path) })) : undefined,
        // A compaction restarts the session mid-turn; anything else starts it waiting for you.
        started === "compact" ? undefined : report("idle"),
      ]);
      return context(canvasGuidance(kind, tile));
    }
    case "UserPromptSubmit":
    case "BeforeAgent": {
      // A subagent's task arrives as its prompt (filtered above): the user's turn goes on, and
      // the tray is theirs.
      const prompt = str(input.prompt)?.trim() ?? "";
      if (!prompt || /^[/!]/.test(prompt)) return undefined; // slash commands and shell escapes aren't prompts
      await report("working");
      // Codex fires no Stop for a turn that fails (the usage limit): codex-turn.ts watches this
      // turn's end in the rollout from here on, detached, and reports that one.
      const rollout = str(input.transcript_path);
      const turn = str(input.turn_id);
      if (kind === "codex" && rollout && turn) {
        let offset = 0;
        try {
          offset = statSync(rollout).size;
        } catch {}
        spawn(process.execPath, [resolve(import.meta.dir, "codex-turn.ts"), tile, rollout, turn, String(offset), String(process.ppid)], { detached: true, stdio: "ignore" }).unref();
      }
      // Peek, hand the context to the agent, then commit: a hook killed before its output
      // reached the agent leaves the tray intact. Only the tray's prompt target gets the tray;
      // mentions other agents attached for this tile (agent.prompt) come with any prompt. With
      // `prompt`, this is the submission drain: it takes the oldest prompt easl's composer typed
      // here, with that prompt's own mentions.
      const drained = await client.api.tray.drain({ peek: true, prompt });
      if (!drained.context) return undefined;
      await Bun.write(Bun.stdout, context(drained.context));
      await quietly(client.api.tray.commit({ ids: drained.mentions.map((m) => m.id) }));
      return undefined;
    }
    case "PreToolUse": {
      // Registered only for the ask tools (./calls.ts): the agent waits on the user's answer, in
      // auto modes too, where no approval announces it. The answer (its PostToolUse, or for
      // Codex's queued question a prompt) takes the tile back to working.
      const question = askedQuestion(input);
      if (question) await report("blocked", question, toolCall(input), undefined, kind === "codex");
      return undefined;
    }
    case "PermissionRequest": {
      // easl keeps the tile blocked until this call finishes (its PostToolUse), whatever other
      // calls (parallel siblings, subagents) finish meanwhile. Codex asks one approval at a time,
      // so its new request is the one on screen: it replaces any earlier wait (`serial`), and the
      // bubble never names a request already answered. Claude Code also asks permission for its
      // ask tool, in every mode: PreToolUse reported that question already, and a second wait for
      // the same call would outlast the answer.
      if (askedQuestion(input)) return undefined;
      const tool = str(input.tool_name) ?? "tool";
      const description = str(obj(input.tool_input)?.description);
      await report("blocked", description ?? `approve ${tool}?`, toolCall(input), undefined, kind === "codex");
      return undefined;
    }
    case "Notification": {
      // Claude Code: an MCP server asks for input, or the prompt has sat idle. Permission dialogs
      // are reported by PermissionRequest, which names the tool. Gemini CLI: each approval
      // dialog, with what it runs or changes (not the call).
      const type = str(input.notification_type);
      if (type === "elicitation_dialog") await report("blocked", str(input.message));
      else if (type === "idle_prompt") await report("idle");
      else if (type === "ToolPermission") {
        const details = obj(input.details) ?? {};
        await report("blocked", geminiApproval(details) ?? str(input.message), geminiApprovalCall(details, str(input.cwd) ?? process.cwd()));
      }
      return undefined;
    }
    case "PostToolUse":
    case "PostToolUseFailure":
    case "AfterTool": {
      // A finished call: the turn runs on (an approval of it was answered), unless other calls
      // still wait for approval. Claude reports a failed call separately; an Esc during it ends
      // the turn, with no Stop.
      if (input.is_interrupt === true) {
        await report("idle");
        return undefined;
      }
      // Codex's queued question finishes at once, unanswered: its wait lasts until the answer
      // comes as a prompt (or the turn ends; Stop raises it again).
      if (input.tool_name === QUEUED_ASK_TOOL) return undefined;
      // Subagents' reads would drag the follow tile around.
      const location = subagent || event === "PostToolUseFailure" ? undefined : kind === "claude" ? claudeLocation(input) : kind === "codex" ? codexLocation(input) : geminiLocation(input);
      await Promise.all([
        report("working", undefined, kind === "gemini" ? geminiToolCall(input) : toolCall(input)),
        location ? quietly(client.api.follow.report({ tile, path: location.path, range: location.range, changes: location.changes, action: location.action })) : undefined,
      ]);
      return undefined;
    }
    case "Stop":
    case "AfterAgent": {
      // The turn's answer (agent.read final): Codex's and Claude Code's `last_assistant_message`,
      // Gemini CLI's `prompt_response`.
      await report("idle", undefined, undefined, str(input.last_assistant_message) ?? str(input.prompt_response));
      // A question Codex queued this turn and the user hasn't answered still waits for them: the
      // turn is over, but the tile isn't done. Reported after the idle (one seq later), so the
      // turn's answer is kept.
      const rollout = kind === "codex" ? str(input.transcript_path) : undefined;
      const turn = str(input.turn_id);
      let asked: Json | undefined;
      try {
        asked = rollout && turn ? unansweredQuestion(readFileSync(rollout, "utf8"), turn) : undefined;
      } catch {}
      if (asked) await spooled(client, { tile, kind, state: "blocked", message: askedQuestion(asked), seq: seq + 1, source, call: toolCall(asked), serial: true });
      return undefined;
    }
    case "Interrupt":
      await report("idle");
      return undefined;
    case "SessionEnd":
      await release(client, { tile, kind, source }, seq);
      return undefined;
  }
  return undefined;
}

// MARK: Follow

function claudeLocation(input: Json): Location | undefined {
  const tool = str(input.tool_name);
  const args = obj(input.tool_input) ?? {};
  const response = obj(input.tool_response) ?? {};
  const cwd = str(input.cwd) ?? process.cwd();
  if (tool === "Read") {
    const file = obj(response.file);
    const path = str(args.file_path);
    if (!path) return undefined;
    const start = num(file?.startLine);
    const lines = num(file?.numLines);
    return { path: absolute(path, cwd), range: start && lines ? { start, end: start + lines - 1 } : undefined, action: "read" };
  }
  if (tool === "Edit" || tool === "MultiEdit" || tool === "Write" || tool === "NotebookEdit") {
    const path = str(args.file_path) ?? str(args.notebook_path);
    if (!path) return undefined;
    const changes = structuredPatchChanges(response.structuredPatch);
    const created = tool === "Write" && str(response.type) === "create";
    return { path: absolute(path, cwd), changes: changes.length ? changes : undefined, action: tool === "Write" && (created || !changes.length) ? "write" : "edit" };
  }
  return undefined;
}

function codexLocation(input: Json): Location | undefined {
  const tool = str(input.tool_name);
  const command = str(obj(input.tool_input)?.command);
  const cwd = str(input.cwd) ?? process.cwd();
  if (!command) return undefined;
  if (tool === "apply_patch") return patchLocation(command, cwd);
  if (tool === "Bash") return readLocation(command, cwd);
  return undefined;
}

// MARK: Gemini CLI

/** The approval dialog's question as Gemini CLI words it, with what it is about. */
function geminiApproval(details: Json): string | undefined {
  switch (str(details.type)) {
    case "exec": {
      const command = str(details.command);
      const root = str(details.rootCommand) ?? command;
      if (!root) return undefined;
      const question = `Allow execution of: '${root}'?${command && command !== root ? ` (${command})` : ""}`;
      return question.length > 160 ? `${question.slice(0, 159)}…` : question;
    }
    case "edit":
      return `Apply this change?${str(details.fileName) ? ` (${str(details.fileName)})` : ""}`;
    case "mcp":
      return `Allow execution of MCP tool "${str(details.toolName) ?? "?"}" from server "${str(details.serverName) ?? "?"}"?`;
    case "info":
      return `Do you want to proceed?${str(details.title) ? ` (${str(details.title)})` : ""}`;
  }
  return str(details.title);
}

/**
 * Gemini's approval notification names no tool call, so both it and the call's AfterTool name
 * the call by what it runs or changes: the shell command, the edited file, the MCP tool, the
 * fetch prompt. A dialog that names none of these (Gemini's own questions) blocks without a call,
 * which the next report of any kind ends.
 */
function geminiApprovalCall(details: Json, cwd: string): string | undefined {
  switch (str(details.type)) {
    case "exec":
      return geminiCallId("exec", str(details.command));
    case "edit": {
      const path = str(details.filePath);
      return geminiCallId("edit", path && real(absolute(path, cwd)));
    }
    case "mcp":
      return geminiCallId("mcp", str(details.serverName) && str(details.toolName) ? `${details.serverName}_${details.toolName}` : undefined);
    case "info":
      return geminiCallId("info", str(details.prompt));
  }
  return undefined;
}

function geminiToolCall(input: Json): string {
  const tool = str(input.tool_name) ?? "";
  const args = obj(input.tool_input) ?? {};
  const cwd = str(input.cwd) ?? process.cwd();
  const path = str(args.file_path);
  const call =
    tool === "run_shell_command" ? geminiCallId("exec", str(args.command))
    : (tool === "replace" || tool === "write_file") && path ? geminiCallId("edit", real(absolute(path, cwd)))
    : tool.startsWith("mcp_") ? geminiCallId("mcp", tool.slice(4))
    : tool === "web_fetch" ? geminiCallId("info", str(args.prompt))
    : undefined;
  return call ?? geminiCallId("tool", tool)!;
}

/** The dialog and the call can name one file differently (`/tmp` is `/private/tmp`). */
function real(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
}

function geminiCallId(kind: string, value: string | undefined): string | undefined {
  return value === undefined ? undefined : createHash("sha256").update(`${kind}\0${value}`).digest("hex").slice(0, 16);
}

/** read_file (its line range), replace (the new text's first line), write_file, and shell reads. */
function geminiLocation(input: Json): Location | undefined {
  const tool = str(input.tool_name);
  const args = obj(input.tool_input) ?? {};
  const cwd = str(input.cwd) ?? process.cwd();
  if (obj(input.tool_response)?.error) return undefined;
  const file = str(args.file_path);
  if (tool === "run_shell_command") {
    const command = str(args.command);
    return command ? readLocation(command, cwd) : undefined;
  }
  if (!file) return undefined;
  const path = absolute(file, cwd);
  if (tool === "read_file") {
    // 0.37 takes 1-based start_line/end_line; its docs still describe 0-based offset/limit.
    const start = num(args.start_line) ?? (typeof args.offset === "number" && args.offset >= 0 ? args.offset + 1 : undefined);
    const end = num(args.end_line) ?? (start && num(args.limit) ? start + num(args.limit)! - 1 : undefined);
    return { path, range: start ? { start, end: end && end >= start ? end : start } : undefined, action: "read" };
  }
  if (tool === "write_file") return { path, action: "write" };
  if (tool === "replace") return editLocation(path, str(args.old_string), str(args.new_string));
  return undefined;
}

// MARK: Input helpers

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function num(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
}

function obj(value: unknown): Json | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;
}

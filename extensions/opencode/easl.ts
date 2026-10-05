// easl integration for opencode, an opencode plugin that the opencode wrapper (bin/opencode)
// adds for one session through OPENCODE_CONFIG_CONTENT (extensions/opencode/config.ts), only
// inside an easl terminal tile. Mirrors extensions/omp/easl.ts:
//  - lifecycle (working / blocked on permission and question prompts / idle) and the session
//    id for resume (`opencode --session <id>`)
//  - the canvas-awareness block (extensions/guidance.ts) in the system prompt
//  - the selection tray drained into the prompt you submit, as a hidden (synthetic) part
//  - follow mode: files the agent reads, edits, and writes re-aim its follow tile
// Every easl call has a short timeout and its errors are swallowed: easl being gone never
// stalls opencode. Lifecycle reports it isn't there to take are spooled for it to replay
// (agent-hooks/report.ts).
import { resolve } from "node:path";
import { CanvasClient } from "../../clients/ts/src/index";
import { absolute, editLocation, type Location, patchLocation, readLocation } from "../agent-hooks/follow";
import { report as spooled, watchCanvasReturn } from "../agent-hooks/report";
import { canvasGuidance } from "../guidance";

const SOURCE = "canvas-opencode";
const IDLE_DEBOUNCE_MS = 250;
const RUN = resolve(import.meta.dir, "../agent-hooks/run");

type Json = Record<string, any>;
type Event = { type: string; properties: Json };
/** The part of opencode's plugin input this plugin uses (@opencode-ai/plugin `PluginInput`). */
type Input = { directory: string };

export const CanvasPlugin = async ({ directory }: Input) => {
  const tile = process.env.EASL_TILE_ID;
  // EASL_AGENT: bin/opencode integrated this opencode (the wrapper's other checks passed).
  if (process.env.EASL_ENV !== "1" || !tile || !process.env.EASL_SOCKET || process.env.EASL_AGENT !== "opencode" || process.env.EASL_AGENT_HOOKS === "0") return {};

  const client = new CanvasClient({ timeoutMs: 1000, reconnectTimeoutMs: 0 });
  const quietly = (work: Promise<unknown>) => work.catch(() => undefined);
  const guidance = canvasGuidance("opencode", tile);
  let seq = Date.now() * 1000;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  let busy = false;
  /**
   * Subagents' (tasks') sessions, from their created/updated events. The plugin's own SDK client
   * can't be asked instead: a request to opencode's server from inside an event handler never
   * answers, and events are delivered one at a time.
   */
  const children = new Set<string>();
  /** The last report, said again when easl comes back (it holds a restored one until then). */
  let last: [state: "working" | "blocked" | "idle", message?: string, call?: string] = ["idle"];

  function report(state: "working" | "blocked" | "idle", message?: string, call?: string): void {
    last = [state, message, call];
    clearTimeout(idleTimer);
    // By the clock: opencode can load the plugin twice in one process (one instance per
    // project/directory it opens), and a counter from each start would reorder their reports.
    const send = () => {
      seq = Math.max(seq + 1, Date.now() * 1000);
      return spooled(client, { tile: tile!, kind: "opencode", state, message, seq, source: SOURCE, call });
    };
    // Debounced: a retry or a tool-only continuation shouldn't flicker the badge.
    if (state === "idle") idleTimer = setTimeout(send, IDLE_DEBOUNCE_MS);
    else void send();
  }
  watchCanvasReturn(client.socketPath, () => report(...last));

  function follow(location: Location | undefined): void {
    if (location) void quietly(client.api.follow.report({ tile: tile!, path: location.path, range: location.range, changes: location.changes, action: location.action }));
  }

  // The tile runs opencode from now on; the session id comes with the first prompt.
  report("idle");
  // opencode fires no event as it quits: release the tile from a process that outlives it.
  process.once("exit", () => {
    Bun.spawn(["/bin/sh", RUN, "opencode", "SessionEnd"], { stdin: "ignore", stdout: "ignore", stderr: "ignore", env: process.env });
  });

  return {
    event: async ({ event }: { event: Event }) => {
      const props = event.properties ?? {};
      switch (event.type) {
        case "session.created":
        case "session.updated":
          if (props.info?.parentID) children.add(props.info.id);
          return;
        case "session.status": {
          if (children.has(props.sessionID)) return;
          const type = props.status?.type;
          if (type === "busy" && !busy) report("working");
          if (type === "idle") report("idle");
          busy = type !== "idle";
          return;
        }
        case "session.idle":
          if (children.has(props.sessionID)) return;
          busy = false;
          report("idle");
          return;
        // Every session's prompts block the tile: opencode shows a subagent's in the TUI too.
        case "permission.asked": {
          const what = [props.permission, ...(Array.isArray(props.patterns) ? props.patterns : [])].filter(Boolean).join(" ");
          const message = `Permission required: ${what}`;
          report("blocked", message.length > 160 ? `${message.slice(0, 159)}…` : message, `permission:${props.id}`);
          return;
        }
        case "permission.replied":
          report("working", undefined, `permission:${props.requestID}`);
          return;
        case "question.asked":
          report("blocked", props.questions?.[0]?.question ?? "waiting for your answer", `question:${props.id}`);
          return;
        case "question.replied":
        case "question.rejected":
          report("working", undefined, `question:${props.requestID}`);
      }
    },

    // The user's prompt: this session is the tile's (resume), and the tray rides along as a
    // synthetic part, which the model reads and the TUI doesn't show. The prompt's text lets a
    // prompt sent from easl's composer take its own mentions.
    "chat.message": async (input: { sessionID: string }, output: { message: { id: string }; parts: Json[] }) => {
      if (children.has(input.sessionID)) return;
      void quietly(client.api.agent.report_session({ tile: tile!, kind: "opencode", sessionId: input.sessionID }));
      const prompt = output.parts.filter((part) => part.type === "text" && !part.synthetic).map((part) => String(part.text ?? "")).join("\n");
      const drained = await client.api.tray.drain({ peek: true, prompt }).catch(() => undefined);
      if (!drained?.context) return;
      output.parts.push({ id: partID(), sessionID: input.sessionID, messageID: output.message.id, type: "text", text: drained.context, synthetic: true });
      await quietly(client.api.tray.commit({ ids: drained.mentions.map((m) => m.id) }));
    },

    "experimental.chat.system.transform": async (input: { sessionID?: string }, output: { system: string[] }) => {
      if (!input.sessionID || !children.has(input.sessionID)) output.system.push(guidance);
    },

    "tool.execute.after": async (input: { tool: string; sessionID: string; args: Json }, output: { metadata?: Json }) => {
      // Subagents' reads would drag the follow tile around.
      if (children.has(input.sessionID)) return;
      const args = input.args ?? {};
      const path = typeof args.filePath === "string" ? absolute(args.filePath, directory) : undefined;
      if (output.metadata?.error) return;
      switch (input.tool) {
        case "read": {
          if (!path) return;
          const start = typeof args.offset === "number" && args.offset > 0 ? args.offset : undefined;
          const end = start && typeof args.limit === "number" && args.limit > 0 ? start + args.limit - 1 : start;
          follow({ path, range: start && end ? { start, end } : undefined, action: "read" });
          return;
        }
        case "edit":
          if (path) follow(editLocation(path, args.oldString, args.newString));
          return;
        case "multiedit":
          if (path) follow(editLocation(path, args.edits?.[0]?.oldString, args.edits?.[0]?.newString));
          return;
        case "write":
          if (path) follow({ path, action: "write" });
          return;
        case "apply_patch":
          if (typeof args.patchText === "string") follow(patchLocation(args.patchText, directory));
          return;
        case "bash":
          if (typeof args.command === "string") follow(readLocation(args.command, typeof args.workdir === "string" ? absolute(args.workdir, directory) : directory));
      }
    },
  };
};

/** A part id the way opencode makes them (`prt_` + time-ordered hex + random base62), so the part sorts after the prompt's own. */
function partID(): string {
  const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
  const time = (BigInt(Date.now()) * 0x1000n + BigInt(Math.floor(Math.random() * 0x1000))).toString(16).padStart(12, "0").slice(-12);
  let random = "";
  for (let i = 0; i < 14; i++) random += alphabet[Math.floor(Math.random() * alphabet.length)];
  return `prt_${time}${random}`;
}

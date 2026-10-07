#!/usr/bin/env bun
// easl CLI: a thin, schema-driven client for agents without a persistent REPL.
//   easl methods                         every method with its description
//   easl methods <name>                  one method's params, result, and referenced types; or one type (CodeProps)
//   easl <namespace>.<method> [--json '{...}' | --json @file | --json @-] [--key value] [--nested.key value] [--flag]
//   easl <namespace> <method> ...
//   easl get <id> [--as raw|graph]       object.get
//   easl tell <name[@board]> <text> [--when next-turn] [--from <label>]   agent.prompt: a message to another agent
//   easl render <id|id,id|x,y,w,h> [--out f.png] [--scale 2] [--full] ...   view.render
//   easl browser <verb> [<tile>] [--key value] ...   browser tiles over the cmux subset (below)
//   easl metrics [--watch] [--reset] [--json]       app.metrics as text (--watch: every second)
//   easl ask "question" --option id=label[:why] ... [--wait]   a question tile for the user: object.create type question
//   easl ask list|get|cancel|wait ...    the question verbs (object.find, object.get, object.update, the --wait loop); `easl ask --help`
//   easl agent spawn --name <n> --command '<argv>' [--cwd <dir>] [--board <id>] [--prompt <text>] [--wait] [--timeout <ms>]
//                                        a new terminal tile running an agent (object.create), optionally
//                                        prompted once it is ready (agent.wait, agent.prompt); prints
//                                        {tile, name, board, command, prompted?, agent?}
// view.render and view.snapshot write the image to --out (relative to the cwd; format from the
// extension) or, without it, to a new file under $TMPDIR/easl-renders/, and print the result
// metadata with its `path`; so does `browser screenshot`. object.create/update print prop values
// over 1 KB elided (`--full` prints them whole); what the app returns is unchanged.
// Connection: EASL_SOCKET, EASL_TILE_ID, EASL_BOARD_ID (every easl terminal tile sets them);
// `browser`: CMUX_SOCKET_PATH (else cmux.sock beside the easl socket), CMUX_SURFACE_ID,
// CMUX_SOCKET_PASSWORD.
// `ask --wait` waits on a dedicated event connection until the question is answered (the answer JSON on
// stdout, exit 0) or closed unanswered (cancelled, expired or deleted: why on stderr, exit 2).
// Errors print `code: message` to stderr and exit 1.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { hostname, tmpdir, userInfo } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import catalog from "../schema/easl-api.json";
import { CanvasClient, CanvasError, DEFAULT_SOCKET, ENV_DEFAULTS, type Agent } from "../clients/ts/src/index";

type Schema = {
  type?: string | string[];
  $ref?: string;
  const?: unknown;
  enum?: unknown[];
  oneOf?: Schema[];
  anyOf?: Schema[];
  properties?: Record<string, Schema>;
  required?: string[];
  items?: Schema;
  description?: string;
  default?: unknown;
  minimum?: number;
  maximum?: number;
};
type MethodSpec = { description: string; params: Schema; result: Schema };
const methods = catalog.methods as Record<string, MethodSpec>;
const definitions = catalog.definitions as Record<string, Schema>;

/** The shipped skill: how to use easl well, beside this file in the checkout and the app bundle. */
const SKILL = resolve(import.meta.dir, "../skills/easl/SKILL.md");
/** Printed prop values longer than this (JSON bytes) are elided unless `--full`. */
const ELIDE_BYTES = 1024;
/** How long `easl agent spawn` waits for its agent to be ready by default (--timeout). */
const SPAWN_TIMEOUT_MS = 120_000;
/** Between agent.wait retries while a spawned agent hasn't reported (each `unavailable`). */
const SPAWN_RETRY_MS = 1000;

const ASK_FORMS = [
  'easl ask "question" --option id=label[:why] ... [--recommend id] [--context obj_…|url|path[:a[-b]]] ... [--asker name[@host]] [--expires 30m|2h|1d|45s|ISO] [--board brd_…] [--wait]',
  "easl ask --json '{...}' | --json @file | --json @-   (question, options, recommended, … as props; the flags add to them)",
  "easl ask list [--open] [--board brd_…]",
  "easl ask get <id> | cancel <id> | wait <id>",
];
const ASK_HELP = [
  "`easl ask` puts a question tile on the board for the user. --option repeats (split at the first =, then the first :); with none, the answer is a note.",
  "--context points at what the question is about: an object id, a URL (https://…, mailto:…), or a path with :line or :start-end.",
  "--asker defaults to the asking terminal tile; outside a tile, to <user>@<short hostname>. --expires takes 45s, 30m, 2h, 1d or an ISO 8601 date-time.",
  "--wait blocks until the user answers: the answer {id, option, label, note, at, by} prints as JSON, exit 0. Cancelled, expired or deleted: why on stderr, exit 2.",
  "`ask wait <id>` does the same for a question already posted; `ask cancel <id>` withdraws one; `ask list --open` lists the open ones.",
];

function usage(help = false): never {
  const lines = [
    "usage: easl methods [<name>]",
    "       easl <namespace>.<method> [--json '{...}' | --json @file | --json @-] [--key value] [--flag]",
    "       easl get <id> [--as graph]",
    "       easl tell <name[@board]> <text> [--when next-turn] [--from <label>]",
    "       easl render <id|id,id|x,y,w,h> [--out file.png] [--scale 2] [--full]",
    "       easl browser <verb> [<tile>] [--key value] [--json '{...}']   (open [url] | list | close | navigate, snapshot, click, …)",
    "       easl metrics [--watch] [--reset] [--json]",
    ...ASK_FORMS.map((form) => `       ${form}`),
    "       easl agent spawn --name <n> --command '<argv>' [--cwd <dir>] [--board <id>] [--prompt <text>] [--wait] [--timeout <ms>]",
  ];
  if (help) {
    lines.push(
      "",
      "`easl methods` lists every method; `easl methods <name>` shows one method's params and result,",
      "or one type's fields: object props per type are TerminalProps, CodeProps, NoteProps, HtmlProps,",
      "ShapeProps, ArrowProps, GroupProps, BrowserProps (e.g. `easl methods CodeProps`).",
      "--json @file reads the params from a file (@- or - reads stdin); --key value pairs combine with it, later ones win.",
      "An array param takes one item, a JSON array, comma-separated strings, or a repeated flag (--until working,blocked).",
      "object.create/update print prop values over 1 KB elided; --full prints them whole.",
      "`easl browser` drives browser tiles over the cmux subset (docs/contracts.md): `open [url]` opens one beside",
      "this terminal, `list` lists this board's, `close <tile>` closes one, any other verb sends browser.<verb> to <tile>",
      "(e.g. `easl browser snapshot obj_… --interactive`, `easl browser click obj_… --selector @e2`).",
      ...ASK_HELP,
      "`easl agent spawn` creates a terminal tile named <n> in <dir> (default: the current directory) running <argv>",
      "(a JSON array, or words split as a shell splits them), on this board unless --board. --prompt sends it a prompt",
      "once its agent reports ready (idle); --wait waits for that prompt's turn to end (without --prompt: until it is",
      "ready). --timeout bounds the wait for ready, default 120000 ms. Prints {tile, name, board, command, prompted, agent}.",
      "",
      `How to use easl well (read before building on the board): ${SKILL}`,
    );
  }
  (help ? console.log : console.error)(lines.join("\n"));
  process.exit(help ? 0 : 2);
}

function setPath(target: Record<string, unknown>, path: string, value: unknown): void {
  const keys = path.split(".");
  let node = target;
  for (const key of keys.slice(0, -1)) {
    node[key] ??= {};
    node = node[key] as Record<string, unknown>;
  }
  node[keys.at(-1)!] = value;
}

/** The `--json` value: inline JSON, `@file` (relative to the cwd), or `@-` (or `-`) for stdin. */
function jsonParams(value: string): Record<string, unknown> {
  let text = value;
  let source = "--json";
  if (value.startsWith("@") || value === "-") {
    const path = value === "-" ? "-" : value.slice(1);
    source = `--json ${value}`;
    try {
      text = path === "-" ? readFileSync(0, "utf8") : readFileSync(resolve(path), "utf8");
    } catch (error) {
      throw new CanvasError("invalid_params", `${source}: cannot read ${path === "-" ? "stdin" : resolve(path)}: ${(error as Error).message}`);
    }
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    throw new CanvasError("invalid_params", `${source}: not JSON (${(error as Error).message})`);
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new CanvasError("invalid_params", `${source}: params must be a JSON object`);
  return parsed as Record<string, unknown>;
}

/** The schema at `path` (`frame.x`) under `schema`, following `$ref`s; undefined past what it declares. */
function schemaAt(schema: Schema | undefined, path: string[]): Schema | undefined {
  let node = schema;
  for (const key of path) {
    while (node?.$ref) node = definitions[node.$ref.replace("#/definitions/", "")];
    node = node?.properties?.[key];
  }
  while (node?.$ref) node = definitions[node.$ref.replace("#/definitions/", "")];
  return node;
}

/** Whether a param declared by `schema` only ever holds a string (`--text 1` stays "1"). */
function takesOnlyStrings(schema: Schema | undefined): boolean {
  if (!schema) return false;
  if (schema.const !== undefined) return typeof schema.const === "string";
  if (schema.enum) return schema.enum.every((value) => typeof value === "string");
  if (schema.oneOf) return schema.oneOf.every(takesOnlyStrings);
  if (schema.anyOf) return schema.anyOf.every(takesOnlyStrings);
  const types = Array.isArray(schema.type) ? schema.type : schema.type ? [schema.type] : [];
  return types.length > 0 && types.every((type) => type === "string" || type === "null");
}

/**
 * The items of `--key value` for a param the method declares as an array: a JSON array as given;
 * otherwise one item, or, when the items are strings (states, ids, types), a comma-separated list
 * (`--until working`, `--until working,blocked`, `--ids obj_a,obj_b`).
 */
function arrayItems(schema: Schema, value: string): unknown[] {
  let parsed: unknown = value;
  try {
    parsed = JSON.parse(value);
  } catch {
    // plain text
  }
  if (Array.isArray(parsed)) return parsed;
  if (takesOnlyStrings(schemaAt(schema.items, []))) return value.split(",").map((item) => item.trim()).filter((item) => item !== "");
  return [parsed];
}

/** Whether a param declared by `schema` only ever holds an array. */
function takesOnlyArrays(schema: Schema | undefined): schema is Schema {
  const types = Array.isArray(schema?.type) ? schema.type : schema?.type ? [schema.type] : [];
  return types.length > 0 && types.every((type) => type === "array");
}

/**
 * `--key value` (JSON when it parses, except for params the method declares as strings, which
 * keep the text as typed, and arrays: see `arrayItems`; repeating an array param's flag appends),
 * `--json '{...}'`/`@file`/`@-`, and bare `--flag` (true).
 */
function parseArgs(args: string[], params?: Schema): Record<string, unknown> {
  let result: Record<string, unknown> = {};
  const lists = new Map<string, unknown[]>();
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (!arg.startsWith("--")) usage();
    const value = args[i + 1];
    if (value === undefined || value.startsWith("--")) {
      if (arg === "--json") usage();
      setPath(result, arg.slice(2), true);
      continue;
    }
    i++;
    if (arg === "--json") {
      result = { ...result, ...jsonParams(value) };
      lists.clear();
      continue;
    }
    const path = arg.slice(2);
    const schema = schemaAt(params, path.split("."));
    if (takesOnlyArrays(schema)) {
      const list = [...(lists.get(path) ?? []), ...arrayItems(schema, value)];
      lists.set(path, list);
      setPath(result, path, list);
      continue;
    }
    let parsed: unknown = value;
    if (!takesOnlyStrings(schema)) {
      try {
        parsed = JSON.parse(value);
      } catch {
        // plain string
      }
    }
    setPath(result, path, parsed);
  }
  return result;
}

/** Compact type text; records every referenced definition in `refs`. */
function typeText(s: Schema, refs: Set<string>): string {
  if (s.$ref) {
    const name = s.$ref.replace("#/definitions/", "");
    refs.add(name);
    return name;
  }
  if (s.const !== undefined) return JSON.stringify(s.const);
  if (s.enum) return s.enum.map((v) => JSON.stringify(v)).join(" | ");
  if (s.oneOf) return s.oneOf.map((o) => typeText(o, refs)).join(" | ");
  if (s.type === "array") {
    const item = typeText(s.items ?? {}, refs);
    return item.includes(" ") ? `(${item})[]` : `${item}[]`;
  }
  if (s.properties) {
    const required = s.required ?? [];
    return `{ ${Object.entries(s.properties).map(([k, v]) => `${k}${required.includes(k) ? "" : "?"}: ${typeText(v, refs)}`).join(", ")} }`;
  }
  return Array.isArray(s.type) ? s.type.join(" | ") : (s.type ?? "any");
}

function fieldLines(schema: Schema, refs: Set<string>, kind: "param" | "result"): string[] {
  // A whole result given as a type (object.measure → Size) lists that type's fields.
  if (schema.$ref) return fieldLines(definitions[schema.$ref.replace("#/definitions/", "")], refs, kind);
  const required = schema.required ?? [];
  const fields = Object.entries(schema.properties ?? {});
  if (fields.length === 0) return ["  (none)"];
  return fields.map(([name, s]) => {
    const notes: string[] = [];
    if (kind === "param") notes.push(required.includes(name) ? "required" : "optional");
    else if (!required.includes(name)) notes.push("optional");
    if (s.default !== undefined) notes.push(`default ${JSON.stringify(s.default)}`);
    if (s.minimum !== undefined || s.maximum !== undefined) notes.push(`range ${s.minimum ?? ""}..${s.maximum ?? ""}`);
    if (kind === "param" && name in ENV_DEFAULTS) notes.push(`auto-filled from ${ENV_DEFAULTS[name]}`);
    const annotation = notes.length ? ` (${notes.join(", ")})` : "";
    return `  ${name}: ${typeText(s, refs)}${annotation}${s.description ? ` — ${s.description}` : ""}`;
  });
}

/** One method's params, result, and the types they use; or one type's fields (`CodeProps`). */
function describe(name: string): void {
  const spec = methods[name];
  const def = definitions[name];
  if (!spec && !def) {
    console.error(`unknown method or type: ${name} (run \`easl methods\`)`);
    process.exit(2);
  }
  const refs = new Set<string>();
  const lines = spec
    ? [name, `  ${spec.description}`, "", "params:", ...fieldLines(spec.params, refs, "param"), "", "result:", ...fieldLines(spec.result, refs, "result")]
    : [name, ...(def.description ? [`  ${def.description}`] : []), "", "fields:", ...(def.properties ? fieldLines(def, refs, "result") : [`  ${typeText(def, refs)}`])];
  refs.delete(name);
  if (refs.size > 0) {
    lines.push("", "types:");
    for (const ref of refs) {
      const referenced = definitions[ref];
      lines.push(`  ${ref}: ${typeText(referenced, new Set())}${referenced.description ? ` — ${referenced.description}` : ""}`);
    }
  }
  console.log(lines.join("\n"));
}

const argv = process.argv.slice(2);
if (argv.length === 0 || argv[0] === "--help" || argv[0] === "-h") usage(true);

if (argv[0] === "methods") {
  if (argv[1]) describe(argv[1]);
  else {
    for (const [name, spec] of Object.entries(methods)) console.log(`${name.padEnd(22)} ${spec.description}`);
    console.log("\n`easl methods <name>` shows a method's params and result, or a type's fields (e.g. CodeProps).");
    console.log(`How to use easl well: ${SKILL}`);
  }
  process.exit(0);
}

/** Params of the cmux subset (docs/contracts.md) that are strings: `--text 1` and `--key 1` stay text. */
const BROWSER_STRINGS: Schema = {
  properties: Object.fromEntries(
    ["surface_id", "workspace_id", "url", "selector", "text", "script", "key", "load_state", "url_contains", "out"].map((key) => [key, { type: "string" }]),
  ),
};
const BROWSER_METHODS: Record<string, string> = { open: "browser.open_split", list: "surface.list", close: "surface.close" };

/**
 * `easl browser <verb> [<tile>] [--key value]`: one request on the cmux browser subset, for agents
 * without omp's browser tool. `open [url]` → browser.open_split beside this terminal (CMUX_SURFACE_ID),
 * `list` → surface.list of this board, `close <tile>` → surface.close, any other verb → browser.<verb>
 * on <tile>. `screenshot` writes the PNG like `render` and prints its `path` instead of the base64.
 */
async function browser(args: string[]): Promise<void> {
  const [verb, ...more] = args;
  if (!verb || verb.startsWith("--")) usage();
  const positional = more[0] !== undefined && !more[0].startsWith("--") ? more.shift() : undefined;
  const params = parseArgs(more, BROWSER_STRINGS);
  const out = params.out;
  delete params.out;
  if (out !== undefined && (verb !== "screenshot" || typeof out !== "string")) {
    throw new CanvasError("invalid_params", "--out <file.png> is for `easl browser screenshot`");
  }
  const method = Object.hasOwn(BROWSER_METHODS, verb) ? BROWSER_METHODS[verb] : `browser.${verb}`;
  if (verb === "open") {
    if (positional !== undefined) params.url ??= positional;
  } else if (positional !== undefined) {
    params.surface_id = positional;
  }
  // open and list act on the calling terminal's board unless told otherwise.
  if ((verb === "open" || verb === "list") && params.surface_id === undefined && params.workspace_id === undefined && process.env.CMUX_SURFACE_ID) {
    params.surface_id = process.env.CMUX_SURFACE_ID;
  }

  const path = process.env.CMUX_SOCKET_PATH || join(dirname(process.env.EASL_SOCKET || DEFAULT_SOCKET), "cmux.sock");
  const socket = connect(path);
  const connected = Promise.withResolvers<void>();
  socket.once("connect", () => connected.resolve());
  socket.once("error", connected.reject);
  try {
    await connected.promise;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    // As the easl client does: a socket that exists but refuses this process is a sandbox (Codex's).
    if (code === "EPERM" || code === "EACCES" || (code === "ENOENT" && existsSync(path))) {
      throw new CanvasError("unavailable", `cmux socket ${path} exists but connecting to it failed (${code}): a sandbox (e.g. Codex's) may be blocking Unix-socket connections; run this outside the sandbox or allow it`);
    }
    throw new CanvasError("unavailable", `cmux socket ${path}: ${(error as Error).message} (is easl running? its terminal tiles set CMUX_SOCKET_PATH)`);
  }
  socket.on("error", () => socket.destroy());
  const lines = createInterface({ input: socket, crlfDelay: Infinity });
  const replies = lines[Symbol.asyncIterator]();
  const reply = async (sent: string): Promise<string> => {
    const next = await replies.next();
    if (next.done) throw new CanvasError("unavailable", `cmux socket ${path} closed before answering ${sent}; it may or may not have applied — re-read before retrying`);
    return next.value;
  };
  try {
    if (process.env.CMUX_SOCKET_PASSWORD) {
      socket.write(`auth ${process.env.CMUX_SOCKET_PASSWORD}\n`);
      const answer = await reply("auth");
      if (!answer.startsWith("OK")) throw new CanvasError("unauthorized", answer.replace(/^ERROR: /, ""));
    }
    socket.write(`${JSON.stringify({ id: 1, method, params })}\n`);
    const response = JSON.parse(await reply(method)) as { ok: boolean; result?: Record<string, unknown>; error?: { code: string; message: string } };
    if (!response.ok) throw new CanvasError(response.error?.code ?? "internal_error", response.error?.message ?? "no error message");
    const result = response.result ?? {};
    if (typeof result.png_base64 === "string") {
      const file = out !== undefined ? resolve(out as string) : join(tmpdir(), "easl-renders", `screenshot-${Date.now()}-${process.pid}.png`);
      if (out === undefined) mkdirSync(dirname(file), { recursive: true });
      writeFileSync(file, Buffer.from(result.png_base64, "base64"));
      delete result.png_base64;
      result.path = file;
    }
    console.log(JSON.stringify(result, null, 2));
  } finally {
    lines.close();
    socket.destroy();
  }
}

if (argv[0] === "browser") {
  try {
    await browser(argv.slice(1));
  } catch (error) {
    if (error instanceof CanvasError) console.error(`${error.code}: ${error.message}`);
    else console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
  process.exit();
}

type Tally = { n: number; ms?: number; maxMs?: number; bytes?: number };
type Metrics = {
  uptimeS: number;
  sinceS: number;
  counters: Record<string, Record<"total" | "last60s" | "last10m", Tally>>;
  gauges: Record<string, number>;
  top: Record<string, { key: string; n: number; ms?: number }[]>;
  longest?: { ms: number; cause: string; agoS: number };
  process: { footprintMB?: number; peakFootprintMB?: number; windows?: Record<string, Record<string, number>>; helpers?: { pid: number; name: string; footprintMB: number; cpuPercent?: number }[] };
};

/** app.metrics as a few lines of text: the 60 s window, with launch totals where they say more. */
function metricsText(m: Metrics): string {
  const c = (name: string, w: "total" | "last60s" | "last10m" = "last60s"): Tally => m.counters[name]?.[w] ?? { n: 0 };
  const ms = (v = 0) => (v >= 100 ? v.toFixed(0) : v.toFixed(1));
  const kb = (v = 0) => `${Math.round(v / 1024)} KB`;
  const p = m.process.windows?.last60s ?? {};
  const lines = [
    `uptime ${Math.round(m.uptimeS)} s; totals since ${Math.round(m.sinceS)} s ago, rates over the last 60 s`,
    `main     busy ${ms((c("main.busy").ms ?? 0) / 600)}%  stretches ≥50 ms ${c("main.stretch50").n} (total ${c("main.stretch50", "total").n})  ≥250 ms ${c("main.stretch250").n} (total ${c("main.stretch250", "total").n})`,
  ];
  if (m.longest) lines.push(`         longest ${Math.round(m.longest.ms)} ms, ${Math.round(m.longest.agoS)} s ago: ${m.longest.cause}`);
  lines.push(`process  cpu ${p.cpuPercent ?? 0}%  wakeups ${p.interruptWakeupsPerS ?? 0}/s  memory ${m.process.footprintMB ?? 0} MB (peak ${m.process.peakFootprintMB ?? 0})`);
  const keys = c("key.wait"), keysTotal = c("key.wait", "total");
  if (keysTotal.n) {
    // How long keys into terminals waited for the main thread (a stall holds them) and how long handing them to Ghostty took.
    lines.push(`keys     ${keys.n} (total ${keysTotal.n}), waited ${ms((keys.ms ?? 0) / (keys.n || 1))} ms mean, ${ms(keys.maxMs)} ms max (total max ${ms(keysTotal.maxMs)}); handling ${ms(c("key.handle").maxMs)} ms max`);
  }
  for (const h of m.process.helpers ?? []) lines.push(`         ${h.name} ${h.pid}: ${h.footprintMB} MB${h.cpuPercent === undefined ? "" : `, ${h.cpuPercent}%`}`);
  // Requests by method: every request counts `api.in.<method>` on arrival and `api.<method>` when
  // answered; `api.main.<method>` is the main-thread part of its dispatches (a batch's operations
  // and async-only methods have none of their own).
  const api = Object.keys(m.counters)
    .filter((k) => k.startsWith("api.in."))
    .map((k) => k.slice("api.in.".length))
    .map((method) => ({ method, call: c(`api.${method}`, "total"), main: c(`api.main.${method}`, "total") }))
    .sort((a, b) => (b.call.ms ?? 0) - (a.call.ms ?? 0));
  lines.push("api      (since reset) method: requests, ms arrival to reply (max), main-thread ms, reply bytes");
  for (const a of api.slice(0, 8)) lines.push(`         ${a.method}: ${a.call.n}, ${ms(a.call.ms)} ms (${ms(a.call.maxMs)}), main ${ms(a.main.ms)} ms, ${kb(a.call.bytes)}`);
  const events = Object.keys(m.counters).filter((k) => k.startsWith("event."));
  lines.push(`events   ${events.map((k) => `${k.slice(6)} ${c(k, "total").n} (${kb(c(k, "total").bytes)})`).join(", ") || "none"}; subscribers ${m.gauges["events.subscribers"] ?? 0}`);
  lines.push(`writes   ${c("board.write", "total").n}, group refits ${c("board.refit", "total").n}; top ${(m.top.writers ?? []).map((w) => `${w.key} ${w.n}`).join(", ") || "none"}`);
  const route = c("route.board", "total");
  lines.push(`routing  board ${route.n}× ${ms(route.ms)} ms (max ${ms(route.maxMs)}), one arrow ${c("route.arrow", "total").n}×; triggers ${(m.top.routingTriggers ?? []).map((t) => `${t.key} ${t.n}`).join(", ") || "none"}`);
  lines.push(`saves    ${c("save.write", "total").n} (scheduled ${c("save.scheduled", "total").n}, coalesced ${c("save.coalesced", "total").n}), encode ${ms(c("save.encode", "total").ms)} ms, ${kb(c("save.write", "total").bytes)}`);
  const live = Object.entries(m.gauges).filter(([k, v]) => k.startsWith("live.") && v > 0).map(([k, v]) => `${k.slice(5)} ${v}`);
  lines.push(`tiles    live ${live.join(" ") || "none"}; html web views ${m.gauges["html.webviews"] ?? 0}, loads ${c("html.load", "total").n}, reuses ${c("html.reuse", "total").n}, measures ${c("html.measure", "total").n} (${ms(c("html.measure", "total").ms)} ms)`);
  return lines.join("\n");
}

if (argv[0] === "metrics") {
  const flags = new Set(argv.slice(1));
  for (const flag of flags) if (!["--watch", "--reset", "--json"].includes(flag)) usage();
  const client = new CanvasClient();
  // A watch resets once, on its first read.
  let reset = flags.has("--reset");
  try {
    do {
      const metrics = (await client.call("app.metrics", { reset, watch: flags.has("--watch") })) as Metrics;
      reset = false;
      if (flags.has("--watch")) process.stdout.write("\x1b[H\x1b[2J");
      console.log(flags.has("--json") ? JSON.stringify(metrics, null, 2) : metricsText(metrics));
      if (flags.has("--watch")) await Bun.sleep(1000);
    } while (flags.has("--watch"));
  } catch (error) {
    if (error instanceof CanvasError) console.error(`${error.code}: ${error.message}`);
    else console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  } finally {
    client.close();
  }
  process.exit();
}

/** The flags of each `easl ask` form: [those that take a value (repeating one adds), bare ones]. */
const ASK_FLAGS = {
  create: [["json", "option", "recommend", "context", "asker", "expires", "board"], ["wait"]],
  list: [["board"], ["open"]],
  get: [[], []],
  cancel: [[], []],
  wait: [["board"], []],
} as const;
type AskForm = keyof typeof ASK_FLAGS;
/** An object id (the schema's `Id`): a `--context` that matches it names an object. */
const ID_PATTERN = /^[a-z]+_[0-9A-Za-z]+$/;
const DURATION_SECONDS: Record<string, number> = { s: 1, m: 60, h: 3600, d: 86400 };

function askHelp(help: boolean): never {
  const lines = [`usage: ${ASK_FORMS[0]}`, ...ASK_FORMS.slice(1).map((form) => `       ${form}`), "", ...ASK_HELP];
  (help ? console.log : console.error)(lines.join("\n"));
  process.exit(help ? 0 : 2);
}

/** The positional arguments and flags of one `easl ask` form; a repeated flag keeps every value. */
function askArgs(form: AskForm, args: string[]): { positional: string[]; flags: Map<string, string[]> } {
  const [valued, bare] = ASK_FLAGS[form] as readonly [readonly string[], readonly string[]];
  const positional: string[] = [];
  const flags = new Map<string, string[]>();
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const name = arg.slice(2);
    if (!arg.startsWith("--")) positional.push(arg);
    else if (bare.includes(name)) flags.set(name, []);
    else if (valued.includes(name)) {
      const value = args[++i];
      if (value === undefined) throw new CanvasError("invalid_params", `${arg} needs a value`);
      flags.set(name, [...(flags.get(name) ?? []), value]);
    } else {
      throw new CanvasError("invalid_params", `unknown flag ${arg} for easl ask${form === "create" ? "" : ` ${form}`} (easl ask --help)`);
    }
  }
  return { positional, flags };
}

/** `--option id=label[:why]`: the id ends at the first `=`, the label at the first `:` after it. */
function parseOption(text: string): Record<string, string> {
  const equals = text.indexOf("=");
  if (equals < 0) throw new CanvasError("invalid_params", `--option takes id=label[:why], got "${text}"`);
  const rest = text.slice(equals + 1);
  const colon = rest.indexOf(":");
  const option: Record<string, string> = { id: text.slice(0, equals).trim(), label: (colon < 0 ? rest : rest.slice(0, colon)).trim() };
  const why = colon < 0 ? "" : rest.slice(colon + 1).trim();
  if (why) option.why = why;
  return option;
}

/**
 * `--context`: an object id → {object}; a URL (a scheme, unless what follows the colon is only
 * `N` or `N-M`: `notes.md:7` is a path) → {url}; else a path with an optional `:N` or `:N-M` → {path, lines}.
 */
function parseContext(text: string): Record<string, unknown> {
  if (ID_PATTERN.test(text)) return { object: text };
  const scheme = /^[A-Za-z][A-Za-z0-9+.-]*:(.*)$/s.exec(text);
  if (scheme && !/^\d+(-\d+)?$/.test(scheme[1])) return { url: text };
  const lines = /^(.+):(\d+)(?:-(\d+))?$/.exec(text);
  if (!lines) return { path: text };
  const start = Number(lines[2]);
  return { path: lines[1], lines: { start, end: lines[3] === undefined ? start : Number(lines[3]) } };
}

/** `--asker name[@host]`. */
function parseAsker(text: string): Record<string, string> {
  const at = text.indexOf("@");
  return at < 0 || at === text.length - 1 ? { name: at < 0 ? text : text.slice(0, at) } : { name: text.slice(0, at), host: text.slice(at + 1) };
}

/** `--expires`: 45s, 30m, 2h, 1d from now as UTC RFC 3339 in whole seconds; an ISO date-time as given. */
function parseExpires(text: string): string {
  const duration = /^(\d+)([smhd])$/.exec(text);
  if (duration) {
    const at = new Date((Math.floor(Date.now() / 1000) + Number(duration[1]) * DURATION_SECONDS[duration[2]]) * 1000);
    if (!Number.isNaN(at.getTime())) return at.toISOString().replace(".000Z", "Z");
  } else if (/^\d{4}-\d{2}-\d{2}T/.test(text)) {
    return text;
  }
  throw new CanvasError("invalid_params", `--expires takes a duration (45s, 30m, 2h, 1d) or an ISO 8601 date-time, got "${text}"`);
}

/** Who asks when no terminal does (from a tile the server fills {tile}): this OS user on this host. */
function defaultAsker(): Record<string, string> | undefined {
  let name = process.env.USER;
  try {
    name = userInfo().username;
  } catch {
    // no passwd entry (a container): $USER
  }
  return name ? { name, host: hostname().split(".")[0] } : undefined;
}

/**
 * The question's props: `--json` first, then the flags on top (the positional question and
 * --recommend/--asker/--expires replace; --option and --context add). Without options the answer is a note.
 */
function questionProps(positional: string[], flags: Map<string, string[]>): Record<string, unknown> {
  const props: Record<string, unknown> = {};
  for (const value of flags.get("json") ?? []) Object.assign(props, jsonParams(value));
  if (positional.length > 1) {
    throw new CanvasError("invalid_params", `easl ask takes one question; quote it (got ${positional.length} arguments, "${positional[1]}" is the second)`);
  }
  if (positional.length === 1) props.question = positional[0];
  for (const [flag, key, parse] of [
    ["option", "options", parseOption],
    ["context", "context", parseContext],
  ] as const) {
    const values = flags.get(flag);
    if (values === undefined) continue;
    const before = props[key] ?? [];
    if (!Array.isArray(before)) throw new CanvasError("invalid_params", `--${flag} adds to ${key}, but --json gave ${key} that is not an array`);
    props[key] = [...before, ...values.map(parse)];
  }
  props.options ??= [];
  const recommend = flags.get("recommend")?.at(-1);
  if (recommend !== undefined) props.recommended = recommend;
  const expires = flags.get("expires")?.at(-1);
  if (expires !== undefined) props.expiresAt = parseExpires(expires);
  const asker = flags.get("asker")?.at(-1);
  if (asker !== undefined) props.asker = parseAsker(asker);
  else if (props.asker === undefined && !process.env.EASL_TILE_ID) props.asker = defaultAsker();
  return props;
}

type EventMessage = { id?: string; ok?: boolean; error?: { code: string; message: string }; event?: string; data?: unknown };
type QuestionObject = { id: string; type?: string; props?: Record<string, unknown> };

/**
 * A dedicated `events.subscribe` connection. clients/ts `subscribe` returns before the app has
 * acknowledged it (a write made next can slip past) and cannot say the connection dropped, and
 * `ask --wait` needs both, so the CLI frames its own.
 */
class EventStream {
  #buffer = "";
  readonly #lines: string[] = [];
  #closed = false;
  #wake: (() => void) | undefined;

  constructor(readonly socket: Socket) {
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      this.#buffer += chunk;
      for (let newline = this.#buffer.indexOf("\n"); newline >= 0; newline = this.#buffer.indexOf("\n")) {
        const line = this.#buffer.slice(0, newline);
        this.#buffer = this.#buffer.slice(newline + 1);
        if (line) this.#lines.push(line);
      }
      this.#wake?.();
    });
    // `close` follows `end` and every error, after the data: a dropped connection always wakes the reader.
    socket.on("error", () => undefined);
    socket.on("close", () => {
      this.#closed = true;
      this.#wake?.();
    });
  }

  /** The next line from the app; undefined once the connection has closed and nothing is left to read. */
  async next(): Promise<EventMessage | undefined> {
    for (;;) {
      const line = this.#lines.shift();
      if (line !== undefined) return JSON.parse(line) as EventMessage;
      if (this.#closed) return undefined;
      await new Promise<void>((resolve) => (this.#wake = resolve));
    }
  }

  close(): void {
    this.socket.destroy();
  }
}

/** Subscribe to `board`'s events (every board's without one) and return once the app has acknowledged it. */
async function openEvents(path: string, board: string | undefined): Promise<EventStream> {
  const socket = connect(path);
  const connected = Promise.withResolvers<void>();
  socket.once("connect", () => connected.resolve());
  socket.once("error", connected.reject);
  try {
    await connected.promise;
  } catch (error) {
    throw new CanvasError("unavailable", `easl socket ${path}: ${(error as Error).message}`);
  }
  const stream = new EventStream(socket);
  socket.write(`${JSON.stringify({ id: "subscribe", method: "events.subscribe", params: board ? { board } : {} })}\n`);
  for (;;) {
    const message = await stream.next();
    if (!message) throw new CanvasError("unavailable", "easl closed the event connection before acknowledging events.subscribe");
    // Events ahead of the acknowledgment predate anything the caller does next.
    if (message.id !== "subscribe") continue;
    if (!message.ok) throw new CanvasError(message.error?.code ?? "internal_error", message.error?.message ?? "events.subscribe failed");
    return stream;
  }
}

/**
 * What a question's state calls for: answered → the answer JSON on stdout, 0; cancelled or
 * expired → why on stderr, 2; still open → undefined.
 */
function questionOutcome(object: QuestionObject): number | undefined {
  const props = object.props ?? {};
  const status = props.status ?? "open";
  if (status === "answered") {
    const { option, note, at, by, ...rest } = (props.answer ?? {}) as Record<string, unknown>;
    const options = Array.isArray(props.options) ? (props.options as { id?: unknown; label?: unknown }[]) : [];
    const label = options.find((candidate) => option !== undefined && candidate.id === option)?.label;
    console.log(JSON.stringify({ id: object.id, option: option ?? undefined, label, note: note ?? undefined, at, by, ...rest }, null, 2));
    return 0;
  }
  if (status === "cancelled") console.error(`cancelled: question ${object.id} was cancelled`);
  else if (status === "expired") console.error(`expired: question ${object.id} expired`);
  else return undefined;
  return 2;
}

/** A question gone from the board: why on stderr, 2. */
function questionDeleted(id: string): number {
  console.error(`deleted: question ${id} was deleted`);
  return 2;
}

/** Read events until question `id` is answered, closed or deleted; a dropped connection is an error. */
async function awaitQuestion(id: string, events: EventStream): Promise<number> {
  for (;;) {
    const message = await events.next();
    if (!message) throw new CanvasError("unavailable", `the event connection closed before question ${id} was answered (\`easl ask wait ${id}\` resumes)`);
    const object = message.data as QuestionObject | undefined;
    if (object?.id !== id) continue;
    if (message.event === "object.deleted") return questionDeleted(id);
    const outcome = message.event === "object.updated" ? questionOutcome(object) : undefined;
    if (outcome !== undefined) return outcome;
  }
}

/**
 * `easl ask`: a question tile for the user (create), or `list`/`get`/`cancel`/`wait` on them. Returns the
 * exit code: 0, or 2 for `--wait`/`wait` on a question that ended without an answer.
 */
async function ask(args: string[]): Promise<number> {
  if (args.length === 0) askHelp(false);
  if (args.includes("--help") || args.includes("-h")) askHelp(true);
  const form: AskForm = args[0] !== "create" && Object.hasOwn(ASK_FLAGS, args[0]) ? (args[0] as AskForm) : "create";
  const { positional, flags } = askArgs(form, form === "create" ? args : args.slice(1));
  const last = (name: string) => flags.get(name)?.at(-1);
  const show = (result: unknown) => console.log(JSON.stringify(result, null, 2));
  if (form === "list" && positional.length > 0) throw new CanvasError("invalid_params", "easl ask list takes no arguments");
  if ((form === "get" || form === "cancel" || form === "wait") && positional.length !== 1) {
    throw new CanvasError("invalid_params", `easl ask ${form} takes one question id`);
  }
  const id = positional[0];
  const props = form === "create" ? questionProps(positional, flags) : undefined;

  const client = new CanvasClient();
  try {
    if (form === "list") {
      const params: Record<string, unknown> = { type: "question" };
      if (flags.has("open")) params.status = "open";
      if (last("board")) params.board = last("board");
      show(await client.call("object.find", params, ["board"]));
    } else if (form === "get") {
      show(await client.call("object.get", { id }, []));
    } else if (form === "cancel") {
      show(await client.call("object.update", { id, props: { status: "cancelled" } }, ["caller"]));
    } else if (form === "wait") {
      // Subscribe first, then read: a change in between is still on the stream.
      const events = await openEvents(client.socketPath, last("board"));
      try {
        let object: QuestionObject;
        try {
          ({ object } = (await client.call("object.get", { id }, [])) as { object: QuestionObject });
        } catch (error) {
          // Deleted before the subscription, or after it and before this read (its object.deleted
          // is queued unread): the same outcome as a deletion during the wait.
          if (error instanceof CanvasError && error.code === "not_found") return questionDeleted(id);
          throw error;
        }
        if (object.type !== "question") throw new CanvasError("invalid_params", `${id} is a ${object.type}, not a question`);
        return questionOutcome(object) ?? (await awaitQuestion(id, events));
      } finally {
        events.close();
      }
    } else {
      const params: Record<string, unknown> = { type: "question", props };
      if (last("board")) params.board = last("board");
      if (!flags.has("wait")) {
        show(await client.call("object.create", params, ["board", "caller"]));
        return 0;
      }
      // Subscribed before the create, to the board it lands on when that is known, else to every board: no update can be missed.
      const events = await openEvents(client.socketPath, last("board") ?? client.boardId);
      try {
        const created = (await client.call("object.create", params, ["board", "caller"])) as { object: QuestionObject };
        return await awaitQuestion(created.object.id, events);
      } finally {
        events.close();
      }
    }
    return 0;
  } finally {
    client.close();
  }
}

if (argv[0] === "ask") {
  try {
    process.exitCode = await ask(argv.slice(1));
  } catch (error) {
    if (error instanceof CanvasError) console.error(`${error.code}: ${error.message}`);
    else console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
  process.exit();
}

/**
 * The argv of `easl agent spawn --command`: a JSON array of strings as given (when it starts with
 * `[`), else the words a POSIX shell would split it into: whitespace separates; '…' is literal;
 * "…" keeps backslash escapes of " \ $ ` only; a backslash outside quotes escapes the next character.
 */
function commandArgv(value: string): string[] {
  if (value.trimStart().startsWith("[")) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(value);
    } catch (error) {
      throw new CanvasError("invalid_params", `--command: not a JSON array (${(error as Error).message})`);
    }
    if (!Array.isArray(parsed) || parsed.length === 0 || !parsed.every((item) => typeof item === "string")) {
      throw new CanvasError("invalid_params", "--command: a JSON array of strings, the program first");
    }
    return parsed;
  }
  const words: string[] = [];
  let word = "";
  let inWord = false; // '' and "" make an empty word
  let quote: "'" | '"' | undefined;
  for (let i = 0; i < value.length; i++) {
    const char = value[i];
    if (quote === "'") {
      if (char === "'") quote = undefined;
      else word += char;
    } else if (quote === '"') {
      if (char === '"') quote = undefined;
      else if (char === "\\" && '"\\$`'.includes(value[i + 1] ?? "x")) word += value[++i];
      else word += char;
    } else if (/\s/.test(char)) {
      if (inWord) words.push(word);
      word = "";
      inWord = false;
    } else {
      inWord = true;
      if (char === "'" || char === '"') quote = char;
      else if (char === "\\" && i + 1 < value.length) word += value[++i];
      else word += char;
    }
  }
  if (quote) throw new CanvasError("invalid_params", `--command: unterminated ${quote} quote`);
  if (inWord) words.push(word);
  if (words.length === 0) throw new CanvasError("invalid_params", "--command names no program");
  return words;
}

type SpawnOptions = { name: string; cwd: string; command: string[]; board?: string; prompt?: string; wait: boolean; timeoutMs: number };

/** `easl agent spawn`'s flags; values are taken as typed (`--prompt --help` is a prompt). */
function spawnOptions(args: string[]): SpawnOptions {
  const values: Record<string, string> = {};
  let wait = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--wait") {
      wait = true;
      continue;
    }
    const key = args[i].slice(2);
    if (!args[i].startsWith("--") || !["name", "cwd", "command", "board", "prompt", "timeout"].includes(key) || args[i + 1] === undefined) usage();
    values[key] = args[++i];
  }
  if (!values.name || values.command === undefined) usage();
  const timeoutMs = values.timeout === undefined ? SPAWN_TIMEOUT_MS : Number(values.timeout);
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) throw new CanvasError("invalid_params", `--timeout is a positive number of milliseconds, not ${values.timeout}`);
  return { name: values.name, cwd: resolve(values.cwd ?? "."), command: commandArgv(values.command), board: values.board, prompt: values.prompt, wait, timeoutMs };
}

/**
 * Waits for a just-spawned terminal's agent to be ready (idle or done) by `deadline`. Its lifecycle
 * is unknown until its first report, and agent.wait gives such a terminal 15 s before answering
 * `unavailable`, so those answers are retried until the deadline.
 */
async function untilReady(client: CanvasClient, tile: string, deadline: number, timeoutMs: number): Promise<Agent> {
  let last = "";
  for (;;) {
    const left = deadline - Date.now();
    if (left <= 0) throw new CanvasError("timeout", `${tile}'s agent was not ready (idle) within ${timeoutMs} ms${last && `; last: ${last}`}`);
    try {
      return (await client.api.agent.wait({ target: tile, until: ["idle", "done"], timeoutMs: left })).agent;
    } catch (error) {
      if (!(error instanceof CanvasError) || error.code !== "unavailable") throw error;
      last = error.message;
    }
    await Bun.sleep(Math.min(SPAWN_RETRY_MS, Math.max(0, deadline - Date.now())));
  }
}

/** `easl agent spawn`: the terminal (object.create), then, as asked, its readiness, the prompt, and that prompt's turn. */
async function spawnAgent(client: CanvasClient, options: SpawnOptions): Promise<Record<string, unknown>> {
  const deadline = Date.now() + options.timeoutMs;
  const { object } = await client.api.object.create({ board: options.board, type: "terminal", props: { name: options.name, cwd: options.cwd, command: options.command } });
  const tile = object.id;
  let agent: Agent | undefined;
  let prompted: boolean | undefined;
  try {
    if (options.prompt !== undefined || options.wait) agent = await untilReady(client, tile, deadline, options.timeoutMs);
    if (options.prompt !== undefined) {
      agent = (await client.api.agent.prompt({ target: tile, text: options.prompt })).agent;
      prompted = true;
      if (options.wait) agent = (await client.api.agent.wait({ target: tile })).agent;
    }
  } catch (error) {
    // The terminal stays: say which, so the caller can use or close it.
    if (error instanceof CanvasError) throw new CanvasError(error.code, `${error.message} (spawned terminal ${tile}${prompted ? ", prompted" : ""})`, error.data);
    throw error;
  }
  const board = agent?.board ?? options.board ?? client.boardId ?? (await client.api.agent.list({})).agents.find((entry) => entry.tile === tile)?.board;
  return { tile, name: options.name, board, command: options.command, prompted, agent };
}

if (argv[0] === "agent" && argv[1] === "spawn") {
  let client: CanvasClient | undefined;
  try {
    const options = spawnOptions(argv.slice(2));
    client = new CanvasClient();
    console.log(JSON.stringify(await spawnAgent(client, options), null, 2));
  } catch (error) {
    if (error instanceof CanvasError) console.error(`${error.code}: ${error.message}`);
    else console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  } finally {
    client?.close();
  }
  process.exit();
}

let method: string;
let rest: string[];
let target: unknown;
if (argv[0] === "get") {
  method = "object.get";
  rest = ["--id", argv[1] ?? usage(), ...argv.slice(2)];
} else if (argv[0] === "tell") {
  // A message to another agent: `--from` names a script sender, `--when next-turn` waits for its running turn to end.
  method = "agent.prompt";
  rest = ["--target", argv[1] ?? usage(), "--text", argv[2] ?? usage(), ...argv.slice(3)];
} else if (argv[0] === "render") {
  method = "view.render";
  rest = argv.slice(2);
  const parts = (argv[1] ?? usage()).split(",").map((part) => part.trim()).filter(Boolean);
  const numbers = parts.map(Number);
  if (parts.length === 4 && numbers.every(Number.isFinite)) target = { x: numbers[0], y: numbers[1], w: numbers[2], h: numbers[3] };
  else target = parts.length === 1 ? parts[0] : parts;
} else if (argv[0].includes(".")) {
  method = argv[0];
  rest = argv.slice(1);
} else {
  method = `${argv[0]}.${argv[1] ?? usage()}`;
  rest = argv.slice(2);
}

const spec = methods[method];
if (!spec) {
  console.error(`unknown method: ${method} (run \`easl methods\`)`);
  process.exit(2);
}

let client: CanvasClient | undefined;
try {
  const params = parseArgs(rest, spec.params);
  if (target !== undefined) params.target = target;
  if (method === "object.get" && params.as === "image") {
    throw new CanvasError("invalid_params", "`get --as image` was removed; use `easl render <id>` (view.render)");
  }
  // `--full` is the CLI's own flag for methods that don't take `full` (view.render does).
  const elide = (method === "object.create" || method === "object.update") && params.full !== true;
  if (!(spec.params.properties && "full" in spec.params.properties)) delete params.full;
  const envKeys = Object.keys(spec.params.properties ?? {}).filter((k) => k in ENV_DEFAULTS);
  client = new CanvasClient();
  const result = (await client.call(method, params, envKeys)) as { object?: { props?: Record<string, unknown> } };
  // A 28 KB HTML page echoed back buries the result; the app's reply itself is whole.
  const props = elide ? result.object?.props : undefined;
  for (const [key, value] of Object.entries(props ?? {})) {
    const bytes = Buffer.byteLength(typeof value === "string" ? value : JSON.stringify(value));
    if (bytes > ELIDE_BYTES) props![key] = `(${bytes} bytes elided; --full prints it)`;
  }
  console.log(JSON.stringify(result, null, 2));
} catch (error) {
  if (error instanceof CanvasError) console.error(`${error.code}: ${error.message}`);
  else console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
} finally {
  client?.close();
}

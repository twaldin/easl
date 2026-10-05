#!/usr/bin/env bun
// easl CLI: a thin, schema-driven client for agents without a persistent REPL.
//   easl methods                         every method with its description
//   easl methods <name>                  one method's params, result, and referenced types; or one type (CodeProps)
//   easl <namespace>.<method> [--json '{...}' | --json @file | --json @-] [--key value] [--nested.key value] [--flag]
//   easl <namespace> <method> ...
//   easl get <id> [--as raw|graph]       object.get
//   easl render <id|id,id|x,y,w,h> [--out f.png] [--scale 2] [--full] ...   view.render
//   easl browser <verb> [<tile>] [--key value] ...   browser tiles over the cmux subset (below)
//   easl metrics [--watch] [--reset] [--json]       app.metrics as text (--watch: every second)
// view.render and view.snapshot write the image to --out (relative to the cwd; format from the
// extension) or, without it, to a new file under $TMPDIR/easl-renders/, and print the result
// metadata with its `path`; so does `browser screenshot`. object.create/update print prop values
// over 1 KB elided (`--full` prints them whole); what the app returns is unchanged.
// Connection: EASL_SOCKET, EASL_TILE_ID, EASL_BOARD_ID (every easl terminal tile sets them);
// `browser`: CMUX_SOCKET_PATH (else cmux.sock beside the easl socket), CMUX_SURFACE_ID,
// CMUX_SOCKET_PASSWORD.
// Errors print `code: message` to stderr and exit 1.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import catalog from "../schema/easl-api.json";
import { CanvasClient, CanvasError, DEFAULT_SOCKET, ENV_DEFAULTS } from "../clients/ts/src/index";

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

function usage(help = false): never {
  const lines = [
    "usage: easl methods [<name>]",
    "       easl <namespace>.<method> [--json '{...}' | --json @file | --json @-] [--key value] [--flag]",
    "       easl get <id> [--as graph]",
    "       easl render <id|id,id|x,y,w,h> [--out file.png] [--scale 2] [--full]",
    "       easl browser <verb> [<tile>] [--key value] [--json '{...}']   (open [url] | list | close | navigate, snapshot, click, …)",
    "       easl metrics [--watch] [--reset] [--json]",
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
  for (const h of m.process.helpers ?? []) lines.push(`         ${h.name} ${h.pid}: ${h.footprintMB} MB${h.cpuPercent === undefined ? "" : `, ${h.cpuPercent}%`}`);
  const api = Object.keys(m.counters)
    .filter((k) => k.startsWith("api.main."))
    .map((k) => ({ method: k.slice("api.main.".length), main: c(k, "total"), call: c(`api.${k.slice("api.main.".length)}`, "total") }))
    .sort((a, b) => (b.main.ms ?? 0) - (a.main.ms ?? 0));
  lines.push("api      (since reset) method: calls, main-thread ms (max), reply bytes");
  for (const a of api.slice(0, 8)) lines.push(`         ${a.method}: ${a.main.n}, ${ms(a.main.ms)} ms (${ms(a.main.maxMs)}), ${kb(a.call.bytes)}`);
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
  try {
    do {
      const metrics = (await client.call("app.metrics", { reset: flags.has("--reset") && !flags.has("--watch"), watch: flags.has("--watch") })) as Metrics;
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

let method: string;
let rest: string[];
let target: unknown;
if (argv[0] === "get") {
  method = "object.get";
  rest = ["--id", argv[1] ?? usage(), ...argv.slice(2)];
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

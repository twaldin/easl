import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const cli = resolve(import.meta.dir, "../bin/easl");

async function run(args: readonly string[], socket: string) {
  const proc = Bun.spawn([cli, ...args], {
    env: { ...process.env, EASL_SOCKET: socket, CMUX_SOCKET_PATH: socket, CMUX_SOCKET_PASSWORD: "" },
    stdout: "pipe",
    stderr: "pipe",
    timeout: 2000,
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  return { stdout, stderr, code };
}

const forms = [
  ["view.render", "--help"],
  ["object.create", "-h"],
  ["view", "render", "-h"],
  ["browser", "navigate", "--help"],
  ["browser", "navigate", "-h"],
  ["--help"],
  ["-h"],
  ["help", "view.render"],
  ["help", "browser", "navigate"],
  ["view.render", "--json", "@missing-help-params.json", "--help"],
  ["render", "--help"],
];

test("help exits successfully without a running server and describes the requested command", async () => {
  const dir = mkdtempSync(join(tmpdir(), "easl-help-"));
  try {
    for (const args of forms) {
      const result = await run(args, join(dir, "missing.sock"));
      expect(result.code, args.join(" ")).toBe(0);
      expect(result.stderr).toBe("");
      if (args.includes("object.create")) {
        expect(result.stdout).toContain("type: ObjectType (required)");
        expect(result.stdout).toContain("props: object (required)");
        expect(result.stdout).toContain("object: CanvasObject");
      } else if (args.includes("browser")) {
        expect(result.stdout).toContain("browser.navigate");
        expect(result.stdout).toContain("url: string (required)");
        expect(result.stdout).toContain("surface_id: string (required)");
        expect(result.stdout).toContain("result:");
      } else if (args.length > 1) {
        expect(result.stdout).toContain("view.render");
        expect(result.stdout).toContain("target: Id | Id[] | Frame (required)");
        expect(result.stdout).toContain("scale: number (optional, default 1, range 0.1..4)");
        expect(result.stdout).toContain("pixels per board point");
        expect(result.stdout).toContain("result:");
        expect(result.stdout).toContain("width: integer");
      } else {
        expect(result.stdout).toContain("usage: easl");
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}, 20_000);

test("help never connects even when a socket is listening", async () => {
  const dir = mkdtempSync(join(tmpdir(), "easl-help-"));
  const socket = join(dir, "trap.sock");
  let connections = 0;
  const server = createServer((connection) => {
    connections++;
    connection.destroy();
  });
  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(socket, resolve);
    });
    for (const args of forms) {
      const result = await run(args, socket);
      expect(result.code, args.join(" ")).toBe(0);
      expect(result.stdout).toContain(args.includes("browser") ? "browser.navigate" : args.includes("object.create") ? "object.create" : args.length > 1 ? "view.render" : "usage: easl");
    }
    for (const [args, expected] of [
      [["help", "tell", "bob"], "agent.prompt"],
      [["help", "agent", "spawn", "--name", "x", "--command", "sh", "--prompt"], "usage: easl"],
      [["help", "metrics"], "usage: easl"],
      [["help", "CodeProps"], "fields:"],
      [["help", "--help"], "usage: easl"],
    ] as const) {
      const result = await run(args, socket);
      expect(result.code, args.join(" ")).toBe(0);
      expect(result.stdout).toContain(expected);
    }
    expect(connections).toBe(0);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(dir, { recursive: true, force: true });
  }
}, 20_000);

test("unknown method help fails locally and suggests the closest method", async () => {
  const dir = mkdtempSync(join(tmpdir(), "easl-help-"));
  try {
    for (const args of [["view.rendr", "--help"], ["browser", "navigat", "--help"], ["browser", "opne", "-h"]]) {
      const result = await run(args, join(dir, "missing.sock"));
      expect(result.code).toBe(2);
      expect(result.stderr).toContain("unknown method");
      expect(result.stderr).toContain(args[0] !== "browser" ? "view.render" : args[1] === "opne" ? "browser open" : "browser navigate");
      expect(result.stdout).toBe("");
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a short help token used as a flag value remains request data", async () => {
  const dir = mkdtempSync(join(tmpdir(), "easl-help-"));
  const socket = join(dir, "server.sock");
  const requests: unknown[] = [];
  const server = createServer((connection) => {
    let buffer = "";
    connection.on("data", (chunk) => {
      buffer += chunk.toString();
      if (!buffer.includes("\n")) return;
      const request: unknown = JSON.parse(buffer.slice(0, buffer.indexOf("\n")));
      if (typeof request !== "object" || request === null || !("id" in request)) throw new Error("invalid CLI request");
      requests.push(request);
      connection.end(`${JSON.stringify({ id: request.id, ok: true, result: {} })}\n`);
    });
  });
  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(socket, resolve);
    });
    for (const args of [
      ["agent.prompt", "--target", "bob", "--text", "-h"],
      ["object.update", "--id", "obj_x", "--props.text", "-h"],
      ["browser", "type", "obj_x", "--selector", "#q", "--text", "-h"],
    ]) {
      const result = await run(args, socket);
      expect(result.code).toBe(0);
      expect(result.stderr).toBe("");
    }
    expect(requests).toMatchObject([
      { method: "agent.prompt", params: { target: "bob", text: "-h" } },
      { method: "object.update", params: { id: "obj_x", props: { text: "-h" } } },
      { method: "browser.type", params: { surface_id: "obj_x", selector: "#q", text: "-h" } },
    ]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(dir, { recursive: true, force: true });
  }
});

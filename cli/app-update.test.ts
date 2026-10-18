import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const cli = resolve(import.meta.dir, "../bin/easl");

async function run(args: string[], socket: string) {
  const proc = Bun.spawn([cli, ...args], {
    env: { ...process.env, EASL_SOCKET: socket },
    stdout: "ignore",
    stderr: "ignore",
    timeout: 2000,
  });
  await proc.exited;
}

test("app.update positional and flag modes send the expected protocol requests", async () => {
  const dir = mkdtempSync(join(tmpdir(), "easl-update-"));
  const socket = join(dir, "server.sock");
  const requests: unknown[] = [];
  const server = createServer((connection) => {
    let buffer = "";
    connection.on("data", (chunk) => {
      buffer += chunk.toString();
      if (!buffer.includes("\n")) return;
      const request = JSON.parse(buffer.slice(0, buffer.indexOf("\n")));
      requests.push({ method: request.method, params: request.params });
      connection.end(`${JSON.stringify({ id: request.id, ok: true, result: null })}\n`);
    });
  });
  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(socket, resolve);
    });
    for (const args of [
      ["app.update", "check"], ["app.update", "install"],
      ["app.update", "--mode", "check"], ["app.update", "--mode", "install"],
      ["app", "update", "check"], ["app", "update", "--mode", "install"],
    ]) {
      await run(args, socket);
    }
    expect(requests).toEqual([
      { method: "app.update", params: { mode: "check" } },
      { method: "app.update", params: { mode: "install" } },
      { method: "app.update", params: { mode: "check" } },
      { method: "app.update", params: { mode: "install" } },
      { method: "app.update", params: { mode: "check" } },
      { method: "app.update", params: { mode: "install" } },
    ]);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    rmSync(dir, { recursive: true, force: true });
  }
});

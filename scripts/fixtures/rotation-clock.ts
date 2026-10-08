// Test-only preload advances long phase deadlines or rejects a stream read; success and child-kill timing use the real clock.
import { readFileSync, watch } from "node:fs";

type ClockState = { clockOffsetMs?: number; rejectStdout?: boolean; hungPid?: number };
const stateFile = process.env.ROTATION_FIXTURE_STATE!;
const state = (): ClockState => JSON.parse(readFileSync(stateFile, "utf8"));
const now = Date.now;
Date.now = () => now() + (state().clockOffsetMs ?? 0);

if (state().rejectStdout) {
  const text = Response.prototype.text;
  let rejected = false;
  Response.prototype.text = function() {
    if (rejected) return text.call(this);
    rejected = true;
    return (async () => {
      if (!state().hungPid) await new Promise<void>((resolve) => {
        const watcher = watch(stateFile, () => {
          if (state().hungPid) { watcher.close(); resolve(); }
        });
        if (state().hungPid) { watcher.close(); resolve(); }
      });
      throw new Error("fixture stdout read rejected");
    })();
  };
}

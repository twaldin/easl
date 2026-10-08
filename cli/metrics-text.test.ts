// bun test cli — `easl metrics` text: the lines that only show when their counters have values.
import { expect, test } from "bun:test";
import { metricsText, type Metrics } from "./metrics-text";

const base = (): Metrics => ({
  uptimeS: 120, sinceS: 120, counters: {}, gauges: {}, top: {},
  process: { footprintMB: 300, peakFootprintMB: 310, windows: { last60s: { cpuPercent: 3, interruptWakeupsPerS: 40 } } },
});
const tally = (last60s: number, total: number) => ({ total: { n: total }, last60s: { n: last60s }, last10m: { n: last60s } });

test("draws show as a per-second rate over the 60 s window with the launch total and live terminals", () => {
  const m = base();
  m.counters["terminal.draw"] = tally(3570, 20000);
  m.gauges["live.TerminalTile"] = 15;
  expect(metricsText(m)).toContain("draws    59.5/s over 60 s (total 20000); terminals live 15");
});

test("no draws line before any terminal drew, no keys line before any key, no stalls line before a sample", () => {
  const m = base();
  m.stalls = { sampled: 0 };
  const text = metricsText(m);
  expect(text).not.toContain("draws");
  expect(text).not.toContain("keys ");
  expect(text).not.toContain("stalls");
});

test("stalls name the count sampled since launch and the newest file", () => {
  const m = base();
  m.stalls = { sampled: 3, newest: "stalls/2026-10-08T051210Z.txt" };
  expect(metricsText(m)).toContain("stalls   3 sampled since launch, newest stalls/2026-10-08T051210Z.txt");
});

test("keys report the 60 s window's mean and max wait and the launch total's max", () => {
  const m = base();
  m.counters["key.wait"] = { total: { n: 200, ms: 1000, maxMs: 1890 }, last60s: { n: 20, ms: 100, maxMs: 47.3 }, last10m: { n: 20, ms: 100, maxMs: 47.3 } };
  m.counters["key.handle"] = { total: { n: 200, ms: 20, maxMs: 1.4 }, last60s: { n: 20, ms: 2, maxMs: 1.4 }, last10m: { n: 20, ms: 2, maxMs: 1.4 } };
  expect(metricsText(m)).toContain("keys     20 (total 200), waited 5.0 ms mean, 47.3 ms max (total max 1890); handling 1.4 ms max");
});

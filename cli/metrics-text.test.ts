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

test("no draws line before any terminal drew, and no keys line before any key", () => {
  const text = metricsText(base());
  expect(text).not.toContain("draws");
  expect(text).not.toContain("keys ");
});

test("keys report the 60 s window's mean and max wait and the launch total's max", () => {
  const m = base();
  m.counters["key.wait"] = { total: { n: 200, ms: 1000, maxMs: 1890 }, last60s: { n: 20, ms: 100, maxMs: 47.3 }, last10m: { n: 20, ms: 100, maxMs: 47.3 } };
  m.counters["key.handle"] = { total: { n: 200, ms: 20, maxMs: 1.4 }, last60s: { n: 20, ms: 2, maxMs: 1.4 }, last10m: { n: 20, ms: 2, maxMs: 1.4 } };
  expect(metricsText(m)).toContain("keys     20 (total 200), waited 5.0 ms mean, 47.3 ms max (total max 1890); handling 1.4 ms max");
});

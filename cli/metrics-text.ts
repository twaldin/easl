// `easl metrics` as text (`metricsText`), apart from the CLI so `bun test cli` can read it.
export type Tally = { n: number; ms?: number; maxMs?: number; bytes?: number };
export type Metrics = {
  uptimeS: number;
  sinceS: number;
  counters: Record<string, Record<"total" | "last60s" | "last10m", Tally>>;
  gauges: Record<string, number>;
  top: Record<string, { key: string; n: number; ms?: number }[]>;
  longest?: { ms: number; cause: string; agoS: number };
  stalls?: { sampled: number; newest?: string };
  process: { footprintMB?: number; peakFootprintMB?: number; windows?: Record<string, Record<string, number>>; helpers?: { pid: number; name: string; footprintMB: number; cpuPercent?: number }[] };
};

/** app.metrics as a few lines of text: the 60 s window, with launch totals where they say more. */
export function metricsText(m: Metrics): string {
  const c = (name: string, w: "total" | "last60s" | "last10m" = "last60s"): Tally => m.counters[name]?.[w] ?? { n: 0 };
  const ms = (v = 0) => (v >= 100 ? v.toFixed(0) : v.toFixed(1));
  const kb = (v = 0) => `${Math.round(v / 1024)} KB`;
  const p = m.process.windows?.last60s ?? {};
  const lines = [
    `uptime ${Math.round(m.uptimeS)} s; totals since ${Math.round(m.sinceS)} s ago, rates over the last 60 s`,
    `main     busy ${ms((c("main.busy").ms ?? 0) / 600)}%  stretches ≥50 ms ${c("main.stretch50").n} (total ${c("main.stretch50", "total").n})  ≥250 ms ${c("main.stretch250").n} (total ${c("main.stretch250", "total").n})`,
  ];
  if (m.longest) lines.push(`         longest ${Math.round(m.longest.ms)} ms, ${Math.round(m.longest.agoS)} s ago: ${m.longest.cause}`);
  // Main-thread stalls of a second or more that the app `sample`d itself through (<home>/stalls/, newest 20 kept).
  if (m.stalls?.sampled) lines.push(`stalls   ${m.stalls.sampled} sampled since launch, newest ${m.stalls.newest}`);
  lines.push(`process  cpu ${p.cpuPercent ?? 0}%  wakeups ${p.interruptWakeupsPerS ?? 0}/s  memory ${m.process.footprintMB ?? 0} MB (peak ${m.process.peakFootprintMB ?? 0})`);
  const keys = c("key.wait"), keysTotal = c("key.wait", "total");
  if (keysTotal.n) {
    // How long keys into terminals waited for the main thread (a stall holds them) and how long handing them to Ghostty took.
    lines.push(`keys     ${keys.n} (total ${keysTotal.n}), waited ${ms((keys.ms ?? 0) / (keys.n || 1))} ms mean, ${ms(keys.maxMs)} ms max (total max ${ms(keysTotal.maxMs)}); handling ${ms(c("key.handle").maxMs)} ms max`);
  }
  const draws = c("terminal.draw"), drawsTotal = c("terminal.draw", "total");
  if (drawsTotal.n) {
    // The wrapper's terminal redraws: a board nobody is watching should show few (IdleRedraw, ~2 per terminal per second).
    lines.push(`draws    ${(draws.n / 60).toFixed(1)}/s over 60 s (total ${drawsTotal.n}); terminals live ${m.gauges["live.TerminalTile"] ?? 0}`);
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

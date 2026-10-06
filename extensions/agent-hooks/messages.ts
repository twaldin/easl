// Out-of-band messages (docs/contracts.md, Peer messages): what an integration that takes
// messages (agent.report `protocol` 1, `agent.inbox`) does with them. omp's extension uses it;
// the rules live here so they are tested without an agent.
import type { AgentMessage } from "../../clients/ts/src/index";

/** The integration protocol this checkout's integrations speak: 1 takes messages. */
export const PROTOCOL = 1;
/** Each sender may wake a receiver this often per hour; past that its messages ride the next turn. */
export const WAKES_PER_HOUR = 20;
const HOUR_MS = 3_600_000;
/** Messages arriving this close together are delivered as one. */
export const COALESCE_MS = 250;

/** `agent://<name>` or `agent://<name>@<board>`, as omp's `write` takes it. */
const PEER = /^agent:\/\/([^/@\s]+)(?:@([^/@\s]+))?\/?$/;

/** The easl address an `agent://` path names, or none (another path, or `agent://all`). */
export function peerAddress(path: string): string | undefined {
  const match = PEER.exec(path);
  if (!match || match[1] === "all") return undefined;
  const name = decodeURIComponent(match[1]);
  return match[2] === undefined ? name : `${name}@${decodeURIComponent(match[2])}`;
}

/** Who sent `message`, for the wake bound: its terminal, else the script's label. */
export function senderKey(message: AgentMessage): string {
  return message.from.tile ?? `script:${message.from.name}`;
}

/**
 * The line ahead of a message: its id, who sent it and how to reply. The id is how the
 * integration knows omp recorded the message (`recordedIds`); the reply's `agent://` URI has its
 * name and board percent-encoded, which `peerAddress` decodes.
 */
export function header(message: AgentMessage): string {
  const from = message.from;
  const intro = `[message ${message.id} from`;
  if (!from.tile) return `${intro} ${from.name}, a script; no reply address]`;
  if (!from.address) return `${intro} terminal ${from.tile}, closed since it sent this; no reply address]`;
  const named = from.address === from.tile ? `terminal ${from.tile}` : `${from.address} (terminal ${from.tile})`;
  const at = from.address.lastIndexOf("@");
  const uri = at < 0 ? encodeURIComponent(from.address) : `${encodeURIComponent(from.address.slice(0, at))}@${encodeURIComponent(from.address.slice(at + 1))}`;
  return `${intro} ${named}; reply with write agent://${uri}]`;
}

/** The ids of the messages whose headers a user message carries: the messages omp recorded with it. */
export function recordedIds(text: string): string[] {
  return [...text.matchAll(/^\[message (msg_[\w-]+) from /gm)].map((match) => match[1]);
}

/** What one delivery hands the agent: each message under its header, its mentions' block after its text. */
export function deliveryText(messages: readonly AgentMessage[]): string {
  return messages.map((message) => [header(message), message.text.trim(), message.context].filter(Boolean).join("\n")).join("\n\n");
}

/** How a message goes in now. */
export type Plan =
  | "steer" // into the running turn, at its next step (cuts an interruptible tool short)
  | "turn" // a new turn: the agent is idle
  | "aside" // into the step omp is streaming, without interrupting it (over the wake bound: no wake)
  | "after-turn" // held until the running turn ends (`next-turn`)
  | "next-start"; // held until the agent's next turn starts (over the wake bound, nothing streaming)

/**
 * Where a message goes given whether its sender may wake the agent now and the agent's state:
 * `turn`, in its turn as it reports (also while omp awaits background work that will resume
 * it); `streaming`, omp running a step now, so an aside joins it instead of starting a turn.
 */
export function plan(when: AgentMessage["when"], state: { turn: boolean; streaming: boolean; mayWake: boolean }): Plan {
  if (state.turn && when === "next-turn") return "after-turn";
  if (!state.mayWake) return state.streaming ? "aside" : "next-start";
  return state.turn ? "steer" : "turn";
}

/** At most `limit` wakes per sender within `windowMs`. */
export class WakeBudget {
  readonly #wakes = new Map<string, number[]>();
  constructor(
    readonly limit = WAKES_PER_HOUR,
    readonly windowMs = HOUR_MS,
  ) {}

  /** Whether every one of `senders` may wake the agent now (nothing is recorded). */
  allows(senders: Iterable<string>, now = Date.now()): boolean {
    for (const sender of senders) if (this.#recent(sender, now).length >= this.limit) return false;
    return true;
  }

  /** Records one wake by each of `senders`. */
  spend(senders: Iterable<string>, now = Date.now()): void {
    for (const sender of senders) this.#wakes.set(sender, [...this.#recent(sender, now), now]);
  }

  #recent(sender: string, now: number): number[] {
    return (this.#wakes.get(sender) ?? []).filter((at) => now - at < this.windowMs);
  }
}

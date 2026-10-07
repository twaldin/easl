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
 * The custom message omp makes of an IRC message to its agent: its TUI draws it as a card
 * (`IRC ← <from>` over the quoted text), and session history and retros print it as
 * `[irc] <from> → me: <text>`, apart from the user's prompts.
 */
export const IRC_INCOMING = "irc:incoming";

/** A card's `details`: the fields omp's card and history read, and the messages it carries. */
export type CardDetails = {
  /** the message's id (a burst's first) */
  id: string;
  /** who sent it (`sender`; a burst's senders, joined) */
  from: string;
  /** what the sender wrote, unescaped (a burst's texts, joined) */
  message: string;
  /** every message the card carries, acked once omp records it */
  easl: { ids: string[] };
};

/** One delivery as omp's `pi.sendMessage` takes it. */
export type Card = { customType: typeof IRC_INCOMING; content: string; display: true; details: CardDetails; attribution: AgentMessage["attribution"] };

/**
 * One delivery as one card: a burst goes in as one message, so it is steered, starts a turn, is
 * recorded and acked as a whole. The content, what the model reads, has each message in omp's
 * IRC envelope (`envelope`).
 */
export function card(messages: readonly AgentMessage[]): Card {
  const ids = messages.map((message) => message.id);
  return {
    customType: IRC_INCOMING,
    content: messages.map(envelope).join("\n\n"),
    display: true,
    details: { id: ids[0], from: [...new Set(messages.map(sender))].join(", "), message: messages.map((message) => message.text.trim()).join("\n\n"), easl: { ids } },
    // A script's message is on the user's behalf: with one among them, the delivery is the user's.
    attribution: messages.some((message) => message.attribution === "user") ? "user" : "agent",
  };
}

/** Who sent a message: its terminal's address, else the script's label or the closed terminal's id. */
export function sender(message: AgentMessage): string {
  return message.from.address ?? message.from.name;
}

/**
 * One message as omp's own IRC envelope puts it: its id, who sent it and how to reply (the
 * `agent://` path with the address's name and board percent-encoded, which `peerAddress`
 * decodes), then its text and its mentions' block. What others wrote can't close the envelope or
 * open a harness block of its own.
 */
function envelope(message: AgentMessage): string {
  const from = message.from;
  const who = !from.tile ? `\`${from.name}\`, a script` : !from.address ? `terminal ${from.tile}, closed since it sent this` : from.address === from.tile ? `terminal ${from.tile}` : `\`${from.address}\` (terminal ${from.tile})`;
  const reply = from.tile && from.address ? `If a response is expected, reply via \`write\` (\`path: "${replyPath(from.address)}"\`, \`content: "…"\`).` : "It has no reply address.";
  // omp's escapeHarnessTags: what others wrote reaches the model as written, but for `<` of an
  // `irc` or `system-*` tag.
  const said = `Incoming easl message ${message.id} from ${who}:\n\n${[message.text.trim(), message.context].filter(Boolean).join("\n\n")}`;
  return `<irc>\n${said.replace(HARNESS_TAG, "&lt;")}\n\n${reply}\n</irc>`;
}

/** `agent://<address>` as omp's `write` takes it, the name and board percent-encoded. */
function replyPath(address: string): string {
  const at = address.lastIndexOf("@");
  return `agent://${at < 0 ? encodeURIComponent(address) : `${encodeURIComponent(address.slice(0, at))}@${encodeURIComponent(address.slice(at + 1))}`}`;
}

/** The `<` of an `irc` or `system-*` tag (omp's harness tags), opening or closing. */
const HARNESS_TAG = /<(?=\s*\/?\s*(?:irc|system-[a-z][a-z-]*)(?![\w-]))/gi;

/** The fields of an omp session message `recordedIds` reads. */
export type Recorded = { role?: unknown; customType?: unknown; toolName?: unknown; details?: unknown; timestamp?: unknown };

/**
 * The ids of the easl messages omp recorded with `message`: an easl card's, or the one omp's
 * `wait` took from its queue as its result instead of injecting the card (that card's `id`).
 */
export function recordedIds(message: Recorded): string[] {
  const details = message.details;
  if (!details || typeof details !== "object") return [];
  if (message.role === "custom" && message.customType === IRC_INCOMING) {
    const easl = "easl" in details ? details.easl : undefined;
    const ids = easl && typeof easl === "object" && "ids" in easl ? easl.ids : undefined;
    return Array.isArray(ids) ? ids.filter((id): id is string => typeof id === "string") : [];
  }
  if (message.role !== "toolResult" || message.toolName !== "wait" || !("waited" in details)) return [];
  const waited = details.waited;
  return waited && typeof waited === "object" && "id" in waited && typeof waited.id === "string" ? [waited.id] : [];
}

/** The hidden context `guided` adds: omp hands it to the model as developer context, and never records it. */
export const GUIDANCE = "easl.guidance";
export type Guidance = { role: "custom"; customType: typeof GUIDANCE; content: string; display: false; attribution: "agent"; timestamp: number };

/**
 * One request's messages with `text` as hidden context: just before the card carrying one of
 * `ids` (the card that started the turn), else before the last message, so the request ends on
 * what it ended on.
 */
export function guided<M extends Recorded>(messages: readonly M[], ids: ReadonlySet<string>, text: string): (M | Guidance)[] {
  const found = messages.findIndex((message) => recordedIds(message).some((id) => ids.has(id)));
  const at = found >= 0 ? found : Math.max(messages.length - 1, 0);
  const stamp = messages[at]?.timestamp;
  const guidance: Guidance = { role: "custom", customType: GUIDANCE, content: text, display: false, attribution: "agent", timestamp: typeof stamp === "number" ? stamp : Date.now() };
  return [...messages.slice(0, at), guidance, ...messages.slice(at)];
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

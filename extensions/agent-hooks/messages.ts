// Out-of-band messages (docs/contracts.md, Peer messages): what an integration that takes
// messages (agent.report `protocol` 1, `agent.inbox`) does with them. omp's extension uses it;
// the rules live here so they are tested without an agent.
import type { MessageRenderer } from "@oh-my-pi/pi-coding-agent";
import type { Component } from "@oh-my-pi/pi-tui";
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

/** agent.prompt `message`: an id of the sender's own, the same on every attempt at one message. */
export const MESSAGE_ID = /^msg_[A-Za-z0-9_-]{8,64}$/;

/**
 * The id every attempt at one `write agent://` sends its message with. omp runs a tool's
 * `tool_result` handlers in turn, each seeing the result the last one left: one that tried and
 * failed leaves the id it sent in `details.easl.message` (its prompt may have timed out and still
 * been queued), and the next sends that id again, which easl queues once. None left: a new one.
 */
export function writeMessageId(details: unknown): string {
  const given = (details as { easl?: { message?: unknown } } | undefined)?.easl?.message;
  return typeof given === "string" && MESSAGE_ID.test(given) ? given : `msg_${crypto.randomUUID().replaceAll("-", "")}`;
}

/** Who sent `message`, for the wake bound: its terminal, else the script's label. */
export function senderKey(message: AgentMessage): string {
  return message.from.tile ?? `script:${message.from.name}`;
}

/**
 * easl's custom message type for a delivery. The extension draws it as omp draws its own IRC
 * messages (`renderCard`), and omp's session history and retros print it as
 * `[easl:message] <irc> Message from …`, apart from the user's prompts. Not omp's `irc:incoming`:
 * omp's own IRC handling would take that over (its `wait` returns one as a bare text result, and
 * one left over at a run's end wakes the agent even after the user stopped it).
 */
export const EASL_MESSAGE = "easl:message";

/** A card's `details`: what its look reads, and the messages it carries. */
export type CardDetails = {
  /** the message's id (a burst's first) */
  id: string;
  /** who sent it (`sender`; a burst's senders, joined) */
  from: string;
  /** what the sender wrote, unescaped (a burst's texts, joined) */
  message: string;
  /** every message the card carries, acked once omp records it */
  ids: string[];
};

/** One delivery as omp's `pi.sendMessage` takes it. */
export type Card = { customType: typeof EASL_MESSAGE; content: string; display: true; details: CardDetails; attribution: AgentMessage["attribution"] };

/**
 * One delivery as one card: a burst goes in as one message, so it is steered, starts a turn, is
 * recorded and acked as a whole. The content, what the model reads, has each message in an IRC
 * envelope as omp's own (`envelope`).
 */
export function card(messages: readonly AgentMessage[]): Card {
  const ids = messages.map((message) => message.id);
  return {
    customType: EASL_MESSAGE,
    content: messages.map(envelope).join("\n\n"),
    display: true,
    details: { id: ids[0], from: [...new Set(messages.map(sender))].join(", "), message: messages.map((message) => message.text.trim()).join("\n\n"), ids },
    // A script's message is on the user's behalf: with one among them, the delivery is the user's.
    attribution: messages.some((message) => message.attribution === "user") ? "user" : "agent",
  };
}

/** Who sent a message: its terminal's address, else the script's label or the closed terminal's id. */
export function sender(message: AgentMessage): string {
  return message.from.address ?? message.from.name;
}

/**
 * One message in an IRC envelope as omp's own: who sent it, its text and its mentions' block, how
 * to reply (the `agent://` path with the address's name and board percent-encoded, which
 * `peerAddress` decodes), and its id on a line of its own (`ENVELOPE_ID`). What others wrote can't
 * close the envelope or open a harness block of its own.
 */
function envelope(message: AgentMessage): string {
  const from = message.from;
  const who = !from.tile ? `\`${from.name}\`, a script` : !from.address ? `terminal ${from.tile}, closed since it sent this` : from.address === from.tile ? `terminal ${from.tile}` : `\`${from.address}\`, terminal ${from.tile}`;
  const reply = from.tile && from.address ? `If a response is expected, reply via \`write\` (\`path: "${replyPath(from.address)}"\`, \`content: "…"\`).` : "It has no reply address.";
  // omp's escapeHarnessTags: what others wrote reaches the model as written, but for `<` of an
  // `irc` or `system-*` tag.
  const said = `Message from ${who}:\n\n${[message.text.trim(), message.context].filter(Boolean).join("\n\n")}`;
  return `<irc>\n${said.replace(HARNESS_TAG, "&lt;")}\n\n${reply}\n(easl message ${message.id})\n</irc>`;
}

/** `agent://<address>` as omp's `write` takes it, the name and board percent-encoded. */
function replyPath(address: string): string {
  const at = address.lastIndexOf("@");
  return `agent://${at < 0 ? encodeURIComponent(address) : `${encodeURIComponent(address.slice(0, at))}@${encodeURIComponent(address.slice(at + 1))}`}`;
}

/** The block easl's hidden guidance is in: standing orders the system prompt states defer to it (easl.ts). */
export const GUIDANCE_BLOCK = "easl-guidance";
/** The `<` of an `irc` or `system-*` tag (omp's harness tags) or of easl's guidance block, opening or closing. */
const HARNESS_TAG = /<(?=\s*\/?\s*(?:irc|easl-guidance|system-[a-z][a-z-]*)(?![\w-]))/gi;
/** The line of an envelope that names its message. */
const ENVELOPE_ID = /^\(easl message (msg_[\w-]+)\)$/gm;

/** The fields of an omp session message `recordedIds` reads. */
export type Recorded = { role?: unknown; customType?: unknown; content?: unknown; details?: unknown; timestamp?: unknown };

/**
 * The ids of the easl messages omp recorded with `message`: a card's, or those of the cards
 * whose text a user message carries (omp put a script's queued card back in the editor on
 * Esc or Alt+Up, as text, and the user sent it).
 */
export function recordedIds(message: Recorded): string[] {
  if (message.role === "custom" && message.customType === EASL_MESSAGE) {
    const details = message.details;
    const ids = details && typeof details === "object" && "ids" in details ? details.ids : undefined;
    return Array.isArray(ids) ? ids.filter((id): id is string => typeof id === "string") : [];
  }
  if (message.role !== "user") return [];
  const content = message.content;
  const text = typeof content === "string" ? content : Array.isArray(content) ? content.map((part) => (part?.type === "text" && typeof part.text === "string" ? part.text : "")).join("\n") : "";
  return [...text.matchAll(ENVELOPE_ID)].map((match) => match[1]);
}

/** The hidden context `guided` adds: omp hands it to the model as developer context, and never records it. */
export const GUIDANCE = "easl.guidance";
export type Guidance = { role: "custom"; customType: typeof GUIDANCE; content: string; display: false; attribution: "agent"; timestamp: number };

/**
 * One request's messages with `text` as hidden context: just before the first card carrying one
 * of `ids`, else (compacted away) first, so it stays where it was from one request to the next.
 */
export function guided<M extends Recorded>(messages: readonly M[], ids: ReadonlySet<string>, text: string): (M | Guidance)[] {
  const at = Math.max(
    messages.findIndex((message) => recordedIds(message).some((id) => ids.has(id))),
    0,
  );
  const stamp = messages[at]?.timestamp;
  const guidance: Guidance = { role: "custom", customType: GUIDANCE, content: text, display: false, attribution: "agent", timestamp: typeof stamp === "number" ? stamp : Date.now() };
  return [...messages.slice(0, at), guidance, ...messages.slice(at)];
}

/** Body rows a card shows folded and unfolded, and the widest a body row gets (omp's IRC card's). */
const CARD_ROWS = { folded: 3, unfolded: 12 };
const CARD_ROW_COLUMNS = 100;

/**
 * A card as omp draws its own incoming IRC messages (pi-tui `createIrcMessageCard`, which omp
 * doesn't export): `💬 IRC ← <from>` and the message's age, then its text quoted, three nonblank
 * lines until the user unfolds it (twelve then), each cut at 100 columns.
 */
export const renderCard: MessageRenderer<CardDetails> = (message, { expanded }, theme) => {
  const from = message.details?.from.trim() || "?";
  const rows = (message.details?.message ?? "").split("\n").filter((line) => line.trim());
  const minutes = Math.floor((Date.now() - message.timestamp) / 60_000);
  const [hours, days] = [Math.floor(minutes / 60), Math.floor(minutes / 1440)];
  const age = days >= 30 ? `${Math.floor(days / 30)}mo ago` : days >= 7 ? `${Math.floor(days / 7)}w ago` : days ? `${days}d ago` : hours ? `${hours}h ago` : minutes ? `${minutes}m ago` : "just now";
  let drawn: { width: number; lines: string[] } | undefined;
  const component: Component = {
    render(width) {
      if (drawn?.width === width) return drawn.lines;
      // One column of padding each side, as omp's card.
      const inner = Math.max(1, width - 2);
      const glyph = theme.styledSymbol("tool.irc", "accent");
      const title = `IRC ${theme.nav.back} ${from}`;
      const room = inner - Bun.stringWidth(glyph) - 1;
      const meta = Bun.stringWidth(title) + 1 + Bun.stringWidth(age) <= room ? ` ${theme.fg("dim", age)}` : "";
      const quote = `  ${theme.fg("dim", theme.md.quoteBorder)} `;
      const columns = Math.min(CARD_ROW_COLUMNS, inner - Bun.stringWidth(quote));
      const shown = expanded ? CARD_ROWS.unfolded : CARD_ROWS.folded;
      const hidden = rows.length - shown;
      const lines = [
        `${glyph} ${theme.fg("accent", fit(title, room))}${meta}`,
        ...rows.slice(0, shown).map((row) => `${quote}${theme.fg("toolOutput", fit(row.trim().replaceAll("\t", "   "), columns))}`),
        ...(hidden > 0 ? [`${quote}${theme.fg("dim", fit(`… +${hidden} more ${hidden === 1 ? "line" : "lines"}`, columns))}`] : []),
      ];
      drawn = { width, lines: lines.map((line) => ` ${line} `) };
      return drawn.lines;
    },
    invalidate() {
      drawn = undefined;
    },
  };
  return component;
};

/** `text` cut to `columns` terminal columns with an ellipsis, at a character boundary. */
function fit(text: string, columns: number): string {
  if (Bun.stringWidth(text) <= columns) return text;
  let kept = "";
  let used = 0;
  for (const { segment } of new Intl.Segmenter().segment(text)) {
    used += Bun.stringWidth(segment);
    if (used > columns - 1) break;
    kept += segment;
  }
  return columns > 0 ? `${kept}…` : "";
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

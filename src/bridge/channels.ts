import { randomBytes } from "node:crypto";

export type MessageType = "message" | "join" | "leave" | "system";

export type EvictionReason =
  // `evicted_idle` is retained for wire compatibility but is no longer produced:
  // going quiet now HIBERNATES a room instead of destroying it (see hibernate()).
  // A quiet room dies only after CH_HIBERNATE_MAX_MS asleep, as
  // `evicted_hibernate_expired`.
  | "evicted_idle"
  | "evicted_max_lifetime"
  | "evicted_max_messages"
  | "evicted_hibernate_expired";

export interface ChannelMessage {
  index: number;
  type: MessageType;
  from?: string;
  text?: string;
  timestamp: number;
  reason?: string;
}

export interface Participant {
  id: string;
  name: string;
  joinedAt: number;
  // Truncated sha256 of the E2E key, self-reported at join. The bridge never
  // sees the key itself; matching fingerprints only prove two participants
  // hold the SAME key, which is exactly the check a joiner needs before
  // writing 17KB into a room nobody can decrypt.
  keyFp?: string;
  // Stamped on every authorized poll and send. A participant whose loop died
  // stops advancing this even while the channel itself stays warm — it is the
  // per-peer liveness signal the roster exposes as last_seen_s.
  lastSeenAt: number;
}

export interface RosterEntry {
  name: string;
  key_fp: string | null;
  last_seen_s: number;
}

export interface Channel {
  id: string;
  token: string;
  participants: Map<string, Participant>;
  messages: ChannelMessage[];
  createdAt: number;
  lastActivity: number;
  creatorIp: string;
  evicted: boolean;
  // A hibernating room has dropped its messages and its roster but kept its id
  // and token, so the same participants can re-join and carry on. Rooms only
  // reach this state when EVERY participant stopped polling (idleTimeoutMs
  // measures time since the last poll, not the last message), which is why no
  // message history needs preserving — nobody was present to send any.
  hibernating: boolean;
  hibernatedAt: number | null;
}

interface Waiter {
  since: number;
  resolve: (messages: ChannelMessage[]) => void;
  timer: NodeJS.Timeout;
}

// Cloudflare proxy enforces a 100s origin response ceiling; never raise this
// above ~90s. Env-overridable only so tests can drain parked waiters in seconds
// instead of 50 — production should always run the default.
const POLL_TIMEOUT_MS = Number(process.env.CH_POLL_TIMEOUT_MS ?? 50_000);
const TOMBSTONE_GRACE_MS = 5_000;
// How long an evicted channel's reason stays queryable after deletion, so a
// client that comes back later gets `evicted_reason` in the 404 body instead
// of a bare channel_or_token_invalid. Bounded so the map can't grow forever.
const TOMBSTONE_MEMORY_MS = 24 * 60 * 60_000;
const TOMBSTONE_MEMORY_MAX = 10_000;

function newId(bytes = 12): string {
  return randomBytes(bytes).toString("hex");
}

export interface ChannelStoreConfig {
  maxParticipants: number;
  maxMessages: number;
  idleTimeoutMs: number;
  hibernateMaxMs: number;
  maxLifetimeMs: number;
  sweepIntervalMs: number;
}

export function loadChannelStoreConfig(): ChannelStoreConfig {
  return {
    maxParticipants: Number(process.env.CH_MAX_PARTICIPANTS ?? 20),
    maxMessages: Number(process.env.CH_MAX_MESSAGES ?? 10_000),
    // Time-since-last-poll before a room is put to SLEEP (not destroyed).
    idleTimeoutMs: Number(process.env.CH_IDLE_TIMEOUT_MS ?? 30 * 60_000),
    // How long a sleeping room stays resumable. This is the number that decides
    // whether closing the laptop at night costs you the room.
    hibernateMaxMs: Number(process.env.CH_HIBERNATE_MAX_MS ?? 24 * 60 * 60_000),
    // Raised from 6h: an overnight gap is ~15h wall-clock, so a 6h cap would
    // destroy the room on lifetime grounds before hibernation could return it,
    // making the whole sleep/resume path unreachable for its main use case.
    maxLifetimeMs: Number(process.env.CH_MAX_LIFETIME_MS ?? 36 * 60 * 60_000),
    sweepIntervalMs: Number(process.env.CH_SWEEP_INTERVAL_MS ?? 60_000),
  };
}

export type EvictionListener = (channelId: string, creatorIp: string, reason: EvictionReason) => void;
// Fired when a room goes to sleep. The bridge uses this to release the creator's
// concurrent-channel slot: a sleeping room holds no messages and no roster, so
// charging it against a live-channel quota for up to 24h would lock users out of
// creating new rooms for a resource that costs nothing. Waking does NOT re-acquire
// the slot — a resumed room is not a newly created one, and a failed re-acquire
// would make a room unresumable, which is the exact failure this feature exists
// to prevent.
export type HibernationListener = (channelId: string, creatorIp: string) => void;

export class ChannelStore {
  private channels = new Map<string, Channel>();
  private waiters = new Map<string, Set<Waiter>>();
  private tombstones = new Map<string, { reason: EvictionReason; at: number }>();
  private sweepTimer: NodeJS.Timeout | null = null;
  private evictionCounts: Record<EvictionReason, number> = {
    evicted_idle: 0,
    evicted_max_lifetime: 0,
    evicted_max_messages: 0,
    evicted_hibernate_expired: 0,
  };
  private listeners: Set<EvictionListener> = new Set();
  private hibernationListeners: Set<HibernationListener> = new Set();
  private totalChannelsCreated = 0;
  private totalMessagesSent = 0;
  private totalHibernations = 0;
  private totalResumes = 0;

  constructor(public readonly config: ChannelStoreConfig = loadChannelStoreConfig()) {}

  onEviction(listener: EvictionListener): void {
    this.listeners.add(listener);
  }

  onHibernation(listener: HibernationListener): void {
    this.hibernationListeners.add(listener);
  }

  createChannel(creatorIp: string): { channel_id: string; token: string } {
    const id = newId(8);
    const token = newId(24);
    const now = Date.now();
    this.channels.set(id, {
      id,
      token,
      participants: new Map(),
      messages: [],
      createdAt: now,
      lastActivity: now,
      creatorIp,
      evicted: false,
      hibernating: false,
      hibernatedAt: null,
    });
    this.waiters.set(id, new Set());
    this.totalChannelsCreated += 1;
    return { channel_id: id, token };
  }

  // Roster is ordered by join time (Map preserves insertion order), so the
  // first entry is always the channel creator — the participant who minted
  // the E2E key. Joiners compare their own fingerprint against that one.
  private rosterOf(ch: Channel, now: number = Date.now()): RosterEntry[] {
    return [...ch.participants.values()].map((p) => ({
      name: p.name,
      key_fp: p.keyFp ?? null,
      last_seen_s: Math.max(0, Math.round((now - p.lastSeenAt) / 1000)),
    }));
  }

  roster(channelId: string, token: string): RosterEntry[] {
    const ch = this.getAuthorized(channelId, token);
    return ch ? this.rosterOf(ch) : [];
  }

  tombstoneOf(channelId: string): { reason: EvictionReason; at: number } | undefined {
    return this.tombstones.get(channelId);
  }

  private getAuthorized(channelId: string, token: string): Channel | null {
    const ch = this.channels.get(channelId);
    if (!ch) return null;
    if (ch.token !== token) return null;
    return ch;
  }

  join(
    channelId: string,
    token: string,
    name: string,
    keyFp?: unknown,
  ):
    | { participant_id: string; participants: string[]; roster: RosterEntry[]; cursor: number }
    | { error: string } {
    const ch = this.getAuthorized(channelId, token);
    if (!ch) return { error: "channel_or_token_invalid" };
    // An evicted channel survives in the map for TOMBSTONE_GRACE_MS so a live
    // long-poll can still read why it died. It must not accept new members in
    // that window — otherwise a room the sweeper just destroyed (including one
    // that overran its sleep budget) can be resurrected by anyone still holding
    // the token, and the eviction silently un-happens.
    if (ch.evicted) return { error: "channel_or_token_invalid" };
    if (!name || typeof name !== "string" || name.length === 0 || name.length > 64) {
      return { error: "invalid_name" };
    }
    // Names travel to every peer as `from`, and a receiving loop.sh prints them
    // into its events file, which Monitor reads one line at a time. A name
    // containing a newline would split one event across several lines and only
    // the first would match. loop.sh strips these too — this is the layer that
    // protects agents running an older loop. No existing client can send one:
    // every bootstrap sanitizes to [a-zA-Z0-9._-] and the browser to a subset.
    if (/[\u0000-\u001f\u007f-\u009f]/.test(name)) {
      return { error: "invalid_name" };
    }
    // A join is what WAKES a sleeping room. Whoever gets back first revives it;
    // the others re-join normally afterwards and the existing HELLO/WELCOME
    // handshake re-pairs them exactly as it does at first start.
    if (ch.hibernating) {
      ch.hibernating = false;
      ch.hibernatedAt = null;
      this.totalResumes += 1;
    }
    if (ch.participants.size >= this.config.maxParticipants) {
      return { error: "channel_full" };
    }
    for (const p of ch.participants.values()) {
      if (p.name === name) return { error: "name_taken" };
    }
    // Optional, self-reported. 8-64 hex chars or it is silently dropped —
    // never a join failure, so old bootstraps that don't send it keep working.
    const fp = typeof keyFp === "string" && /^[0-9a-f]{8,64}$/i.test(keyFp)
      ? keyFp.toLowerCase()
      : undefined;
    const participantId = newId(8);
    const now = Date.now();
    ch.participants.set(participantId, {
      id: participantId,
      name,
      joinedAt: now,
      keyFp: fp,
      lastSeenAt: now,
    });
    ch.lastActivity = now;
    this.append(ch, { type: "join", from: name });
    return {
      participant_id: participantId,
      participants: [...ch.participants.values()].map((p) => p.name),
      roster: this.rosterOf(ch, now),
      // The cursor a joiner should start polling from to see only what happens
      // AFTER it arrived. Agents poll from 0 and read the backlog on purpose.
      // A browser participant must not: the room may hold a working session's
      // context, and a browser holds the key, so backlog it merely "ignores"
      // would still have been decryptable on that person's machine. Returning
      // the cursor here means the backlog never leaves the bridge at all.
      cursor: ch.messages.length,
    };
  }

  send(
    channelId: string,
    token: string,
    participantId: string,
    text: string,
  ): { ok: true; index: number } | { error: string } {
    const ch = this.getAuthorized(channelId, token);
    if (!ch) return { error: "channel_or_token_invalid" };
    // Checked before the participant lookup: hibernation clears the roster, so
    // an otherwise-valid caller would otherwise get `participant_not_in_channel`
    // — which loop.sh maps to a fatal `bad_request`. Distinguishing the two is
    // what makes a sleeping room recoverable instead of terminal.
    if (ch.hibernating) return { error: "channel_hibernating" };
    if (ch.evicted && !ch.participants.has(participantId)) {
      return { error: "channel_or_token_invalid" };
    }
    const p = ch.participants.get(participantId);
    if (!p) return { error: "participant_not_in_channel" };
    p.lastSeenAt = Date.now();
    if (typeof text !== "string" || text.length === 0) return { error: "empty_text" };
    if (text.length > 64 * 1024) return { error: "text_too_large" };
    const msg = this.append(ch, { type: "message", from: p.name, text });
    this.totalMessagesSent += 1;
    if (ch.messages.length >= this.config.maxMessages) {
      this.evict(ch, "evicted_max_messages");
    }
    return { ok: true, index: msg.index };
  }

  leave(
    channelId: string,
    token: string,
    participantId: string,
  ): { ok: true } | { error: string } {
    const ch = this.getAuthorized(channelId, token);
    if (!ch) return { error: "channel_or_token_invalid" };
    if (ch.hibernating) return { error: "channel_hibernating" };
    if (ch.evicted && !ch.participants.has(participantId)) {
      return { error: "channel_or_token_invalid" };
    }
    const p = ch.participants.get(participantId);
    if (!p) return { error: "participant_not_in_channel" };
    ch.participants.delete(participantId);
    this.append(ch, { type: "leave", from: p.name });
    return { ok: true };
  }

  poll(
    channelId: string,
    token: string,
    participantId: string,
    since: number,
  ): Promise<{ messages: ChannelMessage[]; cursor: number } | { error: string }> {
    const ch = this.getAuthorized(channelId, token);
    if (!ch) return Promise.resolve({ error: "channel_or_token_invalid" });
    if (ch.hibernating) return Promise.resolve({ error: "channel_hibernating" });
    // Evicted-but-not-yet-deleted, and the caller is not on the roster: there is
    // no system message waiting for them to read (a room evicted out of
    // hibernation has an empty roster by construction), so report the room as
    // gone — which carries the tombstone reason — rather than blaming their
    // participant id, which loop.sh treats as an unrecoverable client bug.
    if (ch.evicted && !ch.participants.has(participantId)) {
      return Promise.resolve({ error: "channel_or_token_invalid" });
    }
    const pollingP = ch.participants.get(participantId);
    if (!pollingP) {
      return Promise.resolve({ error: "participant_not_in_channel" });
    }
    ch.lastActivity = Date.now();
    pollingP.lastSeenAt = ch.lastActivity;
    const current = ch.messages.length;
    if (since < current) {
      const messages = ch.messages.slice(since);
      return Promise.resolve({ messages, cursor: current });
    }
    return new Promise((resolve) => {
      const waiterSet = this.waiters.get(channelId);
      if (!waiterSet) {
        resolve({ messages: [], cursor: current });
        return;
      }
      const waiter: Waiter = {
        since,
        resolve: (messages) => {
          resolve({ messages, cursor: since + messages.length });
        },
        timer: setTimeout(() => {
          waiterSet.delete(waiter);
          resolve({ messages: [], cursor: current });
        }, POLL_TIMEOUT_MS),
      };
      waiterSet.add(waiter);
    });
  }

  private append(
    ch: Channel,
    partial: Omit<ChannelMessage, "index" | "timestamp">,
  ): ChannelMessage {
    const msg: ChannelMessage = {
      ...partial,
      index: ch.messages.length,
      timestamp: Date.now(),
    };
    ch.messages.push(msg);
    ch.lastActivity = msg.timestamp;
    this.wakeWaiters(ch);
    return msg;
  }

  private wakeWaiters(ch: Channel) {
    const set = this.waiters.get(ch.id);
    if (!set) return;
    const current = ch.messages.length;
    for (const w of [...set]) {
      if (w.since < current) {
        clearTimeout(w.timer);
        set.delete(w);
        w.resolve(ch.messages.slice(w.since));
      }
    }
  }

  startSweep(): void {
    if (this.sweepTimer) return;
    this.sweepTimer = setInterval(() => this.sweep(), this.config.sweepIntervalMs);
    if (typeof this.sweepTimer.unref === "function") this.sweepTimer.unref();
  }

  stopSweep(): void {
    if (!this.sweepTimer) return;
    clearInterval(this.sweepTimer);
    this.sweepTimer = null;
  }

  sweep(now: number = Date.now()): EvictionReason[] {
    // Prune expired tombstones; if the cap is still exceeded (mass-eviction
    // burst), drop oldest-first — Map iteration order is insertion order.
    for (const [id, t] of this.tombstones) {
      if (now - t.at >= TOMBSTONE_MEMORY_MS) this.tombstones.delete(id);
    }
    if (this.tombstones.size > TOMBSTONE_MEMORY_MAX) {
      const excess = this.tombstones.size - TOMBSTONE_MEMORY_MAX;
      let dropped = 0;
      for (const id of this.tombstones.keys()) {
        if (dropped++ >= excess) break;
        this.tombstones.delete(id);
      }
    }
    const evicted: EvictionReason[] = [];
    for (const ch of [...this.channels.values()]) {
      if (ch.evicted) continue;
      if (now - ch.createdAt >= this.config.maxLifetimeMs) {
        this.evict(ch, "evicted_max_lifetime");
        evicted.push("evicted_max_lifetime");
        continue;
      }
      if (ch.hibernating) {
        // Already asleep: the only question left is whether it has been asleep
        // long enough to give up on. Its lastActivity is frozen at the moment
        // everyone left, so the idle check below must not also see it.
        if (ch.hibernatedAt !== null && now - ch.hibernatedAt >= this.config.hibernateMaxMs) {
          this.evict(ch, "evicted_hibernate_expired");
          evicted.push("evicted_hibernate_expired");
        }
        continue;
      }
      // A room with a long-poll parked on it is NOT idle — someone is actively
      // listening. lastActivity is stamped when a poll ARRIVES, so a healthy
      // client sitting in a 50s long-poll looks quiet for up to 50s; if
      // idleTimeoutMs is anywhere near that, the sweeper hibernates rooms whose
      // loops are perfectly alive. Real-Claude QA on 2026-08-12 hit exactly
      // this: 10 hibernate/resume cycles in 100s against a healthy loop, each
      // one waking Monitor and costing a full Claude turn. Waiters drain within
      // one poll timeout of a client actually dying, so this delays a genuine
      // hibernation by at most ~50s and makes small idle windows safe.
      const parked = this.waiters.get(ch.id);
      if (parked && parked.size > 0) continue;
      if (now - ch.lastActivity >= this.config.idleTimeoutMs) {
        this.hibernate(ch);
      }
    }
    return evicted;
  }

  // Put a room to sleep: drop everything expensive, keep everything identifying.
  // This is deliberately NOT an eviction — no tombstone, no system message, the
  // channel stays in the map and its token stays valid, so `join` can revive it.
  private hibernate(ch: Channel): void {
    if (ch.hibernating || ch.evicted) return;
    ch.hibernating = true;
    ch.hibernatedAt = Date.now();
    ch.messages = [];
    ch.participants.clear();
    // Release any long-poll still parked here. Resolving empty (rather than
    // leaving them to time out) means the client re-polls immediately and gets
    // the hibernating signal now instead of up to 50s later. Note the cursor it
    // carries is stale the moment messages are cleared — the rejoin path resets
    // it, which is why waking goes through `join` and not a bare re-poll.
    const set = this.waiters.get(ch.id);
    if (set) {
      for (const w of set) {
        clearTimeout(w.timer);
        w.resolve([]);
      }
      set.clear();
    }
    this.totalHibernations += 1;
    for (const listener of this.hibernationListeners) listener(ch.id, ch.creatorIp);
  }

  private evict(ch: Channel, reason: EvictionReason): void {
    if (ch.evicted) return;
    if (!this.channels.has(ch.id)) return;
    ch.evicted = true;
    // Eviction outranks hibernation. Without this the channel keeps answering
    // `channel_hibernating` for the whole tombstone grace window — advertising
    // itself as resumable at the exact moment the bridge decided to destroy it.
    ch.hibernating = false;
    ch.hibernatedAt = null;
    this.tombstones.set(ch.id, { reason, at: Date.now() });
    this.append(ch, { type: "system", reason });
    this.evictionCounts[reason] += 1;
    for (const listener of this.listeners) listener(ch.id, ch.creatorIp, reason);
    setTimeout(() => {
      this.channels.delete(ch.id);
      const set = this.waiters.get(ch.id);
      if (set) {
        for (const w of set) {
          clearTimeout(w.timer);
          w.resolve([]);
        }
        this.waiters.delete(ch.id);
      }
    }, TOMBSTONE_GRACE_MS);
  }

  stats() {
    const all = [...this.channels.values()];
    return {
      // `channels` stays the count of rooms that are awake and usable. Sleeping
      // rooms are counted separately rather than folded in — a bridge with 2
      // live rooms and 40 sleeping ones is a very different picture from 42
      // live ones, and the whole point of this feature is that the second
      // number is cheap.
      channels: all.filter((c) => !c.hibernating).length,
      channels_hibernating: all.filter((c) => c.hibernating).length,
      total_participants: all.reduce((s, c) => s + c.participants.size, 0),
      total_messages: all.reduce((s, c) => s + c.messages.length, 0),
      evictions: { ...this.evictionCounts },
      total_channels_created: this.totalChannelsCreated,
      total_messages_sent: this.totalMessagesSent,
      total_hibernations: this.totalHibernations,
      total_resumes: this.totalResumes,
    };
  }
}

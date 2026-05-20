import { randomBytes } from "node:crypto";

export type MessageType = "message" | "join" | "leave" | "system";

export type EvictionReason =
  | "evicted_idle"
  | "evicted_max_lifetime"
  | "evicted_max_messages";

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
}

interface Waiter {
  since: number;
  resolve: (messages: ChannelMessage[]) => void;
  timer: NodeJS.Timeout;
}

// Cloudflare proxy enforces a 100s origin response ceiling; never raise this above ~90s.
const POLL_TIMEOUT_MS = 50_000;
const TOMBSTONE_GRACE_MS = 5_000;

function newId(bytes = 12): string {
  return randomBytes(bytes).toString("hex");
}

export interface ChannelStoreConfig {
  maxParticipants: number;
  maxMessages: number;
  idleTimeoutMs: number;
  maxLifetimeMs: number;
  sweepIntervalMs: number;
}

export function loadChannelStoreConfig(): ChannelStoreConfig {
  return {
    maxParticipants: Number(process.env.CH_MAX_PARTICIPANTS ?? 20),
    maxMessages: Number(process.env.CH_MAX_MESSAGES ?? 10_000),
    idleTimeoutMs: Number(process.env.CH_IDLE_TIMEOUT_MS ?? 30 * 60_000),
    maxLifetimeMs: Number(process.env.CH_MAX_LIFETIME_MS ?? 6 * 60 * 60_000),
    sweepIntervalMs: Number(process.env.CH_SWEEP_INTERVAL_MS ?? 60_000),
  };
}

export type EvictionListener = (channelId: string, creatorIp: string, reason: EvictionReason) => void;

export class ChannelStore {
  private channels = new Map<string, Channel>();
  private waiters = new Map<string, Set<Waiter>>();
  private sweepTimer: NodeJS.Timeout | null = null;
  private evictionCounts: Record<EvictionReason, number> = {
    evicted_idle: 0,
    evicted_max_lifetime: 0,
    evicted_max_messages: 0,
  };
  private listeners: Set<EvictionListener> = new Set();
  private totalChannelsCreated = 0;
  private totalMessagesSent = 0;

  constructor(public readonly config: ChannelStoreConfig = loadChannelStoreConfig()) {}

  onEviction(listener: EvictionListener): void {
    this.listeners.add(listener);
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
    });
    this.waiters.set(id, new Set());
    this.totalChannelsCreated += 1;
    return { channel_id: id, token };
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
  ): { participant_id: string; participants: string[] } | { error: string } {
    const ch = this.getAuthorized(channelId, token);
    if (!ch) return { error: "channel_or_token_invalid" };
    if (!name || typeof name !== "string" || name.length === 0 || name.length > 64) {
      return { error: "invalid_name" };
    }
    if (ch.participants.size >= this.config.maxParticipants) {
      return { error: "channel_full" };
    }
    for (const p of ch.participants.values()) {
      if (p.name === name) return { error: "name_taken" };
    }
    const participantId = newId(8);
    const now = Date.now();
    ch.participants.set(participantId, { id: participantId, name, joinedAt: now });
    ch.lastActivity = now;
    this.append(ch, { type: "join", from: name });
    return {
      participant_id: participantId,
      participants: [...ch.participants.values()].map((p) => p.name),
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
    const p = ch.participants.get(participantId);
    if (!p) return { error: "participant_not_in_channel" };
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
    if (!ch.participants.has(participantId)) {
      return Promise.resolve({ error: "participant_not_in_channel" });
    }
    ch.lastActivity = Date.now();
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
    const evicted: EvictionReason[] = [];
    for (const ch of [...this.channels.values()]) {
      if (ch.evicted) continue;
      if (now - ch.createdAt >= this.config.maxLifetimeMs) {
        this.evict(ch, "evicted_max_lifetime");
        evicted.push("evicted_max_lifetime");
        continue;
      }
      if (now - ch.lastActivity >= this.config.idleTimeoutMs) {
        this.evict(ch, "evicted_idle");
        evicted.push("evicted_idle");
      }
    }
    return evicted;
  }

  private evict(ch: Channel, reason: EvictionReason): void {
    if (ch.evicted) return;
    if (!this.channels.has(ch.id)) return;
    ch.evicted = true;
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
    return {
      channels: this.channels.size,
      total_participants: [...this.channels.values()].reduce(
        (s, c) => s + c.participants.size,
        0,
      ),
      total_messages: [...this.channels.values()].reduce(
        (s, c) => s + c.messages.length,
        0,
      ),
      evictions: { ...this.evictionCounts },
      total_channels_created: this.totalChannelsCreated,
      total_messages_sent: this.totalMessagesSent,
    };
  }
}

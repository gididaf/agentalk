// Per-IP token-bucket rate limiter + concurrent-channel cap.
// State is in-memory per process; resets on restart. Single-instance only.

export interface RateLimitConfig {
  channelsPerHour: number;
  messagesPerHour: number;
  concurrentChannelsPerIp: number;
}

export function loadConfig(): RateLimitConfig {
  return {
    channelsPerHour: Number(process.env.RL_CHANNELS_PER_HOUR ?? 10),
    messagesPerHour: Number(process.env.RL_MESSAGES_PER_HOUR ?? 1000),
    concurrentChannelsPerIp: Number(process.env.RL_CONCURRENT_CHANNELS_PER_IP ?? 10),
  };
}

interface Bucket {
  tokens: number;
  lastRefillMs: number;
}

function take(bucket: Bucket, capacity: number, refillPerMs: number): boolean {
  const now = Date.now();
  const elapsed = now - bucket.lastRefillMs;
  bucket.tokens = Math.min(capacity, bucket.tokens + elapsed * refillPerMs);
  bucket.lastRefillMs = now;
  if (bucket.tokens >= 1) {
    bucket.tokens -= 1;
    return true;
  }
  return false;
}

function fresh(capacity: number): Bucket {
  return { tokens: capacity, lastRefillMs: Date.now() };
}

export type RateLimitDecision =
  | { allowed: true }
  | { allowed: false; reason: "rate_limited" | "concurrent_channels_limit"; retryAfterSec: number };

export interface RejectionCounts {
  channels: number;
  messages: number;
  concurrent: number;
}

export class RateLimiter {
  private channelBuckets = new Map<string, Bucket>();
  private messageBuckets = new Map<string, Bucket>();
  private liveChannelsByIp = new Map<string, Set<string>>();
  private rejections: RejectionCounts = { channels: 0, messages: 0, concurrent: 0 };

  constructor(private readonly config: RateLimitConfig) {}

  private channelRefillPerMs(): number {
    return this.config.channelsPerHour / 3_600_000;
  }
  private messageRefillPerMs(): number {
    return this.config.messagesPerHour / 3_600_000;
  }

  checkCreateChannel(ip: string): RateLimitDecision {
    const live = this.liveChannelsByIp.get(ip);
    if (live && live.size >= this.config.concurrentChannelsPerIp) {
      this.rejections.concurrent += 1;
      return {
        allowed: false,
        reason: "concurrent_channels_limit",
        retryAfterSec: 60,
      };
    }
    let bucket = this.channelBuckets.get(ip);
    if (!bucket) {
      bucket = fresh(this.config.channelsPerHour);
      this.channelBuckets.set(ip, bucket);
    }
    if (!take(bucket, this.config.channelsPerHour, this.channelRefillPerMs())) {
      this.rejections.channels += 1;
      const secondsToOneToken = Math.ceil((1 - bucket.tokens) / this.channelRefillPerMs() / 1000);
      return { allowed: false, reason: "rate_limited", retryAfterSec: secondsToOneToken };
    }
    return { allowed: true };
  }

  checkSend(ip: string): RateLimitDecision {
    let bucket = this.messageBuckets.get(ip);
    if (!bucket) {
      bucket = fresh(this.config.messagesPerHour);
      this.messageBuckets.set(ip, bucket);
    }
    if (!take(bucket, this.config.messagesPerHour, this.messageRefillPerMs())) {
      this.rejections.messages += 1;
      const secondsToOneToken = Math.ceil((1 - bucket.tokens) / this.messageRefillPerMs() / 1000);
      return { allowed: false, reason: "rate_limited", retryAfterSec: secondsToOneToken };
    }
    return { allowed: true };
  }

  registerChannel(ip: string, channelId: string): void {
    let set = this.liveChannelsByIp.get(ip);
    if (!set) {
      set = new Set();
      this.liveChannelsByIp.set(ip, set);
    }
    set.add(channelId);
  }

  releaseChannel(ip: string, channelId: string): void {
    const set = this.liveChannelsByIp.get(ip);
    if (!set) return;
    set.delete(channelId);
    if (set.size === 0) this.liveChannelsByIp.delete(ip);
  }

  snapshot(): { config: RateLimitConfig; rejections: RejectionCounts; trackedIps: number } {
    return {
      config: this.config,
      rejections: { ...this.rejections },
      trackedIps: this.liveChannelsByIp.size,
    };
  }
}

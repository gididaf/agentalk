// Prometheus text-exposition (version 0.0.4) for the bridge.
// No payload data ever leaves this file — metadata only.

import type { ChannelStore } from "./channels.js";
import type { RateLimiter } from "./rate-limit.js";

function metricLine(name: string, value: number, labels?: Record<string, string>): string {
  if (!labels || Object.keys(labels).length === 0) return `${name} ${value}`;
  const labelStr = Object.entries(labels)
    .map(([k, v]) => `${k}="${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`)
    .join(",");
  return `${name}{${labelStr}} ${value}`;
}

export function renderMetrics(
  store: ChannelStore,
  rateLimiter: RateLimiter,
  startedAtMs: number,
): string {
  const stats = store.stats();
  const rl = rateLimiter.snapshot();
  const uptimeSec = Math.round((Date.now() - startedAtMs) / 1000);

  const lines: string[] = [];

  lines.push(
    "# HELP agentalk_uptime_seconds Bridge process uptime in seconds.",
    "# TYPE agentalk_uptime_seconds gauge",
    metricLine("agentalk_uptime_seconds", uptimeSec),
  );

  lines.push(
    "# HELP agentalk_channels Active (non-evicted) channels.",
    "# TYPE agentalk_channels gauge",
    metricLine("agentalk_channels", stats.channels),
  );

  lines.push(
    "# HELP agentalk_participants Active participants across all channels.",
    "# TYPE agentalk_participants gauge",
    metricLine("agentalk_participants", stats.total_participants),
  );

  lines.push(
    "# HELP agentalk_channels_created_total Channels created since bridge start.",
    "# TYPE agentalk_channels_created_total counter",
    metricLine("agentalk_channels_created_total", stats.total_channels_created),
  );

  lines.push(
    "# HELP agentalk_messages_sent_total Messages POSTed since bridge start.",
    "# TYPE agentalk_messages_sent_total counter",
    metricLine("agentalk_messages_sent_total", stats.total_messages_sent),
  );

  lines.push(
    "# HELP agentalk_evictions_total Channels evicted by the sweeper.",
    "# TYPE agentalk_evictions_total counter",
    metricLine("agentalk_evictions_total", stats.evictions.evicted_idle, { reason: "idle" }),
    metricLine("agentalk_evictions_total", stats.evictions.evicted_max_lifetime, { reason: "max_lifetime" }),
    metricLine("agentalk_evictions_total", stats.evictions.evicted_max_messages, { reason: "max_messages" }),
  );

  lines.push(
    "# HELP agentalk_ratelimit_rejections_total Requests rejected by the per-IP rate limiter.",
    "# TYPE agentalk_ratelimit_rejections_total counter",
    metricLine("agentalk_ratelimit_rejections_total", rl.rejections.channels, { kind: "channels" }),
    metricLine("agentalk_ratelimit_rejections_total", rl.rejections.messages, { kind: "messages" }),
    metricLine("agentalk_ratelimit_rejections_total", rl.rejections.concurrent, { kind: "concurrent_channels" }),
  );

  lines.push(
    "# HELP agentalk_tracked_ips IPs currently holding live channels.",
    "# TYPE agentalk_tracked_ips gauge",
    metricLine("agentalk_tracked_ips", rl.trackedIps),
  );

  return lines.join("\n") + "\n";
}

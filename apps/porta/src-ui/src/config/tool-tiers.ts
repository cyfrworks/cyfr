/**
 * Tier classification for outbound MCP tool calls.
 *
 * Used by the approval gate to decide whether a tool call from Porta's UI
 * should pause for user approval before being forwarded to cyfr.
 *
 * Tiers:
 *   tier0 — Never gated (auth/onboarding/chat-loop flows; see RULES)
 *   tier1 — Read-only data (forward silently)
 *   tier2 — Writes (approval card)
 *   tier3 — External or irreversible (approval card, high risk)
 *
 * Cyfr's MCP convention puts the sub-action in `args.action` (e.g.
 * `client.callTool("policy", { action: "set", ... })`), so tier entries are
 * (tool name, optional action) pairs. Omitting `action` matches any action
 * on that tool.
 *
 * Classification is DEFAULT-DENY: an action is forwarded silently only when
 * an explicit rule or the read-verb allowlist says so; everything else —
 * including unknown tools and external `server:tool` calls — requires
 * approval. Unlisted writes previously forwarded silently; that was the
 * hole, not a feature.
 */

export type Tier = "tier0" | "tier1" | "tier2" | "tier3";

interface ToolRule {
  name: string;
  /** If set, only match when `args.action` equals this. */
  action?: string;
  tier: Tier;
}

const RULES: ToolRule[] = [
  // Never gated: these run during login/first-run onboarding, before the
  // approval tray is mounted — gating them deadlocks the flow. All are
  // explicit user gestures on dedicated screens.
  { name: "session", tier: "tier0" },
  { name: "registry", action: "probe", tier: "tier0" },
  { name: "registry", action: "whoami", tier: "tier0" },
  { name: "registry", action: "legal_version", tier: "tier0" },
  { name: "registry", action: "legal_page", tier: "tier0" },
  { name: "registry", action: "legal_accept", tier: "tier0" },
  { name: "registry", action: "claim_personal", tier: "tier0" },

  // The chat loop itself: submitting or stopping the agent is the explicit
  // user gesture. What the agent may do while running is governed
  // server-side by the formula's tool_policy, not by this client gate.
  { name: "execution", action: "run_stream", tier: "tier0" },
  { name: "execution", action: "cancel", tier: "tier0" },

  // Irreversible / externally visible — high-risk approval card.
  { name: "tincture_visibility", action: "set", tier: "tier3" },
  { name: "component", action: "delete", tier: "tier3" },
  { name: "policy", action: "delete", tier: "tier3" },
];

/**
 * Actions that only read state, on any tool. A write-shaped action name
 * never belongs here — when in doubt, leave it out and let it gate.
 */
const READ_ACTIONS = new Set([
  "get",
  "list",
  "search",
  "inspect",
  "status",
  "logs",
  "setup_plan",
  "whoami",
  "probe",
]);

export function classifyTool(
  name: string,
  args?: Record<string, unknown>,
): Tier {
  const action = typeof args?.action === "string" ? args.action : undefined;
  for (const rule of RULES) {
    if (rule.name !== name) continue;
    if (rule.action === undefined) return rule.tier;
    if (rule.action === action) return rule.tier;
  }
  if (action !== undefined && READ_ACTIONS.has(action)) return "tier1";
  return "tier2";
}

export function requiresApproval(
  name: string,
  args?: Record<string, unknown>,
): boolean {
  const tier = classifyTool(name, args);
  return tier === "tier2" || tier === "tier3";
}

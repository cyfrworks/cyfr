/**
 * Tier classification for outbound MCP tool calls.
 *
 * Used by Phase 5's approval gate to decide whether a tool call from Porta's
 * UI should pause for user approval before being forwarded to cyfr.
 *
 * Tiers:
 *   tier0 — UI-only (dispatched client-side; never reaches the proxy)
 *   tier1 — Read-only data (forward silently)
 *   tier2 — Reversible writes (lightweight inline confirmation)
 *   tier3 — External or irreversible (explicit approval card every time)
 *
 * Cyfr's MCP convention puts the sub-action in `args.action` (e.g.
 * `client.callTool("policy", { action: "set", ... })`), so tier entries are
 * (tool name, optional action) pairs. Omitting `action` matches any action
 * on that tool — use sparingly, only for tools whose every sub-action is
 * mutating.
 */

export type Tier = "tier0" | "tier1" | "tier2" | "tier3";

interface ToolRule {
  name: string;
  /** If set, only match when `args.action` equals this. */
  action?: string;
  tier: Tier;
}

/**
 * Keep this list narrow. Over-gating reads stalls the UI with approval
 * prompts for benign work (e.g. listing apps to populate the Apps page).
 */
const RULES: ToolRule[] = [
  // Tincture visibility — mutating actions only. `get` / `list` pass through.
  { name: "tincture_visibility", action: "set", tier: "tier3" },
  { name: "tincture_visibility", action: "make_public", tier: "tier3" },
  { name: "tincture_visibility", action: "make_private", tier: "tier2" },

  // Component lifecycle
  { name: "component", action: "delete", tier: "tier3" },
  { name: "component", action: "uninstall", tier: "tier3" },

  // Policy mutation
  { name: "policy", action: "set", tier: "tier2" },
  { name: "policy", action: "update_field", tier: "tier2" },
  { name: "policy", action: "delete", tier: "tier3" },
  { name: "policy", action: "clear", tier: "tier3" },

  // Secret management
  { name: "secret", action: "set", tier: "tier2" },
  { name: "secret", action: "delete", tier: "tier2" },
  { name: "secret", action: "grant", tier: "tier2" },
  { name: "secret", action: "revoke", tier: "tier2" },

  // MCP server config
  { name: "mcp_servers", action: "add", tier: "tier2" },
  { name: "mcp_servers", action: "delete", tier: "tier2" },
];

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
  return "tier1";
}

export function requiresApproval(
  name: string,
  args?: Record<string, unknown>,
): boolean {
  const tier = classifyTool(name, args);
  return tier === "tier2" || tier === "tier3";
}

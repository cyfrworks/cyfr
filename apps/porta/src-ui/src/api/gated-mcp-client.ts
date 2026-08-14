import type { McpClient } from "./mcp-client";
import { classifyTool, requiresApproval } from "../config/tool-tiers";
import { useApprovalStore, type ApprovalRisk } from "../state/approval-store";

/**
 * Wraps an MCP client so that calls to tools classified as tier2/tier3 pause
 * for user approval before being forwarded to cyfr. On rejection, throws an
 * error carrying `user_declined` so callers see a clean decline path.
 *
 * Only applies to tool calls initiated from Porta's UI (the `client` is the
 * one Porta uses to talk to cyfr). AQUA-initiated tool calls run server-side
 * inside cyfr and are NOT intercepted here — for those, AQUA is expected to
 * ask via the text-intent `ui.request_approval` kind first.
 */
export function wrapWithApprovalGate(client: McpClient): McpClient {
  const original = client.callTool.bind(client);

  client.callTool = async (name, args = {}) => {
    if (requiresApproval(name, args)) {
      const decision = await useApprovalStore.getState().request({
        source: "tool_call",
        title: `Run ${describeToolAction(name, args)}?`,
        summary: summaryFor(name, args),
        risk: tierToRisk(name, args),
        actionDescription: describeCall(name, args),
      });
      if (!decision.approved) {
        const reason = decision.reason ? `: ${decision.reason}` : "";
        throw new Error(`user_declined${reason}`);
      }
    }
    return original(name, args);
  };

  return client;
}

function tierToRisk(
  toolName: string,
  args: Record<string, unknown>,
): ApprovalRisk {
  const tier = classifyTool(toolName, args);
  if (tier === "tier3") return "high";
  if (tier === "tier2") return "medium";
  return "low";
}

function describeToolAction(
  name: string,
  args: Record<string, unknown>,
): string {
  const action = typeof args.action === "string" ? args.action : undefined;
  return action ? `${name}:${action}` : name;
}

/** Best-effort plain-English summary for well-known tool/action pairs. */
function summaryFor(name: string, args: Record<string, unknown>): string {
  const action = typeof args.action === "string" ? args.action : undefined;
  if (name === "tincture_visibility" && action === "set") {
    return "Change app sharing settings.";
  }
  if (name === "component" && action === "delete") {
    return "Permanently remove this item.";
  }
  if (name === "vault" && action === "create") return "Store a credential.";
  if (name === "vault" && action === "delete") {
    return "Delete a stored credential.";
  }
  if (name === "mcp_servers" && action === "create") {
    return "Add an external connection.";
  }
  if (name === "mcp_servers" && action === "delete") {
    return "Remove an external connection.";
  }
  return `This will run ${describeToolAction(name, args)}.`;
}

function describeCall(name: string, args: Record<string, unknown>): string {
  try {
    const compact = JSON.stringify(args);
    return `${name} ${compact.length > 120 ? compact.slice(0, 117) + "…" : compact}`;
  } catch {
    return name;
  }
}

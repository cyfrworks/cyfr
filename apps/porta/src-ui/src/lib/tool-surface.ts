/**
 * Attach the formula's `tool_policy` allowlist
 * (`{"tool.action" | "tool.*" => "ask" | "auto"}`), mirroring Prism's
 * `Prism.AgentConfig.put_formula_tool_surface/2`. The policy is the ONLY
 * tool surface: it is always attached (empty object when the guide carries
 * none — an empty allowlist is the fail-closed default, never omission),
 * and the formula derives the provider-native search tool from a
 * `"native_search"` policy key rather than a separate list.
 */
export function applyToolSurface<T extends object>(
  target: T,
  toolPolicy: Record<string, unknown> | null | undefined,
): T {
  const t = target as Record<string, unknown>;
  t.tool_policy =
    toolPolicy && typeof toolPolicy === "object" ? toolPolicy : {};
  return target;
}

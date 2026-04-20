/**
 * Vocabulary translation: Prism backend terms → consumer-facing labels.
 *
 * Porta's consumers don't work with "tinctures" or "catalysts"; they work with
 * "apps" and "AI models". Every user-visible string naming a Prism concept
 * flows through `label()` so we can keep a single source of truth.
 *
 * Dev mode (enabled via `{ dev: true }` or a future preference toggle) returns
 * the raw Prism term — useful when debugging or when a power user wants to
 * copy a component ref verbatim.
 */

export type PrismTerm =
  | "tincture"
  | "component"
  | "formula"
  | "catalyst"
  | "reagent"
  | "mcp_server"
  | "policy"
  | "execution"
  | "namespace_slug"
  | "component_ref"
  | "manifest";

const CONSUMER_LABELS: Record<PrismTerm, string> = {
  tincture: "App",
  component: "Item",
  formula: "Workflow",
  catalyst: "AI model",
  reagent: "Integration",
  mcp_server: "Connection",
  policy: "Permission",
  execution: "Task run",
  // Server field is `namespace_slug` (three-shape namespaces: personal /
  // publisher / reserved). `publisher_name` is gone.
  namespace_slug: "Name",
  component_ref: "ID",
  manifest: "Details",
};

const PRISM_LABELS: Record<PrismTerm, string> = {
  tincture: "Tincture",
  component: "Component",
  formula: "Formula",
  catalyst: "Catalyst",
  reagent: "Reagent",
  mcp_server: "MCP server",
  policy: "Policy",
  execution: "Execution",
  namespace_slug: "namespace.name",
  component_ref: "Component ref",
  manifest: "Manifest",
};

export interface LabelOptions {
  /** Return raw Prism term instead of consumer term. */
  dev?: boolean;
  /** Return plural form. */
  plural?: boolean;
}

export function label(term: PrismTerm, options: LabelOptions = {}): string {
  const source = options.dev ? PRISM_LABELS : CONSUMER_LABELS;
  const base = source[term];
  if (!options.plural) return base;
  // Simple English pluralization — sufficient for the current term set.
  if (base.endsWith("s")) return base;
  if (base.endsWith("y")) return base.slice(0, -1) + "ies";
  return base + "s";
}

/**
 * Translate a policy field name (e.g. "allowed_domains", "rate_limit") to a
 * human-friendly display label. Falls back to title-casing the snake_case name.
 */
const POLICY_FIELD_LABELS: Record<string, string> = {
  allowed_domains: "Allowed domains",
  allowed_methods: "Allowed methods",
  allowed_private_ips: "Allowed private IPs",
  allowed_paths: "Allowed paths",
  allowed_actions: "Allowed actions",
  allowed_tools: "Allowed tools",
  rate_limit: "Rate limit",
  timeout: "Timeout",
  max_memory_bytes: "Max memory",
  max_request_size: "Max request size",
  max_response_size: "Max response size",
  batch_timeout: "Batch timeout",
  max_concurrent_tasks: "Max concurrent tasks",
};

export function policyFieldLabel(field: string): string {
  if (POLICY_FIELD_LABELS[field]) return POLICY_FIELD_LABELS[field];
  return field
    .split("_")
    .map((part, i) => (i === 0 ? part[0]?.toUpperCase() + part.slice(1) : part))
    .join(" ");
}

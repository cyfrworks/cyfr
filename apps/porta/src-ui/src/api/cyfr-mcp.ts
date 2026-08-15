/**
 * Typed wrappers around every MCP tool call Porta needs.
 *
 * This module is the **portable interface** for talking to Cyfr from any
 * client (Porta desktop, future RN mobile/web). The CLI binary, Porta's Rust
 * proxy, and a hypothetical web client all converge on the same MCP tool
 * names + action keys defined here.
 *
 * To verify any function in this file matches the canonical CLI behavior,
 * grep `apps/codex/cmd/*.go` for `client.CallTool("toolName"` and confirm
 * the action key matches.
 *
 * Every function takes an `McpClient` instance — the same client should be
 * shared across the app (see `state/connection-store.ts`).
 */

import type { McpClient } from "./mcp-client";

type Json = Record<string, unknown>;

// ===========================================================================
// Session / identity (whoami is a two-action compose)
// ===========================================================================
//
//   - `session.whoami`  → local cyfr identity (user_id, email, provider)
//   - `registry.whoami` → cyfr.run identity (authenticated, personal_namespace,
//                          memberships)
//
// Callers should invoke both and merge in state. The split exists because
// the auth sliver in Sanctum is intentionally registry-free; cyfr.run
// identity lives under the Compendium registry tool.

/** Local cyfr identity returned by `session.whoami`. */
export interface SessionWhoami {
  user_id: string;
  email: string | null;
  provider: string;
}

/** cyfr.run registry identity returned by `registry.whoami`. */
export interface RegistryWhoami {
  authenticated: boolean;
  personal_namespace: {
    slug: string;
    last_used_at?: string | null;
  } | null;
  memberships: Array<{
    slug: string;
    role: string;
    last_used_at?: string | null;
  }>;
}

/**
 * `session.whoami` — local cyfr identity only. Does NOT include registry
 * state — call `registryWhoami()` separately for that.
 *
 * Cast via `unknown` because `callTool` returns an opaque `Json` shape
 * (the MCP transport doesn't carry typed schemas); the server contract
 * for this action is documented in apps/cyfr/lib/sanctum/mcp.ex handler
 * for `session.whoami`.
 */
export function sessionWhoami(client: McpClient): Promise<SessionWhoami> {
  return client.callTool("session", {
    action: "whoami",
  }) as unknown as Promise<SessionWhoami>;
}

/**
 * `registry.whoami` — cyfr.run push-token identity. Returns an object with
 * `authenticated: false` and empty memberships for unauth'd callers rather
 * than throwing, so callers can surface a login hint.
 */
export function registryWhoami(client: McpClient): Promise<RegistryWhoami> {
  return client.callTool("registry", {
    action: "whoami",
  }) as unknown as Promise<RegistryWhoami>;
}

/** Claim the caller's one-time personal namespace on cyfr.run. */
export function registryClaimPersonal(
  client: McpClient,
  args: { username: string; provider: string; access_token: string },
): Promise<Json> {
  return client.callTool("registry", { action: "claim_personal", ...args });
}

/**
 * `registry.probe` — exchange the IdP `access_token` for fresh push
 * tokens and persist them in the local CredentialStore. Used after
 * `registry.legal-accept` to re-mint tokens when the probe gate fired.
 */
export interface RegistryProbeResponse {
  personal_namespace: { slug: string; token: string; id: string } | null;
  memberships: Array<{ slug: string; role: string; token: string; id: string }>;
  credential_store_warnings?: string[];
}

export function registryProbe(
  client: McpClient,
  args: { provider: string; access_token: string; label?: string },
): Promise<RegistryProbeResponse> {
  return client.callTool("registry", {
    action: "probe",
    ...args,
  }) as unknown as Promise<RegistryProbeResponse>;
}

// ===========================================================================
// Legal-policy clickwrap (R1.11 — see registry_moderation_plan.md §3.12)
// ===========================================================================
//
// cyfr.run's namespace-claim handlers gate on a prior acceptance of the
// current bundled `policy_version`. The UI flow is:
//
//   1. registryLegalVersion()  →  current version + policies[]
//   2. registryGetLegalPage()  →  per-doc markdown for each policies[].name
//   3. registryLegalAccept()   →  records the acceptance row
//
// The OAuth access_token used by registryLegalAccept is the same one
// captured from device-poll for the claim flow (one-shot per device-flow
// completion); after a successful accept, retry registryClaimPersonal
// to land the namespace.

/** Per-policy entry returned by `legal-version`. */
export interface LegalPolicyEntry {
  name: string;
  title: string;
  sha256: string;
}

export interface LegalVersionResponse {
  policy_version: string;
  policies: LegalPolicyEntry[];
}

/** Current bundled `policy_version` plus the active doc set. */
export function registryLegalVersion(
  client: McpClient,
): Promise<LegalVersionResponse> {
  return client.callTool("registry", {
    action: "legal_version",
  }) as unknown as Promise<LegalVersionResponse>;
}

/** Single policy doc as `{name, title, content_markdown}`. */
export function registryGetLegalPage(
  client: McpClient,
  name: string,
): Promise<{ name: string; title: string; content_markdown: string }> {
  return client.callTool("registry", {
    action: "legal_page",
    name,
  }) as unknown as Promise<{
    name: string;
    title: string;
    content_markdown: string;
  }>;
}

/**
 * Record a clickwrap acceptance for the current `policy_version`. Pass
 * the OAuth `access_token` cached from device-poll (the same one that
 * feeds `registryClaimPersonal`). Idempotent on the server side; safe
 * to retry on transient failures.
 */
export function registryLegalAccept(
  client: McpClient,
  args: {
    provider: string;
    access_token: string;
    policy_version: string;
  },
): Promise<{ id: string; accepted_at: string; policy_version: string }> {
  return client.callTool("registry", {
    action: "legal_accept",
    ...args,
  }) as unknown as Promise<{
    id: string;
    accepted_at: string;
    policy_version: string;
  }>;
}

/** `cyfr logout` — invalidate the server-side session. */
export function logout(client: McpClient): Promise<Json> {
  return client.callTool("session", { action: "logout" });
}

/** Start the OAuth 2.0 Device Authorization Flow. */
export function deviceInit(
  client: McpClient,
  provider = "github",
): Promise<Json> {
  return client.callTool("session", { action: "device_init", provider });
}

/**
 * Poll for device flow completion.
 *
 * The response on `status: "complete"` carries `session_token` (the Sanctum
 * bearer credential) + `user`, plus:
 *
 *  - `needs_personal_namespace: boolean` — true when the user hasn't claimed
 *    a personal slug on cyfr.run yet. Route to claim-namespace UI.
 *  - `suggested_username: string | null` — normalized default slug (email
 *    local-part). Pre-fill the claim form.
 *  - `access_token: string | undefined` — one-shot IdP token to forward to
 *    `registry.claim-personal`. Only present when `needs_personal_namespace`
 *    is true. CALLER MUST discard after the claim call; do NOT persist.
 *  - `reauthenticate: true | undefined` — the IdP access_token was rejected
 *    during probe. The device_code is one-shot; force the user to re-login.
 *  - `probe_error: string | undefined` — transient cyfr.run probe failure
 *    (non-reauth). Session is valid; surface as a warning.
 *  - `credential_store_warnings: string[] | undefined` — slugs whose push
 *    tokens were issued server-side but not cached locally.
 */
export function devicePoll(
  client: McpClient,
  deviceCode: string,
  provider = "github",
): Promise<Json> {
  return client.callTool("session", {
    action: "device_poll",
    device_code: deviceCode,
    provider,
  });
}

// ===========================================================================
// Components
// ===========================================================================

/** `cyfr list [--type catalyst]` — installed components. */
export function listComponents(
  client: McpClient,
  type?: string,
): Promise<Json> {
  const args: Json = { action: "list" };
  if (type) args.type = type;
  return client.callTool("component", args);
}

/** `cyfr register` — scan components/ on the server and register them. */
export function registerComponents(
  client: McpClient,
  registerId?: string,
): Promise<Json> {
  const args: Json = { action: "register" };
  if (registerId) args.register_id = registerId;
  return client.callTool("component", args);
}

/** `cyfr setup <ref>` — fetch the component's needs/consent/ready state. */
export function setupPlan(client: McpClient, reference: string): Promise<Json> {
  return client.callTool("component", {
    action: "setup_plan",
    reference,
  });
}

/** Delete a registered component. */
export function removeComponent(
  client: McpClient,
  reference: string,
): Promise<Json> {
  return client.callTool("component", { action: "delete", reference });
}

// ===========================================================================
// Execution (run)
// ===========================================================================

/** `cyfr run <ref> --input <json>` — execute a component. */
export function runComponent(
  client: McpClient,
  reference: string,
  input?: Json,
): Promise<Json> {
  const args: Json = { action: "run", reference };
  if (input) args.input = input;
  return client.callTool("execution", args);
}

/** `cyfr run --logs <id>` — fetch logs for a specific execution. */
export function getExecutionLogs(
  client: McpClient,
  executionId: string,
): Promise<Json> {
  return client.callTool("execution", {
    action: "logs",
    execution_id: executionId,
  });
}

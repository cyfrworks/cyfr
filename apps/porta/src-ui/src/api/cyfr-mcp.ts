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
// Session / identity
// ===========================================================================

/** `cyfr whoami` — returns user, email, provider, registry status. */
export function whoami(client: McpClient): Promise<Json> {
  return client.callTool("session", { action: "whoami" });
}

/** `cyfr logout` — invalidate the server-side session. */
export function logout(client: McpClient): Promise<Json> {
  return client.callTool("session", { action: "logout" });
}

/** Start GitHub Device Flow. Returns `{user_code, verification_uri, device_code, interval}`. */
export function deviceInit(client: McpClient, provider = "github"): Promise<Json> {
  return client.callTool("session", { action: "device-init", provider });
}

/** Poll for device flow completion. Returns `{status, session_id?, user?}`. */
export function devicePoll(
  client: McpClient,
  deviceCode: string,
  provider = "github",
): Promise<Json> {
  return client.callTool("session", {
    action: "device-poll",
    device_code: deviceCode,
    provider,
  });
}

// ===========================================================================
// System
// ===========================================================================

/** `cyfr status` — service health for opus, sanctum, emissary, arca, compendium, registry. */
export function systemStatus(client: McpClient, scope = "all"): Promise<Json> {
  return client.callTool("system", { action: "status", scope });
}

/** `cyfr notify` — dispatch a webhook event. */
export function notify(client: McpClient, event: string, target: string): Promise<Json> {
  return client.callTool("system", { action: "notify", event, target });
}

// ===========================================================================
// Components
// ===========================================================================

/** `cyfr list [--type catalyst]` — installed components. */
export function listComponents(client: McpClient, type?: string): Promise<Json> {
  const args: Json = { action: "list" };
  if (type) args.type = type;
  return client.callTool("component", args);
}

/** `cyfr search <query>` — search the registry. */
export function searchComponents(
  client: McpClient,
  query: string,
): Promise<Json> {
  return client.callTool("component", { action: "search", query });
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

/** `cyfr inspect <ref>` — full metadata, policy, dependency tree, README. */
export function inspectComponent(
  client: McpClient,
  reference: string,
): Promise<Json> {
  return client.callTool("component", { action: "inspect", reference });
}

/** `cyfr setup <ref>` — fetch the recommended secrets, grants, and policy plan. */
export function setupPlan(client: McpClient, reference: string): Promise<Json> {
  return client.callTool("component", {
    action: "setup_plan",
    reference,
  });
}

/** Remove a registered component. */
export function removeComponent(
  client: McpClient,
  reference: string,
): Promise<Json> {
  return client.callTool("component", { action: "remove", reference });
}

// ===========================================================================
// Policy
// ===========================================================================

/** `cyfr policy set <ref> <field> <value>` — update one policy field. */
export function updatePolicyField(
  client: McpClient,
  componentRef: string,
  field: string,
  value: string,
): Promise<Json> {
  return client.callTool("policy", {
    action: "update_field",
    component_ref: componentRef,
    field,
    value,
  });
}

/** `cyfr policy show <ref>` — fetch the full policy doc. */
export function getPolicy(
  client: McpClient,
  componentRef: string,
): Promise<Json> {
  return client.callTool("policy", { action: "get", component_ref: componentRef });
}

// ===========================================================================
// Secrets
// ===========================================================================

/** `cyfr secret set NAME=VALUE` — store a secret server-side (encrypted). */
export function setSecret(
  client: McpClient,
  name: string,
  value: string,
): Promise<Json> {
  return client.callTool("secret", { action: "set", name, value });
}

/** `cyfr secret get NAME` — fetch a secret (server returns masked unless requested). */
export function getSecret(client: McpClient, name: string): Promise<Json> {
  return client.callTool("secret", { action: "get", name });
}

/** `cyfr secret list` — list all stored secret names. */
export function listSecrets(client: McpClient): Promise<Json> {
  return client.callTool("secret", { action: "list" });
}

/** `cyfr secret delete NAME` — remove a secret and all grants. */
export function deleteSecret(client: McpClient, name: string): Promise<Json> {
  return client.callTool("secret", { action: "delete", name });
}

/** `cyfr secret grant <ref> NAME` — allow a component to read the secret. */
export function grantSecret(
  client: McpClient,
  componentRef: string,
  name: string,
): Promise<Json> {
  return client.callTool("secret", {
    action: "grant",
    component_ref: componentRef,
    name,
  });
}

/** `cyfr secret revoke <ref> NAME` — revoke a component's access. */
export function revokeSecret(
  client: McpClient,
  componentRef: string,
  name: string,
): Promise<Json> {
  return client.callTool("secret", {
    action: "revoke",
    component_ref: componentRef,
    name,
  });
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

/** `cyfr run --list` — list recent executions. */
export function listExecutions(client: McpClient): Promise<Json> {
  return client.callTool("execution", { action: "list" });
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

/** `cyfr run --cancel <id>` — cancel a running execution. */
export function cancelExecution(
  client: McpClient,
  executionId: string,
): Promise<Json> {
  return client.callTool("execution", {
    action: "cancel",
    execution_id: executionId,
  });
}

// ===========================================================================
// API keys
// ===========================================================================

/** `cyfr key create` — create a new API key. */
export function createApiKey(
  client: McpClient,
  args: {
    name: string;
    type: "application" | "service" | "admin";
    scope?: string[];
    rate_limit?: string;
    ip_allowlist?: string[];
  },
): Promise<Json> {
  return client.callTool("key", { action: "create", ...args });
}

/** `cyfr key list` — list all API keys. */
export function listApiKeys(client: McpClient): Promise<Json> {
  return client.callTool("key", { action: "list" });
}

/** `cyfr key revoke <name>` — revoke an API key by name. */
export function revokeApiKey(client: McpClient, name: string): Promise<Json> {
  return client.callTool("key", { action: "revoke", name });
}

// ===========================================================================
// OAuth
// ===========================================================================

/** Start OAuth authorization for a component+provider. */
export function oauthAuthorize(
  client: McpClient,
  componentRef: string,
  provider: string,
): Promise<Json> {
  return client.callTool("oauth", {
    action: "authorize",
    component_ref: componentRef,
    provider,
  });
}

// ===========================================================================
// Tincture visibility
// ===========================================================================

/** Get a tincture's public/private visibility setting. */
export function getTinctureVisibility(
  client: McpClient,
  publisher: string,
  name: string,
): Promise<Json> {
  return client.callTool("tincture_visibility", {
    action: "get",
    publisher,
    name,
  });
}

/** Set a tincture's public/private visibility. */
export function setTinctureVisibility(
  client: McpClient,
  publisher: string,
  name: string,
  isPublic: boolean,
): Promise<Json> {
  return client.callTool("tincture_visibility", {
    action: "set",
    publisher,
    name,
    public: isPublic,
  });
}

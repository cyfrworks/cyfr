/**
 * Phase 7 error translation layer. Every user-facing error flows through
 * `translateError` to get a structured shape the UI can render consistently:
 *
 *   { title, body, actions[], rawMessage }
 *
 * Actions are optional suggested next steps. The UI maps them to concrete
 * handlers (navigate, reopen overlay, etc.) — the translator only describes
 * the semantic intent.
 */

import { parseError } from "../api/errors";

export type ErrorActionKind =
  | "retry"
  | "open_settings"
  | "open_connections"
  | "open_components"
  | "open_aqua"
  | "grant_access"
  | "reconnect"
  | "install_runtime";

export interface ErrorAction {
  kind: ErrorActionKind;
  label: string;
  /** Optional payload — e.g. componentRef for grant_access. */
  target?: string;
}

export interface TranslatedError {
  title: string;
  body: string;
  actions: ErrorAction[];
  /** Original, unedited error string — rendered under a "Details" toggle in dev mode. */
  rawMessage: string;
}

interface Rule {
  test: RegExp;
  translate: (match: RegExpMatchArray, raw: string) => TranslatedError;
}

/**
 * Patterns matched against the raw error string (not the parseError output)
 * so we can branch on the original shape. Each rule returns the full shape.
 */
const RULES: Rule[] = [
  // ── Rate limit ────────────────────────────────────────────────────────
  {
    test: /rate[_-]?limit[_-]?exceeded|too many requests|rate limit|429/i,
    translate: (_, raw) => ({
      title: "Too many requests",
      body: "You've hit a rate limit. Wait a moment and try again. If this keeps happening, the permission for this item may be set too strict.",
      actions: [
        { kind: "retry", label: "Retry" },
        { kind: "open_components", label: "Check permissions" },
      ],
      rawMessage: raw,
    }),
  },

  // ── Ungranted credential (host vault-read denial) ─────────────────────
  {
    test: /access-denied:\s*(\S+) not granted to (\S+)/,
    translate: (m, raw) => {
      const secret = m[1] ?? "a credential";
      const ref = m[2] ?? "";
      return {
        title: "Credential needed",
        body: `${humanizeSecret(secret)} is required${ref ? ` for ${shortRef(ref)}` : ""}. Grant access to continue.`,
        actions: ref
          ? [{ kind: "grant_access", label: "Set up now", target: ref }]
          : [],
        rawMessage: raw,
      };
    },
  },

  {
    test: /Secret not found:\s*(\S+)/,
    translate: (m, raw) => ({
      title: "Credential not set",
      body: `${humanizeSecret(m[1] ?? "A credential")} hasn't been added yet. Add it to enable this feature.`,
      actions: [{ kind: "open_components", label: "Add credential" }],
      rawMessage: raw,
    }),
  },

  // ── Auth / session ────────────────────────────────────────────────────
  {
    test: /[Ss]ession expired|Session required/,
    translate: (_, raw) => ({
      title: "Session expired",
      body: "You've been signed out. Sign in again to continue.",
      actions: [{ kind: "reconnect", label: "Sign in" }],
      rawMessage: raw,
    }),
  },

  {
    test: /API key.*(invalid|not valid|unauthorized|unauthenticated)|401|403|invalid.*api.?key/i,
    translate: (_, raw) => ({
      title: "Connection rejected",
      body: "The current API key isn't valid. Check your project's connection settings.",
      actions: [{ kind: "open_connections", label: "Fix connection" }],
      rawMessage: raw,
    }),
  },

  // ── Policy denied ─────────────────────────────────────────────────────
  {
    test: /:denied|policy.*denied|not (allowed|permitted)/i,
    translate: (_, raw) => ({
      title: "Blocked by permissions",
      body: "The current permissions don't allow this action. Loosen the permission or approve the action when prompted.",
      actions: [{ kind: "open_components", label: "Review permissions" }],
      rawMessage: raw,
    }),
  },

  // ── Tool not found / unknown tool ─────────────────────────────────────
  {
    test: /tool not found|unknown tool|no such tool|tool '([^']+)' is not available/i,
    translate: (m, raw) => ({
      title: "Tool unavailable",
      body: m[1]
        ? `The tool "${m[1]}" isn't installed or isn't enabled. Check your connections.`
        : "A required tool isn't installed or enabled. Check your connections.",
      actions: [{ kind: "open_connections", label: "Manage connections" }],
      rawMessage: raw,
    }),
  },

  // ── Manifest parse ────────────────────────────────────────────────────
  {
    test: /manifest.*(parse|invalid|malformed)|cyfr-manifest\.json.*invalid/i,
    translate: (_, raw) => ({
      title: "Invalid manifest",
      body: "An app's configuration file couldn't be read. The app needs to be fixed or reinstalled.",
      actions: [{ kind: "open_components", label: "Open apps" }],
      rawMessage: raw,
    }),
  },

  // ── Docker / container runtime ────────────────────────────────────────
  {
    test: /[Dd]ocker.*(not running|not found|unavailable)|docker daemon|Cannot connect to the Docker daemon/,
    translate: (_, raw) => ({
      title: "Runtime isn't running",
      body: "The local runtime that powers cyfr isn't available. Start it and try again.",
      actions: [{ kind: "install_runtime", label: "Start runtime" }],
      rawMessage: raw,
    }),
  },

  // ── Network / timeout ─────────────────────────────────────────────────
  {
    test: /ETIMEDOUT|timed out|timeout|Network (is |)unreachable|ENOTFOUND|ECONNREFUSED|fetch failed/i,
    translate: (_, raw) => ({
      title: "Connection failed",
      body: "Porta couldn't reach your cyfr instance. Check the connection URL and that the instance is running.",
      actions: [
        { kind: "retry", label: "Retry" },
        { kind: "open_connections", label: "Check project" },
      ],
      rawMessage: raw,
    }),
  },

  // ── Not logged in ─────────────────────────────────────────────────────
  {
    test: /[Nn]ot logged in|[Aa]uthentication required/,
    translate: (_, raw) => ({
      title: "Not signed in",
      body: "Sign in to continue.",
      actions: [{ kind: "reconnect", label: "Sign in" }],
      rawMessage: raw,
    }),
  },
];

export function translateError(raw: unknown): TranslatedError {
  const rawMessage = extractText(raw);

  for (const rule of RULES) {
    const match = rawMessage.match(rule.test);
    if (match) return rule.translate(match, rawMessage);
  }

  // Fall back to the existing parser so we reuse its well-established
  // patterns for the long tail.
  const parsed = parseError(rawMessage);
  return {
    title: titleFromKind(parsed.kind),
    body: parsed.message,
    actions: defaultActionsForKind(parsed.kind),
    rawMessage,
  };
}

function extractText(raw: unknown): string {
  if (raw instanceof Error) return raw.message;
  if (typeof raw === "string") return raw;
  try {
    return JSON.stringify(raw);
  } catch {
    return String(raw);
  }
}

function titleFromKind(kind: string): string {
  switch (kind) {
    case "credential_not_granted":
      return "Credential needed";
    case "auth":
      return "Sign-in required";
    default:
      return "Something went wrong";
  }
}

function defaultActionsForKind(kind: string): ErrorAction[] {
  switch (kind) {
    case "credential_not_granted":
      return [{ kind: "open_components", label: "Set up" }];
    case "auth":
      return [{ kind: "reconnect", label: "Sign in" }];
    default:
      return [];
  }
}

/** "cyfr_pk_abc…" or "GOOGLE_API_KEY" — show a friendlier label. */
function humanizeSecret(name: string): string {
  // Convert SCREAMING_SNAKE into Title Case.
  if (/^[A-Z0-9_]+$/.test(name)) {
    return name
      .toLowerCase()
      .split("_")
      .filter(Boolean)
      .map((w) => w[0]?.toUpperCase() + w.slice(1))
      .join(" ");
  }
  return name;
}

/** "catalyst:local.claude:1.0.0" → "claude" */
function shortRef(ref: string): string {
  const parts = ref.split(":");
  const nameSegment = parts[1];
  if (nameSegment) {
    const dotIdx = nameSegment.indexOf(".");
    return dotIdx >= 0 ? nameSegment.slice(dotIdx + 1) : nameSegment;
  }
  return ref;
}

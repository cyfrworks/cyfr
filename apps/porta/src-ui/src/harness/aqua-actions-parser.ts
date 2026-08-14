/**
 * Extracts, validates, and strips `aqua-actions` fenced blocks from an
 * assistant message.
 *
 * The block must open with exactly ` ```aqua-actions ` (no language
 * aliasing) and contain a JSON array of discriminated-union entries. Parse
 * or validation failures drop individual entries; the entire block is still
 * removed from the rendered content so the user never sees raw JSON, even
 * on malformed output.
 */

export type Intent =
  | { kind: "ui.navigate"; path: string }
  | { kind: "ui.overlay.open"; state?: "peek" | "half" | "full" }
  | { kind: "ui.overlay.close" }
  | { kind: "ui.overlay.focus_input" }
  | { kind: "ui.tincture.open"; publisher: string; name: string }
  | { kind: "ui.tincture.close"; name: string }
  | { kind: "ui.tincture.focus"; name: string }
  | { kind: "ui.schedules.focus"; id: string }
  | { kind: "ui.components.focus"; ref: string }
  | { kind: "ui.mcp.focus"; server: string }
  | { kind: "ui.copy_clipboard"; text: string }
  | {
      kind: "ui.request_approval";
      title: string;
      summary: string;
      risk: "low" | "medium" | "high";
      action_description: string;
    };

export type IntentKind = Intent["kind"];

const ALLOWED_PATHS = new Set<string>([
  "/",
  "/tinctures",
  "/schedules",
  "/components",
  "/mcp-servers",
  "/settings",
]);

const ALLOWED_OVERLAY_STATES = new Set<string>(["peek", "half", "full"]);

const ALLOWED_RISKS = new Set<string>(["low", "medium", "high"]);

// Match fenced blocks opening exactly with ```aqua-actions on its own line.
// The `g` flag lets us replace every block in one pass; `[\s\S]` handles
// multi-line bodies since JS regex `.` does not cross newlines by default.
const BLOCK_RE = /```aqua-actions[ \t]*\r?\n([\s\S]*?)```/g;

// Render-time strip regex: matches closed blocks OR open-but-unclosed tails
// at end-of-string. Used during streaming so partial blocks never flash.
const RENDER_STRIP_RE = /```aqua-actions[ \t]*\r?\n[\s\S]*?(?:```|$)/g;

/**
 * Remove any aqua-actions blocks (closed or mid-stream) from a text chunk
 * for display. This is the safe-for-rendering variant; it does not parse or
 * validate — use {@link parsePortaActions} for dispatch.
 */
export function stripPortaActionBlocks(content: string): string {
  return content.replace(RENDER_STRIP_RE, "");
}

export interface ParseResult {
  /** Assistant content with all aqua-actions blocks removed and trimmed. */
  strippedContent: string;
  /** Validated intents in emission order. */
  intents: Intent[];
  /** Entries that were present but dropped (logged by the activity lane). */
  drops: { raw: unknown; reason: string }[];
}

type ValidateResult =
  | { ok: true; intent: Intent }
  | { ok: false; reason: string };

export function parsePortaActions(content: string): ParseResult {
  const intents: Intent[] = [];
  const drops: { raw: unknown; reason: string }[] = [];

  const strippedContent = content
    .replace(BLOCK_RE, (_match, body: string) => {
      let parsed: unknown;
      try {
        parsed = JSON.parse(body);
      } catch (err) {
        drops.push({
          raw: body,
          reason: `JSON parse error: ${(err as Error).message}`,
        });
        return "";
      }
      if (!Array.isArray(parsed)) {
        drops.push({ raw: parsed, reason: "block body is not a JSON array" });
        return "";
      }
      for (const entry of parsed) {
        const result = validateIntent(entry);
        if (result.ok) intents.push(result.intent);
        else drops.push({ raw: entry, reason: result.reason });
      }
      return "";
    })
    .trim();

  return { strippedContent, intents, drops };
}

function asString(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

function validateIntent(raw: unknown): ValidateResult {
  if (!raw || typeof raw !== "object") {
    return { ok: false, reason: "entry is not an object" };
  }
  const obj = raw as Record<string, unknown>;
  const kind = obj.kind;
  if (typeof kind !== "string") {
    return { ok: false, reason: "missing or non-string 'kind'" };
  }

  switch (kind) {
    case "ui.navigate": {
      const path = asString(obj.path);
      if (!path) return { ok: false, reason: "ui.navigate: missing 'path'" };
      if (!ALLOWED_PATHS.has(path)) {
        return { ok: false, reason: `ui.navigate: path '${path}' not in allowlist` };
      }
      return { ok: true, intent: { kind, path } };
    }
    case "ui.overlay.open": {
      const state = obj.state;
      if (state === undefined) {
        return { ok: true, intent: { kind } };
      }
      if (typeof state !== "string" || !ALLOWED_OVERLAY_STATES.has(state)) {
        return { ok: false, reason: `ui.overlay.open: invalid state '${String(state)}'` };
      }
      return {
        ok: true,
        intent: { kind, state: state as "peek" | "half" | "full" },
      };
    }
    case "ui.overlay.close":
      return { ok: true, intent: { kind } };
    case "ui.overlay.focus_input":
      return { ok: true, intent: { kind } };
    case "ui.tincture.open": {
      const publisher = asString(obj.publisher);
      const name = asString(obj.name);
      if (!publisher || !name) {
        return { ok: false, reason: "ui.tincture.open: requires 'publisher' and 'name'" };
      }
      return { ok: true, intent: { kind, publisher, name } };
    }
    case "ui.tincture.close": {
      const name = asString(obj.name);
      if (!name) return { ok: false, reason: "ui.tincture.close: requires 'name'" };
      return { ok: true, intent: { kind, name } };
    }
    case "ui.tincture.focus": {
      const name = asString(obj.name);
      if (!name) return { ok: false, reason: "ui.tincture.focus: requires 'name'" };
      return { ok: true, intent: { kind, name } };
    }
    case "ui.schedules.focus": {
      const id = asString(obj.id);
      if (!id) return { ok: false, reason: "ui.schedules.focus: requires 'id'" };
      return { ok: true, intent: { kind, id } };
    }
    case "ui.components.focus": {
      const ref = asString(obj.ref);
      if (!ref) return { ok: false, reason: "ui.components.focus: requires 'ref'" };
      return { ok: true, intent: { kind, ref } };
    }
    case "ui.mcp.focus": {
      const server = asString(obj.server);
      if (!server) return { ok: false, reason: "ui.mcp.focus: requires 'server'" };
      return { ok: true, intent: { kind, server } };
    }
    case "ui.copy_clipboard": {
      const text = asString(obj.text);
      if (text === null) return { ok: false, reason: "ui.copy_clipboard: requires 'text'" };
      return { ok: true, intent: { kind, text } };
    }
    case "ui.request_approval": {
      const title = asString(obj.title);
      const summary = asString(obj.summary);
      const risk = obj.risk;
      const actionDesc = asString(obj.action_description);
      if (!title) return { ok: false, reason: "ui.request_approval: requires 'title'" };
      if (!summary) return { ok: false, reason: "ui.request_approval: requires 'summary'" };
      if (typeof risk !== "string" || !ALLOWED_RISKS.has(risk)) {
        return { ok: false, reason: `ui.request_approval: risk must be low|medium|high, got '${String(risk)}'` };
      }
      if (!actionDesc) {
        return { ok: false, reason: "ui.request_approval: requires 'action_description'" };
      }
      return {
        ok: true,
        intent: {
          kind,
          title,
          summary,
          risk: risk as "low" | "medium" | "high",
          action_description: actionDesc,
        },
      };
    }
    default:
      return { ok: false, reason: `unknown kind '${kind}'` };
  }
}

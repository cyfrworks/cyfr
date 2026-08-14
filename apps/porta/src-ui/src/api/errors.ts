/**
 * Parses raw CYFR error strings into user-friendly messages.
 *
 * Errors can arrive as:
 *   - JSON strings: {"message":"...", "type":"dispatch_error"}
 *   - Structured host errors: "access-denied: NAME not granted to REF"
 *   - Plain text from stderr
 */

interface ParsedError {
  /** User-friendly message */
  message: string;
  /** Error category for conditional UI (e.g. showing a "Set up" action) */
  kind: "credential_not_granted" | "auth" | "generic";
}

/** Known error patterns mapped to friendly messages and kinds */
/** Helper to safely get a capture group (defaults to "" if undefined) */
function g(match: RegExpMatchArray, index: number): string {
  return match[index] ?? "";
}

const PATTERNS: {
  test: RegExp;
  kind: ParsedError["kind"];
  rewrite: (match: RegExpMatchArray) => string;
}[] = [
  {
    // Vault read denial from the host: "access-denied: NAME not granted to REF"
    test: /access-denied:\s*(\S+) not granted to (\S+)/,
    kind: "credential_not_granted",
    rewrite: (m) => `${g(m, 1)} not granted to ${shortRef(g(m, 2))}.`,
  },
  {
    // Session / auth errors
    test: /[Ss]ession expired/,
    kind: "auth",
    rewrite: () => "Session expired. Please log in again.",
  },
  {
    test: /[Nn]ot logged in|[Aa]uthentication required/,
    kind: "auth",
    rewrite: () => "Not logged in. Please log in to continue.",
  },
];

/** Shorten a component ref to just publisher.name */
function shortRef(ref: string): string {
  // "catalyst:moonmoon69.claude:1.0.0" → "claude"
  const parts = ref.split(":");
  const nameSegment = parts[1];
  if (nameSegment) {
    const dotIdx = nameSegment.indexOf(".");
    return dotIdx >= 0 ? nameSegment.slice(dotIdx + 1) : nameSegment;
  }
  return ref;
}

/**
 * Try to extract the message from a JSON error string.
 * Handles:
 *   - Plain JSON: {"message":"...", "type":"..."}
 *   - Prefixed JSON: "Invoke error: {\"message\":\"...\",\"type\":\"dispatch_error\"}"
 * Returns null if the input isn't JSON or has no message field.
 */
function tryParseJson(raw: string): string | null {
  // Strip common prefixes to find the JSON object
  let jsonStr = raw.trim();
  const jsonStart = jsonStr.indexOf("{");
  if (jsonStart < 0) return null;
  if (jsonStart > 0) jsonStr = jsonStr.slice(jsonStart);

  try {
    const obj = JSON.parse(jsonStr) as Record<string, unknown>;
    if (typeof obj.message === "string") return obj.message;
    if (typeof obj.error === "string") return obj.error;
  } catch {
    // Not valid JSON
  }
  return null;
}

/**
 * Try to extract a human-readable message from Elixir inspect-format strings.
 * These look like: %{"error" => %{"message" => "API key not valid. Please pass a valid API key."}}
 */
function tryExtractElixirMessage(text: string): string | null {
  // Look for "message" => "..." pattern (Elixir inspect format in escaped JSON)
  const patterns = [
    /\\?"message\\?"\s*=>\s*\\?"([^"\\]+(?:\\.[^"\\]*)*)\\?"/,
    /"message"\s*=>\s*"([^"]+)"/,
  ];
  for (const pat of patterns) {
    const match = text.match(pat);
    if (match?.[1]) {
      const msg = match[1].replace(/\\"/g, '"').replace(/\\\\/g, "\\");
      // Skip if it's just a technical status like "INVALID_ARGUMENT"
      if (msg.length > 3 && msg.includes(" ")) return msg;
    }
  }
  return null;
}

/**
 * Strip CLI command hints from error messages.
 * e.g. "... Grant access with: cyfr secret grant ..." → "..."
 */
function stripCliHints(msg: string): string {
  return msg
    .replace(/\.\s*Grant access with:.*$/s, ".")
    .replace(/\.\s*Run ['"]cyfr [^'"]+['"] to.*$/s, ".")
    .replace(/\.\s*Use:\s.*$/s, ".");
}

/**
 * Parse a raw error (string or Error) into a user-friendly message.
 */
export function parseError(raw: unknown): ParsedError {
  let text: string;
  if (raw instanceof Error) {
    text = raw.message;
  } else if (typeof raw === "string") {
    text = raw;
  } else {
    text = String(raw);
  }

  // Try extracting from JSON wrapper
  const jsonMsg = tryParseJson(text);
  if (jsonMsg) text = jsonMsg;

  // Match against known patterns
  for (const pattern of PATTERNS) {
    const match = text.match(pattern.test);
    if (match) {
      return { message: pattern.rewrite(match), kind: pattern.kind };
    }
  }

  // Try extracting a readable message from Elixir inspect format
  const elixirMsg = tryExtractElixirMessage(text);
  if (elixirMsg) {
    return { message: elixirMsg, kind: "generic" };
  }

  // Fallback: clean up the message
  text = stripCliHints(text);

  // Strip "Invoke error: " prefix
  text = text.replace(/^Invoke error:\s*/i, "");

  // Truncate very long messages
  if (text.length > 200) {
    text = text.slice(0, 197) + "...";
  }

  return { message: text, kind: "generic" };
}

/**
 * Convenience: just get the friendly message string.
 */
export function friendlyError(raw: unknown): string {
  return parseError(raw).message;
}

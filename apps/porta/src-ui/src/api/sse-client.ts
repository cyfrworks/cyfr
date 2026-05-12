import type { McpClient } from "./mcp-client";
import type { ExecutionEvent } from "./types";

export type SSEEventCallback = (event: ExecutionEvent) => void;
export type SSEErrorCallback = (error: Error) => void;
export type SSECloseCallback = () => void;

export interface SSEConnection {
  close: () => void;
}

/**
 * Stream execution events from `GET {baseUrl}/api/executions/{id}/events`.
 *
 * Uses `fetch` + a ReadableStream SSE parser rather than the native
 * `EventSource` so we can send `Authorization: Bearer` (API-key mode) and an
 * explicit `Last-Event-ID` on the initial connect — `EventSource` supports
 * neither. Cookies (Sanctum session mode) ride along via `credentials: include`.
 */
export function connectSSE(
  client: McpClient,
  opts: {
    executionId: string;
    lastEventId?: string;
    onEvent: SSEEventCallback;
    onError: SSEErrorCallback;
    onClose: SSECloseCallback;
  },
): SSEConnection {
  let closed = false;
  const ctrl = new AbortController();

  const finish = (terminal: boolean, err?: Error) => {
    if (closed) return;
    closed = true;
    try {
      ctrl.abort();
    } catch {
      /* ignore */
    }
    if (err) opts.onError(err);
    else if (terminal) opts.onClose();
  };

  const headers: Record<string, string> = { accept: "text/event-stream" };
  if (client.apiKey) headers["authorization"] = `Bearer ${client.apiKey}`;
  if (opts.lastEventId) headers["last-event-id"] = opts.lastEventId;

  const url = `${client.baseUrl}/api/executions/${encodeURIComponent(
    opts.executionId,
  )}/events`;

  (async () => {
    let resp: Response;
    try {
      resp = await fetch(url, {
        method: "GET",
        headers,
        credentials: "include",
        signal: ctrl.signal,
      });
    } catch (e) {
      if (!closed) finish(false, asError(e));
      return;
    }

    if (!resp.ok || !resp.body) {
      finish(false, new Error(`SSE HTTP ${resp.status}`));
      return;
    }

    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";

    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });

        let idx: number;
        // Frames are separated by a blank line.
        while ((idx = buf.indexOf("\n\n")) !== -1) {
          const frame = buf.slice(0, idx);
          buf = buf.slice(idx + 2);
          const parsed = parseFrame(frame);
          if (!parsed) continue;
          if (parsed.event === "ping" || parsed.event === "keepalive") continue;

          let data: Record<string, unknown>;
          try {
            data = JSON.parse(parsed.data) as Record<string, unknown>;
          } catch {
            continue;
          }
          opts.onEvent({
            sequence: parsed.id != null ? Number(parsed.id) : 0,
            type: parsed.event ?? "message",
            data,
          });
          if (parsed.event === "complete" || parsed.event === "error") {
            finish(true);
            return;
          }
        }
      }
      // Stream ended without an explicit terminal event.
      finish(true);
    } catch (e) {
      if (!closed) finish(false, asError(e));
    } finally {
      try {
        reader.releaseLock();
      } catch {
        /* ignore */
      }
    }
  })();

  return {
    close() {
      finish(false);
    },
  };
}

interface ParsedFrame {
  event?: string;
  data: string;
  id?: string;
}

function parseFrame(frame: string): ParsedFrame | null {
  let event: string | undefined;
  let id: string | undefined;
  const dataLines: string[] = [];
  for (const rawLine of frame.split(/\r?\n/)) {
    const line = rawLine.trimEnd();
    if (!line || line.startsWith(":")) continue;
    const colon = line.indexOf(":");
    const field = colon === -1 ? line : line.slice(0, colon);
    const value =
      colon === -1 ? "" : line.slice(colon + 1).replace(/^ /, "");
    if (field === "event") event = value;
    else if (field === "data") dataLines.push(value);
    else if (field === "id") id = value;
  }
  if (dataLines.length === 0) return null;
  return { event, id, data: dataLines.join("\n") };
}

function asError(e: unknown): Error {
  if (e instanceof Error) {
    // An abort during close() is not a real error.
    return e;
  }
  return new Error(String(e));
}

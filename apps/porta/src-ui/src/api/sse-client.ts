import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { ExecutionEvent } from "./types";

export type SSEEventCallback = (event: ExecutionEvent) => void;
export type SSEErrorCallback = (error: Error) => void;
export type SSECloseCallback = () => void;

export interface SSEConnection {
  close: () => void;
}

interface SseEventPayload {
  execution_id: string;
  sequence: number;
  event_type: string;
  data: string;
}

/**
 * Connect to an SSE execution events stream via Tauri proxy.
 * The Rust backend connects to the SSE endpoint and forwards events
 * as Tauri events, bypassing CORS restrictions.
 */
export function connectSSE(
  _url: string,
  opts: {
    executionId: string;
    onEvent: SSEEventCallback;
    onError: SSEErrorCallback;
    onClose: SSECloseCallback;
  },
): SSEConnection {
  let closed = false;
  let unlisten: (() => void) | null = null;

  // Listen for SSE events from the Rust proxy
  listen<SseEventPayload>("sse-event", (event) => {
    if (closed) return;
    const payload = event.payload;

    // Filter to our execution
    if (payload.execution_id !== opts.executionId) return;

    try {
      const data = JSON.parse(payload.data) as Record<string, unknown>;
      const execEvent: ExecutionEvent = {
        sequence: payload.sequence,
        type: payload.event_type,
        data,
      };
      opts.onEvent(execEvent);

      // Close on terminal events
      if (payload.event_type === "complete" || payload.event_type === "error") {
        closed = true;
        opts.onClose();
      }
    } catch {
      // Skip unparseable events
    }
  }).then((fn) => {
    unlisten = fn;
  });

  // Start the SSE proxy in Rust
  invoke("connect_sse", { executionId: opts.executionId }).catch((err) => {
    if (!closed) {
      closed = true;
      opts.onError(new Error(String(err)));
    }
  });

  return {
    close() {
      closed = true;
      unlisten?.();
    },
  };
}

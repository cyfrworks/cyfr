import { create } from "zustand";
import { McpClient } from "../api/mcp-client";
import { wrapWithApprovalGate } from "../api/gated-mcp-client";
import { registerToolAnnotations } from "../config/tool-tiers";
import { host, type RuntimeMode } from "../host";

export type { RuntimeMode };

export interface ConnectionState {
  /** Active Cyfr base URL ("" ⇒ same origin). */
  cyfrUrl: string;
  /** "session" = cookie/device-flow; "remote" = explicit URL + API key. */
  mode: RuntimeMode;
  hasApiKey: boolean;
  /** Shared MCP client. Created lazily after auth is wired up. */
  mcpClient: McpClient | null;

  /** Re-read mode/url/api-key from the host config blob. */
  refresh: () => void;

  /**
   * Build (or rebuild) the shared McpClient based on current mode.
   * - session mode: a session id (from device flow) is attached if present
   * - remote mode: the stored API key is attached
   */
  initMcpClient: () => Promise<McpClient>;

  /** Get the shared client, initializing it on first call. */
  getMcpClient: () => Promise<McpClient>;

  /**
   * Discard the cached MCP client. Call after switching modes or
   * updating the API key so the next getMcpClient() rebuilds.
   */
  resetMcpClient: () => void;
}

export const useConnectionStore = create<ConnectionState>((set, get) => ({
  cyfrUrl: host.cyfrUrl(),
  mode: host.mode(),
  hasApiKey: host.hasApiKey(),
  mcpClient: null,

  refresh: () =>
    set({
      cyfrUrl: host.cyfrUrl(),
      mode: host.mode(),
      hasApiKey: host.hasApiKey(),
    }),

  initMcpClient: async () => {
    get().refresh();
    const { mode, cyfrUrl } = get();

    const client =
      mode === "remote"
        ? new McpClient(cyfrUrl, { apiKey: host.getApiKey() })
        : new McpClient(cyfrUrl);

    if (mode !== "remote") {
      const sid = host.getSessionId();
      if (sid) client.sessionId = sid;
    }

    // Gate dangerous tool calls invoked directly from the UI through the
    // approval flow. AQUA-initiated calls run server-side and aren't
    // intercepted here.
    wrapWithApprovalGate(client);

    // Teach the gate the server's own per-action read/write kinds so a
    // server-side reclassification is honored without a client release.
    // Fire-and-forget: until it lands (or if it fails offline), the gate's
    // static default-deny fallback applies.
    client
      .listTools()
      .then((tools) => registerToolAnnotations(tools))
      .catch(() => {});

    set({ mcpClient: client });
    return client;
  },

  getMcpClient: async () => {
    const existing = get().mcpClient;
    if (existing) return existing;
    return get().initMcpClient();
  },

  resetMcpClient: () => set({ mcpClient: null }),
}));

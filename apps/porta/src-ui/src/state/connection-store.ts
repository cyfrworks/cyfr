import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { McpClient } from "../api/mcp-client";

export interface UpdateInfo {
  kind: "cyfr" | "porta";
  current: string;
  latest: string;
  url?: string;
}

export type RuntimeMode = "remote" | "local-attached" | "local-managed";

interface PortaModeInfo {
  mode: string | null;
  url: string;
  has_api_key: boolean;
}

export interface ConnectionState {
  cyfrUrl: string;
  mode: RuntimeMode | null;
  hasApiKey: boolean;
  /** Shared MCP client. Created lazily after auth is wired up. */
  mcpClient: McpClient | null;

  bootComplete: boolean;
  bootState: string;
  bootMessage: string;
  bootProgress: number;
  updating: boolean;
  updateInfo: UpdateInfo | null;

  setBootComplete: (complete: boolean) => void;
  setBootState: (state: string, message: string, progress: number) => void;
  startUpdate: (info: UpdateInfo) => void;
  finishUpdate: () => void;
  fetchCyfrUrl: () => Promise<void>;

  /** Read mode + url + has_api_key from porta.json. */
  fetchMode: () => Promise<void>;

  /**
   * Build (or rebuild) the shared McpClient based on current mode.
   * - Local modes: read session_id from ~/.cyfr/config.json
   * - Remote mode: read api_key from ~/.cyfr/porta.json
   * After this resolves, `mcpClient` is set.
   */
  initMcpClient: () => Promise<McpClient>;

  /** Get the shared client, initializing it on first call. */
  getMcpClient: () => Promise<McpClient>;

  /**
   * Discard the cached MCP client. Call after switching modes or
   * updating the API key so the next getMcpClient() rebuilds with
   * the new credentials.
   */
  resetMcpClient: () => void;
}

export const useConnectionStore = create<ConnectionState>((set, get) => ({
  cyfrUrl: "http://127.0.0.1:4000",
  mode: null,
  hasApiKey: false,
  mcpClient: null,

  bootComplete: false,
  bootState: "checking",
  bootMessage: "",
  bootProgress: 0,
  updating: false,
  updateInfo: null,

  setBootComplete: (complete) => set({ bootComplete: complete }),

  setBootState: (state, message, progress) =>
    set({ bootState: state, bootMessage: message, bootProgress: progress }),

  startUpdate: (info) => set({ updating: true, updateInfo: info }),
  finishUpdate: () => set({ updating: false, updateInfo: null }),

  fetchCyfrUrl: async () => {
    try {
      const url = await invoke<string>("get_cyfr_url");
      set({ cyfrUrl: url });
    } catch {
      // Fall back to default
    }
  },

  fetchMode: async () => {
    try {
      const info = await invoke<PortaModeInfo>("get_porta_mode");
      set({
        mode: (info.mode as RuntimeMode | null) ?? null,
        cyfrUrl: info.url,
        hasApiKey: info.has_api_key,
      });
    } catch {
      // Fall back to defaults
    }
  },

  initMcpClient: async () => {
    await get().fetchMode();
    const { mode, cyfrUrl } = get();

    let client: McpClient;

    if (mode === "remote") {
      const apiKey = await invoke<string | null>("read_porta_api_key");
      client = new McpClient(cyfrUrl, { apiKey: apiKey ?? undefined });
    } else {
      // Local modes: pull session_id from CLI's config
      client = new McpClient(cyfrUrl);
      try {
        const sessionId = await invoke<string | null>("read_cli_session");
        if (sessionId) client.sessionId = sessionId;
      } catch {
        // No session yet — Device Flow will populate it
      }
    }

    // Persist any session ID the server hands back
    client.onSessionRecovered = (newSessionId) => {
      void invoke("save_cli_session", { sessionId: newSessionId });
    };

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

import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { useConnectionStore } from "./connection-store";
import * as cyfrMcp from "../api/cyfr-mcp";

export interface AuthState {
  authenticated: boolean;
  userName: string | null;
  userEmail: string | null;

  // Device flow state
  loginPending: boolean;
  userCode: string | null;
  verificationUri: string | null;
  loginError: string | null;

  checkAuth: () => Promise<void>;
  startLogin: () => Promise<void>;
  logout: () => Promise<void>;
}

export const useAuthStore = create<AuthState>((set, get) => ({
  authenticated: false,
  userName: null,
  userEmail: null,
  loginPending: false,
  userCode: null,
  verificationUri: null,
  loginError: null,

  checkAuth: async () => {
    try {
      const client = await useConnectionStore.getState().getMcpClient();
      const data = await cyfrMcp.whoami(client);

      // whoami returns user_id at top level, email may be in registry sub-object
      const userId = data.user_id as string | undefined;
      const registry = data.registry as Record<string, unknown> | undefined;
      const email = (data.email as string) ?? (registry?.email as string) ?? null;
      const name = (data.name as string) ?? (registry?.publisher_name as string) ?? null;

      if (userId) {
        set({
          authenticated: true,
          userEmail: email,
          userName: name,
        });
        return;
      }

      // Not authenticated
      set({ authenticated: false, userName: null, userEmail: null });
    } catch {
      set({ authenticated: false, userName: null, userEmail: null });
    }
  },

  startLogin: async () => {
    set({
      loginPending: true,
      userCode: null,
      verificationUri: null,
      loginError: null,
    });

    try {
      // Device Flow only happens in local modes — remote mode uses API key
      // entered in the SetupWizard. Use the shared MCP client.
      const client = await useConnectionStore.getState().getMcpClient();

      // Retry MCP connection — server may still be starting up after boot
      let initErr: unknown;
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          await client.initialize();
          initErr = null;
          break;
        } catch (err) {
          initErr = err;
          if (attempt < 2) await new Promise((r) => setTimeout(r, 2000));
        }
      }
      if (initErr) throw initErr;

      // Step 1: Start device flow
      const initResult = await cyfrMcp.deviceInit(client);

      const userCode = initResult.user_code as string;
      const verificationUri = initResult.verification_uri as string;
      const deviceCode = initResult.device_code as string;
      let interval = (initResult.interval as number) ?? 5;
      if (interval < 5) interval = 5;

      set({ userCode, verificationUri });

      // Poll for completion (user clicks the link manually from LoginPage)
      for (let i = 0; i < 60; i++) {
        await new Promise((r) => setTimeout(r, interval * 1000));
        if (!get().loginPending) return; // cancelled

        try {
          const pollResult = await cyfrMcp.devicePoll(client, deviceCode);

          const status = pollResult.status as string;

          if (status === "complete") {
            // Get the authenticated session ID
            const sessionId =
              (pollResult.session_id as string) || client.sessionId;

            // Save to CLI config so `cyfr` commands use it
            if (sessionId) client.sessionId = sessionId;
            await invoke("save_cli_session", { sessionId: client.sessionId });

            const user = pollResult.user as
              | Record<string, unknown>
              | undefined;
            set({
              authenticated: true,
              loginPending: false,
              userCode: null,
              verificationUri: null,
              userName: (user?.name as string) ?? null,
              userEmail: (user?.email as string) ?? null,
            });
            return;
          }

          if (status === "expired") {
            set({
              loginPending: false,
              loginError: "Code expired. Try again.",
            });
            return;
          }

          if (status === "denied") {
            set({
              loginPending: false,
              loginError: "Authorization denied.",
            });
            return;
          }
        } catch {
          // Network error — keep polling
        }
      }

      set({ loginPending: false, loginError: "Login timed out." });
    } catch (err) {
      set({
        loginPending: false,
        loginError: `Login failed: ${err instanceof Error ? err.message : String(err)}`,
      });
    }
  },

  logout: async () => {
    try {
      const client = await useConnectionStore.getState().getMcpClient();
      await cyfrMcp.logout(client);
      // Drop the now-invalid sessionId from the local CLI config too,
      // so re-running cyfr from a terminal doesn't keep using a dead session.
      await invoke("save_cli_session", { sessionId: "" });
    } catch {
      // Already logged out
    }
    // Discard the cached MCP client so the next caller rebuilds without
    // the invalid sessionId.
    useConnectionStore.getState().resetMcpClient();
    set({
      authenticated: false,
      userName: null,
      userEmail: null,
      loginPending: false,
      userCode: null,
      verificationUri: null,
    });
  },
}));

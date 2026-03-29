import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { McpClient } from "../api/mcp-client";
import { useConnectionStore } from "./connection-store";

interface CyfrResult {
  stdout: string;
  stderr: string;
  success: boolean;
  code: number;
}

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
      // Use the CLI — it reads its own session from ~/.cyfr/config.json
      const result = await invoke<CyfrResult>("cyfr_command", {
        args: ["whoami"],
      });

      if (result.success) {
        const data = JSON.parse(result.stdout) as Record<string, unknown>;
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
      // Device flow needs MCP client — session tool doesn't require auth
      const cyfrUrl =
        (await invoke<string>("get_cyfr_url").catch(() => null)) ??
        useConnectionStore.getState().cyfrUrl;
      useConnectionStore.setState({ cyfrUrl });
      const client = new McpClient(cyfrUrl);

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
      const initResult = await client.callTool("session", {
        action: "device-init",
        provider: "github",
      });

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
          const pollResult = await client.callTool("session", {
            action: "device-poll",
            device_code: deviceCode,
            provider: "github",
          });

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
      await invoke<CyfrResult>("cyfr_command", { args: ["logout"] });
    } catch {
      // Already logged out
    }
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

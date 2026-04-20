import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { useConnectionStore } from "./connection-store";
import * as cyfrMcp from "../api/cyfr-mcp";

/**
 * Claim-gate state — whenever the user has logged in locally but hasn't yet
 * claimed a personal namespace on cyfr.run, the UI routes to a gate screen
 * (see ClaimNamespacePage). `suggestedUsername` pre-fills the form; the IdP
 * `accessToken` is held in memory for one call to `registry.claim-personal`
 * and then discarded (NOT persisted — matches the 10-min signed-cookie TTL
 * used by the web flow).
 */
export interface ClaimGateState {
  needed: boolean;
  suggestedUsername: string | null;
  accessToken: string | null;
  provider: string | null;
}

export interface MembershipSummary {
  slug: string;
  role: string;
}

export interface AuthState {
  authenticated: boolean;
  userName: string | null;
  userEmail: string | null;

  // Registry identity (cyfr.run push tokens). `personalSlug: null` with
  // `authenticated: true` is the claim-gate state — the user is logged in
  // locally but hasn't claimed a personal namespace yet.
  registryAuthenticated: boolean;
  personalSlug: string | null;
  memberships: MembershipSummary[];

  // First-login claim gate. When `needed: true` the LoginPage routes to
  // the claim-namespace screen instead of the dashboard.
  claimGate: ClaimGateState;

  // Device flow state
  loginPending: boolean;
  userCode: string | null;
  verificationUri: string | null;
  loginError: string | null;
  // Non-fatal warning from the probe — e.g. push tokens not cached
  // locally. Surface once; clear on next checkAuth.
  loginWarning: string | null;

  checkAuth: () => Promise<void>;
  startLogin: (provider?: "github" | "google") => Promise<void>;
  submitPersonalClaim: (username: string) => Promise<"ok" | "slug_taken" | "invalid" | "reauth" | "error">;
  dismissClaimGate: () => void;
  logout: () => Promise<void>;
}

const emptyClaimGate: ClaimGateState = {
  needed: false,
  suggestedUsername: null,
  accessToken: null,
  provider: null,
};

// Case-insensitive substring match, used to classify MCP error messages
// surfaced as plain strings by the server. We inspect substrings rather
// than status codes because the `registry.*` MCP tool maps errors to
// human-readable text (see compendium/mcp.ex `to_error_string/1`).
function includesIgnoreCase(haystack: string, needle: string): boolean {
  return haystack.toLowerCase().includes(needle.toLowerCase());
}

export const useAuthStore = create<AuthState>((set, get) => ({
  authenticated: false,
  userName: null,
  userEmail: null,
  registryAuthenticated: false,
  personalSlug: null,
  memberships: [],
  claimGate: emptyClaimGate,
  loginPending: false,
  userCode: null,
  verificationUri: null,
  loginError: null,
  loginWarning: null,

  checkAuth: async () => {
    try {
      const client = await useConnectionStore.getState().getMcpClient();

      // Two-action whoami compose: session.whoami gives local identity,
      // registry.whoami gives cyfr.run namespace state. Call in parallel
      // since they're independent server-side; merge in state.
      // Registry failures are soft — the local identity side is still useful
      // when cyfr.run is unreachable or the user hasn't run a probe yet.
      const [session, registryResult] = await Promise.allSettled([
        cyfrMcp.sessionWhoami(client),
        cyfrMcp.registryWhoami(client),
      ]);

      if (session.status !== "fulfilled") {
        // session.whoami is authoritative for local auth — its failure means
        // no session cookie / invalid Bearer. Treat as logged-out.
        set({
          authenticated: false,
          userName: null,
          userEmail: null,
          registryAuthenticated: false,
          personalSlug: null,
          memberships: [],
        });
        return;
      }

      const sessionData = session.value;
      const hasUser = typeof sessionData.user_id === "string" && sessionData.user_id !== "";

      if (!hasUser) {
        set({
          authenticated: false,
          userName: null,
          userEmail: null,
          registryAuthenticated: false,
          personalSlug: null,
          memberships: [],
        });
        return;
      }

      // Local identity
      const email = sessionData.email ?? null;
      const name = sessionData.display_name ?? sessionData.email ?? null;

      // Registry identity — default to unauthenticated shape when the call
      // failed (network or 401). Don't surface an error; just show the
      // claim-gate hint downstream.
      let registryAuthenticated = false;
      let personalSlug: string | null = null;
      let memberships: MembershipSummary[] = [];

      if (registryResult.status === "fulfilled") {
        const reg = registryResult.value;
        registryAuthenticated = Boolean(reg.authenticated);
        personalSlug = reg.personal_namespace?.slug ?? null;
        memberships = (reg.memberships ?? []).map((m) => ({
          slug: m.slug,
          role: m.role,
        }));
      }

      set({
        authenticated: true,
        userName: name,
        userEmail: email,
        registryAuthenticated,
        personalSlug,
        memberships,
      });
    } catch {
      set({
        authenticated: false,
        userName: null,
        userEmail: null,
        registryAuthenticated: false,
        personalSlug: null,
        memberships: [],
      });
    }
  },

  startLogin: async (provider = "github") => {
    set({
      loginPending: true,
      userCode: null,
      verificationUri: null,
      loginError: null,
      loginWarning: null,
      claimGate: emptyClaimGate,
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
      const initResult = await cyfrMcp.deviceInit(client, provider);

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
          const pollResult = await cyfrMcp.devicePoll(client, deviceCode, provider);

          const status = pollResult.status as string;

          if (status === "complete") {
            // `reauthenticate: true` means the IdP access_token was rejected
            // by cyfr.run during probe — the device_code is one-shot, so we
            // force a full re-login.
            if (pollResult.reauthenticate === true) {
              set({
                loginPending: false,
                loginError:
                  "Login session expired during credential setup. " +
                  "Please sign in again.",
              });
              return;
            }

            // Save the session id so non-UI MCP callers pick it up
            const sessionId =
              (pollResult.session_id as string) || client.sessionId;
            if (sessionId) client.sessionId = sessionId;
            await invoke("save_cli_session", { sessionId: client.sessionId });

            const user = pollResult.user as Record<string, unknown> | undefined;
            const userName = (user?.name as string) ?? null;
            const userEmail = (user?.email as string) ?? null;

            // Non-fatal warnings — push tokens issued but not cached, or a
            // transient probe error. Session is valid; just surface a hint.
            let warning: string | null = null;
            const warns = pollResult.credential_store_warnings as unknown;
            if (Array.isArray(warns) && warns.length > 0) {
              warning =
                `Could not cache push tokens for: ${warns.join(", ")}. ` +
                `Try refreshing or re-running login if issues persist.`;
            }
            const probeErr = pollResult.probe_error as string | undefined;
            if (!warning && probeErr) {
              warning = `cyfr.run identity probe failed (${probeErr}). Some registry features may be limited.`;
            }

            // Claim gate — when cyfr.run reports no personal namespace, we
            // stash the one-shot access_token in memory (never persisted)
            // and flip the gate so routing/UI can pivot to the claim form.
            const needsClaim = pollResult.needs_personal_namespace === true;
            const accessToken = needsClaim
              ? (pollResult.access_token as string | undefined) ?? null
              : null;
            const suggestedUsername = needsClaim
              ? (pollResult.suggested_username as string | undefined) ?? null
              : null;

            if (needsClaim && !accessToken) {
              // Server contract violation — needs_personal_namespace without
              // an access_token means the server is older than auth-refactor
              // (or a mid-upgrade mismatch). Fail loud rather than wedging.
              set({
                loginPending: false,
                loginError:
                  "cyfr.run requires a personal namespace but the server did " +
                  "not return the access_token needed to claim one. Please " +
                  "upgrade the cyfr server.",
              });
              return;
            }

            set({
              authenticated: true,
              loginPending: false,
              userCode: null,
              verificationUri: null,
              userName,
              userEmail,
              loginWarning: warning,
              claimGate: needsClaim
                ? {
                    needed: true,
                    suggestedUsername,
                    accessToken,
                    provider,
                  }
                : emptyClaimGate,
            });

            // Refresh registry identity after login — the probe seeded
            // CredentialStore, so `registry.whoami` now returns real data.
            // Don't await; let it populate in the background.
            void get().checkAuth();
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

  /**
   * Claim the user's one-time personal namespace on cyfr.run using the
   * access_token cached from device-poll. Exactly mirrors the codex CLI
   * flow — see apps/codex/cmd/login.go promptAndClaimPersonalNamespace.
   *
   * Returns a discriminant the UI can use to decide whether to keep the
   * form open ("slug_taken", "invalid") or dismiss ("ok"). "reauth" means
   * the IdP token expired; the UI should route to the login screen to
   * restart DeviceFlow. On any other error, we return "error" and the UI
   * shows a generic message.
   */
  submitPersonalClaim: async (username) => {
    const gate = get().claimGate;
    if (!gate.needed || !gate.accessToken || !gate.provider) {
      return "error";
    }

    try {
      const client = await useConnectionStore.getState().getMcpClient();
      await cyfrMcp.registryClaimPersonal(client, {
        username,
        provider: gate.provider,
        access_token: gate.accessToken,
      });

      // Discard the access_token on success — never persisted, and the
      // server-side token is now one-shot-used.
      set({ claimGate: emptyClaimGate });
      // Refresh whoami so the dashboard picks up the new personal slug.
      await get().checkAuth();
      return "ok";
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);

      // slug_taken → keep form open, let the UI re-prompt.
      if (
        includesIgnoreCase(msg, "slug_taken") ||
        includesIgnoreCase(msg, "already taken")
      ) {
        return "slug_taken";
      }

      // already_claimed → rare, but treat as success. The user already has
      // a namespace; next whoami will surface it. Dismiss the gate.
      if (includesIgnoreCase(msg, "already_claimed")) {
        set({ claimGate: emptyClaimGate });
        await get().checkAuth();
        return "ok";
      }

      if (
        includesIgnoreCase(msg, "invalid_username") ||
        includesIgnoreCase(msg, "reserved")
      ) {
        return "invalid";
      }

      if (includesIgnoreCase(msg, "invalid_access_token")) {
        // Dead IdP token; force re-login.
        set({ claimGate: emptyClaimGate });
        return "reauth";
      }

      return "error";
    }
  },

  dismissClaimGate: () => {
    // User explicitly bailed out of the claim flow. Keep `authenticated: true`
    // because the Sanctum session is valid, but discard the access_token so
    // we don't hold it in memory indefinitely. The plug on cyfr (Elixir)
    // will re-prompt on next page load — same for Porta on next `checkAuth`.
    set({ claimGate: emptyClaimGate });
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
      registryAuthenticated: false,
      personalSlug: null,
      memberships: [],
      claimGate: emptyClaimGate,
      loginPending: false,
      userCode: null,
      verificationUri: null,
      loginWarning: null,
    });
  },
}));

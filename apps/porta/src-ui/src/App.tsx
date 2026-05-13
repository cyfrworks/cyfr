import { useEffect, useRef, useState } from "react";
import { Routes, Route, Navigate } from "react-router-dom";
import { useConnectionStore } from "./state/connection-store";
import { useAuthStore } from "./state/auth-store";
import { useOverlayStore } from "./state/overlay-store";
import { useProjectStore } from "./state/project-store";
import LoginPage from "./pages/LoginPage";
import ClaimNamespacePage from "./pages/ClaimNamespacePage";
import LegalAcceptPage from "./pages/LegalAcceptPage";
import AppShell from "./layouts/AppShell";
import SchedulesPage from "./pages/SchedulesPage";
import ComponentsPage from "./pages/ComponentsPage";
import McpServersPage from "./pages/McpServersPage";
import SettingsPage from "./pages/SettingsPage";
import TincturesPage from "./pages/TincturesPage";
import * as cyfrMcp from "./api/cyfr-mcp";

/**
 * Deep-link `/ask` now maps to "open the overlay to full." It redirects to
 * the Apps page underneath so the user lands on a real view when they close.
 */
function AskRedirect() {
  const open = useOverlayStore((s) => s.open);
  const focusInput = useOverlayStore((s) => s.focusInput);
  useEffect(() => {
    open("full");
    focusInput();
  }, [open, focusInput]);
  return <Navigate to="/tinctures" replace />;
}

export default function App() {
  const getMcpClient = useConnectionStore((s) => s.getMcpClient);
  const mode = useConnectionStore((s) => s.mode);
  const authenticated = useAuthStore((s) => s.authenticated);
  const claimNeeded = useAuthStore((s) => s.claimGate.needed);
  const legalAcceptNeeded = useAuthStore((s) => s.legalAcceptGate.needed);
  const checkAuth = useAuthStore((s) => s.checkAuth);
  const [authChecked, setAuthChecked] = useState(false);
  const [ready, setReady] = useState(false);
  const [setupStatus, setSetupStatus] = useState("");
  const [showSkip, setShowSkip] = useState(false);

  useEffect(() => {
    useProjectStore.getState().hydrate();
  }, []);

  // Seed the first project from the active connection once setup completes.
  useEffect(() => {
    if (ready) useProjectStore.getState().seedFromConnection();
  }, [ready]);

  // Check the saved session as soon as the app mounts.
  useEffect(() => {
    if (!authChecked) {
      checkAuth().finally(() => setAuthChecked(true));
    }
  }, [authChecked, checkAuth]);

  // After auth passes, register + setup all components
  const setupStarted = useRef(false);
  useEffect(() => {
    if (!ready) setupStarted.current = false;
  }, [ready]);
  useEffect(() => {
    if (authChecked && authenticated && !ready && !setupStarted.current) {
      setupStarted.current = true;

      // Show "Skip" button after 15 seconds
      const skipTimer = setTimeout(() => setShowSkip(true), 15000);

      (async () => {
        // Race setup against a 60-second overall timeout
        const setupTimeout = new Promise<"timeout">((resolve) =>
          setTimeout(() => resolve("timeout"), 60000),
        );

        try {
          const result = await Promise.race([doSetup(), setupTimeout]);
          if (result === "timeout") {
            console.warn("Setup timed out after 60s, proceeding to UI");
          }
        } catch (err) {
          console.error("Setup failed:", err);
        } finally {
          clearTimeout(skipTimer);
          setShowSkip(false);
          setReady(true);
        }
      })();

      async function doSetup() {
        const client = await getMcpClient();

        try {
          // Register components — skip in remote mode (a remote server already
          // manages its own components/ directory).
          if (mode !== "remote") {
            setSetupStatus("Registering components...");
            try {
              await cyfrMcp.registerComponents(client);
            } catch {
              // Non-fatal
            }
          }

          // List all registered components
          setSetupStatus("Setting up components...");
          let components: { component_ref: string; name: string }[] = [];
          try {
            const listResult = await cyfrMcp.listComponents(client);
            components = (listResult.components as typeof components) ?? [];
          } catch {
            // Parse failed — skip setup
          }

          // For each component, check if setup is needed and apply
          for (const comp of components) {
            if (!comp.component_ref) continue;
            try {
              let plan: Record<string, unknown> = {};
              try {
                plan = await cyfrMcp.setupPlan(client, comp.component_ref);
              } catch {
                continue;
              }

              // Skip fully-configured components
              if (plan.ready) continue;

              setSetupStatus(`Setting up ${comp.name}...`);
              const nameRef = comp.component_ref.replace(/:[^:]+$/, "");

              // Apply recommended policies only if no stored policy exists yet
              if (!plan.policy_stored) {
                const recommended = (plan.policy_recommended ?? {}) as Record<string, unknown>;

                for (const [field, value] of Object.entries(recommended)) {
                  if (value == null) continue;
                  const valueStr = typeof value === "string" ? value : JSON.stringify(value);
                  try {
                    await cyfrMcp.updatePolicyField(client, nameRef, field, valueStr);
                  } catch {
                    // Individual field failure is non-fatal
                  }
                }
              }

              // Grant secrets that are set but not yet granted
              const secrets = (plan.secrets ?? []) as { name: string; already_set: boolean; already_granted: boolean }[];
              for (const secret of secrets) {
                if (secret.already_set && !secret.already_granted) {
                  try {
                    await cyfrMcp.grantSecret(client, nameRef, secret.name);
                  } catch {
                    // Non-fatal
                  }
                }
              }
            } catch {
              // Individual setup failure is non-fatal
            }
          }
        } catch {
          // Registration failed — continue anyway
        }

        // Load providers (models) and conversations so they're fresh before UI renders
        try {
          setSetupStatus("Loading providers...");
          const { useProviderStore } = await import("./state/provider-store");
          await useProviderStore.getState().loadAll();
        } catch {
          // Non-fatal
        }

        try {
          const { useConversationStore } = await import("./state/conversation-store");
          await useConversationStore.getState().loadConversations();
        } catch {
          // Non-fatal
        }
      }
    }
  }, [authChecked, authenticated, ready]);

  // Checking saved session
  if (!authChecked) {
    return (
      <div className="flex h-full items-center justify-center bg-surface-base">
        <img src="/logo.png" alt="CYFR" className="h-20 w-20 object-contain opacity-50" />
      </div>
    );
  }

  if (!authenticated) {
    return <LoginPage />;
  }

  // Legal-acceptance interstitial takes precedence over the claim gate —
  // cyfr.run requires acceptance of the current bundled policy_version
  // before any namespace claim, so we route the user through the
  // clickwrap before re-prompting for the slug.
  if (legalAcceptNeeded) {
    return <LegalAcceptPage />;
  }

  // Claim-gate — the user has a valid Sanctum session but cyfr.run reports
  // no personal namespace claimed. Block the rest of the UI until the
  // claim succeeds OR the user bails out via "Skip". Mirrors the server-side
  // `require_personal_namespace` plug; implemented here in the render tree
  // because A.Q.U.A. is a SPA with no per-route server pipeline.
  if (claimNeeded) {
    return <ClaimNamespacePage />;
  }

  // Registering + setting up components
  if (!ready) {
    return (
      <div className="flex h-full flex-col items-center justify-center bg-surface-base">
        <img src="/logo.png" alt="CYFR" className="h-20 w-20 object-contain" />
        <div className="mt-4 flex items-center gap-2">
          <svg className="h-4 w-4 animate-spin text-accent-primary" fill="none" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
          </svg>
          <span className="text-sm text-text-secondary">{setupStatus || "Preparing..."}</span>
        </div>
        {showSkip && (
          <button
            onClick={() => setReady(true)}
            className="mt-6 text-sm text-text-muted hover:text-text-secondary underline"
          >
            Skip and continue
          </button>
        )}
      </div>
    );
  }

  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<Navigate to="/tinctures" replace />} />
        {/* /ask is kept for backwards-compat and deep-linking; it opens the
            AQUA overlay to full and lands the user on the Apps page. */}
        <Route path="/ask" element={<AskRedirect />} />
        <Route path="/schedules" element={<SchedulesPage />} />
        <Route path="/components" element={<ComponentsPage />} />
        <Route path="/tinctures" element={<TincturesPage />} />
        <Route path="/mcp-servers" element={<McpServersPage />} />
        <Route path="/settings" element={<SettingsPage />} />
        {/* Redirects from old routes */}
        <Route path="/tasks" element={<Navigate to="/schedules" replace />} />
        <Route path="/integrations" element={<Navigate to="/components" replace />} />
        <Route path="/activity" element={<Navigate to="/mcp-servers" replace />} />
      </Route>
      <Route path="*" element={<Navigate to="/tinctures" replace />} />
    </Routes>
  );
}

import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Routes, Route, Navigate } from "react-router-dom";
import { useConnectionStore } from "./state/connection-store";
import { useAuthStore } from "./state/auth-store";
import BootPage from "./pages/BootPage";
import UpdatePage from "./pages/UpdatePage";
import LoginPage from "./pages/LoginPage";
import AppShell from "./layouts/AppShell";
import TasksPage from "./pages/TasksPage";
import ComponentsPage from "./pages/ComponentsPage";
import McpServersPage from "./pages/McpServersPage";
import SettingsPage from "./pages/SettingsPage";

interface CyfrResult {
  stdout: string;
  stderr: string;
  success: boolean;
  code: number;
}

export default function App() {
  // If opened with ?booted=1 (from transition_to_main), skip boot screen
  const [skipBoot] = useState(
    () => new URLSearchParams(window.location.search).has("booted"),
  );
  const bootComplete = useConnectionStore((s) => s.bootComplete);
  const setBootComplete = useConnectionStore((s) => s.setBootComplete);
  const updating = useConnectionStore((s) => s.updating);
  const updateInfo = useConnectionStore((s) => s.updateInfo);
  const authenticated = useAuthStore((s) => s.authenticated);
  const checkAuth = useAuthStore((s) => s.checkAuth);
  const [authChecked, setAuthChecked] = useState(false);
  const [ready, setReady] = useState(false);
  const [setupStatus, setSetupStatus] = useState("");

  // If we came from the boot window via transition_to_main, mark boot as done
  useEffect(() => {
    if (skipBoot && !bootComplete) {
      setBootComplete(true);
    }
  }, [skipBoot, bootComplete, setBootComplete]);

  // Check auth once boot completes
  useEffect(() => {
    if ((bootComplete || skipBoot) && !authChecked) {
      checkAuth().finally(() => setAuthChecked(true));
    }
  }, [bootComplete, skipBoot, authChecked, checkAuth]);

  // After auth passes, register + setup all components
  const setupStarted = useRef(false);
  useEffect(() => {
    if (!ready) setupStarted.current = false;
  }, [ready]);
  useEffect(() => {
    if (authChecked && authenticated && !ready && !setupStarted.current) {
      setupStarted.current = true;
      (async () => {
        try {
          // Step 0: Ensure Porta MCP gateway is registered with CYFR
          try {
            const mcpList = await invoke<CyfrResult>("cyfr_command", {
              args: ["mcp", "list"],
            });
            const servers = JSON.parse(mcpList.stdout) as Record<string, unknown>;
            const serverList = (servers.servers ?? []) as Record<string, unknown>[];
            const hasGateway = serverList.some((s) => s.name === "porta-gateway");
            if (!hasGateway) {
              setSetupStatus("Connecting tool providers...");
              await invoke<CyfrResult>("cyfr_command", {
                args: [
                  "mcp",
                  "add",
                  "porta-gateway",
                  '{"url":"http://host.docker.internal:9500/mcp"}',
                ],
              });
            }
          } catch {
            // Non-fatal — gateway may already be registered
          }

          // Step 1: Register components
          setSetupStatus("Registering components...");
          await invoke<CyfrResult>("cyfr_command", { args: ["register"] });

          // Step 2: List all registered components
          setSetupStatus("Setting up components...");
          const listResult = await invoke<CyfrResult>("cyfr_command", {
            args: ["list"],
          });

          let components: { component_ref: string; name: string }[] = [];
          try {
            const parsed = JSON.parse(listResult.stdout) as Record<string, unknown>;
            components = (parsed.components as typeof components) ?? [];
          } catch {
            // Parse failed — skip setup
          }

          // Step 3: For each component, check if setup is needed and apply
          for (const comp of components) {
            if (!comp.component_ref) continue;
            try {
              const planResult = await invoke<CyfrResult>("cyfr_command", {
                args: ["setup", comp.component_ref],
              });

              let plan: Record<string, unknown> = {};
              try {
                plan = JSON.parse(planResult.stdout) as Record<string, unknown>;
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
                    await invoke<CyfrResult>("cyfr_command", {
                      args: ["policy", "set", nameRef, field, valueStr],
                    });
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
                    await invoke<CyfrResult>("cyfr_command", {
                      args: ["secret", "grant", nameRef, secret.name],
                    });
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

        // Restore saved model preferences
        try {
          const prefs = await invoke<Record<string, string> | null>("load_prefs");
          if (prefs?.provider) {
            const { useAgentStore } = await import("./state/agent-store");
            useAgentStore.setState({
              provider: prefs.provider,
              model: prefs.model ?? "",
              catalystRef: prefs.catalyst_ref ?? `catalyst:moonmoon69.${prefs.provider}:1.0.0`,
            });
          }
        } catch {
          // No prefs yet
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

        setReady(true);
      })();
    }
  }, [authChecked, authenticated, ready]);

  // Full-screen update flow — blocks all interaction while server is down
  if (updating && updateInfo) {
    return (
      <UpdatePage
        info={updateInfo}
        onComplete={() => setReady(false)}
      />
    );
  }

  if (!bootComplete && !skipBoot) {
    return <BootPage />;
  }

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
      </div>
    );
  }

  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route index element={<Navigate to="/ask" replace />} />
        {/* AskPage is always mounted in AppShell — route is just for nav highlighting */}
        <Route path="/ask" element={null} />
        <Route path="/tasks" element={<TasksPage />} />
        <Route path="/components" element={<ComponentsPage />} />
        <Route path="/mcp-servers" element={<McpServersPage />} />
        <Route path="/settings" element={<SettingsPage />} />
        {/* Redirects from old routes */}
        <Route path="/integrations" element={<Navigate to="/components" replace />} />
        <Route path="/activity" element={<Navigate to="/mcp-servers" replace />} />
      </Route>
      <Route path="*" element={<Navigate to="/ask" replace />} />
    </Routes>
  );
}

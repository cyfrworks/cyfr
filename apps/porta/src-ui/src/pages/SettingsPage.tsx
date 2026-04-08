import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAuthStore } from "../state/auth-store";
import { useConnectionStore } from "../state/connection-store";

export default function SettingsPage() {
  return (
    <div className="flex-1 overflow-y-auto">
      <div className="mx-auto max-w-2xl px-6 py-8">
        <h1 className="text-xl font-semibold text-text-primary">Settings</h1>

        <AccountSection />
        <ConnectionSection />
      </div>
    </div>
  );
}

function AccountSection() {
  const { userName, userEmail, logout } = useAuthStore();

  return (
    <section className="mt-8">
      <h2 className="text-sm font-medium text-text-primary">Account</h2>
      <div className="mt-3 flex items-center justify-between rounded-lg border border-border-default bg-surface-raised px-4 py-3">
        <div>
          <div className="text-sm text-text-primary">
            {userEmail ?? userName ?? "Logged in"}
          </div>
          {userName && userEmail && (
            <div className="text-xs text-text-muted">{userName}</div>
          )}
        </div>
        <button
          onClick={logout}
          className="text-xs text-text-muted hover:text-status-error"
        >
          Log out
        </button>
      </div>
    </section>
  );
}

function ConnectionSection() {
  const mode = useConnectionStore((s) => s.mode);
  const cyfrUrl = useConnectionStore((s) => s.cyfrUrl);
  const hasApiKey = useConnectionStore((s) => s.hasApiKey);
  const fetchMode = useConnectionStore((s) => s.fetchMode);
  const resetMcpClient = useConnectionStore((s) => s.resetMcpClient);
  const [switching, setSwitching] = useState(false);

  useEffect(() => {
    void fetchMode();
  }, [fetchMode]);

  const modeLabel: Record<string, string> = {
    remote: "Remote",
    "local-attached": "Local — Auto-attach",
    "local-managed": "Local — Managed",
  };

  async function handleSwitchInstance() {
    if (
      !confirm(
        "Switch to a different CYFR instance? Porta will restart to the setup wizard.",
      )
    ) {
      return;
    }
    setSwitching(true);
    try {
      // Clear the mode field from porta.json so the wizard appears on next boot.
      const json = await invoke<string>("get_config_json");
      const cfg = JSON.parse(json) as Record<string, unknown>;
      delete cfg.mode;
      delete cfg.apiKey;
      await invoke("save_config_json", { json: JSON.stringify(cfg, null, 2) });
      resetMcpClient();
      // Reset the BOOT_STARTED flag so the next BootPage's start_boot
      // can actually run (instead of being a no-op due to a stale flag
      // from the previous boot). Then navigate to the unbooted URL —
      // BootPage will mount, attach listeners, and call start_boot.
      await invoke("reset_boot_state");
      window.location.href = window.location.pathname;
    } catch (e) {
      alert(`Failed to switch: ${String(e)}`);
      setSwitching(false);
    }
  }

  return (
    <section className="mt-8">
      <h2 className="text-sm font-medium text-text-primary">Connection</h2>
      <div className="mt-3 rounded-lg border border-border-default bg-surface-raised p-4">
        <div className="space-y-2 text-sm">
          <div className="flex justify-between">
            <span className="text-text-muted">Mode</span>
            <span className="text-text-primary">
              {mode ? modeLabel[mode] ?? mode : "Not set"}
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-text-muted">URL</span>
            <span className="font-mono text-xs text-text-primary">{cyfrUrl}</span>
          </div>
          {mode === "remote" && (
            <div className="flex justify-between">
              <span className="text-text-muted">API key</span>
              <span className="text-text-primary">
                {hasApiKey ? "••••••••" : "Not set"}
              </span>
            </div>
          )}
        </div>
        <button
          onClick={handleSwitchInstance}
          disabled={switching}
          className="mt-4 w-full rounded border border-border-default px-3 py-2 text-xs text-text-secondary hover:border-accent-primary hover:text-text-primary disabled:opacity-50"
        >
          {switching ? "Switching..." : "Switch instance"}
        </button>
      </div>
    </section>
  );
}

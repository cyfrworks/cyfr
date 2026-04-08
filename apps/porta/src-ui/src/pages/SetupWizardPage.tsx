import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useConnectionStore } from "../state/connection-store";

type Mode = "remote" | "local-attached" | "local-managed";

/** Reset the cached MCP client so the next caller rebuilds with new credentials. */
function resetSharedClient() {
  useConnectionStore.getState().resetMcpClient();
}

/**
 * First-run setup wizard. Shown when porta.json has no `mode` field.
 * User picks one of three connection modes; on save we re-invoke start_boot.
 */
export default function SetupWizardPage() {
  const [selectedMode, setSelectedMode] = useState<Mode | null>(null);

  return (
    <div className="flex h-full flex-col items-center justify-center bg-surface-base p-4">
      <img src="/logo.png" alt="CYFR" className="mb-2 h-12 w-12 object-contain" />

      <div className="text-base font-semibold text-text-primary">
        Welcome to CYFR
      </div>
      <div className="mb-4 text-xs text-text-secondary">
        How would you like to connect?
      </div>

      {!selectedMode && (
        <div className="flex w-full max-w-md flex-col gap-2">
          <ModeCard
            title="Local — Managed"
            description="Porta runs Cyfr in Docker for you."
            onClick={() => setSelectedMode("local-managed")}
          />
          <ModeCard
            title="Local — Auto-attach"
            description="Connect to Cyfr you already started at localhost:4000."
            onClick={() => setSelectedMode("local-attached")}
          />
          <ModeCard
            title="Remote"
            description="Connect to a Cyfr server hosted on a VPS."
            onClick={() => setSelectedMode("remote")}
          />
        </div>
      )}

      {selectedMode === "remote" && (
        <RemoteForm onBack={() => setSelectedMode(null)} />
      )}
      {selectedMode === "local-attached" && (
        <LocalAttachedForm onBack={() => setSelectedMode(null)} />
      )}
      {selectedMode === "local-managed" && (
        <LocalManagedForm onBack={() => setSelectedMode(null)} />
      )}
    </div>
  );
}

function ModeCard({
  title,
  description,
  onClick,
}: {
  title: string;
  description: string;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="group flex flex-col items-start rounded-lg border border-border-default bg-surface-raised px-3 py-2 text-left transition-all hover:border-accent-primary hover:bg-surface-overlay"
    >
      <div className="text-xs font-semibold text-text-primary">{title}</div>
      <div className="text-[11px] text-text-secondary">{description}</div>
    </button>
  );
}

function RemoteForm({ onBack }: { onBack: () => void }) {
  const [url, setUrl] = useState("https://");
  const [apiKey, setApiKey] = useState("");
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<string | null>(null);
  const [testError, setTestError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const normalizedUrl = () => url.trim().replace(/\/$/, "");

  async function handleTest() {
    setTesting(true);
    setTestResult(null);
    setTestError(null);
    try {
      const result = await invoke<Record<string, unknown>>(
        "test_remote_connection",
        { url: normalizedUrl(), apiKey: apiKey || null },
      );
      setTestResult(JSON.stringify(result));
    } catch (e: unknown) {
      setTestError(String(e));
    } finally {
      setTesting(false);
    }
  }

  async function handleConnect() {
    if (!url || !apiKey) return;
    setSaving(true);
    try {
      await invoke("save_porta_mode", {
        mode: "remote",
        url: normalizedUrl(),
        apiKey,
      });
      resetSharedClient();
      // Re-trigger boot now that mode is saved
      await invoke("retry_boot");
    } catch (e: unknown) {
      setTestError(String(e));
      setSaving(false);
    }
  }

  return (
    <div className="w-full max-w-md">
      <div className="rounded-lg border border-border-default bg-surface-raised p-6">
        <div className="mb-4 text-sm font-semibold text-text-primary">
          Connect to a remote CYFR server
        </div>

        <label className="mb-1 block text-xs text-text-secondary">URL</label>
        <input
          type="text"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          placeholder="https://cyfr.example.com"
          className="mb-3 w-full rounded border border-border-default bg-surface-base px-3 py-2 text-sm text-text-primary placeholder:text-text-muted focus:border-accent-primary focus:outline-none"
        />

        <label className="mb-1 block text-xs text-text-secondary">API key</label>
        <input
          type="password"
          value={apiKey}
          onChange={(e) => setApiKey(e.target.value)}
          placeholder="cyfr_ak_..."
          className="mb-1 w-full rounded border border-border-default bg-surface-base px-3 py-2 text-sm text-text-primary placeholder:text-text-muted focus:border-accent-primary focus:outline-none"
        />
        <p className="mb-4 text-xs text-text-muted">
          Generate one on your server with{" "}
          <code className="font-mono">cyfr key create --type admin</code>.
          Porta needs broad permissions (component_manage, policy_manage,
          secrets_write) to apply setup plans on your behalf.
        </p>

        {testResult && (
          <div className="mb-3 rounded border border-status-success/50 bg-status-success/10 p-2 text-xs text-status-success">
            Connection OK
          </div>
        )}
        {testError && (
          <div className="mb-3 rounded border border-status-error/50 bg-status-error/10 p-2 text-xs text-status-error">
            {testError}
          </div>
        )}

        <div className="flex gap-2">
          <button
            onClick={handleTest}
            disabled={!url || !apiKey || testing || saving}
            className="flex-1 rounded border border-border-default px-3 py-2 text-xs text-text-secondary hover:border-accent-primary hover:text-text-primary disabled:opacity-50"
          >
            {testing ? "Testing..." : "Test connection"}
          </button>
          <button
            onClick={handleConnect}
            disabled={!url || !apiKey || saving}
            className="flex-1 rounded bg-accent-primary px-3 py-2 text-xs font-medium text-white hover:bg-accent-hover disabled:opacity-50"
          >
            {saving ? "Connecting..." : "Connect"}
          </button>
        </div>
      </div>

      <button
        onClick={onBack}
        className="mt-4 block text-xs text-text-muted hover:text-text-secondary"
      >
        ← Back
      </button>
    </div>
  );
}

function LocalAttachedForm({ onBack }: { onBack: () => void }) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleConnect() {
    setSaving(true);
    setError(null);
    try {
      await invoke("save_porta_mode", {
        mode: "local-attached",
        url: "http://127.0.0.1:4000",
        apiKey: null,
      });
      resetSharedClient();
      await invoke("retry_boot");
    } catch (e: unknown) {
      setError(String(e));
      setSaving(false);
    }
  }

  return (
    <div className="w-full max-w-md">
      <div className="rounded-lg border border-border-default bg-surface-raised p-6">
        <div className="mb-3 text-sm font-semibold text-text-primary">
          Use a local CYFR you already started
        </div>
        <p className="mb-4 text-xs text-text-secondary">
          Porta will connect to <code className="font-mono">localhost:4000</code>{" "}
          without managing Docker. Make sure you've already run{" "}
          <code className="font-mono">cyfr up</code> in your project directory.
        </p>

        {error && (
          <div className="mb-3 rounded border border-status-error/50 bg-status-error/10 p-2 text-xs text-status-error">
            {error}
          </div>
        )}

        <button
          onClick={handleConnect}
          disabled={saving}
          className="w-full rounded bg-accent-primary px-3 py-2 text-xs font-medium text-white hover:bg-accent-hover disabled:opacity-50"
        >
          {saving ? "Connecting..." : "Connect"}
        </button>
      </div>

      <button
        onClick={onBack}
        className="mt-4 block text-xs text-text-muted hover:text-text-secondary"
      >
        ← Back
      </button>
    </div>
  );
}

function LocalManagedForm({ onBack }: { onBack: () => void }) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleConnect() {
    setSaving(true);
    setError(null);
    try {
      await invoke("save_porta_mode", {
        mode: "local-managed",
        url: "http://127.0.0.1:4000",
        apiKey: null,
      });
      resetSharedClient();
      await invoke("retry_boot");
    } catch (e: unknown) {
      setError(String(e));
      setSaving(false);
    }
  }

  return (
    <div className="w-full max-w-md">
      <div className="rounded-lg border border-border-default bg-surface-raised p-6">
        <div className="mb-3 text-sm font-semibold text-text-primary">
          Let Porta manage CYFR for you
        </div>
        <p className="mb-4 text-xs text-text-secondary">
          Porta will install/start Docker, scaffold a project in{" "}
          <code className="font-mono">~/cyfr</code>, and run{" "}
          <code className="font-mono">cyfr up</code> on your behalf. This is the
          default for new users.
        </p>

        {error && (
          <div className="mb-3 rounded border border-status-error/50 bg-status-error/10 p-2 text-xs text-status-error">
            {error}
          </div>
        )}

        <button
          onClick={handleConnect}
          disabled={saving}
          className="w-full rounded bg-accent-primary px-3 py-2 text-xs font-medium text-white hover:bg-accent-hover disabled:opacity-50"
        >
          {saving ? "Setting up..." : "Get started"}
        </button>
      </div>

      <button
        onClick={onBack}
        className="mt-4 block text-xs text-text-muted hover:text-text-secondary"
      >
        ← Back
      </button>
    </div>
  );
}

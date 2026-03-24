import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAuthStore } from "../state/auth-store";
import { useAgentStore } from "../state/agent-store";
import {
  useProviderStore,
  type ProviderInfo,
  type ProviderKey,
} from "../state/provider-store";

interface BackendInfo {
  name: string;
  type: string;
  status: string;
  tool_count: number;
}

export default function SettingsPage() {
  const [configJson, setConfigJson] = useState("");
  const [backends, setBackends] = useState<BackendInfo[]>([]);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<{
    type: "success" | "error";
    text: string;
  } | null>(null);
  const [editorOpen, setEditorOpen] = useState(false);

  const loadData = useCallback(async () => {
    try {
      const [json, backendList] = await Promise.all([
        invoke<string>("get_config_json"),
        invoke<BackendInfo[]>("list_backends"),
      ]);
      setConfigJson(json);
      setBackends(backendList);
    } catch {
      // Tauri commands may not exist yet
    }
  }, []);

  useEffect(() => {
    loadData();
  }, [loadData]);

  const handleSave = async () => {
    try {
      JSON.parse(configJson);
    } catch {
      setMessage({ type: "error", text: "Invalid JSON" });
      return;
    }

    setSaving(true);
    setMessage(null);
    try {
      await invoke("save_config_json", { json: configJson });
      setMessage({ type: "success", text: "Configuration saved" });
      const backendList = await invoke<BackendInfo[]>("list_backends");
      setBackends(backendList);
    } catch (err) {
      setMessage({
        type: "error",
        text: `Save failed: ${err instanceof Error ? err.message : String(err)}`,
      });
    }
    setSaving(false);
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "s") {
      e.preventDefault();
      handleSave();
    }
    if (e.key === "Tab") {
      e.preventDefault();
      const target = e.target as HTMLTextAreaElement;
      const start = target.selectionStart;
      const end = target.selectionEnd;
      const newValue =
        configJson.substring(0, start) + "  " + configJson.substring(end);
      setConfigJson(newValue);
      requestAnimationFrame(() => {
        target.selectionStart = target.selectionEnd = start + 2;
      });
    }
  };

  return (
    <div className="flex-1 overflow-y-auto">
      <div className="mx-auto max-w-2xl px-6 py-8">
        <h1 className="text-xl font-semibold text-text-primary">Settings</h1>

        <AccountSection />
        <ProvidersSection />

        {/* Tool Providers */}
        <section className="mt-10">
          <h2 className="text-sm font-medium text-text-primary">
            Tool Providers
          </h2>
          <p className="mt-1 text-xs text-text-secondary">
            MCP servers that provide tools to your CYFR agent.
          </p>

          <div className="mt-4 space-y-2">
            {backends.length === 0 && (
              <p className="text-xs text-text-muted">
                No tool providers configured
              </p>
            )}
            {backends.map((b) => (
              <div
                key={b.name}
                className="flex items-center justify-between rounded-lg border border-border-default bg-surface-raised px-4 py-3"
              >
                <div className="flex items-center gap-3">
                  <span
                    className={`h-2 w-2 rounded-full ${
                      b.status === "ready"
                        ? "bg-status-success"
                        : b.status === "error"
                          ? "bg-status-error"
                          : "bg-text-muted"
                    }`}
                  />
                  <div>
                    <div className="text-sm text-text-primary">{b.name}</div>
                    <div className="text-xs text-text-muted">
                      {b.type} &middot; {b.tool_count} tool
                      {b.tool_count !== 1 ? "s" : ""}
                    </div>
                  </div>
                </div>
              </div>
            ))}
          </div>

          <div className="mt-4">
            <button
              onClick={() => setEditorOpen(!editorOpen)}
              className="text-xs text-accent-primary hover:text-accent-hover"
            >
              {editorOpen ? "Hide" : "Edit"} Configuration
            </button>

            {editorOpen && (
              <div className="mt-2">
                <textarea
                  value={configJson}
                  onChange={(e) => setConfigJson(e.target.value)}
                  onKeyDown={handleKeyDown}
                  spellCheck={false}
                  className="h-64 w-full rounded-lg border border-border-default bg-surface-raised p-3 font-mono text-xs text-text-primary outline-none focus:border-border-focus"
                />
                <div className="mt-2 flex items-center gap-3">
                  <button
                    onClick={handleSave}
                    disabled={saving}
                    className="btn-primary text-xs"
                  >
                    {saving ? "Saving..." : "Save"}
                  </button>
                  {message && (
                    <span
                      className={`text-xs ${
                        message.type === "success"
                          ? "text-status-success"
                          : "text-status-error"
                      }`}
                    >
                      {message.text}
                    </span>
                  )}
                </div>
              </div>
            )}
          </div>
        </section>
      </div>
    </div>
  );
}

// --- Account ---

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

// --- Providers ---

function ProvidersSection() {
  const { providers, loading, registering, loadAll } = useProviderStore();
  const [expanded, setExpanded] = useState<ProviderKey | null>(null);

  useEffect(() => {
    loadAll();
  }, [loadAll]);

  return (
    <section className="mt-10">
      <h2 className="text-sm font-medium text-text-primary">Providers</h2>
      <p className="mt-1 text-xs text-text-secondary">
        AI model providers and API keys for AQUA.
      </p>

      {loading && (
        <div className="mt-4 flex items-center gap-2 text-xs text-text-muted">
          {registering
            ? "Registering components..."
            : "Loading provider status..."}
        </div>
      )}

      <div className="mt-4 space-y-2">
        {providers.map((p) => (
          <ProviderCard
            key={p.key}
            provider={p}
            expanded={expanded === p.key}
            onToggle={() =>
              setExpanded(expanded === p.key ? null : p.key)
            }
          />
        ))}
      </div>
    </section>
  );
}

function ProviderCard({
  provider,
  expanded,
  onToggle,
}: {
  provider: ProviderInfo;
  expanded: boolean;
  onToggle: () => void;
}) {
  const agentProvider = useAgentStore((s) => s.provider);
  const agentModel = useAgentStore((s) => s.model);
  const isSelected = agentProvider === provider.key;

  return (
    <div className="overflow-hidden rounded-lg border border-border-default bg-surface-raised">
      {/* Header */}
      <button
        onClick={onToggle}
        className="flex w-full items-center gap-3 px-4 py-3 text-left"
      >
        <span
          className={`h-2 w-2 shrink-0 rounded-full ${
            provider.ready ? "bg-status-success" : "bg-text-muted"
          }`}
        />
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="text-sm font-medium text-text-primary">
              {provider.label}
            </span>
            {isSelected && (
              <span className="rounded bg-accent-primary/15 px-1.5 py-0.5 text-[10px] font-medium text-accent-primary">
                Default
              </span>
            )}
          </div>
          {provider.ready && isSelected && agentModel && (
            <div className="truncate text-xs text-text-muted">{agentModel}</div>
          )}
        </div>
        <span
          className={`shrink-0 text-xs ${
            provider.ready ? "text-status-success" : "text-text-muted"
          }`}
        >
          {provider.loading
            ? "Setting up..."
            : provider.ready
              ? "Ready"
              : "Setup needed"}
        </span>
        <ChevronIcon expanded={expanded} />
      </button>

      {/* Expanded content */}
      {expanded && (
        <div className="border-t border-border-default px-4 py-3">
          {provider.ready ? (
            <ReadyProviderView provider={provider} />
          ) : (
            <SetupProviderView provider={provider} />
          )}
        </div>
      )}
    </div>
  );
}

function SetupProviderView({ provider }: { provider: ProviderInfo }) {
  const [apiKey, setApiKey] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const setupProvider = useProviderStore((s) => s.setupProvider);

  const handleSave = async () => {
    if (!apiKey.trim()) return;
    setSaving(true);
    setError(null);
    try {
      await setupProvider(provider.key, apiKey.trim());
      setApiKey("");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
    setSaving(false);
  };

  return (
    <div>
      <label className="mb-1.5 block text-xs text-text-muted">
        API Key
      </label>
      <div className="flex gap-2">
        <input
          type="password"
          value={apiKey}
          onChange={(e) => setApiKey(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") handleSave();
          }}
          placeholder={provider.secretName}
          className="flex-1 rounded-lg border border-border-default bg-surface-base px-3 py-2 font-mono text-xs text-text-primary placeholder-text-muted outline-none focus:border-border-focus"
        />
        <button
          onClick={handleSave}
          disabled={!apiKey.trim() || saving}
          className="btn-primary text-xs"
        >
          {saving ? "Saving..." : "Save"}
        </button>
      </div>
      <a
        href={provider.keyUrl}
        target="_blank"
        rel="noopener noreferrer"
        className="mt-2 inline-block text-xs text-accent-primary hover:text-accent-hover"
        onClick={(e) => {
          e.preventDefault();
          invoke("open_url", { url: provider.keyUrl });
        }}
      >
        Get your API key &rarr;
      </a>
      {(error ?? provider.error) && (
        <p className="mt-2 text-xs text-status-error">
          {error ?? provider.error}
        </p>
      )}
    </div>
  );
}

function ReadyProviderView({ provider }: { provider: ProviderInfo }) {
  const [showChange, setShowChange] = useState(false);
  const [newKey, setNewKey] = useState("");
  const [saving, setSaving] = useState(false);
  const setupProvider = useProviderStore((s) => s.setupProvider);
  const removeProvider = useProviderStore((s) => s.removeProvider);
  const selectModel = useProviderStore((s) => s.selectModel);
  const agentProvider = useAgentStore((s) => s.provider);
  const agentModel = useAgentStore((s) => s.model);

  const handleChange = async () => {
    if (!newKey.trim()) return;
    setSaving(true);
    await setupProvider(provider.key, newKey.trim());
    setNewKey("");
    setShowChange(false);
    setSaving(false);
  };

  return (
    <div>
      {/* API Key status */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="text-xs text-text-muted">API Key:</span>
          <span className="font-mono text-xs text-text-secondary">
            ••••••••
          </span>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setShowChange(!showChange)}
            className="text-xs text-text-muted hover:text-text-secondary"
          >
            Change
          </button>
          <button
            onClick={() => removeProvider(provider.key)}
            className="text-xs text-text-muted hover:text-status-error"
          >
            Remove
          </button>
        </div>
      </div>

      {showChange && (
        <div className="mt-2 flex gap-2">
          <input
            type="password"
            value={newKey}
            onChange={(e) => setNewKey(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") handleChange();
            }}
            placeholder="New API key"
            className="flex-1 rounded-lg border border-border-default bg-surface-base px-3 py-2 font-mono text-xs text-text-primary placeholder-text-muted outline-none focus:border-border-focus"
          />
          <button
            onClick={handleChange}
            disabled={!newKey.trim() || saving}
            className="btn-primary text-xs"
          >
            {saving ? "..." : "Update"}
          </button>
        </div>
      )}

      {/* Models */}
      {provider.models.length > 0 && (
        <div className="mt-3">
          <span className="text-xs text-text-muted">Models</span>
          <div className="mt-1.5 flex flex-wrap gap-1.5">
            {provider.models.map((m) => {
              const isActive =
                agentProvider === provider.key && agentModel === m;
              return (
                <button
                  key={m}
                  onClick={() => selectModel(provider.key, m)}
                  className={`rounded-md border px-2.5 py-1 text-xs transition-colors ${
                    isActive
                      ? "border-accent-primary bg-accent-primary/15 text-accent-primary"
                      : "border-border-default text-text-secondary hover:border-border-focus hover:text-text-primary"
                  }`}
                >
                  {m}
                </button>
              );
            })}
          </div>
        </div>
      )}

      {provider.error && (
        <p className="mt-2 text-xs text-status-error">{provider.error}</p>
      )}
    </div>
  );
}

// --- Icons ---

function ChevronIcon({ expanded }: { expanded: boolean }) {
  return (
    <svg
      className={`h-4 w-4 shrink-0 text-text-muted transition-transform ${
        expanded ? "rotate-180" : ""
      }`}
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={2}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M19.5 8.25l-7.5 7.5-7.5-7.5"
      />
    </svg>
  );
}

import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";

interface BackendInfo {
  name: string;
  type: string;
  status: string;
  tool_count: number;
}

const CHROME_DEVTOOLS_ID = "chrome-devtools";
const CHROME_DEVTOOLS_CONFIG = {
  command: "npx",
  args: [
    "-y",
    "chrome-devtools-mcp@latest",
    "--no-usage-statistics",
    "--browser-url=http://127.0.0.1:9222",
  ],
  enabled: true,
};

export default function McpServersPage() {
  const [configJson, setConfigJson] = useState("");
  const [backends, setBackends] = useState<BackendInfo[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<{
    type: "success" | "error";
    text: string;
  } | null>(null);
  const [editorOpen, setEditorOpen] = useState(false);
  const [removing, setRemoving] = useState<string | null>(null);
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [launching, setLaunching] = useState(false);
  const [launchError, setLaunchError] = useState("");
  const [chromeUp, setChromeUp] = useState(false);

  const loadData = useCallback(async () => {
    setLoading(true);
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
    setLoading(false);
  }, []);

  const checkPort = useCallback(async () => {
    try {
      const up = await invoke<boolean>("check_debug_port");
      setChromeUp(up);
    } catch {
      setChromeUp(false);
    }
  }, []);

  useEffect(() => {
    loadData();
    checkPort();
  }, [loadData, checkPort]);

  // Poll port 9222 every 5s while page is open
  useEffect(() => {
    const id = setInterval(checkPort, 5000);
    return () => clearInterval(id);
  }, [checkPort]);

  // Check if chrome-devtools is already in config
  const hasChromeDevtools = (() => {
    try {
      const cfg = JSON.parse(configJson) as { mcpServers?: Record<string, unknown> };
      return !!cfg.mcpServers?.[CHROME_DEVTOOLS_ID];
    } catch {
      return false;
    }
  })();

  const handleAddChrome = async () => {
    setAdding(true);
    setMessage(null);
    try {
      let cfg: { mcpServers?: Record<string, unknown> };
      try {
        cfg = JSON.parse(configJson) as { mcpServers?: Record<string, unknown> };
      } catch {
        cfg = {};
      }
      if (!cfg.mcpServers) cfg.mcpServers = {};
      cfg.mcpServers[CHROME_DEVTOOLS_ID] = CHROME_DEVTOOLS_CONFIG;
      const newJson = JSON.stringify(cfg, null, 2);
      await invoke("save_config_json", { json: newJson });
      await loadData();
    } catch (err) {
      setMessage({
        type: "error",
        text: `Failed to add: ${err instanceof Error ? err.message : String(err)}`,
      });
    }
    setAdding(false);
  };

  const handleRemoveServer = async (name: string) => {
    setRemoving(name);
    try {
      let cfg: { mcpServers?: Record<string, unknown> };
      try {
        cfg = JSON.parse(configJson) as { mcpServers?: Record<string, unknown> };
      } catch {
        cfg = {};
      }
      if (cfg.mcpServers) {
        delete cfg.mcpServers[name];
      }
      const newJson = JSON.stringify(cfg, null, 2);
      await invoke("save_config_json", { json: newJson });
      await loadData();
    } catch (err) {
      setMessage({
        type: "error",
        text: `Remove failed: ${err instanceof Error ? err.message : String(err)}`,
      });
    }
    setRemoving(null);
    setConfirmRemove(null);
  };

  const handleLaunchChrome = async () => {
    setLaunching(true);
    setLaunchError("");
    try {
      await invoke<string>("launch_chrome");
      // Give Chrome a moment to open the debug port, then check
      setTimeout(checkPort, 2000);
    } catch (err) {
      setLaunchError(err instanceof Error ? err.message : String(err));
    }
    setLaunching(false);
  };

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
        <div className="flex items-center gap-2">
          <h1 className="text-xl font-semibold text-text-primary">
            MCP Servers
          </h1>
          {loading && (
            <svg className="h-4 w-4 animate-spin text-text-muted" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
            </svg>
          )}
        </div>
        <p className="mt-1 text-sm text-text-secondary">
          Tool providers that extend your CYFR agent.
        </p>

        {/* Active Servers */}
        <section className="mt-8">
          <h2 className="text-sm font-medium text-text-primary">Active Servers</h2>
          <div className="mt-2 space-y-2">
            {!loading && backends.length === 0 && (
              <p className="text-xs text-text-muted">
                No MCP servers configured
              </p>
            )}
            {backends.map((b) => (
              <div
                key={b.name}
                className="rounded-lg border border-border-default bg-surface-raised px-4 py-3"
              >
                <div className="flex items-center justify-between">
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
                  <div className="flex items-center gap-3">
                    {b.name === CHROME_DEVTOOLS_ID && (
                      chromeUp ? (
                        <span className="text-xs text-status-success">Chrome running</span>
                      ) : launching ? (
                        <span className="flex items-center gap-1.5 text-xs text-text-muted">
                          <svg className="h-3 w-3 animate-spin" fill="none" viewBox="0 0 24 24">
                            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                          </svg>
                          Launching...
                        </span>
                      ) : (
                        <button
                          onClick={handleLaunchChrome}
                          className="text-xs text-accent-primary hover:text-accent-hover"
                        >
                          Launch Chrome
                        </button>
                      )
                    )}
                    {removing === b.name ? (
                      <span className="text-xs text-text-muted">Removing...</span>
                    ) : confirmRemove === b.name ? (
                      <span className="flex items-center gap-1.5 text-xs">
                        <span className="text-text-muted">Remove?</span>
                        <button
                          onClick={() => handleRemoveServer(b.name)}
                          className="text-status-error hover:underline"
                        >
                          Yes
                        </button>
                        <button
                          onClick={() => setConfirmRemove(null)}
                          className="text-text-muted hover:text-text-secondary"
                        >
                          No
                        </button>
                      </span>
                    ) : (
                      <button
                        onClick={() => setConfirmRemove(b.name)}
                        className="text-xs text-text-muted hover:text-status-error"
                      >
                        Remove
                      </button>
                    )}
                  </div>
                </div>
                {b.name === CHROME_DEVTOOLS_ID && !chromeUp && !launching && (
                  <div className="mt-2 text-xs text-status-warning">
                    Chrome must be running with remote debugging enabled
                  </div>
                )}
                {b.name === CHROME_DEVTOOLS_ID && launchError && (
                  <div className="mt-1 text-xs text-status-error">{launchError}</div>
                )}
              </div>
            ))}
          </div>
        </section>

        {/* Available Presets */}
        {!hasChromeDevtools && (
          <section className="mt-8">
            <h2 className="text-sm font-medium text-text-primary">Available</h2>
            <div className="mt-2 space-y-2">
              <div className="flex items-center justify-between rounded-lg border border-border-default bg-surface-raised px-4 py-3">
                <div className="flex items-center gap-3">
                  <span className="text-base">&#127760;</span>
                  <div>
                    <div className="text-sm text-text-primary">Chrome DevTools</div>
                    <div className="text-xs text-text-muted">
                      Browser automation via Chrome DevTools Protocol
                    </div>
                  </div>
                </div>
                <button
                  onClick={handleAddChrome}
                  disabled={adding}
                  className="text-xs text-accent-primary hover:text-accent-hover disabled:opacity-50"
                >
                  {adding ? "Adding..." : "Add"}
                </button>
              </div>
            </div>
          </section>
        )}

        {/* Configuration Editor */}
        <div className="mt-8">
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
      </div>
    </div>
  );
}

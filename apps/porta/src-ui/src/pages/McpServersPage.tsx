import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";

interface BackendInfo {
  name: string;
  type: string;
  status: string;
  tool_count: number;
}

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

        <section className="mt-8">
          <div className="space-y-2">
            {!loading && backends.length === 0 && (
              <p className="text-xs text-text-muted">
                No MCP servers configured
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

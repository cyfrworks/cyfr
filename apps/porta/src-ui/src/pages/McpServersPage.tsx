import { useState, useEffect, useCallback } from "react";
import { useConnectionStore } from "../state/connection-store";
import { PageLayout } from "../components/common/PageLayout";

/**
 * External MCP servers registered with the Cyfr instance.
 *
 * This is a thin UI over Cyfr's `mcp_servers` MCP tool (Emissary's
 * ExternalProvider) — list / create / delete / test / refresh / enable /
 * disable. Tools discovered from a server show up to AQUA namespaced as
 * `<name>:<tool>`.
 *
 * One preset: "Chrome DevTools (neko)" — registers chrome-devtools-mcp, which
 * runs in the `mcp-bridge` sidecar of the standard docker-compose stack, so
 * AQUA agents get `chrome:*` tools. The URL `http://mcp-bridge:8001/mcp` is
 * resolved by Cyfr inside the compose network (the browser never connects to
 * it directly), so this works as-is.
 */

const CHROME_PRESET = { name: "chrome", url: "http://mcp-bridge:8001/mcp", timeout_ms: 60000 };

interface ServerEntry {
  name: string;
  url: string;
  enabled: boolean;
  /** "ready" | "error" | "unknown" | … — best-effort, server-reported. */
  status?: string;
  tool_count?: number;
  error?: string | null;
}

function statusColor(status: string | undefined): string {
  if (status === "ready" || status === "connected") return "bg-status-success";
  if (status === "error") return "bg-status-error";
  if (status === "disabled") return "bg-status-warning";
  return "bg-text-muted";
}

const Spinner = ({ className = "h-3 w-3" }: { className?: string }) => (
  <svg className={`animate-spin ${className}`} fill="none" viewBox="0 0 24 24">
    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
  </svg>
);

function coerceServers(raw: unknown): ServerEntry[] {
  const list = Array.isArray(raw)
    ? raw
    : Array.isArray((raw as { servers?: unknown[] })?.servers)
      ? (raw as { servers: unknown[] }).servers
      : [];
  return list.map((s) => {
    const o = (s ?? {}) as Record<string, unknown>;
    const cfg = (o.config ?? {}) as Record<string, unknown>;
    return {
      name: String(o.name ?? ""),
      url: String(o.url ?? cfg.url ?? ""),
      enabled: o.enabled !== false,
      status: typeof o.status === "string" ? o.status : undefined,
      tool_count:
        typeof o.tool_count === "number"
          ? o.tool_count
          : typeof o.tools_count === "number"
            ? o.tools_count
            : undefined,
      error: (o.error as string | null | undefined) ?? null,
    };
  });
}

export default function McpServersPage() {
  const getMcpClient = useConnectionStore((s) => s.getMcpClient);

  const [servers, setServers] = useState<ServerEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState<{ type: "success" | "error"; text: string } | null>(null);

  const [adding, setAdding] = useState(false);
  const [newName, setNewName] = useState("");
  const [newUrl, setNewUrl] = useState("");
  const [newHeaders, setNewHeaders] = useState("");
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null);

  const call = useCallback(
    async (action: string, args: Record<string, unknown> = {}) => {
      const client = await getMcpClient();
      return client.callTool("mcp_servers", { action, ...args });
    },
    [getMcpClient],
  );

  const loadData = useCallback(async () => {
    setLoading(true);
    try {
      const result = await call("list");
      setServers(coerceServers(result.servers ?? result));
    } catch (err) {
      setMessage({ type: "error", text: `Failed to list servers: ${msg(err)}` });
    }
    setLoading(false);
  }, [call]);

  useEffect(() => {
    void loadData();
  }, [loadData]);

  async function run(label: string, fn: () => Promise<unknown>, key: string) {
    setBusy(key);
    setMessage(null);
    try {
      await fn();
      await loadData();
    } catch (err) {
      setMessage({ type: "error", text: `${label} failed: ${msg(err)}` });
    }
    setBusy(null);
    setConfirmRemove(null);
  }

  async function handleAdd() {
    const name = newName.trim();
    const url = newUrl.trim();
    if (!name || !url) {
      setMessage({ type: "error", text: "Name and URL are required" });
      return;
    }
    let headers: Record<string, string> | undefined;
    if (newHeaders.trim()) {
      try {
        headers = JSON.parse(newHeaders) as Record<string, string>;
      } catch {
        setMessage({ type: "error", text: "Headers must be valid JSON (or blank)" });
        return;
      }
    }
    await run(
      "Add",
      () => call("create", { name, config: { url, ...(headers ? { headers } : {}) } }),
      "add",
    );
    setAdding(false);
    setNewName("");
    setNewUrl("");
    setNewHeaders("");
  }

  return (
    <PageLayout
      title="MCP Servers"
      subtitle="External tool providers registered with this CYFR instance."
      actions={loading ? <Spinner className="h-4 w-4 text-text-muted" /> : undefined}
    >
      {message && (
        <div
          className={`mt-4 rounded-lg px-3 py-2 text-xs ${
            message.type === "success"
              ? "bg-status-success/10 text-status-success"
              : "bg-status-error/10 text-status-error"
          }`}
        >
          {message.text}
        </div>
      )}

      <section className="mt-8">
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-medium text-text-primary">Servers</h2>
          <button
            onClick={() => void loadData()}
            className="text-xs text-accent-primary hover:text-accent-hover"
          >
            Reload
          </button>
        </div>

        <div className="mt-2 space-y-2">
          {!loading && servers.length === 0 && (
            <p className="text-xs text-text-muted">No external MCP servers registered.</p>
          )}
          {servers.map((s) => (
            <div
              key={s.name}
              className="rounded-lg border border-border-default bg-surface-raised px-4 py-3"
            >
              <div className="flex items-center justify-between gap-3">
                <div className="flex min-w-0 items-center gap-3">
                  <span className={`h-2 w-2 shrink-0 rounded-full ${statusColor(s.enabled ? s.status : "disabled")}`} />
                  <div className="min-w-0">
                    <div className="text-sm text-text-primary">{s.name}</div>
                    <div className="truncate text-xs text-text-muted">
                      {s.url}
                      {typeof s.tool_count === "number" && ` · ${s.tool_count} tool${s.tool_count === 1 ? "" : "s"}`}
                      {s.status && ` · ${s.status}`}
                      {!s.enabled && " · disabled"}
                      {s.error && ` · ${s.error}`}
                    </div>
                  </div>
                </div>
                <div className="flex shrink-0 items-center gap-3 text-xs">
                  {busy === `test:${s.name}` ? (
                    <span className="flex items-center gap-1.5 text-text-muted"><Spinner /> Testing…</span>
                  ) : (
                    <button
                      onClick={() => void run("Test", () => call("test", { name: s.name }), `test:${s.name}`)}
                      className="text-accent-primary hover:text-accent-hover"
                    >
                      Test
                    </button>
                  )}
                  <button
                    onClick={() => void run("Refresh", () => call("refresh", { name: s.name }), `refresh:${s.name}`)}
                    className="text-accent-primary hover:text-accent-hover"
                  >
                    Refresh
                  </button>
                  <button
                    onClick={() =>
                      void run(
                        s.enabled ? "Disable" : "Enable",
                        () => call(s.enabled ? "disable" : "enable", { name: s.name }),
                        `toggle:${s.name}`,
                      )
                    }
                    className="text-text-secondary hover:text-text-primary"
                  >
                    {s.enabled ? "Disable" : "Enable"}
                  </button>
                  {busy === `del:${s.name}` ? (
                    <span className="text-text-muted">Removing…</span>
                  ) : confirmRemove === s.name ? (
                    <span className="flex items-center gap-1.5">
                      <span className="text-text-muted">Remove?</span>
                      <button
                        onClick={() => void run("Remove", () => call("delete", { name: s.name }), `del:${s.name}`)}
                        className="text-status-error hover:underline"
                      >
                        Yes
                      </button>
                      <button onClick={() => setConfirmRemove(null)} className="text-text-muted hover:text-text-secondary">
                        No
                      </button>
                    </span>
                  ) : (
                    <button onClick={() => setConfirmRemove(s.name)} className="text-text-muted hover:text-status-error">
                      Remove
                    </button>
                  )}
                </div>
              </div>
            </div>
          ))}
        </div>
      </section>

      <section className="mt-8">
        {!adding ? (
          <div className="flex items-center gap-4">
            <button
              onClick={() => setAdding(true)}
              className="text-xs text-accent-primary hover:text-accent-hover"
            >
              Add server…
            </button>
            {!servers.some((s) => s.name === CHROME_PRESET.name) && (
              <button
                onClick={() =>
                  void run(
                    "Add Chrome DevTools",
                    () =>
                      call("create", {
                        name: CHROME_PRESET.name,
                        config: { url: CHROME_PRESET.url, timeout_ms: CHROME_PRESET.timeout_ms },
                      }),
                    "add",
                  )
                }
                disabled={busy === "add"}
                className="text-xs text-accent-primary hover:text-accent-hover disabled:opacity-50"
                title="Register chrome-devtools-mcp (runs in the mcp-bridge sidecar, drives neko's Chromium)"
              >
                {busy === "add" ? "Adding…" : "+ Chrome DevTools (neko)"}
              </button>
            )}
          </div>
        ) : (
          <div className="space-y-2 rounded-lg border border-border-default bg-surface-raised p-4">
            <input
              autoFocus
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              placeholder="Name (e.g. notion)"
              className="w-full rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary focus:border-accent-primary focus:outline-none"
            />
            <input
              value={newUrl}
              onChange={(e) => setNewUrl(e.target.value)}
              placeholder="MCP endpoint URL (https://…/mcp)"
              className="w-full rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary focus:border-accent-primary focus:outline-none"
            />
            <textarea
              value={newHeaders}
              onChange={(e) => setNewHeaders(e.target.value)}
              placeholder={'Headers JSON (optional), e.g. {"Authorization":"Bearer …"}'}
              spellCheck={false}
              className="h-20 w-full rounded border border-border-default bg-surface-base p-2 font-mono text-xs text-text-primary focus:border-accent-primary focus:outline-none"
            />
            <div className="flex items-center gap-2">
              <button onClick={() => void handleAdd()} disabled={busy === "add"} className="btn-primary text-xs">
                {busy === "add" ? "Adding…" : "Add"}
              </button>
              <button
                onClick={() => {
                  setAdding(false);
                  setNewName("");
                  setNewUrl("");
                  setNewHeaders("");
                }}
                className="text-xs text-text-muted hover:text-text-secondary"
              >
                Cancel
              </button>
            </div>
          </div>
        )}
      </section>
    </PageLayout>
  );
}

function msg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

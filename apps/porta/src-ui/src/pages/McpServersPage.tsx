import { useState, useEffect, useCallback, useMemo } from "react";
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
 * Built-in preset: the local **mcp-bridge** gateway, a sidecar in the docker
 * stack that wraps stdio/npx MCP servers (filesystem, github, …) behind a
 * single HTTP endpoint. Cyfr only sees one external server called `bridge`;
 * the gateway's admin tools (`bridge:add_backend`, `bridge:list_backends`,
 * `bridge:remove_backend`) let you CRUD stdio backends right from this page
 * — see the "Bridge backends" section that appears once the bridge is
 * registered. The URL `http://mcp-bridge:8001/mcp` is resolved by Cyfr inside
 * the compose network (the browser never connects to it directly).
 */

const BRIDGE_PRESET = { name: "bridge", url: "http://mcp-bridge:8001/mcp" };

interface ServerEntry {
  name: string;
  url: string;
  enabled: boolean;
  /** "ready" | "error" | "unknown" | … — best-effort, server-reported. */
  status?: string;
  tool_count?: number;
  error?: string | null;
}

interface BridgeBackend {
  name: string;
  command: string;
  status: string;
  tool_count: number;
  error?: string | null;
}

function statusColor(status: string | undefined): string {
  if (status === "ready" || status === "connected") return "bg-status-success";
  if (status === "error" || status === "crashed") return "bg-status-error";
  if (status === "disabled" || status === "starting") return "bg-status-warning";
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

// The bridge's admin tools return `wrapResult({...})` → `{ content: [{ type:
// "text", text: "<json>" }] }`. Pull the JSON back out, tolerant of bare maps.
function unwrapBridgeResult<T = unknown>(raw: unknown): T | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const content = obj.content;
  if (Array.isArray(content) && content.length > 0) {
    const first = content[0] as Record<string, unknown> | undefined;
    if (first && typeof first.text === "string") {
      try {
        return JSON.parse(first.text) as T;
      } catch {
        return null;
      }
    }
  }
  return raw as T;
}

function coerceBackends(raw: unknown): BridgeBackend[] {
  const obj = unwrapBridgeResult<{ backends?: unknown[] }>(raw);
  const list = Array.isArray(obj?.backends) ? obj!.backends : [];
  return list.map((b) => {
    const o = (b ?? {}) as Record<string, unknown>;
    return {
      name: String(o.name ?? ""),
      command: String(o.command ?? ""),
      status: String(o.status ?? "unknown"),
      tool_count: typeof o.tool_count === "number" ? o.tool_count : 0,
      error: (o.error as string | null | undefined) ?? null,
    };
  });
}

export default function McpServersPage() {
  const getMcpClient = useConnectionStore((s) => s.getMcpClient);

  const [servers, setServers] = useState<ServerEntry[]>([]);
  const [backends, setBackends] = useState<BridgeBackend[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState<{ type: "success" | "error"; text: string } | null>(null);

  const [adding, setAdding] = useState(false);
  const [newName, setNewName] = useState("");
  const [newUrl, setNewUrl] = useState("");
  const [newHeaders, setNewHeaders] = useState("");
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null);

  const [addingBackend, setAddingBackend] = useState(false);
  const [backendName, setBackendName] = useState("");
  const [backendCommand, setBackendCommand] = useState("");
  const [confirmRemoveBackend, setConfirmRemoveBackend] = useState<string | null>(null);

  const callMcpServers = useCallback(
    async (action: string, args: Record<string, unknown> = {}) => {
      const client = await getMcpClient();
      return client.callTool("mcp_servers", { action, ...args });
    },
    [getMcpClient],
  );

  const callBridge = useCallback(
    async (tool: string, args: Record<string, unknown> = {}) => {
      const client = await getMcpClient();
      return client.callTool(`${BRIDGE_PRESET.name}:${tool}`, args);
    },
    [getMcpClient],
  );

  const bridgeEntry = useMemo(
    () => servers.find((s) => s.name === BRIDGE_PRESET.name),
    [servers],
  );
  const bridgeReady = !!bridgeEntry && bridgeEntry.enabled && bridgeEntry.status === "ready";

  const loadBackends = useCallback(async () => {
    try {
      const raw = await callBridge("list_backends");
      setBackends(coerceBackends(raw));
    } catch (err) {
      // Bridge may briefly be unavailable during stack-up; silent on load.
      setBackends([]);
      if (busy != null) {
        setMessage({ type: "error", text: `Bridge: ${msg(err)}` });
      }
    }
  }, [callBridge, busy]);

  const loadData = useCallback(async () => {
    setLoading(true);
    try {
      const result = await callMcpServers("list");
      setServers(coerceServers((result as { servers?: unknown }).servers ?? result));
    } catch (err) {
      setMessage({ type: "error", text: `Failed to list servers: ${msg(err)}` });
    }
    setLoading(false);
  }, [callMcpServers]);

  useEffect(() => {
    void loadData();
  }, [loadData]);

  // Whenever the bridge entry transitions to ready, pull its backends.
  useEffect(() => {
    if (bridgeReady) {
      void loadBackends();
    } else {
      setBackends([]);
    }
  }, [bridgeReady, loadBackends]);

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

  // Bridge admin operations: call the gateway, then refresh the `bridge`
  // entry on cyfr so its external-tools cache picks up the new prefixed
  // tools right away (instead of waiting out the 30 s TTL).
  async function runBridge(label: string, fn: () => Promise<unknown>, key: string) {
    setBusy(key);
    setMessage(null);
    try {
      await fn();
      await callMcpServers("refresh", { name: BRIDGE_PRESET.name }).catch(() => undefined);
      await loadBackends();
      await loadData();
    } catch (err) {
      setMessage({ type: "error", text: `${label} failed: ${msg(err)}` });
    }
    setBusy(null);
    setConfirmRemoveBackend(null);
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
      () => callMcpServers("create", { name, config: { url, ...(headers ? { headers } : {}) } }),
      "add",
    );
    setAdding(false);
    setNewName("");
    setNewUrl("");
    setNewHeaders("");
  }

  async function handleAddBackend() {
    const name = backendName.trim();
    const command = backendCommand.trim();
    if (!name || !command) {
      setMessage({ type: "error", text: "Backend name and command are required" });
      return;
    }
    if (name.includes("__") || name.includes(":")) {
      setMessage({ type: "error", text: "Backend name cannot contain `__` or `:`" });
      return;
    }
    await runBridge(
      "Add backend",
      () => callBridge("add_backend", { name, command }),
      "addb",
    );
    setAddingBackend(false);
    setBackendName("");
    setBackendCommand("");
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
          {servers.map((s) => {
            const isBridge = s.name === BRIDGE_PRESET.name;
            return (
              <div
                key={s.name}
                className="rounded-lg border border-border-default bg-surface-raised px-4 py-3"
              >
                <div className="flex items-center justify-between gap-3">
                  <div className="flex min-w-0 items-center gap-3">
                    <span className={`h-2 w-2 shrink-0 rounded-full ${statusColor(s.enabled ? s.status : "disabled")}`} />
                    <div className="min-w-0">
                      <div className="flex items-center gap-2 text-sm text-text-primary">
                        {s.name}
                        {isBridge && (
                          <span className="rounded bg-accent-primary/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-accent-primary">
                            Bridge
                          </span>
                        )}
                      </div>
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
                        onClick={() => void run("Test", () => callMcpServers("test", { name: s.name }), `test:${s.name}`)}
                        className="text-accent-primary hover:text-accent-hover"
                      >
                        Test
                      </button>
                    )}
                    <button
                      onClick={() => void run("Refresh", () => callMcpServers("refresh", { name: s.name }), `refresh:${s.name}`)}
                      className="text-accent-primary hover:text-accent-hover"
                    >
                      Refresh
                    </button>
                    <button
                      onClick={() =>
                        void run(
                          s.enabled ? "Disable" : "Enable",
                          () => callMcpServers(s.enabled ? "disable" : "enable", { name: s.name }),
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
                          onClick={() => void run("Remove", () => callMcpServers("delete", { name: s.name }), `del:${s.name}`)}
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
            );
          })}
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
            {!bridgeEntry && (
              <button
                onClick={() =>
                  void run(
                    "Setup MCP Bridge",
                    () =>
                      callMcpServers("create", {
                        name: BRIDGE_PRESET.name,
                        config: { url: BRIDGE_PRESET.url },
                      }),
                    "add",
                  )
                }
                disabled={busy === "add"}
                className="text-xs text-accent-primary hover:text-accent-hover disabled:opacity-50"
                title="Register the local mcp-bridge gateway (wraps stdio/npx MCP servers behind one HTTP endpoint)"
              >
                {busy === "add" ? "Adding…" : "+ Setup MCP Bridge"}
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

      {bridgeReady && (
        <section className="mt-10">
          <div className="flex items-center justify-between">
            <div>
              <h2 className="text-sm font-medium text-text-primary">Bridge backends</h2>
              <p className="mt-1 text-xs text-text-muted">
                stdio MCP servers running inside <code className="text-text-secondary">mcp-bridge</code>.
                Their tools surface to AQUA as <code className="text-text-secondary">bridge:&lt;name&gt;__&lt;tool&gt;</code>.
              </p>
            </div>
            <button
              onClick={() => void loadBackends()}
              className="text-xs text-accent-primary hover:text-accent-hover"
            >
              Reload
            </button>
          </div>

          <div className="mt-2 space-y-2">
            {backends.length === 0 && (
              <p className="text-xs text-text-muted">No stdio backends yet. Add one to wrap an npx MCP server.</p>
            )}
            {backends.map((b) => (
              <div
                key={b.name}
                className="rounded-lg border border-border-default bg-surface-raised px-4 py-3"
              >
                <div className="flex items-center justify-between gap-3">
                  <div className="flex min-w-0 items-center gap-3">
                    <span className={`h-2 w-2 shrink-0 rounded-full ${statusColor(b.status)}`} />
                    <div className="min-w-0">
                      <div className="text-sm text-text-primary">{b.name}</div>
                      <div className="truncate text-xs text-text-muted">
                        <code className="text-text-secondary">{b.command}</code>
                        {` · ${b.tool_count} tool${b.tool_count === 1 ? "" : "s"} · ${b.status}`}
                        {b.error && ` · ${b.error}`}
                      </div>
                    </div>
                  </div>
                  <div className="flex shrink-0 items-center gap-3 text-xs">
                    <button
                      onClick={() =>
                        void runBridge(
                          "Restart backend",
                          () => callBridge("restart_backend", { name: b.name }),
                          `rbb:${b.name}`,
                        )
                      }
                      className="text-accent-primary hover:text-accent-hover"
                    >
                      Restart
                    </button>
                    {busy === `delb:${b.name}` ? (
                      <span className="text-text-muted">Removing…</span>
                    ) : confirmRemoveBackend === b.name ? (
                      <span className="flex items-center gap-1.5">
                        <span className="text-text-muted">Remove?</span>
                        <button
                          onClick={() =>
                            void runBridge(
                              "Remove backend",
                              () => callBridge("remove_backend", { name: b.name }),
                              `delb:${b.name}`,
                            )
                          }
                          className="text-status-error hover:underline"
                        >
                          Yes
                        </button>
                        <button
                          onClick={() => setConfirmRemoveBackend(null)}
                          className="text-text-muted hover:text-text-secondary"
                        >
                          No
                        </button>
                      </span>
                    ) : (
                      <button
                        onClick={() => setConfirmRemoveBackend(b.name)}
                        className="text-text-muted hover:text-status-error"
                      >
                        Remove
                      </button>
                    )}
                  </div>
                </div>
              </div>
            ))}
          </div>

          <div className="mt-3">
            {!addingBackend ? (
              <button
                onClick={() => setAddingBackend(true)}
                className="text-xs text-accent-primary hover:text-accent-hover"
              >
                Add backend…
              </button>
            ) : (
              <div className="space-y-2 rounded-lg border border-border-default bg-surface-raised p-4">
                <input
                  autoFocus
                  value={backendName}
                  onChange={(e) => setBackendName(e.target.value)}
                  placeholder="Backend name (e.g. fs)"
                  className="w-full rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary focus:border-accent-primary focus:outline-none"
                />
                <input
                  value={backendCommand}
                  onChange={(e) => setBackendCommand(e.target.value)}
                  placeholder="Shell command (e.g. npx -y @modelcontextprotocol/server-filesystem ./data)"
                  className="w-full rounded border border-border-default bg-surface-base px-2 py-1 font-mono text-xs text-text-primary focus:border-accent-primary focus:outline-none"
                />
                <div className="flex items-center gap-2">
                  <button
                    onClick={() => void handleAddBackend()}
                    disabled={busy === "addb"}
                    className="btn-primary text-xs"
                  >
                    {busy === "addb" ? "Adding…" : "Add"}
                  </button>
                  <button
                    onClick={() => {
                      setAddingBackend(false);
                      setBackendName("");
                      setBackendCommand("");
                    }}
                    className="text-xs text-text-muted hover:text-text-secondary"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            )}
          </div>
        </section>
      )}
    </PageLayout>
  );
}

function msg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

import { useState, useEffect, useCallback } from "react";
import type { McpClient } from "../api/mcp-client";
import { useConnectionStore } from "../state/connection-store";
import { friendlyError } from "../api/errors";
import { PageLayout } from "../components/common/PageLayout";

interface Schedule {
  schedule_id: string;
  name: string;
  cron_expression: string;
  reference: string;
  resolved_reference?: string;
  input?: unknown;
  metadata?: unknown;
  status: "active" | "paused";
  next_run_at: string | null;
  last_run_at: string | null;
  last_execution_id?: string;
  run_count: number;
  error_count: number;
  created_at: string;
  updated_at: string;
}

const CRON_PRESETS: [string, string][] = [
  ["Every minute", "* * * * *"],
  ["Every 5 minutes", "*/5 * * * *"],
  ["Every 15 minutes", "*/15 * * * *"],
  ["Every 30 minutes", "*/30 * * * *"],
  ["Every hour", "0 * * * *"],
  ["Every 6 hours", "0 */6 * * *"],
  ["Every 12 hours", "0 */12 * * *"],
  ["Daily at midnight", "0 0 * * *"],
  ["Daily at 9am", "0 9 * * *"],
  ["Weekdays at 9am", "0 9 * * 1-5"],
  ["Weekly (Sunday midnight)", "0 0 * * 0"],
  ["Monthly (1st at midnight)", "0 0 1 * *"],
  ["Custom", "custom"],
];

async function getMcpClient(): Promise<McpClient> {
  return useConnectionStore.getState().getMcpClient();
}

function cronLabel(expr: string): string {
  const match = CRON_PRESETS.find(([, val]) => val === expr);
  return match ? match[0] : expr;
}

function relativeTime(iso: string | null): string {
  if (!iso) return "-";
  const now = Date.now();
  const then = new Date(iso).getTime();
  if (isNaN(then)) return "-";
  const diffMs = now - then;
  const absDiff = Math.abs(diffMs);
  const future = diffMs < 0;

  if (absDiff < 60_000) return future ? "in <1m" : "<1m ago";
  if (absDiff < 3_600_000) {
    const m = Math.floor(absDiff / 60_000);
    return future ? `in ${m}m` : `${m}m ago`;
  }
  if (absDiff < 86_400_000) {
    const h = Math.floor(absDiff / 3_600_000);
    return future ? `in ${h}h` : `${h}h ago`;
  }
  const d = Math.floor(absDiff / 86_400_000);
  return future ? `in ${d}d` : `${d}d ago`;
}

const Spinner = ({ className = "h-3 w-3" }: { className?: string }) => (
  <svg className={`animate-spin ${className}`} fill="none" viewBox="0 0 24 24">
    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
  </svg>
);

const inputClass =
  "w-full rounded-lg bg-surface-base border border-border-default px-3 py-2 text-sm text-text-primary focus:border-accent-primary focus:ring-1 focus:ring-accent-primary focus:outline-hidden";

const selectClass =
  "w-full rounded-lg bg-surface-base border border-border-default px-3 py-2 text-sm text-text-primary focus:border-accent-primary focus:ring-1 focus:ring-accent-primary focus:outline-hidden";

export default function SchedulesPage() {
  const [schedules, setSchedules] = useState<Schedule[]>([]);
  const [components, setComponents] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [creating, setCreating] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);
  const [actionLoading, setActionLoading] = useState<string | null>(null);

  // Create form state
  const [name, setName] = useState("");
  const [cronPreset, setCronPreset] = useState("");
  const [cronCustom, setCronCustom] = useState("");
  const [reference, setReference] = useState("");
  const [inputJson, setInputJson] = useState("");

  const loadSchedules = useCallback(async () => {
    try {
      const client = await getMcpClient();
      const result = await client.callTool("schedule", { action: "list" });
      const list = (result as { schedules?: Schedule[] }).schedules ?? [];
      setSchedules(list);
      setError(null);
    } catch (err) {
      setError(friendlyError(err));
    }
  }, []);

  const loadComponents = useCallback(async () => {
    try {
      const client = await getMcpClient();
      const result = await client.callTool("component", { action: "list", limit: 1000 });
      const list = (result as { components?: { component_ref: string }[] }).components ?? [];
      setComponents(list.map((c) => c.component_ref).filter(Boolean));
    } catch {
      // Non-fatal — component dropdown will be empty
    }
  }, []);

  useEffect(() => {
    Promise.all([loadSchedules(), loadComponents()]).finally(() => setLoading(false));
  }, [loadSchedules, loadComponents]);

  const handleRefresh = useCallback(async () => {
    setLoading(true);
    await loadSchedules();
    setLoading(false);
  }, [loadSchedules]);

  const handlePause = useCallback(
    async (scheduleId: string) => {
      setActionLoading(scheduleId);
      try {
        const client = await getMcpClient();
        await client.callTool("schedule", { action: "pause", schedule_id: scheduleId });
        await loadSchedules();
      } catch (err) {
        setError(friendlyError(err));
      } finally {
        setActionLoading(null);
      }
    },
    [loadSchedules],
  );

  const handleResume = useCallback(
    async (scheduleId: string) => {
      setActionLoading(scheduleId);
      try {
        const client = await getMcpClient();
        await client.callTool("schedule", { action: "resume", schedule_id: scheduleId });
        await loadSchedules();
      } catch (err) {
        setError(friendlyError(err));
      } finally {
        setActionLoading(null);
      }
    },
    [loadSchedules],
  );

  const handleDelete = useCallback(
    async (scheduleId: string) => {
      setActionLoading(scheduleId);
      try {
        const client = await getMcpClient();
        await client.callTool("schedule", { action: "delete", schedule_id: scheduleId });
        await loadSchedules();
      } catch (err) {
        setError(friendlyError(err));
      } finally {
        setActionLoading(null);
        setConfirmDelete(null);
      }
    },
    [loadSchedules],
  );

  const handleCreate = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      const cron = cronPreset === "custom" ? cronCustom : cronPreset;
      if (!cron) {
        setError("Please select a schedule frequency");
        return;
      }
      setCreating(true);
      setError(null);
      try {
        const client = await getMcpClient();
        const args: Record<string, unknown> = {
          action: "create",
          name,
          cron_expression: cron,
          reference,
        };
        if (inputJson.trim()) {
          try {
            args.input = JSON.parse(inputJson);
          } catch {
            setError("Invalid JSON input");
            setCreating(false);
            return;
          }
        }
        await client.callTool("schedule", args);
        // Reset form
        setName("");
        setCronPreset("");
        setCronCustom("");
        setReference("");
        setInputJson("");
        setShowCreate(false);
        await loadSchedules();
      } catch (err) {
        setError(friendlyError(err));
      } finally {
        setCreating(false);
      }
    },
    [name, cronPreset, cronCustom, reference, inputJson, loadSchedules],
  );

  return (
    <PageLayout
      title="Schedules"
      subtitle="Manage recurring cron schedules for your components."
      actions={
        <>
          <button
            onClick={handleRefresh}
            disabled={loading}
            className="rounded-lg border border-border-default px-3 py-1.5 text-xs text-text-secondary hover:bg-surface-raised hover:text-text-primary transition-colors disabled:opacity-50"
          >
            {loading ? <Spinner /> : "Refresh"}
          </button>
          <button
            onClick={() => {
              setShowCreate(!showCreate);
              if (!showCreate) loadComponents();
            }}
            className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors ${
              showCreate
                ? "text-text-secondary hover:bg-surface-raised"
                : "bg-accent-primary text-white hover:bg-accent-hover"
            }`}
          >
            {showCreate ? "Cancel" : "New Schedule"}
          </button>
        </>
      }
    >
      {/* Error banner */}
        {error && (
          <div className="mt-4 rounded-lg bg-status-error/10 border border-status-error/20 px-4 py-3 text-sm text-status-error flex items-center justify-between">
            <span>{error}</span>
            <button onClick={() => setError(null)} className="ml-2 text-status-error/60 hover:text-status-error">
              <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        )}

        {/* Create form */}
        {showCreate && (
          <form onSubmit={handleCreate} className="mt-4 rounded-lg border border-border-default bg-surface-raised p-4 space-y-4">
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label className="block text-xs font-medium text-text-muted mb-1">Name</label>
                <input
                  type="text"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  placeholder="my-schedule"
                  required
                  className={inputClass}
                />
              </div>
              <div>
                <label className="block text-xs font-medium text-text-muted mb-1">Frequency</label>
                <select
                  value={cronPreset}
                  onChange={(e) => setCronPreset(e.target.value)}
                  required
                  className={selectClass}
                >
                  <option value="" disabled>Select a schedule...</option>
                  {CRON_PRESETS.map(([label, value]) => (
                    <option key={value} value={value}>
                      {label}{value !== "custom" ? ` \u2014 ${value}` : ""}
                    </option>
                  ))}
                </select>
              </div>
              {cronPreset === "custom" && (
                <div>
                  <label className="block text-xs font-medium text-text-muted mb-1">Custom Cron Expression</label>
                  <input
                    type="text"
                    value={cronCustom}
                    onChange={(e) => setCronCustom(e.target.value)}
                    placeholder="*/5 * * * *"
                    required
                    className={`${inputClass} font-mono`}
                  />
                  <p className="mt-1 text-xs text-text-muted">
                    Format: minute hour day-of-month month day-of-week
                  </p>
                </div>
              )}
              <div>
                <label className="block text-xs font-medium text-text-muted mb-1">Component</label>
                {components.length > 0 ? (
                  <select
                    value={reference}
                    onChange={(e) => setReference(e.target.value)}
                    required
                    className={selectClass}
                  >
                    <option value="" disabled>Select a component...</option>
                    {components.map((ref) => (
                      <option key={ref} value={ref}>{ref}</option>
                    ))}
                  </select>
                ) : (
                  <>
                    <input
                      type="text"
                      value={reference}
                      onChange={(e) => setReference(e.target.value)}
                      placeholder="catalyst:local.component:1.0.0"
                      required
                      className={`${inputClass} font-mono`}
                    />
                    <p className="mt-1 text-xs text-text-muted">
                      No registered components found. Enter a reference manually.
                    </p>
                  </>
                )}
              </div>
              <div>
                <label className="block text-xs font-medium text-text-muted mb-1">Input (JSON, optional)</label>
                <input
                  type="text"
                  value={inputJson}
                  onChange={(e) => setInputJson(e.target.value)}
                  placeholder='{"key":"value"}'
                  className={`${inputClass} font-mono`}
                />
              </div>
            </div>
            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setShowCreate(false)}
                className="rounded-lg px-3 py-1.5 text-xs text-text-secondary hover:bg-surface-raised transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={creating}
                className="rounded-lg bg-accent-primary px-3 py-1.5 text-xs font-medium text-white hover:bg-accent-hover transition-colors disabled:opacity-50 flex items-center gap-1.5"
              >
                {creating && <Spinner />}
                Create Schedule
              </button>
            </div>
          </form>
        )}

        {/* Content */}
        <div className="mt-6">
          {loading ? (
            <div className="flex items-center justify-center py-16">
              <Spinner className="h-5 w-5 text-text-muted" />
            </div>
          ) : schedules.length === 0 ? (
            <div className="py-16 text-center">
              <p className="text-sm text-text-muted">No schedules found</p>
              <p className="mt-1 text-xs text-text-muted">
                Create one above or ask AQUA to set up a schedule for you.
              </p>
            </div>
          ) : (
            <div className="overflow-x-auto rounded-lg border border-border-default">
              <table className="min-w-full divide-y divide-border-default">
                <thead className="bg-surface-raised">
                  <tr>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-text-muted">Name</th>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-text-muted">Reference</th>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-text-muted">Schedule</th>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-text-muted">Status</th>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-text-muted">Next Run</th>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-text-muted">Last Run</th>
                    <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wider text-text-muted">Runs</th>
                    <th className="px-4 py-3 text-right text-xs font-medium uppercase tracking-wider text-text-muted" />
                  </tr>
                </thead>
                <tbody className="divide-y divide-border-default">
                  {schedules.map((sched) => (
                    <tr key={sched.schedule_id} className="hover:bg-surface-raised/50">
                      <td className="px-4 py-3 text-sm text-text-primary font-medium whitespace-nowrap">
                        {sched.name}
                      </td>
                      <td className="px-4 py-3 text-xs font-mono text-accent-primary max-w-[180px] truncate" title={sched.reference}>
                        {sched.reference}
                      </td>
                      <td className="px-4 py-3 whitespace-nowrap">
                        <span className="text-sm text-text-secondary" title={sched.cron_expression}>
                          {cronLabel(sched.cron_expression)}
                        </span>
                        <span className="block text-xs text-text-muted font-mono">
                          {sched.cron_expression}
                        </span>
                      </td>
                      <td className="px-4 py-3 whitespace-nowrap">
                        <span
                          className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${
                            sched.status === "active"
                              ? "bg-status-success/15 text-status-success"
                              : "bg-status-warning/15 text-status-warning"
                          }`}
                        >
                          {sched.status}
                        </span>
                      </td>
                      <td className="px-4 py-3 text-xs text-text-muted whitespace-nowrap" title={sched.next_run_at ?? ""}>
                        {relativeTime(sched.next_run_at)}
                      </td>
                      <td className="px-4 py-3 text-xs text-text-muted whitespace-nowrap" title={sched.last_run_at ?? ""}>
                        {relativeTime(sched.last_run_at)}
                      </td>
                      <td className="px-4 py-3 text-sm text-text-secondary whitespace-nowrap">
                        {sched.run_count ?? 0}
                        {(sched.error_count ?? 0) > 0 && (
                          <span className="ml-1 text-status-error">({sched.error_count} err)</span>
                        )}
                      </td>
                      <td className="px-4 py-3 text-right whitespace-nowrap">
                        <div className="flex items-center justify-end gap-2">
                          {actionLoading === sched.schedule_id ? (
                            <Spinner />
                          ) : (
                            <>
                              {sched.status === "active" ? (
                                <button
                                  onClick={() => handlePause(sched.schedule_id)}
                                  className="text-xs text-text-muted hover:text-text-secondary"
                                >
                                  Pause
                                </button>
                              ) : (
                                <button
                                  onClick={() => handleResume(sched.schedule_id)}
                                  className="text-xs text-text-muted hover:text-text-secondary"
                                >
                                  Resume
                                </button>
                              )}
                              {confirmDelete === sched.schedule_id ? (
                                <span className="flex items-center gap-1.5 text-xs">
                                  <span className="text-text-muted">Delete?</span>
                                  <button
                                    onClick={() => handleDelete(sched.schedule_id)}
                                    className="text-status-error hover:underline"
                                  >
                                    Yes
                                  </button>
                                  <button
                                    onClick={() => setConfirmDelete(null)}
                                    className="text-text-muted hover:text-text-secondary"
                                  >
                                    No
                                  </button>
                                </span>
                              ) : (
                                <button
                                  onClick={() => setConfirmDelete(sched.schedule_id)}
                                  className="text-xs text-text-muted hover:text-status-error"
                                >
                                  Delete
                                </button>
                              )}
                            </>
                          )}
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
    </PageLayout>
  );
}

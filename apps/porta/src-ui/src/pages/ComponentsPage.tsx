import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { friendlyError } from "../api/errors";
import {
  useProviderStore,
  type ProviderInfo,
  type ProviderKey,
} from "../state/provider-store";

interface CyfrResult {
  stdout: string;
  stderr: string;
  success: boolean;
  code: number;
}

async function cyfr(args: string[]): Promise<Record<string, unknown>> {
  const result = await invoke<CyfrResult>("cyfr_command", { args });
  if (!result.success) {
    throw new Error(result.stderr.trim() || result.stdout.trim() || "Command failed");
  }
  try {
    return JSON.parse(result.stdout) as Record<string, unknown>;
  } catch {
    return { text: result.stdout };
  }
}

interface ComponentEntry {
  component_ref: string;
  name: string;
  component_type: string;
  description: string;
  publisher: string;
  version: string;
  source: string;
}

interface SetupSecret {
  name: string;
  description: string;
  required: boolean;
  already_set: boolean;
  already_granted: boolean;
}

interface SetupPlan {
  component_ref: string;
  ready: boolean;
  secrets: SetupSecret[];
  policy_current: Record<string, unknown> | null;
  policy_recommended: Record<string, unknown> | null;
  configurable_fields: string[];
}

const TYPE_COLORS: Record<string, string> = {
  catalyst: "bg-purple-500/15 text-purple-400",
  reagent: "bg-blue-500/15 text-blue-400",
  formula: "bg-amber-500/15 text-amber-400",
};

/** Strip version from a component ref: "catalyst:pub.name:1.0.0" → "catalyst:pub.name" */
function versionlessRef(ref: string): string {
  const lastColon = ref.lastIndexOf(":");
  // Only strip if there are at least 2 colons (type:pub.name:version)
  const firstColon = ref.indexOf(":");
  if (lastColon > firstColon) return ref.slice(0, lastColon);
  return ref;
}

/** Versionless refs for the known provider catalysts (managed in Provider Keys section) */
function getProviderRefs(): Set<string> {
  return new Set(
    useProviderStore
      .getState()
      .providers.map((p) => versionlessRef(p.catalystRef)),
  );
}

/**
 * Deduplicate components by versionless ref, keeping the entry with the highest version.
 * This handles cases where multiple versions are installed (e.g. after a CYFR update).
 */
function dedupeByRef(components: ComponentEntry[]): ComponentEntry[] {
  const map = new Map<string, ComponentEntry>();
  for (const c of components) {
    const key = versionlessRef(c.component_ref);
    const existing = map.get(key);
    if (!existing || c.version > existing.version) {
      map.set(key, c);
    }
  }
  return Array.from(map.values());
}

export default function ComponentsPage() {
  const [components, setComponents] = useState<ComponentEntry[]>([]);
  const [loading, setLoading] = useState(true);

  const loadComponents = useCallback(async () => {
    setLoading(true);
    try {
      const result = await invoke<CyfrResult>("cyfr_command", {
        args: ["list"],
      });
      if (result.success) {
        const parsed = JSON.parse(result.stdout) as Record<string, unknown>;
        setComponents((parsed.components as ComponentEntry[]) ?? []);
      }
    } catch {
      // Non-fatal
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    loadComponents();
  }, [loadComponents]);

  // Exclude provider catalysts (handled by Provider Keys section)
  const providerRefs = getProviderRefs();
  const nonProvider = components.filter(
    (c) => !providerRefs.has(versionlessRef(c.component_ref)),
  );

  // Split into installed vs system, then deduplicate by versionless ref
  const installed = dedupeByRef(
    nonProvider.filter((c) => c.source !== "filesystem"),
  );
  const system = dedupeByRef(
    nonProvider.filter((c) => c.source === "filesystem"),
  );

  return (
    <div className="flex-1 overflow-y-auto">
      <div className="mx-auto max-w-2xl px-6 py-8">
        <h1 className="text-xl font-semibold text-text-primary">Components</h1>
        <p className="mt-1 text-sm text-text-secondary">
          Manage installed components, provider keys, and system components.
        </p>

        {loading && (
          <p className="mt-6 text-xs text-text-muted">Loading components...</p>
        )}

        {/* Section 1: Installed */}
        {!loading && (
          <ComponentSection
            title="Installed"
            subtitle="Components pulled from the registry. Agents may install new ones here."
            components={installed}
            canRemove
            onRemoved={loadComponents}
          />
        )}

        {/* Section 2: Provider Keys */}
        <ProvidersSection />

        {/* Section 3: System */}
        {!loading && (
          <ComponentSection
            title="System"
            subtitle="Built-in components shipped with CYFR."
            components={system}
            canRemove={false}
            onRemoved={loadComponents}
          />
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Component list section (used for both Installed and System)
// ---------------------------------------------------------------------------

function ComponentSection({
  title,
  subtitle,
  components,
  canRemove,
  onRemoved,
}: {
  title: string;
  subtitle: string;
  components: ComponentEntry[];
  canRemove: boolean;
  onRemoved: () => void;
}) {
  const [expandedRef, setExpandedRef] = useState<string | null>(null);
  // Pre-fetched setup plans keyed by versionless ref
  const [plans, setPlans] = useState<Record<string, SetupPlan | null>>({});

  // Batch-fetch setup plans for all components to get readiness status
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const results: Record<string, SetupPlan | null> = {};
      await Promise.all(
        components.map(async (c) => {
          const nameRef = versionlessRef(c.component_ref);
          try {
            const result = await cyfr(["setup", nameRef]);
            if (!cancelled) results[nameRef] = result as unknown as SetupPlan;
          } catch {
            if (!cancelled) results[nameRef] = null;
          }
        }),
      );
      if (!cancelled) setPlans(results);
    })();
    return () => {
      cancelled = true;
    };
  }, [components]);

  const refreshPlan = useCallback(
    async (component: ComponentEntry) => {
      const nameRef = versionlessRef(component.component_ref);
      try {
        const result = await cyfr(["setup", nameRef]);
        setPlans((prev) => ({ ...prev, [nameRef]: result as unknown as SetupPlan }));
      } catch {
        setPlans((prev) => ({ ...prev, [nameRef]: null }));
      }
    },
    [],
  );

  if (components.length === 0) {
    return (
      <section className="mt-10">
        <h2 className="text-sm font-medium text-text-primary">{title}</h2>
        <p className="mt-1 text-xs text-text-secondary">{subtitle}</p>
        <p className="mt-4 text-xs text-text-muted">None</p>
      </section>
    );
  }

  // Group by type
  const grouped: Record<string, ComponentEntry[]> = {};
  for (const c of components) {
    const t = c.component_type || "unknown";
    if (!grouped[t]) grouped[t] = [];
    grouped[t].push(c);
  }
  const typeOrder = ["catalyst", "reagent", "formula"];
  const sortedTypes = Object.keys(grouped).sort(
    (a, b) =>
      (typeOrder.indexOf(a) === -1 ? 99 : typeOrder.indexOf(a)) -
      (typeOrder.indexOf(b) === -1 ? 99 : typeOrder.indexOf(b)),
  );

  return (
    <section className="mt-10">
      <h2 className="text-sm font-medium text-text-primary">{title}</h2>
      <p className="mt-1 text-xs text-text-secondary">{subtitle}</p>

      {sortedTypes.map((type) => (
        <div key={type} className="mt-4">
          <h3 className="text-xs font-medium uppercase text-text-muted">
            {type}s
          </h3>
          <div className="mt-2 space-y-1.5">
            {(grouped[type] ?? []).map((c) => {
              const nameRef = versionlessRef(c.component_ref);
              const plan = plans[nameRef];
              return (
                <ComponentCard
                  key={c.component_ref}
                  component={c}
                  plan={plan}
                  expanded={expandedRef === c.component_ref}
                  onToggle={() =>
                    setExpandedRef(
                      expandedRef === c.component_ref ? null : c.component_ref,
                    )
                  }
                  canRemove={canRemove}
                  onRemoved={onRemoved}
                  onPlanChanged={() => refreshPlan(c)}
                />
              );
            })}
          </div>
        </div>
      ))}
    </section>
  );
}

// ---------------------------------------------------------------------------
// Single component card with expandable setup
// ---------------------------------------------------------------------------

function ComponentCard({
  component,
  plan,
  expanded,
  onToggle,
  canRemove,
  onRemoved,
  onPlanChanged,
}: {
  component: ComponentEntry;
  plan: SetupPlan | null | undefined;
  expanded: boolean;
  onToggle: () => void;
  canRemove: boolean;
  onRemoved: () => void;
  onPlanChanged: () => void;
}) {
  // undefined = still loading, null = no setup required, SetupPlan = has plan
  const ready = plan === undefined ? undefined : plan === null ? true : plan.ready;
  const statusLabel =
    ready === undefined
      ? ""
      : ready
        ? "Ready"
        : "Setup needed";
  const dotColor =
    ready === undefined
      ? "bg-text-muted"
      : ready
        ? "bg-status-success"
        : "bg-status-error";
  const textColor =
    ready === undefined
      ? "text-text-muted"
      : ready
        ? "text-status-success"
        : "text-text-muted";

  return (
    <div className="overflow-hidden rounded-lg border border-border-default bg-surface-raised">
      <button
        onClick={onToggle}
        className="flex w-full items-center gap-3 px-4 py-3 text-left"
      >
        <span className={`h-2 w-2 shrink-0 rounded-full ${dotColor}`} />
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <span className="text-sm text-text-primary">{component.name}</span>
            <span
              className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${
                TYPE_COLORS[component.component_type] ??
                "bg-text-muted/15 text-text-muted"
              }`}
            >
              {component.component_type}
            </span>
          </div>
          {component.description && (
            <p className="mt-0.5 truncate text-xs text-text-muted">
              {component.description}
            </p>
          )}
        </div>
        <span className={`shrink-0 text-xs ${textColor}`}>
          {statusLabel}
        </span>
        <ChevronIcon expanded={expanded} />
      </button>

      {expanded && (
        <div className="border-t border-border-default px-4 py-3">
          <ComponentSetup
            component={component}
            plan={plan ?? null}
            canRemove={canRemove}
            onRemoved={onRemoved}
            onPlanChanged={onPlanChanged}
          />
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Expanded setup view — secrets + policies + remove
// ---------------------------------------------------------------------------

function ComponentSetup({
  component,
  plan,
  canRemove,
  onRemoved,
  onPlanChanged,
}: {
  component: ComponentEntry;
  plan: SetupPlan | null;
  canRemove: boolean;
  onRemoved: () => void;
  onPlanChanged: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Secret inputs: { secretName: value }
  const [secretInputs, setSecretInputs] = useState<Record<string, string>>({});
  // Policy inputs: { fieldName: value }
  const [policyInputs, setPolicyInputs] = useState<Record<string, string>>({});

  const startEditing = () => {
    if (!plan) return;
    // Initialize inputs from current stored values only (not recommended)
    const si: Record<string, string> = {};
    for (const s of plan.secrets ?? []) {
      si[s.name] = "";
    }
    const pi: Record<string, string> = {};
    for (const field of plan.configurable_fields ?? []) {
      const current = plan.policy_current?.[field];
      if (current != null) {
        pi[field] = typeof current === "string" ? current : JSON.stringify(current);
      } else {
        pi[field] = "";
      }
    }
    setSecretInputs(si);
    setPolicyInputs(pi);
    setEditing(true);
    setError(null);
  };

  const hasRecommended =
    Object.keys(plan?.policy_recommended ?? {}).length > 0 ||
    Object.keys(plan?.policy_current ?? {}).length > 0;

  const fillRecommended = () => {
    if (!plan) return;
    setPolicyInputs((prev) => {
      const next = { ...prev };
      for (const field of plan.configurable_fields ?? []) {
        if (next[field]) continue; // Don't overwrite user-entered values
        // Prefer setup.policy recommended, fall back to current stored value
        const rec = plan.policy_recommended?.[field] ?? plan.policy_current?.[field];
        if (rec != null) {
          next[field] = typeof rec === "string" ? rec : JSON.stringify(rec);
        }
      }
      return next;
    });
  };

  const handleSave = async () => {
    if (!plan) return;
    setSaving(true);
    setError(null);

    // Name-level ref (without version) for grants/policies
    const nameRef = versionlessRef(component.component_ref);

    try {
      // Save secrets
      for (const secret of plan.secrets ?? []) {
        const inputVal = secretInputs[secret.name] ?? "";
        if (inputVal) {
          // New secret value provided
          await cyfr(["secret", "set", `${secret.name}=${inputVal}`]);
          await cyfr(["secret", "grant", nameRef, secret.name]);
        } else if (secret.already_set && !secret.already_granted) {
          // Just grant existing secret
          await cyfr(["secret", "grant", nameRef, secret.name]);
        }
      }

      // Save policy fields
      for (const field of plan.configurable_fields ?? []) {
        const val = policyInputs[field] ?? "";
        if (val) {
          await cyfr(["policy", "set", nameRef, field, val]);
        }
      }

      // Refresh plan in parent
      onPlanChanged();
      setEditing(false);
    } catch (err) {
      setError(friendlyError(err));
    }
    setSaving(false);
  };

  const [confirmRemove, setConfirmRemove] = useState(false);

  const handleRemove = async () => {
    setRemoving(true);
    setError(null);
    try {
      await cyfr(["remove", component.component_ref]);
      onRemoved();
    } catch (err) {
      setError(friendlyError(err));
      setRemoving(false);
      setConfirmRemove(false);
    }
  };

  if (!plan) {
    return (
      <div className="flex items-center justify-between">
        <p className="text-xs text-text-muted">No setup required</p>
        {canRemove && <RemoveButton confirmRemove={confirmRemove} setConfirmRemove={setConfirmRemove} removing={removing} onRemove={handleRemove} />}
      </div>
    );
  }

  const hasSecrets = (plan.secrets ?? []).length > 0;
  const hasPolicy = (plan.configurable_fields ?? []).length > 0;

  // View mode
  if (!editing) {
    return (
      <div>
        {/* Readiness indicator */}
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <span
              className={`h-2 w-2 rounded-full ${
                plan.ready ? "bg-status-success" : "bg-status-error"
              }`}
            />
            <span className="text-xs text-text-secondary">
              {plan.ready ? "Ready" : "Setup required"}
            </span>
          </div>
          <div className="flex items-center gap-2">
            <button
              onClick={startEditing}
              className="text-xs text-accent-primary hover:text-accent-hover"
            >
              Edit
            </button>
            {canRemove && <RemoveButton confirmRemove={confirmRemove} setConfirmRemove={setConfirmRemove} removing={removing} onRemove={handleRemove} />}
          </div>
        </div>

        {/* Secrets status */}
        {hasSecrets && (
          <div className="mt-3">
            <span className="text-[10px] font-medium uppercase text-text-muted">
              Secrets
            </span>
            <div className="mt-1 space-y-1">
              {plan.secrets.map((s) => (
                <div key={s.name} className="flex items-center justify-between">
                  <span className="font-mono text-xs text-text-secondary">
                    {s.name}
                  </span>
                  <SecretBadge secret={s} />
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Policy summary */}
        {hasPolicy && (
          <div className="mt-3">
            <span className="text-[10px] font-medium uppercase text-text-muted">
              Policy
            </span>
            <div className="mt-1 space-y-1">
              {plan.configurable_fields.map((field) => {
                const current = plan.policy_current?.[field];
                const recommended = plan.policy_recommended?.[field];
                const val = current ?? recommended;
                const display =
                  val == null
                    ? "—"
                    : typeof val === "string"
                      ? val
                      : JSON.stringify(val);
                return (
                  <div
                    key={field}
                    className="flex items-center justify-between gap-2"
                  >
                    <span className="text-xs text-text-secondary">{field}</span>
                    <span
                      className={`truncate text-xs ${
                        current != null ? "text-text-primary" : "text-text-muted italic"
                      }`}
                    >
                      {display}
                    </span>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {error && <p className="mt-2 text-xs text-status-error">{error}</p>}
      </div>
    );
  }

  // Edit mode
  return (
    <div>
      {/* Secrets */}
      {hasSecrets && (
        <div>
          <span className="text-[10px] font-medium uppercase text-text-muted">
            Secrets
          </span>
          <div className="mt-1.5 space-y-2">
            {plan.secrets.map((s) => (
              <div key={s.name}>
                <div className="flex items-center justify-between">
                  <label className="font-mono text-xs text-text-secondary">
                    {s.name}
                    {s.required && (
                      <span className="ml-1 text-status-error">*</span>
                    )}
                  </label>
                  <SecretBadge secret={s} />
                </div>
                {s.already_set ? (
                  <p className="mt-1 text-[10px] text-text-muted">
                    Already set. Leave blank to keep current value.
                  </p>
                ) : null}
                <input
                  type="password"
                  value={secretInputs[s.name] ?? ""}
                  onChange={(e) =>
                    setSecretInputs((prev) => ({
                      ...prev,
                      [s.name]: e.target.value,
                    }))
                  }
                  placeholder={s.already_set ? "Leave blank to keep" : s.name}
                  className="mt-1 w-full rounded-lg border border-border-default bg-surface-base px-3 py-1.5 font-mono text-xs text-text-primary placeholder-text-muted outline-none focus:border-border-focus"
                />
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Policy fields */}
      {hasPolicy && (
        <div className={hasSecrets ? "mt-4" : ""}>
          <span className="text-[10px] font-medium uppercase text-text-muted">
            Policy
          </span>
          <div className="mt-1.5 space-y-2">
            {plan.configurable_fields.map((field) => {
              const recommended = plan.policy_recommended?.[field] ?? plan.policy_current?.[field];
              const source = plan.policy_recommended?.[field] != null ? "recommended" : "current";
              const placeholder = recommended != null
                ? `${typeof recommended === "string" ? recommended : JSON.stringify(recommended)} (${source})`
                : field;
              return (
                <div key={field}>
                  <label className="text-xs text-text-secondary">{field}</label>
                  <input
                    value={policyInputs[field] ?? ""}
                    onChange={(e) =>
                      setPolicyInputs((prev) => ({
                        ...prev,
                        [field]: e.target.value,
                      }))
                    }
                    placeholder={placeholder}
                    className="mt-1 w-full rounded-lg border border-border-default bg-surface-base px-3 py-1.5 text-xs text-text-primary placeholder-text-muted outline-none focus:border-border-focus"
                  />
                </div>
              );
            })}
          </div>
        </div>
      )}

      {error && <p className="mt-2 text-xs text-status-error">{error}</p>}

      {/* Save / Cancel / Fill Recommended */}
      <div className="mt-3 flex justify-end gap-2">
        {hasRecommended && (
          <button
            onClick={fillRecommended}
            className="mr-auto rounded-md border border-border-default px-3 py-1.5 text-xs text-text-muted transition-colors hover:bg-surface-base hover:text-text-secondary"
          >
            Fill Recommended
          </button>
        )}
        <button
          onClick={() => setEditing(false)}
          className="rounded-md border border-border-default px-3 py-1.5 text-xs text-text-secondary transition-colors hover:bg-surface-base"
        >
          Cancel
        </button>
        <button
          onClick={handleSave}
          disabled={saving}
          className="btn-primary rounded-md px-3 py-1.5 text-xs"
        >
          {saving ? "Saving..." : "Save"}
        </button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Inline remove confirm
// ---------------------------------------------------------------------------

function RemoveButton({
  confirmRemove,
  setConfirmRemove,
  removing,
  onRemove,
}: {
  confirmRemove: boolean;
  setConfirmRemove: (v: boolean) => void;
  removing: boolean;
  onRemove: () => void;
}) {
  if (removing) {
    return <span className="text-xs text-text-muted">Removing...</span>;
  }
  if (confirmRemove) {
    return (
      <span className="flex items-center gap-1.5 text-xs">
        <span className="text-text-muted">Remove?</span>
        <button
          onClick={onRemove}
          className="text-status-error hover:underline"
        >
          Yes
        </button>
        <button
          onClick={() => setConfirmRemove(false)}
          className="text-text-muted hover:text-text-secondary"
        >
          No
        </button>
      </span>
    );
  }
  return (
    <button
      onClick={() => setConfirmRemove(true)}
      className="text-xs text-text-muted hover:text-status-error"
    >
      Remove
    </button>
  );
}

// ---------------------------------------------------------------------------
// Secret status badge
// ---------------------------------------------------------------------------

function SecretBadge({ secret }: { secret: SetupSecret }) {
  if (secret.already_set && secret.already_granted) {
    return (
      <span className="rounded bg-green-500/15 px-1.5 py-0.5 text-[10px] font-medium text-green-400">
        Set &amp; Granted
      </span>
    );
  }
  if (secret.already_set) {
    return (
      <span className="rounded bg-yellow-500/15 px-1.5 py-0.5 text-[10px] font-medium text-yellow-400">
        Set (not granted)
      </span>
    );
  }
  return (
    <span className="rounded bg-red-500/15 px-1.5 py-0.5 text-[10px] font-medium text-red-400">
      Not configured
    </span>
  );
}

// ---------------------------------------------------------------------------
// Provider Keys section
// ---------------------------------------------------------------------------

function ProvidersSection() {
  const { providers, loading, loadAll } = useProviderStore();
  const [expanded, setExpanded] = useState<ProviderKey | null>(null);
  const [plans, setPlans] = useState<Record<string, SetupPlan | null>>({});

  useEffect(() => {
    loadAll();
  }, [loadAll]);

  // Fetch setup plans for all provider catalysts
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const results: Record<string, SetupPlan | null> = {};
      await Promise.all(
        providers.map(async (p) => {
          const nameRef = versionlessRef(p.catalystRef);
          try {
            const result = await cyfr(["setup", nameRef]);
            if (!cancelled) results[p.key] = result as unknown as SetupPlan;
          } catch {
            if (!cancelled) results[p.key] = null;
          }
        }),
      );
      if (!cancelled) setPlans(results);
    })();
    return () => {
      cancelled = true;
    };
  }, [providers]);

  const refreshPlan = useCallback(async (provider: ProviderInfo) => {
    const nameRef = versionlessRef(provider.catalystRef);
    try {
      const result = await cyfr(["setup", nameRef]);
      setPlans((prev) => ({ ...prev, [provider.key]: result as unknown as SetupPlan }));
    } catch {
      setPlans((prev) => ({ ...prev, [provider.key]: null }));
    }
  }, []);

  return (
    <section className="mt-10">
      <div className="flex items-center gap-2">
        <h2 className="text-sm font-medium text-text-primary">Provider Keys</h2>
        {loading && (
          <svg className="h-3 w-3 animate-spin text-text-muted" fill="none" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
          </svg>
        )}
      </div>
      <p className="mt-1 text-xs text-text-secondary">
        API keys for AI model providers.
      </p>

      <div className="mt-4 space-y-2">
        {providers.map((p) => (
          <ProviderCard
            key={p.key}
            provider={p}
            plan={plans[p.key]}
            expanded={expanded === p.key}
            onToggle={() =>
              setExpanded(expanded === p.key ? null : p.key)
            }
            onPlanChanged={() => refreshPlan(p)}
          />
        ))}
      </div>
    </section>
  );
}

function ProviderCard({
  provider,
  plan,
  expanded,
  onToggle,
  onPlanChanged,
}: {
  provider: ProviderInfo;
  plan: SetupPlan | null | undefined;
  expanded: boolean;
  onToggle: () => void;
  onPlanChanged: () => void;
}) {
  // Build a ComponentEntry so we can reuse ComponentSetup for secrets/policy editing
  const componentEntry: ComponentEntry = {
    component_ref: provider.catalystRef,
    name: provider.label,
    component_type: "catalyst",
    description: "",
    publisher: "",
    version: "",
    source: "filesystem",
  };

  // Filter the plan to exclude the provider's main API key secret (already managed above)
  const filteredPlan =
    plan != null
      ? {
          ...plan,
          secrets: plan.secrets.filter((s) => s.name !== provider.secretName),
        }
      : plan;

  // Only show ComponentSetup if there are additional secrets or policy fields
  const hasExtra =
    filteredPlan != null &&
    ((filteredPlan.secrets?.length ?? 0) > 0 ||
      (filteredPlan.configurable_fields?.length ?? 0) > 0);

  return (
    <div className="overflow-hidden rounded-lg border border-border-default bg-surface-raised">
      <button
        onClick={onToggle}
        className="flex w-full items-center gap-3 px-4 py-3 text-left"
      >
        <span
          className={`h-2 w-2 shrink-0 rounded-full ${
            provider.ready
              ? "bg-status-success"
              : provider.secretSet && provider.error
                ? "bg-status-error"
                : "bg-text-muted"
          }`}
        />
        <div className="flex-1 min-w-0">
          <span className="text-sm font-medium text-text-primary">
            {provider.label}
          </span>
        </div>
        <span
          className={`shrink-0 text-xs ${
            provider.ready
              ? "text-status-success"
              : provider.secretSet && provider.error
                ? "text-status-error"
                : "text-text-muted"
          }`}
        >
          {provider.loading
            ? "Setting up..."
            : provider.ready
              ? "Ready"
              : provider.secretSet && provider.error
                ? "Error"
                : "Setup needed"}
        </span>
        <ChevronIcon expanded={expanded} />
      </button>

      {expanded && (
        <div className="border-t border-border-default px-4 py-3">
          {provider.ready || provider.secretSet ? (
            <ReadyProviderView provider={provider} />
          ) : (
            <SetupProviderView provider={provider} />
          )}
          {hasExtra && (
            <div className="mt-3 border-t border-border-default pt-3">
              <ComponentSetup
                component={componentEntry}
                plan={filteredPlan}
                canRemove={false}
                onRemoved={() => {}}
                onPlanChanged={onPlanChanged}
              />
            </div>
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
      <label className="mb-1.5 block text-xs text-text-muted">API Key</label>
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
            Remove Key
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

      {provider.error && (
        <p className="mt-2 text-xs text-status-error">{provider.error}</p>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Shared icons
// ---------------------------------------------------------------------------

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

import { useState, useEffect, useCallback } from "react";
import { host } from "../host";
import { friendlyError } from "../api/errors";
import {
  useProviderStore,
  type ProviderInfo,
  type ProviderKey,
} from "../state/provider-store";
import { useConnectionStore } from "../state/connection-store";
import * as cyfrMcp from "../api/cyfr-mcp";
import { PageLayout } from "../components/common/PageLayout";

async function getClient() {
  return useConnectionStore.getState().getMcpClient();
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

interface DeclaredNeed {
  name: string;
  kind: string;
  qualifier: string;
  reason?: string | null;
  required: boolean;
}

interface ConsentNeed {
  need?: string;
  entry_id?: string;
  satisfied: boolean;
  detail?: string | null;
}

interface ConsentSection {
  profile_id: string;
  profile_status: string;
  revision: number | null;
  needs: ConsentNeed[];
  ready: boolean;
}

interface SetupPlan {
  component_ref: string;
  ready: boolean;
  needs: DeclaredNeed[];
  consent: ConsentSection | null;
}

const TYPE_COLORS: Record<string, string> = {
  catalyst: "bg-purple-500/15 text-purple-400",
  reagent: "bg-blue-500/15 text-blue-400",
  formula: "bg-amber-500/15 text-amber-400",
  tincture: "bg-emerald-500/15 text-emerald-400",
};

/** Strip version from a component ref: "catalyst:pub.name:1.0.0" → "catalyst:pub.name" */
function versionlessRef(ref: string): string {
  const lastColon = ref.lastIndexOf(":");
  // Only strip if there are at least 2 colons (type:pub.name:version)
  const firstColon = ref.indexOf(":");
  if (lastColon > firstColon) return ref.slice(0, lastColon);
  return ref;
}

/** Versionless refs for the known provider catalysts (shown in the Providers section) */
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
  const [loadError, setLoadError] = useState<string | null>(null);

  const loadComponents = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      const client = await getClient();
      const parsed = await cyfrMcp.listComponents(client);
      setComponents((parsed.components as ComponentEntry[]) ?? []);
    } catch (e) {
      setLoadError(friendlyError(e));
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    loadComponents();
  }, [loadComponents]);

  // Exclude provider catalysts (shown in the Providers section)
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
    <PageLayout
      title="Components"
      subtitle="Installed components, AI providers, and system components. Grants are managed in the Prism console."
    >
      {loading && (
        <p className="text-xs text-text-muted">Loading components...</p>
      )}
      {loadError && <p className="text-xs text-status-error">{loadError}</p>}

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

      {/* Section 2: Providers */}
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
    </PageLayout>
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
      const client = await getClient();
      const results: Record<string, SetupPlan | null> = {};
      await Promise.all(
        components.map(async (c) => {
          const nameRef = versionlessRef(c.component_ref);
          try {
            const result = await cyfrMcp.setupPlan(client, nameRef);
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
  const typeOrder = ["catalyst", "reagent", "formula", "tincture"];
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
// Single component card with expandable read-only setup state
// ---------------------------------------------------------------------------

function ComponentCard({
  component,
  plan,
  expanded,
  onToggle,
  canRemove,
  onRemoved,
}: {
  component: ComponentEntry;
  plan: SetupPlan | null | undefined;
  expanded: boolean;
  onToggle: () => void;
  canRemove: boolean;
  onRemoved: () => void;
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
          />
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Expanded view — read-only needs/consent state + remove
// ---------------------------------------------------------------------------

function ComponentSetup({
  component,
  plan,
  canRemove,
  onRemoved,
}: {
  component: ComponentEntry;
  plan: SetupPlan | null;
  canRemove: boolean;
  onRemoved: () => void;
}) {
  const [removing, setRemoving] = useState(false);
  const [confirmRemove, setConfirmRemove] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleRemove = async () => {
    setRemoving(true);
    setError(null);
    try {
      const client = await getClient();
      await cyfrMcp.removeComponent(client, component.component_ref);
      onRemoved();
    } catch (err) {
      setError(friendlyError(err));
      setRemoving(false);
      setConfirmRemove(false);
    }
  };

  const removeButton = canRemove && (
    <RemoveButton
      confirmRemove={confirmRemove}
      setConfirmRemove={setConfirmRemove}
      removing={removing}
      onRemove={handleRemove}
    />
  );

  if (!plan) {
    return (
      <div className="flex items-center justify-between">
        <p className="text-xs text-text-muted">No setup required</p>
        {removeButton}
      </div>
    );
  }

  const consentNeeds = plan.consent?.needs ?? [];
  const declaredNeeds = plan.needs ?? [];

  return (
    <div>
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
        {removeButton}
      </div>

      {(consentNeeds.length > 0 || declaredNeeds.length > 0) && (
        <div className="mt-3">
          <span className="text-[10px] font-medium uppercase text-text-muted">
            Connections
          </span>
          <div className="mt-1 space-y-1">
            {consentNeeds.length > 0
              ? consentNeeds.map((n, i) => (
                  <NeedRow
                    key={n.need ?? n.entry_id ?? i}
                    label={n.need ?? n.entry_id ?? `binding ${i + 1}`}
                    satisfied={n.satisfied}
                    detail={n.detail}
                  />
                ))
              : declaredNeeds.map((n) => (
                  <NeedRow
                    key={n.name}
                    label={n.name}
                    satisfied={plan.ready}
                    detail={n.reason ?? (n.required ? "required" : "optional")}
                  />
                ))}
          </div>
        </div>
      )}

      {!plan.ready && (
        <p className="mt-3 text-xs text-text-muted">
          Grant connections in the Prism console, then reload this page.
        </p>
      )}

      {error && <p className="mt-2 text-xs text-status-error">{error}</p>}
    </div>
  );
}

function NeedRow({
  label,
  satisfied,
  detail,
}: {
  label: string;
  satisfied: boolean;
  detail?: string | null;
}) {
  return (
    <div className="flex items-start gap-2">
      <span
        className={`mt-1 inline-block h-1.5 w-1.5 shrink-0 rounded-full ${
          satisfied ? "bg-status-success" : "bg-status-error"
        }`}
      />
      <div className="min-w-0">
        <span className="font-mono text-xs text-text-secondary">{label}</span>
        {detail && <p className="truncate text-xs text-text-muted">{detail}</p>}
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
// Providers section — read-only status; keys are granted in the Prism console
// ---------------------------------------------------------------------------

function ProvidersSection() {
  const { providers, loading, error, loadAll } = useProviderStore();
  const [expanded, setExpanded] = useState<ProviderKey | null>(null);

  useEffect(() => {
    loadAll();
  }, [loadAll]);

  return (
    <section className="mt-10">
      <div className="flex items-center gap-2">
        <h2 className="text-sm font-medium text-text-primary">Providers</h2>
        {loading && (
          <svg className="h-3 w-3 animate-spin text-text-muted" fill="none" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
          </svg>
        )}
      </div>
      <p className="mt-1 text-xs text-text-secondary">
        AI model providers. Connect an API key in the Prism console.
      </p>
      {error && <p className="mt-2 text-xs text-status-error">{error}</p>}

      <div className="mt-4 space-y-2">
        {providers.map((p) => (
          <ProviderCard
            key={p.key}
            provider={p}
            expanded={expanded === p.key}
            onToggle={() => setExpanded(expanded === p.key ? null : p.key)}
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
  const status = provider.ready
    ? "Ready"
    : provider.configured && provider.error
      ? "Error"
      : provider.configured
        ? "Connected"
        : "Setup needed";

  const dotColor = provider.ready
    ? "bg-status-success"
    : provider.configured && provider.error
      ? "bg-status-error"
      : "bg-text-muted";

  const textColor = provider.ready
    ? "text-status-success"
    : provider.configured && provider.error
      ? "text-status-error"
      : "text-text-muted";

  return (
    <div className="overflow-hidden rounded-lg border border-border-default bg-surface-raised">
      <button
        onClick={onToggle}
        className="flex w-full items-center gap-3 px-4 py-3 text-left"
      >
        <span className={`h-2 w-2 shrink-0 rounded-full ${dotColor}`} />
        <div className="flex-1 min-w-0">
          <span className="text-sm font-medium text-text-primary">
            {provider.label}
          </span>
        </div>
        <span className={`shrink-0 text-xs ${textColor}`}>{status}</span>
        <ChevronIcon expanded={expanded} />
      </button>

      {expanded && (
        <div className="border-t border-border-default px-4 py-3">
          {provider.ready ? (
            <p className="text-xs text-text-muted">
              {provider.models.length} model
              {provider.models.length === 1 ? "" : "s"} available.
            </p>
          ) : (
            <div>
              <p className="text-xs text-text-muted">
                Connect your {provider.label} API key in the Prism console
                (Components page), then reload.
              </p>
              <a
                href={provider.keyUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="mt-2 inline-block text-xs text-accent-primary hover:text-accent-hover"
                onClick={(e) => {
                  e.preventDefault();
                  host.openUrl(provider.keyUrl);
                }}
              >
                Get your API key &rarr;
              </a>
            </div>
          )}
          {provider.error && (
            <p className="mt-2 text-xs text-status-error">{provider.error}</p>
          )}
        </div>
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

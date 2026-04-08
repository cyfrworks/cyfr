import { useState, useEffect } from "react";
import { useConnectionStore } from "../../state/connection-store";
import * as cyfrMcp from "../../api/cyfr-mcp";

async function getClient() {
  return useConnectionStore.getState().getMcpClient();
}

interface SecretInfo {
  name: string;
  description?: string;
  required: boolean;
  already_set: boolean;
  already_granted: boolean;
  is_url?: boolean;
}

interface SetupPlan {
  component_ref: string;
  description?: string;
  type: string;
  secrets: SecretInfo[];
  policy_recommended: Record<string, unknown>;
  policy_current: Record<string, unknown>;
  configurable_fields: string[];
  setup: Record<string, unknown>;
  ready: boolean;
}

// Policy field labels for display
const POLICY_LABELS: Record<string, string> = {
  allowed_domains: "Allowed Domains",
  allowed_methods: "Allowed Methods",
  allowed_private_ips: "Allowed Private IPs",
  allowed_paths: "Allowed Paths",
  allowed_actions: "Allowed Actions",
  allowed_tools: "Allowed Tools",
  rate_limit: "Rate Limit",
  timeout: "Timeout",
  max_memory_bytes: "Max Memory",
  max_request_size: "Max Request Size",
  max_response_size: "Max Response Size",
  batch_timeout: "Batch Timeout",
  max_concurrent_tasks: "Max Concurrent Tasks",
};

interface SetupFormProps {
  componentRef: string;
  onComplete: () => void;
  onDismiss: () => void;
}

export function SetupForm({ componentRef, onComplete, onDismiss }: SetupFormProps) {
  const [plan, setPlan] = useState<SetupPlan | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [secretValues, setSecretValues] = useState<Record<string, string>>({});
  const [secretGrants, setSecretGrants] = useState<Record<string, boolean>>({});
  const [policyValues, setPolicyValues] = useState<Record<string, string>>({});
  const [showPolicy, setShowPolicy] = useState(false);

  // Fetch setup plan
  useEffect(() => {
    (async () => {
      try {
        const client = await getClient();
        const p = (await cyfrMcp.setupPlan(client, componentRef)) as unknown as SetupPlan;
        if (p) {
          setPlan(p);

          // Pre-fill secret inputs
          const grants: Record<string, boolean> = {};
          const values: Record<string, string> = {};
          for (const s of p.secrets ?? []) {
            if (s.already_set) {
              grants[s.name] = s.already_granted;
            } else {
              values[s.name] = "";
            }
          }
          setSecretGrants(grants);
          setSecretValues(values);

          // Pre-fill policy inputs from current → manifest → recommended (highest priority)
          const manifestPolicy = (p.setup as Record<string, unknown>)?.policy as Record<string, unknown> ?? {};
          const recommended = p.policy_recommended ?? {};
          const current = p.policy_current ?? {};
          const merged = { ...current, ...manifestPolicy, ...recommended };
          const configurable = p.configurable_fields ?? [];

          const pv: Record<string, string> = {};
          for (const field of configurable) {
            const value = merged[field];
            if (value != null) {
              pv[field] = typeof value === "string" ? value : JSON.stringify(value);
            } else {
              pv[field] = "";
            }
          }
          setPolicyValues(pv);
        }
      } catch {
        setError("Failed to load setup plan");
      }
      setLoading(false);
    })();
  }, [componentRef]);

  const handleSubmit = async () => {
    if (!plan) return;
    setSaving(true);
    setError(null);

    const errors: string[] = [];
    const nameRef = componentRef.replace(/:[^:]+$/, "");
    const client = await getClient();

    // Save secrets
    for (const s of plan.secrets ?? []) {
      if (s.already_set) {
        if (secretGrants[s.name]) {
          try {
            await cyfrMcp.grantSecret(client, nameRef, s.name);
          } catch {
            errors.push(`${s.name} grant failed`);
          }
        }
      } else {
        const value = (secretValues[s.name] ?? "").trim();
        if (value) {
          try {
            await cyfrMcp.setSecret(client, s.name, value);
            await cyfrMcp.grantSecret(client, nameRef, s.name);
          } catch {
            errors.push(`${s.name} failed`);
          }
        }
      }
    }

    // Save policy fields
    for (const [field, value] of Object.entries(policyValues)) {
      if (!value.trim()) continue;
      try {
        await cyfrMcp.updatePolicyField(client, nameRef, field, value);
      } catch {
        errors.push(`Policy ${field} failed`);
      }
    }

    if (errors.length > 0) {
      setError(`Errors: ${errors.join(", ")}`);
    }

    setSaving(false);
    onComplete();
  };

  if (loading) {
    return (
      <div className="my-3 rounded-lg border border-accent-primary/30 bg-accent-primary/5 p-4">
        <p className="text-sm text-text-muted">Loading setup plan...</p>
      </div>
    );
  }

  if (!plan) {
    return (
      <div className="my-3 rounded-lg border border-status-error/30 bg-status-error/5 p-4">
        <p className="text-sm text-status-error">{error ?? "Failed to load setup"}</p>
        <button onClick={onDismiss} className="mt-2 text-xs text-text-muted hover:text-text-secondary">
          Dismiss
        </button>
      </div>
    );
  }

  const componentName = componentRef.split(".").pop()?.split(":")[0] ?? componentRef;
  const hasSecrets = (plan.secrets ?? []).length > 0;
  const policyFields = Object.keys(policyValues);
  const hasPolicies = policyFields.length > 0;

  return (
    <div className="my-3 rounded-lg border border-accent-primary/30 bg-surface-raised p-4">
      {/* Header */}
      <div className="mb-3">
        <h3 className="text-sm font-medium text-text-primary">
          Setup required: {componentName}
        </h3>
        {plan.description && (
          <p className="mt-0.5 text-xs text-text-muted">{plan.description}</p>
        )}
      </div>

      {/* Secrets */}
      {hasSecrets && (
        <div className="space-y-3">
          <div className="text-xs font-medium text-text-secondary">Secrets</div>
          {plan.secrets.map((s) => (
            <div key={s.name}>
              {s.already_set ? (
                <label className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    checked={secretGrants[s.name] ?? false}
                    onChange={(e) =>
                      setSecretGrants((prev) => ({
                        ...prev,
                        [s.name]: e.target.checked,
                      }))
                    }
                    className="rounded border-border-default"
                  />
                  <span className="text-xs text-text-secondary">
                    Grant access to <code className="text-accent-primary">{s.name}</code> (already set)
                  </span>
                </label>
              ) : (
                <div>
                  <label className="mb-1 block text-xs text-text-muted">
                    {s.name}
                    {s.required && <span className="ml-1 text-status-error">*</span>}
                    {s.description && (
                      <span className="ml-1 font-normal text-text-muted">— {s.description}</span>
                    )}
                  </label>
                  <input
                    type={s.is_url ? "text" : "password"}
                    value={secretValues[s.name] ?? ""}
                    onChange={(e) =>
                      setSecretValues((prev) => ({
                        ...prev,
                        [s.name]: e.target.value,
                      }))
                    }
                    placeholder={s.is_url ? "https://..." : s.name}
                    className="w-full rounded-lg border border-border-default bg-surface-base px-3 py-2 font-mono text-xs text-text-primary placeholder-text-muted outline-none focus:border-border-focus"
                  />
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {/* Policy Fields */}
      {hasPolicies && (
        <div className={hasSecrets ? "mt-4" : ""}>
          <button
            onClick={() => setShowPolicy(!showPolicy)}
            className="flex items-center gap-1 text-xs text-text-secondary hover:text-text-primary"
          >
            <svg
              className={`h-3 w-3 transition-transform ${showPolicy ? "rotate-90" : ""}`}
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              strokeWidth={2}
            >
              <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 4.5l7.5 7.5-7.5 7.5" />
            </svg>
            Policy ({policyFields.length} fields, pre-filled with recommended)
          </button>

          {showPolicy && (
            <div className="mt-2 space-y-2">
              {policyFields.map((field) => (
                <div key={field}>
                  <label className="mb-0.5 block text-xs text-text-muted">
                    {POLICY_LABELS[field] ?? field}
                  </label>
                  <input
                    type="text"
                    value={policyValues[field] ?? ""}
                    onChange={(e) =>
                      setPolicyValues((prev) => ({
                        ...prev,
                        [field]: e.target.value,
                      }))
                    }
                    placeholder={field}
                    className="w-full rounded-lg border border-border-default bg-surface-base px-3 py-1.5 font-mono text-xs text-text-primary placeholder-text-muted outline-none focus:border-border-focus"
                  />
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* Actions */}
      <div className="mt-3 flex items-center gap-2">
        <button
          onClick={handleSubmit}
          disabled={saving}
          className="btn-primary text-xs"
        >
          {saving ? "Setting up..." : "Complete Setup"}
        </button>
        <button
          onClick={onDismiss}
          className="text-xs text-text-muted hover:text-text-secondary"
        >
          Skip
        </button>
      </div>

      {error && (
        <p className="mt-2 text-xs text-status-error">{error}</p>
      )}
    </div>
  );
}

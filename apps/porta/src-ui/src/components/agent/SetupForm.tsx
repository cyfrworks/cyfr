import { useState, useEffect } from "react";
import { useConnectionStore } from "../../state/connection-store";
import * as cyfrMcp from "../../api/cyfr-mcp";

async function getClient() {
  return useConnectionStore.getState().getMcpClient();
}

interface DeclaredNeed {
  name: string;
  kind: string;
  qualifier: string;
  reason?: string | null;
  fields: string[];
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
  description?: string;
  type: string;
  needs: DeclaredNeed[];
  consent: ConsentSection | null;
  ready: boolean;
}

interface SetupFormProps {
  componentRef: string;
  onComplete: () => void;
  onDismiss: () => void;
}

/**
 * Read-only view of a component's needs and consent state. Granting is a
 * consent decision made in the Prism console (the consent sheet); Porta
 * shows what is bound, what is missing, and where to finish the walk.
 */
export function SetupForm({
  componentRef,
  onComplete,
  onDismiss,
}: SetupFormProps) {
  const [plan, setPlan] = useState<SetupPlan | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const client = await getClient();
        const p = (await cyfrMcp.setupPlan(
          client,
          componentRef,
        )) as unknown as SetupPlan;
        setPlan(p ?? null);
        if (!p) setError("Setup plan unavailable");
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed to load setup plan");
      }
      setLoading(false);
    })();
  }, [componentRef]);

  if (loading) {
    return (
      <div className="my-3 rounded-lg border border-accent-primary/30 bg-accent-primary/5 p-4">
        <p className="text-sm text-text-muted">Loading setup state...</p>
      </div>
    );
  }

  if (!plan) {
    return (
      <div className="my-3 rounded-lg border border-status-error/30 bg-status-error/5 p-4">
        <p className="text-sm text-status-error">
          {error ?? "Failed to load setup state"}
        </p>
        <button
          onClick={onDismiss}
          className="mt-2 text-xs text-text-muted hover:text-text-secondary"
        >
          Dismiss
        </button>
      </div>
    );
  }

  const componentName =
    componentRef.split(".").pop()?.split(":")[0] ?? componentRef;
  const consentNeeds = plan.consent?.needs ?? [];

  const needRow = (
    label: string,
    satisfied: boolean,
    detail?: string | null,
  ) => (
    <div key={label} className="flex items-start gap-2">
      <span
        className={`mt-1 inline-block h-2 w-2 shrink-0 rounded-full ${
          satisfied ? "bg-status-success" : "bg-status-error"
        }`}
      />
      <div>
        <span className="text-xs text-text-secondary">
          <code className="text-accent-primary">{label}</code>
        </span>
        {detail && <p className="text-xs text-text-muted">{detail}</p>}
      </div>
    </div>
  );

  return (
    <div className="my-3 rounded-lg border border-accent-primary/30 bg-surface-raised p-4">
      <div className="mb-3">
        <h3 className="text-sm font-medium text-text-primary">
          {plan.ready ? "Ready" : "Setup required"}: {componentName}
        </h3>
        {plan.description && (
          <p className="mt-0.5 text-xs text-text-muted">{plan.description}</p>
        )}
      </div>

      {consentNeeds.length > 0 ? (
        <div className="space-y-2">
          {consentNeeds.map((n, i) =>
            needRow(
              n.need ?? n.entry_id ?? `binding ${i + 1}`,
              n.satisfied,
              n.detail,
            ),
          )}
        </div>
      ) : (
        plan.needs.length > 0 && (
          <div className="space-y-2">
            {plan.needs.map((n) =>
              needRow(
                n.name,
                plan.ready,
                n.reason ?? (n.required ? "required" : "optional"),
              ),
            )}
          </div>
        )
      )}

      {!plan.ready && (
        <p className="mt-3 text-xs text-text-muted">
          Grant connections in the Prism console (Components page), then retry
          here.
        </p>
      )}

      <div className="mt-3 flex items-center gap-2">
        <button onClick={onComplete} className="btn-primary text-xs">
          Done
        </button>
        <button
          onClick={onDismiss}
          className="text-xs text-text-muted hover:text-text-secondary"
        >
          Skip
        </button>
      </div>
    </div>
  );
}

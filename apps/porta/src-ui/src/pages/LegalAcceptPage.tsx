import { FormEvent, useEffect, useState } from "react";
import { useAuthStore } from "../state/auth-store";
import { useConnectionStore } from "../state/connection-store";
import * as cyfrMcp from "../api/cyfr-mcp";

/**
 * Policy-acceptance gate (R1.11 — registry_moderation_plan.md §3.12).
 *
 * Renders the bundled policy markdown for read + clickwrap, then calls
 * registry.legal-accept on submit. Fed by `legalAcceptGate` in auth-store —
 * the gate is set when `submitPersonalClaim` traps a 412
 * POLICY_ACCEPTANCE_REQUIRED from cyfr.run.
 *
 * On success the gate transitions back to `claimGate` (carrying the same
 * one-shot OAuth access_token), so the user lands on ClaimNamespacePage
 * with the slug they originally typed pre-filled.
 */
export default function LegalAcceptPage() {
  const gate = useAuthStore((s) => s.legalAcceptGate);
  const submit = useAuthStore((s) => s.submitLegalAccept);
  const dismiss = useAuthStore((s) => s.dismissLegalAcceptGate);
  const logout = useAuthStore((s) => s.logout);
  const getClient = useConnectionStore((s) => s.getMcpClient);

  // Per-policy markdown bodies, fetched lazily after mount. Keyed by name.
  const [bodies, setBodies] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [activeTab, setActiveTab] = useState<string>(
    gate.policies[0]?.name ?? "",
  );
  const [acks, setAcks] = useState<Record<string, boolean>>({});
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      if (!gate.policies.length) return;
      setLoading(true);
      try {
        const client = await getClient();
        const entries = await Promise.all(
          gate.policies.map(async (p) => {
            try {
              const body = await cyfrMcp.registryGetLegalPage(client, p.name);
              return [p.name, body.content_markdown] as const;
            } catch {
              return [p.name, `_(failed to load ${p.name})_`] as const;
            }
          }),
        );
        if (cancelled) return;
        setBodies(Object.fromEntries(entries));
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, [gate.policies, getClient]);

  const allAcked =
    gate.policies.length > 0 && gate.policies.every((p) => acks[p.name]);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!allAcked || submitting) return;

    setError(null);
    setSubmitting(true);
    try {
      const outcome = await submit();
      switch (outcome) {
        case "ok":
          // Gate transitions to claimGate; App.tsx routes to ClaimNamespacePage.
          return;
        case "version_mismatch":
          setError(
            "Policies updated while you were reading. The new version has " +
              "been loaded — please review and re-tick the boxes.",
          );
          setAcks({});
          break;
        case "reauth":
          await logout();
          return;
        case "error":
        default:
          setError("Couldn't record acceptance. Please try again.");
      }
    } finally {
      setSubmitting(false);
    }
  };

  if (!gate.needed) {
    return null;
  }

  return (
    <div className="flex h-full items-center justify-center bg-surface-base p-6">
      <div className="w-full max-w-3xl space-y-4">
        <div>
          <h1 className="text-2xl font-semibold text-text-primary">
            Accept policies
          </h1>
          <p className="mt-2 text-sm text-text-secondary">
            Before publishing on cyfr.run, please review and accept the
            policies below. You're accepting bundle version{" "}
            <code>{gate.policyVersion}</code>.
          </p>
        </div>

        <div className="flex gap-1 flex-wrap border-b border-surface-border">
          {gate.policies.map((p) => (
            <button
              key={p.name}
              type="button"
              onClick={() => setActiveTab(p.name)}
              className={
                "px-3 py-1.5 text-xs border-t border-l border-r " +
                (p.name === activeTab
                  ? "bg-surface-raised text-text-primary border-surface-border font-semibold"
                  : "bg-surface-base text-text-secondary border-transparent hover:text-text-primary")
              }
            >
              {p.title}
            </button>
          ))}
        </div>

        <div className="rounded-md border border-surface-border bg-surface-raised p-4 max-h-[28rem] overflow-auto">
          {loading ? (
            <p className="text-sm text-text-muted">Loading…</p>
          ) : (
            <pre className="whitespace-pre-wrap font-mono text-xs text-text-primary leading-relaxed">
              {bodies[activeTab] || "(no content)"}
            </pre>
          )}
        </div>

        <form onSubmit={handleSubmit} className="space-y-3">
          <fieldset className="rounded-md border border-surface-border p-3">
            <legend className="px-2 text-sm font-medium text-text-primary">
              Acknowledgements
            </legend>
            {gate.policies.map((p) => (
              <label
                key={p.name}
                className="flex items-start gap-2 py-1 text-sm text-text-secondary"
              >
                <input
                  type="checkbox"
                  checked={!!acks[p.name]}
                  onChange={(e) =>
                    setAcks((prev) => ({ ...prev, [p.name]: e.target.checked }))
                  }
                  className="mt-1"
                />
                <span>I have read and agree to the {p.title}.</span>
              </label>
            ))}
          </fieldset>

          {error && (
            <div className="rounded-md border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-400">
              {error}
            </div>
          )}

          <div className="flex gap-2">
            <button
              type="submit"
              disabled={submitting || !allAcked}
              className="flex-1 rounded-md bg-accent-primary px-4 py-2 text-sm font-medium text-white hover:bg-accent-hover disabled:opacity-50"
            >
              {submitting ? "Recording…" : "Accept and continue"}
            </button>
            <button
              type="button"
              onClick={dismiss}
              disabled={submitting}
              className="rounded-md border border-surface-border px-4 py-2 text-sm text-text-secondary hover:bg-surface-raised disabled:opacity-50"
              title="Skip for now — you won't be able to claim a namespace until you accept."
            >
              Skip
            </button>
          </div>
        </form>

        <div className="text-center text-xs text-text-muted">
          Something wrong?{" "}
          <button
            type="button"
            onClick={() => {
              void logout();
            }}
            className="underline hover:text-text-secondary"
          >
            Sign out and try again
          </button>
        </div>
      </div>
    </div>
  );
}

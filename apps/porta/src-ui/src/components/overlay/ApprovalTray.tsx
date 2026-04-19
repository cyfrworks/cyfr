import { useState } from "react";
import {
  useApprovalStore,
  type ApprovalRisk,
  type PendingApproval,
} from "../../state/approval-store";

/**
 * Renders any pending approval cards. Sits inside the AQUA overlay next to
 * the setup rail; hides itself entirely when nothing is pending so it doesn't
 * eat screen real estate.
 */
export function ApprovalTray() {
  const pending = useApprovalStore((s) => s.pending);

  if (pending.length === 0) return null;

  return (
    <aside
      className="flex w-80 shrink-0 flex-col border-l border-border-default bg-surface-base"
      aria-label="Pending approvals"
    >
      <header className="flex items-center justify-between border-b border-border-default px-4 py-2">
        <div className="text-sm font-semibold text-text-primary">
          Needs your approval
        </div>
        {pending.length > 1 && (
          <span className="rounded-full bg-accent-primary/15 px-2 py-0.5 font-mono text-[10px] font-medium text-accent-primary">
            {pending.length}
          </span>
        )}
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto p-3">
        <ul className="space-y-3">
          {pending.map((approval) => (
            <li key={approval.id}>
              <ApprovalCard approval={approval} />
            </li>
          ))}
        </ul>
      </div>
    </aside>
  );
}

const RISK_BADGE: Record<ApprovalRisk, { label: string; className: string }> = {
  low: { label: "Low risk", className: "bg-green-500/15 text-green-500" },
  medium: { label: "Caution", className: "bg-yellow-500/15 text-yellow-500" },
  high: { label: "High risk", className: "bg-red-500/20 text-red-500" },
};

function ApprovalCard({ approval }: { approval: PendingApproval }) {
  const accept = useApprovalStore((s) => s.accept);
  const reject = useApprovalStore((s) => s.reject);
  const [showReason, setShowReason] = useState(false);
  const [reason, setReason] = useState("");

  const risk = RISK_BADGE[approval.risk];

  return (
    <div className="rounded-lg border border-border-default bg-surface-raised p-3">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0 flex-1">
          <div className="text-sm font-medium text-text-primary">
            {approval.title}
          </div>
          <div className="mt-1 text-xs text-text-secondary">
            {approval.summary}
          </div>
        </div>
        <span
          className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium ${risk.className}`}
        >
          {risk.label}
        </span>
      </div>

      <div className="mt-2 rounded bg-surface-base px-2 py-1 font-mono text-[10px] text-text-muted">
        {approval.actionDescription}
      </div>

      <div className="mt-3 flex items-center justify-end gap-2">
        {!showReason ? (
          <>
            <button
              onClick={() => setShowReason(true)}
              className="rounded border border-border-default px-3 py-1 text-xs text-text-secondary transition-colors hover:text-text-primary"
            >
              Decline
            </button>
            <button
              onClick={() => accept(approval.id)}
              className="rounded bg-accent-primary px-3 py-1 text-xs font-medium text-white transition-colors hover:bg-accent-hover"
            >
              Approve
            </button>
          </>
        ) : (
          <div className="flex w-full flex-col gap-2">
            <input
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="Reason (optional)"
              className="rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary focus:border-accent-primary focus:outline-none"
              autoFocus
            />
            <div className="flex justify-end gap-2">
              <button
                onClick={() => {
                  setShowReason(false);
                  setReason("");
                }}
                className="rounded px-3 py-1 text-xs text-text-muted hover:text-text-secondary"
              >
                Back
              </button>
              <button
                onClick={() => reject(approval.id, reason.trim() || undefined)}
                className="rounded bg-status-error px-3 py-1 text-xs font-medium text-white transition-colors hover:bg-status-error/80"
              >
                Decline
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

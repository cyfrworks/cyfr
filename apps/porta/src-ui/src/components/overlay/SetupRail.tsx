import { useAgentStore } from "../../state/agent-store";
import { SetupFormSlot } from "../agent/SetupFormSlot";

/**
 * Right-rail container for setup forms. Renders the currently-active setup
 * form (via the existing SetupFormSlot portal), plus the queue count and a
 * list of dismissed setups the user may resume.
 *
 * Hidden when nothing is pending or waiting.
 */
export function SetupRail() {
  const pendingSetupRef = useAgentStore((s) => s.pendingSetupRef);
  const setupQueue = useAgentStore((s) => s.setupQueue);
  const dismissedSetups = useAgentStore((s) => s.dismissedSetups);
  const resumeDismissedSetup = useAgentStore((s) => s.resumeDismissedSetup);

  const hasContent =
    pendingSetupRef !== null ||
    setupQueue.length > 0 ||
    dismissedSetups.length > 0;

  if (!hasContent) return null;

  return (
    <aside
      className="flex w-80 shrink-0 flex-col border-l border-border-default bg-surface-base"
      aria-label="Setup rail"
    >
      <header className="flex items-center justify-between border-b border-border-default px-4 py-2">
        <div className="min-w-0">
          <div className="text-sm font-semibold text-text-primary">Setup</div>
          <div className="text-[11px] text-text-muted">
            {pendingSetupRef
              ? `Finish setting up ${truncate(pendingSetupRef, 32)}`
              : dismissedSetups.length > 0
                ? `${dismissedSetups.length} waiting`
                : "No setup needed"}
          </div>
        </div>
        {setupQueue.length > 0 && (
          <span
            className="rounded-full bg-accent-primary/15 px-2 py-0.5 font-mono text-[10px] font-medium text-accent-primary"
            title={`${setupQueue.length} more queued`}
          >
            +{setupQueue.length}
          </span>
        )}
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto">
        {/* Portal target for the active setup form. */}
        <div className="p-3">
          <SetupFormSlot />
        </div>

        {dismissedSetups.length > 0 && (
          <section className="border-t border-border-default px-3 py-3">
            <div className="mb-2 text-[11px] font-medium uppercase tracking-wide text-text-muted">
              Waiting
            </div>
            <ul className="space-y-1">
              {dismissedSetups.map((s) => (
                <li
                  key={s.componentRef}
                  className="flex items-center justify-between gap-2 rounded-md bg-surface-raised px-2 py-1.5"
                >
                  <span
                    className="truncate text-xs text-text-secondary"
                    title={s.componentRef}
                  >
                    {truncate(s.componentRef, 28)}
                  </span>
                  <button
                    onClick={() => resumeDismissedSetup(s.componentRef)}
                    className="shrink-0 rounded border border-border-default px-2 py-0.5 text-[10px] text-text-secondary transition-colors hover:bg-accent-primary/10 hover:text-accent-primary"
                  >
                    Resume
                  </button>
                </li>
              ))}
            </ul>
          </section>
        )}
      </div>
    </aside>
  );
}

function truncate(s: string, n: number): string {
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

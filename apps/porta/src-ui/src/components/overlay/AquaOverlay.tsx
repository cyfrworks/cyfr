import { lazy, Suspense, useEffect } from "react";
import { useOverlayStore, type OverlayState } from "../../state/overlay-store";
import { useAgentStore } from "../../state/agent-store";
import { useApprovalStore } from "../../state/approval-store";
import { SetupRail } from "./SetupRail";
import { ApprovalTray } from "./ApprovalTray";

const AskPage = lazy(() => import("../../pages/AskPage"));

/**
 * Height per overlay state. `peek` reveals just enough for the composer, `half`
 * gives a working conversation view, `full` leaves a thin strip at top so the
 * user can still see they haven't left the underlying page.
 */
const HEIGHT_CLASS: Record<Exclude<OverlayState, "closed">, string> = {
  peek: "h-[140px]",
  half: "h-[55vh]",
  full: "h-[calc(100vh-2.5rem)]",
};

const SIZE_STATES: Exclude<OverlayState, "closed">[] = ["peek", "half", "full"];

export function AquaOverlay() {
  const state = useOverlayStore((s) => s.state);
  const close = useOverlayStore((s) => s.close);
  const open = useOverlayStore((s) => s.open);
  const setOverlayState = useOverlayStore((s) => s.setOverlayState);
  const pendingSetupRef = useAgentStore((s) => s.pendingSetupRef);
  const pendingApprovalCount = useApprovalStore((s) => s.pending.length);

  const isOpen = state !== "closed";
  const showBackdrop = state === "half" || state === "full";

  // Escape closes the overlay (when open).
  useEffect(() => {
    if (!isOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        close();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [isOpen, close]);

  // Auto-open overlay (to half) when a new setup becomes active or an
  // approval request appears. We deliberately do NOT subscribe to `state`
  // here: if the user closes the overlay while pending work is still
  // outstanding, re-running this effect on every state change would slam
  // the sheet back open and swallow the close. Only react when the pending
  // values themselves change.
  useEffect(() => {
    if (pendingSetupRef || pendingApprovalCount > 0) {
      if (useOverlayStore.getState().state === "closed") open("half");
    }
  }, [pendingSetupRef, pendingApprovalCount, open]);

  return (
    <>
      {/* Backdrop: darkens the underlying main-content area (but not the sidebar)
       *  when the overlay is at half/full. Clicking dismisses. */}
      <div
        className={`fixed inset-y-0 right-0 left-56 z-40 bg-black/30 transition-opacity duration-200 ${
          showBackdrop ? "opacity-100" : "pointer-events-none opacity-0"
        }`}
        onClick={close}
        aria-hidden="true"
      />

      {/* Sheet. Translated off-screen when closed. */}
      <aside
        className={`fixed bottom-0 right-0 left-56 z-50 flex flex-col overflow-hidden rounded-t-2xl border-t border-x border-border-default bg-surface-base shadow-2xl transition-all duration-200 ease-out ${
          isOpen ? HEIGHT_CLASS[state as Exclude<OverlayState, "closed">] : "h-0 translate-y-full"
        }`}
        aria-label="AQUA assistant"
        aria-hidden={!isOpen}
      >
        {/* Grip / controls bar. Thin so it doesn't compete with AskPage's own header. */}
        <div className="flex shrink-0 items-center justify-between border-b border-border-default px-3 py-1.5">
          {/* Drag-handle affordance (cosmetic for now; drag-to-resize lands later). */}
          <div className="flex flex-1 justify-center">
            <div className="h-1 w-10 rounded-full bg-text-muted/25" />
          </div>

          {/* Size toggles */}
          <div className="flex items-center gap-1 text-text-muted">
            {SIZE_STATES.map((size) => (
              <button
                key={size}
                onClick={() => setOverlayState(size)}
                title={size}
                aria-label={`Set overlay size to ${size}`}
                aria-pressed={state === size}
                className={`h-1.5 w-1.5 rounded-full transition-all ${
                  state === size
                    ? "w-5 bg-accent-primary"
                    : "bg-text-muted/30 hover:bg-text-muted/50"
                }`}
              />
            ))}
            <button
              onClick={close}
              title="Close (Esc)"
              aria-label="Close overlay"
              className="ml-2 rounded p-1 text-text-muted transition-colors hover:bg-surface-raised hover:text-text-secondary"
            >
              <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        </div>

        {/* Body: AskPage + optional right-side setup rail. Kept mounted even
         *  when `closed` so streaming state and conversation continuity
         *  survive open/close. */}
        <div className="flex min-h-0 flex-1">
          <div className="min-w-0 flex-1">
            <Suspense fallback={null}>
              <AskPage />
            </Suspense>
          </div>
          <ApprovalTray />
          <SetupRail />
        </div>
      </aside>
    </>
  );
}

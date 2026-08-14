import { useState, useRef, useEffect } from "react";
import { useActivityStore, type ActivityEntry } from "../../state/activity-store";
import type { Intent } from "../../harness/aqua-actions-parser";

/**
 * Small collapsible button in the sidebar that surfaces what the shell has
 * done on AQUA's behalf — dispatched intents, parse drops, errors. Clicking
 * opens a popover listing recent entries.
 */
export function ActivityLane() {
  const [open, setOpen] = useState(false);
  const entries = useActivityStore((s) => s.entries);
  const unseen = useActivityStore((s) => s.unseen);
  const markSeen = useActivityStore((s) => s.markSeen);
  const clear = useActivityStore((s) => s.clear);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    markSeen();
    const onClick = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    window.addEventListener("mousedown", onClick);
    return () => window.removeEventListener("mousedown", onClick);
  }, [open, markSeen]);

  return (
    <div ref={containerRef} className="relative">
      <button
        onClick={() => setOpen((o) => !o)}
        className={`flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2 text-sm transition-colors ${
          open
            ? "bg-surface-raised text-text-primary"
            : "text-text-secondary hover:bg-surface-raised hover:text-text-primary"
        }`}
        aria-expanded={open}
      >
        <span className="flex items-center gap-3">
          <ActivityIcon />
          Activity
        </span>
        {unseen > 0 && (
          <span className="rounded-full bg-accent-primary/20 px-1.5 py-0.5 font-mono text-[10px] font-medium text-accent-primary">
            {unseen}
          </span>
        )}
      </button>

      {open && (
        <div className="absolute bottom-full left-0 z-50 mb-1 w-80 rounded-lg border border-border-default bg-surface-raised shadow-xl">
          <div className="flex items-center justify-between border-b border-border-default px-3 py-2">
            <span className="text-xs font-medium text-text-primary">Recent activity</span>
            {entries.length > 0 && (
              <button
                onClick={clear}
                className="text-[10px] text-text-muted hover:text-text-secondary"
              >
                Clear
              </button>
            )}
          </div>

          <div className="max-h-80 overflow-y-auto">
            {entries.length === 0 ? (
              <div className="px-3 py-6 text-center text-xs text-text-muted">
                No activity yet.
              </div>
            ) : (
              <ul className="divide-y divide-border-default">
                {entries.map((entry) => (
                  <li key={entry.id} className="px-3 py-2">
                    <EntryRow entry={entry} />
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function EntryRow({ entry }: { entry: ActivityEntry }) {
  const ago = timeAgo(entry.timestamp);
  if (entry.kind === "dispatched") {
    return (
      <div className="flex items-start justify-between gap-2">
        <span className="text-xs text-text-secondary">{describeIntent(entry.intent)}</span>
        <span className="shrink-0 text-[10px] text-text-muted">{ago}</span>
      </div>
    );
  }
  if (entry.kind === "dispatch_error") {
    return (
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="truncate text-xs text-status-error">
            Failed: {describeIntent(entry.intent)}
          </div>
          <div className="truncate text-[10px] text-text-muted">{entry.error}</div>
        </div>
        <span className="shrink-0 text-[10px] text-text-muted">{ago}</span>
      </div>
    );
  }
  return (
    <div className="flex items-start justify-between gap-2">
      <div className="min-w-0">
        <div className="text-xs text-status-warning">Dropped action</div>
        <div className="truncate text-[10px] text-text-muted">{entry.reason}</div>
      </div>
      <span className="shrink-0 text-[10px] text-text-muted">{ago}</span>
    </div>
  );
}

function describeIntent(intent: Intent): string {
  switch (intent.kind) {
    case "ui.navigate":
      return `Navigated to ${intent.path}`;
    case "ui.overlay.open":
      return `Opened overlay${intent.state ? ` (${intent.state})` : ""}`;
    case "ui.overlay.close":
      return "Closed overlay";
    case "ui.overlay.focus_input":
      return "Focused composer";
    case "ui.tincture.open":
      return `Opened ${intent.publisher}.${intent.name}`;
    case "ui.tincture.close":
      return `Closed ${intent.name}`;
    case "ui.tincture.focus":
      return `Focused ${intent.name}`;
    case "ui.schedules.focus":
      return `Focused schedule ${intent.id}`;
    case "ui.components.focus":
      return `Focused ${intent.ref}`;
    case "ui.mcp.focus":
      return `Focused ${intent.server}`;
    case "ui.copy_clipboard":
      return `Copied ${intent.text.length} chars to clipboard`;
    case "ui.request_approval":
      return `Requested approval: ${intent.title}`;
  }
}

function timeAgo(ts: number): string {
  const delta = Math.max(0, Date.now() - ts);
  const s = Math.floor(delta / 1000);
  if (s < 5) return "just now";
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  return `${h}h ago`;
}

function ActivityIcon() {
  return (
    <svg
      className="h-4 w-4"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={1.5}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M3.75 3v11.25A2.25 2.25 0 006 16.5h12M3.75 3h-1.5m1.5 0h16.5m0 0h1.5m-1.5 0v11.25A2.25 2.25 0 0118 16.5h-2.25m-7.5 0h7.5m-7.5 0l-1 3m8.5-3l1 3m0 0l.5 1.5m-.5-1.5h-9.5m0 0l-.5 1.5"
      />
    </svg>
  );
}

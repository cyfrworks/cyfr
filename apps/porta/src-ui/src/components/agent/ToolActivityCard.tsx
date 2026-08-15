import { useState } from "react";
import type { ToolEntry, SubEvent } from "../../state/agent-store";
import { Markdown } from "../common/Markdown";

export function ToolActivityCard({ entry }: { entry: ToolEntry }) {
  const hasSubEvents = entry.subEvents.length > 0;
  const autoExpand = hasSubEvents && entry.status === "running";
  const [manualToggle, setManualToggle] = useState<boolean | null>(null);
  const expanded = manualToggle ?? autoExpand;

  return (
    <div className="my-1.5 rounded-lg border border-border-default bg-surface-raised overflow-hidden">
      <button
        type="button"
        onClick={() => setManualToggle(expanded ? false : true)}
        className="flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-surface-base transition-colors"
      >
        <StatusIcon status={entry.status} />
        <span className="text-xs font-medium text-text-secondary">
          {entry.tool}
        </span>
        {entry.preview && (
          <span className="ml-auto truncate text-xs text-text-muted max-w-[200px]">
            {entry.preview}
          </span>
        )}
        <ChevronIcon expanded={expanded} />
      </button>

      {expanded && (
        <div
          className="border-t border-border-default px-3 py-2"
          onClick={(e) => e.stopPropagation()}
        >
          {/* Sub-agent activity — shown first when present */}
          {hasSubEvents && (
            <div className="mb-2 space-y-0.5">
              {entry.subEvents.map((se, i) => (
                <SubEventView key={i} event={se} />
              ))}
            </div>
          )}
          {entry.input != null && (
            <details className="mb-2">
              <summary className="cursor-pointer text-xs text-text-muted hover:text-text-secondary">
                input
              </summary>
              <pre className="mt-1 overflow-x-auto rounded bg-surface-base p-2 text-xs font-mono text-text-secondary">
                {typeof entry.input === "string"
                  ? entry.input
                  : JSON.stringify(entry.input, null, 2)}
              </pre>
            </details>
          )}
          {entry.preview && (
            <details>
              <summary className="cursor-pointer text-xs text-text-muted hover:text-text-secondary">
                output
              </summary>
              <pre className="mt-1 max-h-40 overflow-auto rounded bg-surface-base p-2 text-xs font-mono text-text-secondary whitespace-pre-wrap">
                {entry.preview}
              </pre>
            </details>
          )}
        </div>
      )}
    </div>
  );
}

function SubEventView({ event }: { event: SubEvent }) {
  switch (event.kind) {
    case "turn_start":
      return (
        <div className="py-0.5 text-xs text-text-muted">Turn {event.turn}</div>
      );
    case "tool_use":
      return (
        <div className="flex items-center gap-1.5 py-0.5">
          <StatusIcon status={event.status === "done" ? "done" : "running"} />
          <span className="text-xs text-text-secondary">{event.tool}</span>
        </div>
      );
    case "tool_result":
      return (
        <div className="flex items-center gap-1.5 py-0.5">
          <StatusIcon status="done" />
          <span className="text-xs text-text-secondary">{event.tool}</span>
          {event.preview && (
            <span className="truncate text-xs text-text-muted max-w-[300px]">
              {event.preview}
            </span>
          )}
        </div>
      );
    case "text_delta":
      return (
        <div className="py-1">
          <Markdown content={event.content ?? ""} />
        </div>
      );
  }
}

function StatusIcon({ status }: { status: string }) {
  if (status === "running") {
    return (
      <svg
        className="h-3 w-3 shrink-0 animate-spin text-text-muted"
        fill="none"
        viewBox="0 0 24 24"
      >
        <circle
          className="opacity-25"
          cx="12"
          cy="12"
          r="10"
          stroke="currentColor"
          strokeWidth="4"
        />
        <path
          className="opacity-75"
          fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
        />
      </svg>
    );
  }

  if (status === "cancelled") {
    return (
      <svg
        className="h-3 w-3 shrink-0 text-status-warning"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
        strokeWidth={2}
      >
        <path
          strokeLinecap="round"
          strokeLinejoin="round"
          d="M6 18L18 6M6 6l12 12"
        />
      </svg>
    );
  }

  return (
    <svg
      className="h-3 w-3 shrink-0 text-status-success"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={2}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M4.5 12.75l6 6 9-13.5"
      />
    </svg>
  );
}

function ChevronIcon({ expanded }: { expanded: boolean }) {
  return (
    <svg
      className={`ml-auto h-3 w-3 shrink-0 text-text-muted transition-transform ${
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

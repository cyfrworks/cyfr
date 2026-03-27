import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useConnectionStore, type UpdateInfo } from "../state/connection-store";

interface UpgradeProgress {
  status: string;
  progress: number;
}

export default function UpdatePage({
  info,
  onComplete,
}: {
  info: UpdateInfo;
  onComplete: () => void;
}) {
  const [status, setStatus] = useState("Starting upgrade...");
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [logLines, setLogLines] = useState<string[]>([]);
  const [showDetails, setShowDetails] = useState(false);
  const logEndRef = useRef<HTMLDivElement>(null);
  const finishUpdate = useConnectionStore((s) => s.finishUpdate);

  useEffect(() => {
    if (showDetails && logEndRef.current) {
      logEndRef.current.scrollIntoView({ behavior: "smooth" });
    }
  }, [logLines, showDetails]);

  // Run the upgrade via the backend perform_upgrade command
  useEffect(() => {
    let cancelled = false;
    setLogLines([]);

    // Listen for progress events from the backend
    const unlistenPromise = listen<UpgradeProgress>(
      "upgrade-progress",
      (event) => {
        if (cancelled) return;
        setStatus(event.payload.status);
        setProgress(event.payload.progress);
        // Collect streamed CLI output lines
        if (event.payload.status) {
          setLogLines((prev) => [...prev.slice(-49), event.payload.status]);
        }
      },
    );

    (async () => {
      try {
        await invoke("perform_upgrade");
        if (!cancelled) {
          setDone(true);
        }
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : String(err));
        }
      }
    })();

    return () => {
      cancelled = true;
      unlistenPromise.then((fn) => fn());
    };
  }, [attempt]);

  // Auto-transition after completion
  useEffect(() => {
    if (done) {
      const timer = setTimeout(() => {
        finishUpdate();
        onComplete();
      }, 600);
      return () => clearTimeout(timer);
    }
  }, [done, finishUpdate, onComplete]);

  const displayProgress = done ? 1.0 : progress;

  return (
    <div className="flex h-full flex-col items-center justify-center bg-surface-base p-8">
      <div className="mb-8">
        <img
          src="/logo.png"
          alt="CYFR"
          className="h-28 w-28 object-contain"
        />
      </div>

      {!error ? (
        <div className="w-full max-w-xs">
          <div className="mb-2 text-center">
            <span className="text-xs font-medium text-accent-primary">
              Updating to v{info.latest}
            </span>
          </div>
          <div className="mb-3 h-1.5 w-full overflow-hidden rounded-full bg-surface-overlay">
            <div
              className="h-full rounded-full bg-gradient-to-r from-accent-primary to-purple-500 transition-all duration-500"
              style={{ width: `${Math.max(displayProgress * 100, 2)}%` }}
            />
          </div>
          <p className="text-center text-sm text-text-secondary">
            {done ? "Update complete!" : status}
          </p>

          {logLines.length > 2 && !done && (
            <div className="mt-3">
              <button
                onClick={() => setShowDetails((v) => !v)}
                className="mx-auto block text-xs text-text-tertiary hover:text-text-secondary"
              >
                {showDetails ? "Hide details" : "Show details"}
              </button>
              {showDetails && (
                <div className="mt-2 max-h-40 overflow-y-auto rounded bg-surface-overlay p-2 font-mono text-[10px] leading-tight text-text-tertiary">
                  {logLines.map((line, i) => (
                    <div key={i}>{line}</div>
                  ))}
                  <div ref={logEndRef} />
                </div>
              )}
            </div>
          )}
        </div>
      ) : (
        <div className="text-center">
          <svg
            className="mx-auto h-12 w-12 text-status-error"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={1.5}
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M12 9v3.75m9-.75a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 3.75h.008v.008H12v-.008Z"
            />
          </svg>
          <h2 className="mt-4 text-lg font-semibold text-text-primary">
            Update Failed
          </h2>
          <p className="mt-2 text-sm text-text-secondary">{error}</p>
          <div className="mt-6 flex flex-col gap-2">
            <button
              onClick={() => {
                setError(null);
                setStatus("Starting upgrade...");
                setProgress(0);
                setDone(false);
                setAttempt((a) => a + 1);
              }}
              className="rounded-lg bg-accent-primary px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-accent-hover"
            >
              Retry
            </button>
            <button
              onClick={() => {
                finishUpdate();
                onComplete();
              }}
              className="rounded-lg bg-surface-overlay px-4 py-2 text-sm font-medium text-text-secondary transition-colors hover:bg-surface-hover"
            >
              Dismiss
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

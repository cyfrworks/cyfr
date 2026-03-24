import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useConnectionStore, type UpdateInfo } from "../state/connection-store";

interface CyfrResult {
  stdout: string;
  stderr: string;
  success: boolean;
  code: number;
}

const STEPS = [
  { label: "Stopping server...", progress: 0.1 },
  { label: "Upgrading CLI...", progress: 0.3 },
  { label: "Updating server...", progress: 0.5 },
  { label: "Starting server...", progress: 0.7 },
  { label: "Waiting for server...", progress: 0.85 },
  { label: "Registering components...", progress: 0.95 },
] as const;

export default function UpdatePage({
  info,
  onComplete,
}: {
  info: UpdateInfo;
  onComplete: () => void;
}) {
  const [step, setStep] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const finishUpdate = useConnectionStore((s) => s.finishUpdate);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        // Step 0: Stop server
        setStep(0);
        await invoke<CyfrResult>("cyfr_command", { args: ["down"] });
        if (cancelled) return;

        // Step 1: Upgrade CLI
        setStep(1);
        await invoke<CyfrResult>("cyfr_command", { args: ["upgrade"] });
        if (cancelled) return;

        // Step 2: Update server image
        setStep(2);
        await invoke<CyfrResult>("cyfr_command", { args: ["update"] });
        if (cancelled) return;

        // Step 3: Start server
        setStep(3);
        await invoke<CyfrResult>("cyfr_command", { args: ["up"] });
        if (cancelled) return;

        // Step 4: Wait for health (poll cyfr status until server responds)
        setStep(4);
        let healthy = false;
        for (let i = 0; i < 60; i++) {
          if (cancelled) return;
          try {
            const result = await invoke<CyfrResult>("cyfr_command", {
              args: ["status"],
            });
            if (result.success) {
              healthy = true;
              break;
            }
          } catch {
            // Not ready yet
          }
          await new Promise((r) => setTimeout(r, 1000));
        }
        if (!healthy) {
          throw new Error("Server did not become healthy after 60 seconds");
        }

        // Step 5: Register components
        setStep(5);
        await invoke<CyfrResult>("cyfr_command", { args: ["register"] });
        if (cancelled) return;

        setDone(true);
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : String(err));
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

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

  const current = STEPS[step];
  const progress = done ? 1.0 : (current?.progress ?? 0);

  return (
    <div className="flex h-full flex-col items-center justify-center bg-surface-base p-8">
      <div className="mb-8">
        <img src="/logo.png" alt="CYFR" className="h-28 w-28 object-contain" />
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
              style={{ width: `${Math.max(progress * 100, 2)}%` }}
            />
          </div>
          <p className="text-center text-sm text-text-secondary">
            {done ? "Update complete!" : current?.label}
          </p>
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
                setStep(0);
                setDone(false);
                // Re-trigger by remounting — simplest approach
                finishUpdate();
                onComplete();
              }}
              className="rounded-lg bg-accent-primary px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-accent-hover"
            >
              Continue
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

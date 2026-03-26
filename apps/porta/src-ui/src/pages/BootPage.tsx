import { useEffect, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { useConnectionStore } from "../state/connection-store";

interface BootEvent {
  state: string;
  message: string;
  progress: number | null;
}

export default function BootPage() {
  const { bootState, bootMessage, bootProgress, setBootState, setBootComplete } =
    useConnectionStore();

  useEffect(() => {
    const unlisten = listen<BootEvent>("boot-state", (event) => {
      const { state, message, progress } = event.payload;
      setBootState(state, message, progress ?? 0);

      if (state === "ready") {
        // Transition window to main app size
        invoke("transition_to_main").catch(() => {});
        setTimeout(() => setBootComplete(true), 300);
      }
    });

    // Trigger boot sequence
    invoke("start_boot").catch(() => {});

    return () => {
      unlisten.then((fn) => fn());
    };
  }, [setBootState, setBootComplete]);

  return (
    <div className="flex h-full flex-col items-center justify-center bg-surface-base p-8">
      {/* Logo */}
      <div className="mb-8">
        <img
          src="/logo.png"
          alt="CYFR"
          className="h-28 w-28 object-contain"
        />
      </div>

      {/* Progress states */}
      {(bootState === "checking" ||
        bootState === "installing_cli" ||
        bootState === "installing_docker" ||
        bootState === "init" ||
        bootState === "starting" ||
        bootState === "ready") && (
        <ProgressView message={bootMessage} progress={bootProgress} />
      )}

      {bootState === "docker_not_found" && <DockerNotFoundView />}
      {bootState === "docker_not_running" && <DockerNotRunningView />}
      {bootState === "cli_not_found" && <CliNotFoundView />}
      {bootState === "error" && <ErrorView message={bootMessage} />}
    </div>
  );
}

function ProgressView({
  message,
  progress,
}: {
  message: string;
  progress: number;
}) {
  return (
    <div className="w-full max-w-xs">
      <div className="mb-3 h-1.5 w-full overflow-hidden rounded-full bg-surface-overlay">
        <div
          className="h-full rounded-full bg-gradient-to-r from-accent-primary to-purple-500 transition-all duration-300"
          style={{ width: `${Math.max(progress * 100, 2)}%` }}
        />
      </div>
      <p className="text-center text-sm text-text-secondary">{message}</p>
    </div>
  );
}

function DockerNotFoundView() {
  const handleInstall = async () => {
    try {
      // install_docker handles the full flow: download, install, poll for readiness, retry boot
      await invoke("install_docker");
    } catch (err) {
      // Show the error to the user instead of swallowing it
      useConnectionStore
        .getState()
        .setBootState("error", String(err), 0);
    }
  };

  return (
    <div className="text-center">
      <StatusIcon type="error" />
      <h2 className="mt-4 text-lg font-semibold text-text-primary">
        Docker Not Found
      </h2>
      <p className="mt-2 text-sm text-text-secondary">
        Docker is required to run CYFR locally.
      </p>
      <div className="mt-6 flex flex-col gap-2">
        <button onClick={handleInstall} className="btn-primary">
          Install Docker
        </button>
        <button
          onClick={() => invoke("open_url", { url: "https://docs.docker.com/get-started/get-docker/" })}
          className="btn-secondary"
        >
          Download Manually
        </button>
      </div>
    </div>
  );
}

function DockerNotRunningView() {
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // Cleanup polling interval on unmount
  useEffect(() => {
    return () => {
      if (pollRef.current) {
        clearInterval(pollRef.current);
        pollRef.current = null;
      }
    };
  }, []);

  const handleOpen = async () => {
    await invoke("open_docker_desktop");
    // Clear any existing poll before creating a new one
    if (pollRef.current) clearInterval(pollRef.current);
    // Poll for Docker readiness, then retry boot
    pollRef.current = setInterval(async () => {
      try {
        const ready = await invoke<boolean>("check_docker_ready");
        if (ready) {
          if (pollRef.current) clearInterval(pollRef.current);
          pollRef.current = null;
          invoke("retry_boot").catch(() => {});
        }
      } catch {
        // Keep polling
      }
    }, 2000);
    setTimeout(() => {
      if (pollRef.current) clearInterval(pollRef.current);
      pollRef.current = null;
    }, 120000);
  };

  return (
    <div className="text-center">
      <StatusIcon type="warning" />
      <h2 className="mt-4 text-lg font-semibold text-text-primary">
        Docker Not Running
      </h2>
      <p className="mt-2 text-sm text-text-secondary">
        Start Docker Desktop to continue.
      </p>
      <button onClick={handleOpen} className="btn-primary mt-6">
        Start Docker
      </button>
    </div>
  );
}

function CliNotFoundView() {
  return (
    <div className="text-center">
      <StatusIcon type="error" />
      <h2 className="mt-4 text-lg font-semibold text-text-primary">
        CYFR CLI Not Found
      </h2>
      <p className="mt-2 text-sm text-text-secondary">
        The CYFR command-line tool is being installed...
      </p>
      <button
        onClick={() => invoke("retry_boot")}
        className="btn-primary mt-6"
      >
        Retry
      </button>
    </div>
  );
}

function ErrorView({ message }: { message: string }) {
  return (
    <div className="text-center">
      <StatusIcon type="error" />
      <h2 className="mt-4 text-lg font-semibold text-text-primary">
        Something went wrong
      </h2>
      <p className="mt-2 text-sm text-text-secondary">{message}</p>
      <button
        onClick={() => invoke("retry_boot")}
        className="btn-primary mt-6"
      >
        Retry
      </button>
    </div>
  );
}

function StatusIcon({ type }: { type: "error" | "warning" }) {
  const color =
    type === "error" ? "text-status-error" : "text-status-warning";
  return (
    <svg
      className={`mx-auto h-12 w-12 ${color}`}
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={1.5}
    >
      {type === "error" ? (
        <path
          strokeLinecap="round"
          strokeLinejoin="round"
          d="M12 9v3.75m9-.75a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 3.75h.008v.008H12v-.008Z"
        />
      ) : (
        <path
          strokeLinecap="round"
          strokeLinejoin="round"
          d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126ZM12 15.75h.007v.008H12v-.008Z"
        />
      )}
    </svg>
  );
}

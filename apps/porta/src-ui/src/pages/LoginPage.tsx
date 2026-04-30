import { invoke } from "@tauri-apps/api/core";
import { useAuthStore } from "../state/auth-store";
import { useConnectionStore } from "../state/connection-store";
import { switchInstance } from "../util/switch-instance";

export default function LoginPage() {
  const {
    loginPending,
    userCode,
    verificationUri,
    loginError,
    startLogin,
    cancelLogin,
  } = useAuthStore();
  const mode = useConnectionStore((s) => s.mode);
  const resetMcpClient = useConnectionStore((s) => s.resetMcpClient);

  const isRemote = mode === "remote";

  function handleSwitchInstance() {
    void switchInstance({ mode, resetMcpClient });
  }

  if (isRemote) {
    return (
      <div className="flex h-full flex-col items-center justify-center bg-surface-base p-8">
        <img src="/logo.png" alt="CYFR" className="h-28 w-28 object-contain" />
        <h1 className="mt-6 text-xl font-semibold text-text-primary">
          Cannot reach remote CYFR
        </h1>
        <p className="mt-3 max-w-md text-center text-sm text-text-secondary">
          Your API key is missing or invalid. Update it in the setup wizard
          or switch to a different CYFR instance.
        </p>
        <button
          onClick={handleSwitchInstance}
          className="btn-primary mt-6 text-sm"
        >
          Open setup wizard
        </button>
      </div>
    );
  }

  return (
    <div className="flex h-full flex-col items-center justify-center bg-surface-base p-8">
      <img
        src="/logo.png"
        alt="CYFR"
        className="h-28 w-28 object-contain"
      />
      <h1 className="mt-6 text-xl font-semibold text-text-primary">
        Sign in to CYFR
      </h1>

      {loginPending && userCode ? (
        <div className="mt-6 text-center">
          <p className="text-sm text-text-secondary">
            Enter this code in your browser:
          </p>
          <div className="mt-3 inline-flex items-center gap-2 rounded-lg bg-surface-overlay pl-6 pr-2 py-2">
            <code className="font-mono text-2xl font-bold tracking-widest text-accent-primary">
              {userCode}
            </code>
            <button
              onClick={() => navigator.clipboard.writeText(userCode ?? "")}
              className="rounded p-1.5 text-text-muted hover:bg-surface-base hover:text-text-secondary"
              title="Copy code"
            >
              <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 0 1-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 0 1 1.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 0 0-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 0 1-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 0 0-3.375-3.375h-1.5a1.125 1.125 0 0 1-1.125-1.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H9.75" />
              </svg>
            </button>
          </div>
          {verificationUri && (
            <p className="mt-4 text-sm">
              <a
                href={verificationUri}
                target="_blank"
                rel="noopener noreferrer"
                className="text-accent-primary hover:text-accent-hover"
                onClick={(e) => {
                  e.preventDefault();
                  invoke("open_url", { url: verificationUri });
                }}
              >
                Open browser to enter code &rarr;
              </a>
            </p>
          )}
          <div className="mt-6 flex items-center justify-center gap-2">
            <LoadingDots />
            <span className="text-sm text-text-muted">
              Waiting for authorization...
            </span>
          </div>
          <button
            onClick={cancelLogin}
            className="mt-3 text-xs text-text-muted hover:text-text-secondary underline"
          >
            Cancel
          </button>
        </div>
      ) : loginPending ? (
        <div className="mt-6 flex flex-col items-center gap-3">
          <div className="flex items-center gap-2">
            <LoadingDots />
            <span className="text-sm text-text-muted">Connecting...</span>
          </div>
          <button
            onClick={cancelLogin}
            className="text-xs text-text-muted hover:text-text-secondary underline"
          >
            Cancel
          </button>
        </div>
      ) : loginError ? (
        <div className="mt-6 text-center">
          <p className="text-sm text-status-error">{loginError}</p>
          <ProviderButtons onPick={startLogin} retry />
        </div>
      ) : (
        <ProviderButtons onPick={startLogin} />
      )}

      <button
        onClick={handleSwitchInstance}
        className="mt-8 text-xs text-text-muted hover:text-text-secondary underline"
      >
        Use a different CYFR instance
      </button>
    </div>
  );
}

function ProviderButtons({
  onPick,
  retry = false,
}: {
  onPick: (provider: "github" | "google") => Promise<void>;
  retry?: boolean;
}) {
  return (
    <div className={`${retry ? "mt-4" : "mt-6"} flex flex-col gap-2`}>
      <button
        onClick={() => void onPick("github")}
        className="btn-primary text-sm"
      >
        {retry ? "Retry with GitHub" : "Sign in with GitHub"}
      </button>
      <button
        onClick={() => void onPick("google")}
        className="btn-secondary text-sm"
      >
        {retry ? "Retry with Google" : "Sign in with Google"}
      </button>
    </div>
  );
}

function LoadingDots() {
  return (
    <span className="flex gap-1">
      <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-accent-primary [animation-delay:-0.3s]" />
      <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-accent-primary [animation-delay:-0.15s]" />
      <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-accent-primary" />
    </span>
  );
}

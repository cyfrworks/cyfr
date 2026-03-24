import { useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAuthStore } from "../state/auth-store";

export default function LoginPage() {
  const {
    loginPending,
    userCode,
    verificationUri,
    loginError,
    startLogin,
  } = useAuthStore();

  // Auto-start login on mount (only if no error from a previous attempt)
  useEffect(() => {
    if (!loginPending && !userCode && !loginError) {
      startLogin();
    }
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="flex h-full flex-col items-center justify-center bg-surface-base p-8">
      <img
        src="/logo.jpg"
        alt="CYFR"
        className="h-16 w-16 rounded-2xl object-cover"
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
                Open GitHub to enter code &rarr;
              </a>
            </p>
          )}
          <div className="mt-6 flex items-center justify-center gap-2">
            <LoadingDots />
            <span className="text-sm text-text-muted">
              Waiting for authorization...
            </span>
          </div>
        </div>
      ) : loginPending ? (
        <div className="mt-6 flex items-center gap-2">
          <LoadingDots />
          <span className="text-sm text-text-muted">Connecting...</span>
        </div>
      ) : loginError ? (
        <div className="mt-6 text-center">
          <p className="text-sm text-status-error">{loginError}</p>
          <button onClick={startLogin} className="btn-primary mt-4 text-sm">
            Try again
          </button>
        </div>
      ) : (
        <div className="mt-6">
          <button onClick={startLogin} className="btn-primary text-sm">
            Sign in with GitHub
          </button>
        </div>
      )}
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

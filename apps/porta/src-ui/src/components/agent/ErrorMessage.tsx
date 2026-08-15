import { useState } from "react";
import { translateError, type ErrorAction } from "../../errors/translator";
import { useOverlayStore } from "../../state/overlay-store";
import { useAgentStore } from "../../state/agent-store";
import { navigate } from "../../harness/navigate";

/**
 * Renders a translated error message inline in the transcript with optional
 * action buttons and a dev-mode details toggle for the raw error string.
 */
export function ErrorMessage({ raw }: { raw: string }) {
  const translated = translateError(raw);
  const [showRaw, setShowRaw] = useState(false);
  const devMode = isDevMode();

  return (
    <div className="rounded-xl border border-status-error/30 bg-status-error/10 px-4 py-3">
      <div className="text-sm font-medium text-status-error">
        {translated.title}
      </div>
      <p className="mt-1 text-sm text-text-secondary">{translated.body}</p>

      {translated.actions.length > 0 && (
        <div className="mt-3 flex flex-wrap gap-2">
          {translated.actions.map((action, i) => (
            <ActionButton key={i} action={action} />
          ))}
        </div>
      )}

      {devMode &&
        translated.rawMessage &&
        translated.rawMessage !== translated.body && (
          <div className="mt-3 border-t border-status-error/20 pt-2">
            <button
              onClick={() => setShowRaw((v) => !v)}
              className="text-[10px] text-text-muted hover:text-text-secondary"
            >
              {showRaw ? "Hide raw error" : "Show raw error"}
            </button>
            {showRaw && (
              <pre className="mt-1 overflow-x-auto rounded bg-surface-base p-2 font-mono text-[10px] text-text-muted">
                {translated.rawMessage}
              </pre>
            )}
          </div>
        )}
    </div>
  );
}

function ActionButton({ action }: { action: ErrorAction }) {
  return (
    <button
      onClick={() => dispatchAction(action)}
      className="rounded border border-border-default bg-surface-raised px-3 py-1 text-xs text-text-secondary transition-colors hover:bg-surface-overlay hover:text-text-primary"
    >
      {action.label}
    </button>
  );
}

function dispatchAction(action: ErrorAction) {
  switch (action.kind) {
    case "retry": {
      // Re-submit the last user message in the conversation, if any.
      const state = useAgentStore.getState();
      const lastUser = [...state.messages]
        .reverse()
        .find((m) => m.role === "user");
      if (lastUser) void state.submit(lastUser.content);
      break;
    }
    case "open_settings":
      navigate("/settings");
      break;
    case "open_connections":
      navigate("/mcp-servers");
      break;
    case "open_components":
      navigate("/components");
      break;
    case "open_aqua":
      useOverlayStore.getState().open();
      useOverlayStore.getState().focusInput();
      break;
    case "grant_access":
      // The grant flow is part of setup — surface via the setup_required path
      // by asking AQUA to run setup. The specific component ref is in target.
      if (action.target) {
        void useAgentStore
          .getState()
          .submit(`Please run setup for ${action.target}.`);
      }
      break;
    case "reconnect":
      // Reopen overlay so the user can sign in again via the existing flow.
      navigate("/settings");
      break;
    case "install_runtime":
      // Backend runtime controls live on the boot screen; no in-app shortcut
      // for restart yet — prompt the user instead.
      alert("Please start the cyfr runtime from your system tray, then retry.");
      break;
  }
}

function isDevMode(): boolean {
  try {
    return localStorage.getItem("porta.devMode") === "true";
  } catch {
    return false;
  }
}

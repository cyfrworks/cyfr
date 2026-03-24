import { useEffect, useState, useRef } from "react";
import { useNavigate } from "react-router-dom";
import { MessageList } from "../components/agent/MessageList";
import { ComposeBar } from "../components/agent/ComposeBar";
import { ConversationSidebar } from "../components/agent/ConversationSidebar";
import { useAgentStore } from "../state/agent-store";
import { useProviderStore, type ProviderKey } from "../state/provider-store";
import { useConversationStore } from "../state/conversation-store";

export default function AskPage() {
  // Save conversation state before window closes
  useEffect(() => {
    const handler = () => {
      const state = useAgentStore.getState();
      if (state.running && state.conversationId) {
        state.persistConversation();
      }
    };
    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
  }, []);

  // Auto-reconnect to the most recent running conversation on mount
  useEffect(() => {
    const tryReconnect = async () => {
      const agentState = useAgentStore.getState();
      // Don't auto-reconnect if user already has an active conversation
      if (agentState.running || agentState.conversationId) return;

      const convStore = useConversationStore.getState();
      await convStore.loadConversations();

      const { conversations } = useConversationStore.getState();
      const runningConv = conversations.find((c) => c.status === "running");
      if (runningConv) {
        const conv = await convStore.getConversation(runningConv.id);
        if (conv) {
          useAgentStore.getState().loadConversation(conv);
        }
      }
    };
    tryReconnect();
  }, []);

  return (
    <div className="flex h-full">
      {/* Main conversation area */}
      <div className="flex flex-1 flex-col">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-border-default px-4 py-2">
          <h1 className="text-sm font-medium text-text-primary">AQUA</h1>
          <ModelSelector />
        </div>

        {/* Messages */}
        <MessageList />

        {/* Input */}
        <ComposeBar />
      </div>

      {/* Conversation history sidebar */}
      <ConversationSidebar />
    </div>
  );
}

function ModelSelector() {
  const provider = useAgentStore((s) => s.provider);
  const model = useAgentStore((s) => s.model);
  const running = useAgentStore((s) => s.running);
  const providers = useProviderStore((s) => s.providers);
  const loading = useProviderStore((s) => s.loading);
  const loadAll = useProviderStore((s) => s.loadAll);
  const selectModel = useProviderStore((s) => s.selectModel);
  const navigate = useNavigate();

  const [open, setOpen] = useState(false);
  const [selProvider, setSelProvider] = useState(provider);
  const [selModel, setSelModel] = useState(model);
  const popoverRef = useRef<HTMLDivElement>(null);

  // Lazy-load providers if not yet loaded (handles direct /ask navigation)
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    if (!loaded && !loading) {
      const hasAny = providers.some((p) => p.ready || p.secretSet);
      if (!hasAny) {
        loadAll().finally(() => setLoaded(true));
      } else {
        setLoaded(true);
      }
    }
  }, [loaded, loading, providers, loadAll]);

  const readyProviders = providers.filter((p) => p.ready);

  const currentProviderInfo = providers.find((p) => p.key === selProvider);
  const availableModels = currentProviderInfo?.models ?? [];

  const handleOpen = () => {
    if (running) return;
    // Use stored provider only if it's actually ready, otherwise pick first ready one
    const storedIsReady = readyProviders.some((p) => p.key === provider);
    setSelProvider(storedIsReady ? provider : (readyProviders[0]?.key ?? ""));
    setSelModel(storedIsReady ? model : "");
    setOpen(true);
  };

  const handleProviderChange = (newProvider: string) => {
    setSelProvider(newProvider);
    setSelModel("");
  };

  const handleSave = () => {
    if (!selProvider || !selModel) return;
    selectModel(selProvider as ProviderKey, selModel);
    setOpen(false);
  };

  // Click outside to close
  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (
        popoverRef.current &&
        !popoverRef.current.contains(e.target as Node)
      ) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [open]);

  // Display label — only show if provider is actually ready
  const providerInfo = providers.find((p) => p.key === provider);
  const displayLabel =
    model && providerInfo?.ready
      ? `${providerInfo.label} / ${model}`
      : null;

  return (
    <div className="relative" ref={popoverRef}>
      <button
        onClick={handleOpen}
        disabled={running}
        className="rounded-md px-2 py-1 text-xs transition-colors hover:bg-surface-raised disabled:opacity-50"
      >
        {displayLabel ? (
          <span className="text-text-muted">{displayLabel}</span>
        ) : (
          <span className="text-accent-primary animate-pulse">
            Select model
          </span>
        )}
      </button>

      {open && (
        <div className="absolute right-0 top-full z-50 mt-1 w-72 rounded-lg border border-border-default bg-surface-raised p-3 shadow-lg">
          {readyProviders.length === 0 ? (
            <div className="text-center py-2">
              <p className="text-xs text-text-muted">
                No providers configured
              </p>
              <button
                onClick={() => {
                  setOpen(false);
                  navigate("/components");
                }}
                className="mt-1 text-xs text-accent-primary hover:text-accent-hover"
              >
                Set up providers
              </button>
            </div>
          ) : (
            <>
              {/* Provider dropdown */}
              <label className="block text-[10px] font-medium uppercase text-text-muted">
                Provider
              </label>
              <select
                value={selProvider}
                onChange={(e) => handleProviderChange(e.target.value)}
                className="mt-1 w-full rounded-lg border border-border-default bg-surface-base px-3 py-1.5 text-sm text-text-primary outline-none focus:border-border-focus"
              >
                {readyProviders.map((p) => (
                  <option key={p.key} value={p.key}>
                    {p.label}
                  </option>
                ))}
              </select>

              {/* Model dropdown */}
              <label className="mt-2 block text-[10px] font-medium uppercase text-text-muted">
                Model
              </label>
              <select
                value={selModel}
                onChange={(e) => setSelModel(e.target.value)}
                className="mt-1 w-full rounded-lg border border-border-default bg-surface-base px-3 py-1.5 text-sm text-text-primary outline-none focus:border-border-focus"
              >
                <option value="" disabled>
                  Select a model...
                </option>
                {availableModels.map((m) => (
                  <option key={m} value={m}>
                    {m}
                  </option>
                ))}
              </select>

              {/* Save / Cancel */}
              <div className="mt-3 flex justify-end gap-2">
                <button
                  onClick={() => setOpen(false)}
                  className="rounded-md border border-border-default px-3 py-1.5 text-xs text-text-secondary transition-colors hover:bg-surface-base"
                >
                  Cancel
                </button>
                <button
                  onClick={handleSave}
                  disabled={!selModel}
                  className="btn-primary rounded-md px-3 py-1.5 text-xs disabled:opacity-30"
                >
                  Save
                </button>
              </div>
            </>
          )}
        </div>
      )}
    </div>
  );
}

import { useEffect, useState } from "react";
import { useLocation } from "react-router-dom";
import { MessageList } from "../components/agent/MessageList";
import { ComposeBar } from "../components/agent/ComposeBar";
import { ConversationSidebar } from "../components/agent/ConversationSidebar";
import { PresetPanel } from "../components/agent/PresetPanel";
import { useAgentStore } from "../state/agent-store";
import { useConversationStore } from "../state/conversation-store";
import { usePresetStore } from "../state/preset-store";

export default function AskPage() {
  const [historyOpen, setHistoryOpen] = useState(false);
  const [presetsOpen, setPresetsOpen] = useState(false);
  const location = useLocation();
  const isVisible = location.pathname === "/ask" || location.pathname === "/";
  const conversationId = useAgentStore((s) => s.conversationId);

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

  // Load presets on mount
  useEffect(() => {
    const { loaded, loadPresets } = usePresetStore.getState();
    if (!loaded) loadPresets();
  }, []);

  // Restore conversation when page becomes visible (mount or navigation back)
  useEffect(() => {
    if (!isVisible) return;

    const restoreConversation = async () => {
      const agentState = useAgentStore.getState();
      // Already have active state — nothing to do
      if (agentState.running || agentState.messages.length > 0) return;

      const convStore = useConversationStore.getState();
      await convStore.loadConversations();

      const { conversations } = useConversationStore.getState();
      const runningConv = conversations.find((c) => c.status === "running");
      // Fall back to most recent conversation (index is sorted by updated_at desc)
      const targetConv = runningConv ?? conversations[0];
      if (targetConv) {
        const conv = await convStore.getConversation(targetConv.id);
        if (conv) {
          useAgentStore.getState().loadConversation(conv);
        }
      }
    };
    restoreConversation();
  }, [isVisible]);

  return (
    <div className="flex h-full">
      {/* Main conversation area */}
      <div className="flex flex-1 flex-col">
        {/* Header */}
        <Header
          historyOpen={historyOpen}
          onToggleHistory={() => setHistoryOpen(!historyOpen)}
          presetsOpen={presetsOpen}
          onTogglePresets={() => setPresetsOpen(!presetsOpen)}
        />

        {/* Inline preset panel */}
        {presetsOpen && <PresetPanel />}

        {/* Messages — key forces fresh Zustand subscriptions on conversation change */}
        <MessageList key={conversationId ?? "new"} />

        {/* Input */}
        <ComposeBar />
      </div>

      {/* Conversation history sidebar */}
      {historyOpen && <ConversationSidebar />}
    </div>
  );
}

function Header({
  historyOpen,
  onToggleHistory,
  presetsOpen,
  onTogglePresets,
}: {
  historyOpen: boolean;
  onToggleHistory: () => void;
  presetsOpen: boolean;
  onTogglePresets: () => void;
}) {
  const newChat = useAgentStore((s) => s.newChat);
  const backgroundExecutions = useAgentStore((s) => s.backgroundExecutions);
  const hasBackground = Object.keys(backgroundExecutions).length > 0;

  return (
    <div className="flex items-center justify-between border-b border-border-default px-4 py-2">
      <div className="flex items-center gap-2">
        <h1 className="text-sm font-medium text-text-primary">AQUA</h1>
        <ActivePresetBadge />
      </div>

      <div className="flex items-center gap-1">
        {/* Presets toggle */}
        <button
          onClick={onTogglePresets}
          className={`rounded-md px-2.5 py-1 text-xs transition-colors ${
            presetsOpen
              ? "bg-accent-primary/10 text-accent-primary"
              : "text-text-secondary hover:bg-surface-raised hover:text-text-primary"
          }`}
        >
          Presets
        </button>

        {/* History toggle */}
        <button
          onClick={onToggleHistory}
          className={`relative rounded-md px-2.5 py-1 text-xs transition-colors ${
            historyOpen
              ? "bg-accent-primary/10 text-accent-primary"
              : "text-text-secondary hover:bg-surface-raised hover:text-text-primary"
          }`}
        >
          History
          {hasBackground && (
            <span className="absolute -right-0.5 -top-0.5 h-1.5 w-1.5 rounded-full bg-status-info animate-pulse" />
          )}
        </button>

        {/* New Chat */}
        <button
          onClick={newChat}
          className="rounded-md px-2.5 py-1 text-xs text-text-secondary transition-colors hover:bg-surface-raised hover:text-text-primary"
          title="New chat"
        >
          <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
          </svg>
        </button>
      </div>
    </div>
  );
}

function ActivePresetBadge() {
  const activePreset = useAgentStore((s) => s.activePreset);
  const presets = usePresetStore((s) => s.presets);

  if (!activePreset && presets.length === 0) {
    return (
      <span className="text-xs text-status-warning animate-pulse">
        Create a preset to get started
      </span>
    );
  }

  if (!activePreset) return null;
  return (
    <span className="inline-flex items-center gap-1 rounded-md bg-accent-primary/10 px-2 py-1 text-xs font-medium text-accent-primary">
      <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09z" />
      </svg>
      {activePreset}
    </span>
  );
}

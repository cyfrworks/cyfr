import { useEffect, useState } from "react";
import { useLocation } from "react-router-dom";
import { MessageList } from "../components/agent/MessageList";
import { ComposeBar } from "../components/agent/ComposeBar";
import { ConversationSidebar } from "../components/agent/ConversationSidebar";
import { AgentEditorPanel } from "../components/agent/AgentEditorPanel";
import { PageLayout } from "../components/common/PageLayout";
import { useAgentStore } from "../state/agent-store";
import { useConversationStore } from "../state/conversation-store";
import { useOrchestratorStore } from "../state/orchestrator-store";

export default function AskPage() {
  const [historyOpen, setHistoryOpen] = useState(false);
  const [editorOpen, setEditorOpen] = useState(false);
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

  // Initialize MCP client and load orchestrators on mount
  useEffect(() => {
    (async () => {
      let client = useAgentStore.getState().client;
      if (!client) {
        await useAgentStore.getState().initClient();
        client = useAgentStore.getState().client;
      }
      if (client) {
        const { loaded, loading, loadOrchestrators } = useOrchestratorStore.getState();
        if (!loaded && !loading) {
          loadOrchestrators(client);
        }
      }
    })();
  }, []);

  // Restore conversation when page becomes visible
  useEffect(() => {
    if (!isVisible) return;

    const restoreConversation = async () => {
      const agentState = useAgentStore.getState();
      if (agentState.running || agentState.messages.length > 0) return;

      const convStore = useConversationStore.getState();
      await convStore.loadConversations();

      const { conversations } = useConversationStore.getState();
      const runningConv = conversations.find((c) => c.status === "running");
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

  const newChat = useAgentStore((s) => s.newChat);
  const backgroundExecutions = useAgentStore((s) => s.backgroundExecutions);
  const hasBackground = Object.keys(backgroundExecutions).length > 0;

  return (
    <PageLayout
      title="AQUA"
      subtitle="AI assistants and conversations."
      actions={
        <>
          <ActiveOrchestratorBadge />
          <button
            onClick={() => setEditorOpen(!editorOpen)}
            className={`rounded-lg px-3 py-1.5 text-xs transition-colors ${
              editorOpen
                ? "bg-accent-primary/10 text-accent-primary"
                : "border border-border-default text-text-secondary hover:bg-surface-raised hover:text-text-primary"
            }`}
          >
            Agents
          </button>
          <button
            onClick={() => setHistoryOpen(!historyOpen)}
            className={`relative rounded-lg px-3 py-1.5 text-xs transition-colors ${
              historyOpen
                ? "bg-accent-primary/10 text-accent-primary"
                : "border border-border-default text-text-secondary hover:bg-surface-raised hover:text-text-primary"
            }`}
          >
            History
            {hasBackground && (
              <span className="absolute -right-0.5 -top-0.5 h-1.5 w-1.5 rounded-full bg-status-info animate-pulse" />
            )}
          </button>
          <button
            onClick={newChat}
            className="rounded-lg border border-border-default p-1.5 text-text-secondary transition-colors hover:bg-surface-raised hover:text-text-primary"
            title="New chat"
            aria-label="New chat"
          >
            <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
            </svg>
          </button>
        </>
      }
      bleed
    >
      <div className="flex h-full">
        <div className="flex min-w-0 flex-1 flex-col">
          {editorOpen && <AgentEditorPanel onClose={() => setEditorOpen(false)} />}
          <MessageList key={conversationId ?? "new"} />
          <ComposeBar />
        </div>
        {historyOpen && <ConversationSidebar />}
      </div>
    </PageLayout>
  );
}

function ActiveOrchestratorBadge() {
  const activeOrchestrator = useAgentStore((s) => s.activeOrchestrator);
  const orchestrators = useOrchestratorStore((s) => s.orchestrators);

  if (!activeOrchestrator && orchestrators.length === 0) {
    return (
      <span className="text-xs text-status-warning animate-pulse">
        No orchestrators configured
      </span>
    );
  }

  if (!activeOrchestrator) return null;
  return (
    <span className="inline-flex items-center gap-1 rounded-md bg-accent-primary/10 px-2 py-1 text-xs font-medium text-accent-primary">
      <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09z" />
      </svg>
      {activeOrchestrator}
    </span>
  );
}

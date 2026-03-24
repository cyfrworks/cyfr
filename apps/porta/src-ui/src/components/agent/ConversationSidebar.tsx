import { useEffect } from "react";
import { useConversationStore } from "../../state/conversation-store";
import { useAgentStore } from "../../state/agent-store";

export function ConversationSidebar() {
  const conversations = useConversationStore((s) => s.conversations);
  const loading = useConversationStore((s) => s.loading);
  const loadConversations = useConversationStore((s) => s.loadConversations);
  const getConversation = useConversationStore((s) => s.getConversation);
  const deleteConversation = useConversationStore((s) => s.deleteConversation);
  const loadConversation = useAgentStore((s) => s.loadConversation);
  const newChat = useAgentStore((s) => s.newChat);
  const currentConvId = useAgentStore((s) => s.conversationId);

  useEffect(() => {
    loadConversations();
  }, [loadConversations]);

  const handleSelect = async (id: string) => {
    if (id === currentConvId) return;
    const conv = await getConversation(id);
    if (conv) loadConversation(conv);
  };

  const handleDelete = async (id: string, e: React.MouseEvent) => {
    e.stopPropagation();
    await deleteConversation(id);
    if (id === currentConvId) newChat();
  };

  return (
    <div className="flex w-64 flex-col border-l border-border-default bg-surface-base">
      <div className="flex items-center justify-between border-b border-border-default px-3 py-2">
        <span className="text-xs font-medium text-text-secondary">
          History
        </span>
        <button
          onClick={newChat}
          className="rounded p-1 text-text-muted hover:bg-surface-raised hover:text-text-secondary"
          title="New chat"
        >
          <svg
            className="h-3.5 w-3.5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2}
          >
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
          </svg>
        </button>
      </div>

      <div className="flex-1 overflow-y-auto">
        {loading && (
          <div className="p-3 text-xs text-text-muted">Loading...</div>
        )}
        {!loading && conversations.length === 0 && (
          <div className="p-3 text-xs text-text-muted">
            No conversations yet
          </div>
        )}
        {conversations.map((conv) => (
          <button
            key={conv.id}
            onClick={() => handleSelect(conv.id)}
            className={`group flex w-full items-center gap-2 px-3 py-2 text-left transition-colors ${
              conv.id === currentConvId
                ? "bg-accent-primary/10 text-text-primary"
                : "text-text-secondary hover:bg-surface-raised"
            }`}
          >
            <div className="min-w-0 flex-1">
              <div className="truncate text-xs">{conv.title}</div>
              <div className="text-[10px] text-text-muted">
                {formatDate(conv.updated_at)}
              </div>
            </div>
            {conv.status === "running" && (
              <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-status-info animate-pulse" />
            )}
            <button
              onClick={(e) => handleDelete(conv.id, e)}
              className="shrink-0 rounded p-0.5 text-text-muted opacity-0 hover:text-status-error group-hover:opacity-100"
              title="Delete"
            >
              <svg
                className="h-3 w-3"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                strokeWidth={2}
              >
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </button>
        ))}
      </div>
    </div>
  );
}

function formatDate(iso: string): string {
  try {
    const d = new Date(iso);
    const now = new Date();
    const diffMs = now.getTime() - d.getTime();
    const diffMins = Math.floor(diffMs / 60000);

    if (diffMins < 1) return "just now";
    if (diffMins < 60) return `${diffMins}m ago`;
    const diffHrs = Math.floor(diffMins / 60);
    if (diffHrs < 24) return `${diffHrs}h ago`;
    const diffDays = Math.floor(diffHrs / 24);
    if (diffDays < 7) return `${diffDays}d ago`;
    return d.toLocaleDateString();
  } catch {
    return "";
  }
}

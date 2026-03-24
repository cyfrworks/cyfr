import { MessageList } from "../components/agent/MessageList";
import { ComposeBar } from "../components/agent/ComposeBar";
import { ConversationSidebar } from "../components/agent/ConversationSidebar";
import { useAgentStore } from "../state/agent-store";

export default function AskPage() {
  const model = useAgentStore((s) => s.model);
  const catalystRef = useAgentStore((s) => s.catalystRef);
  const currentLabel = model || catalystRef.split(".").pop() || "claude";

  return (
    <div className="flex h-full">
      {/* Main conversation area */}
      <div className="flex flex-1 flex-col">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-border-default px-4 py-2">
          <h1 className="text-sm font-medium text-text-primary">AQUA</h1>
          <span className="text-xs text-text-muted">{currentLabel}</span>
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

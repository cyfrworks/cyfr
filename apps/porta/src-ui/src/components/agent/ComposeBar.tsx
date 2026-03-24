import { useState, useRef, useCallback } from "react";
import { useAgentStore } from "../../state/agent-store";

export function ComposeBar() {
  const [input, setInput] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const running = useAgentStore((s) => s.running);
  const submit = useAgentStore((s) => s.submit);
  const stop = useAgentStore((s) => s.stop);

  const handleSubmit = useCallback(() => {
    const trimmed = input.trim();
    if (!trimmed || running) return;
    setInput("");
    submit(trimmed);
    // Reset textarea height
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }
  }, [input, running, submit]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
    }
  };

  const handleInput = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    setInput(e.target.value);
    // Auto-resize
    const el = e.target;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 200)}px`;
  };

  return (
    <div className="border-t border-border-default bg-surface-base p-4">
      <div className="mx-auto flex max-w-3xl items-end gap-2">
        <div className="flex-1 rounded-xl border border-border-default bg-surface-raised focus-within:border-border-focus">
          <textarea
            ref={textareaRef}
            value={input}
            onChange={handleInput}
            onKeyDown={handleKeyDown}
            placeholder="Ask anything..."
            rows={1}
            className="w-full resize-none bg-transparent px-4 py-3 text-sm text-text-primary placeholder-text-muted outline-none"
            disabled={running}
          />
        </div>
        {running ? (
          <button
            onClick={stop}
            className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-status-error/20 text-status-error transition-colors hover:bg-status-error/30"
            title="Stop"
          >
            <svg className="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
              <rect x="6" y="6" width="12" height="12" rx="1" />
            </svg>
          </button>
        ) : (
          <button
            onClick={handleSubmit}
            disabled={!input.trim()}
            className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-accent-primary text-white transition-colors hover:bg-accent-hover disabled:opacity-30 disabled:hover:bg-accent-primary"
            title="Send"
          >
            <svg
              className="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              strokeWidth={2}
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M4.5 10.5 12 3m0 0 7.5 7.5M12 3v18"
              />
            </svg>
          </button>
        )}
      </div>
    </div>
  );
}

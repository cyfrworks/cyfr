import { useState, useRef, useCallback } from "react";
import { useAgentStore } from "../../state/agent-store";

export function ComposeBar() {
  const [input, setInput] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const running = useAgentStore((s) => s.running);
  const submit = useAgentStore((s) => s.submit);
  const stop = useAgentStore((s) => s.stop);
  const pendingAttachments = useAgentStore((s) => s.pendingAttachments);
  const addAttachments = useAgentStore((s) => s.addAttachments);
  const removeAttachment = useAgentStore((s) => s.removeAttachment);

  const hasAttachments = pendingAttachments.length > 0;

  const handleSubmit = useCallback(() => {
    const trimmed = input.trim();
    if ((!trimmed && !hasAttachments) || running) return;
    setInput("");
    submit(trimmed);
    // Reset textarea height
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }
  }, [input, running, submit, hasAttachments]);

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

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = e.target.files;
    if (files && files.length > 0) {
      addAttachments(Array.from(files));
    }
    // Reset so same file can be selected again
    e.target.value = "";
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    const files = e.dataTransfer.files;
    if (files && files.length > 0) {
      addAttachments(Array.from(files));
    }
  };

  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
  };

  return (
    <div className="border-t border-border-default bg-surface-base p-4">
      <div className="mx-auto max-w-3xl">
        {/* Attachment chips */}
        {hasAttachments && (
          <div className="mb-2 flex flex-wrap gap-1.5">
            {pendingAttachments.map((att, i) => (
              <span
                key={i}
                className="inline-flex items-center gap-1 rounded-md bg-surface-raised px-2 py-1 text-xs text-text-secondary"
              >
                <svg className="h-3 w-3 shrink-0 text-text-muted" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M18.375 12.739l-7.693 7.693a4.5 4.5 0 01-6.364-6.364l10.94-10.94A3 3 0 1119.5 7.372L8.552 18.32m.009-.01l-.01.01m5.699-9.941l-7.81 7.81a1.5 1.5 0 002.112 2.13" />
                </svg>
                <span className="max-w-[150px] truncate">{att.filename}</span>
                <button
                  onClick={() => removeAttachment(i)}
                  className="ml-0.5 rounded text-text-muted hover:text-status-error"
                >
                  <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </span>
            ))}
          </div>
        )}

        <div className="flex items-end gap-2">
          <div
            className="flex flex-1 items-end gap-1 rounded-xl border border-border-default bg-surface-raised focus-within:border-border-focus"
            onDrop={handleDrop}
            onDragOver={handleDragOver}
          >
            {/* Attachment button */}
            <button
              onClick={() => fileInputRef.current?.click()}
              disabled={running}
              className="mb-2.5 ml-2 shrink-0 rounded p-1 text-text-muted transition-colors hover:text-text-secondary disabled:opacity-30"
              title="Attach files"
            >
              <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M18.375 12.739l-7.693 7.693a4.5 4.5 0 01-6.364-6.364l10.94-10.94A3 3 0 1119.5 7.372L8.552 18.32m.009-.01l-.01.01m5.699-9.941l-7.81 7.81a1.5 1.5 0 002.112 2.13" />
              </svg>
            </button>
            <input
              ref={fileInputRef}
              type="file"
              multiple
              className="hidden"
              onChange={handleFileSelect}
            />

            <textarea
              ref={textareaRef}
              value={input}
              onChange={handleInput}
              onKeyDown={handleKeyDown}
              placeholder="Ask anything..."
              rows={1}
              className="w-full resize-none bg-transparent px-2 py-3 text-sm text-text-primary placeholder-text-muted outline-none"
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
              disabled={!input.trim() && !hasAttachments}
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
    </div>
  );
}

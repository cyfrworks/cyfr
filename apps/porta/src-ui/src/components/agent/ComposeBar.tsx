import { useState, useRef, useCallback, useMemo } from "react";
import { useAgentStore } from "../../state/agent-store";
import { useOrchestratorStore } from "../../state/orchestrator-store";

export function ComposeBar() {
  const [input, setInput] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const running = useAgentStore((s) => s.running);
  const submit = useAgentStore((s) => s.submit);
  const stop = useAgentStore((s) => s.stop);
  const activeOrchestrator = useAgentStore((s) => s.activeOrchestrator);
  const setActiveOrchestrator = useAgentStore((s) => s.setActiveOrchestrator);
  const pendingAttachments = useAgentStore((s) => s.pendingAttachments);
  const addAttachments = useAgentStore((s) => s.addAttachments);
  const removeAttachment = useAgentStore((s) => s.removeAttachment);
  const orchestrators = useOrchestratorStore((s) => s.orchestrators);

  const hasAttachments = pendingAttachments.length > 0;
  const [orchOpen, setOrchOpen] = useState(false);

  // @mention autocomplete state
  const [mentionQuery, setMentionQuery] = useState<string | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);

  const mentionOptions = useMemo(() => {
    if (mentionQuery === null || orchestrators.length === 0) return [];
    const q = mentionQuery.toLowerCase();
    const items = orchestrators.map((o) => ({ label: o.name, value: o.name, title: o.title }));
    if (!q) return items;
    return items.filter((i) => i.label.toLowerCase().includes(q));
  }, [mentionQuery, orchestrators]);

  const handleSubmit = useCallback(() => {
    const trimmed = input.trim();
    if ((!trimmed && !hasAttachments) || running) return;
    setMentionQuery(null);
    setInput("");
    submit(trimmed);
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
    }
  }, [input, running, submit, hasAttachments]);

  const insertMention = useCallback(
    (value: string) => {
      const ta = textareaRef.current;
      if (!ta) return;
      const pos = ta.selectionStart;
      const text = input;
      const before = text.slice(0, pos);
      const atIdx = before.lastIndexOf("@");
      if (atIdx === -1) return;
      const after = text.slice(pos);
      const newText = `${text.slice(0, atIdx)}@${value} ${after}`;
      setInput(newText);
      setMentionQuery(null);
      setTimeout(() => {
        const cursorPos = atIdx + value.length + 2;
        ta.focus();
        ta.setSelectionRange(cursorPos, cursorPos);
      }, 0);
    },
    [input],
  );

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (mentionQuery !== null && mentionOptions.length > 0) {
      if (e.key === "ArrowDown") {
        e.preventDefault();
        setMentionIndex((i) => (i + 1) % mentionOptions.length);
        return;
      }
      if (e.key === "ArrowUp") {
        e.preventDefault();
        setMentionIndex((i) => (i - 1 + mentionOptions.length) % mentionOptions.length);
        return;
      }
      if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey)) {
        e.preventDefault();
        const selected = mentionOptions[mentionIndex];
        if (selected) insertMention(selected.value);
        return;
      }
      if (e.key === "Escape") {
        e.preventDefault();
        setMentionQuery(null);
        return;
      }
    }

    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
    }
  };

  const handleInput = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    const val = e.target.value;
    setInput(val);

    const pos = e.target.selectionStart;
    const textBefore = val.slice(0, pos);
    const atMatch = textBefore.match(/@([^\s@]*)$/);
    if (atMatch && orchestrators.length > 0) {
      setMentionQuery(atMatch[1]!);
      setMentionIndex(0);
    } else {
      setMentionQuery(null);
    }

    const el = e.target;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 200)}px`;
  };

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = e.target.files;
    if (files && files.length > 0) {
      addAttachments(Array.from(files));
    }
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

  const handlePaste = useCallback(
    (e: React.ClipboardEvent) => {
      const items = e.clipboardData.items;
      const files: File[] = [];
      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        if (item?.kind === "file") {
          const file = item.getAsFile();
          if (file) {
            if (file.type.startsWith("image/") && (!file.name || file.name === "image.png")) {
              const ext = file.type.split("/")[1] || "png";
              const ts = new Date().toISOString().replace(/[:.]/g, "-");
              files.push(new File([file], `screenshot-${ts}.${ext}`, { type: file.type }));
            } else {
              files.push(file);
            }
          }
        }
      }
      if (files.length > 0) {
        e.preventDefault();
        addAttachments(files);
      }
    },
    [addAttachments],
  );

  return (
    <div className="border-t border-border-default bg-surface-base px-4 py-3">
      <div className="mx-auto">
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

        {/* Orchestrator selector */}
        {orchestrators.length > 0 && (
          <div className="relative mb-1.5">
            <button
              onClick={() => !running && setOrchOpen(!orchOpen)}
              disabled={running}
              className="inline-flex items-center gap-1 rounded-md border border-border-default bg-surface-raised px-2 py-1 text-xs text-text-secondary transition-colors hover:bg-surface-base disabled:opacity-50"
            >
              <svg className="h-3 w-3 text-accent-primary" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09z" />
              </svg>
              {activeOrchestrator || "Select agent"}
              <svg className="h-3 w-3 text-text-muted" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 8.25l-7.5 7.5-7.5-7.5" />
              </svg>
            </button>
            {orchOpen && (
              <div className="absolute bottom-full left-0 z-50 mb-1 min-w-[180px] rounded-lg border border-border-default bg-surface-raised py-1 shadow-lg">
                {orchestrators.map((o) => (
                  <button
                    key={o.name}
                    onClick={() => {
                      setActiveOrchestrator(o.name);
                      setOrchOpen(false);
                    }}
                    className={`flex w-full items-center gap-2 px-3 py-1.5 text-left text-xs transition-colors hover:bg-surface-base ${
                      activeOrchestrator === o.name ? "text-accent-primary" : "text-text-secondary"
                    }`}
                  >
                    <span className="flex-1 truncate">{o.title || o.name}</span>
                    <span className="text-[10px] text-text-muted">{o.model ? o.model.split("-").slice(0, 2).join("-") : "no model"}</span>
                  </button>
                ))}
              </div>
            )}
          </div>
        )}

        <div className="relative flex items-end gap-2">
          {/* @mention autocomplete popup */}
          {mentionQuery !== null && mentionOptions.length > 0 && (
            <div className="absolute bottom-full left-0 z-50 mb-1 w-64 rounded-lg border border-border-default bg-surface-raised py-1 shadow-lg">
              {mentionOptions.map((opt, i) => (
                <button
                  key={opt.value}
                  onMouseDown={(e) => {
                    e.preventDefault();
                    insertMention(opt.value);
                  }}
                  className={`flex w-full items-center gap-2 px-3 py-1.5 text-left text-xs transition-colors ${
                    i === mentionIndex
                      ? "bg-accent-primary/15 text-accent-primary"
                      : "text-text-secondary hover:bg-surface-base"
                  }`}
                >
                  <span className="text-text-muted">@</span>
                  <span className="flex-1">{opt.label}</span>
                </button>
              ))}
            </div>
          )}

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
              onPaste={handlePaste}
              placeholder="Ask anything... @agent to target"
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

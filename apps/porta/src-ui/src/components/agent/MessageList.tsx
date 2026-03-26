import { useEffect, useRef, useState, useCallback } from "react";
import { useAgentStore, type Message, type Segment, type ParallelExecution } from "../../state/agent-store";
import { Markdown } from "../common/Markdown";
import { ToolActivityCard } from "./ToolActivityCard";
import { SetupForm } from "./SetupForm";

export function MessageList() {
  // Force re-render on store changes — workaround for Zustand v5 subscription
  // issues when the component is inside a display:none container
  const [, forceRender] = useState(0);
  useEffect(() => {
    return useAgentStore.subscribe(() => forceRender((c) => c + 1));
  }, []);

  const messages = useAgentStore((s) => s.messages);
  const running = useAgentStore((s) => s.running);
  const streamSegments = useAgentStore((s) => s.streamSegments);
  const streamingText = useAgentStore((s) => s.streamingText);
  const progress = useAgentStore((s) => s.progress);
  const tokenUsage = useAgentStore((s) => s.tokenUsage);
  const startedAt = useAgentStore((s) => s.startedAt);
  const pendingSetupRef = useAgentStore((s) => s.pendingSetupRef);
  const completeSetup = useAgentStore((s) => s.completeSetup);
  const dismissSetup = useAgentStore((s) => s.dismissSetup);
  const parallelExecutions = useAgentStore((s) => s.parallelExecutions);

  const scrollContainerRef = useRef<HTMLDivElement>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const isNearBottomRef = useRef(true);
  const [showScrollBtn, setShowScrollBtn] = useState(false);

  const hasParallel = Object.keys(parallelExecutions).length > 0;

  // Track scroll position
  const handleScroll = useCallback(() => {
    const el = scrollContainerRef.current;
    if (!el) return;
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
    isNearBottomRef.current = nearBottom;
    setShowScrollBtn(!nearBottom);
  }, []);

  // Auto-scroll only when near bottom
  useEffect(() => {
    if (isNearBottomRef.current) {
      bottomRef.current?.scrollIntoView({ behavior: "smooth" });
    }
  }, [messages.length, streamingText, parallelExecutions, streamSegments, pendingSetupRef]);

  const scrollToBottom = useCallback(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, []);

  // Restore scroll position when container becomes visible after CSS hidden toggle
  // Only scrolls on 0→>0 height transition (not on window resize/sidebar toggle)
  useEffect(() => {
    const el = scrollContainerRef.current;
    if (!el) return;
    let prevHeight = 0;
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const h = entry.contentRect.height;
        if (prevHeight === 0 && h > 0 && messages.length > 0) {
          bottomRef.current?.scrollIntoView();
        }
        prevHeight = h;
      }
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, [messages.length]);

  return (
    <div className="relative flex-1">
      <div
        ref={scrollContainerRef}
        className="absolute inset-0 overflow-y-auto px-4 py-6"
        onScroll={handleScroll}
      >
        <div className="mx-auto max-w-3xl space-y-4">
          {messages.length === 0 && !running && <EmptyState />}

          {messages.map((msg, i) => (
            <MessageView key={i} message={msg} />
          ))}

          {/* Single-target streaming message */}
          {running && !hasParallel && (
            <div className="flex gap-3">
            <img
              src="/logo.jpg"
              alt="AQUA"
              className="h-7 w-7 shrink-0 rounded-lg object-cover mt-1"
            />
            <div className="min-w-0 flex-1 rounded-xl bg-surface-raised p-4">
              {streamSegments.map((seg, i) => (
                <SegmentView key={i} segment={seg} isLast={i === streamSegments.length - 1} />
              ))}

              {!streamingText && progress && (
                <div className="flex items-center gap-2">
                  <LoadingDots />
                  <span className="text-sm text-text-muted">{progress}</span>
                </div>
              )}

              <div className="mt-3 flex items-center gap-3 text-xs text-text-muted">
                {progress && streamingText && (
                  <span>{progress}</span>
                )}
                {(tokenUsage.input > 0 || tokenUsage.output > 0) && (
                  <span>
                    {tokenUsage.input.toLocaleString()}↑ {tokenUsage.output.toLocaleString()}↓
                  </span>
                )}
                {startedAt && <ElapsedTime startedAt={startedAt} />}
              </div>
            </div>
            </div>
          )}

          {/* Parallel execution streaming */}
          {running && hasParallel && (
            <div className="space-y-3">
              {Object.entries(parallelExecutions).map(([execId, pe]) => (
                <ParallelExecutionView key={execId} pe={pe} />
              ))}
              {progress && (
                <div className="text-center text-xs text-text-muted">{progress}</div>
              )}
            </div>
          )}

          {/* Inline setup form */}
          {pendingSetupRef && (
            <SetupForm
              componentRef={pendingSetupRef}
              onComplete={completeSetup}
              onDismiss={dismissSetup}
            />
          )}

          <div ref={bottomRef} />
        </div>
      </div>

      {/* Scroll-to-bottom button — outside scroll container so it stays pinned */}
      {showScrollBtn && (
        <button
          onClick={scrollToBottom}
          className="absolute bottom-4 left-1/2 z-10 flex h-8 w-8 -translate-x-1/2 items-center justify-center rounded-full border border-border-default bg-surface-raised shadow-md transition-colors hover:bg-surface-base"
          title="Scroll to bottom"
        >
          <svg className="h-4 w-4 text-text-secondary" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 13.5L12 21m0 0l-7.5-7.5M12 21V3" />
          </svg>
        </button>
      )}
    </div>
  );
}

function ParallelExecutionView({ pe }: { pe: ParallelExecution }) {
  return (
    <div className="flex gap-3">
      <img
        src="/logo.jpg"
        alt="AQUA"
        className="h-7 w-7 shrink-0 rounded-lg object-cover mt-1"
      />
      <div className="min-w-0 flex-1 rounded-xl bg-surface-raised p-4">
        {/* Preset badge */}
        <div className="mb-2">
          <span className="inline-flex items-center gap-1 rounded-md bg-accent-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-accent-primary">
            <svg className="h-2.5 w-2.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09z" />
            </svg>
            {pe.presetName}
          </span>
        </div>

        {/* Segments */}
        {pe.segments.map((seg, i) => (
          <SegmentView key={i} segment={seg} isLast={i === pe.segments.length - 1} />
        ))}

        {/* Thinking indicator — show when no content yet */}
        {!pe.text && (
          <div className="flex items-center gap-2">
            <LoadingDots />
            <span className="text-sm text-text-muted">Thinking...</span>
          </div>
        )}

        {/* Footer */}
        <div className="mt-3 flex items-center gap-3 text-xs text-text-muted">
          {pe.currentTurn > 0 && <span>Turn {pe.currentTurn}</span>}
          {(pe.tokenUsage.input > 0 || pe.tokenUsage.output > 0) && (
            <span>
              {pe.tokenUsage.input.toLocaleString()}↑ {pe.tokenUsage.output.toLocaleString()}↓
            </span>
          )}
          <ElapsedTime startedAt={pe.startedAt} />
        </div>
      </div>
    </div>
  );
}

function MessageView({ message }: { message: Message }) {
  if (message.role === "user") {
    return (
      <div className="flex justify-end">
        <div className="max-w-[80%] rounded-xl bg-accent-primary/15 px-4 py-3">
          {message.attachments && message.attachments.length > 0 && (
            <div className="mb-1.5 flex flex-wrap gap-1">
              {message.attachments.map((att, i) => (
                <span
                  key={i}
                  className="inline-flex items-center gap-1 rounded bg-accent-primary/10 px-1.5 py-0.5 text-[10px] text-text-secondary"
                >
                  <svg className="h-2.5 w-2.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M18.375 12.739l-7.693 7.693a4.5 4.5 0 01-6.364-6.364l10.94-10.94A3 3 0 1119.5 7.372L8.552 18.32m.009-.01l-.01.01m5.699-9.941l-7.81 7.81a1.5 1.5 0 002.112 2.13" />
                  </svg>
                  {att.filename}
                </span>
              ))}
            </div>
          )}
          <p className="text-sm text-text-primary whitespace-pre-wrap">
            {message.content}
          </p>
        </div>
      </div>
    );
  }

  if (message.role === "error") {
    return (
      <div className="rounded-xl border border-status-error/30 bg-status-error/10 px-4 py-3">
        <p className="text-sm text-status-error">{message.content}</p>
      </div>
    );
  }

  // Assistant message
  return (
    <div className="flex gap-3">
      <img
        src="/logo.jpg"
        alt="AQUA"
        className="h-7 w-7 shrink-0 rounded-lg object-cover mt-1"
      />
      <div className="min-w-0 flex-1 rounded-xl bg-surface-raised p-4">
      {/* Preset badge */}
      {message.preset && (
        <div className="mb-2">
          <span className="inline-flex items-center gap-1 rounded-md bg-accent-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-accent-primary">
            <svg className="h-2.5 w-2.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09z" />
            </svg>
            {message.preset}
          </span>
        </div>
      )}
      {message.segments ? (
        message.segments.map((seg, i) => (
          <SegmentView key={i} segment={seg} isLast={i === message.segments!.length - 1} />
        ))
      ) : (
        <Markdown content={message.content} />
      )}

      {/* Message footer */}
      {(message.turns || message.durationSeconds || message.tokenUsage) && (
        <div className="mt-3 flex items-center gap-3 border-t border-border-default pt-2 text-xs text-text-muted">
          {message.turns && <span>{message.turns} turn{message.turns > 1 ? "s" : ""}</span>}
          {message.durationSeconds && <span>{message.durationSeconds}s</span>}
          {message.tokenUsage && (
            <span>
              {message.tokenUsage.input.toLocaleString()}↑{" "}
              {message.tokenUsage.output.toLocaleString()}↓
            </span>
          )}
        </div>
      )}
      </div>
    </div>
  );
}

function SegmentView({ segment, isLast }: { segment: Segment; isLast: boolean }) {
  return (
    <div className={isLast ? "" : "mb-3"}>
      {/* Tool activity cards */}
      {segment.tools.map((entry, i) => (
        <ToolActivityCard key={i} entry={entry} />
      ))}

      {/* Segment text */}
      {segment.text && <Markdown content={segment.text} />}
    </div>
  );
}

function EmptyState() {
  return (
    <div className="flex flex-col items-center justify-center py-20">
      <img
        src="/logo.jpg"
        alt="CYFR"
        className="h-14 w-14 rounded-2xl object-cover"
      />
      <h2 className="mt-4 text-lg font-semibold text-text-primary">
        What can I help you with?
      </h2>
      <p className="mt-1 text-sm text-text-secondary">
        Ask a question or start a task
      </p>
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

function ElapsedTime({ startedAt }: { startedAt: number }) {
  const [, setTick] = useState(0);
  const elapsed = Math.round((Date.now() - startedAt) / 1000);
  const mins = Math.floor(elapsed / 60);
  const secs = elapsed % 60;

  useEffect(() => {
    const interval = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(interval);
  }, []);

  return (
    <span>
      {mins > 0 ? `${mins}m ${secs}s` : `${secs}s`}
    </span>
  );
}

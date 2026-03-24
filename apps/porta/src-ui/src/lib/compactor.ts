/**
 * Conversation compactor — TypeScript port of Prism.ConversationCompactor.
 *
 * Strategy: sliding window with tool result truncation.
 * 1. Estimate token count (chars / 4)
 * 2. If under threshold, pass through unchanged
 * 3. If over: truncate tool results in older messages, then drop oldest
 *    messages until under budget — always preserving the last 6 messages
 */

const TOKEN_BUDGET_CHARS = 320_000; // ~80k tokens
const TRUNCATED_RESULT_CHARS = 500;
const PRESERVE_RECENT = 6;

type Message = Record<string, unknown>;

export function compact(messages: unknown): unknown[] {
  if (!Array.isArray(messages)) return messages as unknown[];

  const msgs = messages as Message[];
  const totalChars = estimateChars(msgs);

  if (totalChars <= TOKEN_BUDGET_CHARS) return msgs;

  return doCompact(msgs);
}

function doCompact(messages: Message[]): Message[] {
  const splitAt = Math.max(messages.length - PRESERVE_RECENT, 0);
  const older = messages.slice(0, splitAt);
  const recent = messages.slice(splitAt);

  // Phase 1: truncate tool results in older messages
  const truncatedOlder = older.map(truncateToolResults);

  const candidate = [...truncatedOlder, ...recent];
  if (estimateChars(candidate) <= TOKEN_BUDGET_CHARS) return candidate;

  // Phase 2: drop oldest messages
  return dropUntilFits(truncatedOlder, recent);
}

function dropUntilFits(older: Message[], recent: Message[]): Message[] {
  let remaining = older;
  while (remaining.length > 0) {
    const candidate = [...remaining, ...recent];
    if (estimateChars(candidate) <= TOKEN_BUDGET_CHARS) return candidate;
    remaining = remaining.slice(1);
  }
  return recent;
}

// Tool result truncation — handles Claude, OpenAI, and Gemini formats

function truncateToolResults(msg: Message): Message {
  // OpenAI format: role=tool, content=string
  if (msg.role === "tool" && typeof msg.content === "string") {
    if (msg.content.length > TRUNCATED_RESULT_CHARS) {
      return {
        ...msg,
        content:
          msg.content.slice(0, TRUNCATED_RESULT_CHARS) + "... [truncated]",
      };
    }
    return msg;
  }

  // Claude format: role=user, content=[{type: "tool_result", ...}]
  if (msg.role === "user" && Array.isArray(msg.content)) {
    const updated = (msg.content as Message[]).map((part) => {
      if (part.type !== "tool_result") return part;

      // Simple text content
      if (typeof part.content === "string") {
        if (part.content.length > TRUNCATED_RESULT_CHARS) {
          return {
            ...part,
            content:
              (part.content as string).slice(0, TRUNCATED_RESULT_CHARS) +
              "... [truncated]",
          };
        }
        return part;
      }

      // Nested content blocks
      if (Array.isArray(part.content)) {
        const truncatedNested = (part.content as Message[]).map((inner) => {
          if (
            inner.type === "text" &&
            typeof inner.text === "string" &&
            (inner.text as string).length > TRUNCATED_RESULT_CHARS
          ) {
            return {
              ...inner,
              text:
                (inner.text as string).slice(0, TRUNCATED_RESULT_CHARS) +
                "... [truncated]",
            };
          }
          return inner;
        });
        return { ...part, content: truncatedNested };
      }

      return part;
    });
    return { ...msg, content: updated };
  }

  // Gemini format: role=user, parts=[{functionResponse: {response: ...}}]
  if (msg.role === "user" && Array.isArray(msg.parts)) {
    const updated = (msg.parts as Message[]).map((part) => {
      const fr = part.functionResponse as Message | undefined;
      if (!fr?.response || typeof fr.response !== "object") return part;

      const json = JSON.stringify(fr.response);
      if (json.length <= TRUNCATED_RESULT_CHARS) return part;

      const truncated =
        json.slice(0, TRUNCATED_RESULT_CHARS) + "... [truncated]";
      try {
        const decoded = JSON.parse(truncated) as unknown;
        return {
          ...part,
          functionResponse: { ...fr, response: decoded },
        };
      } catch {
        return {
          ...part,
          functionResponse: { ...fr, response: { truncated } },
        };
      }
    });
    return { ...msg, parts: updated };
  }

  return msg;
}

// Size estimation

function estimateChars(messages: Message[]): number {
  return messages.reduce((acc, msg) => acc + messageChars(msg), 0);
}

function messageChars(msg: Message): number {
  const content = msg.content;
  const parts = msg.parts;

  if (typeof content === "string") return content.length;
  if (Array.isArray(content))
    return (content as Message[]).reduce(
      (acc, block) => acc + blockChars(block),
      0,
    );
  if (Array.isArray(parts))
    return (parts as Message[]).reduce(
      (acc, block) => acc + blockChars(block),
      0,
    );
  return 0;
}

function blockChars(block: Message): number {
  if (typeof block.text === "string") return (block.text as string).length;
  if (typeof block.content === "string")
    return (block.content as string).length;
  if (Array.isArray(block.content))
    return (block.content as Message[]).reduce(
      (acc, inner) => acc + blockChars(inner),
      0,
    );
  if (block.functionResponse) {
    const fr = block.functionResponse as Message;
    if (fr.response && typeof fr.response === "object") {
      return JSON.stringify(fr.response).length;
    }
  }
  return 50;
}

import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { McpClient } from "../api/mcp-client";
import { connectSSE, type SSEConnection } from "../api/sse-client";
import { compact } from "../lib/compactor";
import type {
  ExecutionEvent,
  SerializedMessage,
  SerializedSegment,
  SerializedToolEntry,
  SerializedSubEvent,
  ConversationFile,
} from "../api/types";
import { useConnectionStore } from "./connection-store";

const AGENT_REF = "formula:local.agent";
const DEFAULT_VISIBLE_TOOLS = [
  "execution",
  "guide",
  "system",
  "native_search",
  "component",
  "storage",
  "builder",
  "explorer",
  "files",
  "mcp_servers",
  "request_setup",
];
const SUB_AGENT_TOOLS = new Set(["builder", "explorer"]);

export interface ToolEntry {
  tool: string;
  status: "running" | "done" | "error" | "pending" | "cancelled";
  turn: number;
  preview: string | null;
  input: unknown;
  emitTag: string | null;
  subEvents: SubEvent[];
}

export interface SubEvent {
  kind: "turn_start" | "tool_use" | "tool_result" | "text_delta";
  turn?: number;
  tool?: string;
  status?: string;
  preview?: string;
  content?: string;
}

export interface Segment {
  turn: number;
  tools: ToolEntry[];
  text: string;
}

export interface Message {
  role: "user" | "assistant" | "error";
  content: string;
  timestamp: string;
  segments?: Segment[];
  turns?: number;
  durationSeconds?: number;
  tokenUsage?: { input: number; output: number };
  attachments?: { filename: string; mediaType: string }[];
}

export interface AgentState {
  // Conversation state
  messages: Message[];
  conversationHistory: unknown[];
  conversationId: string | null;

  // Execution state
  running: boolean;
  progress: string | null;
  streamingText: string;
  streamSegments: Segment[];
  currentTurn: number;
  currentExecutionId: string | null;
  tokenUsage: { input: number; output: number };
  startedAt: number | null;

  // Model selection
  provider: string;
  model: string;
  catalystRef: string;

  // Setup state
  pendingSetupRef: string | null;
  pendingRetryInput: string | null;

  // MCP client
  client: McpClient | null;
  sseConnection: SSEConnection | null;

  // Actions
  initClient: () => Promise<void>;
  submit: (message: string) => Promise<void>;
  stop: () => Promise<void>;
  newChat: () => void;
  loadConversation: (conv: ConversationFile) => void;
  setModel: (provider: string, model: string, catalystRef: string) => void;
  completeSetup: () => void;
  dismissSetup: () => void;

  // Internal
  handleEvent: (event: ExecutionEvent) => void;
  finalizeMessage: () => void;
  persistConversation: () => Promise<void>;
}

function generateConversationId(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  const hex = Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `conv_${hex}`;
}

export const useAgentStore = create<AgentState>((set, get) => ({
  messages: [],
  conversationHistory: [],
  conversationId: null,
  running: false,
  progress: null,
  streamingText: "",
  streamSegments: [],
  currentTurn: 0,
  currentExecutionId: null,
  tokenUsage: { input: 0, output: 0 },
  startedAt: null,
  provider: "",
  model: "",
  catalystRef: "",
  pendingSetupRef: null,
  pendingRetryInput: null,
  client: null,
  sseConnection: null,

  initClient: async () => {
    const { cyfrUrl } = useConnectionStore.getState();
    const client = new McpClient(cyfrUrl);
    // Read session from CLI config instead of initializing a new one
    const savedSession = await invoke<string | null>("read_cli_session");
    if (savedSession) {
      client.sessionId = savedSession;
    } else {
      await client.initialize();
    }
    set({ client });

    // Restore model preferences from disk
    try {
      const prefs = await invoke<Record<string, string> | null>("load_prefs");
      if (prefs?.provider) {
        set({
          provider: prefs.provider,
          model: prefs.model ?? "",
          catalystRef: prefs.catalyst_ref ?? `catalyst:moonmoon69.${prefs.provider}:1.0.0`,
        });
      }
    } catch {
      // No prefs saved yet
    }
  },

  submit: async (message: string) => {
    const state = get();

    if (!state.catalystRef || !state.model) {
      const errorMsg: Message = {
        role: "error",
        content: "No model selected. Go to Settings → Providers to configure a provider and select a model.",
        timestamp: new Date().toISOString(),
      };
      set({ messages: [...state.messages, errorMsg] });
      return;
    }

    // Always create a fresh MCP client with the current CLI session
    const { cyfrUrl } = useConnectionStore.getState();
    const client = new McpClient(cyfrUrl);
    const savedSession = await invoke<string | null>("read_cli_session");
    if (savedSession) {
      client.sessionId = savedSession;
    } else {
      await client.initialize();
    }
    set({ client });

    const convId = state.conversationId ?? generateConversationId();

    // Add user message
    const userMessage: Message = {
      role: "user",
      content: message,
      timestamp: new Date().toISOString(),
    };

    const updatedMessages = [...state.messages, userMessage];

    set({
      messages: updatedMessages,
      conversationId: convId,
      running: true,
      progress: "Thinking...",
      streamingText: "",
      streamSegments: [],
      currentTurn: 0,
      tokenUsage: { input: 0, output: 0 },
      startedAt: Date.now(),
    });

    try {
      // Build system prompt
      let systemPrompt =
        "You are an agent running inside CYFR, a governed computation platform.";
      try {
        const guideResult = await client.callTool("guide", {
          action: "get",
          name: "agent-guide",
        });
        if (guideResult.content && typeof guideResult.content === "string") {
          systemPrompt = guideResult.content;
        }
      } catch {
        // Use fallback
      }

      // Add runtime context
      const now = new Date();
      systemPrompt += `\n\nCurrent date: ${now.toISOString().split("T")[0]}`;
      systemPrompt += `\nCurrent time: ${now.toLocaleTimeString()}`;

      // Compact conversation history
      const history = compact(state.conversationHistory);

      // Build execution input
      const input: Record<string, unknown> = {
        catalyst_ref: state.catalystRef,
        model: state.model || undefined,
        task: message,
        system: systemPrompt,
        visible_tools: DEFAULT_VISIBLE_TOOLS,
        messages: history,
      };

      // Call execution tool with run_stream
      const result = await client.callTool("execution", {
        action: "run_stream",
        reference: AGENT_REF,
        input,
      });

      const executionId = result.execution_id as string;
      if (!executionId) {
        throw new Error("No execution_id in response");
      }

      set({ currentExecutionId: executionId });

      // Connect to SSE stream via Tauri proxy
      const sseConnection = connectSSE("", {
        executionId,
        onEvent: (event) => get().handleEvent(event),
        onError: (err) => {
          const s = get();
          if (s.running) {
            const errorMsg: Message = {
              role: "error",
              content: `Stream error: ${err.message}`,
              timestamp: new Date().toISOString(),
            };
            set({
              messages: [...s.messages, errorMsg],
              running: false,
              progress: null,
              sseConnection: null,
            });
          }
        },
        onClose: () => {
          const s = get();
          if (s.running) {
            s.finalizeMessage();
          }
          set({ sseConnection: null });
        },
      });

      set({ sseConnection });
    } catch (err) {
      const errorMsg: Message = {
        role: "error",
        content: `Error: ${err instanceof Error ? err.message : String(err)}`,
        timestamp: new Date().toISOString(),
      };
      set({
        messages: [...get().messages, errorMsg],
        running: false,
        progress: null,
      });
    }
  },

  stop: async () => {
    const { sseConnection, client, currentExecutionId } = get();
    sseConnection?.close();

    if (client && currentExecutionId) {
      try {
        await client.callTool("execution", {
          action: "cancel",
          execution_id: currentExecutionId,
        });
      } catch {
        // Best-effort
      }
    }

    get().finalizeMessage();
  },

  newChat: () => {
    const { sseConnection } = get();
    sseConnection?.close();
    set({
      messages: [],
      conversationHistory: [],
      conversationId: null,
      running: false,
      progress: null,
      streamingText: "",
      streamSegments: [],
      currentTurn: 0,
      currentExecutionId: null,
      tokenUsage: { input: 0, output: 0 },
      startedAt: null,
      sseConnection: null,
    });
  },

  loadConversation: (conv: ConversationFile) => {
    const { sseConnection } = get();
    sseConnection?.close();

    const messages: Message[] = conv.messages.map(deserializeMessage);

    set({
      messages,
      conversationHistory: conv.conversation_history ?? [],
      conversationId: conv.id,
      running: false,
      progress: null,
      streamingText: "",
      streamSegments: [],
      currentTurn: 0,
      currentExecutionId: null,
      tokenUsage: { input: 0, output: 0 },
      startedAt: null,
      provider: conv.provider || "claude",
      model: conv.model || "",
      sseConnection: null,
    });
  },

  completeSetup: () => {
    const state = get();
    const retryInput = state.pendingRetryInput;

    // Add confirmation message
    const confirmMsg: Message = {
      role: "assistant",
      content: `Setup complete for ${state.pendingSetupRef}. ${retryInput ? "Resuming your task..." : ""}`,
      timestamp: new Date().toISOString(),
    };

    set({
      messages: [...state.messages, confirmMsg],
      pendingSetupRef: null,
      pendingRetryInput: null,
      progress: null,
    });

    // Auto-retry the original task
    if (retryInput) {
      setTimeout(() => get().submit(retryInput), 500);
    }
  },

  dismissSetup: () => {
    set({
      pendingSetupRef: null,
      pendingRetryInput: null,
      progress: null,
    });
  },

  setModel: (provider, model, catalystRef) => {
    set({ provider, model, catalystRef });
    // Persist to disk
    invoke("save_prefs", { provider, model, catalystRef }).catch(() => {});
  },

  handleEvent: (event: ExecutionEvent) => {
    const state = get();

    if (event.type === "complete") {
      state.finalizeMessage();
      return;
    }

    if (event.type === "error") {
      const data = event.data as Record<string, unknown>;
      const errorMsg: Message = {
        role: "error",
        content: `Execution error: ${(data.message as string) ?? "Unknown error"}`,
        timestamp: new Date().toISOString(),
      };
      set({
        messages: [...state.messages, errorMsg],
        running: false,
        progress: null,
      });
      return;
    }

    if (event.type !== "emit") return;

    const data = event.data as Record<string, unknown>;
    const kind = data.kind as string;

    // Check if this is a sub-agent event (has emit_tag)
    const emitTag = data.emit_tag as string | undefined;
    if (emitTag) {
      handleSubAgentEvent(set, get, emitTag, data);
      return;
    }

    switch (kind) {
      case "turn_start": {
        const turn = (data.turn as number) ?? state.currentTurn + 1;
        const newSegment: Segment = { turn, tools: [], text: "" };
        set({
          streamSegments: [...state.streamSegments, newSegment],
          currentTurn: turn,
          progress: `Turn ${turn}...`,
        });
        break;
      }

      case "text_delta": {
        const content = (data.content as string) ?? "";
        const segments = [...state.streamSegments];
        const current = segments[segments.length - 1];
        if (current) {
          segments[segments.length - 1] = {
            ...current,
            text: current.text + content,
          };
        }
        set({
          streamingText: state.streamingText + content,
          streamSegments: segments,
          progress: "Writing...",
        });
        break;
      }

      case "tool_use": {
        const tool = data.tool as string;
        const toolCallId = data.tool_call_id as string | undefined;
        const entry: ToolEntry = {
          tool,
          status: "running",
          turn: state.currentTurn,
          preview: null,
          input: data.input ?? null,
          emitTag: SUB_AGENT_TOOLS.has(tool) && toolCallId
            ? `${tool}:${toolCallId}`
            : null,
          subEvents: [],
        };

        const segments = [...state.streamSegments];
        const current = segments[segments.length - 1];
        if (current) {
          segments[segments.length - 1] = {
            ...current,
            tools: [...current.tools, entry],
          };
        }
        set({
          streamSegments: segments,
          progress: `Using ${tool}...`,
        });
        break;
      }

      case "tool_result": {
        const tool = data.tool as string;
        const preview = (data.preview as string) ?? null;
        const segments = [...state.streamSegments];

        // Find last running tool with this name
        for (let si = segments.length - 1; si >= 0; si--) {
          const seg = segments[si]!;
          for (let ti = seg.tools.length - 1; ti >= 0; ti--) {
            const t = seg.tools[ti]!;
            if (t.tool === tool && t.status === "running") {
              const updatedTools = [...seg.tools];
              updatedTools[ti] = { ...t, status: "done", preview };
              segments[si] = { ...seg, tools: updatedTools };
              set({
                streamSegments: segments,
                progress: `${tool} completed`,
              });
              return;
            }
          }
        }
        break;
      }

      case "usage": {
        const input = (data.input_tokens as number) ?? 0;
        const output = (data.output_tokens as number) ?? 0;
        set({
          tokenUsage: {
            input: state.tokenUsage.input + input,
            output: state.tokenUsage.output + output,
          },
        });
        break;
      }

      case "conversation_complete": {
        const messages = data.messages as unknown[];
        if (Array.isArray(messages)) {
          set({ conversationHistory: messages });
        }
        break;
      }

      case "setup_required":
      case "request_setup": {
        const componentRef = (data.component_ref ?? "") as string;
        if (componentRef) {
          // Save the last user message for auto-retry after setup
          const lastUserMsg = state.messages
            .slice()
            .reverse()
            .find((m) => m.role === "user");
          set({
            pendingSetupRef: componentRef,
            pendingRetryInput: lastUserMsg?.content ?? null,
            progress: "Setup required",
          });
        }
        break;
      }
    }
  },

  finalizeMessage: () => {
    const state = get();
    if (!state.running && state.streamSegments.length === 0) return;

    const duration = state.startedAt
      ? Math.round((Date.now() - state.startedAt) / 1000)
      : 0;

    const assistantMessage: Message = {
      role: "assistant",
      content: state.streamingText,
      timestamp: new Date().toISOString(),
      segments:
        state.streamSegments.length > 0 ? state.streamSegments : undefined,
      turns: state.currentTurn || undefined,
      durationSeconds: duration || undefined,
      tokenUsage:
        state.tokenUsage.input > 0 || state.tokenUsage.output > 0
          ? state.tokenUsage
          : undefined,
    };

    set({
      messages: [...state.messages, assistantMessage],
      running: false,
      progress: null,
      streamingText: "",
      streamSegments: [],
      currentTurn: 0,
      currentExecutionId: null,
      startedAt: null,
    });

    // Persist and refresh conversation list
    get().persistConversation().then(() => {
      import("./conversation-store").then(({ useConversationStore }) => {
        useConversationStore.getState().loadConversations();
      });
    });
  },

  persistConversation: async () => {
    const state = get();
    const { conversationId, messages, conversationHistory } = state;
    if (!conversationId) return;

    const firstUserMsg = messages.find((m) => m.role === "user");
    const title = firstUserMsg
      ? firstUserMsg.content.slice(0, 80)
      : "Untitled";

    const convFile: ConversationFile = {
      id: conversationId,
      title,
      created_at:
        messages[0]?.timestamp ?? new Date().toISOString(),
      updated_at: new Date().toISOString(),
      provider: state.provider,
      model: state.model,
      messages: messages.map(serializeMessage),
      conversation_history: conversationHistory,
      execution_id: state.currentExecutionId,
      running: state.running,
    };

    try {
      const json = JSON.stringify(convFile);
      await invoke("cyfr_command", {
        args: [
          "run",
          "catalyst:local.files",
          "--input",
          JSON.stringify({
            action: "write_text",
            path: `data/agent_conversations/${conversationId}.json`,
            content: json,
          }),
        ],
      });
    } catch {
      // Silent — don't break UX for persistence failures
    }
  },
}));

// Sub-agent event handler
function handleSubAgentEvent(
  set: (partial: Partial<AgentState>) => void,
  get: () => AgentState,
  emitTag: string,
  data: Record<string, unknown>,
) {
  const state = get();
  const kind = data.kind as string;
  const segments = [...state.streamSegments];

  // Find the tool entry with this emit_tag
  for (let si = segments.length - 1; si >= 0; si--) {
    const seg = segments[si]!;
    for (let ti = seg.tools.length - 1; ti >= 0; ti--) {
      const tool = seg.tools[ti]!;
      if (tool.emitTag !== emitTag) continue;

      const subEvent: SubEvent = { kind: kind as SubEvent["kind"] };

      switch (kind) {
        case "turn_start":
          subEvent.turn = data.turn as number;
          break;
        case "tool_use":
          subEvent.tool = data.tool as string;
          subEvent.status = "running";
          break;
        case "tool_result":
          subEvent.tool = data.tool as string;
          subEvent.preview = data.preview as string;
          // Also mark the sub tool_use as done
          for (let i = tool.subEvents.length - 1; i >= 0; i--) {
            const se = tool.subEvents[i]!;
            if (se.kind === "tool_use" && se.tool === data.tool && se.status === "running") {
              const updatedSubs = [...tool.subEvents];
              updatedSubs[i] = { ...se, status: "done" };
              const updatedTool = { ...tool, subEvents: updatedSubs };
              const updatedTools = [...seg.tools];
              updatedTools[ti] = updatedTool;
              segments[si] = { ...seg, tools: updatedTools };
              set({ streamSegments: segments });
              return;
            }
          }
          break;
        case "text_delta": {
          // Coalesce consecutive text_delta events
          const lastSub = tool.subEvents[tool.subEvents.length - 1];
          if (lastSub?.kind === "text_delta") {
            const updatedSubs = [...tool.subEvents];
            updatedSubs[updatedSubs.length - 1] = {
              ...lastSub,
              content: (lastSub.content ?? "") + ((data.content as string) ?? ""),
            };
            const updatedTool = { ...tool, subEvents: updatedSubs };
            const updatedTools = [...seg.tools];
            updatedTools[ti] = updatedTool;
            segments[si] = { ...seg, tools: updatedTools };
            set({ streamSegments: segments });
            return;
          }
          subEvent.content = data.content as string;
          break;
        }
      }

      const updatedTool = {
        ...tool,
        subEvents: [...tool.subEvents, subEvent],
      };
      const updatedTools = [...seg.tools];
      updatedTools[ti] = updatedTool;
      segments[si] = { ...seg, tools: updatedTools };
      set({ streamSegments: segments });
      return;
    }
  }
}

// Serialization helpers

function serializeMessage(msg: Message): SerializedMessage {
  return {
    role: msg.role,
    content: msg.content,
    timestamp: msg.timestamp,
    turns: msg.turns,
    duration_seconds: msg.durationSeconds,
    token_usage: msg.tokenUsage,
    segments: msg.segments?.map(serializeSegment),
    attachments: msg.attachments?.map((a) => ({
      filename: a.filename,
      media_type: a.mediaType,
    })),
  };
}

function serializeSegment(seg: Segment): SerializedSegment {
  return {
    turn: seg.turn,
    text: seg.text,
    tools: seg.tools.map(serializeToolEntry),
  };
}

function serializeToolEntry(entry: ToolEntry): SerializedToolEntry {
  return {
    tool: entry.tool,
    status: entry.status,
    preview: entry.preview ?? undefined,
    input: entry.input ?? undefined,
    emit_tag: entry.emitTag ?? undefined,
    sub_events:
      entry.subEvents.length > 0
        ? entry.subEvents.map(serializeSubEvent)
        : undefined,
  };
}

function serializeSubEvent(se: SubEvent): SerializedSubEvent {
  return {
    kind: se.kind,
    turn: se.turn,
    tool: se.tool,
    status: se.status,
    preview: se.preview,
    content: se.content,
  };
}

function deserializeMessage(msg: SerializedMessage): Message {
  return {
    role: msg.role,
    content: msg.content,
    timestamp: msg.timestamp,
    turns: msg.turns,
    durationSeconds: msg.duration_seconds,
    tokenUsage: msg.token_usage,
    segments: msg.segments?.map(deserializeSegment),
    attachments: msg.attachments?.map((a) => ({
      filename: a.filename,
      mediaType: a.media_type,
    })),
  };
}

function deserializeSegment(seg: SerializedSegment): Segment {
  return {
    turn: seg.turn,
    text: seg.text,
    tools: seg.tools.map((t) => ({
      tool: t.tool,
      status: t.status,
      turn: 0,
      preview: t.preview ?? null,
      input: t.input ?? null,
      emitTag: t.emit_tag ?? null,
      subEvents: t.sub_events ?? [],
    })),
  };
}

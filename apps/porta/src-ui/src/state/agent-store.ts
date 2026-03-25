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
import { friendlyError } from "../api/errors";

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
  preset?: string;
  targets?: string[];
  segments?: Segment[];
  turns?: number;
  durationSeconds?: number;
  tokenUsage?: { input: number; output: number };
  attachments?: { filename: string; mediaType: string }[];
}

export interface Attachment {
  filename: string;
  mediaType: string;
  data: string; // base64
}

export interface ParallelExecution {
  presetName: string;
  text: string;
  segments: Segment[];
  currentTurn: number;
  tokenUsage: { input: number; output: number };
  startedAt: number;
  sseConnection: SSEConnection | null;
  conversationHistory: unknown[];
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
  cancelRequested: boolean;

  // Background executions (executionId -> conversationId)
  backgroundExecutions: Record<string, string>;

  // Parallel executions (executionId -> per-execution state)
  parallelExecutions: Record<string, ParallelExecution>;

  // Accumulated conversation histories from completed parallel executions
  completedParallelHistories: Array<{ preset: string; messages: unknown[] }>;

  // Model selection
  provider: string;
  model: string;
  catalystRef: string;

  // Active preset for current conversation
  activePreset: string | null;

  // Setup state
  pendingSetupRef: string | null;
  pendingRetryInput: string | null;

  // File attachments (pending for next submit)
  pendingAttachments: Attachment[];

  // MCP client
  client: McpClient | null;
  sseConnection: SSEConnection | null;

  // Actions
  initClient: () => Promise<void>;
  submit: (message: string) => Promise<void>;
  stop: () => Promise<void>;
  newChat: () => void;
  loadConversation: (conv: ConversationFile) => void;
  reconnectExecution: (executionId: string) => Promise<void>;
  reconnectParallelExecutions: (parallelIds: Record<string, string>) => Promise<void>;
  setModel: (provider: string, model: string, catalystRef: string) => void;
  setActivePreset: (presetName: string) => void;
  completeSetup: () => void;
  dismissSetup: () => void;
  addAttachments: (files: File[]) => Promise<void>;
  removeAttachment: (index: number) => void;
  clearAttachments: () => void;

  // Internal
  handleEvent: (event: ExecutionEvent) => void;
  handleParallelEvent: (executionId: string, event: ExecutionEvent) => void;
  finalizeMessage: () => void;
  finalizeParallelExecution: (executionId: string) => void;
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

/** Derive a provider-specific progress label from the catalyst ref */
function providerProgressLabel(catalystRef: string): string {
  const ref = catalystRef.toLowerCase();
  if (ref.includes("claude")) return "Calling Claude...";
  if (ref.includes("openai")) return "Calling OpenAI...";
  if (ref.includes("gemini")) return "Calling Gemini...";
  if (ref.includes("grok")) return "Calling Grok...";
  if (ref.includes("openrouter")) return "Calling OpenRouter...";
  return "Thinking...";
}

/**
 * Parse @mentions from a message. Only exact preset name matches are extracted.
 * `@all` is a reserved keyword matching all presets.
 * Unmatched @tokens stay in the text as-is.
 *
 * Returns { task: cleaned text, targets: matched preset names[] }
 */
export function parseMentions(
  message: string,
  presetNames: string[],
): { task: string; targets: string[] } {
  if (!message.includes("@")) {
    return { task: message, targets: [] };
  }

  const targets: string[] = [];
  let task = message;

  // Check for @all first
  const allMatch = task.match(/(?:^|\s)@all(?:\s|$)/i);
  if (allMatch) {
    task = task.replace(/@all/gi, "").trim();
    return { task: task || message, targets: [...presetNames] };
  }

  // Try to match @PresetName for each preset (longest names first to avoid partial matches)
  const sortedNames = [...presetNames].sort((a, b) => b.length - a.length);
  for (const name of sortedNames) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(`@${escaped}(?=\\s|$)`, "gi");
    if (re.test(task)) {
      targets.push(name);
      task = task.replace(re, "").trim();
    }
  }

  return { task: task || message, targets };
}

const MAX_ATTACHMENT_SIZE = 20_000_000; // 20MB
const MAX_ATTACHMENTS = 10;

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
  cancelRequested: false,
  backgroundExecutions: {},
  parallelExecutions: {},
  completedParallelHistories: [],
  provider: "",
  model: "",
  catalystRef: "",
  activePreset: null,
  pendingSetupRef: null,
  pendingRetryInput: null,
  pendingAttachments: [],
  client: null,
  sseConnection: null,

  initClient: async () => {
    const { cyfrUrl } = useConnectionStore.getState();
    const client = new McpClient(cyfrUrl);
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

    // --- Parse @mentions ---
    const { usePresetStore } = await import("./preset-store");
    const presetState = usePresetStore.getState();
    const presetNames = presetState.presets.map((p) => p.name);
    const { task: parsedTask, targets } = parseMentions(message, presetNames);

    // Resolve which preset to use for this execution
    let execCatalystRef = "";
    let execModel = "";
    let execPresetName: string | null = null;

    if (targets.length >= 1) {
      // @mention target(s) — use first target for primary execution
      const targetPreset = presetState.getByName(targets[0]!);
      if (targetPreset) {
        execCatalystRef = targetPreset.catalyst_ref;
        execModel = targetPreset.model;
        execPresetName = targetPreset.name;
      }
    } else {
      // No @mention — use active preset or first preset
      const activePreset = state.activePreset
        ? presetState.getByName(state.activePreset)
        : null;
      const preset = activePreset ?? presetState.presets[0];
      if (preset) {
        execCatalystRef = preset.catalyst_ref;
        execModel = preset.model;
        execPresetName = preset.name;
      }
    }

    if (!execCatalystRef || !execModel) {
      const errorMsg: Message = {
        role: "error",
        content: "No preset configured. Go to Settings to create a preset.",
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
    const hasAttachments = state.pendingAttachments.length > 0;

    // Build attachment metadata for display (without base64 data)
    const attachmentMeta = state.pendingAttachments.map((a) => ({
      filename: a.filename,
      mediaType: a.mediaType,
    }));

    // Add user message with preset attribution
    const userMessage: Message = {
      role: "user",
      content: message,
      timestamp: new Date().toISOString(),
      preset: execPresetName ?? undefined,
      targets: targets.length > 0 ? targets : undefined,
      attachments: hasAttachments ? attachmentMeta : undefined,
    };

    const updatedMessages = [...state.messages, userMessage];

    set({
      messages: updatedMessages,
      conversationId: convId,
      running: true,
      cancelRequested: false,
      progress: providerProgressLabel(execCatalystRef),
      streamingText: "",
      streamSegments: [],
      currentTurn: 0,
      tokenUsage: { input: 0, output: 0 },
      startedAt: Date.now(),
      parallelExecutions: {},
      completedParallelHistories: [],
      activePreset: execPresetName,
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

      // Build execution input — use resolved preset's catalyst/model
      const task = parsedTask || (hasAttachments ? "Describe the attached file(s)." : parsedTask);
      const input: Record<string, unknown> = {
        catalyst_ref: execCatalystRef,
        model: execModel || undefined,
        task,
        system: systemPrompt,
        visible_tools: DEFAULT_VISIBLE_TOOLS,
        messages: history,
      };

      // Include attachments if any
      if (hasAttachments) {
        input.attachments = state.pendingAttachments.map((a) => ({
          filename: a.filename,
          media_type: a.mediaType,
          data: a.data,
        }));
      }

      const isMultiTarget = targets.length > 1;

      if (isMultiTarget) {
        // --- PARALLEL PATH: All targets execute and stream simultaneously ---
        const parallelExecs: Record<string, ParallelExecution> = {};
        const allTargets = targets.map((t) => presetState.getByName(t)).filter(Boolean) as NonNullable<ReturnType<typeof presetState.getByName>>[];

        const execPromises = allTargets.map(async (preset) => {
          const targetInput = {
            ...input,
            catalyst_ref: preset.catalyst_ref,
            model: preset.model,
          };
          try {
            const result = await client.callTool("execution", {
              action: "run_stream",
              reference: AGENT_REF,
              input: targetInput,
            });
            const executionId = result.execution_id as string;
            if (!executionId) return null;
            return { preset, executionId };
          } catch {
            return null;
          }
        });

        const results = (await Promise.all(execPromises)).filter(Boolean) as { preset: { name: string; catalyst_ref: string; model: string }; executionId: string }[];

        if (results.length === 0) {
          throw new Error("All parallel executions failed to start");
        }

        // Clear attachments after successful submission
        set({ pendingAttachments: [] });

        // Create parallel execution entries and connect SSE for each
        for (const { preset, executionId } of results) {
          const pe: ParallelExecution = {
            presetName: preset.name,
            text: "",
            segments: [],
            currentTurn: 0,
            tokenUsage: { input: 0, output: 0 },
            startedAt: Date.now(),
            sseConnection: null,
            conversationHistory: [],
          };

          const sseConnection = connectSSE("", {
            executionId,
            onEvent: (event) => get().handleParallelEvent(executionId, event),
            onError: (err) => {
              const s = get();
              if (s.parallelExecutions[executionId]) {
                const errorMsg: Message = {
                  role: "error",
                  content: `Stream error (${preset.name}): ${err.message}`,
                  timestamp: new Date().toISOString(),
                };
                const { [executionId]: _, ...rest } = s.parallelExecutions;
                set({
                  messages: [...s.messages, errorMsg],
                  parallelExecutions: rest,
                });
                // Check if all done
                if (Object.keys(rest).length === 0) {
                  set({ running: false, progress: null });
                  get().persistConversation();
                }
              }
            },
            onClose: () => {
              // Handled by handleParallelEvent on complete/error
            },
          });

          pe.sseConnection = sseConnection;
          parallelExecs[executionId] = pe;
        }

        set({
          parallelExecutions: parallelExecs,
          currentExecutionId: null, // No single primary in parallel mode
          progress: `Running ${results.length} presets...`,
        });

        // Persist early
        get().persistConversation();
      } else {
        // --- SINGLE TARGET PATH (unchanged) ---
        const result = await client.callTool("execution", {
          action: "run_stream",
          reference: AGENT_REF,
          input,
        });

        const executionId = result.execution_id as string;
        if (!executionId) {
          throw new Error("No execution_id in response");
        }

        // Clear attachments after successful submission
        set({ currentExecutionId: executionId, pendingAttachments: [] });

        // Check if cancel was requested while waiting for execution_id
        if (get().cancelRequested) {
          try {
            await client.callTool("execution", {
              action: "cancel",
              execution_id: executionId,
            });
          } catch {
            // Best-effort
          }
          set({
            running: false,
            progress: null,
            currentExecutionId: null,
            cancelRequested: false,
          });
          return;
        }

        // Persist early so the file has running: true + execution_id
        get().persistConversation();

        // Connect to SSE stream via Tauri proxy
        const sseConnection = connectSSE("", {
          executionId,
          onEvent: (event) => get().handleEvent(event),
          onError: (err) => {
            const s = get();
            if (s.running && s.currentExecutionId === executionId) {
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
            if (s.running && s.currentExecutionId === executionId) {
              s.finalizeMessage();
            }
            set({ sseConnection: null });
          },
        });

        set({ sseConnection });
      }
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
        cancelRequested: false,
      });
    }
  },

  stop: async () => {
    const state = get();

    // Running but execution_id hasn't arrived yet — flag for cancellation
    if (state.running && !state.currentExecutionId && Object.keys(state.parallelExecutions).length === 0) {
      set({ cancelRequested: true, progress: "Cancelling..." });
      return;
    }

    // Close parallel execution SSE connections and cancel
    const parallelEntries = Object.entries(state.parallelExecutions);
    if (parallelEntries.length > 0) {
      for (const [execId, pe] of parallelEntries) {
        pe.sseConnection?.close();
        if (state.client) {
          try {
            await state.client.callTool("execution", {
              action: "cancel",
              execution_id: execId,
            });
          } catch {
            // Best-effort
          }
        }
      }
      // Finalize all parallel executions as messages
      for (const [execId] of parallelEntries) {
        const pe = state.parallelExecutions[execId];
        if (pe) {
          const duration = Math.round((Date.now() - pe.startedAt) / 1000);
          const msg: Message = {
            role: "assistant",
            content: pe.text,
            timestamp: new Date().toISOString(),
            preset: pe.presetName,
            segments: pe.segments.length > 0 ? pe.segments : undefined,
            turns: pe.currentTurn || undefined,
            durationSeconds: duration || undefined,
            tokenUsage: pe.tokenUsage.input > 0 || pe.tokenUsage.output > 0 ? pe.tokenUsage : undefined,
          };
          set({ messages: [...get().messages, msg] });
        }
      }
      set({
        parallelExecutions: {},
        running: false,
        progress: null,
        startedAt: null,
        cancelRequested: false,
      });
      get().persistConversation();
      return;
    }

    // Single execution stop
    const { sseConnection, client, currentExecutionId } = state;
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
    const state = get();

    // Close all parallel SSE connections
    for (const pe of Object.values(state.parallelExecutions)) {
      pe.sseConnection?.close();
    }

    // If running, move current execution to background
    if (state.running && state.currentExecutionId && state.conversationId) {
      state.sseConnection?.close();
      state.persistConversation();
      set({
        backgroundExecutions: {
          ...state.backgroundExecutions,
          [state.currentExecutionId]: state.conversationId,
        },
        sseConnection: null,
      });
    } else {
      state.sseConnection?.close();
    }

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
      cancelRequested: false,
      sseConnection: null,
      parallelExecutions: {},
      completedParallelHistories: [],
      pendingSetupRef: null,
      pendingRetryInput: null,
      pendingAttachments: [],
    });
  },

  loadConversation: (conv: ConversationFile) => {
    const state = get();

    // Close all SSE connections (single + parallel)
    state.sseConnection?.close();
    for (const pe of Object.values(state.parallelExecutions)) {
      pe.sseConnection?.close();
    }

    // If running, persist current state before switching away
    if (state.running && state.conversationId) {
      state.persistConversation();
      if (state.currentExecutionId) {
        set({
          backgroundExecutions: {
            ...state.backgroundExecutions,
            [state.currentExecutionId]: state.conversationId,
          },
        });
      }
    }

    const messages: Message[] = conv.messages.map(deserializeMessage);

    // With presets, conversation history is always restored (cross-provider is OK)
    const conversationHistory = conv.conversation_history ?? [];

    set({
      messages,
      conversationHistory,
      conversationId: conv.id,
      running: false,
      progress: null,
      streamingText: "",
      streamSegments: [],
      currentTurn: 0,
      currentExecutionId: null,
      tokenUsage: { input: 0, output: 0 },
      startedAt: null,
      cancelRequested: false,
      provider: conv.provider || state.provider || "claude",
      model: conv.model || state.model || "",
      activePreset: conv.default_preset ?? null,
      sseConnection: null,
      parallelExecutions: {},
      completedParallelHistories: [],
      pendingAttachments: [],
      pendingSetupRef: conv.setup_component_ref ?? null,
      pendingRetryInput: conv.pending_retry_input ?? null,
    });

    // Check if this conversation has a background execution (single-target)
    const bgEntry = Object.entries(state.backgroundExecutions).find(
      ([, convId]) => convId === conv.id,
    );
    if (bgEntry) {
      const [execId] = bgEntry;
      const { [execId]: _, ...rest } = state.backgroundExecutions;
      set({
        backgroundExecutions: rest,
        currentExecutionId: execId,
        running: true,
        progress: "Resuming...",
        startedAt: Date.now(),
      });
      get().reconnectExecution(execId);
    } else if (conv.running && conv.execution_id) {
      // Single execution saved to disk
      get().reconnectExecution(conv.execution_id);
    } else if (conv.running && conv.parallel_execution_ids) {
      // Parallel executions saved to disk — reconnect each
      get().reconnectParallelExecutions(conv.parallel_execution_ids);
    }
  },

  reconnectExecution: async (executionId: string) => {
    const state = get();

    // Ensure we have a client
    let { client } = state;
    if (!client) {
      const { cyfrUrl } = useConnectionStore.getState();
      client = new McpClient(cyfrUrl);
      const savedSession = await invoke<string | null>("read_cli_session");
      if (savedSession) {
        client.sessionId = savedSession;
      } else {
        await client.initialize();
      }
      set({ client });
    }

    try {
      const logsResult = await client.callTool("execution", {
        action: "logs",
        execution_id: executionId,
      });

      const status = logsResult.status as string;

      if (status === "running") {
        set({
          running: true,
          currentExecutionId: executionId,
          startedAt: Date.now(),
          progress: "Reconnected...",
        });

        const sseConnection = connectSSE("", {
          executionId,
          lastEventId: "0", // Replay all buffered events to rebuild streaming state
          onEvent: (event) => get().handleEvent(event),
          onError: (err) => {
            const s = get();
            if (s.running && s.currentExecutionId === executionId) {
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
            if (s.running && s.currentExecutionId === executionId) {
              s.finalizeMessage();
            }
            set({ sseConnection: null });
          },
        });

        set({ sseConnection });
      } else if (status === "completed") {
        const output = logsResult.output as Record<string, unknown> | undefined;
        const content = output?.content as string | undefined;

        if (content) {
          const msg: Message = {
            role: "assistant",
            content,
            timestamp: new Date().toISOString(),
          };
          set({
            messages: [...get().messages, msg],
            running: false,
            currentExecutionId: null,
          });
        } else {
          set({ running: false, currentExecutionId: null });
        }
        get().persistConversation();
      } else if (status === "failed") {
        const error = (logsResult.error as string) ?? "Unknown error";
        const msg: Message = {
          role: "error",
          content: `Agent error: ${error}`,
          timestamp: new Date().toISOString(),
        };
        set({
          messages: [...get().messages, msg],
          running: false,
          currentExecutionId: null,
        });
        get().persistConversation();
      } else {
        set({ running: false, currentExecutionId: null });
        get().persistConversation();
      }
    } catch {
      set({ running: false, currentExecutionId: null });
      get().persistConversation();
    }
  },

  reconnectParallelExecutions: async (parallelIds: Record<string, string>) => {
    const state = get();

    // Ensure we have a client
    let { client } = state;
    if (!client) {
      const { cyfrUrl } = useConnectionStore.getState();
      client = new McpClient(cyfrUrl);
      const savedSession = await invoke<string | null>("read_cli_session");
      if (savedSession) {
        client.sessionId = savedSession;
      } else {
        await client.initialize();
      }
      set({ client });
    }

    // First pass: query status of each execution and collect results
    const runningExecs: Array<{ execId: string; presetName: string }> = [];
    const completedMessages: Message[] = [];

    for (const [execId, presetName] of Object.entries(parallelIds)) {
      try {
        const logsResult = await client.callTool("execution", {
          action: "logs",
          execution_id: execId,
        });
        const status = logsResult.status as string;

        if (status === "running") {
          runningExecs.push({ execId, presetName });
        } else if (status === "completed") {
          const output = logsResult.output as Record<string, unknown> | undefined;
          const content = (output?.content as string) ?? "";
          if (content) {
            completedMessages.push({
              role: "assistant",
              content,
              timestamp: new Date().toISOString(),
              preset: presetName,
            });
          }
        }
        // failed/other: skip
      } catch {
        // Skip unqueryable executions
      }
    }

    // Add completed messages first
    if (completedMessages.length > 0) {
      set({ messages: [...get().messages, ...completedMessages] });
    }

    if (runningExecs.length === 0) {
      // All done
      set({ running: false });
      get().persistConversation();
      return;
    }

    // Second pass: set up ALL parallel execution entries in the store BEFORE
    // connecting SSE, so replayed events find their entries immediately.
    const parallelExecs: Record<string, ParallelExecution> = {};
    for (const { execId, presetName } of runningExecs) {
      parallelExecs[execId] = {
        presetName,
        text: "",
        segments: [],
        currentTurn: 0,
        tokenUsage: { input: 0, output: 0 },
        startedAt: Date.now(),
        sseConnection: null,
        conversationHistory: [],
      };
    }

    set({
      parallelExecutions: parallelExecs,
      running: true,
      progress: `Resuming ${runningExecs.length} presets...`,
      startedAt: Date.now(),
    });

    // Third pass: NOW connect SSE for each — replayed events will find entries
    for (const { execId, presetName } of runningExecs) {
      const sseConnection = connectSSE("", {
        executionId: execId,
        lastEventId: "0", // Replay all buffered events to rebuild streaming state
        onEvent: (event) => get().handleParallelEvent(execId, event),
        onError: (err) => {
          const s = get();
          if (s.parallelExecutions[execId]) {
            const errorMsg: Message = {
              role: "error",
              content: `Stream error (${presetName}): ${err.message}`,
              timestamp: new Date().toISOString(),
            };
            const { [execId]: _, ...rest } = s.parallelExecutions;
            set({
              messages: [...s.messages, errorMsg],
              parallelExecutions: rest,
            });
            if (Object.keys(rest).length === 0) {
              set({ running: false, progress: null });
              get().persistConversation();
            }
          }
        },
        onClose: () => {},
      });

      // Update with SSE connection reference
      const current = get().parallelExecutions[execId];
      if (current) {
        set({
          parallelExecutions: {
            ...get().parallelExecutions,
            [execId]: { ...current, sseConnection },
          },
        });
      }
    }
  },

  completeSetup: () => {
    const state = get();
    const retryInput = state.pendingRetryInput;

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

    if (retryInput) {
      setTimeout(() => get().submit("Setup saved. Please continue with my previous request."), 500);
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
    const state = get();
    const providerChanged = provider !== state.provider;
    const modelChanged = model !== state.model;

    if (providerChanged || modelChanged) {
      set({
        provider,
        model,
        catalystRef,
        messages: [],
        conversationHistory: [],
        conversationId: null,
        tokenUsage: { input: 0, output: 0 },
        streamingText: "",
        streamSegments: [],
        pendingSetupRef: null,
        pendingRetryInput: null,
        pendingAttachments: [],
      });
    } else {
      set({ provider, model, catalystRef });
    }

    invoke("save_prefs", { provider, model, catalystRef }).catch(() => {});
  },

  setActivePreset: (presetName: string) => {
    import("./preset-store").then(({ usePresetStore }) => {
      const preset = usePresetStore.getState().getByName(presetName);
      if (preset) {
        set({
          activePreset: preset.name,
          provider: preset.provider,
          model: preset.model,
          catalystRef: preset.catalyst_ref,
        });
      }
    });
  },

  addAttachments: async (files: File[]) => {
    const state = get();
    const remaining = MAX_ATTACHMENTS - state.pendingAttachments.length;
    const toAdd = files.slice(0, remaining);

    const newAttachments: Attachment[] = [];
    for (const file of toAdd) {
      if (file.size > MAX_ATTACHMENT_SIZE) continue;
      try {
        const buffer = await file.arrayBuffer();
        const bytes = new Uint8Array(buffer);
        let binary = "";
        for (let i = 0; i < bytes.length; i++) {
          binary += String.fromCharCode(bytes[i]!);
        }
        const data = btoa(binary);
        newAttachments.push({
          filename: file.name,
          mediaType: file.type || "application/octet-stream",
          data,
        });
      } catch {
        // Skip unreadable files
      }
    }

    if (newAttachments.length > 0) {
      set({
        pendingAttachments: [...state.pendingAttachments, ...newAttachments],
      });
    }
  },

  removeAttachment: (index: number) => {
    const state = get();
    set({
      pendingAttachments: state.pendingAttachments.filter((_, i) => i !== index),
    });
  },

  clearAttachments: () => {
    set({ pendingAttachments: [] });
  },

  // --- Single-target event handler ---
  handleEvent: (event: ExecutionEvent) => {
    const state = get();

    // Check if this event belongs to a background execution
    const eventExecId =
      (event.data as Record<string, unknown>)?.execution_id as string | undefined;
    if (eventExecId && state.backgroundExecutions[eventExecId]) {
      if (event.type === "complete" || event.type === "error") {
        const convId = state.backgroundExecutions[eventExecId]!;
        const { [eventExecId]: _, ...rest } = state.backgroundExecutions;
        set({ backgroundExecutions: rest });
        finalizeBackgroundConversation(convId, eventExecId);
      }
      return;
    }

    if (event.type === "complete") {
      state.finalizeMessage();
      return;
    }

    if (event.type === "error") {
      const data = event.data as Record<string, unknown>;
      const errorMsg: Message = {
        role: "error",
        content: `Execution error: ${friendlyError(data.error ?? data.message ?? "Unknown error")}`,
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
        } else {
          segments.push({ turn: state.currentTurn || 1, tools: [], text: content });
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
        } else {
          segments.push({ turn: state.currentTurn || 1, tools: [entry], text: "" });
        }

        let progress = `Using ${tool}...`;
        if (tool === "files") progress = "Working with files...";

        set({ streamSegments: segments, progress });
        break;
      }

      case "tool_result": {
        const tool = data.tool as string;
        const preview = (data.preview as string) ?? null;
        const segments = [...state.streamSegments];

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

  // --- Parallel execution event handler ---
  handleParallelEvent: (executionId: string, event: ExecutionEvent) => {
    const state = get();
    const pe = state.parallelExecutions[executionId];
    if (!pe) return;

    if (event.type === "complete") {
      get().finalizeParallelExecution(executionId);
      return;
    }

    if (event.type === "error") {
      const data = event.data as Record<string, unknown>;
      const errorMsg: Message = {
        role: "error",
        content: `Error (${pe.presetName}): ${friendlyError(data.error ?? data.message ?? "Unknown error")}`,
        timestamp: new Date().toISOString(),
      };
      pe.sseConnection?.close();
      const { [executionId]: _, ...rest } = state.parallelExecutions;
      set({
        messages: [...state.messages, errorMsg],
        parallelExecutions: rest,
      });
      // Check if all done
      if (Object.keys(rest).length === 0) {
        set({ running: false, progress: null, startedAt: null });
        get().persistConversation();
      }
      return;
    }

    if (event.type !== "emit") return;

    const data = event.data as Record<string, unknown>;
    const kind = data.kind as string;

    // Check for sub-agent events within parallel execution
    const emitTag = data.emit_tag as string | undefined;
    if (emitTag) {
      handleParallelSubAgentEvent(set, get, executionId, emitTag, data);
      return;
    }

    // Clone the parallel execution for immutable update
    const updated = { ...pe };

    switch (kind) {
      case "turn_start": {
        const turn = (data.turn as number) ?? updated.currentTurn + 1;
        updated.segments = [...updated.segments, { turn, tools: [], text: "" }];
        updated.currentTurn = turn;
        break;
      }

      case "text_delta": {
        const content = (data.content as string) ?? "";
        const segments = [...updated.segments];
        const current = segments[segments.length - 1];
        if (current) {
          segments[segments.length - 1] = { ...current, text: current.text + content };
        } else {
          segments.push({ turn: updated.currentTurn || 1, tools: [], text: content });
        }
        updated.text += content;
        updated.segments = segments;
        break;
      }

      case "tool_use": {
        const tool = data.tool as string;
        const toolCallId = data.tool_call_id as string | undefined;
        const entry: ToolEntry = {
          tool,
          status: "running",
          turn: updated.currentTurn,
          preview: null,
          input: data.input ?? null,
          emitTag: SUB_AGENT_TOOLS.has(tool) && toolCallId ? `${tool}:${toolCallId}` : null,
          subEvents: [],
        };
        const segments = [...updated.segments];
        const current = segments[segments.length - 1];
        if (current) {
          segments[segments.length - 1] = { ...current, tools: [...current.tools, entry] };
        } else {
          segments.push({ turn: updated.currentTurn || 1, tools: [entry], text: "" });
        }
        updated.segments = segments;
        break;
      }

      case "tool_result": {
        const tool = data.tool as string;
        const preview = (data.preview as string) ?? null;
        const segments = [...updated.segments];
        for (let si = segments.length - 1; si >= 0; si--) {
          const seg = segments[si]!;
          for (let ti = seg.tools.length - 1; ti >= 0; ti--) {
            const t = seg.tools[ti]!;
            if (t.tool === tool && t.status === "running") {
              const updatedTools = [...seg.tools];
              updatedTools[ti] = { ...t, status: "done", preview };
              segments[si] = { ...seg, tools: updatedTools };
              updated.segments = segments;
              break;
            }
          }
        }
        break;
      }

      case "usage": {
        const inp = (data.input_tokens as number) ?? 0;
        const out = (data.output_tokens as number) ?? 0;
        updated.tokenUsage = {
          input: updated.tokenUsage.input + inp,
          output: updated.tokenUsage.output + out,
        };
        break;
      }

      case "conversation_complete": {
        const messages = data.messages as unknown[];
        if (Array.isArray(messages)) {
          updated.conversationHistory = messages;
        }
        break;
      }
    }

    set({
      parallelExecutions: { ...state.parallelExecutions, [executionId]: updated },
    });
  },

  // --- Single-target finalize ---
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
      preset: state.activePreset ?? undefined,
      segments:
        state.streamSegments.length > 0 ? state.streamSegments : undefined,
      turns: state.currentTurn || undefined,
      durationSeconds: duration || undefined,
      tokenUsage:
        state.tokenUsage.input > 0 || state.tokenUsage.output > 0
          ? state.tokenUsage
          : undefined,
    };

    const updatedMessages = [...state.messages, assistantMessage];

    set({
      messages: updatedMessages,
      running: false,
      progress: null,
      streamingText: "",
      streamSegments: [],
      currentTurn: 0,
      currentExecutionId: null,
      startedAt: null,
      cancelRequested: false,
    });

    // Persist and update conversation index
    get().persistConversation();
  },

  // --- Parallel execution finalize ---
  finalizeParallelExecution: (executionId: string) => {
    const HISTORY_WINDOW = 20;
    const state = get();
    const pe = state.parallelExecutions[executionId];
    if (!pe) return;

    pe.sseConnection?.close();

    const duration = Math.round((Date.now() - pe.startedAt) / 1000);

    const assistantMessage: Message = {
      role: "assistant",
      content: pe.text,
      timestamp: new Date().toISOString(),
      preset: pe.presetName,
      segments: pe.segments.length > 0 ? pe.segments : undefined,
      turns: pe.currentTurn || undefined,
      durationSeconds: duration || undefined,
      tokenUsage:
        pe.tokenUsage.input > 0 || pe.tokenUsage.output > 0
          ? pe.tokenUsage
          : undefined,
    };

    // Accumulate this execution's conversation history
    const completedHistories = [
      ...state.completedParallelHistories,
      { preset: pe.presetName, messages: pe.conversationHistory },
    ];

    const { [executionId]: _, ...remainingExecs } = state.parallelExecutions;
    const updatedMessages = [...state.messages, assistantMessage];

    if (Object.keys(remainingExecs).length === 0) {
      // All parallel executions done
      const lastUserIdx = updatedMessages.map((m) => m.role).lastIndexOf("user");

      const responsesAfter =
        lastUserIdx >= 0
          ? updatedMessages.slice(lastUserIdx + 1).filter((m) => m.role === "assistant" && m.preset)
          : [];

      let mergedHistory: unknown[];

      if (completedHistories.length > 1 && responsesAfter.length > 1) {
        // Get base history before this @all turn (strip trailing assistant + tool_results)
        const baseHistory = [...state.conversationHistory];
        while (baseHistory.length > 0) {
          const last = baseHistory[baseHistory.length - 1] as Record<string, unknown> | undefined;
          if (last && (last.role === "assistant" || last.role === "tool_results")) {
            baseHistory.pop();
          } else {
            break;
          }
        }

        // Collect intermediate messages from ALL providers
        // Skip shared user message (first) and final assistant (last) from each
        const allProviderMessages: unknown[] = [];
        for (const { messages: convMsgs } of completedHistories) {
          if (convMsgs.length <= 1) continue;
          // Drop first (user msg) and trailing assistant(s)
          const inner = convMsgs.slice(1);
          let end = inner.length;
          while (end > 0) {
            const msg = inner[end - 1] as Record<string, unknown> | undefined;
            if (msg && msg.role === "assistant") {
              end--;
            } else {
              break;
            }
          }
          allProviderMessages.push(...inner.slice(0, end));
        }

        // Merged final assistant with preset labels
        const mergedText = responsesAfter
          .map((m) => `[${m.preset}]:\n${m.content}`)
          .join("\n\n");

        const fullHistory = [...baseHistory, ...allProviderMessages, { role: "assistant", content: mergedText }];

        // Apply rolling window
        mergedHistory = fullHistory.slice(-HISTORY_WINDOW);
      } else {
        // Single preset or no multi-target — use last execution's history
        mergedHistory = pe.conversationHistory.length > 0 ? pe.conversationHistory : state.conversationHistory;
      }

      set({
        messages: updatedMessages,
        parallelExecutions: {},
        completedParallelHistories: [],
        running: false,
        progress: null,
        startedAt: null,
        cancelRequested: false,
        conversationHistory: mergedHistory,
      });

      get().persistConversation();
    } else {
      // Still waiting for other parallel executions
      const remaining = Object.values(remainingExecs).map((e) => e.presetName);
      set({
        messages: updatedMessages,
        parallelExecutions: remainingExecs,
        completedParallelHistories: completedHistories,
        progress: `Waiting: ${remaining.join(", ")}...`,
      });
    }
  },

  persistConversation: async () => {
    const state = get();
    const { conversationId, messages, conversationHistory } = state;
    if (!conversationId) return;

    const firstUserMsg = messages.find((m) => m.role === "user");
    const title = firstUserMsg
      ? firstUserMsg.content.slice(0, 80)
      : "Untitled";

    // Build parallel execution IDs for persistence
    const parallelExecIds: Record<string, string> | undefined =
      Object.keys(state.parallelExecutions).length > 0
        ? Object.fromEntries(
            Object.entries(state.parallelExecutions).map(([eid, pe]) => [eid, pe.presetName]),
          )
        : undefined;

    const convFile: ConversationFile = {
      id: conversationId,
      title,
      created_at:
        messages[0]?.timestamp ?? new Date().toISOString(),
      updated_at: new Date().toISOString(),
      provider: state.provider,
      model: state.model,
      default_preset: state.activePreset ?? undefined,
      messages: messages.map(serializeMessage),
      conversation_history: conversationHistory,
      execution_id: state.currentExecutionId,
      running: state.running,
      setup_component_ref: state.pendingSetupRef ?? undefined,
      pending_retry_input: state.pendingRetryInput ?? undefined,
      parallel_execution_ids: parallelExecIds,
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

      // Update the lightweight index instead of re-reading all files
      const { useConversationStore } = await import("./conversation-store");
      await useConversationStore.getState().upsertIndex({
        id: conversationId,
        title,
        updated_at: convFile.updated_at,
        status: state.running ? "running" : "idle",
      });
    } catch {
      // Silent — don't break UX for persistence failures
    }
  },
}));

// ---------------------------------------------------------------------------
// Background conversation finalizer
// ---------------------------------------------------------------------------

async function finalizeBackgroundConversation(
  conversationId: string,
  executionId: string,
) {
  try {
    const result = await invoke<{ stdout: string; success: boolean }>(
      "cyfr_command",
      {
        args: [
          "run",
          "catalyst:local.files",
          "--input",
          JSON.stringify({
            action: "read_text",
            path: `data/agent_conversations/${conversationId}.json`,
          }),
        ],
      },
    );

    if (!result.success) return;
    const parsed = JSON.parse(result.stdout) as Record<string, unknown>;
    const fileContent = (parsed.result ?? parsed) as Record<string, unknown>;
    const content = fileContent.content as string;
    const convData = JSON.parse(content) as Record<string, unknown>;

    let resultContent: string | null = null;
    try {
      const { cyfrUrl } = useConnectionStore.getState();
      const client = new McpClient(cyfrUrl);
      const savedSession = await invoke<string | null>("read_cli_session");
      if (savedSession) {
        client.sessionId = savedSession;
      }

      const logsResult = await client.callTool("execution", {
        action: "logs",
        execution_id: executionId,
      });

      const status = logsResult.status as string;
      if (status === "completed") {
        const output = logsResult.output as Record<string, unknown> | undefined;
        resultContent = (output?.content as string) ?? null;
      } else if (status === "failed") {
        resultContent = `Agent error: ${(logsResult.error as string) ?? "Unknown error"}`;
      }
    } catch {
      // Can't get result — just mark as not running
    }

    const messages = (convData.messages ?? []) as Record<string, unknown>[];
    if (resultContent) {
      messages.push({
        role: "assistant",
        content: resultContent,
        timestamp: new Date().toISOString(),
      });
    }

    const updated = {
      ...convData,
      messages,
      execution_id: null,
      running: false,
      updated_at: new Date().toISOString(),
    };

    await invoke("cyfr_command", {
      args: [
        "run",
        "catalyst:local.files",
        "--input",
        JSON.stringify({
          action: "write_text",
          path: `data/agent_conversations/${conversationId}.json`,
          content: JSON.stringify(updated),
        }),
      ],
    });

    import("./conversation-store").then(({ useConversationStore }) => {
      useConversationStore.getState().upsertIndex({
        id: conversationId,
        title: (updated.title as string) || "Untitled",
        updated_at: updated.updated_at as string,
        status: "idle",
      });
    });
  } catch {
    // Silent
  }
}

// ---------------------------------------------------------------------------
// Sub-agent event handler (single-target)
// ---------------------------------------------------------------------------

function handleSubAgentEvent(
  set: (partial: Partial<AgentState>) => void,
  get: () => AgentState,
  emitTag: string,
  data: Record<string, unknown>,
) {
  const state = get();
  const kind = data.kind as string;
  const segments = [...state.streamSegments];

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

// ---------------------------------------------------------------------------
// Sub-agent event handler (parallel execution)
// ---------------------------------------------------------------------------

function handleParallelSubAgentEvent(
  set: (partial: Partial<AgentState>) => void,
  get: () => AgentState,
  executionId: string,
  emitTag: string,
  data: Record<string, unknown>,
) {
  const state = get();
  const pe = state.parallelExecutions[executionId];
  if (!pe) return;

  const kind = data.kind as string;
  const segments = [...pe.segments];

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
          for (let i = tool.subEvents.length - 1; i >= 0; i--) {
            const se = tool.subEvents[i]!;
            if (se.kind === "tool_use" && se.tool === data.tool && se.status === "running") {
              const updatedSubs = [...tool.subEvents];
              updatedSubs[i] = { ...se, status: "done" };
              const updatedTool = { ...tool, subEvents: updatedSubs };
              const updatedTools = [...seg.tools];
              updatedTools[ti] = updatedTool;
              segments[si] = { ...seg, tools: updatedTools };
              set({
                parallelExecutions: {
                  ...state.parallelExecutions,
                  [executionId]: { ...pe, segments },
                },
              });
              return;
            }
          }
          break;
        case "text_delta": {
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
            set({
              parallelExecutions: {
                ...state.parallelExecutions,
                [executionId]: { ...pe, segments },
              },
            });
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
      set({
        parallelExecutions: {
          ...state.parallelExecutions,
          [executionId]: { ...pe, segments },
        },
      });
      return;
    }
  }
}

// ---------------------------------------------------------------------------
// Serialization helpers
// ---------------------------------------------------------------------------

function serializeMessage(msg: Message): SerializedMessage {
  return {
    role: msg.role,
    content: msg.content,
    timestamp: msg.timestamp,
    preset: msg.preset,
    targets: msg.targets,
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
    preset: msg.preset,
    targets: msg.targets,
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

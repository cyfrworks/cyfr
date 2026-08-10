import { create } from "zustand";
import type { McpClient } from "../api/mcp-client";
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
import * as cyfrMcp from "../api/cyfr-mcp";
import { buildSystemPrelude, buildPortaContextBlock } from "../harness/system-prelude";
import { parsePortaActions } from "../harness/porta-actions-parser";
import { dispatchIntents } from "../harness/intent-dispatcher";
import { getPortaContext } from "./porta-context-store";
import { useActivityStore } from "./activity-store";

const AGENT_REF = "formula:local.aqua";

interface SubAgentDef {
  name: string;
  title: string;
  description: string;
  prompt: string;
  visible_tools: string[] | null;
  tool_policy?: Record<string, unknown>;
  catalyst_ref: string | null;
  model: string | null;
}

/**
 * Attach the formula's tool-surface fields from a `tool_policy` allowlist
 * (`{"tool.action" | "tool.*" => "ask" | "auto"}`), mirroring Prism's
 * `Prism.AgentConfig.put_formula_tool_surface/2`:
 *
 * - Native-tool-only agents (allowlist names a native tool such as
 *   `native_search`) get `visible_tools: ["native_search"]` and no
 *   `tool_policy` — model-side native tools can't coexist with custom MCP
 *   tools.
 * - Everyone else gets `tool_policy` (empty object when the guide carries
 *   none — the formula treats an absent policy as everything-callable, so
 *   the empty allowlist is the fail-closed default, never omission).
 */
function applyToolSurface<T extends object>(
  target: T,
  toolPolicy: Record<string, unknown> | null | undefined,
): T {
  const t = target as Record<string, unknown>;
  const policy = toolPolicy && typeof toolPolicy === "object" ? toolPolicy : {};
  if (Object.keys(policy).some((k) => k === "native_search")) {
    delete t.tool_policy;
    t.visible_tools = ["native_search"];
  } else {
    t.tool_policy = policy;
    t.visible_tools = null;
  }
  return target;
}

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
  orchestrator?: string;
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

export interface PendingSetup {
  componentRef: string;
  retryInput: string | null;
  queuedAt: number;
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

  // Active orchestrator for current conversation
  activeOrchestrator: string | null;

  // Setup state
  pendingSetupRef: string | null;
  pendingRetryInput: string | null;
  /** FIFO of setups queued behind the currently active one. */
  setupQueue: PendingSetup[];
  /** Setups the user dismissed but may resume. */
  dismissedSetups: PendingSetup[];

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
  setActiveOrchestrator: (name: string) => void;
  completeSetup: () => void;
  dismissSetup: () => void;
  resumeDismissedSetup: (componentRef: string) => void;
  addAttachments: (files: File[]) => Promise<void>;
  removeAttachment: (index: number) => void;
  clearAttachments: () => void;

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
 * Parse a single @mention from a message targeting an orchestrator.
 * Returns { task: cleaned text, mentionName: matched name or null }
 */
export function parseOrchestratorMention(
  message: string,
  orchestratorNames: string[],
): { task: string; mentionName: string | null } {
  if (!message.includes("@") || orchestratorNames.length === 0) {
    return { task: message, mentionName: null };
  }

  const sorted = [...orchestratorNames].sort((a, b) => b.length - a.length);
  for (const name of sorted) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(`@${escaped}(?=\\s|$)`, "i");
    if (re.test(message)) {
      const cleaned = message.replace(re, "").trim();
      return { task: cleaned || message, mentionName: name };
    }
  }

  return { task: message, mentionName: null };
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
  activeOrchestrator: null,
  pendingSetupRef: null,
  pendingRetryInput: null,
  setupQueue: [],
  dismissedSetups: [],
  pendingAttachments: [],
  client: null,
  sseConnection: null,

  initClient: async () => {
    const client = await useConnectionStore.getState().getMcpClient();
    if (!client.sessionId && useConnectionStore.getState().mode !== "remote") {
      await client.discover();
    }
    set({ client });

    // Load orchestrators
    try {
      const { useOrchestratorStore } = await import("./orchestrator-store");
      await useOrchestratorStore.getState().loadOrchestrators(client);
    } catch {
      // Non-fatal
    }
  },

  submit: async (message: string) => {
    const state = get();

    // --- Resolve orchestrator ---
    const { useOrchestratorStore } = await import("./orchestrator-store");
    const orchState = useOrchestratorStore.getState();
    const orchestratorNames = orchState.orchestrators.map((o) => o.name);
    const { task: parsedTask, mentionName } = parseOrchestratorMention(message, orchestratorNames);

    const orchestrator = mentionName
      ? orchState.orchestrators.find((o) => o.name === mentionName)
      : orchState.orchestrators.find((o) => o.name === orchState.activeOrchestrator) ?? orchState.orchestrators[0];

    if (!orchestrator) {
      const errorMsg: Message = {
        role: "error",
        content: "No orchestrators configured.",
        timestamp: new Date().toISOString(),
      };
      set({ messages: [...state.messages, errorMsg] });
      return;
    }

    const execCatalystRef = orchestrator.catalyst_ref;
    const execModel = orchestrator.model;
    const orchestratorName = orchestrator.name;

    if (!execCatalystRef || !execModel) {
      const errorMsg: Message = {
        role: "error",
        content: `Orchestrator "${orchestratorName}" has no model configured. Open the Agents panel to set one.`,
        timestamp: new Date().toISOString(),
      };
      set({ messages: [...state.messages, errorMsg] });
      return;
    }

    // Use the shared MCP client from connection-store
    const client = await useConnectionStore.getState().getMcpClient();
    if (!client.sessionId && useConnectionStore.getState().mode !== "remote") {
      await client.discover();
    }
    set({ client });

    const convId = state.conversationId ?? generateConversationId();
    const hasAttachments = state.pendingAttachments.length > 0;

    const attachmentMeta = state.pendingAttachments.map((a) => ({
      filename: a.filename,
      mediaType: a.mediaType,
    }));

    const userMessage: Message = {
      role: "user",
      content: message,
      timestamp: new Date().toISOString(),
      orchestrator: orchestratorName,
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
      activeOrchestrator: orchestratorName,
    });

    try {
      // Build system prompt + tool_policy from orchestrator config. The
      // policy defaults to the empty allowlist so a failed guide fetch runs
      // the agent with no callable tools rather than with everything —
      // absent tool_policy makes the formula treat every tool as directly
      // callable.
      let systemPrompt =
        "You are an agent running inside CYFR, a governed computation platform.";
      let orchestratorToolPolicy: Record<string, unknown> = {};
      try {
        const guideResult = await client.callTool("aqua", {
          action: "get",
          name: orchestratorName,
        });
        if (guideResult.content && typeof guideResult.content === "string") {
          systemPrompt = guideResult.content;
        }
        if (
          guideResult.tool_policy &&
          typeof guideResult.tool_policy === "object" &&
          !Array.isArray(guideResult.tool_policy)
        ) {
          orchestratorToolPolicy = guideResult.tool_policy as Record<string, unknown>;
        }
      } catch {
        // Use fallback
      }

      // Add runtime context
      const now = new Date();
      systemPrompt += `\n\n---\n\n## Runtime Context\n\n`;
      systemPrompt += `Current date: ${now.toISOString().split("T")[0]}`;
      systemPrompt += `\nCurrent time: ${now.toLocaleTimeString()}`;

      // List installed components
      try {
        const listResult = await client.callTool("component", {
          action: "list",
          limit: 1000,
        });
        const components =
          (listResult as Record<string, unknown>)?.components as
            | Record<string, unknown>[]
            | undefined;
        if (components && components.length > 0) {
          const grouped: Record<string, Record<string, unknown>[]> = {
            catalyst: [],
            formula: [],
            reagent: [],
          };
          for (const c of components) {
            const type = (c.component_type as string) || "unknown";
            if (grouped[type]) grouped[type]!.push(c);
          }
          const counts = `Installed components: ${grouped.catalyst!.length} catalysts, ${grouped.formula!.length} formulas, ${grouped.reagent!.length} reagents`;
          systemPrompt += `\n${counts}`;
          for (const [type, comps] of Object.entries(grouped)) {
            if (comps.length > 0) {
              systemPrompt += `\nInstalled ${type}s:`;
              for (const c of comps) {
                const ref =
                  (c.component_ref as string) ||
                  `${c.component_type}:${(c.publisher as string) || "local"}.${c.name}:${c.version}`;
                const desc = c.description ? ` — ${c.description}` : "";
                systemPrompt += `\n- ${ref}${desc}`;
              }
            }
          }
        }
      } catch {
        /* non-critical */
      }

      // List external MCP servers
      try {
        const serversResult = await client.callTool("mcp_servers", {
          action: "list",
        });
        const servers =
          (serversResult as Record<string, unknown>)?.servers as
            | Record<string, unknown>[]
            | undefined;
        if (servers && servers.length > 0) {
          systemPrompt += `\nConnected MCP servers:`;
          for (const s of servers) {
            const tools = (s.tools as unknown[])?.length
              ? `, ${(s.tools as unknown[]).length} tools`
              : "";
            systemPrompt += `\n- ${s.name} (${s.enabled ? "enabled" : "disabled"}${tools})`;
          }
        }
      } catch {
        /* non-critical */
      }

      // Porta shell-control text-intent protocol. The stable prelude is
      // cache-friendly (rarely changes); the PortaContext tail is small and
      // changes per turn, so it rides after the prelude to preserve cache
      // hits on the prefix.
      systemPrompt += buildSystemPrelude();
      systemPrompt += buildPortaContextBlock(getPortaContext());

      // Compact conversation history
      const history = compact(state.conversationHistory);

      // Build sub-agent definitions filtered by orchestrator
      const subAgents = await fetchSubAgents(client, orchestratorName, execCatalystRef, execModel);

      // Build execution input
      const task = parsedTask || (hasAttachments ? "Describe the attached file(s)." : parsedTask);
      const input: Record<string, unknown> = applyToolSurface(
        {
          catalyst_ref: execCatalystRef,
          model: execModel || undefined,
          task,
          system: systemPrompt,
          messages: history,
          sub_agents: subAgents,
        },
        orchestratorToolPolicy,
      );

      if (hasAttachments) {
        input.attachments = state.pendingAttachments.map((a) => ({
          filename: a.filename,
          media_type: a.mediaType,
          data: a.data,
        }));
      }

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

      // Check if cancel was requested while waiting
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

      // Persist early
      get().persistConversation();

      // Connect to SSE stream via Tauri proxy
      const sseConnection = connectSSE(client, {
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

    // Running but execution_id hasn't arrived yet
    if (state.running && !state.currentExecutionId) {
      set({ cancelRequested: true, progress: "Cancelling..." });
      return;
    }

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
      pendingSetupRef: null,
      pendingRetryInput: null,
      setupQueue: [],
      dismissedSetups: [],
      pendingAttachments: [],
    });
  },

  loadConversation: (conv: ConversationFile) => {
    const state = get();
    state.sseConnection?.close();

    // If running, persist current state before switching
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
      activeOrchestrator: conv.default_orchestrator ?? null,
      sseConnection: null,
      pendingAttachments: [],
      pendingSetupRef: conv.setup_component_ref ?? null,
      pendingRetryInput: conv.pending_retry_input ?? null,
      setupQueue: [],
      dismissedSetups: [],
    });

    // Check for background execution
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
      get().reconnectExecution(conv.execution_id);
    }
  },

  reconnectExecution: async (executionId: string) => {
    const state = get();

    let { client } = state;
    if (!client) {
      client = await useConnectionStore.getState().getMcpClient();
      if (!client.sessionId && useConnectionStore.getState().mode !== "remote") {
        await client.discover();
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

        const sseConnection = connectSSE(client, {
          executionId,
          lastEventId: "0",
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

  setActiveOrchestrator: (name: string) => {
    import("./orchestrator-store").then(({ useOrchestratorStore }) => {
      useOrchestratorStore.getState().selectOrchestrator(name);
    });
    set({ activeOrchestrator: name });
  },

  completeSetup: () => {
    const state = get();
    const completedRef = state.pendingSetupRef;
    const retryInput = state.pendingRetryInput;

    const confirmMsg: Message = {
      role: "assistant",
      content: `Setup complete for ${completedRef}. ${retryInput ? "Resuming your task..." : ""}`,
      timestamp: new Date().toISOString(),
    };

    // Promote the next queued setup, if any.
    const [next, ...rest] = state.setupQueue;
    set({
      messages: [...state.messages, confirmMsg],
      pendingSetupRef: next?.componentRef ?? null,
      pendingRetryInput: next?.retryInput ?? null,
      setupQueue: rest,
      progress: next ? "Setup required" : null,
    });

    // If the completed setup originally interrupted a task and no other setup
    // is pending, resume it. When another setup is pending we defer — the
    // user will finish or dismiss it first.
    if (retryInput && !next) {
      setTimeout(
        () => get().submit("Setup saved. Please continue with my previous request."),
        500,
      );
    }
  },

  dismissSetup: () => {
    const state = get();
    const currentRef = state.pendingSetupRef;
    const currentRetry = state.pendingRetryInput;

    // Park the current setup as "waiting" so the user can resume it later.
    const nextDismissed: PendingSetup[] = currentRef
      ? [
          ...state.dismissedSetups,
          { componentRef: currentRef, retryInput: currentRetry, queuedAt: Date.now() },
        ]
      : state.dismissedSetups;

    const [next, ...rest] = state.setupQueue;
    set({
      dismissedSetups: nextDismissed,
      pendingSetupRef: next?.componentRef ?? null,
      pendingRetryInput: next?.retryInput ?? null,
      setupQueue: rest,
      progress: next ? "Setup required" : null,
    });
  },

  resumeDismissedSetup: (componentRef) => {
    const state = get();
    const target = state.dismissedSetups.find((s) => s.componentRef === componentRef);
    if (!target) return;
    const remaining = state.dismissedSetups.filter((s) => s.componentRef !== componentRef);

    if (state.pendingSetupRef === null) {
      set({
        dismissedSetups: remaining,
        pendingSetupRef: target.componentRef,
        pendingRetryInput: target.retryInput,
        progress: "Setup required",
      });
    } else {
      // There's an active setup — put the resumed item at the front of the
      // queue so the user sees it next.
      set({
        dismissedSetups: remaining,
        setupQueue: [target, ...state.setupQueue],
      });
    }
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
        const entry: ToolEntry = {
          tool,
          status: "running",
          turn: state.currentTurn,
          preview: null,
          input: data.input ?? null,
          emitTag: null,
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
          const retryInput = lastUserMsg?.content ?? null;

          if (state.pendingSetupRef === null) {
            // No active setup — show immediately.
            set({
              pendingSetupRef: componentRef,
              pendingRetryInput: retryInput,
              progress: "Setup required",
            });
          } else if (
            // Don't double-queue the same ref if it's already pending.
            state.pendingSetupRef !== componentRef &&
            !state.setupQueue.some((s) => s.componentRef === componentRef)
          ) {
            set({
              setupQueue: [
                ...state.setupQueue,
                { componentRef, retryInput, queuedAt: Date.now() },
              ],
            });
          }
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

    // Parse any porta-actions block out of the completed message. Blocks are
    // stripped from the displayed content; intents are dispatched fire-and-
    // forget after the state transition so the UI updates promptly.
    const parseResult = parsePortaActions(state.streamingText);

    const assistantMessage: Message = {
      role: "assistant",
      content: parseResult.strippedContent,
      timestamp: new Date().toISOString(),
      orchestrator: state.activeOrchestrator ?? undefined,
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

    get().persistConversation();

    if (parseResult.intents.length > 0) {
      void (async () => {
        const records = await dispatchIntents(parseResult.intents);
        const log = useActivityStore.getState().log;
        for (const r of records) {
          if (r.status === "dispatched") {
            log({ kind: "dispatched", intent: r.intent });
          } else {
            log({
              kind: "dispatch_error",
              intent: r.intent,
              error: r.error ?? "unknown",
            });
          }
        }
      })();
    }
    if (parseResult.drops.length > 0) {
      const log = useActivityStore.getState().log;
      for (const d of parseResult.drops) {
        log({ kind: "drop", raw: d.raw, reason: d.reason });
      }
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

    const convFile: ConversationFile = {
      id: conversationId,
      title,
      created_at:
        messages[0]?.timestamp ?? new Date().toISOString(),
      updated_at: new Date().toISOString(),
      default_orchestrator: state.activeOrchestrator ?? undefined,
      messages: messages.map(serializeMessage),
      conversation_history: conversationHistory,
      execution_id: state.currentExecutionId,
      running: state.running,
      setup_component_ref: state.pendingSetupRef ?? undefined,
      pending_retry_input: state.pendingRetryInput ?? undefined,
    };

    try {
      const json = JSON.stringify(convFile);
      const client = await useConnectionStore.getState().getMcpClient();
      await cyfrMcp.runComponent(client, "catalyst:local.files", {
        action: "write_text",
        path: `data/agent_conversations/${conversationId}.json`,
        content: json,
      });

      const { useConversationStore } = await import("./conversation-store");
      await useConversationStore.getState().upsertIndex({
        id: conversationId,
        title,
        updated_at: convFile.updated_at,
        status: state.running ? "running" : "idle",
      });
    } catch {
      // Silent
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
    const client = await useConnectionStore.getState().getMcpClient();
    const parsed = await cyfrMcp.runComponent(client, "catalyst:local.files", {
      action: "read_text",
      path: `data/agent_conversations/${conversationId}.json`,
    });

    const fileContent = (parsed.result ?? parsed) as Record<string, unknown>;
    const content = fileContent.content as string;
    const convData = JSON.parse(content) as Record<string, unknown>;

    let resultContent: string | null = null;
    try {
      const logsResult = await cyfrMcp.getExecutionLogs(client, executionId);

      const status = logsResult.status as string;
      if (status === "completed") {
        const output = logsResult.output as Record<string, unknown> | undefined;
        resultContent = (output?.content as string) ?? null;
      } else if (status === "failed") {
        resultContent = `Agent error: ${(logsResult.error as string) ?? "Unknown error"}`;
      }
    } catch {
      // Can't get result
    }

    const messages = (convData.messages ?? []) as Record<string, unknown>[];
    const title =
      typeof convData.title === "string" && convData.title.length > 0
        ? convData.title
        : "Untitled";
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

    await cyfrMcp.runComponent(client, "catalyst:local.files", {
      action: "write_text",
      path: `data/agent_conversations/${conversationId}.json`,
      content: JSON.stringify(updated),
    });

    import("./conversation-store").then(({ useConversationStore }) => {
      useConversationStore.getState().upsertIndex({
        id: conversationId,
        title,
        updated_at: updated.updated_at as string,
        status: "idle",
      });
    });
  } catch {
    // Silent
  }
}

// ---------------------------------------------------------------------------
// Sub-agent event handler
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

  let matchSi = -1, matchTi = -1;
  outer: for (let si = segments.length - 1; si >= 0; si--) {
    const seg = segments[si]!;
    for (let ti = seg.tools.length - 1; ti >= 0; ti--) {
      const t = seg.tools[ti]!;
      if (t.emitTag === emitTag) {
        matchSi = si; matchTi = ti;
        break outer;
      }
    }
  }

  // Retroactive match by tool name prefix
  if (matchSi === -1) {
    const colonIdx = emitTag.indexOf(":");
    if (colonIdx > 0) {
      const tagToolName = emitTag.slice(0, colonIdx);
      outer2: for (let si = segments.length - 1; si >= 0; si--) {
        const seg = segments[si]!;
        for (let ti = seg.tools.length - 1; ti >= 0; ti--) {
          const t = seg.tools[ti]!;
          if (t.emitTag === null && t.tool === tagToolName) {
            const updatedTools = [...seg.tools];
            updatedTools[ti] = { ...t, emitTag };
            segments[si] = { ...seg, tools: updatedTools };
            matchSi = si; matchTi = ti;
            break outer2;
          }
        }
      }
    }
  }

  if (matchSi === -1) return;

  const seg = segments[matchSi]!;
  const tool = seg.tools[matchTi]!;
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
          updatedTools[matchTi] = updatedTool;
          segments[matchSi] = { ...seg, tools: updatedTools };
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
        updatedTools[matchTi] = updatedTool;
        segments[matchSi] = { ...seg, tools: updatedTools };
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
  updatedTools[matchTi] = updatedTool;
  segments[matchSi] = { ...seg, tools: updatedTools };
  set({ streamSegments: segments });
}

// ---------------------------------------------------------------------------
// Serialization helpers
// ---------------------------------------------------------------------------

function serializeMessage(msg: Message): SerializedMessage {
  return {
    role: msg.role,
    content: msg.content,
    timestamp: msg.timestamp,
    orchestrator: msg.orchestrator,
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
    orchestrator: msg.orchestrator,
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

// ---------------------------------------------------------------------------
// Fetch sub-agent definitions filtered by orchestrator
// ---------------------------------------------------------------------------

async function fetchSubAgents(
  client: { callTool: (name: string, args: Record<string, unknown>) => Promise<Record<string, unknown>> },
  orchestratorName: string,
  fallbackCatalystRef: string,
  fallbackModel: string | undefined,
): Promise<SubAgentDef[]> {
  try {
    const listResult = await client.callTool("aqua", {
      action: "list",
      type: "sub-agent",
    });
    const guides = (listResult.guides as Record<string, unknown>[]) ?? [];

    const subAgents: SubAgentDef[] = [];
    for (const g of guides) {
      try {
        const detail = await client.callTool("aqua", {
          action: "get",
          name: g.name as string,
        });

        // Filter by parent orchestrator
        const parent = detail.parent as string | null;
        if (parent && parent !== orchestratorName) continue;

        const toolPolicy =
          detail.tool_policy &&
          typeof detail.tool_policy === "object" &&
          !Array.isArray(detail.tool_policy)
            ? (detail.tool_policy as Record<string, unknown>)
            : {};

        subAgents.push(
          applyToolSurface(
            {
              name: (detail.name as string) ?? (g.name as string),
              title: (detail.title as string) ?? (g.name as string),
              description: (detail.description as string) ?? "",
              prompt: (detail.content as string) ?? "",
              visible_tools: (detail.visible_tools as string[] | null) ?? null,
              catalyst_ref: (detail.catalyst_ref as string | null) ?? fallbackCatalystRef,
              model: (detail.model as string | null) ?? fallbackModel ?? null,
            },
            toolPolicy,
          ),
        );
      } catch {
        // Skip agents that fail to load
      }
    }
    return subAgents;
  } catch {
    return [];
  }
}

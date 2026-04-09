// JSON-RPC 2.0 types

export interface JSONRPCRequest {
  jsonrpc: "2.0";
  id: number;
  method: string;
  params?: unknown;
}

export interface JSONRPCNotification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

export interface JSONRPCResponse {
  jsonrpc: "2.0";
  id: number | string;
  result?: unknown;
  error?: JSONRPCError;
}

export interface JSONRPCError {
  code: number;
  message: string;
  data?: unknown;
}

// MCP types

export interface InitializeResult {
  protocolVersion: string;
  capabilities: Record<string, unknown>;
  serverInfo?: { name: string; version: string };
}

export interface ToolCallParams {
  name: string;
  arguments: Record<string, unknown>;
}

export interface ToolCallResult {
  content: ContentBlock[];
  structuredContent?: unknown;
  isError?: boolean;
}

export interface ContentBlock {
  type: string;
  text?: string;
}

export interface Tool {
  name: string;
  title?: string;
  description?: string;
  inputSchema?: unknown;
  outputSchema?: unknown;
}

export interface ToolsListResult {
  tools: Tool[];
}

// MCP error codes
export const MCP_ERROR_SESSION_EXPIRED = -33302;
export const MCP_ERROR_SESSION_REQUIRED = -33301;
export const MCP_ERROR_AUTH_REQUIRED = -33001;

// Execution event types

export interface ExecutionEvent {
  sequence: number;
  type: string;
  data: ExecutionEventData;
}

export type ExecutionEventData =
  | EmitEventData
  | CompleteEventData
  | ErrorEventData;

export interface EmitEventData {
  kind: string;
  [key: string]: unknown;
}

export interface CompleteEventData {
  execution_id?: string;
}

export interface ErrorEventData {
  error?: string;
  message?: string;
  execution_id?: string;
}

// Agent-specific event data shapes

export interface TextDeltaData {
  kind: "text_delta";
  content: string;
}

export interface ToolUseData {
  kind: "tool_use";
  tool: string;
  tool_call_id?: string;
  turn?: number;
  input?: unknown;
}

export interface ToolResultData {
  kind: "tool_result";
  tool: string;
  preview?: string;
}

export interface UsageData {
  kind: "usage";
  input_tokens: number;
  output_tokens: number;
}

export interface ConversationCompleteData {
  kind: "conversation_complete";
  messages: unknown[];
}

export interface TurnStartData {
  kind: "turn_start";
  turn: number;
}

// Orchestrators (agents loaded from backend)

export interface Orchestrator {
  name: string;
  title: string;
  catalyst_ref: string;
  model: string;
}

export interface AgentDetail {
  name: string;
  title: string;
  type: "orchestrator" | "sub-agent";
  parent: string | null;
  description: string;
  model: string | null;
  catalyst_ref: string | null;
  visible_tools: string[] | null;
  content: string;
}

// Tinctures

export interface TinctureEntry {
  name: string;
  publisher: string;
  title: string;
  /** Glyph fallback from `manifest.tincture.icon` — emoji or Lucide icon name. Used when iconUrl is null. */
  iconHint: string | null;
  /** Resolved tincture:// URL for `manifest.tincture.media.icon`, if present. */
  iconUrl: string | null;
  /** Resolved tincture:// URLs for `manifest.tincture.media.previews`. Capped at 6. */
  previews: string[];
  /** Short marketing line from `manifest.tincture.tagline`. */
  tagline: string | null;
  public: boolean;
  component_ref: string;
}

// Conversation persistence

export interface ConversationFile {
  id: string;
  title: string;
  created_at: string;
  updated_at: string;
  default_orchestrator?: string;
  messages: SerializedMessage[];
  conversation_history: unknown[];
  execution_id: string | null;
  running: boolean;
  setup_component_ref?: string;
  pending_retry_input?: string;
}

export interface SerializedMessage {
  role: "user" | "assistant" | "error";
  content: string;
  timestamp: string;
  orchestrator?: string;
  turns?: number;
  duration_seconds?: number;
  token_usage?: { input: number; output: number };
  segments?: SerializedSegment[];
  attachments?: AttachmentMeta[];
}

export interface SerializedSegment {
  turn: number;
  text: string;
  tools: SerializedToolEntry[];
}

export interface SerializedToolEntry {
  tool: string;
  status: "done" | "running" | "error" | "pending" | "cancelled";
  preview?: string;
  input?: unknown;
  emit_tag?: string;
  sub_events?: SerializedSubEvent[];
}

export interface SerializedSubEvent {
  kind: "turn_start" | "tool_use" | "tool_result" | "text_delta";
  turn?: number;
  tool?: string;
  status?: string;
  preview?: string;
  content?: string;
}

export interface AttachmentMeta {
  filename: string;
  media_type: string;
}

// Conversation list entry
export interface ConversationEntry {
  id: string;
  title: string;
  updated_at: string;
  status: "idle" | "running";
}

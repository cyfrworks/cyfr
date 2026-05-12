import type {
  JSONRPCRequest,
  JSONRPCResponse,
  JSONRPCError,
  InitializeResult,
  ToolCallResult,
  Tool,
  ToolsListResult,
} from "./types";
import {
  MCP_ERROR_SESSION_EXPIRED,
  MCP_ERROR_SESSION_REQUIRED,
  MCP_ERROR_AUTH_REQUIRED,
} from "./types";

export class SessionExpiredError extends Error {
  constructor() {
    super("Session expired");
    this.name = "SessionExpiredError";
  }
}

export class SessionRequiredError extends Error {
  constructor() {
    super("Session required");
    this.name = "SessionRequiredError";
  }
}

export class AuthRequiredError extends Error {
  constructor() {
    super("Authentication required");
    this.name = "AuthRequiredError";
  }
}

interface TransportResponse {
  status: number;
  body: string;
  sessionId: string | null;
}

/**
 * MCP client speaking Streamable HTTP directly to the Cyfr `/mcp` endpoint.
 *
 * Auth modes (the server prefers the API key when both are present):
 * - Session ID (`MCP-Session-Id` header) — after Device Flow login
 * - API key (`Authorization: Bearer` header) — remote/API-key mode
 *
 * Cyfr's Emissary handles CORS/OPTIONS on `/mcp` (EmissaryWeb.Plugs.CORS), and
 * when the PWA is served from the same origin as Cyfr there is no CORS at all.
 */
export class McpClient {
  baseUrl: string;
  sessionId: string;
  apiKey: string;
  onSessionRecovered?: (sessionId: string) => void;

  private nextId = 0;
  private recovering = false;

  constructor(baseUrl: string, options: { apiKey?: string } = {}) {
    // Strip a trailing slash so `${baseUrl}/mcp` is well-formed; "" => same-origin.
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.sessionId = "";
    this.apiKey = options.apiKey ?? "";
  }

  async initialize(): Promise<void> {
    this.sessionId = "";
    const req: JSONRPCRequest = {
      jsonrpc: "2.0",
      id: ++this.nextId,
      method: "initialize",
      params: {
        protocolVersion: "2025-11-25",
        capabilities: {},
        clientInfo: { name: "aqua", version: "1.0.3" },
      },
    };

    const resp = await this.doRequest(req);

    if (resp.error) {
      throw new Error(`Initialize error: ${resp.error.message}`);
    }

    if (resp.result) {
      const result = resp.result as InitializeResult;
      if (result.protocolVersion && result.protocolVersion !== "2025-11-25") {
        throw new Error(
          `Unsupported protocol: server ${result.protocolVersion}, client 2025-11-25`,
        );
      }
    }

    await this.sendNotification("notifications/initialized", null);
  }

  async callTool(
    name: string,
    args: Record<string, unknown> = {},
  ): Promise<Record<string, unknown>> {
    const req: JSONRPCRequest = {
      jsonrpc: "2.0",
      id: ++this.nextId,
      method: "tools/call",
      params: { name, arguments: args },
    };

    const resp = await this.doRequest(req);

    if (resp.error) {
      throw new Error(resp.error.message);
    }

    const toolResult = resp.result as ToolCallResult;

    if (toolResult.isError) {
      const msg = toolResult.content?.[0]?.text ?? "Tool returned error";
      throw new Error(msg);
    }

    if (
      toolResult.structuredContent &&
      typeof toolResult.structuredContent === "object"
    ) {
      return toolResult.structuredContent as Record<string, unknown>;
    }

    if (
      toolResult.content?.length > 0 &&
      toolResult.content[0]!.type === "text" &&
      toolResult.content[0]!.text
    ) {
      try {
        return JSON.parse(toolResult.content[0]!.text) as Record<
          string,
          unknown
        >;
      } catch {
        return { text: toolResult.content[0]!.text };
      }
    }

    return {};
  }

  async listTools(): Promise<Tool[]> {
    const req: JSONRPCRequest = {
      jsonrpc: "2.0",
      id: ++this.nextId,
      method: "tools/list",
    };

    const resp = await this.doRequest(req);

    if (resp.error) {
      throw new Error(`List tools error: ${resp.error.message}`);
    }

    const result = resp.result as ToolsListResult;
    return result.tools ?? [];
  }

  async close(): Promise<void> {
    if (!this.sessionId) return;

    try {
      await this.transport("DELETE", null);
    } catch {
      // Best-effort
    }
    this.sessionId = "";
  }

  /** Single HTTP round-trip to the `/mcp` endpoint. */
  private async transport(
    method: "POST" | "DELETE",
    body: string | null,
  ): Promise<TransportResponse> {
    const headers: Record<string, string> = {};
    if (body != null) headers["content-type"] = "application/json";
    // The server can return either JSON or an SSE stream; ask for both.
    headers["accept"] = "application/json, text/event-stream";
    if (this.apiKey) headers["authorization"] = `Bearer ${this.apiKey}`;
    if (this.sessionId) headers["mcp-session-id"] = this.sessionId;

    const resp = await fetch(`${this.baseUrl}/mcp`, {
      method,
      headers,
      body: body ?? undefined,
      credentials: "include",
    });

    const text = await resp.text();
    return {
      status: resp.status,
      body: text,
      sessionId: resp.headers.get("mcp-session-id"),
    };
  }

  private async sendNotification(
    method: string,
    params: unknown,
  ): Promise<void> {
    const body = JSON.stringify({
      jsonrpc: "2.0",
      method,
      ...(params != null ? { params } : {}),
    });

    const resp = await this.transport("POST", body);

    if (resp.sessionId) {
      this.sessionId = resp.sessionId;
    }

    if (resp.status !== 200 && resp.status !== 202) {
      throw new Error(`Notification HTTP ${resp.status}: ${resp.body}`);
    }
  }

  private async doRequest(req: JSONRPCRequest): Promise<JSONRPCResponse> {
    try {
      return await this.doRequestOnce(req);
    } catch (err) {
      if (this.recovering) throw err;

      if (
        err instanceof SessionExpiredError ||
        err instanceof SessionRequiredError
      ) {
        this.recovering = true;
        try {
          await this.initialize();
          this.onSessionRecovered?.(this.sessionId);
          return await this.doRequestOnce(req);
        } finally {
          this.recovering = false;
        }
      }

      throw err;
    }
  }

  private async doRequestOnce(req: JSONRPCRequest): Promise<JSONRPCResponse> {
    const resp = await this.transport("POST", JSON.stringify(req));

    if (resp.sessionId) {
      this.sessionId = resp.sessionId;
    }

    if (resp.status !== 200) {
      if (resp.status === 404 && this.sessionId) {
        throw new SessionExpiredError();
      }

      try {
        const errResp = JSON.parse(resp.body) as JSONRPCResponse;
        if (errResp.error) {
          const code = (errResp.error as JSONRPCError).code;
          if (code === MCP_ERROR_SESSION_EXPIRED)
            throw new SessionExpiredError();
          if (code === MCP_ERROR_SESSION_REQUIRED)
            throw new SessionRequiredError();
          if (code === MCP_ERROR_AUTH_REQUIRED) throw new AuthRequiredError();
          throw new Error(errResp.error.message);
        }
      } catch (parseErr) {
        if (
          parseErr instanceof SessionExpiredError ||
          parseErr instanceof SessionRequiredError ||
          parseErr instanceof AuthRequiredError
        ) {
          throw parseErr;
        }
      }
      throw new Error(`HTTP ${resp.status}: ${resp.body}`);
    }

    return parseMcpBody(resp.body);
  }
}

/**
 * The `/mcp` endpoint may answer a POST with a bare JSON body or with an SSE
 * stream (`event: message\ndata: {...}\n\n`). For a single request/response we
 * just need the first `data:` payload.
 */
function parseMcpBody(body: string): JSONRPCResponse {
  const trimmed = body.trimStart();
  if (trimmed.startsWith("event:") || trimmed.startsWith("data:")) {
    for (const line of trimmed.split(/\r?\n/)) {
      if (line.startsWith("data:")) {
        return JSON.parse(line.slice(5).trim()) as JSONRPCResponse;
      }
    }
    throw new Error("SSE response contained no data frame");
  }
  return JSON.parse(body) as JSONRPCResponse;
}

import { invoke } from "@tauri-apps/api/core";
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

interface ProxyResponse {
  status: number;
  body: string;
  session_id: string | null;
}

/**
 * MCP client that proxies HTTP requests through the Tauri Rust backend.
 * This avoids CORS preflight issues (the CYFR server doesn't handle OPTIONS
 * on /mcp, causing browser fetch to fail with "Load failed").
 *
 * Supports two auth modes:
 * - Session ID (`MCP-Session-Id` header) — local modes after Device Flow
 * - API key (`Authorization: Bearer` header) — remote mode
 *
 * Both can be set; the server prefers the API key when present.
 */
export class McpClient {
  baseUrl: string;
  sessionId: string;
  apiKey: string;
  onSessionRecovered?: (sessionId: string) => void;

  private nextId = 0;
  private recovering = false;

  constructor(baseUrl: string, options: { apiKey?: string } = {}) {
    this.baseUrl = baseUrl;
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
        clientInfo: { name: "porta", version: "1.0.3" },
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
      await invoke<ProxyResponse>("mcp_proxy", {
        request: {
          method: "DELETE",
          body: null,
          session_id: this.sessionId,
          api_key: this.apiKey || null,
        },
      });
    } catch {
      // Best-effort
    }
    this.sessionId = "";
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

    const proxyResp = await invoke<ProxyResponse>("mcp_proxy", {
      request: {
        method: "POST",
        body,
        session_id: this.sessionId || null,
        api_key: this.apiKey || null,
      },
    });

    if (proxyResp.session_id) {
      this.sessionId = proxyResp.session_id;
    }

    if (proxyResp.status !== 200 && proxyResp.status !== 202) {
      throw new Error(
        `Notification HTTP ${proxyResp.status}: ${proxyResp.body}`,
      );
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

  private async doRequestOnce(
    req: JSONRPCRequest,
  ): Promise<JSONRPCResponse> {
    const proxyResp = await invoke<ProxyResponse>("mcp_proxy", {
      request: {
        method: "POST",
        body: JSON.stringify(req),
        session_id: this.sessionId || null,
        api_key: this.apiKey || null,
      },
    });

    if (proxyResp.session_id) {
      this.sessionId = proxyResp.session_id;
    }

    if (proxyResp.status !== 200) {
      if (proxyResp.status === 404 && this.sessionId) {
        throw new SessionExpiredError();
      }

      try {
        const errResp = JSON.parse(proxyResp.body) as JSONRPCResponse;
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
      throw new Error(`HTTP ${proxyResp.status}: ${proxyResp.body}`);
    }

    return JSON.parse(proxyResp.body) as JSONRPCResponse;
  }
}

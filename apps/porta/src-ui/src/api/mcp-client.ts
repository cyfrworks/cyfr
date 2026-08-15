import type {
  JSONRPCRequest,
  JSONRPCResponse,
  JSONRPCError,
  ToolCallResult,
  Tool,
  ToolsListResult,
} from "./types";
import { MCP_ERROR_AUTH_REQUIRED } from "./types";

class AuthRequiredError extends Error {
  constructor() {
    super("Authentication required");
    this.name = "AuthRequiredError";
  }
}

/** The protocol revision this client speaks. Declared on every request. */
const PROTOCOL_VERSION = "2026-07-28";

interface DiscoverResult {
  supportedVersions?: string[];
  capabilities?: Record<string, unknown>;
  instructions?: string;
  // Identity lives here, under io.modelcontextprotocol/serverInfo. The server
  // stamps it on every result, so discovery carries no separate copy.
  _meta?: Record<string, unknown>;
}

interface TransportResponse {
  status: number;
  body: string;
}

/**
 * MCP client speaking Streamable HTTP directly to the Cyfr `/mcp` endpoint.
 *
 * Auth: the caller's credential travels in `Authorization: Bearer` on every
 * request — either an API key, or the session token obtained by Device Flow
 * login. The server resolves it per request, so there is no protocol session to
 * establish and a revoked credential stops working immediately.
 *
 * Cyfr's Emissary handles CORS/OPTIONS on `/mcp` (EmissaryWeb.Plugs.CORS), and
 * when the PWA is served from the same origin as Cyfr there is no CORS at all.
 */
export class McpClient {
  baseUrl: string;
  sessionId: string;
  apiKey: string;

  private nextId = 0;

  constructor(baseUrl: string, options: { apiKey?: string } = {}) {
    // Strip a trailing slash so `${baseUrl}/mcp` is well-formed; "" => same-origin.
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.sessionId = "";
    this.apiKey = options.apiKey ?? "";
  }

  /**
   * Confirm the server speaks a revision we understand.
   *
   * Not a handshake and not a precondition — every request declares its own
   * version, so this establishes nothing and may be skipped entirely. It exists
   * so a mismatch surfaces once, clearly, instead of on every later call.
   */
  async discover(): Promise<void> {
    const req: JSONRPCRequest = {
      jsonrpc: "2.0",
      id: ++this.nextId,
      method: "server/discover",
      params: {},
    };

    const resp = await this.doRequest(req);

    if (resp.error) {
      throw new Error(`server/discover error: ${resp.error.message}`);
    }

    const result = resp.result as DiscoverResult | undefined;
    const versions = result?.supportedVersions ?? [];
    if (versions.length > 0 && !versions.includes(PROTOCOL_VERSION)) {
      throw new Error(
        `Unsupported protocol: server speaks ${versions.join(", ")}, client ${PROTOCOL_VERSION}`,
      );
    }
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

  /**
   * Releases client-side state. There is no server-side session to terminate —
   * the credential is revoked by logging out, not by closing a client.
   */
  async close(): Promise<void> {
    this.sessionId = "";
  }

  /**
   * The per-request metadata the protocol requires. There is no handshake, so
   * every request carries its own version, identity and capabilities.
   */
  private meta(): Record<string, unknown> {
    return {
      "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
      "io.modelcontextprotocol/clientInfo": { name: "aqua", version: "1.0.3" },
      "io.modelcontextprotocol/clientCapabilities": {},
    };
  }

  /**
   * The value `Mcp-Name` must carry, or null when the method names no subject.
   */
  private namedSubject(
    method: string,
    params: Record<string, unknown> | undefined,
  ): string | null {
    if (!params) return null;
    if (method === "tools/call" || method === "prompts/get") {
      return typeof params.name === "string" ? params.name : null;
    }
    if (method === "resources/read") {
      return typeof params.uri === "string" ? params.uri : null;
    }
    return null;
  }

  /**
   * The specification's Base64 sentinel, applied when a value cannot travel as
   * a plain header: outside visible ASCII, whitespace-padded, or already
   * looking like the sentinel.
   */
  private encodeHeaderValue(v: string): string {
    const plain =
      v.length > 0 &&
      v === v.trim() &&
      !v.startsWith("=?base64?") &&
      /^[\x20-\x7E]*$/.test(v);

    if (plain) return v;

    const bytes = new TextEncoder().encode(v);
    let binary = "";
    bytes.forEach((b) => (binary += String.fromCharCode(b)));
    return `=?base64?${btoa(binary)}?=`;
  }

  /** Single HTTP round-trip to the `/mcp` endpoint. */
  private async transport(
    method: "POST" | "DELETE",
    body: string | null,
    routing?: { method: string; params?: Record<string, unknown> },
  ): Promise<TransportResponse> {
    const headers: Record<string, string> = {};

    // Mirror body fields into headers so an intermediary can route without
    // parsing the body. The server refuses a header that disagrees with the
    // body, so both are derived from the same value.
    if (routing) {
      headers["mcp-method"] = routing.method;
      const name = this.namedSubject(routing.method, routing.params);
      if (name !== null) headers["mcp-name"] = this.encodeHeaderValue(name);
    }
    // Required on every request, and must equal the version declared in _meta.
    headers["mcp-protocol-version"] = PROTOCOL_VERSION;
    if (body != null) headers["content-type"] = "application/json";
    // The server can return either JSON or an SSE stream; ask for both.
    headers["accept"] = "application/json, text/event-stream";
    // An explicit API key wins; otherwise the Device Flow session token is the
    // bearer credential. Both are resolved server-side on every request.
    const credential = this.apiKey || this.sessionId;
    if (credential) headers["authorization"] = `Bearer ${credential}`;

    const resp = await fetch(`${this.baseUrl}/mcp`, {
      method,
      headers,
      body: body ?? undefined,
      credentials: "include",
    });

    const text = await resp.text();
    return { status: resp.status, body: text };
  }

  /**
   * No retry-on-expiry: the credential authenticates each request on its own,
   * so a rejected one will be rejected again. A revoked credential needs a
   * fresh login, not a re-handshake.
   */
  private async doRequest(req: JSONRPCRequest): Promise<JSONRPCResponse> {
    return this.doRequestOnce(req);
  }

  private async doRequestOnce(req: JSONRPCRequest): Promise<JSONRPCResponse> {
    const params = {
      ...((req.params as Record<string, unknown>) ?? {}),
      _meta: this.meta(),
    };
    const resp = await this.transport(
      "POST",
      JSON.stringify({ ...req, params }),
      {
        method: req.method,
        params,
      },
    );

    if (resp.status !== 200) {
      // A 404 is not an auth signal in this revision: the server has no
      // sessions and answers 404 with -32601 for an unimplemented method.
      // The JSON-RPC error body is the only source of meaning.
      let parsed: JSONRPCResponse | null = null;
      try {
        parsed = JSON.parse(resp.body) as JSONRPCResponse;
      } catch {
        /* body was not JSON — parsed stays null */
      }
      const error = parsed?.error as JSONRPCError | undefined;
      if (error) {
        if (error.code === MCP_ERROR_AUTH_REQUIRED)
          throw new AuthRequiredError();
        throw new Error(error.message);
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

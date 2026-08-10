package mcp

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync/atomic"
)

const protocolVersion = "2026-07-28"

// ErrSessionExpired is returned when the server reports that the session has expired.
var ErrSessionExpired = fmt.Errorf("session expired")

// ErrSessionRequired is returned when the server requires a session but none was provided.
var ErrSessionRequired = fmt.Errorf("session required")

// ErrAuthRequired is returned when the session exists but is not authenticated.
var ErrAuthRequired = fmt.Errorf("authentication required")

// ErrUnsupportedProtocol is returned when the server's protocol version doesn't match the client's.
var ErrUnsupportedProtocol = fmt.Errorf("unsupported protocol version")

// Client is a JSON-RPC 2.0 MCP client over HTTP.
type Client struct {
	BaseURL   string
	SessionID string

	httpClient *http.Client
	nextID     atomic.Int64
}

// NewClient creates a new MCP client for the given base URL.
func NewClient(baseURL string) *Client {
	return &Client{
		BaseURL: baseURL,
		httpClient: &http.Client{
			// Never follow an HTTPS->HTTP downgrade (it would leak the session
			// token over plaintext), and cap redirect chains so a misbehaving
			// or hostile server can't bounce us indefinitely.
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) > 0 && via[0].URL.Scheme == "https" && req.URL.Scheme != "https" {
					return fmt.Errorf("refusing to follow HTTPS->%s redirect to %s", req.URL.Scheme, req.URL.Host)
				}
				if len(via) >= 5 {
					return fmt.Errorf("stopped after 5 redirects")
				}
				return nil
			},
		},
	}
}

// setCredential attaches the caller's credential to a request.
//
// The credential travels in Authorization on every request rather than in a
// protocol session header: the server resolves it per request, so a revoked
// token stops working immediately and there is no server-side session state to
// establish, carry or expire.
func (c *Client) setCredential(req *http.Request) {
	if c.SessionID != "" {
		req.Header.Set("Authorization", "Bearer "+c.SessionID)
	}
}

// Close releases client-side state. The credential authenticates each request
// on its own, so there is no server-side session to terminate — the token
// outlives the process and is revoked by logging out, not by closing a client.
func (c *Client) Close() error {
	c.SessionID = ""
	return nil
}

// Discover asks the server which protocol revisions it speaks, and fails if
// none of them is ours. There is no handshake to perform — every request carries
// its own version — so this is purely a compatibility check a caller may run
// once, and never a precondition for anything else.
func (c *Client) Discover() error {
	req := JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      int(c.nextID.Add(1)),
		Method:  "server/discover",
		Params:  map[string]any{},
	}

	resp, err := c.doRequest(req)
	if err != nil {
		return fmt.Errorf("server/discover: %w", err)
	}
	if resp.Error != nil {
		return fmt.Errorf("server/discover error: %s", resp.Error.Message)
	}

	resultBytes, _ := json.Marshal(resp.Result)
	var discovered DiscoverResult
	if json.Unmarshal(resultBytes, &discovered) != nil {
		return nil // Unreadable result is not fatal; the next real call decides.
	}

	for _, v := range discovered.ProtocolVersions {
		if v == protocolVersion {
			return nil
		}
	}

	return fmt.Errorf("%w: server speaks %v, client supports %q",
		ErrUnsupportedProtocol, discovered.ProtocolVersions, protocolVersion)
}

// withMeta attaches the per-request metadata the protocol requires.
//
// There is no handshake, so every request declares its own protocol version,
// client identity and capabilities. Params may be a struct or a map, so it is
// round-tripped through JSON to get a map to add `_meta` to.
func withMeta(params any) map[string]any {
	m := map[string]any{}
	if params != nil {
		if b, err := json.Marshal(params); err == nil {
			_ = json.Unmarshal(b, &m)
		}
	}
	m["_meta"] = map[string]any{
		"io.modelcontextprotocol/protocolVersion": protocolVersion,
		"io.modelcontextprotocol/clientInfo": map[string]any{
			"name":    "cyfr",
			"version": "0.1.0",
		},
		"io.modelcontextprotocol/clientCapabilities": map[string]any{},
	}
	return m
}

// CallTool invokes an MCP tool and returns the raw result.
func (c *Client) CallTool(name string, args map[string]any) (map[string]any, error) {
	if args == nil {
		args = map[string]any{}
	}
	req := JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      int(c.nextID.Add(1)),
		Method:  "tools/call",
		Params: ToolCallParams{
			Name:      name,
			Arguments: args,
		},
	}

	resp, err := c.doRequest(req)
	if err != nil {
		return nil, err
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("%s", resp.Error.Message)
	}

	// Parse the result - it contains content blocks
	resultBytes, err := json.Marshal(resp.Result)
	if err != nil {
		return nil, fmt.Errorf("marshal result: %w", err)
	}

	var toolResult ToolCallResult
	if err := json.Unmarshal(resultBytes, &toolResult); err != nil {
		// Try as raw map
		var raw map[string]any
		if err2 := json.Unmarshal(resultBytes, &raw); err2 != nil {
			return nil, fmt.Errorf("unmarshal result: %w", err)
		}
		return raw, nil
	}

	if toolResult.IsError {
		if len(toolResult.Content) > 0 {
			return nil, fmt.Errorf("%s", toolResult.Content[0].Text)
		}
		return nil, fmt.Errorf("tool returned error")
	}

	// MCP 2025-11-25: prefer structuredContent when available
	if toolResult.StructuredContent != nil {
		if m, ok := toolResult.StructuredContent.(map[string]any); ok {
			return m, nil
		}
	}

	// Fall back to parsing text content as JSON
	if len(toolResult.Content) > 0 && toolResult.Content[0].Type == "text" {
		var result map[string]any
		if err := json.Unmarshal([]byte(toolResult.Content[0].Text), &result); err != nil {
			return map[string]any{"text": toolResult.Content[0].Text}, nil
		}
		return result, nil
	}

	return map[string]any{}, nil
}

// ListTools returns the list of available MCP tools.
func (c *Client) ListTools() ([]Tool, error) {
	req := JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      int(c.nextID.Add(1)),
		Method:  "tools/list",
	}

	resp, err := c.doRequest(req)
	if err != nil {
		return nil, fmt.Errorf("list tools: %w", err)
	}

	if resp.Error != nil {
		return nil, fmt.Errorf("list tools error: %s", resp.Error.Message)
	}

	resultBytes, err := json.Marshal(resp.Result)
	if err != nil {
		return nil, fmt.Errorf("marshal result: %w", err)
	}

	var toolsResult ToolsListResult
	if err := json.Unmarshal(resultBytes, &toolsResult); err != nil {
		return nil, fmt.Errorf("unmarshal tools: %w", err)
	}

	return toolsResult.Tools, nil
}

// sendNotification sends a JSON-RPC notification (no id, no response expected).
func (c *Client) sendNotification(method string, params any) error {
	notif := JSONRPCNotification{
		JSONRPC: "2.0",
		Method:  method,
		Params:  params,
	}

	body, err := json.Marshal(notif)
	if err != nil {
		return fmt.Errorf("marshal notification: %w", err)
	}

	httpReq, err := http.NewRequest("POST", c.BaseURL+"/mcp", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create notification request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json, text/event-stream")
	httpReq.Header.Set("MCP-Protocol-Version", protocolVersion)
	c.setCredential(httpReq)

	httpResp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return fmt.Errorf("send notification: %w", err)
	}
	defer httpResp.Body.Close()

	// Notifications expect 200 or 202
	if httpResp.StatusCode != http.StatusOK && httpResp.StatusCode != http.StatusAccepted {
		respBody, _ := io.ReadAll(httpResp.Body)
		return fmt.Errorf("notification HTTP %d: %s", httpResp.StatusCode, string(respBody))
	}

	return nil
}

func (c *Client) doRequest(req JSONRPCRequest) (*JSONRPCResponse, error) {
	// No retry-on-expiry: the credential authenticates each request on its own,
	// so a rejected one will be rejected again. A revoked or expired token needs
	// `cyfr login`, not a re-handshake.
	return c.doRequestOnce(req)
}

func (c *Client) doRequestOnce(req JSONRPCRequest) (*JSONRPCResponse, error) {
	req.Params = withMeta(req.Params)

	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequest("POST", c.BaseURL+"/mcp", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json, text/event-stream")
	httpReq.Header.Set("MCP-Protocol-Version", protocolVersion)
	c.setCredential(httpReq)

	httpResp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("http request: %w", err)
	}
	defer httpResp.Body.Close()

	respBody, err := io.ReadAll(httpResp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}

	if httpResp.StatusCode != http.StatusOK {
		// MCP spec: server returns HTTP 404 when session has expired.
		// Check this before JSON-RPC parsing to handle bare 404 responses.
		if httpResp.StatusCode == http.StatusNotFound && c.SessionID != "" {
			return nil, ErrSessionExpired
		}

		// Try to parse as JSON-RPC error and extract a clean message
		var errResp JSONRPCResponse
		if json.Unmarshal(respBody, &errResp) == nil && errResp.Error != nil {
			switch errResp.Error.Code {
			case -33302:
				return nil, ErrSessionExpired
			case -33301:
				return nil, ErrSessionRequired
			case -33001:
				return nil, ErrAuthRequired
			default:
				return nil, fmt.Errorf("%s", errResp.Error.Message)
			}
		}
		return nil, fmt.Errorf("HTTP %d: %s", httpResp.StatusCode, string(respBody))
	}

	var resp JSONRPCResponse
	if err := json.Unmarshal(respBody, &resp); err != nil {
		return nil, fmt.Errorf("unmarshal response: %w", err)
	}

	return &resp, nil
}

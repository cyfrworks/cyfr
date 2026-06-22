package mcp

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync/atomic"
)

const protocolVersion = "2025-11-25"

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

	// OnSessionRecovered is called when auto-recovery obtains a new session ID.
	// Use this to persist the new session ID to config.
	OnSessionRecovered func(sessionID string)

	httpClient *http.Client
	nextID     atomic.Int64
	recovering bool
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

// Close terminates the MCP session by sending DELETE to the server.
// Per MCP spec, clients SHOULD send DELETE when they no longer need a session.
func (c *Client) Close() error {
	if c.SessionID == "" {
		return nil
	}
	req, err := http.NewRequest("DELETE", c.BaseURL+"/mcp", nil)
	if err != nil {
		return fmt.Errorf("create delete request: %w", err)
	}
	req.Header.Set("MCP-Session-Id", c.SessionID)
	req.Header.Set("MCP-Protocol-Version", protocolVersion)
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("delete session: %w", err)
	}
	resp.Body.Close()
	c.SessionID = ""
	return nil
}

// Initialize sends the MCP initialize request and captures the session ID.
func (c *Client) Initialize() error {
	c.SessionID = "" // Clear stale session ID; initialize creates a new one
	req := JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      int(c.nextID.Add(1)),
		Method:  "initialize",
		Params: map[string]any{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]any{},
			"clientInfo": map[string]any{
				"name":    "cyfr",
				"version": "0.1.0",
			},
		},
	}

	resp, err := c.doRequest(req)
	if err != nil {
		return fmt.Errorf("initialize: %w", err)
	}

	if resp.Error != nil {
		return fmt.Errorf("initialize error: %s", resp.Error.Message)
	}

	// MCP spec: client SHOULD verify protocolVersion in response
	if resp.Result != nil {
		resultBytes, _ := json.Marshal(resp.Result)
		var initResult InitializeResult
		if json.Unmarshal(resultBytes, &initResult) == nil {
			if initResult.ProtocolVersion != "" && initResult.ProtocolVersion != protocolVersion {
				return fmt.Errorf("%w: server speaks %q, client supports %q",
					ErrUnsupportedProtocol, initResult.ProtocolVersion, protocolVersion)
			}
		}
	}

	// MCP spec: client MUST send notifications/initialized after successful init
	if err := c.sendNotification("notifications/initialized", nil); err != nil {
		return fmt.Errorf("send initialized notification: %w", err)
	}

	return nil
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
	if c.SessionID != "" {
		httpReq.Header.Set("MCP-Session-Id", c.SessionID)
	}

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
	resp, err := c.doRequestOnce(req)
	if err == nil || c.recovering {
		return resp, err
	}

	// Auto-recover on session expired or session required
	if errors.Is(err, ErrSessionExpired) || errors.Is(err, ErrSessionRequired) {
		c.recovering = true
		defer func() { c.recovering = false }()

		if initErr := c.Initialize(); initErr != nil {
			return nil, err // Return the original error
		}

		if c.OnSessionRecovered != nil {
			c.OnSessionRecovered(c.SessionID)
		}

		// Retry the original request with the new session
		return c.doRequestOnce(req)
	}

	return resp, err
}

func (c *Client) doRequestOnce(req JSONRPCRequest) (*JSONRPCResponse, error) {
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
	if c.SessionID != "" {
		httpReq.Header.Set("MCP-Session-Id", c.SessionID)
	}

	httpResp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("http request: %w", err)
	}
	defer httpResp.Body.Close()

	// Capture session ID from response headers
	if sid := httpResp.Header.Get("Mcp-Session-Id"); sid != "" {
		c.SessionID = sid
	}

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

package mcp

import (
	"bytes"
	"encoding/json"
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
		BaseURL:    baseURL,
		httpClient: &http.Client{},
	}
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

	return nil
}

// CallTool invokes an MCP tool and returns the raw result.
func (c *Client) CallTool(name string, args map[string]any) (map[string]any, error) {
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
		return nil, fmt.Errorf("call tool %s: %w", name, err)
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

	// Parse the text content as JSON
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

func (c *Client) doRequest(req JSONRPCRequest) (*JSONRPCResponse, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequest("POST", c.BaseURL+"/mcp", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
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
		// Detect session expiry: server returns 404 with error code -33302
		if httpResp.StatusCode == http.StatusNotFound {
			var errResp JSONRPCResponse
			if json.Unmarshal(respBody, &errResp) == nil && errResp.Error != nil && errResp.Error.Code == -33302 {
				return nil, ErrSessionExpired
			}
		}
		// Detect session required: server returns 400 with error code -33301
		if httpResp.StatusCode == http.StatusBadRequest {
			var errResp JSONRPCResponse
			if json.Unmarshal(respBody, &errResp) == nil && errResp.Error != nil && errResp.Error.Code == -33301 {
				return nil, ErrSessionRequired
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

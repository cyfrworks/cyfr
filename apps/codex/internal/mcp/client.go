package mcp

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/cyfr/codex/internal/version"
)

const protocolVersion = "2026-07-28"

// ErrAuthRequired is returned when the caller presented no usable credential.
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
			// A hung server must never hang the CLI (or a script driving it)
			// indefinitely. The bound covers the whole exchange including a
			// progress stream; the server brutal-kills a tool call at five
			// minutes, so ten leaves room for the stream to drain. Per-call
			// deadlines travel in the request context.
			Timeout: 10 * time.Minute,
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
func (c *Client) Discover(ctx context.Context) error {
	req := JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      int(c.nextID.Add(1)),
		Method:  "server/discover",
		Params:  map[string]any{},
	}

	resp, err := c.doRequest(ctx, req)
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

	for _, v := range discovered.SupportedVersions {
		if v == protocolVersion {
			return nil
		}
	}

	return fmt.Errorf("%w: server speaks %v, client supports %q",
		ErrUnsupportedProtocol, discovered.SupportedVersions, protocolVersion)
}

// routingHeaders mirrors body fields into the headers the protocol requires, so
// an intermediary can route and authorize without parsing the body. The server
// refuses a header that disagrees with the body, so they are derived from it
// rather than tracked separately.
func routingHeaders(req *http.Request, method string, params any) {
	req.Header.Set("Mcp-Method", method)

	if name := namedSubject(method, params); name != "" {
		req.Header.Set("Mcp-Name", encodeHeaderValue(name))
	}
}

// namedSubject is the value Mcp-Name must carry, or "" when the method names
// no subject.
func namedSubject(method string, params any) string {
	m, ok := params.(map[string]any)
	if !ok {
		return ""
	}

	switch method {
	case "tools/call", "prompts/get":
		if name, ok := m["name"].(string); ok {
			return name
		}
	case "resources/read":
		if uri, ok := m["uri"].(string); ok {
			return uri
		}
	}
	return ""
}

// encodeHeaderValue applies the specification's Base64 sentinel when a value
// cannot travel as a plain header: outside visible ASCII, padded with
// whitespace, or already looking like the sentinel.
func encodeHeaderValue(v string) string {
	safe := v != "" &&
		v == strings.TrimSpace(v) &&
		!strings.HasPrefix(v, "=?base64?")

	if safe {
		for _, r := range v {
			if r < 0x20 || r > 0x7E {
				safe = false
				break
			}
		}
	}

	if safe {
		return v
	}
	return "=?base64?" + base64.StdEncoding.EncodeToString([]byte(v)) + "?="
}

// withMeta attaches the per-request metadata the protocol requires.
//
// There is no handshake, so every request declares its own protocol version,
// client identity and capabilities. Params may be a struct or a map, so it is
// round-tripped through JSON to get a map to add `_meta` to.
func withMeta(params any, progressToken string) map[string]any {
	m := map[string]any{}
	if params != nil {
		if b, err := json.Marshal(params); err == nil {
			_ = json.Unmarshal(b, &m)
		}
	}
	meta := map[string]any{
		"io.modelcontextprotocol/protocolVersion": protocolVersion,
		"io.modelcontextprotocol/clientInfo": map[string]any{
			"name": "cyfr",
			// The ldflags-injected build version — a hardcoded literal here
			// once announced 0.1.0 from every build.
			"version": version.Version,
		},
		"io.modelcontextprotocol/clientCapabilities": map[string]any{},
	}
	// Opting in is what makes the server answer with a stream instead of a
	// single object, so it is only sent when the caller can consume one.
	if progressToken != "" {
		meta["progressToken"] = progressToken
	}
	m["_meta"] = meta
	return m
}

// CallTool invokes an MCP tool and returns the raw result.
func (c *Client) CallTool(ctx context.Context, name string, args map[string]any) (map[string]any, error) {
	return c.CallToolWithProgress(ctx, name, args, nil)
}

// CallToolWithProgress invokes a tool and reports progress as it arrives.
//
// Progress travels on this request's own response stream. There is no separate
// stream to open and no id to correlate by hand: passing a handler is what opts
// in, and every notification on the stream belongs to this call.
func (c *Client) CallToolWithProgress(ctx context.Context, name string, args map[string]any, onProgress ProgressFunc) (map[string]any, error) {
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

	progressToken := ""
	if onProgress != nil {
		progressToken = fmt.Sprintf("prog-%d", req.ID)
	}

	resp, err := c.doRequestOnce(ctx, req, progressToken, onProgress)
	if err != nil {
		return nil, err
	}

	if resp.Error != nil {
		return nil, rpcError(resp.Error)
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
func (c *Client) ListTools(ctx context.Context) ([]Tool, error) {
	req := JSONRPCRequest{
		JSONRPC: "2.0",
		ID:      int(c.nextID.Add(1)),
		Method:  "tools/list",
	}

	resp, err := c.doRequest(ctx, req)
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
func (c *Client) sendNotification(ctx context.Context, method string, params any) error {
	notif := JSONRPCNotification{
		JSONRPC: "2.0",
		Method:  method,
		Params:  params,
	}

	body, err := json.Marshal(notif)
	if err != nil {
		return fmt.Errorf("marshal notification: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", c.BaseURL+"/mcp", bytes.NewReader(body))
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

func (c *Client) doRequest(ctx context.Context, req JSONRPCRequest) (*JSONRPCResponse, error) {
	// No retry-on-expiry: the credential authenticates each request on its own,
	// so a rejected one will be rejected again. A revoked or expired token needs
	// `cyfr login`, not a re-handshake.
	return c.doRequestOnce(ctx, req, "", nil)
}

// rpcError maps a JSON-RPC error object to a Go error, preserving the
// sentinel identity the auth code carries: `errors.Is(err, ErrAuthRequired)`
// must hold wherever -33001 arrived — a 4xx envelope or a 200 body alike.
// The old `fmt.Errorf("%s", …)` wrappers erased it, so the login hint only
// worked by the coincidence that auth errors happened to ride a 401.
func rpcError(e *JSONRPCError) error {
	if e.Code == -33001 {
		return fmt.Errorf("%w: %s", ErrAuthRequired, e.Message)
	}
	return fmt.Errorf("%s", e.Message)
}

// ProgressFunc receives the params of a notifications/progress sent while a
// request was being served.
type ProgressFunc func(params map[string]any)

func (c *Client) doRequestOnce(ctx context.Context, req JSONRPCRequest, progressToken string, onProgress ProgressFunc) (*JSONRPCResponse, error) {
	req.Params = withMeta(req.Params, progressToken)

	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", c.BaseURL+"/mcp", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json, text/event-stream")
	httpReq.Header.Set("MCP-Protocol-Version", protocolVersion)
	routingHeaders(httpReq, req.Method, req.Params)
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
		// A 404 used to be read as "the session expired" — that was the previous
		// transport, where the server forgot a session and answered 404. This
		// revision has no sessions and gives 404 a different meaning entirely:
		// an unimplemented method, carrying -32601. Keeping the old heuristic
		// told a perfectly authenticated user to run `cyfr login` whenever they
		// hit a method the server does not have.
		var errResp JSONRPCResponse
		if json.Unmarshal(respBody, &errResp) == nil && errResp.Error != nil {
			return nil, rpcError(errResp.Error)
		}
		return nil, fmt.Errorf("HTTP %d: %s", httpResp.StatusCode, string(respBody))
	}

	// The server answers a progress-opted request with an SSE stream: the
	// notifications it produced while working, then the response. Both shapes are
	// valid for the same request, so the content type decides how to read it.
	if strings.HasPrefix(httpResp.Header.Get("Content-Type"), "text/event-stream") {
		return parseStreamedResponse(respBody, onProgress)
	}

	var resp JSONRPCResponse
	if err := json.Unmarshal(respBody, &resp); err != nil {
		return nil, fmt.Errorf("unmarshal response: %w", err)
	}

	return &resp, nil
}

// parseStreamedResponse walks the SSE frames of a response stream, handing each
// notification to onProgress and returning the response that terminates it.
func parseStreamedResponse(body []byte, onProgress ProgressFunc) (*JSONRPCResponse, error) {
	var last *JSONRPCResponse

	for _, frame := range strings.Split(string(body), "\n\n") {
		var payload []byte
		for _, line := range strings.Split(frame, "\n") {
			if data, ok := strings.CutPrefix(line, "data: "); ok {
				payload = append(payload, data...)
			}
		}
		if len(payload) == 0 {
			continue
		}

		// A notification has a method and no id; the response has an id.
		var probe struct {
			Method string `json:"method"`
			ID     any    `json:"id"`
		}
		if json.Unmarshal(payload, &probe) != nil {
			continue
		}

		if probe.ID == nil && probe.Method != "" {
			if onProgress != nil && probe.Method == "notifications/progress" {
				var notif struct {
					Params map[string]any `json:"params"`
				}
				if json.Unmarshal(payload, &notif) == nil {
					onProgress(notif.Params)
				}
			}
			continue
		}

		var resp JSONRPCResponse
		if json.Unmarshal(payload, &resp) == nil {
			last = &resp
		}
	}

	if last == nil {
		return nil, fmt.Errorf("response stream ended without a response")
	}
	return last, nil
}

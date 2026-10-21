// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package mcp

import "encoding/json"

// JSONRPCRequest is a JSON-RPC 2.0 request.
type JSONRPCRequest struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int    `json:"id"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

// JSONRPCResponse is a JSON-RPC 2.0 response.
// ID is typed as any to accept both integer and string IDs per JSON-RPC 2.0 spec.
type JSONRPCResponse struct {
	JSONRPC string        `json:"jsonrpc"`
	ID      any           `json:"id"`
	Result  any           `json:"result,omitempty"`
	Error   *JSONRPCError `json:"error,omitempty"`
}

// JSONRPCError is a JSON-RPC 2.0 error object.
type JSONRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

// DiscoverResult is the result of server/discover: which protocol revisions the
// server speaks, plus its capabilities and guidance.
//
// Identity is not here. The server reports itself in every result's _meta under
// io.modelcontextprotocol/serverInfo, so discovery has no reason to carry a
// second copy — see Meta.
type DiscoverResult struct {
	SupportedVersions []string       `json:"supportedVersions"`
	Capabilities      map[string]any `json:"capabilities"`
	Instructions      string         `json:"instructions,omitempty"`
	Meta              map[string]any `json:"_meta,omitempty"`
}

// ToolCallParams are the parameters for tools/call.
type ToolCallParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

// ToolCallResult is the result of tools/call.
type ToolCallResult struct {
	Content           []ContentBlock `json:"content"`
	StructuredContent any            `json:"structuredContent,omitempty"`
	IsError           bool           `json:"isError,omitempty"`
}

// ContentBlock is a content block in a tool result.
type ContentBlock struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

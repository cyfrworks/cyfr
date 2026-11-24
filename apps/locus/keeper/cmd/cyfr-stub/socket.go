// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"

	"github.com/cyfr/locus/keeper/internal/toolsock"
)

// socket is the socket mode's source: the driver's socket of this name.
type socket string

func (s socket) list() (any, *rpcError) {
	var listing toolsock.Listing
	if err := toolsock.Ask(string(s), toolsock.Request{Op: "list"}, &listing); err != nil {
		return nil, &rpcError{Code: -32603, Message: unreachable}
	}
	if listing.Tools == nil {
		listing.Tools = []toolsock.Tool{}
	}
	return listing, nil
}

func (s socket) call(params json.RawMessage) (callResult, *rpcError) {
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &p); err != nil || p.Name == "" {
		return callResult{}, &rpcError{Code: -32602, Message: "invalid params"}
	}
	var result toolsock.Result
	if err := toolsock.Ask(string(s), toolsock.Request{Op: "call", Name: p.Name, Arguments: p.Arguments}, &result); err != nil {
		return callResult{Content: []content{{Type: "text", Text: unreachable}}, IsError: true}, nil
	}
	return callResult{Content: []content{{Type: "text", Text: result.Text}}, IsError: result.IsError}, nil
}

func (socket) holds() bool { return true }

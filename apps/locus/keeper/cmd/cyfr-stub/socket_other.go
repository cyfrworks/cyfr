// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build !linux

package main

import "encoding/json"

// socket is the socket mode's source. The driver's socket is an abstract
// Unix socket, which only Linux has, so elsewhere it is never reachable.
type socket string

func (socket) list() (any, *rpcError) {
	return nil, &rpcError{Code: -32603, Message: unreachable}
}

func (socket) call(json.RawMessage) (callResult, *rpcError) {
	return callResult{Content: []content{{Type: "text", Text: unreachable}}, IsError: true}, nil
}

func (socket) holds() bool { return true }

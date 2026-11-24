// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Command cyfr-stub is the MCP stdio server through which a harness that
// CYFR drives sees CYFR's tools. It runs nothing itself: CYFR runs every
// call through its gate, and the stub answers what CYFR answered. It has
// two modes.
//
//	cyfr-stub <tool>…
//
// Each argument is one tool as JSON, `{"name", "description"?,
// "inputSchema"?}`; `tools/list` answers them in order. A `tools/call`
// answers the `result` member of the call's arguments as its text content,
// or the `error` member with `isError`, and nothing else: the harness asks
// its driver before it calls a tool of the stub's (Claude Code under
// cyfr-claude-code), the driver holds the ask while CYFR runs the call,
// and its allow puts CYFR's answer into the call's input (`updatedInput`).
// A call with neither member did not pass that ask, and is answered as an
// error naming that. One tool per argument, since an argument is bounded
// by the kernel (MAX_ARG_STRLEN, 128 KiB) and a tool list is not.
//
//	cyfr-stub --socket <name>
//
// The tools are the brain driver's, asked of its socket, the abstract Unix
// socket <name> (production passes the toolsock package's Name). Each
// `tools/list` asks the socket for its list, so a session's later listing
// shows the tools the session holds then; a `tools/call` passes the call's
// name and arguments whole to the socket, and answers its result as text
// content, with `isError` when the result is an error. The socket answers a
// call once CYFR has, with no clock, so each call is answered in its own
// goroutine and calls overlap. A socket the stub cannot reach is answered
// as an error naming that CYFR's tools are not reachable.
//
// Either way the stub speaks newline-delimited JSON-RPC 2.0 on standard
// input and output, writes nothing else to its output, and exits when its
// input closes and every call it holds is answered.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
)

// maxLineBytes bounds one message from the harness: a call's input with
// the largest answer the driver puts in it, and room beyond.
const maxLineBytes = 16 << 20

// ungated is the answer to a call that did not pass the driver's ask.
const ungated = "This call did not pass CYFR's gate, so CYFR did not run it. Ask again; CYFR answers a call only through its own ask."

// unreachable answers a request in socket mode when the driver's socket
// cannot be reached: the words the model reads.
const unreachable = "CYFR's tools are not reachable from this session right now, so CYFR has no answer to this request."

// tool is one tool as `tools/list` answers it.
type tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--socket" {
		if len(os.Args) != 3 || os.Args[2] == "" {
			fmt.Fprintln(os.Stderr, "cyfr-stub: usage: cyfr-stub --socket NAME")
			os.Exit(2)
		}
		if err := serveSource(os.Stdin, os.Stdout, socket(os.Args[2])); err != nil {
			fmt.Fprintln(os.Stderr, "cyfr-stub:", err)
			os.Exit(1)
		}
		return
	}
	tools, err := parseTools(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "cyfr-stub:", err)
		os.Exit(2)
	}
	if err := serve(os.Stdin, os.Stdout, tools); err != nil {
		fmt.Fprintln(os.Stderr, "cyfr-stub:", err)
		os.Exit(1)
	}
}

// parseTools reads one tool from each argument: a name of 1 to 128
// characters, given once, an optional description and an input schema
// that is a JSON object (`{"type": "object"}` when absent).
func parseTools(args []string) ([]tool, error) {
	tools := make([]tool, 0, len(args))
	seen := make(map[string]bool, len(args))
	for i, arg := range args {
		var raw struct {
			Name        *string         `json:"name"`
			Description *string         `json:"description"`
			InputSchema json.RawMessage `json:"inputSchema"`
		}
		if err := json.Unmarshal([]byte(arg), &raw); err != nil {
			return nil, fmt.Errorf("argument %d is not a tool as JSON", i+1)
		}
		if raw.Name == nil || len(*raw.Name) == 0 || len(*raw.Name) > 128 {
			return nil, fmt.Errorf("argument %d names no tool of 1 to 128 characters", i+1)
		}
		if seen[*raw.Name] {
			return nil, fmt.Errorf("argument %d names the tool %q a second time", i+1, *raw.Name)
		}
		seen[*raw.Name] = true
		schema := raw.InputSchema
		if len(schema) == 0 || string(schema) == "null" {
			schema = json.RawMessage(`{"type":"object"}`)
		} else if !isObject(schema) {
			return nil, fmt.Errorf("argument %d: the input schema of %q is not an object", i+1, *raw.Name)
		}
		t := tool{Name: *raw.Name, InputSchema: schema}
		if raw.Description != nil {
			t.Description = *raw.Description
		}
		tools = append(tools, t)
	}
	return tools, nil
}

func isObject(raw json.RawMessage) bool {
	var m map[string]json.RawMessage
	return json.Unmarshal(raw, &m) == nil && m != nil
}

// request is one JSON-RPC message from the harness: a request when it has
// an id, a notification otherwise.
type request struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type content struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type callResult struct {
	Content []content `json:"content"`
	IsError bool      `json:"isError,omitempty"`
}

// source is where a stub's tools come from: the arguments it was given,
// or the driver's socket.
type source interface {
	// list answers `tools/list`.
	list() (any, *rpcError)
	// call answers a `tools/call`.
	call(params json.RawMessage) (callResult, *rpcError)
	// holds is true when a call waits on another process for its answer,
	// so each call is answered in its own goroutine.
	holds() bool
}

// given is the argument mode's source.
type given []tool

func (g given) list() (any, *rpcError) {
	return struct {
		Tools []tool `json:"tools"`
	}{g}, nil
}

func (g given) call(params json.RawMessage) (callResult, *rpcError) { return call(params, g) }

func (given) holds() bool { return false }

// serve answers the harness's messages from in on out until in closes,
// with the tools it was given.
func serve(in io.Reader, out io.Writer, tools []tool) error {
	return serveSource(in, out, given(tools))
}

// serveSource answers the harness's messages from in on out from src until
// in closes and every call in flight is answered.
func serveSource(in io.Reader, out io.Writer, src source) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 64<<10), maxLineBytes)
	writer := &replies{w: bufio.NewWriter(out)}
	var calls sync.WaitGroup
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			if err := writer.write(response{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &rpcError{Code: -32700, Message: "parse error"}}); err != nil {
				return err
			}
			continue
		}
		if len(req.ID) == 0 || string(req.ID) == "null" {
			continue
		}
		// req's members are copies, not views of the scanner's buffer,
		// so a call's goroutine may outlive this line.
		if req.Method == "tools/call" && src.holds() {
			calls.Add(1)
			go func() {
				defer calls.Done()
				_ = writer.write(respond(req, src))
			}()
			continue
		}
		if err := writer.write(respond(req, src)); err != nil {
			return err
		}
	}
	if err := scanner.Err(); err != nil {
		if errors.Is(err, bufio.ErrTooLong) {
			return fmt.Errorf("a message past %d bytes", maxLineBytes)
		}
		return err
	}
	calls.Wait()
	return writer.failed()
}

// replies writes one response a line, one at a time, keeping the first
// error: every later write fails with it.
type replies struct {
	mu  sync.Mutex
	w   *bufio.Writer
	err error
}

func (r *replies) write(reply response) error {
	encoded, err := json.Marshal(reply)
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.err != nil {
		return r.err
	}
	if err == nil {
		_, err = r.w.Write(append(encoded, '\n'))
	}
	if err == nil {
		err = r.w.Flush()
	}
	r.err = err
	return err
}

func (r *replies) failed() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.err
}

// respond is the response to one request.
func respond(req request, src source) response {
	reply := response{JSONRPC: "2.0", ID: req.ID}
	switch req.Method {
	case "initialize":
		reply.Result = initialized(req.Params)
	case "ping":
		reply.Result = struct{}{}
	case "tools/list":
		reply.Result, reply.Error = src.list()
	case "tools/call":
		result, err := src.call(req.Params)
		if err != nil {
			reply.Error = err
		} else {
			reply.Result = result
		}
	default:
		reply.Error = &rpcError{Code: -32601, Message: "method not found"}
	}
	return reply
}

// initialized answers `initialize` in the protocol version the harness
// asked for: the stub uses nothing any version changed.
func initialized(params json.RawMessage) any {
	var asked struct {
		ProtocolVersion string `json:"protocolVersion"`
	}
	_ = json.Unmarshal(params, &asked)
	version := asked.ProtocolVersion
	if version == "" {
		version = "2025-06-18"
	}
	return map[string]any{
		"protocolVersion": version,
		"capabilities":    map[string]any{"tools": map[string]any{}},
		"serverInfo":      map[string]any{"name": "cyfr", "version": "1"},
	}
}

// call answers a `tools/call` from the answer its arguments carry.
func call(params json.RawMessage, tools []tool) (callResult, *rpcError) {
	var p struct {
		Name      string                     `json:"name"`
		Arguments map[string]json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return callResult{}, &rpcError{Code: -32602, Message: "invalid params"}
	}
	known := false
	for _, t := range tools {
		if t.Name == p.Name {
			known = true
			break
		}
	}
	if !known {
		return callResult{}, &rpcError{Code: -32602, Message: "unknown tool"}
	}
	if raw, ok := p.Arguments["error"]; ok {
		return callResult{Content: []content{{Type: "text", Text: text(raw)}}, IsError: true}, nil
	}
	if raw, ok := p.Arguments["result"]; ok {
		return callResult{Content: []content{{Type: "text", Text: text(raw)}}}, nil
	}
	return callResult{Content: []content{{Type: "text", Text: ungated}}, IsError: true}, nil
}

// text is a JSON string's value, or any other JSON value as it is written.
func text(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return string(raw)
}

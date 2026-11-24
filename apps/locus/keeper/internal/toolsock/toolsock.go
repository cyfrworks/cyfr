// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Package toolsock is the socket through which a harness's MCP stdio
// server (cyfr-stub in socket mode) reaches the brain driver that holds
// CYFR's tools for the session: an abstract Unix socket, one fixed name,
// which lives in the network namespace of the space it was bound in. A
// space is one spawn of the backends service and its own network and IPC
// namespaces, so only the session's own processes reach its driver's
// socket, and two sessions of one home never reach each other's. The
// driver is its one listener.
//
// Each connection carries one request and its answer, one JSON object a
// line each way: `{"op":"list"}` is answered `{"tools":[…]}`, each tool
// `{name, description, inputSchema}` as MCP lists it, the tools the
// session's start named; `{"op":"call","name":…,"arguments":{…}}` is
// answered `{"text":…,"is_error":…}` once CYFR has answered the call,
// which the driver shows the holder as an ask and holds until then, with
// no clock of its own. A connection whose peer is not of the listener's
// own uid is closed unread.
package toolsock

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"

	"golang.org/x/sys/unix"
)

// Name is the socket's abstract name in every space.
const Name = "cyfr-tools"

// MaxLineBytes bounds one line each way: a call's arguments or its answer,
// at most a wire line, and room beyond.
const MaxLineBytes = 16 << 20

// Request is one request a connection carries.
type Request struct {
	Op        string          `json:"op"`
	Name      string          `json:"name,omitempty"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
}

// Tool is one tool as `tools/list` answers it.
type Tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

// Listing answers a list.
type Listing struct {
	Tools []Tool `json:"tools"`
}

// Result answers a call.
type Result struct {
	Text    string `json:"text"`
	IsError bool   `json:"is_error"`
}

func address(name string) *net.UnixAddr { return &net.UnixAddr{Name: "@" + name, Net: "unix"} }

// Listen binds the socket `name` in the caller's network namespace. A name
// another process holds there is an error: one listener a space.
func Listen(name string) (*net.UnixListener, error) {
	return net.ListenUnix("unix", address(name))
}

// Accept is the next connection of the listener's own uid; one of another
// uid is closed unread.
func Accept(l *net.UnixListener) (*net.UnixConn, error) {
	for {
		conn, err := l.AcceptUnix()
		if err != nil {
			return nil, err
		}
		if samePeer(conn) {
			return conn, nil
		}
		_ = conn.Close()
	}
}

func samePeer(conn *net.UnixConn) bool {
	raw, err := conn.SyscallConn()
	if err != nil {
		return false
	}
	var cred *unix.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil || credErr != nil || cred == nil {
		return false
	}
	return int(cred.Uid) == os.Getuid()
}

// ReadRequest reads a connection's one request.
func ReadRequest(conn net.Conn) (Request, error) {
	var r Request
	line, err := readLine(conn)
	if err != nil {
		return r, err
	}
	if err := json.Unmarshal(line, &r); err != nil {
		return r, fmt.Errorf("a request that does not read: %w", err)
	}
	switch {
	case r.Op == "list":
	case r.Op == "call" && r.Name != "":
	default:
		return r, errors.New("a request of no kind the socket takes")
	}
	return r, nil
}

// WriteAnswer writes a connection's one answer and closes it.
func WriteAnswer(conn net.Conn, answer any) error {
	defer conn.Close()
	line, err := json.Marshal(answer)
	if err != nil {
		return err
	}
	_, err = conn.Write(append(line, '\n'))
	return err
}

// Ask sends one request to the socket `name` and reads its answer into
// answer. It waits as long as the driver holds the request.
func Ask(name string, r Request, answer any) error {
	conn, err := net.DialUnix("unix", nil, address(name))
	if err != nil {
		return err
	}
	defer conn.Close()
	line, err := json.Marshal(r)
	if err != nil {
		return err
	}
	if _, err := conn.Write(append(line, '\n')); err != nil {
		return err
	}
	reply, err := readLine(conn)
	if err != nil {
		return err
	}
	return json.Unmarshal(reply, answer)
}

func readLine(conn net.Conn) ([]byte, error) {
	reader := bufio.NewReaderSize(conn, 64<<10)
	var line []byte
	for {
		chunk, err := reader.ReadSlice('\n')
		line = append(line, chunk...)
		if len(line) > MaxLineBytes+1 {
			return nil, errors.New("a line past the socket's bound")
		}
		switch {
		case err == nil:
			return line[:len(line)-1], nil
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		default:
			return nil, err
		}
	}
}

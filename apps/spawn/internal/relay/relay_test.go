// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package relay

import (
	"bytes"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/spawn/internal/frame"
)

const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

type backendPipes struct {
	// The relay's ends.
	stdinW, stdoutR, stderrR *os.File
	// The backend's ends.
	stdinR, stdoutW, stderrW *os.File
}

func newPipes(t *testing.T) backendPipes {
	t.Helper()
	var p backendPipes
	var err error
	if p.stdinR, p.stdinW, err = os.Pipe(); err != nil {
		t.Fatal(err)
	}
	if p.stdoutR, p.stdoutW, err = os.Pipe(); err != nil {
		t.Fatal(err)
	}
	if p.stderrR, p.stderrW, err = os.Pipe(); err != nil {
		t.Fatal(err)
	}
	return p
}

func listen(t *testing.T) (string, net.Listener) {
	t.Helper()
	dir, err := os.MkdirTemp("", "relay")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "a.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return path, ln
}

func TestRelayCarriesAllThreeStreams(t *testing.T) {
	path, ln := listen(t)
	p := newPipes(t)

	done := make(chan error, 1)
	go func() { done <- Run(Spec{Path: path, Token: token}, p.stdinW, p.stdoutR, p.stderrR, time.Second) }()

	conn, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	buf := make([]byte, frame.MaxPayload)

	stream, payload, err := frame.Read(conn, buf)
	if err != nil || stream != frame.StreamAttach || string(payload) != token {
		t.Fatalf("attach frame %d %q %v", stream, payload, err)
	}

	if err := frame.Write(conn, frame.StreamStdin, []byte("ping\n")); err != nil {
		t.Fatal(err)
	}
	if err := frame.Write(conn, frame.StreamStdin, nil); err != nil {
		t.Fatal(err)
	}
	in, err := io.ReadAll(p.stdinR)
	if err != nil || string(in) != "ping\n" {
		t.Fatalf("backend stdin %q %v", in, err)
	}

	if _, err := p.stdoutW.WriteString("pong\n"); err != nil {
		t.Fatal(err)
	}
	if _, err := p.stderrW.WriteString("log line\n"); err != nil {
		t.Fatal(err)
	}
	p.stdoutW.Close()
	p.stderrW.Close()

	got := map[byte]*bytes.Buffer{frame.StreamStdout: {}, frame.StreamStderr: {}}
	ended := map[byte]bool{}
	for len(ended) < 2 {
		stream, payload, err := frame.Read(conn, buf)
		if err != nil {
			t.Fatalf("reading relay output: %v", err)
		}
		if len(payload) == 0 {
			ended[stream] = true
			continue
		}
		got[stream].Write(payload)
	}
	if got[frame.StreamStdout].String() != "pong\n" || got[frame.StreamStderr].String() != "log line\n" {
		t.Fatalf("stdout %q stderr %q", got[frame.StreamStdout], got[frame.StreamStderr])
	}

	if err := <-done; err != nil {
		t.Fatalf("relay ended with %v", err)
	}
	if _, _, err := frame.Read(conn, buf); err != io.EOF {
		t.Fatalf("connection not closed after both outputs ended: %v", err)
	}
}

func TestRelayEndsWhenTheClientCloses(t *testing.T) {
	path, ln := listen(t)
	p := newPipes(t)
	defer p.stdoutW.Close()
	defer p.stderrW.Close()

	done := make(chan error, 1)
	go func() { done <- Run(Spec{Path: path, Token: token}, p.stdinW, p.stdoutR, p.stderrR, time.Second) }()

	conn, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := frame.Read(conn, make([]byte, frame.MaxPayload)); err != nil {
		t.Fatal(err)
	}
	conn.Close()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("relay ended with %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("relay outlived its client connection")
	}
	if n, err := p.stdinR.Read(make([]byte, 1)); n != 0 || err != io.EOF {
		t.Fatalf("backend stdin not closed: %d %v", n, err)
	}
}

func TestRelayRefusesOutputFramesFromTheClient(t *testing.T) {
	path, ln := listen(t)
	p := newPipes(t)
	defer p.stdoutW.Close()
	defer p.stderrW.Close()

	done := make(chan error, 1)
	go func() { done <- Run(Spec{Path: path, Token: token}, p.stdinW, p.stdoutR, p.stderrR, time.Second) }()

	conn, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, _, err := frame.Read(conn, make([]byte, frame.MaxPayload)); err != nil {
		t.Fatal(err)
	}
	if err := frame.Write(conn, frame.StreamStdout, []byte("x")); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "stdin") {
			t.Fatalf("relay ended with %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("relay accepted an output frame from the client")
	}
}

func TestRelayRefusesAnInvalidSpecAndClosesItsFiles(t *testing.T) {
	p := newPipes(t)
	err := Run(Spec{Path: "relative.sock", Token: token}, p.stdinW, p.stdoutR, p.stderrR, time.Second)
	if err == nil {
		t.Fatal("a relative attach path was accepted")
	}
	if _, err := p.stdoutR.Read(make([]byte, 1)); err == nil {
		t.Fatal("the relay's files were left open")
	}
}

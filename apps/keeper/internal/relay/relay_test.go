// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package relay

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/keeper/internal/frame"
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

// newControlPair makes the control channel's socketpair: the relay's end
// and the backend's, which a spawned command would hold as fd 3.
func newControlPair(t *testing.T) (relayEnd, backendEnd *net.UnixConn) {
	t.Helper()
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	var ends [2]*net.UnixConn
	for i, fd := range fds {
		f := os.NewFile(uintptr(fd), "control")
		conn, err := net.FileConn(f)
		_ = f.Close()
		if err != nil {
			t.Fatal(err)
		}
		ends[i] = conn.(*net.UnixConn)
	}
	t.Cleanup(func() { ends[0].Close(); ends[1].Close() })
	return ends[0], ends[1]
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

// session is a relay under test seen from the client: its connection past
// the attach frame, the backend's pipe ends and, with control, the
// backend's end of the channel.
type session struct {
	conn    net.Conn
	buf     []byte
	done    chan error
	p       backendPipes
	backend *net.UnixConn
	// relayBackend is the backend's end of its relay, which an isolated
	// spawn's command holds as fd 4.
	relayBackend *net.UnixConn
}

func start(t *testing.T, withControl bool) *session {
	t.Helper()
	return startWith(t, withControl, false)
}

// startWith is start for a spawn with a relay, as every spawn of an
// isolated pool has, when withRelay.
func startWith(t *testing.T, withControl, withRelay bool) *session {
	t.Helper()
	path, ln := listen(t)
	s := &session{buf: make([]byte, frame.MaxPayload), done: make(chan error, 1), p: newPipes(t)}
	var control, relay Control
	if withControl {
		var relayEnd *net.UnixConn
		relayEnd, s.backend = newControlPair(t)
		control = relayEnd
	}
	if withRelay {
		var relayEnd *net.UnixConn
		relayEnd, s.relayBackend = newControlPair(t)
		relay = relayEnd
	}
	spec := Spec{Path: path, Token: token, Control: withControl, Relay: withRelay}
	go func() { s.done <- Run(spec, s.p.stdinW, s.p.stdoutR, s.p.stderrR, control, relay, time.Second) }()
	conn, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	s.conn = conn
	stream, payload, err := frame.Read(conn, s.buf)
	if err != nil || stream != frame.StreamAttach || string(payload) != token {
		t.Fatalf("attach frame %d %q %v", stream, payload, err)
	}
	return s
}

// next reads frames until one on stream arrives and returns its payload;
// io.EOF ends the wait with ok false.
func (s *session) next(t *testing.T, stream byte) ([]byte, bool) {
	t.Helper()
	for {
		got, payload, err := frame.Read(s.conn, s.buf)
		if errors.Is(err, io.EOF) {
			return nil, false
		}
		if err != nil {
			t.Fatalf("reading relay output: %v", err)
		}
		if got == stream {
			return bytes.Clone(payload), true
		}
	}
}

func (s *session) result(t *testing.T) error {
	t.Helper()
	select {
	case err := <-s.done:
		return err
	case <-time.After(5 * time.Second):
		t.Fatal("the relay did not end")
		return nil
	}
}

func TestRelayCarriesAllThreeStreams(t *testing.T) {
	s := start(t, false)
	p := s.p

	if err := frame.Write(s.conn, frame.StreamStdin, []byte("ping\n")); err != nil {
		t.Fatal(err)
	}
	if err := frame.Write(s.conn, frame.StreamStdin, nil); err != nil {
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
		stream, payload, err := frame.Read(s.conn, s.buf)
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

	if err := s.result(t); err != nil {
		t.Fatalf("relay ended with %v", err)
	}
	if _, _, err := frame.Read(s.conn, s.buf); err != io.EOF {
		t.Fatalf("connection not closed after both outputs ended: %v", err)
	}
}

func TestRelayEndsWhenTheClientCloses(t *testing.T) {
	s := start(t, false)
	defer s.p.stdoutW.Close()
	defer s.p.stderrW.Close()
	s.conn.Close()

	if err := s.result(t); err != nil {
		t.Fatalf("relay ended with %v", err)
	}
	if n, err := s.p.stdinR.Read(make([]byte, 1)); n != 0 || err != io.EOF {
		t.Fatalf("backend stdin not closed: %d %v", n, err)
	}
}

func TestRelayRefusesOutputFramesFromTheClient(t *testing.T) {
	s := start(t, false)
	defer s.p.stdoutW.Close()
	defer s.p.stderrW.Close()
	if err := frame.Write(s.conn, frame.StreamStdout, []byte("x")); err != nil {
		t.Fatal(err)
	}
	if err := s.result(t); err == nil || !strings.Contains(err.Error(), "stdin") {
		t.Fatalf("relay ended with %v", err)
	}
}

func TestRelayRefusesAnInvalidSpecAndClosesItsFiles(t *testing.T) {
	p := newPipes(t)
	relayEnd, backendEnd := newControlPair(t)
	err := Run(Spec{Path: "relative.sock", Token: token, Control: true}, p.stdinW, p.stdoutR, p.stderrR, relayEnd, nil, time.Second)
	if err == nil {
		t.Fatal("a relative attach path was accepted")
	}
	if _, err := p.stdoutR.Read(make([]byte, 1)); err == nil {
		t.Fatal("the relay's files were left open")
	}
	if _, err := backendEnd.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("the relay's end of the control channel was left open: %v", err)
	}
}

func TestRelayCarriesTheControlChannelBothWays(t *testing.T) {
	s := start(t, true)
	defer s.p.stdoutW.Close()
	defer s.p.stderrW.Close()

	// Client to backend: the bytes arrive on the backend's end verbatim,
	// two frames as one stream.
	for _, chunk := range []string{`{"v":1,"type":"assign"`, `}` + "\n"} {
		if err := frame.Write(s.conn, frame.StreamControl, []byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}
	got := make([]byte, 64)
	n, err := io.ReadAtLeast(s.backend, got, len(`{"v":1,"type":"assign"}`)+1)
	if err != nil || string(got[:n]) != `{"v":1,"type":"assign"}`+"\n" {
		t.Fatalf("backend read %q %v", got[:n], err)
	}

	// Backend to client: a control frame, then the end once the backend
	// closes its end while its stdio stays open.
	if _, err := s.backend.Write([]byte(`{"v":1,"type":"complete"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	if payload, ok := s.next(t, frame.StreamControl); !ok || string(payload) != `{"v":1,"type":"complete"}`+"\n" {
		t.Fatalf("control frame %q %v", payload, ok)
	}
	s.backend.Close()
	if payload, ok := s.next(t, frame.StreamControl); !ok || len(payload) != 0 {
		t.Fatalf("after the backend closed its end: %q %v", payload, ok)
	}
	select {
	case err := <-s.done:
		t.Fatalf("the relay ended with stdio open: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestRelayEndsOnlyOnceTheControlChannelHasEnded(t *testing.T) {
	s := start(t, true)
	s.p.stdoutW.Close()
	s.p.stderrW.Close()
	// The two stdio streams end in either order.
	ended := map[byte]bool{}
	for len(ended) < 2 {
		stream, payload, err := frame.Read(s.conn, s.buf)
		if err != nil || len(payload) != 0 || (stream != frame.StreamStdout && stream != frame.StreamStderr) {
			t.Fatalf("stdio did not end: stream %d %q %v", stream, payload, err)
		}
		ended[stream] = true
	}
	select {
	case err := <-s.done:
		t.Fatalf("the relay ended with the control channel open: %v", err)
	case <-time.After(200 * time.Millisecond):
	}

	s.backend.Close()
	if payload, ok := s.next(t, frame.StreamControl); !ok || len(payload) != 0 {
		t.Fatalf("control stream did not end: %q %v", payload, ok)
	}
	if err := s.result(t); err != nil {
		t.Fatalf("relay ended with %v", err)
	}
	if _, _, err := frame.Read(s.conn, s.buf); err != io.EOF {
		t.Fatalf("connection not closed after every output ended: %v", err)
	}
}

func TestRelayClosesTheBackendsControlInputOnTheClientsEndFrame(t *testing.T) {
	s := start(t, true)
	defer s.p.stdoutW.Close()
	defer s.p.stderrW.Close()

	if err := frame.Write(s.conn, frame.StreamControl, nil); err != nil {
		t.Fatal(err)
	}
	if n, err := s.backend.Read(make([]byte, 1)); n != 0 || err != io.EOF {
		t.Fatalf("the backend's reading side stayed open: %d %v", n, err)
	}
	// The backend still writes, and a client frame after the end is dropped.
	if err := frame.Write(s.conn, frame.StreamControl, []byte("late")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.backend.Write([]byte("still here\n")); err != nil {
		t.Fatal(err)
	}
	if payload, ok := s.next(t, frame.StreamControl); !ok || string(payload) != "still here\n" {
		t.Fatalf("control frame %q %v", payload, ok)
	}
	select {
	case err := <-s.done:
		t.Fatalf("the relay ended: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestRelayRefusesAControlFrameWithoutAControlChannel(t *testing.T) {
	s := start(t, false)
	defer s.p.stdoutW.Close()
	defer s.p.stderrW.Close()
	if err := frame.Write(s.conn, frame.StreamControl, []byte("x")); err != nil {
		t.Fatal(err)
	}
	if err := s.result(t); !errors.Is(err, errProtocol) {
		t.Fatalf("relay ended with %v", err)
	}
}

func TestRelayEndsOnAnOversizeControlFrame(t *testing.T) {
	s := start(t, true)
	defer s.p.stdoutW.Close()
	defer s.p.stderrW.Close()
	header := []byte{frame.StreamControl, 0, 1, 0, 1}
	if _, err := s.conn.Write(header); err != nil {
		t.Fatal(err)
	}
	if err := s.result(t); !errors.Is(err, frame.ErrTooLarge) {
		t.Fatalf("relay ended with %v", err)
	}
	if n, err := s.backend.Read(make([]byte, 1)); n != 0 || err != io.EOF {
		t.Fatalf("the backend's end was not closed with the relay: %d %v", n, err)
	}
}

// relayStreamVector is one of the shared vectors' relay_streams cases.
type relayStreamVector struct {
	Why             string `json:"why"`
	BackendWrites   string `json:"backend_writes_hex"`
	ClientOpens     bool   `json:"client_opens"`
	Ended           []int  `json:"ended_streams"`
	RelayPayloadHex string `json:"relay_payload_hex"`
}

func relayStreamVectors(t *testing.T) map[string]relayStreamVector {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "keeper_protocol.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		RelayStreams map[string]relayStreamVector `json:"relay_streams"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	if len(v.RelayStreams) != 2 {
		t.Fatalf("relay_streams holds %d cases, want unused and opened", len(v.RelayStreams))
	}
	return v.RelayStreams
}

// The shared vectors' relay rule: a spawn with a relay whose command
// writes to it and exits sends nothing on the relay stream, its end frame
// included, unless the client opened the stream, and then carries what
// the command wrote and ends the stream.
func TestTheRelayStreamIsSilentUntilTheClientOpensIt(t *testing.T) {
	for name, c := range relayStreamVectors(t) {
		s := startWith(t, true, true)
		writes, _ := hex.DecodeString(c.BackendWrites)
		want, _ := hex.DecodeString(c.RelayPayloadHex)
		// The command writes a relay frame to fd 4, then exits: every one
		// of its ends closes. With the stream opened, it exits once what it
		// wrote has arrived, so the exit does not race the opening frame.
		exit := func() {
			s.relayBackend.Close()
			s.backend.Close()
			s.p.stdoutW.Close()
			s.p.stderrW.Close()
		}
		if c.ClientOpens {
			if err := frame.Write(s.conn, frame.StreamRelay, nil); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := s.relayBackend.Write(writes); err != nil {
			t.Fatal(err)
		}
		exited := !c.ClientOpens
		if exited {
			exit()
		}

		got := map[byte][]byte{}
		var ended []int
		for {
			if !exited && bytes.Equal(got[frame.StreamRelay], want) {
				exit()
				exited = true
			}
			stream, payload, err := frame.Read(s.conn, s.buf)
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				t.Fatalf("%s: reading the relay: %v", name, err)
			}
			if len(payload) == 0 {
				ended = append(ended, int(stream))
				continue
			}
			got[stream] = append(got[stream], payload...)
		}
		if err := s.result(t); err != nil {
			t.Fatalf("%s: the relay ended with %v", name, err)
		}
		slices.Sort(ended)
		if !slices.Equal(ended, c.Ended) || !bytes.Equal(got[frame.StreamRelay], want) {
			t.Errorf("%s (%s): ended %v, relay stream %x; want ended %v, relay stream %x", name, c.Why, ended, got[frame.StreamRelay], c.Ended, want)
		}
		if _, sent := got[frame.StreamRelay]; !c.ClientOpens && sent {
			t.Errorf("%s: a frame on the unopened relay stream", name)
		}
	}
}

// Once open, the relay stream carries the client's bytes to the command's
// fd 4 and a zero-length client frame closes the command's reading side,
// while what the command writes still arrives.
func TestTheOpenedRelayStreamCarriesBothWays(t *testing.T) {
	s := startWith(t, true, true)
	defer s.p.stdoutW.Close()
	defer s.p.stderrW.Close()
	if err := frame.Write(s.conn, frame.StreamRelay, []byte("answer")); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 16)
	if n, err := io.ReadAtLeast(s.relayBackend, got, len("answer")); err != nil || string(got[:n]) != "answer" {
		t.Fatalf("the command read %q %v", got[:n], err)
	}
	if err := frame.Write(s.conn, frame.StreamRelay, nil); err != nil {
		t.Fatal(err)
	}
	if n, err := s.relayBackend.Read(got); n != 0 || err != io.EOF {
		t.Fatalf("the command's reading side stayed open: %d %v", n, err)
	}
	if _, err := s.relayBackend.Write([]byte("call")); err != nil {
		t.Fatal(err)
	}
	if payload, ok := s.next(t, frame.StreamRelay); !ok || string(payload) != "call" {
		t.Fatalf("relay frame %q %v", payload, ok)
	}
}

func TestRelayRefusesARelayFrameWithoutARelay(t *testing.T) {
	s := start(t, true)
	defer s.p.stdoutW.Close()
	defer s.p.stderrW.Close()
	if err := frame.Write(s.conn, frame.StreamRelay, nil); err != nil {
		t.Fatal(err)
	}
	if err := s.result(t); !errors.Is(err, errProtocol) {
		t.Fatalf("relay ended with %v", err)
	}
}

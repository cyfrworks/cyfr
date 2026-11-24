// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type processVectors struct {
	Version  int `json:"version"`
	GoToMain []struct {
		Name    string         `json:"name"`
		Message map[string]any `json:"message"`
	} `json:"go_to_main"`
	MainToGo []struct {
		Name    string          `json:"name"`
		Message json.RawMessage `json:"message"`
	} `json:"main_to_go"`
	Refused []struct {
		Name   string `json:"name"`
		To     string `json:"to"`
		Line   string `json:"line"`
		Reason string `json:"reason"`
	} `json:"refused"`
}

func readProcessVectors(t *testing.T) processVectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "desktop-process.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v processVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if v.Version != Version {
		t.Fatalf("the vectors are version %d; cyfr speaks %d", v.Version, Version)
	}
	return v
}

func str(o map[string]any, k string) string { s, _ := o[k].(string); return s }

// Each message cyfr sends is written exactly as the vector spells it.
func TestCyfrWritesEachMessageAsPinned(t *testing.T) {
	for _, c := range readProcessVectors(t).GoToMain {
		t.Run(c.Name, func(t *testing.T) {
			o := c.Message
			attempt, _ := o["attempt"].(float64)
			id, _ := o["id"].(float64)
			m := Message{Type: str(o, "type"), Attempt: uint64(attempt), ID: uint64(id), URL: str(o, "url"), Home: str(o, "home"), Account: str(o, "account"),
				Rail: str(o, "rail"), Update: str(o, "update"), Record: o["record"] == true, Proxy: str(o, "proxy"), Resolver: str(o, "resolver"),
				Setup: str(o, "setup")}
			read, write := io.Pipe()
			t.Cleanup(func() { read.Close() })
			if err := NewWriter(write, nil).Queue(m); err != nil {
				t.Fatal(err)
			}
			line, err := bufio.NewReader(read).ReadString('\n')
			if err != nil {
				t.Fatal(err)
			}
			if strings.Count(line, "\n") != 1 || !strings.HasSuffix(line, "\n") {
				t.Fatalf("not one line: %q", line)
			}
			var got map[string]any
			if err := json.Unmarshal([]byte(line), &got); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, o) {
				t.Fatalf("wrote %v; the vector is %v", got, o)
			}
		})
	}
}

// Each message main sends is read with its fields, and nothing else.
func TestCyfrReadsEachMessageFromMain(t *testing.T) {
	for _, c := range readProcessVectors(t).MainToGo {
		t.Run(c.Name, func(t *testing.T) {
			m, err := ReadFromMain(c.Message)
			if err != nil {
				t.Fatal(err)
			}
			var o map[string]any
			_ = json.Unmarshal(c.Message, &o)
			attempt, _ := o["attempt"].(float64)
			id, _ := o["id"].(float64)
			ok, _ := o["ok"].(bool)
			offer, _ := o["offer"].(float64)
			if m.Type != o["type"] || m.Home != str(o, "home") || m.Attempt != uint64(attempt) || m.ID != uint64(id) || m.OK != ok ||
				m.Offer != uint64(offer) {
				t.Fatalf("read %+v from %s", m, c.Message)
			}
			path, has := o["path"]
			switch {
			case has && path == nil && m.Path != nil:
				t.Fatalf("a cancelled pick read as %q", *m.Path)
			case has && path != nil && (m.Path == nil || *m.Path != path):
				t.Fatalf("the folder read as %v", m.Path)
			}
		})
	}
}

func TestCyfrRefusesEachRefusedLine(t *testing.T) {
	read := 0
	for _, c := range readProcessVectors(t).Refused {
		if c.To != "go" {
			continue
		}
		read++
		t.Run(c.Name, func(t *testing.T) {
			_, err := ReadFromMain([]byte(c.Line))
			var r *Refusal
			if !errors.As(err, &r) || r.Reason != c.Reason {
				t.Fatalf("got %v; want refused for %s", err, c.Reason)
			}
		})
	}
	if read == 0 {
		t.Fatal("no refusal addressed to cyfr")
	}
	if _, err := ReadFromMain(bytes.Repeat([]byte(" "), MaxLine+1)); !errors.Is(err, ErrRefused) {
		t.Fatalf("a line past the bound was read: %v", err)
	}
}

// cyfr sends only its own messages, each whole.
func TestCyfrSendsNothingMainSends(t *testing.T) {
	for _, typ := range append([]string{"unlock"}, fromMain...) {
		if err := NewWriter(io.Discard, nil).Queue(Message{Type: typ, Home: "https://x"}); err == nil {
			t.Errorf("sent %s", typ)
		}
	}
	if err := NewWriter(io.Discard, nil).Queue(Message{Type: TypeHome, Home: "https://x", Account: "https://y"}); err == nil {
		t.Error("sent home without its attempt")
	}
	if err := NewWriter(io.Discard, nil).Queue(Message{Type: TypeHome, Home: "https://x", Attempt: 1}); err == nil {
		t.Error("sent home without its account service")
	}
}

// The writer keeps the order its lines were given in, and Queue returns
// while main reads nothing.
func TestWriter_QueueWaitsOnNoPeerAndKeepsTheOrder(t *testing.T) {
	read, write := io.Pipe()
	to := NewWriter(write, nil)
	// The writer holds this line, which main does not read.
	_ = to.Queue(Message{Type: TypeReady, URL: "http://127.0.0.1:7340/"})
	queued := make(chan struct{})
	go func() {
		defer close(queued)
		for range 3 {
			_ = to.Queue(Message{Type: TypeLocked})
		}
	}()
	select {
	case <-queued:
	case <-time.After(2 * time.Second):
		t.Fatal("Queue waited for main to read")
	}
	_ = to.Queue(Message{Type: TypeOpened, Home: "https://x.example", Attempt: 1})
	lines := bufio.NewScanner(read)
	var types []string
	for len(types) < 5 && lines.Scan() {
		var m map[string]any
		if err := json.Unmarshal(lines.Bytes(), &m); err != nil {
			t.Fatal(err)
		}
		types = append(types, m["type"].(string))
	}
	if strings.Join(types, " ") != "ready locked locked locked opened" {
		t.Fatalf("main read %v", types)
	}
}

// TestWriterHelper writes to its standard output after main closed it,
// for TestWriter_AClosedPipeIsAnErrorNotTheEnd.
func TestWriterHelper(t *testing.T) {
	if os.Getenv("CYFR_WRITER_HELPER") == "" {
		t.Skip("run by TestWriter_AClosedPipeIsAnErrorNotTheEnd")
	}
	to := NewWriter(os.Stdout, nil)
	// sleep-ok: the parent closes its end of the pipe meanwhile
	time.Sleep(500 * time.Millisecond)
	_ = to.Queue(Message{Type: TypeLocked})
	// The write fails on the closed pipe; with SIGPIPE taken it ends this
	// process first.
	_, err := os.Stdout.Write([]byte("\n"))
	fmt.Fprintf(os.Stderr, "written: %v\n", err)
	// What the test binary reports after this test (its coverage, under
	// -cover) goes where the parent reads, not to the pipe it closed.
	os.Stdout = os.Stderr
}

// A write to a pipe main closed is an error the process lives on after,
// never a SIGPIPE that ends it before a lock ends its sessions.
func TestWriter_AClosedPipeIsAnErrorNotTheEnd(t *testing.T) {
	helper := exec.Command(os.Args[0], "-test.run=^TestWriterHelper$")
	helper.Env = append(os.Environ(), "CYFR_WRITER_HELPER=1")
	out, err := helper.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var said strings.Builder
	helper.Stderr = &said
	if err := helper.Start(); err != nil {
		t.Fatal(err)
	}
	out.Close()
	err = helper.Wait()
	if err != nil || !strings.Contains(said.String(), "written: ") || strings.Contains(said.String(), "written: <nil>") {
		t.Fatalf("the helper ended with %v, saying:\n%s", err, said.String())
	}
}

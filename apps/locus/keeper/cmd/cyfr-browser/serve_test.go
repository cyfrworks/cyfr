// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"io"
	"os"
	"testing"
	"time"
)

// fakeChrome answers the commands of one open and one read over a pipe
// pair, as Chrome does over its debugging pipe. A navigation to
// unreachableURL fails as Chrome's does, and each target closed is told on
// closes when it is given.
func fakeChrome(commands io.Reader, answers io.Writer, closes chan<- string) {
	in := bufio.NewReader(commands)
	address := "about:blank"
	write := func(message map[string]any) {
		data, _ := json.Marshal(message)
		_, _ = answers.Write(append(data, 0))
	}
	for {
		data, err := in.ReadBytes(0)
		if err != nil {
			return
		}
		var m struct {
			ID        int64           `json:"id"`
			Method    string          `json:"method"`
			Params    json.RawMessage `json:"params"`
			SessionID string          `json:"sessionId"`
		}
		_ = json.Unmarshal(data[:len(data)-1], &m)
		reply := func(result any) {
			message := map[string]any{"id": m.ID, "result": result}
			if m.SessionID != "" {
				message["sessionId"] = m.SessionID
			}
			write(message)
		}
		load := func(loader string) {
			write(map[string]any{"method": "Page.lifecycleEvent", "sessionId": "S1",
				"params": map[string]any{"frameId": "T1", "loaderId": loader, "name": "load"}})
		}
		switch m.Method {
		case "Target.createTarget":
			reply(map[string]any{"targetId": "T1"})
		case "Target.attachToTarget":
			reply(map[string]any{"sessionId": "S1"})
		case "Page.enable", "Page.setLifecycleEventsEnabled", "Emulation.setFocusEmulationEnabled":
			reply(map[string]any{})
		case "Page.getFrameTree":
			reply(map[string]any{"frameTree": map[string]any{"frame": map[string]any{"id": "T1"}}})
		case "Target.closeTarget":
			var p struct {
				TargetID string `json:"targetId"`
			}
			_ = json.Unmarshal(m.Params, &p)
			reply(map[string]any{"success": true})
			if closes != nil {
				closes <- p.TargetID
			}
		case "Page.navigate":
			var p struct {
				URL string `json:"url"`
			}
			_ = json.Unmarshal(m.Params, &p)
			if p.URL == unreachableURL {
				reply(map[string]any{"frameId": "T1", "loaderId": "L3", "errorText": "net::ERR_ADDRESS_UNREACHABLE"})
				continue
			}
			address = p.URL
			reply(map[string]any{"frameId": "T1", "loaderId": "L2"})
			load("L1")
			load("L2")
		case "Page.getNavigationHistory":
			reply(map[string]any{"currentIndex": 0, "entries": []any{map[string]any{"url": address, "title": "Example"}}})
		case "Accessibility.getFullAXTree":
			reply(map[string]any{"nodes": []any{
				map[string]any{"nodeId": "1", "ignored": false, "role": map[string]any{"value": "RootWebArea"},
					"name": map[string]any{"value": "Example"}, "childIds": []string{"2", "9"}, "backendDOMNodeId": 1},
				map[string]any{"nodeId": "2", "ignored": false, "role": map[string]any{"value": "generic"},
					"name": map[string]any{"value": ""}, "childIds": []string{"3", "4", "5"}, "parentId": "1"},
				map[string]any{"nodeId": "3", "ignored": false, "role": map[string]any{"value": "heading"},
					"name": map[string]any{"value": "Hello"}, "childIds": []string{"6"}, "parentId": "2", "backendDOMNodeId": 8},
				map[string]any{"nodeId": "4", "ignored": false, "role": map[string]any{"value": "button"},
					"name": map[string]any{"value": "Go"}, "parentId": "2", "backendDOMNodeId": 12},
				map[string]any{"nodeId": "5", "ignored": false, "role": map[string]any{"value": "textbox"},
					"name": map[string]any{"value": "Name"}, "value": map[string]any{"type": "string", "value": "v"},
					"parentId": "2", "backendDOMNodeId": 13},
				map[string]any{"nodeId": "6", "ignored": false, "role": map[string]any{"value": "StaticText"},
					"name": map[string]any{"value": "Hello"}, "childIds": []string{"7"}, "parentId": "3", "backendDOMNodeId": 23},
				map[string]any{"nodeId": "7", "ignored": false, "role": map[string]any{"value": "InlineTextBox"},
					"name": map[string]any{"value": "Hello"}, "parentId": "6"},
				map[string]any{"nodeId": "9", "ignored": true, "role": map[string]any{"value": "none"},
					"childIds": []string{"10"}, "parentId": "1"},
				map[string]any{"nodeId": "10", "ignored": false, "role": map[string]any{"value": "link"},
					"name": map[string]any{"value": "More"}, "parentId": "9", "backendDOMNodeId": 30},
			}})
		default:
			write(map[string]any{"id": m.ID, "error": map[string]any{"code": -32601, "message": m.Method + " wasn't found"}})
		}
	}
}

// host is the test's side of the driver's session: it sends requests and
// takes each response whole, acknowledging every chunk.
type host struct {
	t   *testing.T
	in  io.Writer
	out *bufio.Reader
	r   reader
}

func (h *host) send(message any) {
	h.t.Helper()
	if _, err := h.in.Write(encode(must(json.Marshal(message)))); err != nil {
		h.t.Fatal(err)
	}
}

func (h *host) response(id int64) map[string]any {
	h.t.Helper()
	var text []byte
	buf := make([]byte, 4096)
	for {
		n, err := h.out.Read(buf)
		if err != nil {
			h.t.Fatalf("the driver's output ended: %v", err)
		}
		for _, body := range h.r.feed(buf[:n]) {
			var m resMessage
			if err := json.Unmarshal(body, &m); err != nil || m.T != "res" || m.ID != id || m.Seq != len(text)/9 {
				h.t.Fatalf("a frame out of turn: %s", body)
			}
			text = append(text, must(base64.StdEncoding.DecodeString(m.Part))...)
			h.send(map[string]any{"t": "ack", "id": id, "seq": m.Seq})
			if m.Seq == m.Of-1 {
				var answer map[string]any
				if err := json.Unmarshal(text, &answer); err != nil {
					h.t.Fatalf("a response of no JSON: %s", text)
				}
				return answer
			}
		}
	}
}

const unreachableURL = "https://unreachable.test/"

func TestOpenAndReadOverFakeChrome(t *testing.T) {
	commandsIn, commandsOut := io.Pipe()
	answersIn, answersOut := io.Pipe()
	go fakeChrome(commandsIn, answersOut, nil)
	b := newBrowser()
	b.c = newCDP(commandsOut, answersIn, b.onTarget)

	hostIn, driverOut := io.Pipe()
	driverIn, hostOut := io.Pipe()
	s := newSlot(driverOut, 9, time.Minute)
	served := make(chan error, 1)
	go func() { served <- serve(driverIn, s, b, nil, make(chan os.Signal)) }()
	h := &host{t: t, in: hostOut, out: bufio.NewReader(hostIn), r: reader{max: maxToHost}}

	h.send(map[string]any{"t": "req", "id": 1, "win": "thr_01", "op": "read", "args": map[string]any{}})
	if got := h.response(1); !jsonEqual(got, `{"error":{"code":"no_window","message":"There is no browser window for this thread; open a page first."}}`) {
		t.Fatalf("a read before any open answered %v", got)
	}
	h.send(map[string]any{"t": "req", "id": 2, "win": "thr_01", "op": "open", "args": map[string]any{"url": "https://example.com/"}})
	if got := h.response(2); !jsonEqual(got, `{"ok":{"url":"https://example.com/","title":"Example"}}`) {
		t.Fatalf("an open answered %v", got)
	}
	h.send(map[string]any{"t": "req", "id": 3, "win": "thr_01", "op": "read", "args": map[string]any{}})
	want := "RootWebArea \"Example\"\n  heading \"Hello\"\n    StaticText \"Hello\"\n  [12] button \"Go\"\n" +
		"  [13] textbox \"Name\" = \"v\"\n  [30] link \"More\"\n"
	if got := h.response(3); !jsonEqual(got, string(must(json.Marshal(map[string]any{"ok": map[string]any{
		"url": "https://example.com/", "title": "Example", "text": want}})))) {
		t.Fatalf("a read answered %v, want the text %q", got, want)
	}
	h.send(map[string]any{"t": "req", "id": 4, "win": "thr_01", "op": "open", "args": map[string]any{"url": "file:///etc/passwd"}})
	if got := h.response(4); !jsonEqual(got, `{"error":{"code":"bad_url","message":"Only http and https addresses open in the browser."}}`) {
		t.Fatalf("an open of a file answered %v", got)
	}
	hostOut.Close()
	if err := <-served; err != nil {
		t.Fatalf("serve ended with %v when its input ended", err)
	}
}

// An open that fails in a window it made leaves no window: the window is
// closed before the failure is answered, so the host, which counts the
// windows that showed a page, counts every window that stands.
func TestFailedOpenLeavesNoWindow(t *testing.T) {
	commandsIn, commandsOut := io.Pipe()
	answersIn, answersOut := io.Pipe()
	closes := make(chan string, 4)
	go fakeChrome(commandsIn, answersOut, closes)
	b := newBrowser()
	b.c = newCDP(commandsOut, answersIn, b.onTarget)

	hostIn, driverOut := io.Pipe()
	driverIn, hostOut := io.Pipe()
	s := newSlot(driverOut, 9, time.Minute)
	served := make(chan error, 1)
	go func() { served <- serve(driverIn, s, b, nil, make(chan os.Signal)) }()
	h := &host{t: t, in: hostOut, out: bufio.NewReader(hostIn), r: reader{max: maxToHost}}

	h.send(map[string]any{"t": "req", "id": 1, "win": "thr_01", "op": "open", "args": map[string]any{"url": unreachableURL}})
	if got := h.response(1); !jsonEqual(got, `{"error":{"code":"unreachable","message":"The page could not be loaded (net::ERR_ADDRESS_UNREACHABLE)."}}`) {
		t.Fatalf("a failed open answered %v", got)
	}
	select {
	case target := <-closes:
		if target != "T1" {
			t.Fatalf("the failed open closed %q, not its own window", target)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the window a failed open made was not closed")
	}
	b.mu.Lock()
	left := len(b.windows)
	b.mu.Unlock()
	if left != 0 {
		t.Fatalf("a failed open left %d windows", left)
	}
	h.send(map[string]any{"t": "req", "id": 2, "win": "thr_01", "op": "read", "args": map[string]any{}})
	if got := h.response(2); !jsonEqual(got, `{"error":{"code":"no_window","message":"There is no browser window for this thread; open a page first."}}`) {
		t.Fatalf("a read after a failed open answered %v", got)
	}

	// A failure in a window that already showed a page leaves it standing.
	h.send(map[string]any{"t": "req", "id": 3, "win": "thr_01", "op": "open", "args": map[string]any{"url": "https://example.com/"}})
	if got := h.response(3); !jsonEqual(got, `{"ok":{"url":"https://example.com/","title":"Example"}}`) {
		t.Fatalf("an open answered %v", got)
	}
	h.send(map[string]any{"t": "req", "id": 4, "win": "thr_01", "op": "open", "args": map[string]any{"url": unreachableURL}})
	if got := h.response(4); got["error"] == nil {
		t.Fatalf("a failed open in a standing window answered %v", got)
	}
	select {
	case target := <-closes:
		t.Fatalf("a failed open closed the window %q that already showed a page", target)
	case <-time.After(200 * time.Millisecond):
	}
	hostOut.Close()
	if err := <-served; err != nil {
		t.Fatalf("serve ended with %v when its input ended", err)
	}
}

func jsonEqual(got map[string]any, want string) bool {
	return string(must(json.Marshal(got))) == string(must(json.Marshal(must(decodeObject(want)))))
}

func decodeObject(text string) (map[string]any, error) {
	var value map[string]any
	return value, json.Unmarshal([]byte(text), &value)
}

// Chrome's temporary folder is made in its home, and a dead Chrome's lock
// folders there are removed; anything else in it is kept.
func TestChromeTempIsMadeAndClearedOfADeadChromesLocks(t *testing.T) {
	home := t.TempDir()
	if err := chromeTemp(home); err != nil {
		t.Fatal(err)
	}
	dir := home + "/" + chromeTmp
	stale := dir + "/org.chromium.Chromium.ZcmaaZ"
	if err := os.MkdirAll(stale, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stale+"/SingletonSocket", nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dir+"/kept", []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := chromeTemp(home); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatalf("a dead Chrome's lock folder was left: %v", err)
	}
	if _, err := os.Stat(dir + "/kept"); err != nil {
		t.Fatalf("a file of the home's temporary folder was removed: %v", err)
	}
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// castChrome is a Chrome over a pipe pair whose windows each animate: a
// window being cast makes a new frame whenever fewer than two it sent are
// unacknowledged, as Chrome's screencast does, so a frame comes only as
// fast as the driver acknowledges them. Each target is T<n> on session
// S<n>. A navigation waits on hold when it is set, so a test can keep a
// request in its window.
type castChrome struct {
	mu sync.Mutex
	w  io.Writer
	// size gives a frame's base64 length at a quality.
	size    func(quality int) int
	targets int
	casting map[string]*screencast
	inputs  []string
	casts   []string
	stops   []string
	order   []string
	// stopWait delays the answer to a stop.
	stopWait time.Duration
	hold     chan struct{}
	closedCh chan string
}

type screencast struct {
	quality, width, height int
	inFlight               int
	next                   int64
}

func newCastChrome(commands io.Reader, answers io.Writer) *castChrome {
	f := &castChrome{w: answers, size: func(int) int { return 64 }, casting: map[string]*screencast{},
		closedCh: make(chan string, 8)}
	go f.serve(commands)
	return f
}

func (f *castChrome) write(message map[string]any) {
	data, _ := json.Marshal(message)
	f.mu.Lock()
	defer f.mu.Unlock()
	_, _ = f.w.Write(append(data, 0))
}

// frame sends session's next frame when it may: a cast under two frames
// unacknowledged.
func (f *castChrome) frame(session string) {
	f.mu.Lock()
	sc := f.casting[session]
	if sc == nil || sc.inFlight >= 2 {
		f.mu.Unlock()
		return
	}
	sc.inFlight++
	sc.next++
	n, data := sc.next, strings.Repeat("A", f.size(sc.quality))
	f.mu.Unlock()
	f.write(map[string]any{"method": "Page.screencastFrame", "sessionId": session, "params": map[string]any{
		"data": data, "sessionId": n,
		"metadata": map[string]any{"deviceWidth": 1280, "deviceHeight": 900},
	}})
}

func (f *castChrome) serve(commands io.Reader) {
	in := bufio.NewReader(commands)
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
			f.write(message)
		}
		switch m.Method {
		case "Target.createTarget":
			f.mu.Lock()
			f.targets++
			n := f.targets
			f.mu.Unlock()
			reply(map[string]any{"targetId": fmt.Sprintf("T%d", n)})
		case "Target.attachToTarget":
			var p struct {
				TargetID string `json:"targetId"`
			}
			_ = json.Unmarshal(m.Params, &p)
			reply(map[string]any{"sessionId": "S" + strings.TrimPrefix(p.TargetID, "T")})
		case "Page.enable", "Page.setLifecycleEventsEnabled":
			reply(map[string]any{})
		case "Page.getFrameTree":
			reply(map[string]any{"frameTree": map[string]any{"frame": map[string]any{"id": "F" + m.SessionID}}})
		case "Target.closeTarget":
			var p struct {
				TargetID string `json:"targetId"`
			}
			_ = json.Unmarshal(m.Params, &p)
			session := "S" + strings.TrimPrefix(p.TargetID, "T")
			f.mu.Lock()
			delete(f.casting, session)
			f.mu.Unlock()
			reply(map[string]any{"success": true})
			f.write(map[string]any{"method": "Target.detachedFromTarget", "params": map[string]any{
				"sessionId": session, "targetId": p.TargetID}})
			f.closedCh <- p.TargetID
		case "Page.navigate":
			f.mu.Lock()
			hold := f.hold
			f.mu.Unlock()
			if hold != nil {
				go func(id int64, session string) {
					<-hold
					f.write(map[string]any{"id": id, "sessionId": session, "result": map[string]any{"frameId": "F" + session}})
				}(m.ID, m.SessionID)
				continue
			}
			reply(map[string]any{"frameId": "F" + m.SessionID})
		case "Page.getNavigationHistory":
			reply(map[string]any{"currentIndex": 0, "entries": []any{map[string]any{"url": "https://example.com/", "title": "Example"}}})
		case "Accessibility.getFullAXTree":
			reply(map[string]any{"nodes": []any{map[string]any{"nodeId": "1", "role": map[string]any{"value": "RootWebArea"},
				"name": map[string]any{"value": strings.Repeat("long text ", 4000)}}}})
		case "Page.startScreencast":
			var p struct {
				Quality   int `json:"quality"`
				MaxWidth  int `json:"maxWidth"`
				MaxHeight int `json:"maxHeight"`
			}
			_ = json.Unmarshal(m.Params, &p)
			f.mu.Lock()
			// As Chrome does, a start while one runs is refused.
			if f.casting[m.SessionID] != nil {
				f.mu.Unlock()
				f.write(map[string]any{"id": m.ID, "sessionId": m.SessionID,
					"error": map[string]any{"code": -32000, "message": "Screencast is already active"}})
				continue
			}
			f.casting[m.SessionID] = &screencast{quality: p.Quality, width: p.MaxWidth, height: p.MaxHeight}
			f.casts = append(f.casts, fmt.Sprintf("%s q%d %dx%d", m.SessionID, p.Quality, p.MaxWidth, p.MaxHeight))
			f.order = append(f.order, "start "+m.SessionID)
			f.mu.Unlock()
			reply(map[string]any{})
			f.frame(m.SessionID)
			f.frame(m.SessionID)
		case "Page.stopScreencast":
			f.mu.Lock()
			delete(f.casting, m.SessionID)
			f.stops = append(f.stops, m.SessionID)
			f.order = append(f.order, "stop "+m.SessionID)
			stopWait := f.stopWait
			f.mu.Unlock()
			if stopWait > 0 {
				go func(id int64, session string) {
					time.Sleep(stopWait)
					f.mu.Lock()
					f.order = append(f.order, "stopped "+session)
					f.mu.Unlock()
					f.write(map[string]any{"id": id, "sessionId": session, "result": map[string]any{}})
				}(m.ID, m.SessionID)
				continue
			}
			reply(map[string]any{})
		case "Page.screencastFrameAck":
			f.mu.Lock()
			if sc := f.casting[m.SessionID]; sc != nil && sc.inFlight > 0 {
				sc.inFlight--
			}
			f.mu.Unlock()
			reply(map[string]any{})
			f.frame(m.SessionID)
		case "Input.dispatchMouseEvent", "Input.dispatchKeyEvent":
			var p map[string]any
			_ = json.Unmarshal(m.Params, &p)
			f.mu.Lock()
			f.inputs = append(f.inputs, fmt.Sprintf("%s %s %s", m.SessionID, strings.TrimPrefix(m.Method, "Input.dispatch"), describeInput(p)))
			f.mu.Unlock()
			reply(map[string]any{})
		default:
			f.write(map[string]any{"id": m.ID, "error": map[string]any{"code": -32601, "message": m.Method + " wasn't found"}})
		}
	}
}

func describeInput(p map[string]any) string {
	switch p["type"] {
	case "keyDown", "rawKeyDown", "keyUp":
		text, ok := p["text"].(string)
		if !ok {
			return fmt.Sprintf("%v %v", p["type"], p["key"])
		}
		return fmt.Sprintf("%v %v %q", p["type"], p["key"], text)
	default:
		return fmt.Sprintf("%v %v,%v %v", p["type"], p["x"], p["y"], p["button"])
	}
}

func (f *castChrome) seenInputs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.inputs...)
}

func (f *castChrome) startedCasts() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.casts...)
}

func (f *castChrome) stoppedCasts() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.stops...)
}

// caster is the test's side of a driver whose Chrome is a castChrome: it
// reads every message the driver writes into an inbox.
type caster struct {
	t      *testing.T
	in     io.Writer
	inbox  chan map[string]any
	chrome *castChrome
	done   chan error
}

func newCaster(t *testing.T) *caster {
	commandsIn, commandsOut := io.Pipe()
	answersIn, answersOut := io.Pipe()
	chrome := newCastChrome(commandsIn, answersOut)
	b := newBrowser()
	b.c = newCDP(commandsOut, answersIn, b.onTarget)
	hostIn, driverOut := io.Pipe()
	driverIn, hostOut := io.Pipe()
	s := newSlot(driverOut, 64, time.Minute)
	h := &caster{t: t, in: hostOut, inbox: make(chan map[string]any, 256), chrome: chrome, done: make(chan error, 1)}
	go func() { h.done <- serve(driverIn, s, b, nil, make(chan os.Signal)) }()
	go func() {
		r := reader{max: maxToHost}
		buf := make([]byte, 64<<10)
		for {
			n, err := hostIn.Read(buf)
			for _, body := range r.feed(buf[:n]) {
				var m map[string]any
				_ = json.Unmarshal(body, &m)
				h.inbox <- m
			}
			if err != nil {
				close(h.inbox)
				return
			}
		}
	}()
	t.Cleanup(func() {
		hostOut.Close()
		if err := <-h.done; err != nil {
			t.Errorf("serve ended with %v when its input ended", err)
		}
	})
	return h
}

func (h *caster) send(message any) {
	h.t.Helper()
	if _, err := h.in.Write(encode(must(json.Marshal(message)))); err != nil {
		h.t.Fatal(err)
	}
}

// next is the driver's next message, or nil when none comes within wait.
func (h *caster) next(wait time.Duration) map[string]any {
	select {
	case m := <-h.inbox:
		return m
	case <-time.After(wait):
		return nil
	}
}

// response takes response id whole, acknowledging each chunk; images that
// come meanwhile are kept in order and answered.
func (h *caster) response(id int64) (map[string]any, []map[string]any) {
	h.t.Helper()
	var text []byte
	var images []map[string]any
	for {
		m := h.next(5 * time.Second)
		if m == nil {
			h.t.Fatalf("response %d never came", id)
		}
		if m["t"] == "image" || m["t"] == "uncast" {
			images = append(images, m)
			continue
		}
		if m["t"] != "res" || int64(m["id"].(float64)) != id {
			h.t.Fatalf("a message out of turn: %v", m)
		}
		text = append(text, must(base64.StdEncoding.DecodeString(m["part"].(string)))...)
		h.send(map[string]any{"t": "ack", "id": id, "seq": m["seq"]})
		if m["seq"].(float64) == m["of"].(float64)-1 {
			var answer map[string]any
			if err := json.Unmarshal(text, &answer); err != nil {
				h.t.Fatalf("a response of no JSON: %s", text)
			}
			return answer, images
		}
	}
}

func (h *caster) image(what string) map[string]any {
	h.t.Helper()
	m := h.next(5 * time.Second)
	if m == nil || m["t"] != "image" {
		h.t.Fatalf("%s: want an image, got %v", what, m)
	}
	return m
}

func (h *caster) nothing(what string) {
	h.t.Helper()
	if m := h.next(300 * time.Millisecond); m != nil {
		h.t.Fatalf("%s: want nothing, got %v", what, m)
	}
}

func (h *caster) open(id int64, win string) {
	h.t.Helper()
	h.send(map[string]any{"t": "req", "id": id, "win": win, "op": "open", "args": map[string]any{"url": "https://example.com/"}})
	if got, _ := h.response(id); got["ok"] == nil {
		h.t.Fatalf("an open answered %v", got)
	}
}

func (h *caster) cast(id int64, win string) {
	h.t.Helper()
	h.send(map[string]any{"t": "req", "id": id, "win": win, "op": "cast", "args": map[string]any{"width": 1280, "height": 720}})
}

// A cast sends one image and no other until the host says it has seen it,
// and a response the host asks for meanwhile still arrives whole: a host
// that does not acknowledge an image gets no further one, and Chrome makes
// none past the two it may have unacknowledged.
func TestACastSendsOneImageAtATimeBesideAWholeResponse(t *testing.T) {
	h := newCaster(t)
	h.open(1, "thr_01")
	h.cast(2, "thr_01")
	if got, images := h.response(2); !jsonEqual(got, `{"ok":{}}`) || len(images) > 1 {
		t.Fatalf("the cast answered %v with %d images", got, len(images))
	} else if len(images) == 1 {
		h.inbox <- images[0]
	}
	first := h.image("the cast's first image")
	if first["seq"].(float64) != 1 || first["id"].(float64) != 2 || first["at"] != nil {
		t.Fatalf("the first image is %v", first)
	}
	h.nothing("with the image unacknowledged")

	h.send(map[string]any{"t": "req", "id": 3, "win": "thr_01", "op": "read", "args": map[string]any{}})
	answer, images := h.response(3)
	if answer["ok"] == nil || len(images) != 0 {
		t.Fatalf("a read beside an unacknowledged image answered %v, with %d images", answer, len(images))
	}
	h.nothing("still with the image unacknowledged")

	h.send(map[string]any{"t": "seen", "id": 2, "seq": 1})
	if second := h.image("the image after the first was seen"); second["seq"].(float64) != 2 {
		t.Fatalf("the second image is %v", second)
	}
	h.nothing("with the second unacknowledged")
	// A stale acknowledgement, of the first again, sends nothing.
	h.send(map[string]any{"t": "seen", "id": 2, "seq": 1})
	h.nothing("after a stale acknowledgement")
	h.send(map[string]any{"t": "seen", "id": 2, "seq": 2})
	h.image("the third image")
}

func TestACastOfNoWindowIsRefused(t *testing.T) {
	h := newCaster(t)
	h.cast(1, "thr_none")
	if got, _ := h.response(1); !jsonEqual(got, `{"error":{"code":"no_window","message":"There is no browser window for this thread; open a page first."}}`) {
		t.Fatalf("a cast of no window answered %v", got)
	}
	h.send(map[string]any{"t": "req", "id": 2, "win": "thr_01", "op": "cast", "args": map[string]any{"width": 4097, "height": 720}})
	if got, _ := h.response(2); got["error"].(map[string]any)["code"] != "bad_request" {
		t.Fatalf("a cast past the bound answered %v", got)
	}
}

// Uncast stops the screencast; an acknowledgement or input after it
// changes nothing, and a new cast of the window starts afresh under its
// own id, which an acknowledgement of the old one does not advance.
func TestUncastEndsACastAndALaterCastStartsAfresh(t *testing.T) {
	h := newCaster(t)
	h.open(1, "thr_01")
	h.cast(2, "thr_01")
	h.response(2)
	h.image("the first cast's image")
	h.send(map[string]any{"t": "uncast", "id": 2})
	waitFor(t, func() bool { return len(h.chrome.stoppedCasts()) == 1 }, "the screencast to stop")
	h.send(map[string]any{"t": "seen", "id": 2, "seq": 1})
	h.send(map[string]any{"t": "input", "id": 2, "evs": []any{mouseAt("down", 0.5, 0.5)}})
	h.nothing("after uncast")
	if inputs := h.chrome.seenInputs(); len(inputs) != 0 {
		t.Fatalf("input after uncast reached the window: %v", inputs)
	}

	h.cast(3, "thr_01")
	_, images := h.response(3)
	for len(images) < 1 {
		images = append(images, h.image("the second cast's image"))
	}
	if images[0]["id"].(float64) != 3 || images[0]["seq"].(float64) != 1 {
		t.Fatalf("the second cast's first image is %v", images[0])
	}
	h.send(map[string]any{"t": "seen", "id": 2, "seq": 1})
	h.nothing("after the old cast's acknowledgement")
}

// A window that closes ends its cast, and the host is told.
func TestAClosedWindowEndsItsCast(t *testing.T) {
	h := newCaster(t)
	h.open(1, "thr_01")
	h.cast(2, "thr_01")
	h.response(2)
	h.image("the cast's image")
	h.send(map[string]any{"t": "req", "id": 3, "win": "thr_01", "op": "close", "args": map[string]any{}})
	_, more := h.response(3)
	for len(more) == 0 {
		more = append(more, h.next(5*time.Second))
	}
	if !jsonEqual(more[len(more)-1], `{"t":"uncast","id":2}`) {
		t.Fatalf("a closed window's cast ended with %v", more)
	}
}

func mouseAt(kind string, x, y float64) map[string]any {
	button, clicks := "left", 1
	if kind == "move" {
		button, clicks = "none", 0
	}
	return map[string]any{"k": "mouse", "type": kind, "x": x, "y": y, "button": button, "clicks": clicks, "mods": 0}
}

// The person's input reaches the cast's window alone, mapped onto it from
// the image they see, while a request holds that window; input that does
// not read is dropped whole.
func TestInputReachesTheCastWindowBesideARequestInIt(t *testing.T) {
	h := newCaster(t)
	h.open(1, "thr_01")
	h.open(2, "thr_02")
	h.cast(3, "thr_02")
	h.response(3)
	h.image("the cast's image")

	h.chrome.mu.Lock()
	h.chrome.hold = make(chan struct{})
	hold := h.chrome.hold
	h.chrome.mu.Unlock()
	h.send(map[string]any{"t": "req", "id": 4, "win": "thr_02", "op": "open", "args": map[string]any{"url": "https://example.org/"}})
	h.send(map[string]any{"t": "input", "id": 3, "evs": []any{
		mouseAt("move", 0.25, 0.5), mouseAt("down", 0.25, 0.5), mouseAt("up", 0.25, 0.5),
		map[string]any{"k": "wheel", "x": 0.5, "y": 0.5, "dx": 0, "dy": 120, "mods": 0},
		map[string]any{"k": "key", "type": "down", "key": "a", "code": "KeyA", "text": "a", "vk": 65, "mods": 0},
		map[string]any{"k": "key", "type": "up", "key": "a", "code": "KeyA", "text": "", "vk": 65, "mods": 0},
	}})
	// Not one event of a message with one that does not read.
	h.send(map[string]any{"t": "input", "id": 3, "evs": []any{mouseAt("down", 0.1, 0.1), mouseAt("down", 1.5, 0.1)}})
	want := []string{
		"S2 MouseEvent mouseMoved 320,450 none", "S2 MouseEvent mousePressed 320,450 left",
		"S2 MouseEvent mouseReleased 320,450 left", "S2 MouseEvent mouseWheel 640,450 <nil>",
		`S2 KeyEvent keyDown a "a"`, "S2 KeyEvent keyUp a",
	}
	waitFor(t, func() bool { return len(h.chrome.seenInputs()) >= len(want) }, "the input to land while the open waits")
	if got := h.chrome.seenInputs(); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("the input landed as\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	close(hold)
	if got, _ := h.response(4); got["ok"] == nil {
		t.Fatalf("the open that held the window answered %v", got)
	}
}

// An image too large for one message is not sent: the cast goes on at a
// lower quality, and at its floor at a smaller size.
func TestAnImageTooLargeStepsTheCastDown(t *testing.T) {
	h := newCaster(t)
	h.chrome.size = func(quality int) int {
		if quality > 30 {
			return maxImage + 1
		}
		return 100
	}
	h.open(1, "thr_01")
	h.cast(2, "thr_01")
	_, images := h.response(2)
	for len(images) < 1 {
		images = append(images, h.image("an image small enough"))
	}
	if got := len(images[0]["jpeg"].(string)); got != 100 || images[0]["seq"].(float64) != 1 {
		t.Fatalf("the first image sent is %d bytes, seq %v", got, images[0]["seq"])
	}
	// Chrome has two frames in flight when it restarts: the one made before
	// the restart's answer at the old quality steps nothing down again.
	if got := strings.Join(h.chrome.startedCasts(), ", "); got != "S1 q60 1280x720, S1 q45 1280x720, S1 q30 1280x720" {
		t.Fatalf("the screencast started as %s", got)
	}
}

// An image too large at the least quality and size ends the cast.
func TestAnImageTooLargeAtTheLeastEndsTheCast(t *testing.T) {
	h := newCaster(t)
	h.chrome.size = func(int) int { return maxImage + 1 }
	h.open(1, "thr_01")
	h.cast(2, "thr_01")
	_, more := h.response(2)
	for len(more) == 0 {
		more = append(more, h.next(5*time.Second))
	}
	if !jsonEqual(more[0], `{"t":"uncast","id":2}`) {
		t.Fatalf("a cast whose every image is too large ended with %v", more)
	}
	if last := h.chrome.startedCasts(); last[len(last)-1] != "S1 q15 16x16" {
		t.Fatalf("the screencast stepped down to %v", last)
	}
}

func waitFor(t *testing.T, check func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !check() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// A window's next cast, after its last was ended, starts only once the
// last's screencast has stopped, so that stop never ends the new one.
func TestACastAfterAnUncastStartsOnceTheOldHasStopped(t *testing.T) {
	h := newCaster(t)
	h.chrome.mu.Lock()
	h.chrome.stopWait = 200 * time.Millisecond
	h.chrome.mu.Unlock()
	h.open(1, "thr_01")
	h.cast(2, "thr_01")
	h.response(2)
	h.image("the first cast's image")
	h.send(map[string]any{"t": "uncast", "id": 2})
	h.cast(3, "thr_01")
	_, images := h.response(3)
	for len(images) < 1 {
		images = append(images, h.image("the second cast's image"))
	}
	h.chrome.mu.Lock()
	order := strings.Join(h.chrome.order, ", ")
	h.chrome.mu.Unlock()
	if order != "start S1, stop S1, stopped S1, start S1" {
		t.Fatalf("the screencasts went %s", order)
	}
}

// Review round one, finding 1: a cast that ended writes nothing of the
// input queued for it, however much waited.
func TestAnEndedCastWritesNothingOfItsQueuedInput(t *testing.T) {
	var wire bytes.Buffer
	b := &browser{c: &cdp{w: &wire, calls: map[int64]*pending{}}}
	cs := newCasts(b, nil, nil)
	ctx, cancel := context.WithCancel(context.Background())
	c := &cast{id: 1, cancel: cancel, input: make(chan inputBatch, 3)}
	cs.byID[1] = c
	for range 3 {
		c.input <- inputBatch{session: "S1", calls: []cdpInput{{method: "Input.dispatchKeyEvent",
			params: map[string]any{"type": "keyDown", "text": "x"}}}}
	}
	cs.uncast(1)
	b.runInput(ctx, c.input)
	if wire.Len() != 0 {
		t.Fatalf("an ended cast still wrote %d input commands", bytes.Count(wire.Bytes(), []byte{0}))
	}
}

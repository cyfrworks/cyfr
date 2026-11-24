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
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// pageChrome is a Chrome over a pipe pair that pauses what its windows ask
// of the reserved origin, as the Fetch domain does: a navigation there is
// paused, and answered by the driver before it commits, and a test pauses
// a page's own requests on any session. Each target is T<n> on session
// S<n>, its main frame M<n>; each frame's security origin is what the
// last document it committed says, or what a test sets.
type pageChrome struct {
	t  *testing.T
	mu sync.Mutex
	w  io.Writer
	// origins holds each session's frames, by id, with their origins and
	// parents; navigations the main frame's last address.
	origins  map[string]map[string][2]string
	address  map[string]string
	targets  int
	children int
	paused   int
	// navs holds each paused navigation's command and session.
	navs map[string]navigation
	open map[string]bool
	// answers carries each fulfilment and failure the driver made; held
	// keeps those a test has not taken yet.
	answers chan pageAnswer
	held    []pageAnswer
	// left holds the bodies a pause left out, by network id.
	left map[string]string
	runs chan string
	// fails holds how a window's navigation to an address fails.
	fails map[string]navFail
	// historyError fails every read of a window's navigation history.
	historyError bool
	// refuseChildNaming refuses the naming of every target attached to a
	// window's session (agent.go).
	refuseChildNaming bool
	// loaders holds each frame's document's loader, which a request it
	// makes is reported with; callerOrigin, the Origin a frame's caller
	// sends when it is not the frame's document's, as a sandboxed frame's.
	loaders, callerOrigin map[string]string
	// order holds each naming and each run, as "name <session>" and
	// "run <session>", in the order the driver asked them; closed, the
	// targets it closed.
	order, closed []string
}

type navigation struct {
	id      int64
	session string
	url     string
	// link says the page navigated itself, so no command awaits an answer.
	link bool
	// loads says the commit is followed by its load; late, that the test
	// commits it.
	loads, late bool
}

// navFail is how a navigation fails: Chrome answers errorText, after
// committing the error page commit when one is named; or, with hangs, the
// navigation is paused and answered, and commits with no load after, or,
// with late too, commits only when the test says.
type navFail struct {
	errorText, commit string
	hangs, late       bool
}

type pageAnswer struct {
	method, session, request string
	status                   int
	headers                  map[string]string
	body                     []byte
	// nav says the request was a window's navigation.
	nav bool
}

func newPageChrome(t *testing.T, commands io.Reader, answers io.Writer) *pageChrome {
	f := &pageChrome{t: t, w: answers, origins: map[string]map[string][2]string{}, address: map[string]string{},
		navs: map[string]navigation{}, open: map[string]bool{}, answers: make(chan pageAnswer, 64), runs: make(chan string, 16),
		left: map[string]string{}, fails: map[string]navFail{}, loaders: map[string]string{},
		callerOrigin: map[string]string{}}
	go f.serve(commands)
	return f
}

func (f *pageChrome) write(message map[string]any) {
	data, _ := json.Marshal(message)
	f.mu.Lock()
	defer f.mu.Unlock()
	_, _ = f.w.Write(append(data, 0))
}

// pause pauses a script's fetch on session, as the frame it names made it,
// with a network id when network is set, and answers its request id.
func (f *pageChrome) pause(session, method, address, frame string, network bool, body string) string {
	return f.pauseAs(session, "Fetch", method, address, frame, network, body)
}

// pauseAs pauses a request of resourceType on session, of the frame it
// names: the frame whose document made it, or for a navigation the frame
// it loads into. One with a network id is reported first, as made by its
// frame's document.
func (f *pageChrome) pauseAs(session, resourceType, method, address, frame string, network bool, body string) string {
	f.mu.Lock()
	loader := f.loaders[frame]
	f.mu.Unlock()
	return f.pauseFrom(session, resourceType, method, address, frame, network, body, loader, true)
}

// pauseFrom pauses a request as pauseAs does, made by the document of
// loader: reported before its pause when before is set, else when the
// test reports it. A POST carries its frame's origin as its Origin, or
// the one a test gave the frame's caller (callerOrigin).
func (f *pageChrome) pauseFrom(session, resourceType, method, address, frame string, network bool, body, loader string,
	before bool) string {
	id := f.newRequest()
	headers := map[string]string{}
	if method == "POST" {
		headers = f.callerHeaders(session, frame)
	}
	if network && before {
		f.report(session, id, method, address, loader)
	}
	f.pauseWith(id, session, resourceType, method, address, frame, headers, network, body)
	return id
}

// callerHeaders are the headers a POST of frame's caller carries: its
// Origin, its frame's origin or the one a test gave its caller.
func (f *pageChrome) callerHeaders(session, frame string) map[string]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	origin, given := f.callerOrigin[frame]
	if !given {
		origin = f.origins[session][frame][1]
	}
	if origin == "" {
		return map[string]string{}
	}
	return map[string]string{"Origin": origin}
}

// newRequest names a request to pause, which a test may report before it
// pauses it.
func (f *pageChrome) newRequest() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.paused++
	id := fmt.Sprintf("interception-%d", f.paused)
	f.open[id] = true
	return id
}

// pauseWith pauses request id of resourceType on session, of the frame it
// names, with headers, and with a network id when network is set.
func (f *pageChrome) pauseWith(id, session, resourceType, method, address, frame string, headers map[string]string,
	network bool, body string) {
	request := map[string]any{"url": address, "method": method, "headers": headers}
	if body != "" {
		request["hasPostData"] = true
		request["postData"] = body
		request["postDataEntries"] = []any{map[string]any{"bytes": base64.StdEncoding.EncodeToString([]byte(body))}}
	}
	params := map[string]any{"requestId": id, "request": request, "frameId": frame, "resourceType": resourceType}
	if network {
		params["networkId"] = "net-" + id
	}
	f.write(map[string]any{"method": "Fetch.requestPaused", "sessionId": session, "params": params})
}

// report reports paused request id as made by the document of loader, as
// Network.requestWillBeSent does.
func (f *pageChrome) report(session, id, method, address, loader string) {
	f.event(session, "Network.requestWillBeSent", map[string]any{"requestId": "net-" + id, "loaderId": loader,
		"type": "Fetch", "request": map[string]any{"url": address, "method": method}})
}

// frameDocument attaches frame to parent, reported on parentSession, and
// commits a document of its own in it on session, as the page's process
// reports them; it answers the document's loader.
func (f *pageChrome) frameDocument(parentSession, session, frame, parent string) string {
	f.mu.Lock()
	f.paused++
	loader := fmt.Sprintf("Lframe-%d", f.paused)
	f.loaders[frame] = loader
	f.mu.Unlock()
	f.event(parentSession, "Page.frameAttached", map[string]any{"frameId": frame, "parentFrameId": parent})
	f.event(session, "Page.frameNavigated", map[string]any{"frame": map[string]any{
		"id": frame, "parentId": parent, "loaderId": loader, "url": reservedOrigin + "/",
		"securityOrigin": reservedOrigin}, "type": "Navigation"})
	return loader
}

// pauseLeavingOut pauses a POST whose body the pause leaves out, as Chrome
// does a body it does not carry, for Network.getRequestPostData to give; an
// empty body is one Chrome cannot give.
func (f *pageChrome) pauseLeavingOut(session, address, frame, body string) string {
	f.mu.Lock()
	f.paused++
	id := fmt.Sprintf("interception-%d", f.paused)
	f.open[id] = true
	if body != "" {
		f.left["net-"+id] = body
	}
	loader := f.loaders[frame]
	f.mu.Unlock()
	f.report(session, id, "POST", address, loader)
	f.write(map[string]any{"method": "Fetch.requestPaused", "sessionId": session, "params": map[string]any{
		"requestId": id, "request": map[string]any{"url": address, "method": "POST", "headers": f.callerHeaders(session, frame),
			"hasPostData": true}, "frameId": frame, "resourceType": "Fetch", "networkId": "net-" + id}})
	return id
}

// link navigates session's main frame to address as its own document
// does, by a link, a script or the person: a navigation of the reserved
// origin is paused and commits once the driver answers it, a fulfilment
// with its document and a failure with Chrome's error page, and answers
// its request id; any other commits at once, and answers "".
func (f *pageChrome) link(session, address string) string { return f.linkWith(session, address, false) }

// linkLate navigates as link does, but a navigation of the reserved origin
// the driver answers commits only when the test commits it.
func (f *pageChrome) linkLate(session, address string) string {
	return f.linkWith(session, address, true)
}

func (f *pageChrome) linkWith(session, address string, late bool) string {
	main := "M" + strings.TrimPrefix(session, "S")
	f.mu.Lock()
	f.paused++
	id := fmt.Sprintf("interception-%d", f.paused)
	if !strings.HasPrefix(address, reservedOrigin+"/") {
		f.mu.Unlock()
		f.commit(session, address, "L"+id)
		return ""
	}
	f.navs[id] = navigation{session: session, url: address, link: true, loads: true, late: late}
	f.open[id] = true
	f.mu.Unlock()
	f.write(map[string]any{"method": "Fetch.requestPaused", "sessionId": session, "params": map[string]any{
		"requestId": id, "request": map[string]any{"url": address, "method": "GET", "headers": map[string]string{}},
		"frameId": main, "resourceType": "Document", "networkId": "L" + id}})
	return id
}

// fail makes a window's navigation to address fail as how says.
func (f *pageChrome) fail(address string, how navFail) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fails[address] = how
}

// frame sets a frame of session, with its parent and origin. A frame
// inside another commits a document of that origin, reported as the
// page's process does, after the frame's attachment when it is new.
func (f *pageChrome) frame(session, id, parent, origin string) {
	f.mu.Lock()
	if f.origins[session] == nil {
		f.origins[session] = map[string][2]string{}
	}
	_, known := f.origins[session][id]
	f.origins[session][id] = [2]string{parent, origin}
	f.paused++
	loader := fmt.Sprintf("Lframe-%d", f.paused)
	if parent != "" {
		f.loaders[id] = loader
	}
	f.mu.Unlock()
	if parent == "" {
		return
	}
	if !known {
		f.event(session, "Page.frameAttached", map[string]any{"frameId": id, "parentFrameId": parent})
	}
	f.event(session, "Page.frameNavigated", map[string]any{"frame": map[string]any{
		"id": id, "parentId": parent, "loaderId": loader, "url": origin + "/", "securityOrigin": origin}, "type": "Navigation"})
}

// attach attaches a target of kind to session, waiting for its debugger,
// and answers its session.
func (f *pageChrome) attach(parent, kind string) string {
	f.mu.Lock()
	f.children++
	child := fmt.Sprintf("C%d", f.children)
	f.mu.Unlock()
	f.write(map[string]any{"method": "Target.attachedToTarget", "sessionId": parent, "params": map[string]any{
		"sessionId": child, "waitingForDebugger": true,
		"targetInfo": map[string]any{"targetId": "X" + child, "type": kind, "url": ""}}})
	return child
}

// attachToBrowser reports a target of kind attached to the browser's own
// attachment, held, opened by the target opener ("" for none), and
// answers its session.
func (f *pageChrome) attachToBrowser(kind, opener string) string {
	f.mu.Lock()
	f.children++
	child := fmt.Sprintf("C%d", f.children)
	f.mu.Unlock()
	f.write(map[string]any{"method": "Target.attachedToTarget", "params": map[string]any{
		"sessionId": child, "waitingForDebugger": true,
		"targetInfo": map[string]any{"targetId": "X" + child, "type": kind, "url": "", "openerId": opener}}})
	return child
}

// event writes an event of session.
func (f *pageChrome) event(session, method string, params map[string]any) {
	f.write(map[string]any{"method": method, "sessionId": session, "params": params})
}

// answer waits for the driver's answer to paused request id.
func (f *pageChrome) answer(id string) pageAnswer {
	f.t.Helper()
	return f.answered(func(a pageAnswer) bool { return a.request == id }, "request "+id)
}

// navigated waits for the driver's answer to a window's navigation.
func (f *pageChrome) navigated() pageAnswer {
	f.t.Helper()
	return f.answered(func(a pageAnswer) bool { return a.nav }, "a navigation")
}

func (f *pageChrome) answered(want func(pageAnswer) bool, what string) pageAnswer {
	f.t.Helper()
	for i, a := range f.held {
		if want(a) {
			f.held = append(f.held[:i:i], f.held[i+1:]...)
			return a
		}
	}
	deadline := time.After(5 * time.Second)
	for {
		select {
		case a := <-f.answers:
			if want(a) {
				return a
			}
			f.held = append(f.held, a)
		case <-deadline:
			f.t.Fatalf("%s was never answered; held %+v", what, f.held)
		}
	}
}

// drop forgets every answer to request id that has come.
func (f *pageChrome) drop(id string) {
	for {
		select {
		case a := <-f.answers:
			f.held = append(f.held, a)
			continue
		default:
		}
		break
	}
	kept := f.held[:0]
	for _, a := range f.held {
		if a.request != id {
			kept = append(kept, a)
		}
	}
	f.held = kept
}

// none says that no request is answered for a while.
func (f *pageChrome) none(what string) {
	f.t.Helper()
	if len(f.held) > 0 {
		f.t.Fatalf("%s: requests were answered: %+v", what, f.held)
	}
	select {
	case a := <-f.answers:
		f.t.Fatalf("%s: request %s was answered: %+v", what, a.request, a)
	case <-time.After(200 * time.Millisecond):
	}
}

func (f *pageChrome) serve(commands io.Reader) {
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
		var p struct {
			URL          string `json:"url"`
			TargetID     string `json:"targetId"`
			RequestID    string `json:"requestId"`
			ResponseCode int    `json:"responseCode"`
			Headers      []struct {
				Name, Value string
			} `json:"responseHeaders"`
			Body string `json:"body"`
		}
		_ = json.Unmarshal(m.Params, &p)
		switch m.Method {
		case "Target.createTarget":
			f.mu.Lock()
			f.targets++
			n := f.targets
			f.mu.Unlock()
			reply(map[string]any{"targetId": fmt.Sprintf("T%d", n)})
		case "Target.attachToTarget":
			session := "S" + strings.TrimPrefix(p.TargetID, "T")
			f.frame(session, "M"+strings.TrimPrefix(p.TargetID, "T"), "", "://")
			reply(map[string]any{"sessionId": session})
		case "Page.enable", "Page.setLifecycleEventsEnabled", "Network.enable", "Fetch.enable", "Target.setAutoAttach":
			reply(map[string]any{})
		case "Emulation.setUserAgentOverride", "Network.setUserAgentOverride":
			f.mu.Lock()
			refuse := f.refuseChildNaming && strings.HasPrefix(m.SessionID, "C")
			f.mu.Unlock()
			if refuse {
				f.write(map[string]any{"id": m.ID, "sessionId": m.SessionID,
					"error": map[string]any{"code": -32000, "message": "Not allowed"}})
				continue
			}
			f.mu.Lock()
			f.order = append(f.order, "name "+m.SessionID)
			f.mu.Unlock()
			reply(map[string]any{})
		case "Runtime.runIfWaitingForDebugger":
			f.mu.Lock()
			f.order = append(f.order, "run "+m.SessionID)
			f.mu.Unlock()
			reply(map[string]any{})
			f.runs <- m.SessionID
		case "Target.getTargetInfo":
			reply(map[string]any{"targetInfo": map[string]any{"targetId": "X" + m.SessionID}})
		case "Page.getFrameTree":
			reply(map[string]any{"frameTree": f.tree(m.SessionID)})
		case "Network.getRequestPostData":
			var q struct {
				RequestID string `json:"requestId"`
			}
			_ = json.Unmarshal(m.Params, &q)
			f.mu.Lock()
			body, ok := f.left[q.RequestID]
			f.mu.Unlock()
			if !ok {
				f.write(map[string]any{"id": m.ID, "sessionId": m.SessionID,
					"error": map[string]any{"code": -32000, "message": "No post data available for the request"}})
				continue
			}
			reply(map[string]any{"postData": base64.StdEncoding.EncodeToString([]byte(body)), "base64Encoded": true})
		case "Page.navigate":
			main := "M" + strings.TrimPrefix(m.SessionID, "S")
			f.mu.Lock()
			how, failing := f.fails[p.URL]
			f.mu.Unlock()
			if failing && !how.hangs {
				if how.commit != "" {
					f.commit(m.SessionID, how.commit, "Lfailed-"+p.URL)
				}
				reply(map[string]any{"frameId": main, "errorText": how.errorText})
				continue
			}
			// A navigation to a fragment of the page stays in its document:
			// Chrome answers no loader and reports no commit.
			if strings.Contains(p.URL, "#") {
				reply(map[string]any{"frameId": "M" + strings.TrimPrefix(m.SessionID, "S")})
				continue
			}
			f.mu.Lock()
			f.paused++
			id := fmt.Sprintf("interception-%d", f.paused)
			if strings.HasPrefix(p.URL, reservedOrigin+"/") {
				f.navs[id] = navigation{id: m.ID, session: m.SessionID, url: p.URL, loads: !(failing && how.hangs),
					late: failing && how.late}
				f.open[id] = true
				f.mu.Unlock()
				f.write(map[string]any{"method": "Fetch.requestPaused", "sessionId": m.SessionID, "params": map[string]any{
					"requestId": id, "request": map[string]any{"url": p.URL, "method": "GET", "headers": map[string]string{}},
					"frameId": "M" + strings.TrimPrefix(m.SessionID, "S"), "resourceType": "Document", "networkId": "L" + id}})
				continue
			}
			f.mu.Unlock()
			reply(map[string]any{"frameId": "M" + strings.TrimPrefix(m.SessionID, "S"), "loaderId": "L" + id})
			f.commit(m.SessionID, p.URL, "L"+id)
		case "Page.getNavigationHistory":
			f.mu.Lock()
			address := f.address[m.SessionID]
			historyError := f.historyError
			f.mu.Unlock()
			if historyError {
				f.write(map[string]any{"id": m.ID, "sessionId": m.SessionID,
					"error": map[string]any{"code": -32000, "message": "history unavailable"}})
				continue
			}
			reply(map[string]any{"currentIndex": 0, "entries": []any{map[string]any{"url": address, "title": "Put"}}})
		case "Fetch.fulfillRequest", "Fetch.failRequest":
			f.mu.Lock()
			open := f.open[p.RequestID]
			delete(f.open, p.RequestID)
			nav, isNav := f.navs[p.RequestID]
			delete(f.navs, p.RequestID)
			f.mu.Unlock()
			if !open {
				f.write(map[string]any{"id": m.ID, "sessionId": m.SessionID,
					"error": map[string]any{"code": -32602, "message": "Invalid InterceptionId."}})
				continue
			}
			body, _ := base64.StdEncoding.DecodeString(p.Body)
			headers := map[string]string{}
			for _, h := range p.Headers {
				headers[h.Name] = h.Value
			}
			reply(map[string]any{})
			switch {
			case isNav && nav.link && nav.late:
			case isNav && nav.link:
				if m.Method == "Fetch.failRequest" {
					f.commit(nav.session, "chrome-error://chromewebdata/", "L"+p.RequestID)
				} else {
					f.commit(nav.session, nav.url, "L"+p.RequestID)
				}
			case isNav:
				frame := "M" + strings.TrimPrefix(nav.session, "S")
				if m.Method == "Fetch.failRequest" {
					f.write(map[string]any{"id": nav.id, "sessionId": nav.session, "result": map[string]any{
						"frameId": frame, "loaderId": "L" + p.RequestID, "errorText": "net::ERR_BLOCKED_BY_CLIENT"}})
				} else {
					f.write(map[string]any{"id": nav.id, "sessionId": nav.session, "result": map[string]any{
						"frameId": frame, "loaderId": "L" + p.RequestID}})
					switch {
					case nav.late:
					case nav.loads:
						f.commit(nav.session, nav.url, "L"+p.RequestID)
					default:
						f.commitOnly(nav.session, nav.url, "L"+p.RequestID)
					}
				}
			}
			f.answers <- pageAnswer{method: m.Method, session: m.SessionID, request: p.RequestID,
				status: p.ResponseCode, headers: headers, body: body, nav: isNav && !nav.link}
		case "Target.closeTarget":
			session := "S" + strings.TrimPrefix(p.TargetID, "T")
			f.mu.Lock()
			f.closed = append(f.closed, p.TargetID)
			f.mu.Unlock()
			reply(map[string]any{"success": true})
			f.write(map[string]any{"method": "Target.detachedFromTarget", "params": map[string]any{
				"sessionId": session, "targetId": p.TargetID}})
		default:
			f.write(map[string]any{"id": m.ID, "error": map[string]any{"code": -32601, "message": m.Method + " wasn't found"}})
		}
	}
}

// commit makes address the main frame's document: its origin, its
// navigation reported and its load.
func (f *pageChrome) commit(session, address, loader string) {
	f.commitOnly(session, address, loader)
	f.event(session, "Page.lifecycleEvent", map[string]any{"frameId": "M" + strings.TrimPrefix(session, "S"),
		"loaderId": loader, "name": "load"})
}

// commitOnly makes address the main frame's document, its origin and its
// navigation reported, with no load.
func (f *pageChrome) commitOnly(session, address, loader string) {
	main := "M" + strings.TrimPrefix(session, "S")
	origin := "://"
	if strings.HasPrefix(address, "https://") {
		rest := strings.TrimPrefix(address, "https://")
		origin = "https://" + strings.SplitN(rest, "/", 2)[0]
	}
	f.mu.Lock()
	f.address[session] = address
	f.origins[session] = map[string][2]string{main: {"", origin}}
	f.loaders[main] = loader
	f.mu.Unlock()
	f.event(session, "Page.frameNavigated", map[string]any{"frame": map[string]any{
		"id": main, "loaderId": loader, "url": address, "securityOrigin": origin}, "type": "Navigation"})
}

func (f *pageChrome) tree(session string) map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	nodes := map[string]map[string]any{}
	for id, fr := range f.origins[session] {
		nodes[id] = map[string]any{"frame": map[string]any{"id": id, "parentId": fr[0], "securityOrigin": fr[1]}}
	}
	var root map[string]any
	for id, fr := range f.origins[session] {
		if parent := nodes[fr[0]]; parent != nil {
			children, _ := parent["childFrames"].([]any)
			parent["childFrames"] = append(children, nodes[id])
		} else {
			root = nodes[id]
		}
	}
	return root
}

// pageHost is the host's side for puts and calls: it takes every message
// the driver sends into an inbox and acknowledges each response chunk.
type pageHost struct {
	t     *testing.T
	in    io.Writer
	inbox chan map[string]any
	held  []map[string]any
}

func newPageHost(t *testing.T, in io.Writer, out io.Reader) *pageHost {
	h := &pageHost{t: t, in: in, inbox: make(chan map[string]any, 256)}
	go func() {
		r := reader{max: maxToHost}
		buf := make([]byte, 64<<10)
		for {
			n, err := out.Read(buf)
			for _, body := range r.feed(buf[:n]) {
				var m map[string]any
				if json.Unmarshal(body, &m) == nil {
					h.inbox <- m
				}
			}
			if err != nil {
				close(h.inbox)
				return
			}
		}
	}()
	return h
}

func (h *pageHost) send(message any) {
	h.t.Helper()
	if _, err := h.in.Write(encode(must(json.Marshal(message)))); err != nil {
		h.t.Fatal(err)
	}
}

// take answers the first message want accepts, holding the others.
func (h *pageHost) take(want func(map[string]any) bool, what string) map[string]any {
	h.t.Helper()
	for i, m := range h.held {
		if want(m) {
			h.held = append(h.held[:i:i], h.held[i+1:]...)
			return m
		}
	}
	deadline := time.After(5 * time.Second)
	for {
		select {
		case m, ok := <-h.inbox:
			if !ok {
				h.t.Fatalf("the driver's output ended before %s", what)
			}
			if m["t"] == "res" {
				h.send(map[string]any{"t": "ack", "id": m["id"], "seq": m["seq"]})
			}
			if want(m) {
				return m
			}
			h.held = append(h.held, m)
		case <-deadline:
			h.t.Fatalf("%s never came; held %v", what, h.held)
		}
	}
}

// response answers response id whole, its chunks put together.
func (h *pageHost) response(id int) map[string]any {
	h.t.Helper()
	var text []byte
	for {
		m := h.take(func(m map[string]any) bool { return m["t"] == "res" && m["id"] == float64(id) }, fmt.Sprintf("response %d", id))
		text = append(text, must(base64.StdEncoding.DecodeString(m["part"].(string)))...)
		if m["seq"] == m["of"].(float64)-1 {
			var answer map[string]any
			if err := json.Unmarshal(text, &answer); err != nil {
				h.t.Fatalf("a response of no JSON: %s", text)
			}
			return answer
		}
	}
}

// quiet says that no message want accepts comes for a while.
func (h *pageHost) quiet(want func(map[string]any) bool, what string) {
	h.t.Helper()
	deadline := time.After(300 * time.Millisecond)
	for {
		select {
		case m, ok := <-h.inbox:
			if !ok {
				return
			}
			if want(m) {
				h.t.Fatalf("%s: %v", what, m)
			}
			h.held = append(h.held, m)
		case <-deadline:
			return
		}
	}
}

// bodyOf is a call's body, its bytes from their base64.
func bodyOf(call map[string]any) string {
	text, _ := call["body"].(string)
	return string(must(base64.StdEncoding.DecodeString(text)))
}

type siteFile struct {
	path, typ, body string
}

// put sends a put of files under root as req id with its parts, each at
// most size bytes, and answers its response.
func (h *pageHost) put(id int, win, root, entry string, files []siteFile, size int) map[string]any {
	h.t.Helper()
	h.sendPut(id, win, root, entry, files, size)
	return h.response(id)
}

// sendPut sends a put as put does, and leaves its response to come.
func (h *pageHost) sendPut(id int, win, root, entry string, files []siteFile, size int) {
	h.t.Helper()
	manifest := []map[string]any{}
	var all []byte
	for _, f := range files {
		manifest = append(manifest, map[string]any{"path": f.path, "type": f.typ, "size": len(f.body)})
		all = append(all, f.body...)
	}
	var parts [][]byte
	for at := 0; at < len(all); at += size {
		parts = append(parts, all[at:min(at+size, len(all))])
	}
	h.send(map[string]any{"t": "req", "id": id, "win": win, "op": "page", "of": len(parts),
		"args": map[string]any{"root": root, "entry": entry, "files": manifest}})
	for seq, part := range parts {
		h.send(map[string]any{"t": "part", "id": id, "seq": seq, "part": base64.StdEncoding.EncodeToString(part)})
	}
}

const testRoot = "/t/ath01/local/site"

var testSite = []siteFile{
	{"index.html", "text/html", "<!doctype html><title>Put</title><script src=app.js></script>"},
	{"app.js", "text/javascript", "window.ran = 1"},
	{"img/pic.png", "image/png", "\x89PNG\r\n\x1a\n"},
}

type pageRig struct {
	f      *pageChrome
	h      *pageHost
	b      *browser
	close  func()
	served chan error
}

func newPageRig(t *testing.T) *pageRig {
	commandsIn, commandsOut := io.Pipe()
	answersIn, answersOut := io.Pipe()
	f := newPageChrome(t, commandsIn, answersOut)
	b := newBrowser()
	b.c = newCDP(commandsOut, answersIn, b.onTarget)
	hostIn, driverOut := io.Pipe()
	driverIn, hostOut := io.Pipe()
	s := newSlot(driverOut, 49152, time.Minute)
	served := make(chan error, 1)
	go func() { served <- serve(driverIn, s, b, nil, make(chan os.Signal)) }()
	r := &pageRig{f: f, h: newPageHost(t, hostOut, hostIn), b: b, served: served}
	r.close = func() {
		hostOut.Close()
		if err := <-served; err != nil {
			t.Errorf("serve ended with %v when its input ended", err)
		}
	}
	return r
}

// A put's files arrive in parts, and its page is answered from them: the
// entry at the root and the root's slash, each file at its path with its
// type, nothing at a path the put does not hold, and nothing for a window
// with no put.
func TestPutIsAnsweredFromItsFiles(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	shown := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 7)
	if !jsonEqual(shown, `{"ok":{"url":"https://cyfr.invalid/t/ath01/local/site","title":"Put"}}`) {
		t.Fatalf("the put answered %v", shown)
	}
	nav := r.f.navigated()
	if nav.method != "Fetch.fulfillRequest" || nav.status != 200 || string(nav.body) != testSite[0].body ||
		nav.headers["Content-Type"] != "text/html" {
		t.Fatalf("the navigation to the root was answered %+v", nav)
	}
	for _, c := range []struct {
		method, path string
		status       int
		typ, body    string
	}{
		{"GET", testRoot + "/", 200, "text/html", testSite[0].body},
		{"GET", testRoot + "/app.js", 200, "text/javascript", testSite[1].body},
		{"GET", testRoot + "/img/pic.png", 200, "image/png", testSite[2].body},
		{"GET", testRoot + "/img/pic%2Epng", 200, "image/png", testSite[2].body},
		{"HEAD", testRoot + "/app.js", 200, "text/javascript", ""},
		{"GET", testRoot + "/missing.js", 404, "", ""},
		{"GET", testRoot + "app.js", 404, "", ""},
		{"GET", "/t/ath01/local/other/app.js", 404, "", ""},
		{"POST", testRoot + "/form", 404, "", ""},
		{"OPTIONS", "/_f/v1/invoke", 404, "", ""},
	} {
		id := r.f.pause("S1", c.method, reservedOrigin+c.path, "M1", true, "")
		a := r.f.answer(id)
		if a.method != "Fetch.fulfillRequest" || a.status != c.status || a.headers["Content-Type"] != c.typ || string(a.body) != c.body {
			t.Errorf("%s %s was answered %+v, want %d %q %q", c.method, c.path, a, c.status, c.typ, c.body)
		}
	}

	// A window with no put is answered nothing: its open of the reserved
	// origin fails, and leaves no window.
	r.h.send(map[string]any{"t": "req", "id": 2, "win": "thr_02", "op": "open", "args": map[string]any{"url": reservedOrigin + testRoot}})
	if got := r.h.response(2); !jsonEqual(got, `{"error":{"code":"unreachable","message":"The page could not be loaded (net::ERR_BLOCKED_BY_CLIENT)."}}`) {
		t.Fatalf("an open of the reserved origin in a window with no put answered %v", got)
	}
	if a := r.f.navigated(); a.method != "Fetch.failRequest" {
		t.Fatalf("the open's navigation was answered %+v", a)
	}

	// An open in the put's window shows another page: its files are gone.
	r.h.send(map[string]any{"t": "req", "id": 3, "win": "thr_01", "op": "open", "args": map[string]any{"url": "https://example.com/"}})
	if got := r.h.response(3); got["ok"] == nil {
		t.Fatalf("an open answered %v", got)
	}
	if a := r.f.answer(r.f.pause("S1", "GET", reservedOrigin+testRoot+"/app.js", "M1", true, "")); a.method != "Fetch.failRequest" {
		t.Fatalf("a window that showed another page was answered %+v from its old put", a)
	}
}

// A put whose parts do not arrive whole is refused, and nothing of it is
// kept or run.
func TestPutRefusals(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	files := func(n int, size int) []map[string]any {
		list := []map[string]any{}
		for i := range n {
			list = append(list, map[string]any{"path": fmt.Sprintf("f%d.js", i), "type": "text/javascript", "size": size})
		}
		list[0]["path"] = "index.html"
		return list
	}
	refused := func(id int, code string, what string) {
		t.Helper()
		got := r.h.response(id)
		e, _ := got["error"].(map[string]any)
		if e == nil || e["code"] != code || !strings.HasSuffix(e["message"].(string), ".") {
			t.Errorf("%s answered %v, want %s", what, got, code)
		}
	}
	page := func(id int, of int, args map[string]any) {
		r.h.send(map[string]any{"t": "req", "id": id, "win": "thr_r", "op": "page", "of": of, "args": args})
	}
	part := func(id, seq int, data []byte) {
		r.h.send(map[string]any{"t": "part", "id": id, "seq": seq, "part": base64.StdEncoding.EncodeToString(data)})
	}

	page(1, 0, map[string]any{"html": "<p>a page</p>"})
	refused(1, "bad_request", "a page of html")
	page(2, 1, map[string]any{"root": testRoot, "entry": "index.html", "files": files(maxPutFiles+1, 0)})
	refused(2, "too_large", "a put of more files than the bound")
	page(3, 33, map[string]any{"root": testRoot, "entry": "index.html", "files": []map[string]any{
		{"path": "index.html", "type": "text/html", "size": maxPutBytes - 1}, {"path": "b.bin", "type": "application/octet-stream", "size": 2}}})
	refused(3, "too_large", "a put of more bytes than the bound")
	for n, args := range []map[string]any{
		{"root": testRoot, "entry": "missing.html", "files": files(1, 0)},
		{"root": "t/ath01/local/site", "entry": "index.html", "files": files(1, 0)},
		{"root": testRoot + "/", "entry": "index.html", "files": files(1, 0)},
		{"root": testRoot, "entry": "index.html", "files": []map[string]any{{"path": "index.html", "type": "text/html", "size": 0}, {"path": "/abs.js", "type": "text/javascript", "size": 0}}},
		{"root": testRoot, "entry": "index.html", "files": []map[string]any{{"path": "index.html", "type": "text/html", "size": 0}, {"path": "../up.js", "type": "text/javascript", "size": 0}}},
		{"root": testRoot, "entry": "index.html", "files": []map[string]any{{"path": "index.html", "type": "text/html", "size": 0}, {"path": "index.html", "type": "text/html", "size": 0}}},
		{"root": testRoot, "entry": "index.html", "files": []map[string]any{{"path": "index.html", "type": "text/html", "size": -1}}},
		{"root": testRoot, "entry": "index.html", "files": []map[string]any{{"path": "index.html", "size": 0}}},
	} {
		page(10+n, 0, args)
		refused(10+n, "bad_request", fmt.Sprintf("manifest %d", n))
	}

	// Parts out of order, sizes that do not add up and parts that cannot
	// hold the files each refuse the put, and a part after the refusal is
	// passed over.
	site := map[string]any{"root": testRoot, "entry": "index.html", "files": []map[string]any{{"path": "index.html", "type": "text/html", "size": 4}}}
	page(30, 2, site)
	part(30, 1, []byte("ab"))
	refused(30, "bad_request", "a part out of order")
	part(30, 0, []byte("ab"))
	page(31, 2, site)
	part(31, 0, []byte("ab"))
	part(31, 1, []byte("abc"))
	refused(31, "bad_request", "parts past the files' sizes")
	page(32, 2, site)
	part(32, 0, []byte("a"))
	part(32, 1, []byte("b"))
	refused(32, "bad_request", "parts short of the files' sizes")
	page(33, 0, site)
	refused(33, "bad_request", "no part for bytes the files hold")
	page(34, 1, site)
	r.h.send(map[string]any{"t": "part", "id": 34, "seq": 0, "part": "not base64!"})
	refused(34, "bad_request", "a part that is not base64")
	r.h.quiet(func(m map[string]any) bool { return m["t"] == "res" }, "a refused put answered again")
	r.f.none("a refused put")
	r.b.mu.Lock()
	windows := len(r.b.windows)
	r.b.mu.Unlock()
	if windows != 0 {
		t.Fatalf("refused puts left %d windows", windows)
	}
}

// A put whose parts stop arriving is refused at its keep, and nothing of it
// is kept.
func TestPutWhosePartsStopIsRefused(t *testing.T) {
	var out bytes.Buffer
	s := newSlot(&out, 49152, time.Minute)
	now := time.Unix(1000, 0)
	s.now = func() time.Time { return now }
	ran := 0
	ps := newPuts(s, func(request) { ran++ })
	s.running[5] = true
	if err := ps.start(request{ID: 5, Win: "thr", Op: "page", Of: 2, Args: json.RawMessage(
		`{"root":"/t/a/local/p","entry":"index.html","files":[{"path":"index.html","type":"text/html","size":4}]}`)}); err != nil {
		t.Fatal(err)
	}
	if err := ps.part(5, 0, []byte("ab"), false); err != nil {
		t.Fatal(err)
	}
	now = now.Add(time.Minute - time.Millisecond)
	if err := ps.expire(); err != nil || out.Len() != 0 || len(ps.byID) != 1 {
		t.Fatalf("a put within its keep was refused: %v %q", err, out.String())
	}
	now = now.Add(time.Millisecond)
	if err := ps.expire(); err != nil || len(ps.byID) != 0 {
		t.Fatalf("a put past its keep was kept: %v", err)
	}
	var r reader
	r.max = maxToHost
	bodies := r.feed(out.Bytes())
	var res resMessage
	if len(bodies) != 1 || json.Unmarshal(bodies[0], &res) != nil || res.ID != 5 ||
		!strings.Contains(string(must(base64.StdEncoding.DecodeString(res.Part))), `"code":"timeout"`) {
		t.Fatalf("a put past its keep answered %q", out.String())
	}
	if err := ps.part(5, 1, []byte("cd"), false); err != nil || ran != 0 {
		t.Fatalf("a part after the refusal ran the put: %v, %d", err, ran)
	}
}

// A put's files are laid out as its manifest says, from its parts in
// order.
func TestPutAssembly(t *testing.T) {
	var out bytes.Buffer
	s := newSlot(&out, 49152, time.Minute)
	var got *put
	ps := newPuts(s, func(r request) { got = r.put })
	s.running[7] = true
	if err := ps.start(request{ID: 7, Win: "thr", Op: "page", Of: 3, Args: json.RawMessage(
		`{"root":"/t/a/local/p","entry":"dist/index.html","files":[{"path":"dist/index.html","type":"text/html","size":5},` +
			`{"path":"empty.txt","type":"text/plain","size":0},{"path":"dist/a.js","type":"text/javascript","size":3}]}`)}); err != nil {
		t.Fatal(err)
	}
	for seq, data := range []string{"<p>", "hi", "a=1"} {
		if err := ps.part(7, int64(seq), []byte(data), false); err != nil {
			t.Fatal(err)
		}
	}
	if got == nil || got.root != "/t/a/local/p" || got.entry != "dist/index.html" || len(got.files) != 3 ||
		string(got.files["dist/index.html"].data) != "<p>hi" || len(got.files["empty.txt"].data) != 0 ||
		string(got.files["dist/a.js"].data) != "a=1" || got.files["dist/a.js"].typ != "text/javascript" || out.Len() != 0 {
		t.Fatalf("the put was laid out as %+v, answering %q", got, out.String())
	}
	if f := got.lookup("/t/a/local/p"); f == nil || string(f.data) != "<p>hi" {
		t.Fatalf("the root is answered %+v, not the entry", f)
	}
	if f := got.lookup("/t/a/local/p/"); f == nil || string(f.data) != "<p>hi" {
		t.Fatalf("the root's slash is answered %+v, not the entry", f)
	}
	if f := got.lookup("/t/a/local/pdist/a.js"); f != nil {
		t.Fatal("a path that only begins as the root's is answered")
	}
}

// A call is passed up only from a document of the reserved origin in a
// window the driver put: the page and a frame inside it of that origin,
// in its process or in another; never from a frame of another origin, a
// worker, a target of another kind or a window with no put. Its answer is
// the host's, and a body over the bound is 413.
func TestCallsArePassedUpOnlyFromThePutsDocuments(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	if shown := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); shown["ok"] == nil {
		t.Fatalf("the put answered %v", shown)
	}
	r.f.navigated()
	isCall := func(m map[string]any) bool { return m["t"] == "call" }

	id := r.f.pause("S1", "POST", reservedOrigin+"/_f/v1/invoke", "M1", true, `{"ref":"local.counter:0.1.0"}`)
	call := r.h.take(isCall, "the page's call")
	if !jsonEqual(call, `{"t":"call","id":1,"win":"thr_01","put":1,"op":"invoke","body":"eyJyZWYiOiJsb2NhbC5jb3VudGVyOjAuMS4wIn0="}`) {
		t.Fatalf("the page's call went up as %v", call)
	}
	r.f.none("a call before its answer")
	r.h.send(map[string]any{"t": "answer", "id": 1, "status": 200, "body": `{"ok":true}`})
	if a := r.f.answer(id); a.method != "Fetch.fulfillRequest" || a.status != 200 || string(a.body) != `{"ok":true}` ||
		a.headers["Content-Type"] != "application/json" || len(a.headers) != 1 {
		t.Fatalf("the call was answered %+v", a)
	}

	// A frame of the reserved origin inside the page is admitted; one of
	// another origin, and a worker, which carries no network id, are not.
	r.f.frame("S1", "F2", "M1", reservedOrigin)
	r.f.frame("S1", "F3", "M1", "://")
	r.f.frame("S1", "F4", "F3", "https://example.com")
	r.f.pause("S1", "POST", reservedOrigin+"/_f/v1/action", "F2", true, `{"from":"frame"}`)
	if call := r.h.take(isCall, "the frame's call"); call["op"] != "action" || bodyOf(call) != `{"from":"frame"}` || call["id"] != float64(2) {
		t.Fatalf("the frame of the reserved origin's call went up as %v", call)
	}
	for _, c := range []struct {
		what, frame string
		network     bool
	}{
		{"a frame of an opaque origin", "F3", true},
		{"a frame of another site", "F4", true},
		{"a worker of the page", "M1", false},
		{"a frame the tree does not hold", "F9", true},
	} {
		if a := r.f.answer(r.f.pause("S1", "POST", reservedOrigin+"/_f/v1/invoke", c.frame, c.network, `{"x":1}`)); a.method != "Fetch.failRequest" {
			t.Errorf("%s's call was answered %+v, not failed", c.what, a)
		}
	}
	r.h.quiet(isCall, "a call that is not admitted went up")

	// A frame of another process inside the page: of the reserved origin it
	// is admitted, of another it is not; a service worker is answered
	// nothing.
	frame := r.f.attach("S1", "iframe")
	if run := <-r.f.runs; run != frame {
		t.Fatalf("%s ran before the frame %s was set up", run, frame)
	}
	r.f.frame(frame, "O1", "M1", reservedOrigin)
	r.f.pause(frame, "POST", reservedOrigin+"/_f/v1/invoke", "O1", true, `{"from":"oopif"}`)
	if call := r.h.take(isCall, "the frame of another process's call"); bodyOf(call) != `{"from":"oopif"}` {
		t.Fatalf("the frame of another process's call went up as %v", call)
	}
	r.f.frame(frame, "O1", "M1", "https://example.com")
	if a := r.f.answer(r.f.pause(frame, "POST", reservedOrigin+"/_f/v1/invoke", "O1", true, `{"x":1}`)); a.method != "Fetch.failRequest" {
		t.Fatalf("a frame of another site in another process was answered %+v", a)
	}
	r.f.frameDocument("S1", frame, "O1", "M1")
	if a := r.f.answer(r.f.pause(frame, "GET", reservedOrigin+testRoot+"/app.js", "O1", true, "")); a.status != 200 {
		t.Fatalf("a frame of another process was answered %+v for a file of its window's put", a)
	}
	worker := r.f.attach("S1", "service_worker")
	<-r.f.runs
	if a := r.f.answer(r.f.pause(worker, "GET", reservedOrigin+testRoot+"/sw.js", "W1", false, "")); a.method != "Fetch.failRequest" {
		t.Fatalf("a service worker's script was answered %+v", a)
	}
	r.h.quiet(isCall, "a call that is not admitted went up")

	// A body over the bound is 413 and an unknown call path 404; neither
	// goes up.
	for _, c := range []struct {
		path, body string
		status     int
	}{
		{"/_f/v1/invoke", strings.Repeat("x", maxCallBody+1), 413},
		{"/_f/v1/other", "{}", 404},
	} {
		if a := r.f.answer(r.f.pause("S1", "POST", reservedOrigin+c.path, "M1", true, c.body)); a.status != c.status {
			t.Errorf("a POST of %d bytes to %s was answered %+v, want %d", len(c.body), c.path, a, c.status)
		}
	}
	// A body's bytes go up as they are, text or not.
	r.f.pause("S1", "POST", reservedOrigin+"/_f/v1/invoke", "M1", true, "\xff\xfe")
	if call := r.h.take(isCall, "a call of bytes that are no text"); call["body"] != "//4=" {
		t.Fatalf("a call of bytes that are no text went up as %v", call)
	}
	r.f.pauseLeavingOut("S1", reservedOrigin+"/_f/v1/invoke", "M1", `{"from":"left out"}`)
	if call := r.h.take(isCall, "a call whose body the pause left out"); bodyOf(call) != `{"from":"left out"}` {
		t.Fatalf("a call whose body the pause left out went up as %v", call)
	}
	if a := r.f.answer(r.f.pauseLeavingOut("S1", reservedOrigin+"/_f/v1/invoke", "M1", strings.Repeat("z", maxCallBody+1))); a.status != 413 {
		t.Fatalf("a body over the bound that the pause left out was answered %+v", a)
	}
	if a := r.f.answer(r.f.pauseLeavingOut("S1", reservedOrigin+"/_f/v1/invoke", "M1", "")); a.method != "Fetch.failRequest" {
		t.Fatalf("a body Chrome could not give was answered %+v", a)
	}
	if call := r.f.pause("S1", "POST", reservedOrigin+"/_f/v1/invoke", "M1", true, strings.Repeat("y", maxCallBody)); call == "" {
		t.Fatal("no request")
	}
	if call := r.h.take(isCall, "a call at the bound"); bodyOf(call) != strings.Repeat("y", maxCallBody) {
		t.Fatalf("a call at the bound went up with %d bytes", len(bodyOf(call)))
	}

	// A window with no put makes no call.
	r.h.send(map[string]any{"t": "req", "id": 2, "win": "thr_02", "op": "open", "args": map[string]any{"url": "https://example.com/"}})
	if got := r.h.response(2); got["ok"] == nil {
		t.Fatalf("an open answered %v", got)
	}
	r.f.frame("S2", "M2", "", reservedOrigin)
	if a := r.f.answer(r.f.pause("S2", "POST", reservedOrigin+"/_f/v1/invoke", "M2", true, `{}`)); a.method != "Fetch.failRequest" {
		t.Fatalf("a window with no put was answered %+v", a)
	}
	r.h.quiet(isCall, "a window with no put made a call")
}

// A call carries its own document's origin, as Chrome reported it with
// that document's commit, not its frame's next document's: a call of a
// frame's opaque document, named only after the frame committed a
// document of the reserved origin, makes no call.
func TestACallCarriesItsOwnDocumentsOrigin(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	if shown := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); shown["ok"] == nil {
		t.Fatalf("the put answered %v", shown)
	}
	r.f.navigated()
	r.f.frame("S1", "F2", "M1", "://")
	r.f.mu.Lock()
	opaque := r.f.loaders["F2"]
	r.f.mu.Unlock()
	id := r.f.pauseFrom("S1", "Fetch", "POST", callPath, "F2", true, `{}`, opaque, false)
	r.f.frame("S1", "F2", "M1", reservedOrigin)
	r.f.report("S1", id, "POST", callPath, opaque)
	if a := r.f.answer(id); a.method != "Fetch.failRequest" {
		t.Fatalf("a call of an opaque document whose frame went on to the reserved origin was answered %+v", a)
	}
	r.h.quiet(func(m map[string]any) bool { return m["t"] == "call" }, "the call went up")
}

// A call the driver holds is given up, its request failed and the host
// told `callend`, when its window navigates, shows another page or
// closes, and when its frame goes; an answer for it after is passed over.
func TestCallsEndWithTheirDocument(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	if shown := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); shown["ok"] == nil {
		t.Fatalf("the put answered %v", shown)
	}
	r.f.navigated()
	r.f.frame("S1", "F2", "M1", reservedOrigin)
	call := func(frame string) (string, int64) {
		t.Helper()
		request := r.f.pause("S1", "POST", reservedOrigin+"/_f/v1/invoke", frame, true, `{}`)
		m := r.h.take(func(m map[string]any) bool { return m["t"] == "call" }, "a call")
		return request, int64(m["id"].(float64))
	}
	ended := func(request string, id int64, what string, closed bool) {
		t.Helper()
		m := r.h.take(func(m map[string]any) bool { return m["t"] == "callend" }, what+": the callend")
		if m["id"] != float64(id) {
			t.Fatalf("%s: the driver ended call %v, want %d", what, m["id"], id)
		}
		if !closed {
			if a := r.f.answer(request); a.method != "Fetch.failRequest" {
				t.Fatalf("%s: the call's request was answered %+v", what, a)
			}
		} else {
			// A closed window's request goes with it, failed or not.
			time.Sleep(200 * time.Millisecond)
			r.f.drop(request)
		}
		r.h.send(map[string]any{"t": "answer", "id": id, "status": 200, "body": "{}"})
		r.f.none(what + ": an answer after the end")
	}

	request, id := call("F2")
	r.f.event("S1", "Page.frameDetached", map[string]any{"frameId": "F2", "reason": "remove"})
	ended(request, id, "its frame gone", false)

	// An answered call is no longer held: its frame's end ends nothing.
	r.f.frame("S1", "F5", "M1", reservedOrigin)
	request, id = call("F5")
	r.h.send(map[string]any{"t": "answer", "id": id, "status": 200, "body": "{}"})
	if a := r.f.answer(request); a.status != 200 {
		t.Fatalf("the call was answered %+v", a)
	}
	r.f.event("S1", "Page.frameDetached", map[string]any{"frameId": "F5", "reason": "remove"})
	r.h.quiet(func(m map[string]any) bool { return m["t"] == "callend" }, "an answered call was ended")

	r.f.frame("S1", "F3", "M1", reservedOrigin)
	request, id = call("F3")
	r.f.event("S1", "Page.frameNavigated", map[string]any{"frame": map[string]any{
		"id": "F4", "parentId": "M1", "url": "https://example.com/", "securityOrigin": "https://example.com"}})
	r.h.quiet(func(m map[string]any) bool { return m["t"] == "callend" }, "another frame's navigation ended the frame's call")
	r.f.event("S1", "Page.frameNavigated", map[string]any{"frame": map[string]any{
		"id": "M1", "url": "https://example.com/", "securityOrigin": "https://example.com"}})
	ended(request, id, "its window navigated", false)

	// An open that stays in the window's document, at a fragment of it,
	// keeps the document, its put and its calls.
	if shown := r.h.put(5, "thr_01", testRoot, "index.html", testSite, 64); shown["ok"] == nil {
		t.Fatalf("the put after the navigation answered %v", shown)
	}
	r.f.navigated()
	request, id = call("M1")
	r.h.send(map[string]any{"t": "req", "id": 4, "win": "thr_01", "op": "open", "args": map[string]any{"url": reservedOrigin + testRoot + "#here"}})
	if got := r.h.response(4); got["ok"] == nil {
		t.Fatalf("an open of a fragment answered %v", got)
	}
	r.h.quiet(func(m map[string]any) bool { return m["t"] == "callend" }, "an open that kept the document ended its call")
	r.h.send(map[string]any{"t": "answer", "id": id, "status": 200, "body": "{}"})
	if a := r.f.answer(request); a.status != 200 {
		t.Fatalf("the call of a document an open kept was answered %+v", a)
	}

	r.f.frame("S1", "M1", "", reservedOrigin)
	request, id = call("M1")
	if shown := r.h.put(2, "thr_01", testRoot, "index.html", testSite, 64); shown["ok"] == nil {
		t.Fatalf("the second put answered %v", shown)
	}
	r.f.navigated()
	ended(request, id, "its window showed another page", false)

	request, id = call("M1")
	r.h.send(map[string]any{"t": "req", "id": 3, "win": "thr_01", "op": "close", "args": map[string]any{}})
	if got := r.h.response(3); !jsonEqual(got, `{"ok":{"closed":true}}`) {
		t.Fatalf("the close answered %v", got)
	}
	ended(request, id, "its window closed", true)
}

// A call is a script's fetch from an admitted document, named by the frame
// of the document that made it. A navigation to a call path, a form's
// that a document of any origin submits into a frame of the put among
// them, names the frame it loads into: it is no call, and is answered as
// any path the put does not hold.
func TestANavigationToACallPathIsNoCall(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	if shown := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); shown["ok"] == nil {
		t.Fatalf("the put answered %v", shown)
	}
	r.f.navigated()
	isCall := func(m map[string]any) bool { return m["t"] == "call" }
	r.f.frame("S1", "F2", "M1", reservedOrigin)
	for _, c := range []struct {
		what, kind, method, path, frame string
	}{
		{"a form submitted into a frame of the put", "Document", "POST", "/_f/v1/invoke", "F2"},
		{"a form submitted into the page", "Document", "POST", "/_f/v1/action", "M1"},
		{"a navigation of a frame to a call path", "Document", "GET", "/_f/v1/invoke", "F2"},
		{"a beacon", "Ping", "POST", "/_f/v1/invoke", "M1"},
	} {
		if a := r.f.answer(r.f.pauseAs("S1", c.kind, c.method, reservedOrigin+c.path, c.frame, true, `{"from":"form"}`)); a.method != "Fetch.fulfillRequest" || a.status != 404 {
			t.Errorf("%s was answered %+v, not 404", c.what, a)
		}
	}
	r.h.quiet(isCall, "a navigation went up as a call")
	for n, c := range []struct{ kind, frame string }{{"Fetch", "F2"}, {"XHR", "M1"}} {
		r.f.pauseAs("S1", c.kind, "POST", reservedOrigin+"/_f/v1/invoke", c.frame, true, `{"from":"script"}`)
		if call := r.h.take(isCall, c.kind+"'s call"); call["id"] != float64(n+1) || bodyOf(call) != `{"from":"script"}` {
			t.Fatalf("a %s from a document of the put went up as %v", c.kind, call)
		}
	}
}

// A show that fails leaves its window as it was before it was tried: the
// earlier put's page and files while the window still shows that page,
// no put once it shows another, and nothing of the failed put either way.
func TestAFailedShowLeavesItsWindowAsItWas(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	if got := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); got["ok"] == nil {
		t.Fatal(got)
	}
	r.f.navigated()
	fetched := func(path string) pageAnswer {
		t.Helper()
		return r.f.answer(r.f.pause("S1", "GET", reservedOrigin+path, "M1", true, ""))
	}
	replacement := []siteFile{{"index.html", "text/html", "NEW SECRET"}, {"app.js", "text/javascript", "window.ran = 2"}}

	// Chrome gives the navigation up and the earlier page stays.
	r.f.fail(reservedOrigin+testRoot+"/aborted", navFail{errorText: "net::ERR_ABORTED"})
	if got := r.h.put(2, "thr_01", testRoot+"/aborted", "index.html", replacement, 64); got["error"] == nil {
		t.Fatalf("a put whose navigation was given up answered %v", got)
	}
	if a := fetched(testRoot + "/aborted"); a.status != 404 {
		t.Fatalf("the failed put's entry was answered %d %q", a.status, a.body)
	}
	if a := fetched(testRoot + "/app.js"); a.status != 200 || string(a.body) != "window.ran = 1" {
		t.Fatalf("the earlier put's file was answered %+v after a failed show", a)
	}

	// A put of the same root as the page it replaces fails: the earlier
	// files stay, not the failed put's of the same names.
	r.f.fail(reservedOrigin+testRoot, navFail{errorText: "net::ERR_ABORTED"})
	if got := r.h.put(3, "thr_01", testRoot, "index.html", replacement, 64); got["error"] == nil {
		t.Fatalf("a put of the same root answered %v", got)
	}
	if a := fetched(testRoot + "/app.js"); a.status != 200 || string(a.body) != "window.ran = 1" {
		t.Fatalf("a failed put of the same root left %+v", a)
	}

	// Chrome commits its error page: the window shows the earlier page no
	// more, and has no put.
	r.f.fail(reservedOrigin+testRoot, navFail{errorText: "net::ERR_FAILED", commit: "chrome-error://chromewebdata/"})
	if got := r.h.put(4, "thr_01", testRoot, "index.html", replacement, 64); got["error"] == nil {
		t.Fatalf("a put whose navigation ended at the error page answered %v", got)
	}
	if a := fetched(testRoot + "/app.js"); a.method != "Fetch.failRequest" {
		t.Fatalf("a window showing the error page was answered %+v", a)
	}
}

// A show that fails after its entry's navigation was answered, waiting for
// its load, ends its put: the window serves nothing of it, whether its
// commit was taken before the failure or after, and a call its document
// made ends with it.
func TestAShowThatFailsAfterItsCommitEndsItsPut(t *testing.T) {
	for _, late := range []bool{false, true} {
		r := newPageRig(t)
		if got := r.h.put(1, "thr_01", testRoot+"/first", "index.html", testSite, 64); got["ok"] == nil {
			t.Fatal(got)
		}
		r.f.navigated()
		r.f.fail(reservedOrigin+testRoot, navFail{hangs: true, late: late})
		p := &put{root: testRoot, entry: "index.html", files: map[string]putFile{
			"index.html": {typ: "text/html", data: []byte("<p>put")}, "app.js": {typ: "text/javascript", data: []byte("window.ran = 3")}}}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		shown := make(chan error, 1)
		go func() {
			_, err := r.b.run(ctx, request{Win: "thr_01", Op: "page", put: p})
			shown <- err
		}()
		nav := r.f.navigated()
		var id any
		if !late {
			r.f.pause("S1", "POST", reservedOrigin+"/_f/v1/invoke", "M1", true, `{}`)
			id = r.h.take(func(m map[string]any) bool { return m["t"] == "call" }, "the committed document's call")["id"]
		}
		if err := <-shown; err == nil {
			t.Fatal("a show whose load never came answered no error")
		}
		cancel()
		if late {
			r.f.commitOnly("S1", reservedOrigin+testRoot, "L"+nav.request)
		} else if m := r.h.take(func(m map[string]any) bool { return m["t"] == "callend" }, "the failed put's callend"); m["id"] != id {
			t.Errorf("the failed put's show ended call %v, want %v", m["id"], id)
		}
		if a := r.f.answer(r.f.pause("S1", "GET", reservedOrigin+testRoot+"/app.js", "M1", true, "")); a.method != "Fetch.failRequest" {
			t.Errorf("a put whose show failed after its navigation was answered, its commit taken late %v, answered %+v", late, a)
		}
		r.close()
	}
}

// A show that fails after its put committed, on the read of where its
// window is, ends its put as a failed load does: the window serves
// nothing of it.
func TestAShowWhoseHistoryReadFailsEndsItsPut(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	if got := r.h.put(1, "thr_01", testRoot+"/first", "index.html", testSite, 64); got["ok"] == nil {
		t.Fatal(got)
	}
	r.f.navigated()
	r.f.mu.Lock()
	r.f.historyError = true
	r.f.mu.Unlock()
	if got := r.h.put(2, "thr_01", testRoot, "index.html", testSite, 64); got["error"] == nil {
		t.Fatalf("a put whose history read failed answered %v", got)
	}
	r.f.navigated()
	a := r.f.answer(r.f.pause("S1", "GET", reservedOrigin+testRoot+"/app.js", "M1", true, ""))
	if a.method != "Fetch.failRequest" {
		t.Fatalf("a put whose history read failed served its file: %+v", a)
	}
}

// A put ends when its window's main frame commits a document that is not
// one of its files, whoever navigated it, with the calls of its documents;
// a navigation between its own files keeps it.
func TestAPutEndsWhenItsWindowLeavesIt(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	site := append([]siteFile{{"two.html", "text/html", "<title>Two</title><script src=app.js></script>"}}, testSite...)
	if got := r.h.put(1, "thr_01", testRoot, "index.html", site, 64); got["ok"] == nil {
		t.Fatal(got)
	}
	r.f.navigated()
	isCall := func(m map[string]any) bool { return m["t"] == "call" }
	isEnd := func(m map[string]any) bool { return m["t"] == "callend" }
	fetched := func() pageAnswer {
		t.Helper()
		return r.f.answer(r.f.pause("S1", "GET", reservedOrigin+testRoot+"/app.js", "M1", true, ""))
	}
	call := func() int64 {
		t.Helper()
		r.f.pause("S1", "POST", reservedOrigin+"/_f/v1/invoke", "M1", true, `{}`)
		return int64(r.h.take(isCall, "a call")["id"].(float64))
	}

	// A link to another of its pages: the put stands, and the calls of the
	// document it left end.
	id := call()
	if a := r.f.answer(r.f.link("S1", reservedOrigin+testRoot+"/two.html")); a.status != 200 || string(a.body) != site[0].body {
		t.Fatalf("a link to another page of the put was answered %+v", a)
	}
	if m := r.h.take(isEnd, "the left document's callend"); m["id"] != float64(id) {
		t.Fatalf("the driver ended %v, want %d", m["id"], id)
	}
	if a := fetched(); a.status != 200 {
		t.Fatalf("after a link within the put its file was answered %+v", a)
	}

	// A link to a path the put does not hold commits a document that is
	// none of its files.
	if a := r.f.answer(r.f.link("S1", reservedOrigin+testRoot+"/missing.html")); a.status != 404 {
		t.Fatalf("a link to a path the put does not hold was answered %+v", a)
	}
	if a := fetched(); a.method != "Fetch.failRequest" {
		t.Fatalf("after its window committed no file of it, the put was answered %+v", a)
	}

	// A link to another site.
	if got := r.h.put(2, "thr_01", testRoot, "index.html", site, 64); got["ok"] == nil {
		t.Fatal(got)
	}
	r.f.navigated()
	id = call()
	r.f.link("S1", "https://example.com/")
	if m := r.h.take(isEnd, "the callend of the page left for another site"); m["id"] != float64(id) {
		t.Fatalf("the driver ended %v, want %d", m["id"], id)
	}
	if a := fetched(); a.method != "Fetch.failRequest" {
		t.Fatalf("after navigation to another site, the old put answered %d %q", a.status, a.body)
	}
	r.h.quiet(isCall, "a call went up after the put ended")
}

// A call names the put its document belongs to, from the commit of that
// put's entry, before its load and so before the put is answered: on a
// window's first put, and while a put replaces another, where the earlier
// put's document names the earlier put until the new entry commits, and
// the new document the new put.
func TestACallNamesThePutItsDocumentBelongsTo(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	isCall := func(m map[string]any) bool { return m["t"] == "call" }
	call := func(what string) map[string]any {
		t.Helper()
		request := r.f.pause("S1", "POST", reservedOrigin+"/_f/v1/invoke", "M1", true, `{}`)
		m := r.h.take(isCall, what)
		r.h.send(map[string]any{"t": "answer", "id": m["id"], "status": 200, "body": "{}"})
		if a := r.f.answer(request); a.status != 200 {
			t.Fatalf("%s was answered %+v", what, a)
		}
		return m
	}
	unanswered := func(id int) {
		t.Helper()
		isResponse := func(m map[string]any) bool { return m["t"] == "res" && m["id"] == float64(id) }
		for _, m := range r.h.held {
			if isResponse(m) {
				t.Fatalf("put %d was answered before its load: %v", id, m)
			}
		}
		r.h.quiet(isResponse, fmt.Sprintf("put %d was answered before its load", id))
	}
	// Each put's entry is answered at once and commits only when the test
	// says, with its load after that.
	start := func(id int, root string) pageAnswer {
		t.Helper()
		r.f.fail(reservedOrigin+root, navFail{hangs: true, late: true})
		r.h.sendPut(id, "thr_01", root, "index.html", testSite, 64)
		return r.f.navigated()
	}
	load := func(id int, root string, nav pageAnswer) {
		t.Helper()
		r.f.event("S1", "Page.lifecycleEvent", map[string]any{"frameId": "M1", "loaderId": "L" + nav.request, "name": "load"})
		if got := r.h.response(id); !jsonEqual(got, `{"ok":{"url":"`+reservedOrigin+root+`","title":"Put"}}`) {
			t.Fatalf("put %d answered %v", id, got)
		}
	}

	first := start(1, testRoot+"/first")
	r.f.commitOnly("S1", reservedOrigin+testRoot+"/first", "L"+first.request)
	if m := call("the first put's call before its load"); !jsonEqual(m, `{"t":"call","id":1,"win":"thr_01","put":1,"op":"invoke","body":"e30="}`) {
		t.Fatalf("a call of the first put's document before its load went up as %v", m)
	}
	unanswered(1)
	load(1, testRoot+"/first", first)

	second := start(2, testRoot)
	if m := call("the earlier put's call while another is shown"); !jsonEqual(m, `{"t":"call","id":2,"win":"thr_01","put":1,"op":"invoke","body":"e30="}`) {
		t.Fatalf("a call of the earlier put's document while the next put loads went up as %v", m)
	}
	r.f.commitOnly("S1", reservedOrigin+testRoot, "L"+second.request)
	if m := call("the new put's call before its load"); !jsonEqual(m, `{"t":"call","id":3,"win":"thr_01","put":2,"op":"invoke","body":"e30="}`) {
		t.Fatalf("a call of the new put's document before its load went up as %v", m)
	}
	unanswered(2)
	load(2, testRoot, second)
	r.h.quiet(func(m map[string]any) bool { return m["t"] == "callend" }, "an answered call was ended")
}

// A frame of another process that Chrome refuses to name as the browser
// it is never runs, and the window's next action says why; the window
// itself is named before anything loads in it.
func TestAFrameThatCannotBeNamedNeverRuns(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	r.b.agent = map[string]any{"userAgent": "Mozilla/5.0 Chrome/156.0.8078.79"}
	r.f.mu.Lock()
	r.f.refuseChildNaming = true
	r.f.mu.Unlock()
	if shown := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); shown["ok"] == nil {
		t.Fatalf("the put answered %v", shown)
	}
	r.f.navigated()
	frame := r.f.attach("S1", "iframe")
	select {
	case run := <-r.f.runs:
		t.Fatalf("%s ran though the frame %s was not named", run, frame)
	case <-time.After(300 * time.Millisecond):
	}
	r.h.send(map[string]any{"t": "req", "id": 2, "win": "thr_01", "op": "read", "args": map[string]any{}})
	read := r.h.response(2)
	failure, _ := read["error"].(map[string]any)
	if failure["code"] != "unnamed" {
		t.Fatalf("the window's next action answered %v", read)
	}
}

// twoPuts shows put A at testRoot, then starts a show of put B at the
// same root whose entry is answered at once and commits only when the test
// says; A and B hold different bytes at one path, same.txt. It answers the
// rig, the loaders of A's and B's documents, and the show's end, which
// fails once timeout passes with no commit.
func twoPuts(t *testing.T, timeout time.Duration) (r *pageRig, a, b string, shown chan error) {
	t.Helper()
	r = newPageRig(t)
	files := []siteFile{{"index.html", "text/html", "<title>A</title>"}, {"same.txt", "text/plain", "A's bytes"}}
	if got := r.h.put(1, "thr_01", testRoot, "index.html", files, 64); got["ok"] == nil {
		t.Fatal(got)
	}
	a = "L" + r.f.navigated().request
	r.f.fail(reservedOrigin+testRoot, navFail{hangs: true, late: true})
	p := &put{id: 2, root: testRoot, entry: "index.html", files: map[string]putFile{
		"index.html": {typ: "text/html", data: []byte("<title>B</title>")},
		"same.txt":   {typ: "text/plain", data: []byte("B's bytes")}}}
	shown = make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		_, err := r.b.run(ctx, request{Win: "thr_01", Op: "page", put: p})
		shown <- err
	}()
	b = "L" + r.f.navigated().request
	return r, a, b, shown
}

const sameFile = reservedOrigin + testRoot + "/same.txt"

// A page's file is answered from the put of the document that made it, as
// Chrome names that document, however its request, the request's report
// and the commit of the next put's entry are ordered; a document of
// neither put is answered nothing.
func TestAFileIsAnsweredFromThePutOfTheDocumentThatMadeIt(t *testing.T) {
	bytesOf := func(a pageAnswer) string {
		if a.method != "Fetch.fulfillRequest" {
			return "nothing"
		}
		return fmt.Sprintf("%d %s", a.status, a.body)
	}
	get := func(r *pageRig, loader string, before bool) string {
		return r.f.pauseFrom("S1", "Fetch", "GET", sameFile, "M1", true, "", loader, before)
	}
	for _, c := range []struct {
		what string
		run  func(r *pageRig, a, b string, shown chan error) pageAnswer
		want string
	}{
		{"the new document's request, paused before its commit is reported", func(r *pageRig, a, b string, shown chan error) pageAnswer {
			id := get(r, b, true)
			r.f.commit("S1", reservedOrigin+testRoot, b)
			return r.f.answer(id)
		}, "200 B's bytes"},
		{"the new document's request, reported after its pause and before its commit", func(r *pageRig, a, b string, shown chan error) pageAnswer {
			id := get(r, b, false)
			r.f.none("a request whose document is not yet named")
			r.f.report("S1", id, "GET", sameFile, b)
			return r.f.answer(id)
		}, "200 B's bytes"},
		{"the earlier document's request, paused after the next entry was answered and live across its commit", func(r *pageRig, a, b string, shown chan error) pageAnswer {
			id := get(r, a, true)
			r.f.commit("S1", reservedOrigin+testRoot, b)
			return r.f.answer(id)
		}, "200 A's bytes"},
		{"the new document's request, its show ending with no commit", func(r *pageRig, a, b string, shown chan error) pageAnswer {
			id := get(r, b, true)
			if err := <-shown; err == nil {
				t.Error("a show whose entry never committed answered no error")
			}
			return r.f.answer(id)
		}, "200 B's bytes"},
		{"the earlier document's request, reported only after the next put's commit", func(r *pageRig, a, b string, shown chan error) pageAnswer {
			id := get(r, a, false)
			r.f.commit("S1", reservedOrigin+testRoot, b)
			if err := <-shown; err != nil {
				t.Errorf("the put answered %v", err)
			}
			r.f.report("S1", id, "GET", sameFile, a)
			return r.f.answer(id)
		}, "nothing"},
		{"the new document's request, its show ending on a load reported before its commit", func(r *pageRig, a, b string, shown chan error) pageAnswer {
			r.f.event("S1", "Page.lifecycleEvent", map[string]any{"frameId": "M1", "loaderId": b, "name": "load"})
			if err := <-shown; err != nil {
				t.Errorf("the put answered %v", err)
			}
			r.f.commitOnly("S1", reservedOrigin+testRoot, b)
			return r.f.answer(get(r, b, true))
		}, "200 B's bytes"},
		{"a request of a document of neither put", func(r *pageRig, a, b string, shown chan error) pageAnswer {
			return r.f.answer(get(r, "Lnobody", true))
		}, "nothing"},
	} {
		r, a, b, shown := twoPuts(t, time.Second)
		if got := bytesOf(c.run(r, a, b, shown)); got != c.want {
			t.Errorf("%s was answered %s, want %s", c.what, got, c.want)
		}
		r.close()
	}
}

// A request whose document Chrome names nowhere, as a dedicated worker's
// is, is answered while the window has one put it can belong to, and waits
// while a show's entry is answered and its commit not taken, for the put
// that stands after.
func TestARequestNoDocumentNamesWaitsForTheShow(t *testing.T) {
	for _, commits := range []bool{true, false} {
		r, _, b, shown := twoPuts(t, time.Second)
		id := r.f.pause("S1", "GET", sameFile, "M1", false, "")
		r.f.none("a worker's request while a show loads")
		want := "A's bytes"
		if commits {
			r.f.commit("S1", reservedOrigin+testRoot, b)
			want = "B's bytes"
		}
		err := <-shown
		if a := r.f.answer(id); a.status != 200 || string(a.body) != want {
			t.Errorf("a worker's request across a show that committed %v (%v) was answered %d %q, want %q",
				commits, err, a.status, a.body, want)
		}
		if a := r.f.answer(r.f.pause("S1", "GET", sameFile, "M1", false, "")); a.status != 200 || string(a.body) != want {
			t.Errorf("a worker's request with no show loading was answered %d %q, want %q", a.status, a.body, want)
		}
		r.close()
	}
}

// lockedLog is a driver's log a test reads.
type lockedLog struct {
	mu   sync.Mutex
	text bytes.Buffer
}

func (l *lockedLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.text.Write(p)
}

func (l *lockedLog) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.text.String()
}

// At most maxWaiting requests wait in a window: one past that is refused
// at once, which the driver's log says once, and those that waited are
// answered when what they wait for comes.
func TestWaitingRequestsAreBounded(t *testing.T) {
	r, _, b, shown := twoPuts(t, 5*time.Second)
	defer r.close()
	log := &lockedLog{}
	r.b.log = log
	var waited []string
	for range maxWaiting {
		waited = append(waited, r.f.pause("S1", "GET", sameFile, "M1", false, ""))
	}
	for range 2 {
		if a := r.f.answer(r.f.pause("S1", "GET", sameFile, "M1", false, "")); a.method != "Fetch.failRequest" {
			t.Fatalf("a request past the bound was answered %+v", a)
		}
	}
	if lines := strings.Count(log.String(), "\n"); lines != 1 || !strings.Contains(log.String(), "window thr_01") {
		t.Errorf("the driver's log said %q of the bound, want one line naming the window", log.String())
	}
	r.f.commit("S1", reservedOrigin+testRoot, b)
	for _, id := range waited {
		if a := r.f.answer(id); a.status != 200 || string(a.body) != "B's bytes" {
			t.Fatalf("a request that waited was answered %d %q", a.status, a.body)
		}
	}
	if err := <-shown; err != nil {
		t.Errorf("the put answered %v", err)
	}
}

const callPath = reservedOrigin + "/_f/v1/invoke"

// callFrom pauses a script's call on the main frame as the document of
// loader made it, reported before its pause when before is set.
func callFrom(r *pageRig, loader string, before bool) string {
	return r.f.pauseFrom("S1", "Fetch", "POST", callPath, "M1", true, `{"from":"page"}`, loader, before)
}

// A call goes up for the put of the document that made it, as Chrome names
// that document, once, and for no other. Its document's commit is taken
// before its report on the page's session, as Chrome sends them; a call
// paused and reported before that commit, of a later put's document or of
// the same put's next page, is refused, as are the earlier document's call
// known only after the commit and a call that names no document.
//
// Chrome does not send a call's report before its document's commit: the
// image's Chromium 156 reported none of 1,809 calls first, over 900
// navigations within one put by link, reload and form, each new document
// and its frame calling as they started. These orders are forced here
// only to show what the driver does if they came.
func TestACallGoesUpForTheDocumentThatMadeIt(t *testing.T) {
	isCall := func(m map[string]any) bool { return m["t"] == "call" }
	refused := func(t *testing.T, r *pageRig, id, what string) {
		t.Helper()
		if a := r.f.answer(id); a.method != "Fetch.failRequest" {
			t.Errorf("%s was answered %+v, not refused", what, a)
		}
		r.h.quiet(isCall, what+" went up")
	}
	t.Run("a later put's document's call before its commit", func(t *testing.T) {
		r, _, b, shown := twoPuts(t, 5*time.Second)
		defer r.close()
		refused(t, r, callFrom(r, b, true), "the shown document's call before its commit")
		r.f.commit("S1", reservedOrigin+testRoot, b)
		if err := <-shown; err != nil {
			t.Errorf("the put answered %v", err)
		}
		r.f.pause("S1", "POST", callPath, "M1", true, `{"from":"page"}`)
		if m := r.h.take(isCall, "the committed document's call"); !jsonEqual(m, `{"t":"call","id":1,"win":"thr_01","put":2,"op":"invoke","body":"eyJmcm9tIjoicGFnZSJ9"}`) {
			t.Errorf("the committed document's call went up as %v", m)
		}
		r.h.quiet(isCall, "a call went up twice")
	})
	t.Run("the same put's next page's call before its commit", func(t *testing.T) {
		r := newPageRig(t)
		defer r.close()
		site := append([]siteFile{{"two.html", "text/html", "<title>Two</title>"}}, testSite...)
		if got := r.h.put(1, "thr_01", testRoot, "index.html", site, 64); got["ok"] == nil {
			t.Fatal(got)
		}
		r.f.navigated()
		link := r.f.linkLate("S1", reservedOrigin+testRoot+"/two.html")
		if a := r.f.answer(link); a.status != 200 {
			t.Fatalf("a link to another page of the put was answered %+v", a)
		}
		refused(t, r, callFrom(r, "L"+link, true), "the next page's call before its commit")
		r.f.commit("S1", reservedOrigin+testRoot+"/two.html", "L"+link)
		callFrom(r, "L"+link, true)
		if m := r.h.take(isCall, "the next page's call after its commit"); m["put"] != float64(1) {
			t.Errorf("the next page's call went up as %v", m)
		}
	})
	t.Run("the earlier document's call reported after the commit", func(t *testing.T) {
		r, a, b, shown := twoPuts(t, 5*time.Second)
		defer r.close()
		id := callFrom(r, a, false)
		r.f.commit("S1", reservedOrigin+testRoot, b)
		if err := <-shown; err != nil {
			t.Errorf("the put answered %v", err)
		}
		r.f.report("S1", id, "POST", callPath, a)
		refused(t, r, id, "the earlier document's call across the commit")
	})
	t.Run("a call that names no document", func(t *testing.T) {
		r, _, _, _ := twoPuts(t, 5*time.Second)
		defer r.close()
		refused(t, r, r.f.pauseFrom("S1", "Fetch", "POST", callPath, "M1", false, `{}`, "", true), "a worker's call")
		refused(t, r, callFrom(r, "", true), "a call whose report names no document")
	})
}

// A call waits for its own report alone, within the window's bound: one
// past it is refused, and those that waited go up once each when their
// reports come.
func TestWaitingCallsAreBounded(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	if got := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); got["ok"] == nil {
		t.Fatal(got)
	}
	loader := "L" + r.f.navigated().request
	log := &lockedLog{}
	r.b.log = log
	isCall := func(m map[string]any) bool { return m["t"] == "call" }
	var waited []string
	for range maxWaiting {
		waited = append(waited, callFrom(r, loader, false))
	}
	if a := r.f.answer(callFrom(r, loader, false)); a.method != "Fetch.failRequest" {
		t.Fatalf("a call past the bound was answered %+v", a)
	}
	if lines := strings.Count(log.String(), "\n"); lines != 1 {
		t.Errorf("the driver's log said %q of the bound, want one line", log.String())
	}
	r.h.quiet(isCall, "a call went up before its report")
	for _, id := range waited {
		r.f.report("S1", id, "POST", callPath, loader)
	}
	seen := map[float64]bool{}
	for range maxWaiting {
		m := r.h.take(isCall, "a call that waited")
		if m["put"] != float64(1) || seen[m["id"].(float64)] {
			t.Fatalf("a call that waited went up as %v", m)
		}
		seen[m["id"].(float64)] = true
	}
	r.h.quiet(isCall, "a call went up twice")
}

// A call goes up only while the document that made it is its frame's
// document now: the earlier document's call of a main frame that went on
// to another page of the same put, or of a frame that went away and came
// back, is refused, its report before its pause or after.
func TestACallGoesUpOnlyWhileItsDocumentStands(t *testing.T) {
	isCall := func(m map[string]any) bool { return m["t"] == "call" }
	site := append([]siteFile{{"two.html", "text/html", "<title>Two</title>"}}, testSite...)
	for _, before := range []bool{true, false} {
		t.Run(fmt.Sprintf("reported before its pause %v", before), func(t *testing.T) {
			r := newPageRig(t)
			defer r.close()
			if got := r.h.put(1, "thr_01", testRoot, "index.html", site, 64); got["ok"] == nil {
				t.Fatal(got)
			}
			first := "L" + r.f.navigated().request
			if a := r.f.answer(r.f.link("S1", reservedOrigin+testRoot+"/two.html")); a.status != 200 {
				t.Fatalf("a link to another page of the put was answered %+v", a)
			}
			id := callFrom(r, first, before)
			if !before {
				r.f.report("S1", id, "POST", callPath, first)
			}
			if a := r.f.answer(id); a.method != "Fetch.failRequest" {
				t.Errorf("the call of the page the main frame left was answered %+v", a)
			}
			r.f.frame("S1", "F2", "M1", reservedOrigin)
			r.f.mu.Lock()
			left := r.f.loaders["F2"]
			r.f.mu.Unlock()
			r.f.frame("S1", "F2", "M1", "https://example.com")
			r.f.frame("S1", "F2", "M1", reservedOrigin)
			id = r.f.pauseFrom("S1", "Fetch", "POST", callPath, "F2", true, `{}`, left, before)
			if !before {
				r.f.report("S1", id, "POST", callPath, left)
			}
			if a := r.f.answer(id); a.method != "Fetch.failRequest" {
				t.Errorf("the call of the document a frame left and came back from was answered %+v", a)
			}
			r.h.quiet(isCall, "a departed document's call went up")
		})
	}
}

// A request whose report came before its document's put was replaced is
// refused when it pauses after, a file's and a call's, never left waiting.
func TestALatePauseOfAReportedRequestIsRefused(t *testing.T) {
	r, a, b, shown := twoPuts(t, 5*time.Second)
	defer r.close()
	call, file := r.f.newRequest(), r.f.newRequest()
	r.f.report("S1", call, "POST", callPath, a)
	r.f.report("S1", file, "GET", sameFile, a)
	r.f.commit("S1", reservedOrigin+testRoot, b)
	if err := <-shown; err != nil {
		t.Fatalf("the put answered %v", err)
	}
	r.f.pauseWith(call, "S1", "Fetch", "POST", callPath, "M1", map[string]string{"Origin": reservedOrigin}, true, `{}`)
	r.f.pauseWith(file, "S1", "Fetch", "GET", sameFile, "M1", map[string]string{}, true, "")
	for _, id := range []string{call, file} {
		if got := r.f.answer(id); got.method != "Fetch.failRequest" {
			t.Errorf("the replaced document's request %s was answered %+v", id, got)
		}
	}
}

// A call to a call's path with a query is a call, its report and its pause
// read alike; a call whose Content-Length is past the bound is 413 before
// its body is read; and a call of the first put's document goes up once
// its commit is taken, and is refused before, as a later put's is.
func TestACallsPathLengthAndFirstShow(t *testing.T) {
	isCall := func(m map[string]any) bool { return m["t"] == "call" }
	t.Run("a call with a query", func(t *testing.T) {
		r := newPageRig(t)
		defer r.close()
		if got := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); got["ok"] == nil {
			t.Fatal(got)
		}
		r.f.navigated()
		r.f.pause("S1", "POST", callPath+"?from=query", "M1", true, `{}`)
		if m := r.h.take(isCall, "a call with a query"); m["put"] != float64(1) {
			t.Errorf("a call with a query went up as %v", m)
		}
	})
	t.Run("a Content-Length past the bound", func(t *testing.T) {
		r := newPageRig(t)
		defer r.close()
		if got := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); got["ok"] == nil {
			t.Fatal(got)
		}
		r.f.navigated()
		r.f.mu.Lock()
		loader := r.f.loaders["M1"]
		r.f.mu.Unlock()
		id := r.f.newRequest()
		r.f.report("S1", id, "POST", callPath, loader)
		r.f.pauseWith(id, "S1", "Fetch", "POST", callPath, "M1", map[string]string{"Origin": reservedOrigin,
			"Content-Length": strconv.Itoa(maxCallBody + 1)}, true, `{}`)
		if a := r.f.answer(id); a.status != 413 {
			t.Errorf("a call whose Content-Length is past the bound was answered %+v", a)
		}
		r.h.quiet(isCall, "a call past the bound went up")
	})
	t.Run("the first put's call before its commit", func(t *testing.T) {
		r := newPageRig(t)
		defer r.close()
		r.f.fail(reservedOrigin+testRoot, navFail{hangs: true, late: true})
		r.h.sendPut(1, "thr_01", testRoot, "index.html", testSite, 64)
		loader := "L" + r.f.navigated().request
		r.f.mu.Lock()
		r.f.callerOrigin["M1"] = reservedOrigin
		r.f.mu.Unlock()
		// An order Chrome does not send (TestACallGoesUpForTheDocumentThatMadeIt):
		// it is refused.
		if a := r.f.answer(callFrom(r, loader, true)); a.method != "Fetch.failRequest" {
			t.Errorf("the first put's call before its commit was answered %+v", a)
		}
		r.h.quiet(isCall, "the first put's call went up before its commit")
		r.f.commit("S1", reservedOrigin+testRoot, loader)
		callFrom(r, loader, true)
		if m := r.h.take(isCall, "the first put's call after its commit"); m["put"] != float64(1) {
			t.Errorf("the first put's call went up as %v", m)
		}
	})
}

// A call is admitted by the origin it is made with, its Origin header,
// which a script cannot set: a sandboxed frame of a put's file calls as an
// opaque origin, and its call is refused.
func TestASandboxedFramesCallIsRefused(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	if got := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); got["ok"] == nil {
		t.Fatal(got)
	}
	r.f.navigated()
	r.f.frame("S1", "F6", "M1", reservedOrigin)
	r.f.mu.Lock()
	r.f.callerOrigin["F6"] = "null"
	r.f.mu.Unlock()
	if a := r.f.answer(r.f.pause("S1", "POST", callPath, "F6", true, `{}`)); a.method != "Fetch.failRequest" {
		t.Errorf("a sandboxed frame's call was answered %+v", a)
	}
	r.h.quiet(func(m map[string]any) bool { return m["t"] == "call" }, "a sandboxed frame's call went up")
}

// A window a page opens, which Chrome attaches to the browser's own
// attachment with its opener named, is named before it runs, and belongs
// to its opener's window: its requests for the reserved origin are failed
// and none of its calls goes up, as for any target of the window that is
// not one of its frames. A window that one opens belongs to the same
// window. Neither is a window of the driver's: the driver's windows stay
// as they were, and one of them ending forgets nothing else. A window the
// driver made itself, which the attachment reports with no opener, and a
// shared worker are let run, the worker once it is named.
func TestAWindowAPageOpensIsNamedBeforeItRuns(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	r.b.agent = map[string]any{"userAgent": "Mozilla/5.0 Chrome/156.0.8078.79"}
	if shown := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); shown["ok"] == nil {
		t.Fatalf("the put answered %v", shown)
	}
	r.f.navigated()
	popup := r.f.attachToBrowser("page", "T1")
	if run := ranWithin(t, r.f, "the window the page opened"); run != popup {
		t.Fatalf("%s ran in place of the window the page opened, %s", run, popup)
	}
	inner := r.f.attachToBrowser("page", "X"+popup)
	if run := ranWithin(t, r.f, "the window the opened window opened"); run != inner {
		t.Fatalf("%s ran in place of the window the opened window opened, %s", run, inner)
	}
	own := r.f.attachToBrowser("page", "")
	if run := ranWithin(t, r.f, "a window with no opener"); run != own {
		t.Fatalf("%s ran in place of a window with no opener, %s", run, own)
	}
	shared := r.f.attachToBrowser("shared_worker", "")
	if run := ranWithin(t, r.f, "the shared worker"); run != shared {
		t.Fatalf("%s ran in place of the shared worker %s", run, shared)
	}
	r.f.mu.Lock()
	order := strings.Join(r.f.order, ", ")
	r.f.mu.Unlock()
	for _, s := range []string{popup, inner, shared} {
		named, ran := strings.Index(order, "name "+s+","), strings.Index(order, "run "+s)
		if named < 0 || ran < 0 || named > ran {
			t.Fatalf("%s was not named before it ran: %s", s, order)
		}
	}
	if strings.Contains(order, "name "+own+",") {
		t.Fatalf("a window with no opener was named on the attachment's session: %s", order)
	}
	for _, s := range []string{popup, inner} {
		if a := r.f.answer(r.f.pause(s, "POST", reservedOrigin+"/_f/v1/invoke", "P"+s, true, `{"from":"popup"}`)); a.method != "Fetch.failRequest" {
			t.Fatalf("the call of the opened window %s was answered %+v, not failed", s, a)
		}
		if a := r.f.answer(r.f.pause(s, "GET", reservedOrigin+testRoot+"/app.js", "P"+s, true, "")); a.method != "Fetch.failRequest" {
			t.Fatalf("the opened window %s was answered %+v for a file of its opener's put", s, a)
		}
	}
	r.h.quiet(func(m map[string]any) bool { return m["t"] == "call" }, "a call of a window a page opened went up")
	r.f.write(map[string]any{"method": "Target.targetDestroyed", "params": map[string]any{"targetId": "X" + popup}})
	r.f.write(map[string]any{"method": "Target.detachedFromTarget", "params": map[string]any{"sessionId": popup, "targetId": "X" + popup}})
	r.h.send(map[string]any{"t": "req", "id": 2, "win": "thr_01", "op": "read", "args": map[string]any{}})
	// The read's answer comes after Chrome's events of the window's end, so
	// the driver has taken them by then; the fake answers no page read.
	if read := r.h.response(2); strings.Contains(fmt.Sprint(read), "no_window") {
		t.Fatalf("the window that opened a window that ended answered %v", read)
	}
	r.b.mu.Lock()
	windows, opened, opener := len(r.b.windows), len(r.b.opened), r.b.opened["X"+inner]
	r.b.mu.Unlock()
	if windows != 1 || opened != 1 || opener == nil || opener.name != "thr_01" {
		t.Fatalf("the driver holds %d windows and %d opened ones, the inner one of %v", windows, opened, opener)
	}
	r.f.mu.Lock()
	closed := r.f.closed
	r.f.mu.Unlock()
	if len(closed) != 0 {
		t.Fatalf("the driver closed %v", closed)
	}
}

// A window a page opens that Chrome refuses to name never runs: it is
// closed, and the window that opened it says so at its next action.
func TestAWindowAPageOpensThatCannotBeNamedIsClosed(t *testing.T) {
	r := newPageRig(t)
	defer r.close()
	r.b.agent = map[string]any{"userAgent": "Mozilla/5.0 Chrome/156.0.8078.79"}
	if shown := r.h.put(1, "thr_01", testRoot, "index.html", testSite, 64); shown["ok"] == nil {
		t.Fatalf("the put answered %v", shown)
	}
	r.f.navigated()
	r.f.mu.Lock()
	r.f.refuseChildNaming = true
	r.f.mu.Unlock()
	popup := r.f.attachToBrowser("page", "T1")
	select {
	case run := <-r.f.runs:
		t.Fatalf("%s ran though the window %s was not named", run, popup)
	case <-time.After(300 * time.Millisecond):
	}
	r.h.send(map[string]any{"t": "req", "id": 2, "win": "thr_01", "op": "read", "args": map[string]any{}})
	read := r.h.response(2)
	failure, _ := read["error"].(map[string]any)
	r.f.mu.Lock()
	closed := strings.Join(r.f.closed, " ")
	r.f.mu.Unlock()
	if failure["code"] != "unnamed" || closed != "X"+popup {
		t.Fatalf("the window's next action answered %v, and the driver closed %q", read, closed)
	}
}

// ranWithin answers the next target the driver let run, failing t when
// none runs within a few seconds.
func ranWithin(t *testing.T, f *pageChrome, what string) string {
	t.Helper()
	select {
	case run := <-f.runs:
		return run
	case <-time.After(5 * time.Second):
		t.Fatalf("%s was never let run", what)
		return ""
	}
}

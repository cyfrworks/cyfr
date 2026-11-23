// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"
)

// A page the driver shows is a put (C15): files the host hands over, which
// the driver answers the page's requests for the reserved origin from,
// with no server and no network, and calls the page makes there, which it
// passes up to the host. Every window has Chrome's request interception
// (the Fetch domain) on for the reserved origin before its first
// navigation, and so has every frame of another process inside it, as each
// attaches; a dedicated worker's requests are paused on the session of the
// frame that made it, and a service worker's, or any other target's that
// attaches to a window, are failed. Chrome itself never resolves the
// reserved name (quiet, main.go), so a request that no interception
// pauses, such as a socket's or a shared worker's, fails inside Chrome and
// reaches no network.
//
// A put stands from the commit of its entry in the window's main frame
// until that frame commits a document that is not one of its files,
// whoever navigated it, or the window closes; its files and the calls its
// documents made end together then (replace). A navigation between its
// own files keeps it.
const (
	reservedHost   = "cyfr.invalid"
	reservedOrigin = "https://" + reservedHost
	// The put's bound, its parts' size and a call's body: the vectors' put
	// and call.
	maxPutBytes = 32 << 20
	maxPutFiles = 1024
	partBytes   = 1 << 20
	maxCallBody = 64 << 10
)

var fetchPatterns = map[string]any{"patterns": []map[string]string{{"urlPattern": reservedOrigin + "/*"}}}

// callOps are the paths a page's call is posted to, and the op each names.
var callOps = map[string]string{"/_f/v1/invoke": "invoke", "/_f/v1/action": "action"}

// put is the files of one page, laid out under root: the entry at root and
// root/, each file at root/path; id is its `page` request's, which every
// call its documents make names. failed, guarded by its window's mu, marks
// a put whose show failed: it serves nothing and never stands.
type put struct {
	id          int64
	root, entry string
	files       map[string]putFile
	failed      bool
}

type putFile struct {
	typ  string
	data []byte
}

// lookup answers the file a request's decoded path names, or nil.
func (p *put) lookup(at string) *putFile {
	var name string
	switch {
	case at == p.root || at == p.root+"/":
		name = p.entry
	case strings.HasPrefix(at, p.root+"/"):
		name = at[len(p.root)+1:]
	default:
		return nil
	}
	if f, ok := p.files[name]; ok {
		return &f
	}
	return nil
}

// manifest is a put's `page` args, before its bytes arrive.
type manifest struct {
	Root  *string `json:"root"`
	Entry *string `json:"entry"`
	Files []struct {
		Path *string `json:"path"`
		Type *string `json:"type"`
		Size *int64  `json:"size"`
	} `json:"files"`
}

var errBadPut = badRequest("A page names its root, its entry among its files, and each file's path, type and size.")

// readManifest checks a put's args and answers the total of its sizes.
func readManifest(args json.RawMessage) (*manifest, int64, error) {
	var m manifest
	if len(args) == 0 || json.Unmarshal(args, &m) != nil || m.Root == nil || m.Entry == nil || len(m.Files) == 0 {
		return nil, 0, errBadPut
	}
	root := *m.Root
	if !strings.HasPrefix(root, "/") || root == "/" || path.Clean(root) != root {
		return nil, 0, errBadPut
	}
	if len(m.Files) > maxPutFiles {
		return nil, 0, &failure{"too_large", "The page holds more than the " + strconv.Itoa(maxPutFiles) + " files the browser takes."}
	}
	seen := make(map[string]bool, len(m.Files))
	var total int64
	for _, f := range m.Files {
		if f.Path == nil || f.Type == nil || f.Size == nil || *f.Size < 0 {
			return nil, 0, errBadPut
		}
		p := *f.Path
		if p == "" || strings.HasPrefix(p, "/") || path.Clean(p) != p || p == ".." || strings.HasPrefix(p, "../") || seen[p] {
			return nil, 0, errBadPut
		}
		seen[p] = true
		if total += *f.Size; total > maxPutBytes {
			return nil, 0, &failure{"too_large", "The page is larger than the " + strconv.Itoa(maxPutBytes>>20) + " MiB the browser takes."}
		}
	}
	if !seen[*m.Entry] {
		return nil, 0, errBadPut
	}
	return &m, total, nil
}

// assembly is a put whose parts are arriving.
type assembly struct {
	r     request
	m     *manifest
	total int64
	data  []byte
	next  int64
	at    time.Time
}

// puts gathers the puts' parts on the serve loop's goroutine and hands
// each put whose last part arrived whole to run.
type puts struct {
	s    *slot
	run  func(request)
	byID map[int64]*assembly
}

func newPuts(s *slot, run func(request)) *puts {
	return &puts{s: s, run: run, byID: map[int64]*assembly{}}
}

// start takes a `page` request: refused at once when its manifest is, run
// at once when it awaits no part, else held for its parts.
func (ps *puts) start(r request) error {
	m, total, err := readManifest(r.Args)
	if err == nil && (r.Of < 0 || r.Of < (total+partBytes-1)/partBytes) {
		err = badRequest("The page's parts cannot hold its files.")
	}
	if err != nil {
		return ps.s.ready(r.ID, answer(nil, err))
	}
	a := &assembly{r: r, m: m, total: total, data: make([]byte, 0, total), at: ps.s.now()}
	if r.Of == 0 {
		return ps.done(a)
	}
	ps.byID[r.ID] = a
	return nil
}

// part takes part seq of put id; a part of a put not held is passed over.
func (ps *puts) part(id, seq int64, data []byte, bad bool) error {
	a := ps.byID[id]
	if a == nil {
		return nil
	}
	if bad || seq != a.next || len(data) > partBytes || int64(len(a.data)+len(data)) > a.total {
		delete(ps.byID, id)
		return ps.s.ready(id, answer(nil, badRequest("The page's parts did not arrive in order, each within its bound and its files' sizes.")))
	}
	a.data = append(a.data, data...)
	a.next++
	a.at = ps.s.now()
	if a.next < a.r.Of {
		return nil
	}
	delete(ps.byID, id)
	return ps.done(a)
}

// done runs a put whose parts have all arrived, once its sizes add up.
func (ps *puts) done(a *assembly) error {
	if int64(len(a.data)) != a.total {
		return ps.s.ready(a.r.ID, answer(nil, badRequest("The page's parts do not add up to its files' sizes.")))
	}
	p := &put{id: a.r.ID, root: *a.m.Root, entry: *a.m.Entry, files: make(map[string]putFile, len(a.m.Files))}
	at := int64(0)
	for _, f := range a.m.Files {
		p.files[*f.Path] = putFile{typ: *f.Type, data: a.data[at : at+*f.Size : at+*f.Size]}
		at += *f.Size
	}
	a.r.put = p
	ps.run(a.r)
	return nil
}

// expire refuses every put whose next part has not come within keep, and
// keeps nothing of it.
func (ps *puts) expire() error {
	for id, a := range ps.byID {
		if ps.s.now().Sub(a.at) >= ps.s.keep {
			delete(ps.byID, id)
			if err := ps.s.ready(id, answer(nil, &failure{"timeout", "The page's parts stopped arriving."})); err != nil {
				return err
			}
		}
	}
	return nil
}

// show loads p's entry in w. Until the show ends, p answers only the
// main frame's navigations to its files and w keeps the put it had
// (serving); a commit of p's own entry makes p w's put (committed). A
// show that fails leaves w as it was, and p serves nothing after: one
// that failed after its entry committed ends p there, and one whose
// commit comes late finds p failed. Every return passes through the one
// deferred end, so no way of failing after p was staged misses it.
func (b *browser) show(ctx context.Context, w *window, p *put) (shown any, err error) {
	w.mu.Lock()
	w.next = p
	w.mu.Unlock()
	defer func() {
		w.mu.Lock()
		w.next = nil
		if err != nil {
			p.failed = true
		}
		stands := w.put == p
		w.mu.Unlock()
		if err != nil && stands {
			b.replace(w, nil)
		}
	}()
	entry := url.URL{Scheme: "https", Host: reservedHost, Path: p.root}
	if err = b.navigate(ctx, w, entry.String()); err != nil {
		return nil, err
	}
	return b.where(ctx, w)
}

// committed takes the document w's main frame committed under loader: the
// put whose file answered its navigation stands, and none other.
func (b *browser) committed(w *window, loader string) {
	w.mu.Lock()
	p := w.docs[loader]
	w.mu.Unlock()
	b.replace(w, p)
}

// replace makes p, or no put, w's files, and gives up every call w holds:
// the window's main frame shows another document, or the window has
// closed. Every end of a window's put and of its calls passes through
// here; a failed put is never made w's.
func (b *browser) replace(w *window, p *put) {
	w.mu.Lock()
	if p != nil && p.failed {
		p = nil
	}
	w.gen++
	w.put = p
	w.docs = nil
	w.mu.Unlock()
	b.pages <- pageEvent{win: w}
}

// current answers w's put and its generation, which a replace moves on.
func (w *window) current() (*put, int64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.put, w.gen
}

// serving answers the put a request for path is answered from, and w's
// generation. A GET navigation of the main frame takes the put being
// shown when that holds the file, else w's put, and is recorded by its
// network id as that put's document: Chrome commits the document under a
// loader of that id. Every other request takes w's put.
func (w *window) serving(navigation bool, network, path string) (*put, int64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	pt := w.put
	if navigation && w.next != nil && w.next.lookup(path) != nil {
		pt = w.next
	}
	if pt != nil && pt.failed {
		return nil, w.gen
	}
	if navigation && pt != nil && network != "" && pt.lookup(path) != nil {
		if w.docs == nil {
			w.docs = map[string]*put{}
		}
		w.docs[network] = pt
	}
	return pt, w.gen
}

// Kinds of the sessions a window's requests are paused on: its page's, or
// a frame's of another process inside it, which are answered from its put,
// or a target's of another kind, which is answered nothing.
const (
	sessionPage    = "page"
	sessionFrame   = "frame"
	sessionForeign = "foreign"
)

func intercepted(method string, _ json.RawMessage) bool {
	switch method {
	case "Fetch.requestPaused", "Target.attachedToTarget", "Target.detachedFromTarget", "Page.frameNavigated", "Page.frameDetached":
		return true
	}
	return false
}

// interceptOn turns on what a session of a window's frames needs before
// it loads anything: its frame events, its network's request ids, which
// a call is admitted by, the interception, and an attachment to every
// target it starts, each held until it is set up.
func (b *browser) interceptOn(ctx context.Context, session string) error {
	for _, step := range []struct {
		method string
		params any
	}{
		{"Page.enable", nil},
		{"Network.enable", map[string]any{"maxTotalBufferSize": 0, "maxResourceBufferSize": 0}},
		{"Fetch.enable", fetchPatterns},
		{"Target.setAutoAttach", map[string]any{"autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true}},
	} {
		if err := b.c.call(ctx, session, step.method, step.params, nil); err != nil {
			return err
		}
	}
	return nil
}

// serveSession answers what is paused on session, one of window w's, in
// the order Chrome reports it beside its frames' navigations, until the
// session ends; then it gives up the session's calls and ends the
// sessions it attached.
func (b *browser) serveSession(w *window, session, kind string, events *watch) {
	children := map[string]bool{}
	defer func() {
		b.c.unwatch(events)
		for child := range children {
			b.c.detach(child)
		}
		b.pages <- pageEvent{session: session}
	}()
	for {
		ev, err := events.next(context.Background())
		if err != nil {
			return
		}
		switch ev.method {
		case "Fetch.requestPaused":
			b.paused(w, session, kind, events, ev.params)
		case "Target.attachedToTarget":
			var attached struct {
				SessionID  string `json:"sessionId"`
				TargetInfo struct {
					Type string `json:"type"`
				} `json:"targetInfo"`
			}
			if json.Unmarshal(ev.params, &attached) == nil && attached.SessionID != "" {
				children[attached.SessionID] = true
				go b.attachChild(w, attached.SessionID, attached.TargetInfo.Type)
			}
		case "Target.detachedFromTarget":
			var detached struct {
				SessionID string `json:"sessionId"`
			}
			if json.Unmarshal(ev.params, &detached) == nil {
				delete(children, detached.SessionID)
			}
		case "Page.frameNavigated":
			var navigated struct {
				Frame struct {
					ID       string `json:"id"`
					ParentID string `json:"parentId"`
					LoaderID string `json:"loaderId"`
				} `json:"frame"`
			}
			if json.Unmarshal(ev.params, &navigated) == nil {
				if navigated.Frame.ParentID == "" && kind == sessionPage {
					b.committed(w, navigated.Frame.LoaderID)
				} else {
					b.pages <- pageEvent{session: session, frame: navigated.Frame.ID}
				}
			}
		case "Page.frameDetached":
			var detached struct {
				FrameID string `json:"frameId"`
			}
			if json.Unmarshal(ev.params, &detached) == nil {
				b.pages <- pageEvent{session: session, frame: detached.FrameID}
			}
		}
	}
}

// attachChild sets up a target that attached to one of w's sessions,
// held until it runs and named as every target is (agent.go): a frame of
// another process is intercepted as the
// window's frames are; a dedicated worker needs nothing, since its
// requests are paused on its frame's session; every other target's
// requests for the reserved origin are failed. Its session is served from
// before the first step, so whatever a step that took pauses is answered
// though a later step fail; what no step pauses fails inside Chrome.
func (b *browser) attachChild(w *window, session, kind string) {
	ctx, cancel := context.WithTimeout(context.Background(), opWait)
	defer cancel()
	// A service worker answers its network's commands only once it runs,
	// so it is named after it is let run; every other target before.
	if kind != "service_worker" {
		_ = b.name(ctx, session, kind)
	}
	switch kind {
	case "worker":
	case "iframe":
		go b.serveSession(w, session, sessionFrame, b.c.watch(session, intercepted))
		_ = b.interceptOn(ctx, session)
	default:
		go b.serveSession(w, session, sessionForeign, b.c.watch(session, intercepted))
		_ = b.c.call(ctx, session, "Fetch.enable", fetchPatterns, nil)
	}
	_ = b.c.call(ctx, session, "Runtime.runIfWaitingForDebugger", nil, nil)
	if kind == "service_worker" {
		_ = b.name(ctx, session, kind)
	}
}

type pausedRequest struct {
	RequestID string `json:"requestId"`
	Request   struct {
		URL             string `json:"url"`
		Method          string `json:"method"`
		PostData        string `json:"postData"`
		HasPostData     bool   `json:"hasPostData"`
		PostDataEntries []struct {
			Bytes *string `json:"bytes"`
		} `json:"postDataEntries"`
	} `json:"request"`
	FrameID      string `json:"frameId"`
	NetworkID    string `json:"networkId"`
	ResourceType string `json:"resourceType"`
}

// callTypes are the requests a call can be: what a document's script
// fetches. Chrome names such a request's frame as the frame of the
// document that made it, where a navigation's, a form's among them, is the
// frame it loads into.
var callTypes = map[string]bool{"Fetch": true, "XHR": true}

// paused answers one request for the reserved origin: a GET or HEAD from
// the window's files, a call to the host when it is admitted, anything
// else as nothing is there. A window with no put, and a session that is
// not one of its frames', is answered nothing.
func (b *browser) paused(w *window, session, kind string, events *watch, params json.RawMessage) {
	var p pausedRequest
	if json.Unmarshal(params, &p) != nil || p.RequestID == "" {
		return
	}
	u, err := url.Parse(p.Request.URL)
	if kind == sessionForeign || err != nil || u.Scheme+"://"+u.Host != reservedOrigin {
		go b.failPaused(session, p.RequestID)
		return
	}
	navigation := kind == sessionPage && p.ResourceType == "Document" && p.Request.Method == "GET" && p.FrameID == w.frame
	pt, gen := w.serving(navigation, p.NetworkID, u.Path)
	if pt == nil {
		go b.failPaused(session, p.RequestID)
		return
	}
	switch p.Request.Method {
	case "GET", "HEAD":
		f := pt.lookup(u.Path)
		if f == nil {
			go b.answerPaused(session, p.RequestID, 404, nil, nil)
			return
		}
		headers := map[string]string{"Content-Type": f.typ, "Cache-Control": "no-store"}
		body := f.data
		if p.Request.Method == "HEAD" {
			body = nil
		}
		go b.answerPaused(session, p.RequestID, 200, headers, body)
		return
	case "POST":
	default:
		go b.answerPaused(session, p.RequestID, 404, nil, nil)
		return
	}
	op := callOps[u.Path]
	if op == "" || !callTypes[p.ResourceType] {
		go b.answerPaused(session, p.RequestID, 404, nil, nil)
		return
	}
	if !b.admits(session, events, p) {
		go b.failPaused(session, p.RequestID)
		return
	}
	body, read := b.postBody(session, p)
	switch {
	case !read:
		go b.failPaused(session, p.RequestID)
	case len(body) > maxCallBody:
		go b.answerPaused(session, p.RequestID, 413, nil, nil)
	default:
		b.pages <- pageEvent{call: &heldCall{win: w, gen: gen, put: pt.id, session: session, request: p.RequestID,
			frame: p.FrameID, op: op, body: body}}
	}
}

type frameTree struct {
	Frame struct {
		ID             string `json:"id"`
		ParentID       string `json:"parentId"`
		SecurityOrigin string `json:"securityOrigin"`
	} `json:"frame"`
	ChildFrames []frameTree `json:"childFrames"`
}

func (t *frameTree) origin(id string) (string, bool) {
	if t.Frame.ID == id {
		return t.Frame.SecurityOrigin, true
	}
	for i := range t.ChildFrames {
		if origin, ok := t.ChildFrames[i].origin(id); ok {
			return origin, true
		}
	}
	return "", false
}

// admits says whether a script's POST paused on session (callTypes) came
// from a document of the reserved origin: the security origin of the frame
// it names, the frame of the document that made it, as the session's frame
// tree has it. A worker's request is paused on its frame's session with that
// frame's id, but carries no network id, since no worker's network is
// enabled; a frame's carries one. Chrome reports a navigation of the frame
// it made before it answered the tree ahead of the answer, so one queued
// then means the tree may show the next document, not the requester.
func (b *browser) admits(session string, events *watch, p pausedRequest) bool {
	if p.NetworkID == "" || p.FrameID == "" {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), opWait)
	defer cancel()
	var tree struct {
		FrameTree frameTree `json:"frameTree"`
	}
	if b.c.call(ctx, session, "Page.getFrameTree", nil, &tree) != nil {
		return false
	}
	if origin, ok := tree.FrameTree.origin(p.FrameID); !ok || origin != reservedOrigin {
		return false
	}
	return !events.queued(func(ev cdpEvent) bool {
		var e struct {
			FrameID string `json:"frameId"`
			Frame   struct {
				ID       string `json:"id"`
				ParentID string `json:"parentId"`
			} `json:"frame"`
		}
		if json.Unmarshal(ev.params, &e) != nil {
			return true
		}
		switch ev.method {
		case "Page.frameNavigated":
			return e.Frame.ID == p.FrameID || e.Frame.ParentID == ""
		case "Page.frameDetached":
			return e.FrameID == p.FrameID
		}
		return false
	})
}

// postBody is a paused POST's body, from the bytes the pause carries, else
// its text, else from Chrome; false when Chrome gives none.
func (b *browser) postBody(session string, p pausedRequest) ([]byte, bool) {
	var body []byte
	for _, entry := range p.Request.PostDataEntries {
		part, err := base64.StdEncoding.DecodeString(deref(entry.Bytes))
		if entry.Bytes == nil || err != nil {
			body = nil
			break
		}
		body = append(body, part...)
	}
	switch {
	case body != nil:
		return body, true
	case p.Request.PostData != "":
		return []byte(p.Request.PostData), true
	case !p.Request.HasPostData:
		return nil, true
	}
	ctx, cancel := context.WithTimeout(context.Background(), opWait)
	defer cancel()
	var data struct {
		PostData      string `json:"postData"`
		Base64Encoded bool   `json:"base64Encoded"`
	}
	if b.c.call(ctx, session, "Network.getRequestPostData", map[string]any{"requestId": p.NetworkID}, &data) != nil {
		return nil, false
	}
	if !data.Base64Encoded {
		return []byte(data.PostData), true
	}
	decoded, err := base64.StdEncoding.DecodeString(data.PostData)
	return decoded, err == nil
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// answerPaused fulfils a paused request; one Chrome refuses, as it does a
// status it does not take, is failed, so none is left paused.
func (b *browser) answerPaused(session, request string, status int, headers map[string]string, body []byte) {
	ctx, cancel := context.WithTimeout(context.Background(), opWait)
	defer cancel()
	list := make([]map[string]string, 0, len(headers))
	for name, value := range headers {
		list = append(list, map[string]string{"name": name, "value": value})
	}
	params := map[string]any{"requestId": request, "responseCode": status, "responseHeaders": list,
		"body": base64.StdEncoding.EncodeToString(body)}
	if err := b.c.call(ctx, session, "Fetch.fulfillRequest", params, nil); err != nil && ctx.Err() == nil {
		_ = b.c.call(ctx, session, "Fetch.failRequest", map[string]any{"requestId": request, "errorReason": "Failed"}, nil)
	}
}

// failPaused answers a paused request nothing.
func (b *browser) failPaused(session, request string) {
	ctx, cancel := context.WithTimeout(context.Background(), opWait)
	defer cancel()
	_ = b.c.call(ctx, session, "Fetch.failRequest", map[string]any{"requestId": request, "errorReason": "BlockedByClient"}, nil)
}

// pageEvent goes from the windows to the serve loop: a call to pass up,
// or the end of the calls it names, every call of win, or of session, or
// of session's frame.
type pageEvent struct {
	call           *heldCall
	win            *window
	session, frame string
}

// heldCall is a page's call, its request paused until the host answers;
// put is the id of the put it was admitted by, the one its document
// belongs to.
type heldCall struct {
	win                     *window
	gen, put                int64
	session, request, frame string
	op                      string
	body                    []byte
}

type callMessage struct {
	T    string `json:"t"`
	ID   int64  `json:"id"`
	Win  string `json:"win"`
	Put  int64  `json:"put"`
	Op   string `json:"op"`
	Body string `json:"body"`
}

type callendMessage struct {
	T  string `json:"t"`
	ID int64  `json:"id"`
}

// calls holds the calls passed up, on the serve loop's goroutine, by the
// driver's own numbers.
type calls struct {
	b    *browser
	s    *slot
	next int64
	held map[int64]*heldCall
}

func newCalls(b *browser, s *slot) *calls {
	return &calls{b: b, s: s, held: map[int64]*heldCall{}}
}

// take passes a call up, naming its put, its body's bytes in base64, or
// gives up the calls an end names. A call whose window has shown another
// page since it was admitted is given up at once: that window's end has
// gone by.
func (cl *calls) take(e pageEvent) error {
	if c := e.call; c != nil {
		if _, gen := c.win.current(); gen != c.gen {
			go cl.b.failPaused(c.session, c.request)
			return nil
		}
		cl.next++
		cl.held[cl.next] = c
		body := base64.StdEncoding.EncodeToString(c.body)
		c.body = nil
		return cl.s.write(callMessage{T: "call", ID: cl.next, Win: c.win.name, Put: c.put, Op: c.op, Body: body})
	}
	for id, c := range cl.held {
		if (e.win != nil && c.win == e.win) || (e.session != "" && c.session == e.session && (e.frame == "" || c.frame == e.frame)) {
			delete(cl.held, id)
			go cl.b.failPaused(c.session, c.request)
			if err := cl.s.write(callendMessage{T: "callend", ID: id}); err != nil {
				return err
			}
		}
	}
	return nil
}

// answer fulfils call id with the host's answer; an answer for a call no
// longer held is passed over.
func (cl *calls) answer(id int64, status int, body string) {
	c := cl.held[id]
	if c == nil {
		return
	}
	delete(cl.held, id)
	go cl.b.answerPaused(c.session, c.request, status, map[string]string{"Content-Type": "application/json"}, []byte(body))
}

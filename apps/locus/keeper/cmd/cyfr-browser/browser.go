// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image/png"
	"io"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// opWait bounds one request, its window's making and an open's wait
	// for the load event included.
	opWait = 30 * time.Second
	// settleWait is how long a click waits for the loading it may have
	// started, and stopWait how long for that loading to stop, before it
	// answers where the window is; opWait leaves room for that answer.
	settleWait = 500 * time.Millisecond
	stopWait   = 20 * time.Second
	// maxResponse bounds a response's text.
	maxResponse = 16 << 20
)

// request is one `req` of the host's; a `page`'s put is assembled from
// the parts that follow it (page.go).
type request struct {
	ID   int64
	Win  string
	Op   string
	Args json.RawMessage
	Of   int64
	put  *put
}

// failure is a response's error: its code and a sentence a person reads.
type failure struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (f *failure) Error() string { return f.Message }

var (
	errNoWindow = &failure{"no_window", "There is no browser window for this thread; open a page first."}
	errBadRef   = &failure{"bad_ref", "That element is no longer on the page; read the page again."}
	errBadURL   = &failure{"bad_url", "Only http and https addresses open in the browser."}
)

// browser keeps one Chrome window per host window name.
type browser struct {
	c       *cdp
	mu      sync.Mutex
	windows map[string]*window
	// pages carries the windows' calls, and their ends, to the serve loop.
	pages chan pageEvent
	// agent is how every target names itself (agent.go), set once Chrome
	// has answered its version and before any window is made; person, the
	// language and time zone it reads pages in (person.go), set before
	// Chrome starts.
	agent  map[string]any
	person person
	// log is the driver's log.
	log io.Writer
}

// window is one Chrome page target and its flattened session. Its name is
// set when it is made; its other fields but put and gen are set before
// ready closes and read only after.
type window struct {
	name                   string
	target, session, frame string
	ready                  chan struct{}
	err                    error
	// op runs the window's requests one at a time.
	op sync.Mutex
	// mu guards the window's put, the files its document is answered from;
	// gen, which moves on whenever its main frame commits another document
	// or it closes; next, the put a show is loading, and landed, the put of
	// a show that ended before its commit was taken (page.go); and docs,
	// which put each of its documents belongs to (docs.go).
	mu     sync.Mutex
	put    *put
	gen    int64
	next   *put
	landed *put
	docs   documents
	// unnamed says a target attached to the window was refused its naming
	// (agent.go) and was not let run, which the window's next action says.
	unnamed bool
}

func newBrowser() *browser {
	return &browser{windows: map[string]*window{}, pages: make(chan pageEvent, 64), log: os.Stderr}
}

// onTarget forgets a window whose target Chrome reports gone, with its put
// and its calls, and closes one whose page crashed.
func (b *browser) onTarget(method string, params json.RawMessage) {
	var event struct {
		TargetID string `json:"targetId"`
	}
	switch method {
	case "Target.targetDestroyed", "Target.detachedFromTarget", "Target.targetCrashed":
		if json.Unmarshal(params, &event) != nil {
			return
		}
	default:
		return
	}
	b.mu.Lock()
	for name, w := range b.windows {
		if made(w) && w.target == event.TargetID {
			delete(b.windows, name)
			go b.replace(w, nil)
		}
	}
	b.mu.Unlock()
	if method == "Target.targetCrashed" {
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), opWait)
			defer cancel()
			_ = b.c.call(ctx, "", "Target.closeTarget", map[string]any{"targetId": event.TargetID}, nil)
		}()
	}
}

func made(w *window) bool {
	select {
	case <-w.ready:
		return w.err == nil
	default:
		return false
	}
}

// do runs one request once and answers its response text.
func (b *browser) do(r request) []byte {
	ctx, cancel := context.WithTimeout(context.Background(), opWait)
	defer cancel()
	result, err := b.run(ctx, r)
	return answer(result, err)
}

// answer is a response's text: `{"ok": result}`, or `{"error": failure}`.
func answer(result any, err error) []byte {
	if err == nil {
		text, mErr := json.Marshal(map[string]any{"ok": result})
		switch {
		case mErr != nil:
			err = mErr
		case len(text) > maxResponse:
			err = &failure{"too_large", "The answer is larger than the browser sends; read a smaller page."}
		default:
			return text
		}
	}
	var f *failure
	if !errors.As(err, &f) {
		f = describe(err)
	}
	text, _ := json.Marshal(map[string]any{"error": f})
	return text
}

func describe(err error) *failure {
	var refused *cdpError
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return &failure{"timeout", fmt.Sprintf("The browser did not finish within %d seconds.", int(opWait.Seconds()))}
	case errors.Is(err, errDetached):
		return &failure{"no_window", "The window was closed while the browser worked in it."}
	case errors.As(err, &refused):
		return &failure{"failed", "The browser could not do that: " + refused.Message + "."}
	default:
		return &failure{"failed", "The browser could not do that: " + err.Error() + "."}
	}
}

func badRequest(message string) error { return &failure{"bad_request", message} }

func (b *browser) run(ctx context.Context, r request) (any, error) {
	if r.Op == "close_all" {
		if r.Win != "" {
			return nil, badRequest("Closing every window names no window.")
		}
		return b.closeAll(ctx), nil
	}
	if r.Win == "" {
		return nil, badRequest("The request names no window.")
	}
	var args struct {
		URL  *string `json:"url"`
		Ref  *string `json:"ref"`
		Text *string `json:"text"`
		Key  *string `json:"key"`
	}
	if len(r.Args) > 0 && json.Unmarshal(r.Args, &args) != nil {
		return nil, badRequest("The request's arguments are not an object of its operation's.")
	}
	need := func(value *string, name string) (string, error) {
		if value == nil {
			return "", badRequest("The request names no " + name + ".")
		}
		return *value, nil
	}
	switch r.Op {
	case "open":
		address, err := need(args.URL, "url")
		if err != nil {
			return nil, err
		}
		if u, err := url.Parse(address); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return nil, errBadURL
		}
		return b.in(ctx, r.Win, true, func(w *window) (any, error) {
			if err := b.navigate(ctx, w, address); err != nil {
				return nil, err
			}
			return b.where(ctx, w)
		})
	case "read":
		return b.in(ctx, r.Win, false, func(w *window) (any, error) { return b.read(ctx, w) })
	case "click":
		ref, err := need(args.Ref, "ref")
		if err != nil {
			return nil, err
		}
		return b.in(ctx, r.Win, false, func(w *window) (any, error) { return b.click(ctx, w, ref) })
	case "type":
		ref, err := need(args.Ref, "ref")
		if err != nil {
			return nil, err
		}
		text, err := need(args.Text, "text")
		if err != nil {
			return nil, err
		}
		return b.in(ctx, r.Win, false, func(w *window) (any, error) { return b.typeText(ctx, w, ref, text) })
	case "key":
		name, err := need(args.Key, "key")
		if err != nil {
			return nil, err
		}
		key, ok := keys[name]
		if !ok {
			return nil, &failure{"bad_key", "The browser does not press " + strconv.Quote(name) + "."}
		}
		return b.in(ctx, r.Win, false, func(w *window) (any, error) { return b.press(ctx, w, key) })
	case "page":
		if r.put == nil {
			return nil, errBadPut
		}
		return b.in(ctx, r.Win, true, func(w *window) (any, error) { return b.show(ctx, w, r.put) })
	case "screenshot":
		return b.in(ctx, r.Win, false, func(w *window) (any, error) { return b.screenshot(ctx, w) })
	case "close":
		closed := b.closeWindow(ctx, r.Win)
		return map[string]bool{"closed": closed}, nil
	default:
		return nil, badRequest("The browser does not do " + strconv.Quote(r.Op) + ".")
	}
}

// in runs fn in window name, made first when create is set, after the
// window's earlier requests. A window this request made is closed before
// its failure is answered: the host counts the windows that showed a page,
// so none stands that it does not count.
func (b *browser) in(ctx context.Context, name string, create bool, fn func(*window) (any, error)) (any, error) {
	w, made, err := b.window(ctx, name, create)
	if err != nil {
		return nil, err
	}
	w.op.Lock()
	defer w.op.Unlock()
	out, err := fn(w)
	w.mu.Lock()
	if w.unnamed {
		out, err = nil, errUnnamed
	}
	w.unnamed = false
	w.mu.Unlock()
	if err != nil && made {
		b.forget(ctx, name, w)
	}
	return out, err
}

// forget closes window w, named name, and forgets it, unless another
// window has taken its name meanwhile.
func (b *browser) forget(ctx context.Context, name string, w *window) {
	b.mu.Lock()
	if b.windows[name] == w {
		delete(b.windows, name)
	}
	b.mu.Unlock()
	b.replace(w, nil)
	_ = b.c.call(ctx, "", "Target.closeTarget", map[string]any{"targetId": w.target}, nil)
}

// window answers window name, and whether this call made it.
func (b *browser) window(ctx context.Context, name string, create bool) (*window, bool, error) {
	b.mu.Lock()
	w := b.windows[name]
	if w == nil {
		if !create {
			b.mu.Unlock()
			return nil, false, errNoWindow
		}
		w = &window{name: name, ready: make(chan struct{})}
		b.windows[name] = w
		b.mu.Unlock()
		w.err = b.makeWindow(ctx, w)
		if w.err != nil {
			b.mu.Lock()
			if b.windows[name] == w {
				delete(b.windows, name)
			}
			b.mu.Unlock()
		}
		close(w.ready)
		return w, w.err == nil, w.err
	}
	b.mu.Unlock()
	select {
	case <-w.ready:
	case <-ctx.Done():
		return nil, false, ctx.Err()
	}
	if w.err != nil {
		return nil, false, w.err
	}
	return w, false, nil
}

func (b *browser) makeWindow(ctx context.Context, w *window) error {
	var target struct {
		TargetID string `json:"targetId"`
	}
	if err := b.c.call(ctx, "", "Target.createTarget", map[string]any{"url": "about:blank", "newWindow": true}, &target); err != nil {
		return err
	}
	err := b.attach(ctx, w, target.TargetID)
	if err != nil {
		_ = b.c.call(ctx, "", "Target.closeTarget", map[string]any{"targetId": target.TargetID}, nil)
	}
	return err
}

// attach takes window w's target, with the reserved origin intercepted
// before its first navigation (page.go).
func (b *browser) attach(ctx context.Context, w *window, target string) error {
	var attached struct {
		SessionID string `json:"sessionId"`
	}
	if err := b.c.call(ctx, "", "Target.attachToTarget", map[string]any{"targetId": target, "flatten": true}, &attached); err != nil {
		return err
	}
	session := attached.SessionID
	go b.serveSession(w, session, sessionPage, b.c.watch(session, intercepted))
	if err := b.name(ctx, session, "page"); err != nil {
		return err
	}
	if err := b.interceptOn(ctx, session); err != nil {
		return err
	}
	if err := b.c.call(ctx, session, "Page.setLifecycleEventsEnabled", map[string]any{"enabled": true}, nil); err != nil {
		return err
	}
	var tree struct {
		FrameTree struct {
			Frame struct {
				ID string `json:"id"`
			} `json:"frame"`
		} `json:"frameTree"`
	}
	if err := b.c.call(ctx, session, "Page.getFrameTree", nil, &tree); err != nil {
		return err
	}
	w.target, w.session, w.frame = target, session, tree.FrameTree.Frame.ID
	return nil
}

// closeWindow closes window name's target: whether there was one.
func (b *browser) closeWindow(ctx context.Context, name string) bool {
	b.mu.Lock()
	w := b.windows[name]
	delete(b.windows, name)
	b.mu.Unlock()
	if w == nil {
		return false
	}
	select {
	case <-w.ready:
	case <-ctx.Done():
		return true
	}
	if w.err != nil {
		return false
	}
	b.replace(w, nil)
	_ = b.c.call(ctx, "", "Target.closeTarget", map[string]any{"targetId": w.target}, nil)
	return true
}

func (b *browser) closeAll(ctx context.Context) map[string]int {
	b.mu.Lock()
	names := make([]string, 0, len(b.windows))
	for name := range b.windows {
		names = append(names, name)
	}
	b.mu.Unlock()
	closed := 0
	for _, name := range names {
		if b.closeWindow(ctx, name) {
			closed++
		}
	}
	return map[string]int{"closed": closed}
}

// navigate loads address in w's main frame and waits for its load event.
func (b *browser) navigate(ctx context.Context, w *window, address string) error {
	loads := b.c.watch(w.session, func(method string, params json.RawMessage) bool {
		var event struct {
			Name string `json:"name"`
		}
		return method == "Page.lifecycleEvent" && json.Unmarshal(params, &event) == nil && event.Name == "load"
	})
	defer b.c.unwatch(loads)
	var nav struct {
		FrameID   string `json:"frameId"`
		LoaderID  string `json:"loaderId"`
		ErrorText string `json:"errorText"`
	}
	if err := b.c.call(ctx, w.session, "Page.navigate", map[string]any{"url": address}, &nav); err != nil {
		return err
	}
	if nav.ErrorText != "" {
		return &failure{"unreachable", "The page could not be loaded (" + nav.ErrorText + ")."}
	}
	if nav.LoaderID == "" {
		return nil
	}
	for {
		load, err := loads.next(ctx)
		if err != nil {
			return err
		}
		var event struct {
			FrameID  string `json:"frameId"`
			LoaderID string `json:"loaderId"`
		}
		if json.Unmarshal(load.params, &event) == nil && event.FrameID == nav.FrameID && event.LoaderID == nav.LoaderID {
			return nil
		}
	}
}

type place struct {
	URL   string `json:"url"`
	Title string `json:"title"`
}

// where answers the address and title of w's current page.
func (b *browser) where(ctx context.Context, w *window) (place, error) {
	var history struct {
		CurrentIndex int `json:"currentIndex"`
		Entries      []struct {
			URL   string `json:"url"`
			Title string `json:"title"`
		} `json:"entries"`
	}
	if err := b.c.call(ctx, w.session, "Page.getNavigationHistory", nil, &history); err != nil {
		return place{}, err
	}
	if history.CurrentIndex < 0 || history.CurrentIndex >= len(history.Entries) {
		return place{}, nil
	}
	entry := history.Entries[history.CurrentIndex]
	return place{URL: entry.URL, Title: entry.Title}, nil
}

func (b *browser) read(ctx context.Context, w *window) (any, error) {
	var tree struct {
		Nodes []axNode `json:"nodes"`
	}
	if err := b.c.call(ctx, w.session, "Accessibility.getFullAXTree", nil, &tree); err != nil {
		return nil, err
	}
	at, err := b.where(ctx, w)
	if err != nil {
		return nil, err
	}
	return map[string]string{"url": at.URL, "title": at.Title, "text": axText(tree.Nodes)}, nil
}

type axNode struct {
	NodeID           string   `json:"nodeId"`
	Ignored          bool     `json:"ignored"`
	Role             axValue  `json:"role"`
	Name             axValue  `json:"name"`
	Value            axValue  `json:"value"`
	ChildIDs         []string `json:"childIds"`
	ParentID         string   `json:"parentId"`
	BackendDOMNodeID int64    `json:"backendDOMNodeId"`
}

type axValue struct {
	Value json.RawMessage `json:"value"`
}

func (v axValue) String() string {
	var text string
	if json.Unmarshal(v.Value, &text) == nil {
		return text
	}
	return string(v.Value)
}

// interactive are the roles a read gives a ref, which click and type take.
var interactive = map[string]bool{
	"link": true, "button": true, "textbox": true, "searchbox": true, "combobox": true, "checkbox": true,
	"radio": true, "menuitem": true, "tab": true, "option": true, "switch": true, "slider": true,
}

// axText writes the page's accessibility tree as text, a line per node
// indented by its depth among the nodes written. An interactive node
// starts with its ref, `[N]`, N its backend DOM node id. Ignored nodes,
// inline text boxes (which repeat their text's) and nameless generic
// nodes are not written; their children take their place.
func axText(nodes []axNode) string {
	byID := make(map[string]*axNode, len(nodes))
	for i := range nodes {
		byID[nodes[i].NodeID] = &nodes[i]
	}
	type item struct {
		node  *axNode
		depth int
	}
	var stack []item
	for i := len(nodes) - 1; i >= 0; i-- {
		if byID[nodes[i].ParentID] == nil {
			stack = append(stack, item{&nodes[i], 0})
		}
	}
	var out strings.Builder
	seen := make(map[string]bool, len(nodes))
	for len(stack) > 0 {
		top := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		n := top.node
		if seen[n.NodeID] {
			continue
		}
		seen[n.NodeID] = true
		role, name := n.Role.String(), n.Name.String()
		depth := top.depth
		if !n.Ignored && role != "InlineTextBox" && !((role == "generic" || role == "none") && name == "") {
			out.WriteString(strings.Repeat("  ", depth))
			if interactive[role] && n.BackendDOMNodeID > 0 {
				fmt.Fprintf(&out, "[%d] ", n.BackendDOMNodeID)
			}
			out.WriteString(role)
			if name != "" {
				out.WriteString(" " + strconv.Quote(name))
			}
			if value := n.Value.String(); (role == "textbox" || role == "searchbox") && value != "" {
				out.WriteString(" = " + strconv.Quote(value))
			}
			out.WriteByte('\n')
			depth++
		}
		for i := len(n.ChildIDs) - 1; i >= 0; i-- {
			if child := byID[n.ChildIDs[i]]; child != nil {
				stack = append(stack, item{child, depth})
			}
		}
	}
	return out.String()
}

// node resolves a ref: a backend DOM node id of the window's page.
func node(ref string) (int64, error) {
	id, err := strconv.ParseInt(ref, 10, 64)
	if err != nil || id <= 0 {
		return 0, errBadRef
	}
	return id, nil
}

// onNode runs a DOM command on a ref's node; a node Chrome cannot find is
// a stale ref.
func (b *browser) onNode(ctx context.Context, w *window, method string, id int64, result any) error {
	err := b.c.call(ctx, w.session, method, map[string]any{"backendNodeId": id}, result)
	var refused *cdpError
	if errors.As(err, &refused) {
		return errBadRef
	}
	return err
}

func (b *browser) click(ctx context.Context, w *window, ref string) (any, error) {
	id, err := node(ref)
	if err != nil {
		return nil, err
	}
	loading := b.c.watch(w.session, func(method string, params json.RawMessage) bool {
		var event struct {
			FrameID string `json:"frameId"`
		}
		return (method == "Page.frameStartedLoading" || method == "Page.frameStoppedLoading") &&
			json.Unmarshal(params, &event) == nil && event.FrameID == w.frame
	})
	defer b.c.unwatch(loading)
	if err := b.onNode(ctx, w, "DOM.scrollIntoViewIfNeeded", id, nil); err != nil {
		return nil, err
	}
	var quads struct {
		Quads [][]float64 `json:"quads"`
	}
	if err := b.onNode(ctx, w, "DOM.getContentQuads", id, &quads); err != nil {
		return nil, err
	}
	if len(quads.Quads) == 0 || len(quads.Quads[0]) != 8 {
		return nil, errBadRef
	}
	q := quads.Quads[0]
	x, y := (q[0]+q[2]+q[4]+q[6])/4, (q[1]+q[3]+q[5]+q[7])/4
	for _, kind := range []string{"mouseMoved", "mousePressed", "mouseReleased"} {
		event := map[string]any{"type": kind, "x": x, "y": y}
		if kind != "mouseMoved" {
			event["button"], event["clickCount"] = "left", 1
		}
		if err := b.c.call(ctx, w.session, "Input.dispatchMouseEvent", event, nil); err != nil {
			return nil, err
		}
	}
	settle, cancel := context.WithTimeout(ctx, settleWait)
	event, err := loading.next(settle)
	cancel()
	if err == nil && event.method == "Page.frameStartedLoading" {
		stop, cancel := context.WithTimeout(ctx, stopWait)
		for err == nil && event.method == "Page.frameStartedLoading" {
			event, err = loading.next(stop)
		}
		cancel()
	}
	if errors.Is(err, errDetached) {
		return nil, err
	}
	return b.where(ctx, w)
}

func (b *browser) typeText(ctx context.Context, w *window, ref, text string) (any, error) {
	id, err := node(ref)
	if err != nil {
		return nil, err
	}
	if err := b.onNode(ctx, w, "DOM.focus", id, nil); err != nil {
		return nil, err
	}
	if err := b.c.call(ctx, w.session, "Input.insertText", map[string]any{"text": text}, nil); err != nil {
		return nil, err
	}
	return struct{}{}, nil
}

// keyDef is one key Input.dispatchKeyEvent presses.
type keyDef struct {
	key, code, text string
	vk              int
}

var keys = map[string]keyDef{
	"Enter":      {"Enter", "Enter", "\r", 13},
	"Tab":        {"Tab", "Tab", "", 9},
	"Escape":     {"Escape", "Escape", "", 27},
	"Backspace":  {"Backspace", "Backspace", "", 8},
	"Delete":     {"Delete", "Delete", "", 46},
	"ArrowUp":    {"ArrowUp", "ArrowUp", "", 38},
	"ArrowDown":  {"ArrowDown", "ArrowDown", "", 40},
	"ArrowLeft":  {"ArrowLeft", "ArrowLeft", "", 37},
	"ArrowRight": {"ArrowRight", "ArrowRight", "", 39},
	"Home":       {"Home", "Home", "", 36},
	"End":        {"End", "End", "", 35},
	"PageUp":     {"PageUp", "PageUp", "", 33},
	"PageDown":   {"PageDown", "PageDown", "", 34},
	"Space":      {" ", "Space", " ", 32},
}

func (b *browser) press(ctx context.Context, w *window, k keyDef) (any, error) {
	down := map[string]any{"type": "rawKeyDown", "key": k.key, "code": k.code, "windowsVirtualKeyCode": k.vk}
	if k.text != "" {
		down["type"], down["text"] = "keyDown", k.text
	}
	up := map[string]any{"type": "keyUp", "key": k.key, "code": k.code, "windowsVirtualKeyCode": k.vk}
	for _, event := range []map[string]any{down, up} {
		if err := b.c.call(ctx, w.session, "Input.dispatchKeyEvent", event, nil); err != nil {
			return nil, err
		}
	}
	return struct{}{}, nil
}

func (b *browser) screenshot(ctx context.Context, w *window) (any, error) {
	var shot struct {
		Data string `json:"data"`
	}
	if err := b.c.call(ctx, w.session, "Page.captureScreenshot", map[string]any{"format": "png"}, &shot); err != nil {
		return nil, err
	}
	data, err := base64.StdEncoding.DecodeString(shot.Data)
	if err != nil {
		return nil, err
	}
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	return map[string]any{"png": shot.Data, "width": config.Width, "height": config.Height}, nil
}

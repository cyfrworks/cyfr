// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"fmt"
	"strings"
)

// A request for a file of a window's put is answered from the put of the
// document that made it, as Chrome names that document, and from no other.
// Chrome names a document by its loader: on the navigation that makes it,
// as that navigation's network id, and on each request the document sends,
// as the loaderId of the request's Network.requestWillBeSent, which shares
// the paused request's network id and comes before the pause or after it.
// A main frame's document belongs to the put whose file answered its
// navigation (serving). A frame's document belongs to the put of the
// document the frame was attached in, which Page.frameAttached names by its
// order: the page's process reports a frame's attachment after the commit
// of the document it is attached in. That holds whether the driver answered
// the frame's navigation or Chrome made the document itself (srcdoc,
// about:blank, another origin). A document of neither the window's put nor
// the put a show is loading is answered nothing.
//
// Chrome names no document on a dedicated worker's script and its own
// requests, nor on a keepalive request. Such a request is answered only
// while the window has one put it can belong to: while no show's entry has
// been answered without its commit being taken (loading), the show's end
// counting for none, since Chrome reports the entry's load beside its
// commit and not after it. Otherwise it waits for that commit or the
// show's end, and is then answered from the put that stands. Two cases
// follow, and neither reaches another window's files: a keepalive request
// of a page whose put was replaced is answered from the put that stands,
// to a page that is gone; and a worker's request made while a show loads
// waits for that show's commit or end.
//
// A page's call goes up when it is made with the reserved origin, by its
// Origin header, which Chrome sets as the caller acts (a sandboxed frame's
// is null) and no script can set; names a document, its loader; that
// document is its frame's document now; and that document's put is the
// window's. Anything else is refused: its fetch fails as a network error,
// and the host never hears of it. A call carries a person's action, so it
// is stricter than a file, and it waits for one thing only: its own
// report, when its pause came first. Chrome sends a document's report from
// the page's process after that document's commit and its frames'
// attachments, on the same session, and each session's events are taken
// in the order Chrome sent them (the image's Chromium 156 showed it over
// 900 navigations within one put, by link, reload and form, each new
// document and its frame calling as they started): so when a call's report
// is taken, its document's commit and its frame's attachment have been,
// and one not yet known is refused, not waited for.
//
// A file's request waits only for what names it: its loader's report, its
// frame's attachment, or a show's commit or end. A report is kept until its
// request pauses, whatever became of its document's put, so a pause that
// comes late is refused, not held; at most maxReports are kept, the oldest
// forgotten first. At most maxWaiting wait in a window; one past that is
// refused, which the driver's log says once for the window. A request
// whose report was forgotten past maxReports waits for a report that will
// not come, a call's among them: it holds one of the maxWaiting places
// until its session ends.
const (
	maxWaiting = 256
	// maxReports bounds the reports kept for requests not yet paused.
	maxReports = 1024
	// maxDepth bounds the frames a document's put is looked up through.
	maxDepth = 64
)

// documents is what a window knows of its documents, guarded by its mu.
type documents struct {
	// puts holds, by loader, the put whose file answered the navigation
	// that made the document.
	puts map[string]*put
	// owners holds, by frame, the loader of the document the frame was
	// attached in; current, by frame, the loader of its document now; and
	// frames, by loader, the frame a frame's document is in.
	owners, current, frames map[string]string
	// reports holds the loader of each request reported before its pause,
	// by network id, the oldest first in order.
	reports map[string]string
	order   []string
	waiting []waiter
	// full says the driver's log has said the window's bound was reached.
	full bool
}

// waiter is a paused request of a window's pages: for a file of a put, a
// GET or a HEAD that is not the main frame's navigation, or a call, by its
// session and id, with its decoded path, its network id and the frame
// Chrome names. navigation says it is a frame's navigation; named, that
// its loader is known.
type waiter struct {
	session, request, path string
	head, navigation       bool
	network, frame, loader string
	named                  bool
	call                   *callArgs
}

// callArgs is what a call carries: its op, and its pause, which its
// body is read from.
type callArgs struct {
	op     string
	paused pausedRequest
}

// answered is a request whose put is known, nil answering it nothing, and
// for a call the window's generation when that became known.
type answered struct {
	r   waiter
	p   *put
	gen int64
}

func (d *documents) init() {
	if d.puts == nil {
		d.puts, d.owners, d.current, d.frames, d.reports = map[string]*put{}, map[string]string{},
			map[string]string{}, map[string]string{}, map[string]string{}
	}
}

// usable is p when a document of it may be answered now: p is w's put or
// the put being shown or landing, and has not failed.
func (w *window) usable(p *put) *put {
	if p == nil || p.failed || (p != w.put && p != w.next && p != w.landed) {
		return nil
	}
	return p
}

// loading says a show's entry was answered and its commit is not taken:
// the window may hold a document of its put and one of the put shown.
func (w *window) loading() bool {
	if w.landed != nil {
		return true
	}
	if w.next == nil || w.next == w.put {
		return false
	}
	for _, p := range w.docs.puts {
		if p == w.next {
			return true
		}
	}
	return false
}

// putOf answers the put loader's document belongs to, nil for none, and
// false while a frame it is in has not had its attachment reported.
func (w *window) putOf(loader string) (*put, bool) {
	for range maxDepth {
		if p, ok := w.docs.puts[loader]; ok {
			return w.usable(p), true
		}
		frame, ok := w.docs.frames[loader]
		if !ok {
			return nil, true
		}
		owner, ok := w.docs.owners[frame]
		if !ok {
			return nil, false
		}
		loader = owner
	}
	return nil, true
}

// place answers the put r is answered from, and false while what names
// r's document has not come.
func (w *window) place(r *waiter) (*put, bool) {
	d := &w.docs
	d.init()
	if r.call != nil {
		return w.placeCall(r)
	}
	if r.navigation {
		owner, ok := d.owners[r.frame]
		if !ok {
			return nil, false
		}
		p, ok := w.putOf(owner)
		if ok && p != nil && r.network != "" && p.lookup(r.path) != nil {
			d.puts[r.network] = p
		}
		return p, ok
	}
	if r.network != "" && !r.named {
		loader, ok := d.reports[r.network]
		if !ok {
			return nil, false
		}
		delete(d.reports, r.network)
		r.loader, r.named = loader, true
	}
	if r.loader != "" {
		return w.putOf(r.loader)
	}
	if w.loading() {
		return nil, false
	}
	return w.usable(w.put), true
}

// placeCall answers the put call r goes up for, nil for none, and false
// while its report has not come.
func (w *window) placeCall(r *waiter) (*put, bool) {
	d := &w.docs
	if r.network == "" || header(r.call.paused.Request.Headers, "Origin") != reservedOrigin {
		return nil, true
	}
	if !r.named {
		loader, ok := d.reports[r.network]
		if !ok {
			return nil, false
		}
		delete(d.reports, r.network)
		r.loader, r.named = loader, true
	}
	if r.loader == "" || d.current[r.frame] != r.loader {
		return nil, true
	}
	if p, ok := w.putOf(r.loader); ok && p != nil && p == w.put {
		return p, true
	}
	return nil, true
}

// header is the value of the header name in headers, by any case.
func header(headers map[string]string, name string) string {
	for key, value := range headers {
		if strings.EqualFold(key, name) {
			return value
		}
	}
	return ""
}

// settle takes every waiting request whose put is now known.
func (w *window) settle() []answered {
	var done []answered
	kept := w.docs.waiting[:0]
	for _, r := range w.docs.waiting {
		if p, ok := w.place(&r); ok {
			done = append(done, answered{r, p, w.gen})
		} else {
			kept = append(kept, r)
		}
	}
	clear(w.docs.waiting[len(kept):])
	w.docs.waiting = kept
	return done
}

// prune forgets the documents of puts that can no longer be answered,
// after a commit or a show's end; their requests' reports stay until the
// requests pause.
func (w *window) prune() {
	d := &w.docs
	d.init()
	for loader, p := range d.puts {
		if w.usable(p) == nil {
			delete(d.puts, loader)
		}
	}
	for loader := range d.frames {
		if p, ok := w.putOf(loader); ok && p == nil {
			delete(d.frames, loader)
		}
	}
	for frame, owner := range d.owners {
		if p, ok := w.putOf(owner); ok && p == nil {
			delete(d.owners, frame)
			delete(d.current, frame)
		}
	}
}

// compactReports keeps the order of the reports to those still held.
func (w *window) compactReports() {
	d := &w.docs
	kept := d.order[:0]
	for _, network := range d.order {
		if _, ok := d.reports[network]; ok {
			kept = append(kept, network)
		}
	}
	clear(d.order[len(kept):])
	d.order = kept
}

// reported takes Chrome's report of a request for a file before or after
// its pause: its network id and its document's loader.
func (b *browser) reported(w *window, network, loader string) {
	w.mu.Lock()
	d := &w.docs
	d.init()
	if _, ok := d.reports[network]; !ok {
		d.reports[network] = loader
		d.order = append(d.order, network)
	}
	if len(d.order) > 2*maxReports {
		w.compactReports()
	}
	for len(d.reports) > maxReports {
		if _, ok := d.reports[d.order[0]]; ok {
			delete(d.reports, d.order[0])
		}
		d.order = d.order[1:]
	}
	done := w.settle()
	w.mu.Unlock()
	b.answerAll(w, done)
}

// frameAttached takes frame's attachment to parent, whose document now is
// the one it is attached in.
func (b *browser) frameAttached(w *window, frame, parent string) {
	w.mu.Lock()
	w.docs.init()
	w.docs.owners[frame] = w.docs.current[parent]
	done := w.settle()
	w.mu.Unlock()
	b.answerAll(w, done)
}

// frameCommitted takes the document frame, a frame inside w's main frame,
// committed under loader.
func (b *browser) frameCommitted(w *window, frame, loader string) {
	w.mu.Lock()
	w.docs.init()
	w.docs.current[frame] = loader
	w.docs.frames[loader] = frame
	done := w.settle()
	w.mu.Unlock()
	b.answerAll(w, done)
}

// frameGone forgets a frame that left its document, and its documents,
// which then belong to no put.
func (b *browser) frameGone(w *window, frame string) {
	w.mu.Lock()
	d := &w.docs
	d.init()
	delete(d.owners, frame)
	delete(d.current, frame)
	for loader, in := range d.frames {
		if in == frame {
			delete(d.frames, loader)
		}
	}
	done := w.settle()
	w.mu.Unlock()
	b.answerAll(w, done)
}

// hold answers r from the put of its document, or holds it until that is
// known, within the window's bound.
func (b *browser) hold(w *window, r waiter) {
	w.mu.Lock()
	p, ok := w.place(&r)
	if ok {
		gen := w.gen
		w.mu.Unlock()
		b.answerAll(w, []answered{{r, p, gen}})
		return
	}
	if len(w.docs.waiting) >= maxWaiting {
		said := w.docs.full
		w.docs.full = true
		w.mu.Unlock()
		if !said {
			fmt.Fprintf(b.log, "cyfr-browser: window %s: %d requests already wait for the document that made them to be known; more are refused\n",
				w.name, maxWaiting)
		}
		go b.failPaused(r.session, r.request)
		return
	}
	w.docs.waiting = append(w.docs.waiting, r)
	w.mu.Unlock()
}

// sessionEnded fails the requests of session still waiting.
func (b *browser) sessionEnded(w *window, session string) {
	w.mu.Lock()
	var gone []answered
	kept := w.docs.waiting[:0]
	for _, r := range w.docs.waiting {
		if r.session == session {
			gone = append(gone, answered{r, nil, 0})
		} else {
			kept = append(kept, r)
		}
	}
	clear(w.docs.waiting[len(kept):])
	w.docs.waiting = kept
	w.mu.Unlock()
	b.answerAll(w, gone)
}

// answerAll answers requests whose put is known: each call here, in the
// order its document's events came, so that an end that follows it finds
// it held (calls.take); the files one after another on one goroutine, so
// that at most one file's body is encoded at a time.
func (b *browser) answerAll(w *window, done []answered) {
	var files []answered
	for _, a := range done {
		if a.r.call != nil {
			b.deliver(w, a)
		} else {
			files = append(files, a)
		}
	}
	if len(files) == 0 {
		return
	}
	go func() {
		for _, a := range files {
			b.answerFile(a.r, a.p)
		}
	}()
}

// deliver passes call a up for its put, or refuses it with no put.
func (b *browser) deliver(w *window, a answered) {
	r := a.r
	if a.p == nil {
		go b.failPaused(r.session, r.request)
		return
	}
	body, read := b.postBody(r.session, r.call.paused)
	switch {
	case !read:
		go b.failPaused(r.session, r.request)
	case len(body) > maxCallBody:
		go b.answerPaused(r.session, r.request, 413, nil, nil)
	default:
		b.pages <- pageEvent{call: &heldCall{win: w, gen: a.gen, put: a.p.id, session: r.session, request: r.request,
			frame: r.frame, op: r.call.op, body: body}}
	}
}

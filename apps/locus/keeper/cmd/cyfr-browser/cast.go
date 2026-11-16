// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
)

// A cast is one window's screencast, which the person watches (C12): the
// host asks for it with a `req` of op `cast`, whose id names the cast from
// then on, and ends it with `uncast`. Its images go out one at a time,
// each an `image` the host acknowledges with `seen`; the next goes only
// after that, and Chrome makes the next only once this driver has
// acknowledged the last to it, so a host that does not acknowledge gets no
// further image and Chrome makes none. An image cut in a tail is not sent
// again: the host ends that cast and asks for another. When its window
// closes the cast ends and the host is told `uncast`. The person's `input`
// goes to the cast's window alone, beside whatever request runs there,
// mapped onto the window from the last image sent.
const (
	// castQuality is a cast's first JPEG quality; an image too large for
	// its message steps it down by castStep to castFloor, and then halves
	// the image's bound.
	castQuality = 60
	castStep    = 15
	castFloor   = 15
	// maxImage bounds an image's base64, so its message fits the host's
	// bound with its other fields.
	maxImage = maxToHost - 256
	// maxCasts bounds the casts at once.
	maxCasts = 8
	// The bounds of the box a cast's images are scaled to fit.
	minCastSide, maxCastSide = 16, 4096
	// castInputs bounds the input messages a cast holds while its window
	// takes the last; past it they are dropped.
	castInputs = 8
)

type imageMessage struct {
	T    string `json:"t"`
	ID   int64  `json:"id"`
	Seq  int64  `json:"seq"`
	JPEG string `json:"jpeg"`
}

type uncastMessage struct {
	T  string `json:"t"`
	ID int64  `json:"id"`
}

var errTooManyCasts = &failure{"too_many_casts", "The browser is showing as many windows as it can; close one first."}

// chromeFrame is one Page.screencastFrame.
type chromeFrame struct {
	data string
	// ack is the frame's number, which Page.screencastFrameAck names.
	ack     int64
	session string
	// width and height are the window's viewport, in CSS pixels, which
	// the person's input is mapped onto.
	width, height float64
}

// cast is one cast's state, held on the serve loop's goroutine.
type cast struct {
	id      int64
	win     string
	cancel  context.CancelFunc
	done    chan struct{}
	session string
	seq     int64
	// sent is the image the host has not acknowledged, held as the frame
	// Chrome waits for; held is the newest frame since, which goes when
	// sent is acknowledged; dropped are frames held before held, which
	// Chrome is told of then.
	sent    *chromeFrame
	held    *chromeFrame
	dropped []chromeFrame
	// shown is the last image sent: the window the person sees.
	shown *chromeFrame
	input chan inputBatch
}

type inputBatch struct {
	session string
	calls   []cdpInput
}

// casts runs the casts on the serve loop's goroutine; their screencasts
// and inputs run in goroutines of their own that report on events.
type casts struct {
	b      *browser
	s      *slot
	events chan<- event
	byID   map[int64]*cast
	// done holds each window's last cast's end, which the window's next
	// cast waits for, however that one ended, so a stop of the old never
	// lands after the new one started.
	done map[string]<-chan struct{}
}

func newCasts(b *browser, s *slot, events chan<- event) *casts {
	return &casts{b: b, s: s, events: events, byID: map[int64]*cast{}, done: map[string]<-chan struct{}{}}
}

// start begins cast r.ID of window r.Win, ending any other cast of that
// window first; its answer comes as a `casting` event.
func (cs *casts) start(r request) {
	var args struct {
		Width  *int `json:"width"`
		Height *int `json:"height"`
	}
	fail := func(err error) {
		go func() { cs.events <- event{kind: "casting", id: r.ID, text: answer(nil, err), failed: true} }()
	}
	if len(r.Args) == 0 || json.Unmarshal(r.Args, &args) != nil || args.Width == nil || args.Height == nil ||
		*args.Width < minCastSide || *args.Width > maxCastSide || *args.Height < minCastSide || *args.Height > maxCastSide {
		fail(badRequest("A cast names the width and height it is shown at, each 16 to 4096 pixels."))
		return
	}
	if r.Win == "" {
		fail(badRequest("The request names no window."))
		return
	}
	for _, other := range cs.byID {
		if other.win == r.Win {
			cs.end(other)
		}
	}
	if len(cs.byID) >= maxCasts {
		fail(errTooManyCasts)
		return
	}
	// The ends of casts that have stopped are let go.
	for win, done := range cs.done {
		select {
		case <-done:
			delete(cs.done, win)
		default:
		}
	}
	after := cs.done[r.Win]
	ctx, cancel := context.WithCancel(context.Background())
	c := &cast{id: r.ID, win: r.Win, cancel: cancel, done: make(chan struct{}), input: make(chan inputBatch, castInputs)}
	cs.byID[r.ID] = c
	cs.done[r.Win] = c.done
	go cs.b.runCast(ctx, c.id, c.win, c.done, after, *args.Width, *args.Height, cs.events)
	go cs.b.runInput(ctx, c.input)
}

// casting takes a cast's start: its window's session, or its failure.
func (cs *casts) casting(e event) error {
	c := cs.byID[e.id]
	if c != nil {
		if e.failed {
			cs.end(c)
		} else {
			c.session = e.session
		}
	}
	return cs.s.ready(e.id, e.text)
}

// image takes a frame Chrome made for cast id.
func (cs *casts) image(id int64, f chromeFrame) error {
	c := cs.byID[id]
	if c == nil {
		cs.b.ackFrame(f)
		return nil
	}
	if c.sent == nil {
		return cs.send(c, f)
	}
	if c.held != nil {
		c.dropped = append(c.dropped, *c.held)
	}
	c.held = &f
	return nil
}

func (cs *casts) send(c *cast, f chromeFrame) error {
	c.seq++
	c.sent, c.shown = &f, &f
	return cs.s.write(imageMessage{T: "image", ID: c.id, Seq: c.seq, JPEG: f.data})
}

// seen takes the host's acknowledgement of image seq of cast id: Chrome is
// told, and the newest frame since goes. Any other acknowledgement, of an
// image not the one unacknowledged or of a cast that ended, changes
// nothing.
func (cs *casts) seen(id, seq int64) error {
	c := cs.byID[id]
	if c == nil || c.sent == nil || seq != c.seq {
		return nil
	}
	cs.release(c)
	if held := c.held; held != nil {
		c.held = nil
		return cs.send(c, *held)
	}
	return nil
}

// release tells Chrome of every frame the cast holds but the newest.
func (cs *casts) release(c *cast) {
	if c.sent != nil {
		cs.b.ackFrame(*c.sent)
	}
	for _, f := range c.dropped {
		cs.b.ackFrame(f)
	}
	c.sent, c.dropped = nil, nil
}

// uncast ends cast id as the host asked.
func (cs *casts) uncast(id int64) {
	if c := cs.byID[id]; c != nil {
		cs.end(c)
	}
}

// ended ends cast id, whose window closed, and tells the host.
func (cs *casts) ended(id int64) error {
	c := cs.byID[id]
	if c == nil {
		return nil
	}
	cs.end(c)
	return cs.s.write(uncastMessage{T: "uncast", ID: id})
}

func (cs *casts) end(c *cast) {
	delete(cs.byID, c.id)
	c.cancel()
	cs.release(c)
	if c.held != nil {
		cs.b.ackFrame(*c.held)
		c.held = nil
	}
	close(c.input)
}

// input sends the person's input to cast id's window, mapped onto the
// window as the last image sent shows it. Input for a cast that ended,
// or that has sent no image, is dropped, as is input past castInputs
// messages waiting.
func (cs *casts) input(id int64, events []inputEvent) {
	c := cs.byID[id]
	if c == nil || c.shown == nil || c.session == "" {
		return
	}
	calls := make([]cdpInput, len(events))
	for i, ev := range events {
		calls[i] = ev.call(c.shown.width, c.shown.height)
	}
	select {
	case c.input <- inputBatch{session: c.session, calls: calls}:
	default:
	}
}

// stop ends every cast, when the driver ends.
func (cs *casts) stop() {
	for _, c := range cs.byID {
		cs.end(c)
	}
}

// runCast casts window win until ctx ends or the window closes, reporting
// its start, each frame and its window's end on events. A cast that
// replaces another of its window starts once that one has stopped (after).
func (b *browser) runCast(ctx context.Context, id int64, win string, done chan<- struct{}, after <-chan struct{},
	width, height int, events chan<- event) {
	defer close(done)
	// A cast's start is always answered, so its request is never left
	// running; an image or an end of a cast that has ended is not sent.
	casting := func(e event) { events <- e }
	report := func(e event) bool {
		select {
		case events <- e:
			return true
		case <-ctx.Done():
			return false
		}
	}
	fail := func(err error) { casting(event{kind: "casting", id: id, text: answer(nil, err), failed: true}) }
	if after != nil {
		select {
		case <-after:
		case <-ctx.Done():
			fail(context.Canceled)
			return
		}
	}
	start, cancel := context.WithTimeout(ctx, opWait)
	defer cancel()
	w, _, err := b.window(start, win, false)
	if err != nil {
		fail(err)
		return
	}
	frames := b.c.watch(w.session, func(method string, _ json.RawMessage) bool { return method == "Page.screencastFrame" })
	defer b.c.unwatch(frames)
	quality := castQuality
	if err := b.screencast(start, w.session, quality, width, height); err != nil {
		fail(err)
		return
	}
	casting(event{kind: "casting", id: id, session: w.session, text: answer(struct{}{}, nil)})
	for {
		next, err := frames.next(ctx)
		if err != nil {
			if ctx.Err() != nil {
				b.stopScreencast(w.session)
			} else {
				report(event{kind: "castend", id: id})
			}
			return
		}
		f, ok := frameOf(w.session, next.params)
		if !ok {
			continue
		}
		if len(f.data) > maxImage {
			// Too large for one message: Chrome is told, and the cast
			// goes on at a lower quality, then at a smaller size; one too
			// large at the least of both ends.
			b.ackFrame(f)
			switch {
			case quality > castFloor:
				quality = max(quality-castStep, castFloor)
			case width > minCastSide || height > minCastSide:
				width, height = max(width/2, minCastSide), max(height/2, minCastSide)
			default:
				b.stopScreencast(w.session)
				report(event{kind: "castend", id: id})
				return
			}
			// Chrome refuses a start while its screencast runs, so it is
			// stopped first.
			b.stopScreencast(w.session)
			again, cancel := context.WithTimeout(ctx, opWait)
			err := b.screencast(again, w.session, quality, width, height)
			cancel()
			if err != nil && ctx.Err() == nil {
				report(event{kind: "castend", id: id})
				return
			}
			// The frames that came before the restart's answer were made
			// as before it: Chrome is told of them, and none steps the cast
			// down again.
			for _, stale := range frames.drain() {
				if f, ok := frameOf(w.session, stale.params); ok {
					b.ackFrame(f)
				}
			}
			continue
		}
		if !report(event{kind: "image", id: id, frame: f}) {
			b.ackFrame(f)
			b.stopScreencast(w.session)
			return
		}
	}
}

func frameOf(session string, params json.RawMessage) (chromeFrame, bool) {
	var p struct {
		Data      string `json:"data"`
		SessionID int64  `json:"sessionId"`
		Metadata  struct {
			DeviceWidth  float64 `json:"deviceWidth"`
			DeviceHeight float64 `json:"deviceHeight"`
		} `json:"metadata"`
	}
	if json.Unmarshal(params, &p) != nil || p.Data == "" {
		return chromeFrame{}, false
	}
	return chromeFrame{data: p.Data, ack: p.SessionID, session: session,
		width: p.Metadata.DeviceWidth, height: p.Metadata.DeviceHeight}, true
}

func (b *browser) screencast(ctx context.Context, session string, quality, width, height int) error {
	return b.c.call(ctx, session, "Page.startScreencast", map[string]any{
		"format": "jpeg", "quality": quality, "maxWidth": width, "maxHeight": height, "everyNthFrame": 1,
	}, nil)
}

func (b *browser) stopScreencast(session string) {
	ctx, cancel := context.WithTimeout(context.Background(), opWait)
	defer cancel()
	_ = b.c.call(ctx, session, "Page.stopScreencast", nil, nil)
}

// ackFrame tells Chrome a frame was taken, so it makes the next.
func (b *browser) ackFrame(f chromeFrame) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), opWait)
		defer cancel()
		_ = b.c.call(ctx, f.session, "Page.screencastFrameAck", map[string]any{"sessionId": f.ack}, nil)
	}()
}

// runInput dispatches the person's input in the order it came, each call
// on its window's session directly, so it lands beside a request that
// holds the window. Every call carries the cast's own context, so once the
// cast ended nothing of it is written (cdp.call), whatever was queued.
func (b *browser) runInput(ctx context.Context, batches <-chan inputBatch) {
	for batch := range batches {
		for _, call := range batch.calls {
			one, cancel := context.WithTimeout(ctx, opWait)
			err := b.c.call(one, batch.session, call.method, call.params, nil)
			cancel()
			if errors.Is(err, errDetached) || ctx.Err() != nil {
				break
			}
		}
	}
}

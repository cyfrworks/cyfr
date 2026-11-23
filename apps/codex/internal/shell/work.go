// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"errors"
	"sync"
)

// Work is everything begun for one CYFR opened from a folder on this
// computer: its one cancellation, the readings begun under it and the
// processes started under it. Each begins through Start and no other way,
// with a context Join made, which ends with the Work. Starting and ending
// are decided under its one lock: once End has returned nothing starts,
// and a start that lost the race to End is refused, never begun and then
// stopped. End waits on no reading, process or answer, only on a start
// holding the lock: the start of a process (fork and exec), or of a
// goroutine.
//
// The screen's Work ends as its pages stop, and as the screen returns;
// the CYFR app's, when the app lets go of that CYFR or selects another.
type Work struct {
	mu sync.Mutex
	// ctx is cancelled only under mu, by End, so that a start holding mu
	// sees whether the Work ended, and the answer holds until it lets go.
	ctx    context.Context
	cancel context.CancelFunc
}

// ErrEnded refuses a start under a Work that has ended.
var ErrEnded = errors.New("CYFR here was let go of before it was asked")

// NewWork is a Work that ends at End or when parent ends.
func NewWork(parent context.Context) *Work {
	ctx, cancel := context.WithCancel(context.WithoutCancel(parent))
	w := &Work{ctx: ctx, cancel: cancel}
	// The parent is let go of once w ends, whatever ended it.
	unhook := context.AfterFunc(parent, w.End)
	context.AfterFunc(ctx, func() { unhook() })
	return w
}

// End ends w: every context Join made ends, and nothing starts under w
// again.
func (w *Work) End() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.cancel()
}

// Context ends with w.
func (w *Work) Context() context.Context { return w.ctx }

// Join is ctx ending as well when w does, and its stop, which lets go of
// it.
func (w *Work) Join(ctx context.Context) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(ctx)
	unhook := context.AfterFunc(w.ctx, cancel)
	return ctx, func() {
		unhook()
		cancel()
	}
}

// Start calls start under w's lock, unless w has ended (ErrEnded) or ctx
// has (its error): then start is not called. start begins what it begins
// and returns; what it began ends with a context Join made.
func (w *Work) Start(ctx context.Context, start func() error) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	switch {
	case w.ctx.Err() != nil:
		return ErrEnded
	case ctx.Err() != nil:
		return ctx.Err()
	}
	return start()
}

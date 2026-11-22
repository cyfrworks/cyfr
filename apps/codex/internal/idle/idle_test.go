// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package idle_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/idle"
	"github.com/cyfr/codex/internal/idle/idletest"
)

func started(t *testing.T, c *idletest.Compositor, after time.Duration) (idled chan struct{}, ended chan error) {
	t.Helper()
	w, err := idle.Start(t.Context(), c.Socket, after)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = w.Close() })
	idled, ended = make(chan struct{}, 8), make(chan error, 1)
	go func() { ended <- w.Run(func() { idled <- struct{}{} }) }()
	return idled, ended
}

func await[T any](t *testing.T, ch <-chan T, what string) T {
	t.Helper()
	select {
	case v := <-ch:
		return v
	case <-time.After(10 * time.Second):
		t.Fatalf("no %s", what)
		panic("unreachable")
	}
}

// A seat without input goes idle however a page holds the screen awake,
// and again for each later stretch without input.
func TestWatch_AnInhibitorDoesNotHoldOffTheIdle(t *testing.T) {
	for name, held := range map[string]bool{"nothing plays": false, "a page holds an inhibitor": true} {
		t.Run(name, func(t *testing.T) {
			c := idletest.Start(t, idletest.Options{Inhibited: held})
			idled, _ := started(t, c, 20*time.Millisecond)
			await(t, idled, "idle")
			c.Input()
			await(t, idled, "idle after the next input")
		})
	}
}

// A compositor the watch cannot rely on never starts one, and none falls
// back to the notification an inhibitor holds off.
func TestStart_Refuses(t *testing.T) {
	for name, c := range map[string]struct {
		options idletest.Options
		want    string
	}{
		"a notifier of version 1": {idletest.Options{Version: 1}, "cannot tell input"},
		"no notifier":             {idletest.Options{NoNotifier: true}, "cannot tell input"},
		"no seat":                 {idletest.Options{NoSeat: true}, "no seat"},
		"the compositor refuses":  {idletest.Options{Refusal: "not here"}, "refused: not here"},
	} {
		t.Run(name, func(t *testing.T) {
			comp := idletest.Start(t, c.options)
			w, err := idle.Start(t.Context(), comp.Socket, time.Minute)
			if err == nil {
				_ = w.Close()
				t.Fatal("a watch started")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("err = %v, want %q", err, c.want)
			}
			if c.options.Refusal != "" {
				return
			}
			select {
			case asked := <-comp.Asked:
				t.Errorf("it asked for %+v all the same", asked)
			default:
			}
		})
	}
	t.Run("a compositor that answers nothing", func(t *testing.T) {
		comp := idletest.Start(t, idletest.Options{Silent: true})
		ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
		defer cancel()
		if w, err := idle.Start(ctx, comp.Socket, time.Minute); err == nil {
			_ = w.Close()
			t.Fatal("a watch started")
		}
	})
}

// A watch that can tell no more ends, so its owner can lock.
func TestWatch_EndsWhenItCanTellNoMore(t *testing.T) {
	for name, lose := range map[string]func(c *idletest.Compositor){
		"the compositor went": func(c *idletest.Compositor) { c.Stop() },
		"its seat went":       func(c *idletest.Compositor) { c.Remove(idletest.SeatName) },
		"its notifier went":   func(c *idletest.Compositor) { c.Remove(idletest.NotifierName) },
	} {
		t.Run(name, func(t *testing.T) {
			c := idletest.Start(t, idletest.Options{})
			_, ended := started(t, c, time.Hour)
			lose(c)
			if err := await(t, ended, "end of the watch"); err == nil {
				t.Fatal("the watch ended saying nothing")
			}
		})
	}
}

func TestSocket(t *testing.T) {
	for _, c := range []struct{ display, dir, want string }{
		{"wayland-0", "/run/user/1000", "/run/user/1000/wayland-0"},
		{"/tmp/w", "", "/tmp/w"},
		{"", "/run/user/1000", ""},
		{"wayland-0", "", ""},
	} {
		t.Setenv("WAYLAND_DISPLAY", c.display)
		t.Setenv("XDG_RUNTIME_DIR", c.dir)
		if got, err := idle.Socket(); got != c.want || (err == nil) != (c.want != "") {
			t.Errorf("Socket() with %q in %q = %q, %v; want %q", c.display, c.dir, got, err, c.want)
		}
	}
}

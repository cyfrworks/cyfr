// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestReview_LiveIdleChannelAnswersBothPeersPings(t *testing.T) {
	oldEvery, oldWithin := reportEvery, heardWithin
	reportEvery, heardWithin = 30*time.Millisecond, 300*time.Millisecond
	t.Cleanup(func() { reportEvery, heardWithin = oldEvery, oldWithin })
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	setUpAndOpen(t, home, b)
	home.mu.Lock()
	peer := home.conns[len(home.conns)-1]
	initial := len(home.capabilities)
	home.mu.Unlock()
	for i := 0; i < 5; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		err := peer.Ping(ctx)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		home.mu.Lock()
		reports := len(home.capabilities) - initial
		home.mu.Unlock()
		if !b.shell.Unlocked() {
			t.Fatalf("a live idle box locked: %s", b.page())
		}
		if reports >= 10 {
			t.Logf("box remains unlocked after %d reports and five server pings", reports)
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("live idle box did not keep reporting")
}

func TestReview_CloseDuringReportPreservesReason(t *testing.T) {
	oldEvery, oldWithin := reportEvery, heardWithin
	reportEvery, heardWithin = time.Millisecond, time.Second
	t.Cleanup(func() { reportEvery, heardWithin = oldEvery, oldWithin })
	for _, tc := range []struct {
		name string
		code websocket.StatusCode
		want error
	}{{"revoked", 4403, ErrRevoked}, {"renew", 4408, ErrRenew}} {
		t.Run(tc.name, func(t *testing.T) {
			home := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				conn, err := websocket.Accept(w, r, nil)
				if err != nil {
					return
				}
				defer conn.CloseNow()
				if _, _, err := conn.Read(r.Context()); err == nil {
					_ = conn.Close(tc.code, tc.name)
				}
			}))
			defer home.Close()
			wrong := 0
			var first error
			for i := 0; i < 500; i++ {
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(home.URL, "http"), nil)
				if err != nil {
					cancel()
					t.Fatal(err)
				}
				c := &Channel{conn: conn, report: func() []string { return nil }, waiting: map[string]chan answer{}, done: make(chan struct{})}
				readDone, reportDone := make(chan struct{}), make(chan struct{})
				go func() { defer close(readDone); c.read() }()
				go func() { defer close(reportDone); c.reportLoop() }()
				select {
				case <-c.Done():
				case <-ctx.Done():
					t.Fatal("channel did not end")
				}
				if err := c.Err(); !errors.Is(err, tc.want) {
					wrong++
					if first == nil {
						first = err
					}
				}
				conn.CloseNow()
				<-readDone
				<-reportDone
				cancel()
			}
			if wrong != 0 {
				t.Errorf("%d of 500 closes with code %d lost %v; first error = %v", wrong, tc.code, tc.want, first)
			}
		})
	}
}

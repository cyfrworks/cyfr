// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"errors"
	"net"
	"net/netip"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/locus/keeper/internal/logx"
)

// fakeGuard serves the control on a socket of the test's own, recording
// each run of the guard script its server would make.
type fakeGuard struct {
	path string
	mu   sync.Mutex
	runs [][]string
	fail bool
}

func startFake(t *testing.T, netns string) *fakeGuard {
	t.Helper()
	f := &fakeGuard{path: filepath.Join(t.TempDir(), "guard.sock")}
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: f.path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	s := &server{log: logx.New("cyfr-guard-test"), ranges: []Range{{20001, 20032}, {40001, 49999}}, netns: netns,
		apply: func(args ...string) error {
			f.mu.Lock()
			defer f.mu.Unlock()
			f.runs = append(f.runs, args)
			if f.fail {
				return errors.New("forced failure")
			}
			return nil
		}}
	go func() {
		for {
			conn, err := l.AcceptUnix()
			if err != nil {
				return
			}
			go s.serve(conn)
		}
	}()
	return f
}

func (f *fakeGuard) taken() [][]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([][]string(nil), f.runs...)
}

func TestAdmitAndClear(t *testing.T) {
	f := startFake(t, "net:[1]")
	c := NewClient(f.path, "net:[1]")
	addrs := []netip.Addr{netip.MustParseAddr("1.2.3.4"), netip.MustParseAddr("::ffff:5.6.7.8"), netip.MustParseAddr("2606:4700::1111")}
	if err := c.Admit(40001, addrs); err != nil {
		t.Fatal(err)
	}
	if err := c.Clear(20001); err != nil {
		t.Fatal(err)
	}
	want := [][]string{{"admit", "40001", "1.2.3.4", "5.6.7.8", "2606:4700::1111"}, {"clear", "20001"}}
	if got := f.taken(); !reflect.DeepEqual(got, want) {
		t.Fatalf("the guard ran %v, want %v", got, want)
	}
}

func TestRefusals(t *testing.T) {
	f := startFake(t, "net:[1]")
	c := NewClient(f.path, "net:[1]")
	if err := c.Admit(30001, []netip.Addr{netip.MustParseAddr("1.2.3.4")}); err == nil || !strings.Contains(err.Error(), "no spawn's") {
		t.Fatalf("a uid outside the ranges was not refused: %v", err)
	}
	if len(f.taken()) != 0 {
		t.Fatal("a refused request ran the guard")
	}
	f.fail = true
	if err := c.Clear(40001); err == nil || !strings.Contains(err.Error(), "could not install") {
		t.Fatalf("a failed change was not refused: %v", err)
	}
	f.fail = false
	if err := c.Clear(40001); err != nil {
		t.Fatalf("the connection did not survive a refusal: %v", err)
	}
	if err := c.Admit(40001, nil); err == nil {
		t.Fatal("an admit of no address was sent")
	}
}

func TestOtherNamespaceIsNoGuard(t *testing.T) {
	f := startFake(t, "net:[2]")
	c := NewClient(f.path, "net:[1]")
	err := c.Clear(40001)
	if err == nil || !strings.Contains(err.Error(), "recreated") {
		t.Fatalf("a guard of another namespace was taken: %v", err)
	}
	if len(f.taken()) != 0 {
		t.Fatal("a request reached a guard of another namespace")
	}
}

func TestNoGuardIsAnError(t *testing.T) {
	c := NewClient(filepath.Join(t.TempDir(), "absent.sock"), "net:[1]")
	if err := c.Clear(40001); err == nil {
		t.Fatal("a guard that is not there answered")
	}
}

// A connection that ends leaves every uid it admitted, and did not clear
// since, refused every public address.
func TestLostConnectionRefusesItsUIDs(t *testing.T) {
	f := startFake(t, "net:[1]")
	c := NewClient(f.path, "net:[1]")
	one := []netip.Addr{netip.MustParseAddr("1.2.3.4")}
	for _, uid := range []int{40002, 40001, 20005} {
		if err := c.Admit(uid, one); err != nil {
			t.Fatal(err)
		}
	}
	if err := c.Clear(20005); err != nil {
		t.Fatal(err)
	}
	c.mu.Lock()
	c.drop()
	c.mu.Unlock()
	deadline := time.Now().Add(5 * time.Second)
	for len(f.taken()) < 6 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	got := f.taken()[4:]
	if want := [][]string{{"admit", "40001"}, {"admit", "40002"}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("after the connection ended the guard ran %v, want %v", got, want)
	}
	// The client dials again.
	if err := c.Clear(40001); err != nil {
		t.Fatal(err)
	}
}

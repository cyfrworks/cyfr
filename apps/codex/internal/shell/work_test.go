// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"net"
	"net/http"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Starting and ending are decided under one lock: once End has returned,
// no start runs, however many race it; every start before it ran whole;
// a start that lost is refused, its work never begun.
func TestWork_NothingStartsOnceItEnded(t *testing.T) {
	for range 300 {
		w := NewWork(t.Context())
		var ended atomic.Bool
		var began, after atomic.Int64
		var all sync.WaitGroup
		for range 8 {
			all.Go(func() {
				for {
					err := w.Start(t.Context(), func() error {
						if ended.Load() {
							after.Add(1)
						}
						began.Add(1)
						return nil
					})
					if err != nil {
						if !errors.Is(err, ErrEnded) {
							t.Errorf("a start was refused with %v", err)
						}
						return
					}
				}
			})
		}
		for began.Load() < 20 {
			// Spins until the starts race the end below.
		}
		w.End()
		ended.Store(true)
		all.Wait()
		if n := after.Load(); n != 0 {
			t.Fatalf("%d starts began after End returned", n)
		}
		if w.Context().Err() == nil {
			t.Fatal("the Work's context outlived its end")
		}
	}
}

// End waits on nothing begun: a reading still running, a caller's context
// still live. What was begun hears the end on its context.
func TestWork_EndWaitsOnNothingBegun(t *testing.T) {
	w := NewWork(t.Context())
	release := make(chan struct{})
	defer close(release)
	heard := make(chan error, 1)
	joined, stop := w.Join(t.Context())
	defer stop()
	if err := w.Start(t.Context(), func() error {
		go func() {
			<-joined.Done()
			heard <- joined.Err()
			<-release
		}()
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	returns(t, "End", w.End)
	select {
	case err := <-heard:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("the reading heard %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the reading never heard the end")
	}
	if err := w.Start(t.Context(), func() error { t.Error("a start ran after the end"); return nil }); !errors.Is(err, ErrEnded) {
		t.Fatalf("a start after the end answered %v", err)
	}
}

// A Work ends with its parent.
func TestWork_EndsWithItsParent(t *testing.T) {
	parent, cancel := context.WithCancel(t.Context())
	w := NewWork(parent)
	cancel()
	select {
	case <-w.Context().Done():
	case <-time.After(5 * time.Second):
		t.Fatal("the Work outlived its parent")
	}
	if err := w.Start(t.Context(), func() error { t.Error("a start ran after the end"); return nil }); !errors.Is(err, ErrEnded) {
		t.Fatalf("a start after the end answered %v", err)
	}
}

// A page that got as far as its reading only once the pages stopped
// begins none: neither the terms read nor Docker's, though it was served
// before the end. Its request's context ended with the Work (Sol's 4546
// probe).
func TestServer_NoReadingBeginsOnceThePagesStopped(t *testing.T) {
	home := newFakeHome(t)
	atView, goOn := make(chan struct{}), make(chan struct{})
	letGo := sync.OnceFunc(func() { close(goOn) })
	defer letGo()
	terms := make(chan error, 1)
	var asked atomic.Bool
	b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), func(c *Config) {
		c.Unwatched = func() string { close(atView); <-goOn; return "" }
		c.Client = &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
			terms <- r.Context().Err()
			return http.DefaultTransport.RoundTrip(r)
		})}
	})
	b.srv.Reachable = func(context.Context) error { asked.Store(true); return nil }
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	served := make(chan error, 1)
	go func() { served <- b.srv.ServeOn(ctx, ln) }()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, "http://"+ln.Addr().String()+"/", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Host = Listen
	done := make(chan struct{})
	go func() {
		defer close(done)
		if r, err := http.DefaultClient.Do(req); err == nil {
			r.Body.Close()
		}
	}()
	select {
	case <-atView:
	case <-time.After(5 * time.Second):
		t.Fatal("the page never reached its view")
	}
	b.shell.Lock("")
	cancel()
	select {
	case <-served:
	case <-time.After(5 * time.Second):
		t.Fatal("the pages never stopped")
	}
	letGo()
	<-done
	select {
	case err := <-terms:
		t.Fatalf("the page began a terms read once the pages stopped (its context: %v)", err)
	case <-time.After(300 * time.Millisecond): // sleep-ok: a bounded look for a request that must not come
	}
	if asked.Load() {
		t.Fatal("the page began a reading once the pages stopped")
	}
}

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Every reading the pages begin, and every terms read, begins on the
// rosters below, each proved under an ended Work: a reading begun
// elsewhere fails here by being absent.
func TestServer_EveryReadingBeginsUnderTheWork(t *testing.T) {
	found := map[string][]string{}
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		tree, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range tree.Decls {
			name := file + "'s declarations"
			if f, ok := d.(*ast.FuncDecl); ok {
				name = f.Name.Name
			}
			ast.Inspect(d, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				if sel, ok := call.Fun.(*ast.SelectorExpr); ok && (sel.Sel.Name == "Reachable" || sel.Sel.Name == "readTerms" || sel.Sel.Name == "SetupToken") {
					found[sel.Sel.Name] = append(found[sel.Sel.Name], name)
				}
				return true
			})
		}
	}
	for how, want := range map[string][]string{
		// read: begun by Work.Start (TestServer_NoReadingBeginsOnceThePagesStopped).
		"Reachable": {"read"},
		// read, and a page's own on its request's context, which ends with
		// the Work (TestServer_ARequestsContextEndsWithTheWork).
		"readTerms": {"read", "server.go's declarations"},
		// A first hello's, on an action's context; the token's reading of
		// a folder begins its work under the Work (cmd's roster).
		"SetupToken": {"admission"},
	} {
		got := slices.Compact(slices.Sorted(slices.Values(found[how])))
		if !slices.Equal(got, want) {
			t.Errorf("%s is called in %v, and the roster says %v", how, got, want)
		}
	}
}

// A request's context ends with the pages' Work: a page's own terms read
// in flight hears the end at once, not at its own bound.
func TestServer_ARequestsContextEndsWithTheWork(t *testing.T) {
	home := newFakeHome(t)
	entered := make(chan context.Context, 1)
	b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), func(c *Config) {
		c.Client = &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
			entered <- r.Context()
			<-r.Context().Done()
			return nil, r.Context().Err()
		})}
	})
	go b.aloud()
	var ctx context.Context
	select {
	case ctx = <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("the page read no terms")
	}
	began := time.Now()
	b.srv.Work.End()
	select {
	case <-ctx.Done():
	case <-time.After(termsWithin):
	}
	if !errors.Is(ctx.Err(), context.Canceled) || time.Since(began) > termsWithin/2 {
		t.Fatalf("the request's terms read heard %v after %v", ctx.Err(), time.Since(began))
	}
}

// A screen page's reading already in flight hears the Work's end at once,
// its terms read and its reading of the home alike, not at their own
// bounds.
func TestServer_AReadingInFlightEndsWithTheWork(t *testing.T) {
	home := newFakeHome(t)
	entered := make(chan context.Context, 2)
	b := newBoxAt(t, home, t.TempDir(), home.accounts.URL(), func(c *Config) {
		c.Client = &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
			entered <- r.Context()
			<-r.Context().Done()
			return nil, r.Context().Err()
		})}
	})
	b.srv.Reachable = func(ctx context.Context) error {
		entered <- ctx
		<-ctx.Done()
		return ctx.Err()
	}
	returns(t, "the setup page", func() { b.aloud() })
	began := time.Now()
	for i, what := range []string{"the terms read", "the reading of the home"} {
		var ctx context.Context
		select {
		case ctx = <-entered:
		case <-time.After(termsWithin):
			t.Fatalf("%s never began", what)
		}
		if i == 0 {
			b.srv.Work.End()
		}
		select {
		case <-ctx.Done():
		case <-time.After(termsWithin):
		}
		if !errors.Is(ctx.Err(), context.Canceled) || time.Since(began) > termsWithin/2 {
			t.Fatalf("%s heard %v after %v", what, ctx.Err(), time.Since(began))
		}
	}
}

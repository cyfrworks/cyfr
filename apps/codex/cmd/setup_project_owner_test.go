// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/shell"
)

// Setup's work begins only through a folder's Work: these are every
// function that names what begins it, and each is proved below under an
// ended Work (TestNothingBeginsOnceTheFoldersWorkEnded). A start added
// elsewhere fails here by being absent.
func TestEveryWorkStartIsUnderTheFoldersWork(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	names := []string{"workBegunBy", "beginUnder", "preparer", "prepare", "workGroup", "startWork"}
	found := map[string][]string{}
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		tree, err := parser.ParseFile(token.NewFileSet(), file, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range tree.Decls {
			f, ok := d.(*ast.FuncDecl)
			if !ok {
				continue
			}
			ast.Inspect(f.Body, func(n ast.Node) bool {
				var name string
				switch n := n.(type) {
				case *ast.Ident:
					name = n.Name
				case *ast.SelectorExpr:
					name = n.Sel.Name
				}
				if slices.Contains(names, name) {
					found[name] = append(found[name], f.Name.Name)
				}
				return true
			})
		}
	}
	for _, name := range names {
		found[name] = slices.Compact(slices.Sorted(slices.Values(found[name])))
	}
	want := map[string][]string{
		// The two that ask setup's work: a folder's reading (look) and
		// the rest (setupWork), each under a Work.
		"workBegunBy": {"look", "setupWork"},
		"beginUnder":  {"openFolder", "setupWork"},
		"preparer":    {"openFolder", "setupWork"},
		"prepare":     {"beginUnder", "preparer"},
		"startWork":   {"preparer"},
		"workGroup":   {"prepare"},
	}
	for _, name := range names {
		if !slices.Equal(found[name], want[name]) {
			t.Errorf("%s is named in %v, and the roster says %v", name, found[name], want[name])
		}
	}
}

// countedWork stands in for the launcher, counting the work begun.
func countedWork(t *testing.T) *atomic.Int64 {
	t.Helper()
	var begun atomic.Int64
	saved, savedDial := startWork, dialTCP
	t.Cleanup(func() { startWork, dialTCP = saved, savedDial })
	startWork = func(context.Context, []string) (workBegin, error) {
		return func() (*workProcess, error) {
			begun.Add(1)
			_, in := io.Pipe()
			return &workProcess{in: in, out: strings.NewReader(`{"type":"done"}` + "\n"), wait: func() error { return nil }, kill: func() {}}, nil
		}, nil
	}
	dialTCP = func(context.Context, string, string) (net.Conn, error) {
		return nil, errors.New("the test makes no connection")
	}
	return &begun
}

// Every way a folder's CYFR is read, and setup's work asked, begins its
// work while the folder's Work lives and none once it ended: the screen's
// reading and the app's (Answers), the token's read, a page's request to
// the CYFR, and setup's work asked.
func TestNothingBeginsOnceTheFoldersWorkEnded(t *testing.T) {
	for name, ask := range map[string]func(ctx context.Context, work *shell.Work, l desktop.Local){
		"a reading": func(ctx context.Context, _ *shell.Work, l desktop.Local) { _ = l.Answers(ctx) },
		"the token": func(ctx context.Context, _ *shell.Work, l desktop.Local) { _, _ = l.Shell.SetupToken(ctx) },
		"a page's request": func(ctx context.Context, _ *shell.Work, l desktop.Local) {
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, l.Shell.Address+"/", nil)
			if err != nil {
				t.Fatal(err)
			}
			if resp, err := l.Shell.Client.Do(req); err == nil {
				resp.Body.Close()
			}
		},
		"setup's work": func(ctx context.Context, work *shell.Work, _ desktop.Local) {
			_, _ = setupWork(ctx, work, nil, workProbe)
		},
	} {
		t.Run(name, func(t *testing.T) {
			for _, ended := range []bool{false, true} {
				begun := countedWork(t)
				work := shell.NewWork(t.Context())
				l, err := readLocal(work, setUpFolder(t), "the test")
				if err != nil {
					t.Fatal(err)
				}
				if ended {
					work.End()
				}
				ask(t.Context(), work, l)
				switch n := begun.Load(); {
				case ended && n != 0:
					t.Fatalf("%d works began once the Work ended", n)
				case !ended && n == 0:
					t.Fatal("no work began while the Work lived")
				}
			}
		})
	}
}

// A start refused at its begin begins nothing, whether its caller went or
// the Work ended while the launcher made it ready (Sol's 4546 probe):
// the decision is under the Work's lock, at the begin itself.
func TestAStartThatLostItsRaceBeginsNothing(t *testing.T) {
	for name, c := range map[string]struct {
		end  func(cancel func(), work *shell.Work)
		want error
	}{
		"its caller went": {end: func(cancel func(), _ *shell.Work) { cancel() }, want: context.Canceled},
		"the Work ended":  {end: func(_ func(), work *shell.Work) { work.End() }, want: shell.ErrEnded},
	} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			work := shell.NewWork(t.Context())
			l := newWorkLauncher()
			l.system = "darwin"
			keeps := l.keeps
			l.keeps = func(name string) bool {
				c.end(cancel, work)
				return keeps(name)
			}
			w, err := beginUnder(work, l.prepare)(ctx, []string{workProbe})
			if w != nil {
				w.in.Close()
				_ = w.wait()
				t.Fatal("a process began after the end")
			}
			if !errors.Is(err, c.want) {
				t.Fatalf("the begin answered %v, want %v", err, c.want)
			}
		})
	}
}

// Ending the Work waits on no launcher still making a start ready, and
// that start, once ready, is refused, never begun.
func TestEndingWaitsOnNoLauncher(t *testing.T) {
	starting, _, release := heldLauncher(t)
	held := startWork
	begun := countedWork(t)
	startWork = func(ctx context.Context, args []string) (workBegin, error) {
		_, _ = held(ctx, args)
		return func() (*workProcess, error) {
			begun.Add(1)
			return nil, errors.New("the test begins nothing")
		}, nil
	}
	work := shell.NewWork(t.Context())
	asked := make(chan error, 1)
	go func() {
		_, err := setupWork(context.WithoutCancel(t.Context()), work, nil, workProbe)
		asked <- err
	}()
	<-starting
	ended := make(chan struct{})
	go func() { work.End(); close(ended) }()
	select {
	case <-ended:
	case <-time.After(5 * time.Second):
		t.Fatal("ending the Work waited on its launcher")
	}
	release()
	if err := <-asked; !errors.Is(err, context.Canceled) && !errors.Is(err, shell.ErrEnded) {
		t.Fatalf("the reading answered %v, not its end", err)
	}
	if n := begun.Load(); n != 0 {
		t.Fatalf("%d works began once the Work ended", n)
	}
}

// A worker's done does not hide how it exited: its end is both.
func TestADoneThatExitedOtherwiseIsAFailure(t *testing.T) {
	_, in := io.Pipe()
	w := &workProcess{in: in, out: strings.NewReader(`{"type":"done","ready":true}` + "\n"),
		wait: func() error { return errors.New("exit status 3") }, kill: func() {}}
	m, err := workBegunBy(t.Context(), func(context.Context, []string) (*workProcess, error) { return w, nil }, nil, workProbe)
	if err == nil || !strings.Contains(err.Error(), "exit status 3") || !m.Ready {
		t.Fatalf("answered %+v and %v", m, err)
	}
}

// The backstop is armed in one place for every way a reading's work is
// told to stop, whichever of its pipes closed first: its stdout's end,
// its caller going, the Work ending, its caller going as it began. Each
// work still running then is killed at the bound, and not before. A run
// told to stop either way is never killed; neither is a work that ended.
func TestTheBackstopForEachWayTheWorkIsToldToStop(t *testing.T) {
	type way struct {
		// silent is whether its stdout ends at once.
		silent bool
		end    func(cancel func(), work *shell.Work)
		// asBegun is whether end comes inside the begin.
		asBegun bool
	}
	ways := map[string]way{
		"its stdout ended first":   {silent: true},
		"its caller went first":    {end: func(cancel func(), _ *shell.Work) { cancel() }},
		"the Work ended first":     {end: func(_ func(), work *shell.Work) { work.End() }},
		"its caller went as begun": {end: func(cancel func(), _ *shell.Work) { cancel() }, asBegun: true},
	}
	for name, c := range ways {
		for _, verb := range []string{workLook, workRun} {
			t.Run(name+", "+verb, func(t *testing.T) {
				t.Parallel()
				ctx, cancel := context.WithCancel(t.Context())
				defer cancel()
				work := shell.NewWork(t.Context())
				reader, in := io.Pipe()
				go func() { _, _ = io.Copy(io.Discard, reader) }()
				var out io.Reader = strings.NewReader("")
				if !c.silent {
					r, w := io.Pipe()
					defer w.Close()
					out = r
				}
				killed, release := make(chan time.Time, 1), make(chan struct{})
				defer close(release)
				p := &workProcess{in: in, out: out,
					wait: func() error { <-release; return nil },
					kill: func() { killed <- time.Now() }}
				// As setupWork asks it, with this work's own begin: the
				// subtests run side by side.
				prepare := func(context.Context, []string) (workBegin, error) {
					return func() (*workProcess, error) {
						if c.asBegun {
							c.end(cancel, work)
						}
						return p, nil
					}, nil
				}
				dir := t.TempDir()
				go func() {
					ctx, stop := work.Join(ctx)
					defer stop()
					_, _ = workBegunBy(ctx, beginUnder(work, prepare), nil, verb, dir)
				}()
				told := time.Now()
				if c.end != nil && !c.asBegun {
					// sleep-ok: lets the work begin before the end comes.
					time.Sleep(50 * time.Millisecond)
					told = time.Now()
					c.end(cancel, work)
				}
				select {
				case at := <-killed:
					if verb == workRun {
						t.Fatal("a run was killed")
					}
					if took := at.Sub(told); took < workEndsWithin-500*time.Millisecond {
						t.Fatalf("killed %v after it was told, before the bound", took)
					}
				case <-time.After(workEndsWithin + 2*time.Second):
					if verb != workRun {
						t.Fatal("the work outlived the bound")
					}
				}
			})
		}
	}
	t.Run("an ended work", func(t *testing.T) {
		t.Parallel()
		_, in := io.Pipe()
		killed := make(chan struct{}, 1)
		p := &workProcess{in: in, out: strings.NewReader(`{"type":"done"}` + "\n"), wait: func() error { return nil }, kill: func() { killed <- struct{}{} }}
		if _, err := workBegunBy(t.Context(), func(context.Context, []string) (*workProcess, error) { return p, nil }, nil, workLook, t.TempDir()); err != nil {
			t.Fatal(err)
		}
		select {
		case <-killed:
			t.Fatal("a work that ended was killed")
		case <-time.After(workEndsWithin + time.Second): // sleep-ok: a bounded look for a kill that must not come
		}
	})
}

// A remote Docker's failure says its own error, never the log-in
// sentence, though this process lacks the docker group its account is in
// (Sol's 4546 probe).
func TestARemoteDockerIsNoStaleGroup(t *testing.T) {
	s := newLocalStack(t)
	s.env(4321)
	s.answer("context.out", "tcp://docker.example:2376\n")
	saved, savedSg := machine, sgProgram
	t.Cleanup(func() { machine, sgProgram = saved, savedSg })
	machine.system = func() string { return "linux" }
	machine.groups = func(_ context.Context, account string) []string {
		if account != "" {
			return []string{dockerGroup}
		}
		return nil
	}
	sgProgram = filepath.Join(t.TempDir(), "no-sg")
	l, err := readLocal(shell.NewWork(t.Context()), s.project, "screen")
	if err != nil {
		t.Fatal(err)
	}
	err = l.Answers(t.Context())
	if err == nil || !strings.Contains(err.Error(), "runs containers on another computer") || strings.Contains(err.Error(), loginAgain) {
		t.Fatalf("a remote Docker gave: %v", err)
	}
}

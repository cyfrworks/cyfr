// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/prompt"
	"github.com/cyfr/codex/internal/version"
)

// blockAfter is a terminal's input that holds the lines answered and then
// blocks, as a person who stops typing does: asked is closed once a
// question reads past them. The read never ends, so a command a failing
// test leaves running answers nothing more, nor writes in the directory
// the test returns to.
func blockAfter(t *testing.T, lines ...string) (in *blockingInput, asked <-chan struct{}) {
	t.Helper()
	b := &blockingInput{rest: answersText(lines), asked: make(chan struct{})}
	return b, b.asked
}

func answersText(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	return strings.Join(lines, "\n") + "\n"
}

type blockingInput struct {
	rest  string
	asked chan struct{}
	once  sync.Once
}

func (b *blockingInput) Read(p []byte) (int, error) {
	if b.rest != "" {
		n := copy(p, b.rest)
		b.rest = b.rest[n:]
		return n, nil
	}
	b.once.Do(func() { close(b.asked) })
	select {}
}

// interruptAt runs command under a context cancelled once asked is
// closed, and answers its error; the command must end within a bound.
func interruptAt(t *testing.T, asked <-chan struct{}, command func(ctx context.Context) error) error {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- command(ctx) }()
	select {
	case <-asked:
	case err := <-done:
		t.Fatalf("the command ended before it asked: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("the command never asked")
	}
	cancel()
	select {
	case err := <-done:
		return err
	case <-time.After(10 * time.Second):
		t.Fatal("the question did not end on the interrupt")
		return nil
	}
}

// wantInterrupted fails unless err is an interrupted question's: its
// sentence, and exit status 130.
func wantInterrupted(t *testing.T, err error, sentence string) {
	t.Helper()
	if i := (interruption{}); !errors.As(err, &i) || err.Error() != sentence || ExitStatus(err) != exitInterrupted {
		t.Fatalf("the interrupted question answered %v (exit %d), want %q and exit %d", err, ExitStatus(err), sentence, exitInterrupted)
	}
}

// An interrupt at any of init's questions ends init there, before it
// writes a file, takes the lock or runs anything: on a release build the
// questions come before the scaffold's download and --force's removals.
func TestInitQuestionsEndOnAnInterrupt(t *testing.T) {
	for _, c := range []struct {
		name    string
		answers []string
		release bool
	}{
		{"the access question", nil, false},
		{"the machine name", []string{"1"}, false},
		{"the domain", []string{"2"}, false},
		{"the certificate email", []string{"2", "cyfr.example.com"}, false},
		{"the admin email", []string{"3"}, false},
		{"a release's access question, with --force", nil, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			newInitProject(t)
			s := useFakeEngine(t)
			kept := []string{".env.example"}
			o := initOptions{noPull: true}
			if c.release {
				savedVersion, savedDownload := version.Version, downloadScaffold
				t.Cleanup(func() { version.Version, downloadScaffold = savedVersion, savedDownload })
				version.Version = "0.6.0-alpha.1"
				downloadScaffold = func(string) error {
					t.Error("init downloaded the scaffold before its questions were answered")
					return nil
				}
				if err := os.WriteFile("docker-compose.yml", []byte("services: {}\n"), 0644); err != nil {
					t.Fatal(err)
				}
				kept = append(kept, "docker-compose.yml")
				o.force = true
			}
			in, asked := blockAfter(t, c.answers...)
			askTerminal = func() bool { return true }
			askInput = in
			var out bytes.Buffer
			err := interruptAt(t, asked, func(ctx context.Context) error { return runInit(ctx, o, &out, &out) })
			wantInterrupted(t, err, "Interrupted; nothing was written.")
			nothingWritten(t, kept...)
			if s.locks != 0 || len(s.joins) != 0 || len(s.switches) != 0 {
				t.Errorf("the interrupted init took the lock %d times, joined %v, switched %v", s.locks, s.joins, s.switches)
			}
		})
	}
}

// `cyfr access`'s questions end on an interrupt: before the join nothing
// is changed; after it the join is said to stand, and nothing is switched.
func TestAccessQuestionsEndOnAnInterrupt(t *testing.T) {
	for _, c := range []struct {
		name    string
		mode    string
		o       accessOptions
		answers []string
		want    string
		joins   int
	}{
		{"the change", access.ModePublic, accessOptions{domain: "cyfr.example.com"}, nil, "Interrupted; nothing was written.", 0},
		{"the join", access.ModeTailnet, accessOptions{hostname: "home"}, nil, "Interrupted; nothing was written.", 0},
		{"the change after the join", access.ModeTailnet, accessOptions{}, []string{"yes"},
			"Interrupted. This machine joined your tailnet as `cyfr.tail1234.ts.net`, and how this home is reached was not changed.", 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newAccessProject(t)
			before := read(t, ".env")
			in, asked := blockAfter(t, c.answers...)
			askTerminal = func() bool { return true }
			askInput = in
			err := interruptAt(t, asked, func(ctx context.Context) error {
				return runAccess(ctx, c.mode, c.o, false, "", &bytes.Buffer{})
			})
			wantInterrupted(t, err, c.want)
			if len(s.joins) != c.joins || len(s.switches) != 0 || read(t, ".env") != before {
				t.Errorf("the interrupted access joined %v and switched %v, want %d joins and no switch", s.joins, s.switches, c.joins)
			}
		})
	}
}

// The process prints an interrupted question's sentence alone, on stderr,
// and exits 130.
func TestAnInterruptedQuestionPrintsItsSentence(t *testing.T) {
	newInitProject(t)
	useFakeEngine(t)
	t.Cleanup(func() { _ = initCmd.Flags().Set("no-pull", "false") })
	in, asked := blockAfter(t)
	askTerminal = func() bool { return true }
	askInput = in
	var out string
	err := interruptAt(t, asked, func(ctx context.Context) error {
		var err error
		out, err = runLogin(t, ctx, "init", "--no-pull")
		return err
	})
	if ExitStatus(err) != exitInterrupted {
		t.Errorf("the interrupted init exits %d, want %d", ExitStatus(err), exitInterrupted)
	}
	if !strings.HasSuffix(out, "\nInterrupted; nothing was written.\n") || strings.Contains(out, "Error:") {
		t.Errorf("the interrupted init printed:\n%s", out)
	}
}

// A form ends when the command's context does, as prompt.ErrAborted.
func TestAFormEndsWithTheContext(t *testing.T) {
	in, asked := blockAfter(t)
	restore := prompt.UseTerminal(in, &bytes.Buffer{})
	t.Cleanup(restore)
	err := interruptAt(t, asked, func(ctx context.Context) error {
		_, err := prompt.SelectOne(ctx, "Pick one", []prompt.Option{{Label: "a", Value: "a"}})
		return err
	})
	if !errors.Is(err, prompt.ErrAborted) || ExitStatus(err) != exitInterrupted {
		t.Errorf("the form answered %v", err)
	}
}

// A release's init asks its questions before the scaffold's download; a
// download that fails with a warning lays down no .env.example, so no
// .env is written and init says the mode answered was not applied.
func TestInitSaysAnAnsweredModeWasNotAppliedWithoutATemplate(t *testing.T) {
	t.Chdir(t.TempDir())
	s := useFakeEngine(t)
	savedVersion, savedDownload := version.Version, downloadScaffold
	t.Cleanup(func() { version.Version, downloadScaffold = savedVersion, savedDownload })
	version.Version = "0.6.0-alpha.1"
	downloadScaffold = func(string) error { return errors.New("the release is offline") }
	askTerminal = func() bool { return true }
	askInput = strings.NewReader("1\n\n\n")
	var out bytes.Buffer
	err := runInit(context.Background(), initOptions{noPull: true}, &out, &out)
	if err == nil || err.Error() != "the home was not set up to be reached as answered (tailnet): there is no .env.example to write .env from" {
		t.Fatalf("init answered %v\n%s", err, out.String())
	}
	if fileExists(".env") || len(s.joins) != 0 || len(s.switches) != 0 {
		t.Errorf("init wrote .env (%v), joined %v or switched %v", fileExists(".env"), s.joins, s.switches)
	}
}

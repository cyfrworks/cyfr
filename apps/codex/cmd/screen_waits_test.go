//go:build linux

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/idle"
	"github.com/cyfr/codex/internal/idle/idletest"
)

// hungScreen is a screen whose key is on an account and whose Docker never
// answers, running until the test ends.
type hungScreen struct {
	*runningScreen
	compositor *idletest.Compositor
	passphrase string
	asked      string
	browser    string
}

func startHungScreen(t *testing.T, edit ...func(*holder.Record)) *hungScreen {
	t.Helper()
	screenProject(t)
	// The folder's account service too, or a test of making an account asks
	// cyfr.run.
	env, err := os.OpenFile(".env", os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = env.WriteString("CYFR_DIRECTORY_URL=http://127.0.0.1:9\n")
	if err = errors.Join(err, env.Close()); err != nil {
		t.Fatal(err)
	}
	passphrase, err := holder.GeneratePassphrase()
	if err != nil {
		t.Fatal(err)
	}
	rec, err := holder.NewSoftware([]byte(passphrase))
	if err != nil {
		t.Fatal(err)
	}
	// An account service on this computer that is not the folder's CYFR is
	// refused with nothing sent, so this test asks no network.
	rec.Identifier, rec.Directory = "per_"+strings.Repeat("e", 64), "http://127.0.0.1:9"
	for _, e := range edit {
		e(rec)
	}
	device := filepath.Join(os.Getenv("HOME"), ".cyfr", "device")
	if err := os.MkdirAll(device, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := rec.Create(filepath.Join(device, "holder.json")); err != nil {
		t.Fatal(err)
	}
	seen := t.TempDir()
	h := &hungScreen{passphrase: passphrase, asked: filepath.Join(seen, "asked"), browser: filepath.Join(seen, "browser")}
	h.compositor = screenCompositor(t, idletest.Options{})
	programs := quietScreen()
	// sleep-ok: stand-ins that run until what started them ends them
	programs["docker"] = "echo asked >>" + h.asked + "\nexec /bin/sleep 100"
	// sleep-ok: a stand-in child that runs until the shell ends it
	programs["google-chrome-stable"] = "echo $$ >>" + h.browser + "\nexec /bin/sleep 100"
	screenPrograms(t, programs)
	h.runningScreen = startScreen(t)
	return h
}

func (h *hungScreen) timesAsked() int {
	raw, _ := os.ReadFile(h.asked)
	return strings.Count(string(raw), "asked")
}

func (h *hungScreen) until(what string, ok func() bool) {
	h.t.Helper()
	for deadline := time.Now().Add(15 * time.Second); !ok(); {
		if time.Now().After(deadline) {
			h.t.Fatalf("never: %s", what)
		}
		time.Sleep(20 * time.Millisecond) // sleep-ok: polls an observable condition
	}
}

// unlocking begins an unlock and returns once Docker holds it.
func (h *hungScreen) unlocking() <-chan struct{} {
	h.t.Helper()
	h.shows(watchedPage)
	h.until("the page's reading reached Docker", func() bool { return h.timesAsked() > 0 })
	before := h.timesAsked()
	answered := make(chan struct{})
	go func() {
		defer close(answered)
		if resp, err := h.ask(http.MethodPost, "/unlock", url.Values{"secret": {h.passphrase}}); err == nil {
			resp.Body.Close()
		}
	}()
	h.until("the unlock reached Docker", func() bool { return h.timesAsked() > before })
	return answered
}

// soon is f, which is to wait for nothing Docker holds.
func (h *hungScreen) soon(what string, f func()) {
	h.t.Helper()
	began := time.Now()
	f()
	if took := time.Since(began); took > idle.AnswerWithin {
		h.t.Errorf("%s took %v", what, took)
	}
}

// With Docker never answering, the screen's page says at once that CYFR
// is starting, and says it again as it refreshes.
func TestScreenShell_AHungDockerHoldsUpNoPage(t *testing.T) {
	h := startHungScreen(t)
	h.shows(watchedPage)
	h.until("the page's reading reached Docker", func() bool { return h.timesAsked() > 0 })
	h.soon("a page beside the reading", func() {
		resp, err := h.ask(http.MethodGet, "/", nil)
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if page := html.UnescapeString(string(raw)); !strings.Contains(page, watchedPage) || !strings.Contains(page, `http-equiv="refresh"`) {
			t.Fatalf("the page is\n%s", page)
		}
	})
}

// A suspend locks at once beside an unlock Docker holds, and the watches
// take none of it for a sleep they were not told of.
func TestScreenShell_ASuspendWaitsForNoUnlock(t *testing.T) {
	said, err := os.Create(filepath.Join(t.TempDir(), "stderr"))
	if err != nil {
		t.Fatal(err)
	}
	stderr := os.Stderr
	os.Stderr = said
	t.Cleanup(func() {
		os.Stderr = stderr
		said.Close()
	})
	h := startHungScreen(t)
	unlocked := h.unlocking()
	if err := syscall.Kill(os.Getpid(), syscall.SIGUSR1); err != nil {
		t.Fatal(err)
	}
	h.soon("the suspend's lock", func() { <-unlocked })
	// sleep-ok: two looks of the watches, where a late lock would be seen
	time.Sleep(2*watchesTick + watchesTick/2)
	h.shows(watchedPage)
	if raw, _ := os.ReadFile(said.Name()); strings.Contains(string(raw), "this device slept") {
		t.Fatalf("the watches said %s", raw)
	}
}

// A lost watch says why at once beside an unlock Docker holds.
func TestScreenShell_ALostWatchWaitsForNoUnlock(t *testing.T) {
	h := startHungScreen(t)
	unlocked := h.unlocking()
	h.compositor.Stop()
	h.soon("the reason", func() { h.shows(idleUnwatched) })
	h.soon("the loss's lock", func() { <-unlocked })
}

// The browser's exit locks an unlock still in flight, which no page is
// left to finish for.
func TestScreenShell_TheBrowsersExitLocksAnUnlockInFlight(t *testing.T) {
	h := startHungScreen(t)
	pid := h.browserPID()
	unlocked := h.unlocking()
	if err := syscall.Kill(pid, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	h.soon("the browser's exit's lock", func() { <-unlocked })
}

// It locks with nothing in flight and no channel open too: the proof a
// typed passphrase handed the page ends with that page.
func TestScreenShell_TheBrowsersExitLocksWithNothingInFlight(t *testing.T) {
	h := startHungScreen(t, func(r *holder.Record) { r.Identifier, r.Directory = "", "" })
	pid := h.browserPID()
	post := func(path string, fields url.Values) string {
		resp, err := h.ask(http.MethodPost, path, fields)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			t.Fatal(err)
		}
		return html.UnescapeString(string(raw))
	}
	const onlyThatPage = "Only the page this device's PIN or passphrase was typed on can do that."
	_, after, ok := strings.Cut(post("/create", url.Values{"name": {"ada"}, "secret": {h.passphrase}}), `data-proof="`)
	proof, _, _ := strings.Cut(after, `"`)
	if !ok || proof == "" {
		t.Fatal("the typed passphrase handed its page no proof")
	}
	if page := post("/saved", url.Values{"proof": {proof}}); strings.Contains(page, onlyThatPage) {
		t.Fatalf("that page's proof was refused before the browser's exit:\n%s", page)
	}
	if err := syscall.Kill(pid, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	h.until("the browser started again", func() bool {
		raw, _ := os.ReadFile(h.browser)
		return strings.Count(string(raw), "\n") > 1
	})
	if page := post("/saved", url.Values{"proof": {proof}}); !strings.Contains(page, onlyThatPage) {
		t.Fatalf("the proof outlived the browser that held it:\n%s", page)
	}
}

// browserPID is the first browser's, once it runs.
func (h *hungScreen) browserPID() int {
	h.t.Helper()
	var pid int
	h.until("the browser runs", func() bool {
		raw, err := os.ReadFile(h.browser)
		if err != nil {
			return false
		}
		first, _, whole := strings.Cut(string(raw), "\n")
		pid, err = strconv.Atoi(first)
		return whole && err == nil && pid > 1
	})
	return pid
}

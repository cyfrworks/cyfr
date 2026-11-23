//go:build linux

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
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

	"github.com/cyfr/codex/internal/account/accounttest"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/idle"
	"github.com/cyfr/codex/internal/idle/idletest"
	"github.com/cyfr/codex/internal/version"
)

// hungScreen is a screen whose key is on an account and whose Docker never
// answers, running until the test ends.
type hungScreen struct {
	*runningScreen
	compositor *idletest.Compositor
	passphrase string
	asked      string
}

func startHungScreen(t *testing.T, edit ...func(*holder.Record)) *hungScreen {
	t.Helper()
	screenProject(t)
	// The folder's account service too, or a test of making an account asks
	// cyfr.run: the folder's own CYFR, which Docker never answers for.
	env, err := os.OpenFile(".env", os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = env.WriteString("CYFR_DIRECTORY_URL=http://localhost:4321\n")
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
	rec.Identifier, rec.Directory = "per_"+strings.Repeat("e", 64), "http://localhost:4321"
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
	h := &hungScreen{passphrase: passphrase, asked: filepath.Join(seen, "asked")}
	h.compositor = screenCompositor(t, idletest.Options{})
	programs := quietScreen()
	// sleep-ok: stand-ins that run until what started them ends them
	programs["docker"] = "echo asked $$ >>" + h.asked + "\nexec /bin/sleep 100"
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

// The app's lock (a page it lost, among others) locks an unlock still in
// flight, which no page is left to finish for.
func TestScreenShell_TheAppsLockLocksAnUnlockInFlight(t *testing.T) {
	h := startHungScreen(t)
	unlocked := h.unlocking()
	h.app.send(mainLocks)
	h.soon("the app's lock", func() { <-unlocked })
}

// It locks with nothing in flight and no channel open too: the proof a
// typed passphrase handed the page ends with that page.
func TestScreenShell_TheAppsLockLocksWithNothingInFlight(t *testing.T) {
	h := startHungScreen(t, func(r *holder.Record) { r.Identifier, r.Directory = "", "" })
	h.app.until("ready")
	post := h.posted
	_, after, ok := strings.Cut(post("/create", url.Values{"name": {"ada"}, "secret": {h.passphrase}}), `data-proof="`)
	proof, _, _ := strings.Cut(after, `"`)
	if !ok || proof == "" {
		t.Fatal("the typed passphrase handed its page no proof")
	}
	if page := post("/saved", url.Values{"proof": {proof}}); strings.Contains(page, onlyThatPage) {
		t.Fatalf("that page's proof was refused before the app's lock:\n%s", page)
	}
	h.app.send(mainLocks)
	h.app.until("locked")
	if page := post("/saved", url.Values{"proof": {proof}}); !strings.Contains(page, onlyThatPage) {
		t.Fatalf("the proof outlived the app's lock:\n%s", page)
	}
}

// A recovery code shown and not yet saved ends with the app's lock: the
// screen's next page is the account made again.
func TestScreenShell_TheAppsLockEndsAnUnsavedRecoveryCode(t *testing.T) {
	screenProject(t)
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	accounts := accounttest.New(t)
	at, err := url.Parse(accounts.URL())
	if err != nil {
		t.Fatal(err)
	}
	// The folder's own CYFR serves its accounts, so the test asks no network.
	home := "http://localhost:" + at.Port()
	env := "CYFR_ACCESS=local\nCYFR_PORT=" + at.Port() + "\nCYFR_SETUP_TOKEN=the-token\nCYFR_DIRECTORY_URL=" + home + "\n"
	if err := os.WriteFile(".env", []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	accounts.ServedAt(home)
	container, err := json.Marshal(map[string]any{"id": "c0ffee", "running": true, "started": "t1", "dir": dir,
		"ports": map[string]any{at.Port() + "/tcp": []map[string]string{{"HostIp": "127.0.0.1", "HostPort": at.Port()}}}})
	if err != nil {
		t.Fatal(err)
	}
	h := &hungScreen{}
	h.compositor = screenCompositor(t, idletest.Options{})
	programs := quietScreen()
	programs["docker"] = "case \"$1\" in\ncontext) echo unix:///var/run/docker.sock;;\nps) echo c0ffee;;\ninspect) echo '" + string(container) + "';;\nesac"
	screenPrograms(t, programs)
	h.runningScreen = startScreen(t)
	h.shows(`action="/passphrase"`)

	drawn := pageCode.FindStringSubmatch(h.posted("/passphrase", url.Values{}))
	if drawn == nil {
		t.Fatal("no passphrase was drawn")
	}
	setUp := h.posted("/setup", url.Values{"name": {"ada"}, "secret": {drawn[1]}, "again": {drawn[1]}})
	proof := pageProof.FindStringSubmatch(setUp)
	if proof == nil {
		t.Fatalf("setup reached no recovery code:\n%s", setUp)
	}
	h.app.send(mainLocks)
	h.app.until("locked")
	if page := h.posted("/", nil); !strings.Contains(page, "No account yet?") {
		t.Fatalf("after the app's lock the account is not to be made again:\n%s", page)
	}
	if page := h.posted("/saved", url.Values{"proof": {proof[1]}}); !strings.Contains(page, onlyThatPage) {
		t.Fatalf("the code's proof outlived the app's lock:\n%s", page)
	}
}

// posted is the page a form is answered with, or with no fields the page
// at path.
func (h *hungScreen) posted(path string, fields url.Values) string {
	h.t.Helper()
	method := http.MethodPost
	if fields == nil {
		method = http.MethodGet
	}
	resp, err := h.ask(method, path, fields)
	if err != nil {
		h.t.Fatal(err)
	}
	raw, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		h.t.Fatal(err)
	}
	return html.UnescapeString(string(raw))
}

const onlyThatPage = "Only the page this device's PIN or passphrase was typed on can do that."

// mainLocks is main's lock, as the app sends it when it lost its page.
const mainLocks = `{"version":1,"type":"lock"}`

// Where only a new login gives the screen's setup's work the docker group,
// the screen's page says so in place of "CYFR is starting", which is for a
// CYFR that may yet answer.
func TestScreenShell_SaysToLogInAgainWhereThatIsWhatIsMissing(t *testing.T) {
	screenProject(t)
	t.Setenv(workStaleGroup, "1")
	_ = screenCompositor(t, idletest.Options{})
	programs := quietScreen()
	// This computer's own Docker, whose socket refuses a process without
	// the docker group.
	programs["docker"] = `[ "$1" = context ] && echo unix:///var/run/docker.sock && exit 0
echo "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2
exit 1`
	screenPrograms(t, programs)
	s := startScreen(t)
	s.shows(loginAgain)
	resp, err := s.ask(http.MethodGet, "/", nil)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if page := html.UnescapeString(string(raw)); strings.Contains(page, "CYFR is starting") {
		t.Fatalf("the page says CYFR is starting:\n%s", page)
	}
}

// A screen that ends while its context lives on, main's pipe ending,
// ends the reading it began too: the Docker call that holds it is gone at
// once, not at the reading's own bound.
func TestScreenShell_AScreenThatEndsEndsItsReadings(t *testing.T) {
	h := startHungScreen(t)
	h.shows(watchedPage)
	h.until("the page's reading reached Docker", func() bool { return h.timesAsked() > 0 })
	h.app.reply.Close()
	select {
	case err := <-h.ended:
		if err != nil {
			t.Fatalf("the screen ended with %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the screen did not end")
	}
	ended := time.Now()
	// The Docker calls this screen's readings made, by pid, and no other
	// program's on this computer.
	h.until("the Docker call the reading held to end", func() bool {
		raw, _ := os.ReadFile(h.asked)
		for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
			if f := strings.Fields(line); len(f) == 2 {
				if pid, err := strconv.Atoi(f[1]); err == nil && !gone(pid) {
					return false
				}
			}
		}
		return true
	})
	if took := time.Since(ended); took > 3*time.Second {
		t.Fatalf("the reading's Docker call ended %v after the screen", took)
	}
}

// The screen's warning is read as each page is drawn: one shell on one
// listener, its CYFR answering and its folder set to the app's release,
// draws its lock page with no warning; once only the folder's release
// changes, as a `cyfr update` at the same address leaves it, the next
// lock page from that listener names the folder's release.
func TestScreenShell_TheNextLockPageNamesTheFolderUpdatedAtItsAddress(t *testing.T) {
	screenProject(t)
	saved := version.Version
	t.Cleanup(func() { version.Version = saved })
	version.Version = "0.6.0"
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	compose := func(tag string) {
		if err := os.WriteFile("docker-compose.yml", []byte("services:\n  cyfr:\n    image: ghcr.io/cyfrworks/cyfr:"+tag+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	compose("0.6.0")
	accounts := accounttest.New(t)
	at, err := url.Parse(accounts.URL())
	if err != nil {
		t.Fatal(err)
	}
	home := "http://localhost:" + at.Port()
	env := "CYFR_ACCESS=local\nCYFR_PORT=" + at.Port() + "\nCYFR_SETUP_TOKEN=the-token\nCYFR_DIRECTORY_URL=" + home + "\n"
	if err := os.WriteFile(".env", []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	accounts.ServedAt(home)
	container, err := json.Marshal(map[string]any{"id": "c0ffee", "running": true, "started": "t1", "dir": dir,
		"ports": map[string]any{at.Port() + "/tcp": []map[string]string{{"HostIp": "127.0.0.1", "HostPort": at.Port()}}}})
	if err != nil {
		t.Fatal(err)
	}
	h := &hungScreen{}
	h.compositor = screenCompositor(t, idletest.Options{})
	programs := quietScreen()
	programs["docker"] = "case \"$1\" in\ncontext) echo unix:///var/run/docker.sock;;\nps) echo c0ffee;;\ninspect) echo '" + string(container) + "';;\nesac"
	screenPrograms(t, programs)
	h.runningScreen = startScreen(t)
	h.shows(`action="/passphrase"`)
	drawn := pageCode.FindStringSubmatch(h.posted("/passphrase", url.Values{}))
	if drawn == nil {
		t.Fatal("no passphrase was drawn")
	}
	proof := pageProof.FindStringSubmatch(h.posted("/setup", url.Values{"name": {"ada"}, "secret": {drawn[1]}, "again": {drawn[1]}}))
	if proof == nil {
		t.Fatal("setup reached no recovery code")
	}
	h.posted("/saved", url.Values{"proof": {proof[1]}})
	h.app.send(mainLocks)
	h.app.until("locked")
	const named = "is set to release 0.6.1"
	if page := h.posted("/", nil); !strings.Contains(page, "CYFR is locked") || strings.Contains(page, "is set to release") {
		t.Fatalf("the lock page, the releases agreeing:\n%s", page)
	}
	compose("0.6.1")
	if page := h.posted("/", nil); !strings.Contains(page, "CYFR is locked") || !strings.Contains(page, named) {
		t.Fatalf("the next lock page does not name the folder's release:\n%s", page)
	}
}

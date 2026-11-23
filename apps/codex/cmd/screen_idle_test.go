//go:build linux

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.
package cmd

import (
	"context"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/idle"
	"github.com/cyfr/codex/internal/idle/idletest"
	"github.com/cyfr/codex/internal/shell"
)

// screenCompositor is the compositor of this test's screen, which its
// subprocesses find as the screen's shell does.
func screenCompositor(t *testing.T, o idletest.Options) *idletest.Compositor {
	t.Helper()
	c := idletest.Start(t, o)
	t.Setenv("WAYLAND_DISPLAY", c.Socket)
	return c
}

// screenPrograms puts stand-ins of the screen's programs first on PATH.
func screenPrograms(t *testing.T, scripts map[string]string) {
	t.Helper()
	bin := t.TempDir()
	for name, script := range scripts {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+script+"\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin+":/usr/bin:/bin")
	// The folder's readings are setup's work's, and reach this docker too.
	workSeesDocker(t, t.TempDir())
}

// swayidleSays begins a stand-in swayidle: said speaks as swayidle 1.9
// does with -d (its time, its source line, what it says).
const swayidleSays = `said() { echo "2026-11-22 06:48:52 - [Line 219] $*" >&2; }
`

// swayidleHears is a swayidle that subscribed to sleep and answers.
// sleep-ok: the stand-in runs on until its watch stops it.
const swayidleHears = swayidleSays + `trap 'said "Got SIGUSR1"' USR1
said "Got sleep lock: 12"
while :; do /bin/sleep 0.1; done`

// swayidleNeverAnswers is a swayidle that says it holds its sleep lock
// and never comes to answer, as one stopped before its event loop.
// sleep-ok: the stand-in runs on until its watch stops it.
const swayidleNeverAnswers = swayidleSays + `trap '' USR1
said "Got sleep lock: 12"
while :; do /bin/sleep 0.1; done`

// swayidleAnswersThen is a swayidle that subscribed, answered once, and
// then does as the rest of the script says, answering no more.
// sleep-ok: the stand-in waits for its question.
const swayidleAnswersThen = swayidleSays + `answered=
trap 'said "Got SIGUSR1"; answered=1' USR1
said "Got sleep lock: 12"
while [ -z "$answered" ]; do /bin/sleep 0.05; done
trap '' USR1
`

// swayidleHearsNothing is swayidle where it cannot subscribe: it says so,
// answers, and runs on all the same.
// sleep-ok: the stand-in runs on until its watch stops it.
const swayidleHearsNothing = swayidleSays + `trap 'said "Got SIGUSR1"' USR1
said "Failed to open D-Bus connection: No such file or directory"
said "Failed to add D-Bus signal match : sleep: Invalid argument"
said "Enable idle timeouts"
while :; do /bin/sleep 0.1; done`

// quietScreen is the screen's programs, each running, with swayidle
// hearing sleep.
func quietScreen() map[string]string {
	return map[string]string{
		"pkill": "exit 0",
		// No screen's test asks this machine's Docker.
		"docker":               "exit 1",
		"wvkbd-mobintl":        "exec /bin/sleep 30", // sleep-ok: a stand-in child that runs until the shell ends it
		"swayidle":             swayidleHears,
		"google-chrome-stable": "exec /bin/sleep 30", // sleep-ok: a stand-in child that runs until the shell ends it
	}
}

func lockedWith(t *testing.T, locks <-chan string, want string) {
	t.Helper()
	select {
	case why := <-locks:
		if why != want {
			t.Fatalf("locked saying %q, want %q", why, want)
		}
	case <-time.After(10 * time.Second):
		t.Fatalf("the screen did not lock (%q)", want)
	}
}

// watched is screen watches kept as the screen's shell keeps them, with
// each change of Unwatched and each lock heard.
type watched struct {
	*screenWatches
	changes chan string
	locks   chan string
	// openAtLock is whether the last lock found the gate open.
	openAtLock atomic.Bool
}

func startWatches(t *testing.T, after time.Duration) *watched {
	t.Helper()
	return startWatchesBy(t, after, screenClocks)
}

func startWatchesBy(t *testing.T, after time.Duration, clocks func() (boot, monotonic time.Duration, err error)) *watched {
	t.Helper()
	w := &watched{changes: make(chan string, 32), locks: make(chan string, 32)}
	w.screenWatches = newScreenWatches(after, func(why string) { w.changes <- why })
	w.clocks = clocks
	w.lock = func(why string) {
		if why == "" && w.Unwatched() == "" {
			t.Error("a loss locked before it was published, so an unlock could follow that lock")
		}
		w.openAtLock.Store(w.Unwatched() == "")
		w.locks <- why
	}
	ctx, cancel := context.WithCancel(t.Context())
	kept := make(chan struct{})
	go func() {
		defer close(kept)
		w.keep(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		<-kept
	})
	return w
}

func (w *watched) becomes(t *testing.T, want string) {
	t.Helper()
	select {
	case why := <-w.changes:
		if why != want {
			t.Fatalf("the screen became %q, want %q", why, want)
		}
	case <-time.After(idle.CheckEvery + 3*idle.AnswerWithin):
		t.Fatalf("the screen never became %q", want)
	}
}

// A page that holds the compositor awake, as one playing a video a tap
// started does, does not hold the screen's lock off.
func TestScreenWatch_LocksWhateverHoldsTheScreenAwake(t *testing.T) {
	screenCompositor(t, idletest.Options{Inhibited: true})
	screenPrograms(t, quietScreen())
	w := startWatches(t, 20*time.Millisecond)
	lockedWith(t, w.locks, idleLocked)
}

// A suspend locks, through the one command swayidle was given and no
// configuration can replace, and the screen may be unlocked again only
// once swayidle holds the next sleep's lock and has answered again.
func TestScreenWatch_ASuspendLocks(t *testing.T) {
	screenCompositor(t, idletest.Options{})
	programs := quietScreen()
	// swayidle's order at a sleep (main.c prepare_for_sleep): the command,
	// the lock's release, and the next lock at the waking.
	// sleep-ok: the stand-in's sleep, then it runs on until its watch stops it.
	programs["swayidle"] = swayidleSays + `[ "$1 $2 $3 $4 $5" = "-d -w -C /dev/null before-sleep" ] && [ "$#" = 6 ] || exit 64
answered=
trap 'said "Got SIGUSR1"; answered=1' USR1
said "Got sleep lock: 12"
while [ -z "$answered" ]; do /bin/sleep 0.05; done
sh -c "$6"
said "Releasing inhibitor lock 12"
/bin/sleep 0.5
said "Got sleep lock: 13"
while :; do /bin/sleep 0.1; done`
	screenPrograms(t, programs)
	w := startWatches(t, time.Hour)
	w.becomes(t, "")
	lockedWith(t, w.locks, suspendLocked)
	w.becomes(t, sleepUnwatched)
	w.becomes(t, "")
}

// swayidle running with no subscription to sleep is no watch: the screen
// is never unlockable with it, and locks.
func TestScreenWatch_RunningWithNoSubscriptionPermitsNoUnlock(t *testing.T) {
	screenCompositor(t, idletest.Options{})
	programs := quietScreen()
	programs["swayidle"] = swayidleHearsNothing
	screenPrograms(t, programs)
	w := startWatches(t, time.Hour)
	w.becomes(t, sleepUnwatched)
	lockedWith(t, w.locks, "")
	select {
	case <-w.Settled():
	default:
		t.Fatal("the failure did not settle the screen's first page")
	}
}

// A watch that stops showing that it works is lost, which locks: a
// compositor that stops answering, and a swayidle that runs on saying
// nothing.
func TestScreenWatch_AWatchNoLongerKnownToWorkLocks(t *testing.T) {
	t.Run("the compositor stops answering", func(t *testing.T) {
		c := screenCompositor(t, idletest.Options{})
		screenPrograms(t, quietScreen())
		w := startWatches(t, time.Hour)
		w.becomes(t, "")
		c.Freeze()
		w.becomes(t, idleUnwatched)
		lockedWith(t, w.locks, "")
	})
	t.Run("swayidle stops answering", func(t *testing.T) {
		screenCompositor(t, idletest.Options{})
		programs := quietScreen()
		// sleep-ok: the stand-in runs on, answering nothing, until stopped.
		programs["swayidle"] = swayidleAnswersThen + `while :; do /bin/sleep 0.1; done`
		screenPrograms(t, programs)
		w := startWatches(t, time.Hour)
		w.becomes(t, "")
		w.becomes(t, sleepUnwatched)
		lockedWith(t, w.locks, "")
	})
}

// The lock got is no answer: a swayidle that says it holds one and never
// answers permits no unlock, at the start, at the waking, or where it took
// another without saying that it let the last go.
func TestScreenWatch_ALockGotPermitsNoUnlockUntilAnAnswer(t *testing.T) {
	t.Run("at the start", func(t *testing.T) {
		screenCompositor(t, idletest.Options{})
		programs := quietScreen()
		programs["swayidle"] = swayidleNeverAnswers
		screenPrograms(t, programs)
		w := startWatches(t, time.Hour)
		w.becomes(t, sleepUnwatched) // its first change, so it was never ""
		lockedWith(t, w.locks, "")
	})
	for name, again := range map[string]string{
		"at the waking": `said "Releasing inhibitor lock 12"
said "Got sleep lock: 13"`,
		"another taken, none let go": `said "Got sleep lock: 13"`,
	} {
		t.Run(name, func(t *testing.T) {
			screenCompositor(t, idletest.Options{})
			programs := quietScreen()
			// sleep-ok: the stand-in runs on, answering nothing, until stopped.
			programs["swayidle"] = swayidleAnswersThen + again + "\nwhile :; do /bin/sleep 0.1; done"
			screenPrograms(t, programs)
			w := startWatches(t, time.Hour)
			w.becomes(t, "")
			w.becomes(t, sleepUnwatched)
			lockedWith(t, w.locks, suspendLocked)
			lockedWith(t, w.locks, "") // the question's deadline
			select {
			case why := <-w.changes:
				t.Fatalf("it became %q on a lock got and no answer", why)
			default:
			}
		})
	}
}

// A sleep nothing reported, as with logind gone while the bus and swayidle
// stay up, locks on the first tick after waking, the gate closed first,
// and the watches start again: one the monotonic clock stood still in, and
// one it ran on through, as suspend to idle may leave it, seen by the
// boot clock alone. Time awake, which both counted, is no sleep.
func TestScreenWatch_ASleepSwayidleDidNotReportLocksOnTheFirstTickAfterWaking(t *testing.T) {
	for name, sleep := range map[string]struct{ boot, monotonic time.Duration }{
		"the monotonic clock stood still": {time.Second, 0},
		"both clocks ran on":              {time.Hour, time.Hour},
	} {
		t.Run(name, func(t *testing.T) {
			screenCompositor(t, idletest.Options{})
			screenPrograms(t, quietScreen())
			var boot, monotonic atomic.Int64
			reads := make(chan int64, 256)
			w := startWatchesBy(t, time.Hour, func() (time.Duration, time.Duration, error) {
				// In screenClocks' order, so time both count between is no sleep.
				b, m := boot.Load(), monotonic.Load()
				select {
				case reads <- b:
				default:
				}
				return time.Duration(b), time.Duration(m), nil
			})
			advance := func(b, m time.Duration) {
				monotonic.Add(int64(m))
				to := boot.Add(int64(b))
				for {
					select {
					case read := <-reads:
						if read == to {
							return
						}
					case <-time.After(10 * time.Second):
						t.Fatal("the watch read no clock")
					}
				}
			}
			w.becomes(t, "")

			// Awake, up to the latest a tick may come.
			advance(idle.AnswerWithin, idle.AnswerWithin)
			advance(watchesTick, watchesTick) // the tick before this one has been acted on
			select {
			case why := <-w.locks:
				t.Fatalf("time awake locked the screen (%q)", why)
			default:
			}

			advance(sleep.boot, sleep.monotonic)
			// That reading was the first tick after the waking.
			select {
			case why := <-w.locks:
				if why != suspendLocked {
					t.Fatalf("locked saying %q, want %q", why, suspendLocked)
				}
			case <-time.After(watchesTick):
				t.Fatal("the first tick after the waking did not lock")
			}
			if w.openAtLock.Load() {
				t.Fatal("the sleep locked with the gate still open")
			}
			w.becomes(t, sleepUnwatched)
			w.becomes(t, "")
		})
	}
}

// screenWatchAfter is set where tests/desktop-proof/screen/idle.sh runs
// TestScreenWatchHelper under a real compositor.
const screenWatchAfter = "CYFR_SCREEN_WATCH_AFTER"

// TestScreenWatchHelper is the screen's watches as a process of their own,
// counting a time short enough to wait for, for that proof to read: each
// lock, and each time the screen became watched or unwatched.
func TestScreenWatchHelper(t *testing.T) {
	if os.Getenv(screenWatchAfter) == "" {
		t.Skip("run by tests/desktop-proof/screen/idle.sh")
	}
	after, err := time.ParseDuration(os.Getenv(screenWatchAfter))
	if err != nil {
		t.Fatal(err)
	}
	w := newScreenWatches(after, func(why string) {
		if why == "" {
			fmt.Println("watching")
		} else {
			fmt.Println("unwatched: " + why)
		}
	})
	w.lock = func(why string) { fmt.Println("locked: " + why) }
	w.keep(t.Context())
}

// runningScreen is the screen's shell running until the test ends, its
// page read as the screen's own browser reads it.
type runningScreen struct {
	t     *testing.T
	ended chan error
	done  chan struct{}
	// address is where this test's own listener serves the pages.
	address func() string
	// offered is whether a page read meanwhile offered the screen's use.
	offered bool
}

// watchedPage is what a watched screen shows in these tests, whose CYFR
// answers nothing.
const watchedPage = "CYFR is starting"

func startScreen(t *testing.T) *runningScreen {
	t.Helper()
	if err := os.MkdirAll(screenDir, 0o700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	listen, address := ownListener()
	s := &runningScreen{t: t, ended: make(chan error, 1), done: make(chan struct{}), address: address}
	go func() {
		defer close(s.done)
		s.ended <- runScreenShell(ctx, listen)
	}()
	t.Cleanup(func() {
		cancel()
		<-s.done
	})
	return s
}

// ask sends what the screen's own browser sends to the shell's one
// address, to this test's listener in its place.
func (s *runningScreen) ask(method, path string, form url.Values) (*http.Response, error) {
	req, err := http.NewRequest(method, "http://"+s.address()+path, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Host = shell.Listen
	if form != nil {
		req.Header.Set("Origin", shell.Origin)
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	return http.DefaultClient.Do(req)
}

// shows waits for the shell's own page to show want, the shell running.
func (s *runningScreen) shows(want string) string {
	s.t.Helper()
	page := ""
	// sleep-ok: polls the shell's page, which changes as the watches do.
	for deadline := time.Now().Add(idle.CheckEvery + 4*idle.AnswerWithin); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		select {
		case err := <-s.ended:
			s.t.Fatalf("the shell ended where it must stay locked and say why: %v", err)
		default:
		}
		resp, err := s.ask(http.MethodGet, "/", nil)
		if err != nil {
			continue
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		page = html.UnescapeString(string(raw))
		s.offered = s.offered || strings.Contains(page, watchedPage)
		if strings.Contains(page, want) {
			return page
		}
	}
	s.t.Fatalf("the screen's page never showed %q:\n%s", want, page)
	return ""
}

// staysLockedSaying is the shell running on, locked, with why on its own
// page and no way there to unlock, a forged unlock included.
func (s *runningScreen) staysLockedSaying(why string) {
	s.t.Helper()
	page := s.shows(why)
	if strings.Contains(page, `action="/unlock"`) || strings.Contains(page, `action="/setup"`) || !strings.Contains(page, `http-equiv="refresh"`) {
		s.t.Fatalf("a screen that cannot watch offers a way to unlock, or keeps its page:\n%s", page)
	}
	resp, err := s.ask(http.MethodPost, "/unlock", url.Values{"secret": {"135790"}})
	if err != nil {
		s.t.Fatal(err)
	}
	resp.Body.Close()
	s.shows(why)
}

// The screen's shell counts its five minutes from input alone, and when it
// can count them no longer it stays, locked, and says so.
func TestScreenShell_CountsFiveMinutesOfInputAloneAndStaysLockedWithoutThem(t *testing.T) {
	screenProject(t)
	compositor := screenCompositor(t, idletest.Options{})
	screenPrograms(t, quietScreen())
	s := startScreen(t)
	select {
	case asked := <-compositor.Asked:
		if !asked.InputOnly || asked.After != 5*time.Minute {
			t.Fatalf("the screen asked for %+v, want five minutes of input alone", asked)
		}
	case err := <-s.ended:
		t.Fatalf("the shell ended before it asked: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("the screen never asked the compositor to count input alone")
	}
	s.shows(watchedPage)
	compositor.Stop()
	s.staysLockedSaying(idleUnwatched)
}

// A screen that cannot start its watches stays locked, for as long as that
// lasts, with one sentence saying why on its own page.
func TestScreenShell_AWatchThatCannotStartShowsWhy(t *testing.T) {
	for name, c := range map[string]struct {
		compositor idletest.Options
		swayidle   string
		want       string
	}{
		"a compositor that cannot count input alone": {idletest.Options{Version: 1}, swayidleHears, idleUnwatched},
		"swayidle running with no subscription":      {idletest.Options{}, swayidleHearsNothing, sleepUnwatched},
		"swayidle with a lock and no answer":         {idletest.Options{}, swayidleNeverAnswers, sleepUnwatched},
		"swayidle exiting":                           {idletest.Options{}, "exit 42", sleepUnwatched},
		"no swayidle":                                {idletest.Options{}, "", sleepUnwatched},
	} {
		t.Run(name, func(t *testing.T) {
			screenProject(t)
			screenCompositor(t, c.compositor)
			programs := quietScreen()
			programs["swayidle"] = c.swayidle
			if c.swayidle == "" {
				delete(programs, "swayidle")
			}
			screenPrograms(t, programs)
			if c.swayidle == "" {
				// The stand-ins name their programs whole: this PATH holds
				// them and no swayidle of the machine's.
				bin, _, _ := strings.Cut(os.Getenv("PATH"), ":")
				t.Setenv("PATH", bin)
			}
			s := startScreen(t)
			s.staysLockedSaying(c.want)
			// Through a second try, as through the first.
			time.Sleep(watchesAgain + 200*time.Millisecond) // sleep-ok: the shell's own wait before it tries again
			s.staysLockedSaying(c.want)
			if s.offered {
				t.Fatal("a screen that could not start its watches offered its use meanwhile")
			}
		})
	}
}

// A watch that starts working again gives the screen back its page.
func TestScreenShell_WatchesThatWorkAgainShowThePage(t *testing.T) {
	screenProject(t)
	screenCompositor(t, idletest.Options{})
	programs := quietScreen()
	mended := filepath.Join(t.TempDir(), "mended")
	programs["swayidle"] = "[ -e " + mended + " ] || exit 1\n" + swayidleHears
	screenPrograms(t, programs)
	s := startScreen(t)
	s.staysLockedSaying(sleepUnwatched)
	if err := os.WriteFile(mended, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	s.shows(watchedPage)
}

// TestScreenShellHelper runs the screen's shell as a process of its own
// for TestScreenShell_AKilledShellLeavesNoChildBehind.
func TestScreenShellHelper(t *testing.T) {
	if os.Getenv("CYFR_SCREEN_SHELL_HELPER") == "" {
		t.Skip("run by TestScreenShell_AKilledShellLeavesNoChildBehind")
	}
	listen, _ := ownListener()
	_ = runScreenShell(context.Background(), listen)
}

// A shell killed outright leaves no keyboard, suspend watch or Chrome
// behind: each ends with it.
func TestScreenShell_AKilledShellLeavesNoChildBehind(t *testing.T) {
	screenProject(t)
	screenCompositor(t, idletest.Options{})
	if err := os.MkdirAll(screenDir, 0o700); err != nil {
		t.Fatal(err)
	}
	bin, pids := t.TempDir(), t.TempDir()
	children := []string{"wvkbd-mobintl", "swayidle", "google-chrome-stable"}
	for _, name := range children {
		script := "echo $$ >" + filepath.Join(pids, name) + "\nexec /bin/sleep 60\n"
		if name == "swayidle" {
			script = "echo $$ >" + filepath.Join(pids, name) + "\n" + swayidleHears + "\n"
		}
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\n"+script), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(bin, "pkill"), []byte("#!/bin/sh\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	shell := exec.Command(os.Args[0], "-test.run=^TestScreenShellHelper$")
	shell.Env = append(os.Environ(), "CYFR_SCREEN_SHELL_HELPER=1", "PATH="+bin+":/usr/bin:/bin")
	if err := shell.Start(); err != nil {
		t.Fatal(err)
	}
	var running []int
	for deadline := time.Now().Add(10 * time.Second); len(running) < len(children); {
		if time.Now().After(deadline) {
			_ = shell.Process.Kill()
			t.Fatalf("the shell started %d of its children", len(running))
		}
		running = running[:0]
		for _, name := range children {
			if raw, err := os.ReadFile(filepath.Join(pids, name)); err == nil {
				if pid, err := strconv.Atoi(strings.TrimSpace(string(raw))); err == nil {
					running = append(running, pid)
				}
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	_ = shell.Process.Signal(syscall.SIGKILL)
	_ = shell.Wait()
	deadline := time.Now().Add(3 * time.Second)
	for _, pid := range running {
		for syscall.Kill(pid, 0) == nil {
			if time.Now().After(deadline) {
				_ = syscall.Kill(pid, syscall.SIGKILL)
				t.Fatalf("child %d outlived the killed shell", pid)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
}

// A folder that names another CYFR than the one the screen opened ends
// the screen's shell, which its launcher starts again on that reading,
// and Chrome is given localhost as 127.0.0.1 alone.
func TestScreenShell_AChangedFolderEndsTheShellForANewReading(t *testing.T) {
	screenProject(t)
	screenCompositor(t, idletest.Options{})
	if err := os.MkdirAll(screenDir, 0o700); err != nil {
		t.Fatal(err)
	}
	chromed := filepath.Join(t.TempDir(), "chrome.args")
	programs := quietScreen()
	// sleep-ok: a stand-in child that runs until the shell ends it
	programs["google-chrome-stable"] = `echo "$@" >` + chromed + `; exec /bin/sleep 30`
	screenPrograms(t, programs)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	listen, address := ownListener()
	ended := make(chan error, 1)
	go func() { ended <- runScreenShell(ctx, listen) }()
	for {
		if raw, err := os.ReadFile(chromed); err == nil && strings.HasSuffix(string(raw), "\n") {
			if !strings.Contains(string(raw), "--host-resolver-rules=MAP localhost 127.0.0.1") {
				t.Errorf("Chrome was started with %s", raw)
			}
			break
		}
		select {
		case err := <-ended:
			t.Fatalf("the screen ended first: %v", err)
		case <-time.After(20 * time.Millisecond):
		}
	}
	if err := os.WriteFile(".env", []byte("CYFR_ACCESS=local\nCYFR_PORT=4322\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodGet, "http://"+address()+"/", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Host = "127.0.0.1:7340"
	if resp, err := http.DefaultClient.Do(req); err == nil {
		resp.Body.Close()
	}
	select {
	case err := <-ended:
		if err == nil || ctx.Err() != nil || !strings.Contains(err.Error(), "starts again") {
			t.Fatalf("the screen ended with %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the screen kept the CYFR it read before")
	}
}

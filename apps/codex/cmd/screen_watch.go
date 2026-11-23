// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"strconv"
	"sync"
	"time"

	"github.com/cyfr/codex/internal/idle"
)

// What the screen's own page says while the screen may not be unlocked.
const (
	watchesStarting = "This screen stays locked until it can tell when to lock."
	idleUnwatched   = "This screen stays locked because it cannot tell when five minutes pass without touch, key or pointer input."
	sleepUnwatched  = "This screen stays locked because it cannot tell when this device goes to sleep."
	keyboardGone    = "This screen stays locked because its on-screen keyboard is not running. It starts the keyboard again."
)

const (
	// watchesAgain is how long after losing its watches the screen starts
	// them again.
	watchesAgain = time.Second
	// watchesTick is the interval between their looks at their deadlines
	// and at whether the machine slept.
	watchesTick = 250 * time.Millisecond
)

// screenWatches are what lock the screen with nobody asking: after has
// passed without input (internal/idle), and the device is going to sleep
// (swayidle, which locks before the screen goes dark). The screen may be
// unlocked only while both are known to work (Unwatched is ""), and known
// is observed, never that a process started. That the machine slept is
// observed here too, whatever swayidle heard: either the boot clock ran on
// where the monotonic clock stood still, or, as in a suspend to idle that
// leaves both running, the boot clock ran on past a tick by more than
// idle.AnswerWithin, in which the shell itself watched nothing. A sleep
// locks on the first tick after waking and starts the watches again.
// Losing either watch locks at once; the page then says which, and the
// watches are started again for as long as the screen runs.
type screenWatches struct {
	after time.Duration
	lock  func(why string)
	// clocks reads the boot clock and the monotonic clock.
	clocks func() (boot, monotonic time.Duration, err error)
	// changed hears each change of Unwatched, once it has changed; nil
	// hears none. A loss is shown through its lock (shell.Shell.Lock).
	changed func(why string)

	mu      sync.Mutex
	why     string
	settled chan struct{}
	settle  sync.Once
}

func newScreenWatches(after time.Duration, changed func(why string)) *screenWatches {
	return &screenWatches{after: after, clocks: screenClocks, changed: changed, why: watchesStarting, settled: make(chan struct{})}
}

// Unwatched is why the screen may not be unlocked now, or "".
func (w *screenWatches) Unwatched() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.why
}

// Settled is closed once the watches first worked or first failed.
func (w *screenWatches) Settled() <-chan struct{} { return w.settled }

func (w *screenWatches) set(why string) {
	w.mu.Lock()
	changed := w.why != why
	w.why = why
	w.mu.Unlock()
	w.settle.Do(func() { close(w.settled) })
	if changed && w.changed != nil {
		w.changed(why)
	}
}

// unwatched is a watch lost: what the page says, and the cause.
type unwatched struct {
	page  string
	cause error
}

func (u unwatched) Error() string { return u.page + " (" + u.cause.Error() + ")" }
func (u unwatched) Unwrap() error { return u.cause }

// keep watches until ctx ends. The loss is published before the lock, so
// an unlock either saw it or is ended by that lock.
func (w *screenWatches) keep(ctx context.Context) {
	told := ""
	var keyboard *screenKeyboard
	defer func() { keyboard.stop() }()
	for {
		var err error
		if keyboard == nil || !keyboard.running() {
			if keyboard, err = startKeyboard(); err != nil {
				err = unwatched{keyboardGone, err}
			}
		}
		if err == nil {
			err = w.watch(ctx, keyboard.ended)
		}
		if ctx.Err() != nil {
			return
		}
		var lost unwatched
		if !errors.As(err, &lost) {
			lost = unwatched{idleUnwatched, err}
		}
		w.set(lost.page)
		w.lock("")
		if said := lost.Error(); said != told {
			told = said
			fmt.Fprintln(os.Stderr, "cyfr screen: "+said)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(watchesAgain):
		}
	}
}

// suspended locks for a sleep, the gate closed first.
func (w *screenWatches) suspended() {
	w.set(sleepUnwatched)
	w.lock(suspendLocked)
}

// screenKeyboard is the on-screen keyboard, which the watches keep running:
// ended is closed once it has ended.
type screenKeyboard struct {
	cmd   *exec.Cmd
	ended chan struct{}
}

func startKeyboard() (*screenKeyboard, error) {
	k := &screenKeyboard{cmd: screenChild(exec.Command("wvkbd-mobintl")), ended: make(chan struct{})}
	if err := k.cmd.Start(); err != nil {
		return nil, fmt.Errorf("the on-screen keyboard did not start: %w", err)
	}
	go func() {
		_ = k.cmd.Wait()
		close(k.ended)
	}()
	return k, nil
}

func (k *screenKeyboard) running() bool {
	select {
	case <-k.ended:
		return false
	default:
		return true
	}
}

// stop ends a keyboard that runs, and waits for its end.
func (k *screenKeyboard) stop() {
	if k != nil {
		_ = k.cmd.Process.Kill()
		<-k.ended
	}
}

// watch runs both watches until one is not known to work, or the keyboard
// (keyboardEnded) ends, and says which. The keyboard is watched as they
// are: one that does not start or that ends locks the screen, whose page
// says so, and keep starts it again; a watch lost leaves it running.
func (w *screenWatches) watch(ctx context.Context, keyboardEnded <-chan struct{}) error {
	socket, err := idle.Socket()
	if err != nil {
		return unwatched{idleUnwatched, err}
	}
	input, err := idle.Start(ctx, socket, w.after)
	if err != nil {
		return unwatched{idleUnwatched, err}
	}
	defer input.Close()
	inputEnded := make(chan error, 1)
	go func() { inputEnded <- input.Run(func() { w.lock(idleLocked) }) }()

	suspending := make(chan os.Signal, 1)
	signal.Notify(suspending, sigUSR1)
	defer signal.Stop(suspending)
	sleep, err := startSleepWatch()
	if err != nil {
		return unwatched{sleepUnwatched, err}
	}
	defer sleep.stop()

	boot, monotonic, err := w.clocks()
	if err != nil {
		return unwatched{sleepUnwatched, err}
	}
	stoodStill, looked := boot-monotonic, boot
	tick := time.NewTicker(watchesTick)
	defer tick.Stop()
	// due is when swayidle is to have subscribed, to have answered, or to
	// be asked next.
	subscribed, asked := false, false
	due := time.Now().Add(idle.AnswerWithin)
	ask := func() error {
		if err := sleep.ask(); err != nil {
			return unwatched{sleepUnwatched, err}
		}
		asked, due = true, time.Now().Add(idle.AnswerWithin)
		return nil
	}
	silent := func() error {
		return unwatched{sleepUnwatched, sleep.failure("swayidle did not answer")}
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-inputEnded:
			return unwatched{idleUnwatched, err}
		case <-keyboardEnded:
			return unwatched{keyboardGone, errors.New("the on-screen keyboard ended")}
		case <-sleep.exited:
			return unwatched{sleepUnwatched, sleep.failure("swayidle stopped")}
		case <-suspending:
			began := time.Now()
			w.lock(suspendLocked)
			due = due.Add(time.Since(began)) // the lock's time is not swayidle's
		case event := <-sleep.events:
			switch event {
			case sleepSubscribed:
				// The lock got may precede swayidle's event loop: only the
				// answer to a question asked after it opens the gate.
				if w.Unwatched() == "" {
					w.suspended()
				}
				subscribed = true
				if err := ask(); err != nil {
					return err
				}
			case sleepReleased:
				// Until swayidle holds the next sleep's lock, at the waking,
				// and answers again, the watch is not known to work.
				subscribed, asked = false, false
				w.suspended()
				due = time.Now().Add(2 * idle.AnswerWithin)
			case sleepAnswered:
				if !subscribed || !asked {
					break
				}
				if !time.Now().Before(due) {
					return silent()
				}
				asked, due = false, time.Now().Add(idle.CheckEvery)
				w.set("")
			}
		case <-tick.C:
			boot, monotonic, err := w.clocks()
			if err != nil {
				return unwatched{sleepUnwatched, err}
			}
			asleep := boot-monotonic-stoodStill > watchesTick
			frozen := boot-looked > watchesTick+idle.AnswerWithin
			if asleep || frozen {
				w.suspended()
				return unwatched{sleepUnwatched, errors.New("this device slept")}
			}
			looked = boot
			if time.Now().Before(due) {
				break
			}
			switch {
			case !subscribed:
				return unwatched{sleepUnwatched, sleep.failure("swayidle did not show that it hears this device's sleep")}
			case asked:
				return silent()
			}
			if err := ask(); err != nil {
				return err
			}
		}
	}
}

type sleepEvent int

const (
	sleepSubscribed sleepEvent = iota + 1
	sleepReleased
	sleepAnswered
)

// What swayidle 1.9 says with -d, each line after its time and source
// line. It asks logind for its delay lock only once its match on
// PrepareForSleep was made (main.c setup_sleep_listener), so the lock got
// is the subscription shown; it releases that lock as the device goes to
// sleep, after running before-sleep's command, and takes the next at the
// waking. It holds SIGUSR1 back from before it takes the first lock and
// answers it only from its event loop, so the answer shows the loop runs;
// with no timeout of its own it does nothing else on it. A swayidle that
// words the lock got or the answer otherwise is never known to work, and
// the screen then stays locked and says so.
var (
	swayidleSaid = regexp.MustCompile(`^\S+ \S+ - \[Line \d+\] (.*)$`)
	swayidleGot  = regexp.MustCompile(`^Got sleep lock: \d+$`)
	swayidleLet  = regexp.MustCompile(`^Releasing inhibitor lock \d+$`)
)

const swayidleAnswer = "Got SIGUSR1"

// sleepWatch is one swayidle, hearing sleep alone, and what it says.
type sleepWatch struct {
	cmd    *exec.Cmd
	events chan sleepEvent
	done   chan struct{}
	exited chan struct{}

	mu      sync.Mutex
	partial []byte
	failed  string
}

// startSleepWatch starts swayidle. -C /dev/null keeps the account's and
// the machine's configuration out: a before-sleep there replaces the one
// given here.
func startSleepWatch() (*sleepWatch, error) {
	s := &sleepWatch{events: make(chan sleepEvent), done: make(chan struct{}), exited: make(chan struct{})}
	s.cmd = screenChild(exec.Command("swayidle", "-d", "-w", "-C", "/dev/null",
		"before-sleep", "kill -USR1 "+strconv.Itoa(os.Getpid())))
	s.cmd.Stderr = s
	s.cmd.WaitDelay = time.Second // a command it ran may hold its standard error
	if err := s.cmd.Start(); err != nil {
		return nil, fmt.Errorf("swayidle did not start: %w", err)
	}
	go func() {
		_ = s.cmd.Wait()
		close(s.exited)
	}()
	return s, nil
}

// Write reads what swayidle says, a line at a time.
func (s *sleepWatch) Write(p []byte) (int, error) {
	s.mu.Lock()
	s.partial = append(s.partial, p...)
	var events []sleepEvent
	for {
		line, rest, whole := bytes.Cut(s.partial, []byte("\n"))
		if !whole {
			break
		}
		if said := swayidleSaid.FindSubmatch(line); said != nil {
			switch {
			case swayidleGot.Match(said[1]):
				events = append(events, sleepSubscribed)
			case swayidleLet.Match(said[1]):
				events = append(events, sleepReleased)
			case string(said[1]) == swayidleAnswer:
				events = append(events, sleepAnswered)
			case bytes.HasPrefix(said[1], []byte("Failed")):
				s.failed = string(said[1])
			}
		}
		s.partial = rest
	}
	if len(s.partial) > 64<<10 {
		s.partial = nil // no line of swayidle's is so long
	}
	s.mu.Unlock()
	for _, e := range events {
		select {
		case s.events <- e:
		case <-s.done:
		}
	}
	return len(p), nil
}

// failure is what, with the last failure swayidle said.
func (s *sleepWatch) failure(what string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failed == "" {
		return errors.New(what)
	}
	return fmt.Errorf("%s: %s", what, s.failed)
}

func (s *sleepWatch) ask() error { return s.cmd.Process.Signal(sigUSR1) }

func (s *sleepWatch) stop() {
	close(s.done)
	_ = s.cmd.Process.Kill()
	<-s.exited
}

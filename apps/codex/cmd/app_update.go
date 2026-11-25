// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/cyfr/codex/internal/release"
)

// The bounds of the installed app's update, each longer than what it
// bounds can take when it works: appQuitWithin the app's own end (its
// cyfr's five-second shutdown and its lock), appAskWithin one start of the
// app that asks the running one to end, appReplaceWithin a package tool's
// install of the app, and boundGrace how long a process the bound killed
// may take to be gone.
const (
	appReplaceWithin = 20 * time.Minute
	boundGrace       = 10 * time.Second
)

// appQuitWithin and appAskWithin are variables so tests shorten them.
var (
	appQuitWithin = 30 * time.Second
	appAskWithin  = 15 * time.Second
)

// errOverran is a step its bound ended (runWithin).
var errOverran = errors.New("it did not finish within")

// The installed app's road and its closing, package variables so tests
// stand in for them.
var (
	// appRoadHere is the road this machine's installed app is updated by
	// (systemAppRoad, one per system): nil where cyfr update has none.
	appRoadHere = systemAppRoad
	// quitApp ends the CYFR app this account runs, answering once none
	// runs whether one ran (askAppToQuit).
	quitApp = askAppToQuit
	// reopenApp starts the installed app again, not waiting for it.
	reopenApp = startInstalledApp
)

// appRoad is how an installer outside the app brings this machine's
// installed CYFR app to a release.
type appRoad interface {
	// fetch verifies release target's installer for this machine against
	// the release's signed checksums, changing nothing of CYFR's: what it
	// keeps lies in a folder of its own, which staged.remove removes. It
	// refuses a target its installer would not install over before, the
	// installed app's release ("" for none it answers).
	fetch(ctx context.Context, out io.Writer, before, target string) (*staged, error)
	// elevate takes, before the app closes, what replace needs to run as
	// someone else, and refuses where it cannot, answering what lets it go
	// once the update is done; again is the command to run once a refusal
	// is mended. ask is whether a password may be asked for at this
	// program's terminal: false answers, asking nothing, as a run with no
	// terminal would.
	elevate(out io.Writer, again string, ask bool) (release func(), err error)
	// replace installs what fetch verified over the installed app, older
	// when that is a release before the installed one, and runs to its
	// end within its bound, whatever this cyfr is asked meanwhile. A
	// replacement that failed leaves the installed app as it was or as the
	// installer's own undoing left it; it never answers success unless
	// its installer did.
	replace(out io.Writer, s *staged, older bool) error
	// finish ends the replacement once the transaction has read the
	// installed app's release: confirmed, it removes what was kept to go
	// back to; not, it puts back what it kept. It is the one step that
	// removes the app before, so nothing needed to go back is gone before
	// the last step that can refuse. An error confirmed is what was left
	// behind; unconfirmed, that the app could not be put back.
	finish(out io.Writer, s *staged, confirmed bool) error
	// closesTheBox is the root commands that stop the box's screen and
	// start it again, through the same elevation, where the road has one;
	// empty where the road's replace stops and starts it itself; nil
	// elsewhere.
	closesTheBox() (stop, start []string)
}

// staged is release target's installer fetch verified: file, its sha256
// sum, in dir, the folder of its own fetch made; a road whose installer
// fetches for itself (Homebrew) stages no file, and one whose service
// fetched it holds the service's connection and its answers. kept is
// what a road's replace kept to go back to, which its finish removes or
// puts back (the Mac's old app, Windows' cyfr set aside), and swapped
// whether the Mac's swap was made.
type staged struct {
	target, dir, file, sum string
	kept                   string
	swapped                bool
	service                net.Conn
	answers                *bufio.Reader
}

// remove removes the folder fetch made and lets the service go: one let
// go before it was told to install installs nothing.
func (s *staged) remove() {
	if s == nil {
		return
	}
	if s.dir != "" {
		_ = os.RemoveAll(s.dir)
	}
	if s.service != nil {
		_ = s.service.Close()
	}
}

// fetchInstaller downloads release target's installer for goos on goarch
// into a folder of its own, mode 0600, and keeps it only once its sha256
// is the one the release's signed checksums.txt names (appPackageSum,
// fetchAppPackage), bounded by fetchBinaryTimeout. It changes nothing
// else.
func fetchInstaller(ctx context.Context, out io.Writer, target, goos, goarch string) (*staged, error) {
	fmt.Fprintf(out, "Downloading the CYFR app, release %s for %s/%s, and checking it against the release's signed checksums...\n", target, goos, goarch)
	fetch, cancel := context.WithTimeout(ctx, fetchBinaryTimeout)
	defer cancel()
	sum, err := appPackageSum(fetch, target, goos, goarch)
	var data []byte
	if err == nil {
		data, err = fetchAppPackage(fetch, target, goos, goarch, sum)
	}
	switch {
	case errors.Is(err, release.ErrUnverified):
		return nil, fmt.Errorf("The CYFR app of release %s did not verify (%w); nothing was changed and CYFR runs as it did", target, err)
	case err != nil:
		return nil, fmt.Errorf("cyfr update could not download the CYFR app of release %s (%v); nothing was changed and CYFR runs as it did. Run 'cyfr update' again", target, err)
	}
	dir, err := os.MkdirTemp("", "cyfr-update-")
	if err == nil {
		s := &staged{target: target, dir: dir, file: filepath.Join(dir, release.PackageName(target, goos, goarch)), sum: sum}
		if err = os.WriteFile(s.file, data, 0o600); err == nil {
			return s, nil
		}
		s.remove()
	}
	return nil, fmt.Errorf("cyfr update could not keep the CYFR app's installer it verified (%v); nothing was changed and CYFR runs as it did", err)
}

// appIs says which release the installed app is, as its own cyfr answers
// (machine.appRelease): one that answers none is not taken for any.
func appIs(answered string) string {
	if answered == "" {
		return "the CYFR app's own cyfr answers no release"
	}
	return "the CYFR app is release " + answered
}

// updateApp brings the installed CYFR app to release target through road,
// in the order whose every refusal leaves a
// working app: the installer is verified, then the elevation is taken,
// then the running app is closed, then the installer replaces it, then
// the release the app's own cyfr answers is read, and the app is opened
// again as it was. A refusal before the close changes nothing; the close
// is never made for a replacement that cannot follow. On the box's own
// screen (the screen service active) the app's launcher would start the
// old app again the moment it ended, so the service is stopped first,
// as root, and started again once the installer is done, whatever it
// answered: the screen comes back locked. Elsewhere the app this account
// runs is asked to end (quitApp) and, when it ran, is opened again.
// Anything but release target answered after the installer is a refusal:
// the CYFR the folder holds is not touched. again is the command the
// person runs to try again.
func updateApp(ctx context.Context, out io.Writer, road appRoad, before, target, again string) error {
	if road == nil {
		return errors.New("cyfr update has no installer for the CYFR app on this system; nothing was changed")
	}
	older := release.IsVersion(before) && release.IsNewer(before, target)
	if before == "" {
		fmt.Fprintf(out, "Updating the CYFR app, whose own cyfr answers no release, to %s...\n", target)
	} else {
		fmt.Fprintf(out, "Updating the CYFR app from %s to %s...\n", before, target)
	}
	s, err := road.fetch(ctx, out, before, target)
	if err != nil {
		return err
	}
	defer s.remove()
	if ctx.Err() != nil {
		return errors.New("cyfr update was interrupted before the CYFR app was closed; nothing was changed and CYFR runs as it did")
	}
	let, err := road.elevate(out, again, true)
	if err != nil {
		return err
	}
	defer let()
	if ctx.Err() != nil {
		return errors.New("cyfr update was interrupted before the CYFR app was closed; nothing was changed and CYFR runs as it did")
	}

	// Whether the box's screen runs decides how the app is closed and
	// whether its screen is started again: a read with no answer replaces
	// nothing.
	stop, start := road.closesTheBox()
	box := false
	if stop != nil {
		_, active, err := machine.screenService()
		if err != nil {
			return fmt.Errorf("cyfr update could not tell whether this machine's screen runs (%v); nothing was changed and CYFR runs as it did. Run '%s' again", err, again)
		}
		box = active
	}
	ran := false
	if box && len(stop) > 0 {
		fmt.Fprintln(out, "Stopping this machine's screen, so its launcher does not start the old CYFR app again while it is replaced...")
		if err := applyWithin(appQuitWithin, stop); err != nil {
			// A stop that failed may have stopped it: it is started again.
			_ = applyWithin(appQuitWithin, start)
			return fmt.Errorf("The screen could not be stopped (%v); nothing was replaced and the CYFR app is as it was", err)
		}
	} else if !box {
		fmt.Fprintln(out, "Closing the CYFR app...")
		r, err := quitApp()
		if err != nil {
			return fmt.Errorf("The CYFR app could not be closed (%v); nothing was replaced. If CYFR is closed, open it again: it is release %s", err, before)
		}
		ran = r
	}

	// The app opened again as it was, or why it could not be: a road's
	// replacement that installed the app with the box's screen not started
	// again says so in its place.
	var reopen string
	replaced := road.replace(out, s, older)
	if unstarted := screenUnstarted(""); errors.As(replaced, &unstarted) {
		replaced, reopen = nil, string(unstarted)
	}
	answered := machine.appRelease()
	confirmed := replaced == nil && answered == target
	finished := road.finish(out, s, confirmed)
	after := answered
	if !confirmed {
		after = machine.appRelease()
	}
	// The app is opened again as it was, whatever came before; one that
	// is not stops the update before the stack, whose next run finishes
	// it.
	if box && len(start) > 0 {
		if err := applyWithin(appQuitWithin, start); err != nil {
			reopen = fmt.Sprintf("the screen could not be started again (%v): start it with 'sudo systemctl start cyfr-screen'", err)
		}
	} else if ran {
		switch err := reopenApp(writesTheRecord(out)); {
		case errors.Is(err, errNoDisplayToReopen):
			reopen = "the CYFR app was closed and cannot be opened from a session with no display: open CYFR on this computer's desktop"
		case err != nil:
			reopen = fmt.Sprintf("the CYFR app could not be opened again (%v): open CYFR", err)
		}
	}
	switch {
	case !confirmed && finished != nil:
		return fmt.Errorf("%s, and the CYFR app before it could not be put back (%v); your CYFR was not touched. Install release %s from %s/tag/%s", refusedReplacement(replaced, answered, after, target), finished, target, releasesPage, target)
	case !confirmed && reopen != "":
		return fmt.Errorf("%s; %s, and your CYFR was not touched. Then run '%s' again", refusedReplacement(replaced, answered, after, target), reopen, again)
	case !confirmed:
		return fmt.Errorf("%s; your CYFR was not touched. Run '%s' again", refusedReplacement(replaced, answered, after, target), again)
	case finished != nil:
		fmt.Fprintf(out, "What was kept of the CYFR app before this one could not be removed (%v); the next update removes it.\n", finished)
	}
	if reopen != "" {
		return fmt.Errorf("The CYFR app is release %s, but %s, then run '%s' again to update CYFR here; your CYFR was not touched", target, reopen, again)
	}
	fmt.Fprintf(out, "The CYFR app is release %s.\n", target)
	return nil
}

// screenUnstarted is a replacement that installed the app with the box's
// screen not started again, saying how to start it: the update stops
// before the stack, as one whose screen does not start again through sudo
// does (updateApp).
type screenUnstarted string

func (s screenUnstarted) Error() string { return string(s) }

// refusedReplacement says why a replacement is refused and which release
// the app is now, once what was kept went back (after): its installer's
// failure, or the installed app's own cyfr answering another than target.
func refusedReplacement(replaced error, answered, after, target string) string {
	if replaced != nil {
		return fmt.Sprintf("%v; %s", replaced, appIs(after))
	}
	said := "the installed app's own cyfr answered no release"
	if answered != "" {
		said = "the installed app's own cyfr answered " + answered
	}
	return fmt.Sprintf("The installer finished, but %s, not %s; %s", said, target, appIs(after))
}

// applyWithin runs commands as root through one sudo, whose login
// elevate took, in a transient system unit bounded by within
// (systemd-run): at the bound systemd kills every process the unit's
// control group holds, whatever root started (KillSignal=SIGKILL), and
// systemd-run returns only once the unit has stopped. A terminal's ^C
// does not reach the unit. A run that failed at or past its bound is
// errOverran, never its own status.
func applyWithin(within time.Duration, commands []string) error {
	start := time.Now()
	err := machine.apply([]string{boundedRoot(within, commands)})
	if err != nil && time.Since(start) >= within {
		return fmt.Errorf("%w %v", errOverran, within)
	}
	return err
}

// boundedRoot is commands, each run only once those before it succeeded,
// as one transient unit of at most within (applyWithin).
func boundedRoot(within time.Duration, commands []string) string {
	return shellQuote([]string{"systemd-run", "--wait", "--pipe", "--collect", "--quiet",
		"-p", fmt.Sprintf("RuntimeMaxSec=%d", int(within.Seconds())), "-p", "KillSignal=SIGKILL", "-p", fmt.Sprintf("TimeoutStopSec=%d", int(boundGrace.Seconds())),
		"--", "/bin/sh", "-c", strings.Join(commands, " && ")})
}

// appQuitNone and appQuitAsked are the statuses the installed app started
// with --quit ends with (desktop/src/app.js): none of its kind ran for
// this account, so it took their place and ended at once; or one ran,
// which it asked to end. Any other status, or no status within its bound,
// is not an answer.
const (
	appQuitNone  = 0
	appQuitAsked = 3
)

// askAppToQuit ends the CYFR app this account runs: the installed app is
// started with --quit, which asks a running one to end and says so, again
// every quarter second until it says none runs, all within appQuitWithin.
// It answers whether one ran; with no app installed none runs. The app
// ends only on its own act, as it ends on any other close: what the page
// was doing is left as a quit leaves it.
func askAppToQuit() (bool, error) {
	app, err := installedApp()
	if err != nil {
		return false, err
	}
	if _, err := os.Stat(app); errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	deadline := time.Now().Add(appQuitWithin)
	ran := false
	for {
		c := exec.Command(app, "--quit")
		c.Env = append(os.Environ(), "CYFR_NO_UPDATE_CHECK=1")
		err := runWithin(appAskWithin, c)
		var exit *exec.ExitError
		switch {
		case err == nil:
			return ran, nil
		case errors.As(err, &exit) && exit.ExitCode() == appQuitAsked:
			ran = true
		case errors.As(err, &exit):
			return ran, fmt.Errorf("the CYFR app asked to quit ended with status %d", exit.ExitCode())
		default:
			return ran, fmt.Errorf("the CYFR app could not be asked to quit: %v", err)
		}
		if time.Now().After(deadline) {
			return ran, fmt.Errorf("it was still running %v after it was asked to quit", appQuitWithin)
		}
		time.Sleep(250 * time.Millisecond) // sleep-ok: the pace of asking a running app whether it has ended
	}
}

// errNoDisplayToReopen is startInstalledApp's refusal in a session with no
// display, a terminal reached over SSH among them: the app started there
// ends at once (Missing X server or $DISPLAY), though --quit from there
// reaches and ends the app of the account's desktop.
var errNoDisplayToReopen = errors.New("this session has no display")

// startInstalledApp opens the installed app, not waiting for it, as
// cyfr setup opens it, with --updated for an update Update CYFR started,
// whose window the app opens on its record; in a session with no display
// it opens nothing (errNoDisplayToReopen).
func startInstalledApp(updated bool) error {
	if !hasDisplay() {
		return errNoDisplayToReopen
	}
	app, err := installedApp()
	if err != nil {
		return err
	}
	c := exec.Command(app)
	if updated {
		c.Args = append(c.Args, "--updated")
	}
	if err := c.Start(); err != nil {
		return err
	}
	return c.Process.Release()
}

// errUpdateRuns is the refusal of a second cyfr update while one runs.
var errUpdateRuns = errors.New("Another cyfr update is changing CYFR on this computer; nothing was changed. Run 'cyfr update' again once it has finished")

// lockUpdate takes the lock one cyfr update at a time holds while it
// changes the installed app or this program (updateLockPath), before
// anything is staged, and answers what lets it go; a second update is
// refused (errUpdateRuns). The lock goes with this process, however it
// ends, and is not handed over: the program the update goes on as runs
// the stack's step under the stack's own lock.
func lockUpdate() (func(), error) {
	f, err := openLock(updateLockPath)
	if err != nil {
		return nil, fmt.Errorf("cyfr update could not open its lock %s (%v); nothing was changed", updateLockPath, err)
	}
	held, err := takeLock(f)
	switch {
	case held:
		f.Close()
		return nil, errUpdateRuns
	case err != nil:
		f.Close()
		return nil, fmt.Errorf("cyfr update could not take its lock %s (%v); nothing was changed", updateLockPath, err)
	}
	var once sync.Once
	return func() { once.Do(func() { f.Close() }) }, nil
}

// openLock opens the lock file at path for reading, which is all a lock
// needs, and never with O_CREAT where it is there: in a shared sticky
// folder Linux refuses an O_CREAT open of a file another account owns,
// to root as well (fs.protected_regular). Where it is not there it is
// made, readable by every account whatever this one's umask, and opened
// again; one another update made meanwhile is opened as it is.
func openLock(path string) (*os.File, error) {
	f, err := os.Open(path)
	if !errors.Is(err, fs.ErrNotExist) {
		return f, err
	}
	made, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	switch {
	case errors.Is(err, fs.ErrExist):
	case err != nil:
		return nil, err
	default:
		if err := errors.Join(made.Chmod(0o644), made.Close()); err != nil {
			return nil, err
		}
	}
	return os.Open(path)
}

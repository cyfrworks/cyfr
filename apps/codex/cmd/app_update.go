// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/release"
)

// The bounds of the installed app's update, each longer than what it
// bounds can take when it works: appQuitWithin the app's own end (its
// cyfr's five-second shutdown and its lock), appAskWithin one start of the
// app that asks the running one to end, appReplaceWithin a package tool's
// install of the app, and boundGrace what a process the bound ended is
// given to go.
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
	// is mended.
	elevate(out io.Writer, again string) (release func(), err error)
	// replace installs what fetch verified over the installed app, older
	// when that is a release before the installed one, and runs to its
	// end within its bound, whatever this cyfr is asked meanwhile. A
	// replacement that failed leaves the installed app as it was or as the
	// installer's own undoing left it; it never answers success unless
	// its installer did.
	replace(out io.Writer, s *staged, older bool) error
	// closesTheBox is the root commands that stop the box's screen and
	// start it again, through the same elevation, where the road has one;
	// nil elsewhere.
	closesTheBox() (stop, start []string)
}

// staged is release target's installer fetch verified: file, its sha256
// sum, in dir, the folder of its own fetch made; a road whose installer
// fetches for itself (Homebrew) stages no file.
type staged struct{ target, dir, file, sum string }

// remove removes the folder fetch made.
func (s *staged) remove() {
	if s != nil && s.dir != "" {
		_ = os.RemoveAll(s.dir)
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
		return nil, fmt.Errorf("The CYFR app of release %s did not verify (%v); nothing was changed and CYFR runs as it did", target, err)
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
	let, err := road.elevate(out, again)
	if err != nil {
		return err
	}
	defer let()
	if ctx.Err() != nil {
		return errors.New("cyfr update was interrupted before the CYFR app was closed; nothing was changed and CYFR runs as it did")
	}

	stop, start := road.closesTheBox()
	_, box := machine.screenService()
	box = box && stop != nil
	ran := false
	if box {
		fmt.Fprintln(out, "Stopping this machine's screen, so its launcher does not start the old CYFR app again while it is replaced...")
		if err := applyWithin(appQuitWithin, stop); err != nil {
			// A stop that failed may have stopped it: it is started again.
			_ = applyWithin(appQuitWithin, start)
			return fmt.Errorf("The screen could not be stopped (%v); nothing was replaced and the CYFR app is as it was", err)
		}
	} else {
		fmt.Fprintln(out, "Closing the CYFR app...")
		r, err := quitApp()
		if err != nil {
			return fmt.Errorf("The CYFR app could not be closed (%v); nothing was replaced. If CYFR is closed, open it again: it is release %s", err, before)
		}
		ran = r
	}

	replaced := road.replace(out, s, older)
	after := machine.appRelease()
	if box {
		if err := applyWithin(appQuitWithin, start); err != nil {
			fmt.Fprintf(out, "The screen could not be started again (%v); run 'sudo systemctl start cyfr-screen'.\n", err)
		}
	} else if ran {
		if err := reopenApp(); err != nil {
			fmt.Fprintf(out, "The CYFR app could not be opened again (%v); open it yourself.\n", err)
		}
	}
	switch {
	case replaced != nil:
		return fmt.Errorf("%v; %s, and your CYFR was not touched. Run '%s' again", replaced, appIs(after), again)
	case after != target:
		return fmt.Errorf("The installer finished, but %s, not %s; your CYFR was not touched. Run '%s' again", appIs(after), target, again)
	}
	fmt.Fprintf(out, "The CYFR app is release %s.\n", target)
	return nil
}

// applyWithin runs commands as root through one sudo, whose login
// elevate took, bounded by within: timeout, in a process group of its
// own that a terminal's ^C does not reach, ends the whole group the
// commands make at the bound, and its status then is errOverran.
func applyWithin(within time.Duration, commands []string) error {
	c := shellQuote([]string{"sh", "-c", strings.Join(commands, " && ")})
	err := machine.apply([]string{fmt.Sprintf("timeout --kill-after=%ds %ds %s", int(boundGrace.Seconds()), int(within.Seconds()), c)})
	var exit *exec.ExitError
	if errors.As(err, &exit) && (exit.ExitCode() == timedOut || exit.ExitCode() == timedOutKilled) {
		return fmt.Errorf("%w %v", errOverran, within)
	}
	return err
}

// timedOut and timedOutKilled are timeout's statuses for a command its
// bound ended, by its signal and by the kill after it.
const (
	timedOut       = 124
	timedOutKilled = 137
)

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

// startInstalledApp opens the installed app, not waiting for it, as
// cyfr setup opens it.
func startInstalledApp() error {
	app, err := installedApp()
	if err != nil {
		return err
	}
	c := exec.Command(app)
	if err := c.Start(); err != nil {
		return err
	}
	return c.Process.Release()
}

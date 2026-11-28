// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/desktop"
	"github.com/cyfr/codex/internal/shell"
	"github.com/cyfr/codex/internal/version"
)

// The CYFR app's Update CYFR page (internal/desktop/update.go): what it
// offers, worked out by the app's own cyfr, and the run a yes starts,
// which is cyfr update itself, the same transaction a person runs in a
// terminal. The update of the app and the update of this computer's own
// CYFR are two yeses: the app's first, which ends with the app opened
// again at the new release; then, in that app, this computer's own CYFR's
// change, worked out by the new release's own code (cyfr update --offer)
// and made only as it was shown (--confirmed).

// offerWithin bounds the read of this computer's own CYFR's change: the
// manifest's fetch and the schema's read, each bounded within it.
const offerWithin = composeRunTimeout + 2*time.Minute

// updateRecordName is the update's record, the output of each run Update
// CYFR starts, in the device's folder beside its list of CYFRs; windowRecord
// is its path.
const updateRecordName = "update.log"

func windowRecord() string {
	dir, err := shell.DeviceFolder()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, updateRecordName)
}

// writesTheRecord is whether out is the update's record: the run Update
// CYFR started, its output that file by its start (beginWindowUpdate),
// and the program it hands over to, which keeps that output. Its update
// is the app's alone, and it opens the app again with --updated.
func writesTheRecord(out io.Writer) bool {
	f, ok := out.(*os.File)
	if !ok {
		return false
	}
	mine, err := f.Stat()
	if err != nil {
		return false
	}
	record, err := os.Stat(windowRecord())
	return err == nil && os.SameFile(mine, record)
}

// windowOffer is what Update CYFR offers this app, whose own cyfr this
// is, with project the folder of this computer's own CYFR when it is the
// one open. Where a newer release is published, the app's own update to
// it, once what the transaction would refuse before the app closes is
// asked as its run, which has no terminal, would meet it (the road's
// elevation, asking nothing): refused, the sentence and the line to run
// in a terminal instead. Where none is, this computer's own CYFR's change,
// if its stack is behind the app. The app's run is the app's alone
// (writesTheRecord), started in device; this computer's own CYFR's runs
// in its folder.
func windowOffer(ctx context.Context, device, project string) desktop.UpdatePlan {
	current := version.Version
	p := desktop.UpdatePlan{UpdateOffer: desktop.UpdateOffer{App: current, Says: []string{}}}
	say := func(lines ...string) { p.Says = append(p.Says, lines...) }
	target, latest, none, err := updateTarget(ctx, current, "", func(t string) bool { return t == current })
	switch {
	case err != nil:
		say(fmt.Sprintf("The newest release of CYFR could not be read (%v). Nothing was changed; try again later.", errors.Unwrap(err)))
		return p
	case none == devBuild:
		say(fmt.Sprintf("This CYFR app is a development build (%s), which is not updated.", current))
		return p
	case none == noReleaseYet:
		say("No release of CYFR is published yet, so this app stays as it is.")
	case none == pastNewest:
		say(fmt.Sprintf("This CYFR app is release %s, newer than the newest release, %s, so it stays.", current, latest))
	case none == onNewest:
		say(fmt.Sprintf("This CYFR app is release %s, the newest.", current))
	}
	if none != 0 {
		if project != "" {
			stackOffer(ctx, &p, project)
		}
		return p
	}

	again := "cyfr update --version " + target
	p.Target = target
	cask := caskInstalled()
	road := appRoadHere()
	if cask {
		road = caskRoad{exact: true}
	}
	if road == nil {
		say("This system has no installer the CYFR app can be updated with; nothing was changed.")
		return p
	}
	// What the transaction would refuse before the app closes is asked
	// now, as its run meets it with no terminal (detachedFromApp), so the
	// page says it before any yes: sudo is never asked for a password,
	// whatever terminal this cyfr has.
	var said strings.Builder
	let, err := road.elevate(&said, again, false)
	if err != nil {
		for _, line := range strings.Split(strings.TrimSpace(said.String()), "\n") {
			if line = strings.TrimSpace(line); line != "" {
				say(line)
			}
		}
		say(err.Error())
		// On a Mac only an account that may not write the app is
		// refused, which sudo lets write it (macRoad's elevate).
		p.Terminal = again
		if runtime.GOOS == "darwin" && !cask {
			p.Terminal = "sudo " + again
		}
		return p
	}
	let()
	p.Step = "app"
	say(fmt.Sprintf("Updating closes this app, replaces it with release %s once it is checked against the release's signed checksums, and opens it again.", target))
	// What the road said of how it makes the update (Linux's service).
	for _, line := range strings.Split(strings.TrimSpace(said.String()), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			say(line)
		}
	}
	if cask {
		say("Homebrew replaces it, as it installed it.")
	}
	if project != "" {
		say(fmt.Sprintf("Your CYFR in %s keeps running its release until you update it too: this page offers that once the app has opened again.", project))
	}
	p.Dir, p.Args = device, []string{"update", "--version", target}
	return p
}

// stackOffer adds this computer's own CYFR's change in project to p, as
// this release's own cyfr update shows it (--offer): the yes that makes
// it, where there is one, and otherwise the sentence why there is none.
func stackOffer(ctx context.Context, p *desktop.UpdatePlan, project string) {
	self, err := selfExecutable()
	if err != nil {
		p.Says = append(p.Says, fmt.Sprintf("Your CYFR in %s could not be checked (%v).", project, err))
		return
	}
	c := exec.CommandContext(ctx, self, "update", "--version", version.Version, "--offer")
	c.Dir = project
	var out, said bytes.Buffer
	c.Stdout, c.Stderr = &out, &said
	if err := runWithin(offerWithin, c); err != nil {
		why := lastError(said.String())
		if why == "" {
			why = err.Error()
		}
		p.Says = append(p.Says, fmt.Sprintf("Your CYFR in %s could not be checked for its update: %s", project, why))
		return
	}
	text := strings.TrimSuffix(out.String(), "\n")
	var shown shownChange
	if err := json.Unmarshal([]byte(text[strings.LastIndex(text, "\n")+1:]), &shown); err != nil ||
		(shown.Change == "" || shown.Confirmation == "") && shown.Current == "" {
		p.Says = append(p.Says, fmt.Sprintf("Your CYFR in %s could not be checked for its update: its answer could not be read.", project))
		return
	}
	if shown.Current != "" {
		p.Says = append(p.Says, fmt.Sprintf("Your CYFR in %s: %s", project, shown.Current))
		return
	}
	p.Step, p.Target = "stack", version.Version
	lines := strings.Split(strings.TrimSpace(shown.Change), "\n")
	if shown.OnRelease {
		// A CYFR on this release already switches nothing: the change's own
		// first line says so, and the page starts there.
		lines[0] = fmt.Sprintf("Your CYFR in %s: %s", project, strings.TrimSpace(lines[0]))
	} else {
		p.Says = append(p.Says, fmt.Sprintf("Your CYFR in %s still runs the release it ran before this app was updated, as it does after a cyfr update answered no. Updating it to release %s:", project, version.Version))
	}
	for _, line := range lines {
		p.Says = append(p.Says, strings.TrimSpace(line))
	}
	p.Dir, p.Args = project, []string{"update", "--version", version.Version, "--confirmed", shown.Confirmation}
}

// lastError is the sentence cyfr ended on, its last "Error: " line.
func lastError(said string) string {
	last := ""
	for _, line := range strings.Split(said, "\n") {
		if s, ok := strings.CutPrefix(strings.TrimSpace(line), "Error: "); ok {
			last = s
		}
	}
	return last
}

// beginWindowUpdate starts plan's run, the app's own cyfr in plan's
// folder, apart from this cyfr and the app (detachedFromApp): the update
// closes the app, and with it this cyfr, and goes on to its end. Its
// output is record, a file, never a pipe of the app's, which would end it
// once nobody read it. Its input is nothing: no question is asked.
func beginWindowUpdate(p desktop.UpdatePlan, record *os.File) (func() error, error) {
	self, err := selfExecutable()
	if err != nil {
		return nil, fmt.Errorf("The app's cyfr could not be found (%v); nothing was changed", err)
	}
	c := exec.Command(self, p.Args...)
	c.Dir, c.Stdout, c.Stderr = p.Dir, record, record
	c.SysProcAttr = detachedFromApp()
	if err := c.Start(); err != nil {
		return nil, fmt.Errorf("The update could not be started apart from this app (%v); nothing was changed. Run 'cyfr update' in a terminal instead", err)
	}
	return c.Wait, nil
}

// windowUpdateRuns is whether an update runs on this computer, by the
// locks it holds: cyfr update's own while it changes the app or this
// program, and the stack's of the CYFR in project while that one's runs.
func windowUpdateRuns(project string) bool {
	if f, err := os.Open(updateLockPath); err == nil {
		held, _ := takeLock(f)
		f.Close()
		if held {
			return true
		}
	}
	return project != "" && access.Locked(project)
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/shell"
	"github.com/cyfr/codex/internal/version"
	"github.com/spf13/cobra"
)

//go:embed screen
var screenFiles embed.FS

const (
	screenDir  = ".cyfr/screen"
	screenUnit = "/etc/systemd/system/cyfr-screen.service"
	// appPackage is the CYFR app's Linux package (desktop/scripts/build.mjs),
	// the screen's browser, which the launcher runs.
	appPackage = "cyfr-desktop"
	// screenAppFile is where `cyfr screen on` keeps the app's package it
	// fetched, the account's alone, until the command ends.
	screenAppFile = screenDir + "/" + appPackage + ".deb"
)

// fetchAppPackage is release.FetchPackage, a variable so tests stand in
// for the release.
var fetchAppPackage = release.FetchPackage

// screenPath is a project path the service's unit can hold as it is.
var screenPath = regexp.MustCompile(`^[A-Za-z0-9/._-]+$`)

var screenCmd = &cobra.Command{
	Use:   "screen",
	Short: "Show CYFR on this machine's own screen, or stop showing it",
	Long:  "Show CYFR full-screen on this machine's own screen at power-on, with no desktop, on Ubuntu 26.04 LTS on amd64. The screen sets CYFR up with your name and a PIN (a passphrase on a machine without a TPM chip): it makes your account, with this box its first device, and shows your recovery code, or adds the box to the account you have once a device of yours approves it; then it opens Prism. It locks after five minutes without input, whatever is playing on it, at a suspend and from its Lock, and unlocks with the PIN. It never starts or stops CYFR. The CYFR app is what shows it: `cyfr screen on` installs the app's package of this cyfr's release, downloaded and checked against the release's signed checksums before anything is asked, where the machine has no other.",
}

var screenOnCmd = &cobra.Command{
	Use:   "on",
	Short: "Show CYFR on this machine's own screen; again, rewrite what shows it",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		return runScreenOn(cmd.Context(), cmd.OutOrStdout())
	},
}

// runScreenOn is `cyfr screen on`: screenOn, asking first, then the next
// step; answered no, it says so and ends as no failure.
func runScreenOn(ctx context.Context, out io.Writer) error {
	switch err := screenOn(ctx, true, out); {
	case errors.Is(err, errDeclined):
		return nil
	case err != nil:
		return err
	}
	fmt.Fprintln(out, "The screen starts at the next boot. Run `cyfr up`, then `sudo reboot`.")
	return nil
}

var screenOffCmd = &cobra.Command{
	Use:   "off",
	Short: "Give this machine's screen back to its login prompt",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		return screenOff(cmd.OutOrStdout())
	},
}

var screenShellCmd = &cobra.Command{
	Use:    "shell",
	Short:  "Run this machine's screen: its pages, keyboard and idle lock, for the CYFR app that started it (the app runs it)",
	Hidden: true,
	Args:   cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		return runScreenShell(cmd.Context(), shell.ListenLoopback, os.Stdin, os.Stdout)
	},
}

func init() {
	screenCmd.AddCommand(screenOnCmd, screenOffCmd, screenShellCmd)
	rootCmd.AddCommand(screenCmd)
}

// screenPossible is a machine `cyfr screen on` runs on.
func screenPossible() bool {
	return askTerminal() && machine.supported() && machine.arch() == "amd64"
}

// askScreen is init's question, for a new project on a machine that can
// show CYFR and has no desktop: true for the first answer, which init
// installs (screenOn) once .env is written.
func askScreen(ctx context.Context, out io.Writer) (bool, error) {
	if !screenPossible() || machine.displayManager() {
		return false, nil
	}
	fmt.Fprintln(out, "This machine has no desktop. Show CYFR on its screen?")
	fmt.Fprintln(out, "  1. Yes. At power-on this screen shows CYFR full screen, with an on-screen keyboard.")
	fmt.Fprintln(out, "  2. No. This screen keeps its login prompt, and you open CYFR from another machine.")
	answer, _, err := askLine(ctx, bufio.NewReader(askInput), out, "Choose 1 or 2", "1")
	if err != nil {
		return false, interruption{errQuestionInterrupted}
	}
	if answer != "1" {
		return false, nil
	}
	return true, screenAdministrator("cyfr init")
}

// screenOn writes what shows CYFR into the project, then installs it through
// one sudo, asking first when confirm says to. It starts nothing, so the
// terminal it runs in is never taken away, on tty1 included: the screen
// starts at the next boot.
func screenOn(ctx context.Context, confirm bool, out io.Writer) error {
	switch {
	case !screenPossible():
		return errors.New("`cyfr screen` runs at a terminal on Ubuntu 26.04 LTS on amd64, as your own account")
	case machine.displayManager():
		return errors.New("This machine's display manager has the screen. Stop it, then run `cyfr screen on` again")
	case !access.HasComposeFile(".") || !fileExists(".env"):
		return errors.New("There is no CYFR in this directory. Run `cyfr screen on` in the directory `cyfr init` set up")
	}
	dir, account, err := screenSite()
	if err != nil {
		return err
	}
	if err := screenAdministrator("cyfr screen on"); err != nil {
		return err
	}
	app, err := screenFetchApp(ctx, out)
	defer app.remove()
	if err != nil {
		return err
	}
	commands := screenCommands(dir, account, app.sum)
	fmt.Fprintln(out, "These commands show CYFR on this machine's own screen, as root:")
	for _, c := range commands {
		fmt.Fprintf(out, "  %s\n", c)
	}
	if confirm {
		answer, err := ask(ctx, bufio.NewReader(askInput), out, "Show CYFR on this screen? (yes/no)", "no")
		if err != nil {
			return interruption{errQuestionInterrupted}
		}
		if !strings.EqualFold(answer, "yes") && !strings.EqualFold(answer, "y") {
			fmt.Fprintln(out, "Nothing was installed. Run cyfr screen on again when you want to continue.")
			return errDeclined
		}
	}
	// The files the commands install are written once sudo has the login,
	// so a refusal leaves the project as it was.
	defer machine.forget()
	if err := unlockSudo(out, "cyfr screen on"); err != nil {
		return err
	}
	if err := writeScreenFiles(dir, account); err != nil {
		return fmt.Errorf("cyfr screen could not write %s (%v)", screenDir, err)
	}
	if machine.apply(commands) != nil {
		return errors.New("Showing CYFR on this screen failed. Fix what is shown above, then run `cyfr screen on` again")
	}
	return nil
}

// screenAdministrator refuses an account outside the sudo and admin groups
// before the screen is asked for or anything is written, in words alone:
// the screen is this account's, so it cannot be set up from another, and
// CYFR prints no command that grants an account sudo.
func screenAdministrator(again string) error {
	account, administers, err := administrator()
	if err != nil || administers {
		return err
	}
	return outsideTheGroups{account, again}
}

// outsideTheGroups is screenAdministrator's refusal: nothing has run.
type outsideTheGroups struct{ account, again string }

func (o outsideTheGroups) Error() string {
	return fmt.Sprintf("Your account, %s, is not in the sudo or admin group, so CYFR does not run commands as root for it. Nothing was changed. Whoever administers this machine can add your account to the sudo group; then run `%s` again", o.account, o.again)
}

// screenSite is the project directory and the account the screen's files
// name: the working directory, refused when the service's unit could not
// hold its path as it is, and this account.
func screenSite() (string, string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", "", err
	}
	if !screenPath.MatchString(dir) {
		return "", "", fmt.Errorf("`cyfr screen` needs a project path of letters, digits and / . _ - alone, and this one is %q", dir)
	}
	account, err := user.Current()
	if err != nil {
		return "", "", err
	}
	return dir, account.Username, nil
}

// fetchedApp is the CYFR app's package `cyfr screen on` fetched into
// screenAppFile, sum its sha256 as the release's signed checksums name it;
// the zero fetchedApp is none, the machine holding the app of this release.
type fetchedApp struct {
	sum string
	// made are the folders the fetch made, removed with the file when the
	// command ends, so the project is left as it was unless the screen's
	// files were written into them since.
	made []string
}

// screenFetchApp fetches the CYFR app's package of this cyfr's release
// for this machine into screenAppFile, mode 0600, unless dpkg holds it
// installed at that release already: release.FetchPackage answers its
// bytes only once they match the release's signed checksums. A
// development build, with no release to fetch from, is refused.
func screenFetchApp(ctx context.Context, out io.Writer) (fetchedApp, error) {
	if machine.installed(appPackage) == version.Version {
		return fetchedApp{}, nil
	}
	if !release.IsVersion(version.Version) {
		return fetchedApp{}, fmt.Errorf("This cyfr is a development build (%s), so there is no release of the CYFR app to download for it, and this machine has none installed at it. Install the CYFR app's package built with this cyfr, then run `cyfr screen on` again", version.Version)
	}
	var app fetchedApp
	for _, d := range []string{filepath.Dir(screenDir), screenDir} {
		if !fileExists(d) {
			if err := os.Mkdir(d, 0o700); err != nil {
				return app, fmt.Errorf("cyfr screen could not make %s (%v)", d, err)
			}
			app.made = append([]string{d}, app.made...)
		}
	}
	fmt.Fprintf(out, "Downloading the CYFR app, release %s for %s, and checking it against the release's signed checksums.\n", version.Version, machine.arch())
	data, err := fetchAppPackage(ctx, version.Version, machine.arch())
	if err != nil {
		return app, fmt.Errorf("The CYFR app could not be downloaded, so nothing was installed (%v). Run `cyfr screen on` again", err)
	}
	if err := writeFileAtomic(screenAppFile, data, 0o600); err != nil {
		return app, fmt.Errorf("cyfr screen could not keep the CYFR app's package in %s (%v)", screenAppFile, err)
	}
	sum := sha256.Sum256(data)
	app.sum = hex.EncodeToString(sum[:])
	return app, nil
}

// remove removes the fetched package, and the folders the fetch made that
// nothing else was written into since.
func (a fetchedApp) remove() {
	if a.sum != "" || len(a.made) > 0 {
		_ = os.Remove(screenAppFile)
	}
	for _, d := range a.made {
		_ = os.Remove(d)
	}
}

// screenCommands are the commands `cyfr screen on` runs, the packages'
// only if needed: app is the sha256 of the CYFR app's package fetched into
// the project, or "" where the machine has it. The package is the
// account's file, so root copies it where the account cannot write, and
// apt installs that copy only once root has checked it against app: a
// package changed after the fetch is never installed.
func screenCommands(dir, account, app string) []string {
	base := machine.installed("labwc") != "" && machine.installed("wvkbd") != "" && machine.installed("swayidle") != ""
	var commands []string
	if !base || app != "" {
		commands = append(commands, "apt-get update")
	}
	if !base {
		commands = append(commands, "apt-get install -y --no-install-recommends labwc wvkbd swayidle")
	}
	if app != "" {
		commands = append(commands,
			"d=$(mktemp -d)",
			"chmod 0755 \"$d\"",
			"install -m 0644 "+shellQuote([]string{filepath.Join(dir, screenAppFile)})+" \"$d/"+appPackage+".deb\"",
			"echo '"+app+"  '\"$d/"+appPackage+".deb\" | sha256sum --check --strict --quiet",
			"apt-get install -y \"$d/"+appPackage+".deb\"",
			"rm -rf \"$d\"")
	}
	files := shellQuote([]string{filepath.Join(dir, screenDir)})
	return append(commands,
		// The TPM's resource manager is the tss group's: the screen's
		// account joins it, where there is one, to keep its PIN in the chip.
		"{ ! getent group tss >/dev/null || usermod -aG tss "+shellQuote([]string{account})+"; }",
		"install -m 0644 "+files+"/cyfr-screen.service "+screenUnit,
		"systemctl daemon-reload",
		"systemctl disable getty@tty1",
		"systemctl enable cyfr-screen")
}

// screenOffCommands give this machine's screen back to its login prompt,
// as root: `cyfr screen off` and `cyfr uninstall` run them.
var screenOffCommands = []string{
	"{ systemctl disable --now cyfr-screen || true; }",
	"rm -f " + screenUnit,
	"systemctl daemon-reload",
	"systemctl enable --now getty@tty1",
}

// screenOff leaves the packages, the CYFR app's among them, and the project.
func screenOff(out io.Writer) error {
	if !askTerminal() || !machine.supported() {
		return errors.New("`cyfr screen` runs at a terminal on Ubuntu 26.04 LTS, as your own account")
	}
	if err := screenAdministrator("cyfr screen off"); err != nil {
		return err
	}
	commands := screenOffCommands
	fmt.Fprintln(out, "These commands give this machine's screen back to its login prompt, as root:")
	for _, c := range commands {
		fmt.Fprintf(out, "  %s\n", c)
	}
	defer machine.forget()
	if err := unlockSudo(out, "cyfr screen off"); err != nil {
		return err
	}
	if machine.apply(commands) != nil {
		return errors.New("Giving the screen back failed. Fix what is shown above, then run `cyfr screen off` again")
	}
	return nil
}

// writeScreenFiles renders the embedded files into the project, naming
// the directory and the account, which `cyfr screen on` writes. They hold
// nothing of how CYFR is reached: the shell reads that from the folder
// each time it starts.
func writeScreenFiles(dir, account string) error {
	fill := strings.NewReplacer("@DIR@", dir, "@ACCOUNT@", account)
	if err := os.MkdirAll(screenDir, 0o700); err != nil {
		return err
	}
	entries, err := screenFiles.ReadDir("screen")
	if err != nil {
		return err
	}
	for _, e := range entries {
		raw, err := screenFiles.ReadFile("screen/" + e.Name())
		if err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		if strings.HasSuffix(e.Name(), ".sh") {
			mode = 0o755
		}
		if err := writeFileAtomic(filepath.Join(screenDir, e.Name()), []byte(fill.Replace(string(raw))), mode); err != nil {
			return err
		}
	}
	return nil
}

// screenIdle is how long the screen waits without local input before it
// locks. It is counted from input alone (internal/idle): a video that a
// tap or click started, with sound or without, in a page or in a frame of
// one, holds off the idle notification swayidle takes, so the time is not
// swayidle's to count. One that started by itself does not.
const screenIdle = 5 * time.Minute

const (
	idleLocked    = "Locked after five minutes without use."
	suspendLocked = "Locked as this device went to sleep."
)

// runScreenShell is the screen's session inside labwc, which the CYFR app
// started in the project's folder (desktop/src/app.js): the shell's pages
// on loopback (listen takes their address), the on-screen keyboard, the
// watches that lock it (screenWatches), and the app as the browser on
// those pages (screenApp), reading its main process's messages from in
// and writing its own to out, told the pages once the keyboard and the
// watches are up (screenWatches.watch). While the keyboard or those
// watches are not known to work it runs on locked, its page saying why.
// main's end, which ends its pipe, locks and ends the shell; this
// process's own end (SIGTERM, SIGINT, SIGHUP) locks before it exits. Any
// lock hides what is on the screen first (the app's hide), then ends the
// sessions at the home, so no page of the unlocked session outlives it.
func runScreenShell(ctx context.Context, listen func() (net.Listener, error), in io.Reader, out io.Writer) error {
	_ = holder.HardenProcess()
	dir, err := os.Getwd()
	if err != nil {
		return err
	}
	local, err := readLocal(dir, "screen")
	if err != nil {
		return fmt.Errorf("The screen cannot read how CYFR is reached here (%v)", err)
	}
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer stop()
	browser, err := newScreenApp(in, out, local)
	if err != nil {
		return err
	}
	// A keyboard and a suspend watch a killed shell left, the watch
	// aimed at that shell's pid.
	_ = exec.Command("pkill", "-x", "wvkbd-mobintl").Run()
	_ = exec.Command("pkill", "-f", "--", "^swayidle -d -w -C /dev/null before-sleep kill -USR1 ").Run()
	host, _ := os.Hostname()
	ln, device, err := screenClaim(listen, dir)
	if err != nil {
		return err
	}
	// A watch lost locks, and the lock hides the page shown then, which
	// gives way to the one that says why (shell.Shell.Lock).
	watches := newScreenWatches(screenIdle, nil)
	cfg := local.Shell
	cfg.DisplayName, cfg.Restart, cfg.Warning = host, browser.hide, releaseApart(dir, version.Version)
	cfg.Record = filepath.Join(device, "holder.json")
	cfg.Clients = shell.ClientFile(filepath.Join(device, "client.json"))
	cfg.Unwatched = watches.Unwatched
	sh, err := shell.New(cfg)
	if err != nil {
		ln.Close()
		return err
	}
	// A folder naming another CYFR than the one this shell opened ends it:
	// the launcher starts it again on the reading made then.
	moved := make(chan error, 1)
	srv := &shell.Server{Shell: sh, Reachable: func() bool {
		err := local.Answers(ctx)
		var unbound *shell.Unbound
		if errors.As(err, &unbound) && unbound.Moved {
			select {
			case moved <- err:
			default:
			}
		}
		return err == nil
	}}
	served := make(chan error, 1)
	go func() { served <- srv.ServeOn(ctx, ln) }()

	watches.lock = func(why string) { sh.Lock(why) }
	watching, stopWatching := context.WithCancel(ctx)
	kept := make(chan struct{})
	go func() {
		defer close(kept)
		watches.keep(watching)
	}()
	defer func() {
		stopWatching()
		<-kept
	}()
	// The first page is the one the watches give: the lock page, or why not.
	select {
	case <-watches.Settled():
	case <-ctx.Done():
	}

	shown := make(chan error, 1)
	go func() { shown <- browser.show(sh.Lock) }()

	var ended error
	select {
	case <-ctx.Done():
	case ended = <-served:
	case ended = <-shown:
	case err := <-moved:
		ended = fmt.Errorf("The screen starts again on this folder's settings (%v)", err)
	}
	sh.Lock("")
	return ended
}

// releaseApart is what the screen's page says where the app's cyfr, which
// runs this shell (release ours), is another release than the CYFR the
// folder runs: `cyfr update` moves the folder and the program that ran it,
// and the app only as `cyfr screen on` installs it again. "" where they
// agree, or where either is no release.
func releaseApart(dir, ours string) string {
	running := folderRelease(dir)
	if !release.IsVersion(ours) || running == "" || running == ours {
		return ""
	}
	return fmt.Sprintf("This screen's CYFR app is release %s and the CYFR here runs release %s, so the screen may not work as it should. Run `cyfr screen on` in %s to bring the app to release %s.", ours, running, dir, running)
}

// folderRelease is the release the compose file in dir runs CYFR at: the
// one tag its cyfr images share where it is a release version, else "".
func folderRelease(dir string) string {
	for _, name := range access.ComposeMainFiles {
		path := filepath.Join(dir, name)
		if !fileExists(path) {
			continue
		}
		found := ""
		for _, image := range imagesFromCompose(path, []string{buildsProfile, access.ModePublic, access.ModeTailnet}) {
			repository, tag, _ := splitImageReference(image)
			if normalizeRepository(repository) != release.RepoCyfr {
				continue
			}
			if !release.IsVersion(tag) || found != "" && tag != found {
				return ""
			}
			found = tag
		}
		return found
	}
	return ""
}

// screenClaim takes the shell's listener, then selects the CYFR in dir in
// this account's client record: the record is shared with the CYFR app,
// so only the one process holding the listener writes it.
func screenClaim(listen func() (net.Listener, error), dir string) (net.Listener, string, error) {
	ln, err := listen()
	if err != nil {
		return nil, "", fmt.Errorf("The screen cannot take %s, which another program holds (%v)", shell.Listen, err)
	}
	device, err := shell.DeviceDir()
	if err == nil {
		err = shell.ClientFile(filepath.Join(device, "client.json")).SelectProject(dir)
	}
	if err != nil {
		ln.Close()
		return nil, "", fmt.Errorf("The screen cannot show the CYFR here: %v", err)
	}
	return ln, device, nil
}

// sigUSR1 is Linux's SIGUSR1, named by number so this file builds where
// the screen never runs: the screen runs on Ubuntu alone.
const sigUSR1 = syscall.Signal(10)

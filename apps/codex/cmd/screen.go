// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"embed"
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
	"github.com/cyfr/codex/internal/wayland"
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

// appCyfr is the cyfr inside the CYFR app's package, the one that runs the
// screen's shell (desktop/scripts/build.mjs); a variable so tests stand in
// for it.
var appCyfr = "/opt/cyfr/resources/cyfr"

// appProgram is the CYFR app's own program in its package.
const appProgram = "/opt/cyfr/CYFR"

// appPackageSum and fetchAppPackage are release.PackageChecksum and
// release.FetchPackage, variables so tests stand in for the release.
var (
	appPackageSum   = release.PackageChecksum
	fetchAppPackage = release.FetchPackage
)

// screenPath is a project path the service's unit can hold as it is.
var screenPath = regexp.MustCompile(`^[A-Za-z0-9/._-]+$`)

var screenCmd = &cobra.Command{
	Use:   "screen",
	Short: "Show CYFR on this machine's own screen, or stop showing it",
	Long:  "Show CYFR full-screen on this machine's own screen at power-on, with no desktop, on Ubuntu 26.04 LTS on amd64 or arm64. The screen sets CYFR up with your name and a PIN (a passphrase on a machine without a TPM chip): it makes your account, with this box its first device, and shows your recovery code, or adds the box to the account you have once a device of yours approves it; then it opens Prism. It locks after five minutes without input, whatever is playing on it, at a suspend and from its Lock, and unlocks with the PIN. It never starts or stops CYFR. The CYFR app is what shows it: `cyfr screen on` installs the app's package of this cyfr's release where the app's own cyfr answers no such release: the commands it shows install the package the release's signed checksums name, downloaded only after the yes.",
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

var screenAppCmd = &cobra.Command{
	Use:    "app DIR",
	Short:  "Start the CYFR app as this machine's screen for the project in DIR, on the route its CYFR takes (the screen's launcher runs it)",
	Hidden: true,
	Args:   cobra.ExactArgs(1),
	RunE: func(_ *cobra.Command, args []string) error {
		return screenExec(screenAppArgs(args[0]))
	},
}

// screenAppArgs is the CYFR app's command line as this machine's screen
// for the project in dir, which becomes the app's process (screenExec):
// --screen-project, and the engine's route to the folder's CYFR where it
// takes one (localRoute), read at each start, since the engine takes a
// route only as it starts: the app never starts itself again on the route
// its shell names (desktop/src/states.js), its launcher does, through
// this. A folder that cannot be read starts the app on none; its shell,
// reading the same folder, fails before it shows anything, so the screen
// stays dark: the reason goes to the app's error stream (the journal),
// the app ends itself once, and the launcher tries again a second later.
func screenAppArgs(dir string) []string {
	args := []string{appProgram, "--screen-project=" + dir}
	if read, err := readFolder(dir); err == nil {
		if proxy, resolver := localRoute(read.Mode); proxy != "" {
			args = append(args, "--proxy-server="+proxy, "--host-resolver-rules="+resolver)
		}
	}
	return args
}

func init() {
	screenCmd.AddCommand(screenOnCmd, screenOffCmd, screenShellCmd, screenAppCmd)
	rootCmd.AddCommand(screenCmd)
}

// screenPossible is a machine `cyfr screen on` runs on: one the CYFR app
// is released for.
func screenPossible() bool {
	arch := machine.arch()
	return askTerminal() && machine.supported() && (arch == "amd64" || arch == "arm64")
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
		return errors.New("`cyfr screen` runs at a terminal on Ubuntu 26.04 LTS on amd64 or arm64, as your own account")
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
	sum, err := screenAppSum(ctx)
	if err != nil {
		return err
	}
	commands := screenCommands(dir, account, sum)
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
	// Nothing is downloaded or written before the yes. The package is
	// fetched before sudo asks, so a slow download outlasts no login, and
	// removed as the command ends; the files the commands install are
	// written once sudo has the login, so a refusal leaves the project as
	// it was.
	if sum != "" {
		app, err := screenFetchApp(ctx, out, sum)
		defer app.remove()
		if err != nil {
			return err
		}
	}
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

// screenAppSum is the sha256 the signed checksums of this cyfr's release
// name for the CYFR app's package for this machine, read before anything is
// asked, downloaded or written, or "" where the machine holds the app of
// this release already (machine.appRelease). A development build, with no
// release to read, is refused.
func screenAppSum(ctx context.Context) (string, error) {
	if machine.appRelease() == version.Version {
		return "", nil
	}
	if !release.IsVersion(version.Version) {
		return "", fmt.Errorf("This cyfr is a development build (%s), so there is no release of the CYFR app to download for it, and this machine has none installed at it. Install the CYFR app's package built with this cyfr, then run `cyfr screen on` again", version.Version)
	}
	sum, err := appPackageSum(ctx, version.Version, machine.arch())
	if err != nil {
		return "", fmt.Errorf("The signed checksums of release %s could not be read for the CYFR app, so nothing was installed (%v). Run `cyfr screen on` again", version.Version, err)
	}
	return sum, nil
}

// fetchedApp is the CYFR app's package `cyfr screen on` fetched into
// screenAppFile, once the person said yes; the zero fetchedApp is none.
type fetchedApp struct {
	fetched bool
	// made are the folders the fetch made, removed with the file when the
	// command ends, so the project is left as it was unless the screen's
	// files were written into them since.
	made []string
}

// screenFetchApp downloads the CYFR app's package of this cyfr's release
// for this machine into screenAppFile, mode 0600, its bytes kept only once
// their sha256 is sum, the one screenAppSum read.
func screenFetchApp(ctx context.Context, out io.Writer, sum string) (fetchedApp, error) {
	app := fetchedApp{fetched: true}
	for _, d := range []string{filepath.Dir(screenDir), screenDir} {
		if !fileExists(d) {
			if err := os.Mkdir(d, 0o700); err != nil {
				return app, fmt.Errorf("cyfr screen could not make %s (%v)", d, err)
			}
			app.made = append([]string{d}, app.made...)
		}
	}
	fmt.Fprintf(out, "Downloading the CYFR app, release %s for %s, and checking it against the release's signed checksums.\n", version.Version, machine.arch())
	data, err := fetchAppPackage(ctx, version.Version, machine.arch(), sum)
	if err != nil {
		return app, fmt.Errorf("The CYFR app could not be downloaded, so nothing was installed (%v). Run `cyfr screen on` again", err)
	}
	if err := writeFileAtomic(screenAppFile, data, 0o600); err != nil {
		return app, fmt.Errorf("cyfr screen could not keep the CYFR app's package in %s (%v)", screenAppFile, err)
	}
	return app, nil
}

// remove removes the fetched package, and the folders the fetch made that
// nothing else was written into since.
func (a fetchedApp) remove() {
	if a.fetched {
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
// package changed after the fetch is never installed. That copy is
// stageApp's alone.
func screenCommands(dir, account, app string) []string {
	base := machine.installed("labwc") && machine.installed("wvkbd") && machine.installed("swayidle")
	var commands []string
	if !base || app != "" {
		commands = append(commands, "apt-get update")
	}
	if app != "" {
		commands = append(commands, stageApp(filepath.Join(dir, screenAppFile), app))
	}
	if !base {
		commands = append(commands, "apt-get install -y --no-install-recommends labwc wvkbd swayidle")
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

// stageApp is the one command that installs the CYFR app's package from
// the account's file at path, whose sha256 is sum: root's copy in a folder
// of its own, checked, handed to apt. The folder is that command's alone,
// a subshell whose exit removes it on every way out, the copy, the check
// or apt failing, an interrupt, or apt done, so nothing staged outlives
// it; it runs before anything of the screen is installed, so a failure
// leaves no part of the screen behind.
func stageApp(path, sum string) string {
	deb := "\"$d/" + appPackage + ".deb\""
	return "( trap 'rm -rf \"$d\"' EXIT && trap 'exit 1' INT TERM HUP && d=$(mktemp -d) && chmod 0755 \"$d\"" +
		" && install -m 0644 " + shellQuote([]string{path}) + " " + deb +
		" && echo '" + sum + "  '" + deb + " | sha256sum --check --strict --quiet" +
		" && apt-get install -y " + deb + " )"
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
	// Everything the screen begins for its CYFR ends as it returns, and as
	// its pages stop (shell.Server.ServeOn).
	work := shell.NewWork(ctx)
	defer work.End()
	local, err := readLocal(work, dir, "screen")
	if err != nil {
		return fmt.Errorf("The screen cannot read how CYFR is reached here (%v)", err)
	}
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer stop()
	// The compositor's own list of windows confirms each hide (screenApp).
	windows := wayland.ListWindows(ctx)
	defer windows.Close()
	hiding := func() func() error {
		return windows.Mark(screenHideWithin).Closed
	}
	var ln net.Listener
	browser, err := newScreenApp(in, out, local, hiding, func(why error) { endScreenApp(appProgram, ln, why) })
	if err != nil {
		return err
	}
	// A keyboard and a suspend watch a killed shell left, the watch
	// aimed at that shell's pid.
	_ = exec.Command("pkill", "-x", "wvkbd-mobintl").Run()
	_ = exec.Command("pkill", "-f", "--", "^swayidle -d -w -C /dev/null before-sleep kill -USR1 ").Run()
	host, _ := os.Hostname()
	ln, device, entry, err := screenClaim(listen, dir, local.Shell.Address)
	if err != nil {
		return err
	}
	// A watch lost locks, and the lock hides the page shown then, which
	// gives way to the one that says why (shell.Shell.Lock).
	watches := newScreenWatches(screenIdle, nil)
	cfg := local.Shell
	cfg.DisplayName, cfg.Restart = host, browser.hide
	// Read as each page is drawn: a `cyfr update` of the folder at the same
	// address leaves this shell running, and its next lock page says so.
	cfg.Warning = func() string { return releaseApart(dir, version.Version) }
	cfg.Record = filepath.Join(device, "holder.json")
	cfg.Clients = entry
	cfg.Unwatched = watches.Unwatched
	sh, err := shell.New(cfg)
	if err != nil {
		ln.Close()
		return err
	}
	// A folder naming another CYFR than the one this shell opened ends it:
	// the launcher starts it again on the reading made then.
	moved := make(chan error, 1)
	srv := &shell.Server{Shell: sh, Work: work, Reachable: func(ctx context.Context) error {
		err := local.Answers(ctx)
		var unbound *shell.Unbound
		if errors.As(err, &unbound) && unbound.Moved {
			select {
			case moved <- err:
			default:
			}
		}
		return err
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
	// The last lock hides as the screen's end, after which nothing shows,
	// and is confirmed or carried out before this returns.
	browser.finish(sh.Lock)
	return ended
}

// screenHideWithin is how long a hide has to be confirmed by the
// compositor (screenApp): a hide takes 6 to 727 ms from its cause on the
// screen step (tests/desktop-proof/screen/app.sh), and 2 s is that step's
// bound too.
const screenHideWithin = 2 * time.Second

// endScreenApp carries out a hide the compositor did not confirm, why
// saying what it said instead. Where this process's parent is program, the
// installed app, it closes the shell's listener, so the app's next start,
// whose cyfr takes it, finds it free, ends the app by the kernel
// (screenEndParent), and only then says why (screenSay): before, the
// saying could wait on the stuck app, the reader of this process's
// standard error. Its own lock goes on meanwhile: the proofs to CYFR,
// the channel's close and the key's erase hold the shell, which this
// process's end waits for; the app's end ends its pipe, and so the shell
// (runScreenShell). Where the parent is not the app, nothing is ended,
// and that is said.
func endScreenApp(program string, ln net.Listener, why error) {
	if err := screenEndParent(program, func() { ln.Close() }); err != nil {
		fmt.Fprintf(os.Stderr, "The lock's hide was not confirmed within %v (%v), and the CYFR app was not ended: %v.\n", screenHideWithin, why, err)
		return
	}
	screenSay(fmt.Sprintf("The lock's hide was not confirmed within %v (%v), so the CYFR app was ended from outside, and its launcher starts it again, locked.", screenHideWithin, why))
}

// releaseApart is what the screen's page says where the app's cyfr, which
// runs this shell (release ours), is another release than the one the
// folder's compose file is set to, read there and not from a container:
// `cyfr update` moves the folder and the program that ran it, never the
// app. The instruction is the one installPackage gives, which brings the
// app to the folder's release whether the cyfr on PATH is the package's
// own, whose `cyfr screen on` finds its own release installed, or one of
// its own. "" where they agree, or where either is no release.
func releaseApart(dir, ours string) string {
	set := folderRelease(dir)
	if !release.IsVersion(ours) || set == "" || set == ours {
		return ""
	}
	return fmt.Sprintf("This screen's CYFR app is release %s and the CYFR in %s is set to release %s, so the screen may not work as it should. To bring the app to release %s, %s.", ours, dir, set, set, installPackage(appPackage, set))
}

// folderRelease is the release the compose file in dir runs CYFR at
// (sharedRelease), "" without one.
func folderRelease(dir string) string {
	for _, name := range access.ComposeMainFiles {
		path := filepath.Join(dir, name)
		if !fileExists(path) {
			continue
		}
		return sharedRelease(func(yield func(string, string) bool) {
			for _, image := range imagesFromCompose(path, []string{buildsProfile, access.ModePublic, access.ModeTailnet}) {
				repository, tag, _ := splitImageReference(image)
				if !yield(repository, tag) {
					return
				}
			}
		})
	}
	return ""
}

// screenClaim takes the shell's listener, then selects the CYFR in dir, at
// home, in this account's list of CYFRs, which keeps the device's standing
// there: the list is shared with the CYFR app, so only the one process
// holding the listener writes it.
func screenClaim(listen func() (net.Listener, error), dir, home string) (net.Listener, string, *shell.Selection, error) {
	ln, err := listen()
	if err != nil {
		return nil, "", nil, fmt.Errorf("The screen cannot take %s, which another program holds (%v)", shell.Listen, err)
	}
	device, err := shell.DeviceDir()
	var entry *shell.Selection
	if err == nil {
		entry, err = shell.Homes(filepath.Join(device, "homes.json")).SelectLocal(home, dir)
	}
	if err == nil {
		err = entry.Commit("")
	}
	if err != nil {
		ln.Close()
		return nil, "", nil, fmt.Errorf("The screen cannot show the CYFR here: %v", err)
	}
	return ln, device, entry, nil
}

// sigUSR1 is Linux's SIGUSR1, named by number so this file builds where
// the screen never runs: the screen runs on Ubuntu alone.
const sigUSR1 = syscall.Signal(10)

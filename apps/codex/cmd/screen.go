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
	"sync"
	"syscall"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/shell"
	"github.com/spf13/cobra"
)

//go:embed screen
var screenFiles embed.FS

const (
	screenDir     = ".cyfr/screen"
	screenUnit    = "/etc/systemd/system/cyfr-screen.service"
	screenAptLine = "/etc/apt/apt.conf.d/52cyfr-screen"
	// screenPolicy is Chrome's managed policy on this machine: no password
	// saving or autofill, so a PIN or passphrase is never offered to
	// Google Password Manager, and no extensions.
	screenPolicy = "/etc/opt/chrome/policies/managed/cyfr-screen.json"
	chromeDeb    = "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
)

// screenPath is a project path the service's unit can hold as it is.
var screenPath = regexp.MustCompile(`^[A-Za-z0-9/._-]+$`)

var screenCmd = &cobra.Command{
	Use:   "screen",
	Short: "Show CYFR on this machine's own screen, or stop showing it",
	Long:  "Show CYFR full-screen on this machine's own screen at power-on, with no desktop, on Ubuntu 26.04 LTS on amd64. The screen sets CYFR up with your name and a PIN (a passphrase on a machine without a TPM chip): it makes your account, with this box its first device, and shows your recovery code, or adds the box to the account you have once a device of yours approves it; then it opens Prism. It locks after five minutes without input, whatever is playing on it, at a suspend and from its Lock, and unlocks with the PIN. It never starts or stops CYFR.",
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
	Short:  "Run this machine's screen: its pages, Chrome, keyboard and idle lock (the screen's service runs it)",
	Hidden: true,
	Args:   cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		return runScreenShell(cmd.Context(), shell.ListenLoopback)
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
	commands := screenCommands(dir, account)
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

// screenCommands are the commands `cyfr screen on` runs, the packages'
// only if needed.
func screenCommands(dir, account string) []string {
	base, chrome := machine.installed("labwc") && machine.installed("wvkbd") && machine.installed("swayidle"), machine.installed("google-chrome-stable")
	var commands []string
	if !base || !chrome {
		commands = append(commands, "apt-get update")
	}
	if !base {
		commands = append(commands, "apt-get install -y --no-install-recommends labwc wvkbd swayidle")
	}
	if !chrome {
		commands = append(commands,
			"deb=$(mktemp --suffix=.deb)",
			"echo 'Downloading Chrome from Google (about 110 MB)'",
			"curl -fL --progress-bar -o \"$deb\" "+chromeDeb,
			"apt-get install -y \"$deb\"",
			"rm -f \"$deb\"")
	}
	files := shellQuote([]string{filepath.Join(dir, screenDir)})
	return append(commands,
		// The TPM's resource manager is the tss group's: the screen's
		// account joins it, where there is one, to keep its PIN in the chip.
		"{ ! getent group tss >/dev/null || usermod -aG tss "+shellQuote([]string{account})+"; }",
		"install -m 0644 "+files+"/52cyfr-screen "+screenAptLine,
		"install -D -m 0644 "+files+"/cyfr-screen-policy.json "+screenPolicy,
		"install -m 0644 "+files+"/cyfr-screen.service "+screenUnit,
		"systemctl daemon-reload",
		"systemctl disable getty@tty1",
		"systemctl enable cyfr-screen")
}

// screenOffCommands give this machine's screen back to its login prompt,
// as root: `cyfr screen off` and `cyfr uninstall` run them.
var screenOffCommands = []string{
	"{ systemctl disable --now cyfr-screen || true; }",
	"rm -f " + screenUnit + " " + screenAptLine + " " + screenPolicy,
	"systemctl daemon-reload",
	"systemctl enable --now getty@tty1",
}

// screenOff leaves the packages, Chrome's profile and the project.
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

// followScreen rewrites the screen's files of the project in the working
// directory, when it has them, after a change of address: the shell reads
// the new head when the screen next starts.
func followScreen() error {
	if !fileExists(screenDir) {
		return nil
	}
	dir, account, err := screenSite()
	if err == nil {
		err = writeScreenFiles(dir, account)
	}
	if err != nil {
		return fmt.Errorf("cyfr could not rewrite this machine's screen files %s (%v). Run `cyfr screen on` to rewrite them", screenDir, err)
	}
	return nil
}

// writeScreenFiles renders the embedded files into the project, naming
// this program, the directory and the account: `cyfr screen on` and a
// change of address (cyfr access) rewrite them.
func writeScreenFiles(dir, account string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	if !screenPath.MatchString(self) {
		return fmt.Errorf("the cyfr program's path %q is not one of letters, digits and / . _ - alone", self)
	}
	fill := strings.NewReplacer("@CYFR@", self, "@DIR@", dir, "@ACCOUNT@", account)
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

// runScreenShell is the screen's session inside labwc: the shell's pages on
// loopback (listen takes their address), the on-screen keyboard, the
// watches that lock it (screenWatches) and Chrome on those pages. While
// those watches are not known to work it runs on locked, its page saying
// why.
// Chrome's exit locks and starts it again on the lock page; this process's
// own end (SIGTERM, SIGINT, SIGHUP) locks before it exits. Any lock ends
// the sessions at the home first, then starts Chrome again, so no page of
// the unlocked session outlives it.
func runScreenShell(ctx context.Context, listen func() (net.Listener, error)) error {
	_ = holder.HardenProcess()
	dir, err := os.Getwd()
	if err != nil {
		return err
	}
	local, err := readLocal(dir, "screen")
	if err != nil {
		return fmt.Errorf("The screen cannot read how CYFR is reached here (%v)", err)
	}
	chromeArgs := []string{"--no-first-run", "--no-default-browser-check", "--disable-extensions",
		"--ozone-platform=wayland", "--user-data-dir=" + filepath.Join(dir, screenDir, "chrome"), "--app=" + shell.Origin + "/"}

	if local.Proxy != "" {
		chromeArgs = append(chromeArgs, "--proxy-server="+local.Proxy, "--host-resolver-rules="+local.Resolver)
	} else {
		chromeArgs = append(chromeArgs, "--host-resolver-rules="+localhostIsIPv4)
	}

	ctx, stop := signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer stop()
	// A Chrome a killed shell left behind still shows its pages: it ends
	// before this shell starts its own, on the lock page.
	profile := "--user-data-dir=" + filepath.Join(dir, screenDir, "chrome")
	_ = exec.Command("pkill", "-f", "--", profile).Run()
	// So do a keyboard and a suspend watch a killed shell left, the watch
	// aimed at that shell's pid.
	_ = exec.Command("pkill", "-x", "wvkbd-mobintl").Run()
	_ = exec.Command("pkill", "-f", "--", "^swayidle -d -w -C /dev/null before-sleep kill -USR1 ").Run()
	chrome := &screenChrome{args: chromeArgs}
	host, _ := os.Hostname()
	ln, device, err := screenClaim(listen, dir)
	if err != nil {
		return err
	}
	// A page shown as the watches were lost gives way to the one that says so.
	watches := newScreenWatches(screenIdle, func(why string) {
		if why != "" {
			chrome.restart()
		}
	})
	cfg := local.Shell
	cfg.DisplayName, cfg.Restart = host, chrome.restart
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

	keyboard := screenChild(exec.Command("wvkbd-mobintl"))
	_ = keyboard.Start()
	defer func() {
		if keyboard.Process != nil {
			_ = keyboard.Process.Kill()
			_ = keyboard.Wait()
		}
	}()

	watches.lock = sh.Lock
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

	browsing, stopBrowsing := context.WithCancel(ctx)
	defer stopBrowsing()
	browser := make(chan error, 1)
	go func() {
		for browsing.Err() == nil {
			if err := chrome.run(browsing); err != nil {
				browser <- err
				return
			}
			if browsing.Err() == nil && sh.InUse() {
				sh.Lock("Locked because the browser closed.")
			}
			select {
			case <-browsing.Done():
			case <-time.After(time.Second):
			}
		}
	}()

	var ended error
	select {
	case <-ctx.Done():
	case ended = <-served:
	case err := <-browser:
		ended = fmt.Errorf("Chrome did not start (%v)", err)
	case err := <-moved:
		ended = fmt.Errorf("The screen starts again on this folder's settings (%v)", err)
	}
	sh.Lock("")
	stopBrowsing()
	return ended
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

// screenChrome is the one Chrome the screen runs.
type screenChrome struct {
	args []string
	mu   sync.Mutex
	proc *os.Process
}

// run runs Chrome on the shell's pages until it exits or ctx ends.
func (c *screenChrome) run(ctx context.Context) error {
	cmd := screenChild(exec.CommandContext(ctx, "google-chrome-stable", c.args...))
	if err := cmd.Start(); err != nil {
		return err
	}
	c.mu.Lock()
	c.proc = cmd.Process
	c.mu.Unlock()
	_ = cmd.Wait()
	c.mu.Lock()
	c.proc = nil
	c.mu.Unlock()
	return nil
}

// restart ends Chrome, whose loop starts it again on the lock page.
func (c *screenChrome) restart() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.proc != nil {
		_ = c.proc.Signal(syscall.SIGTERM)
	}
}

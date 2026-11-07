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
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
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
	Long:  "Show CYFR full-screen on this machine's own screen at power-on, with no desktop, on Ubuntu 26.04 LTS on amd64. The screen sets CYFR up with your name and a PIN (a passphrase on a machine without a TPM chip): it makes your account, with this box its first device, and shows your recovery code, or adds the box to the account you have once a device of yours approves it; then it opens Prism. It locks after five minutes without use, at a suspend and from its Lock, and unlocks with the PIN. It never starts or stops CYFR.",
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
		return runScreenShell(cmd.Context())
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
	return answer == "1", nil
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
	if err := writeScreenFiles(dir, account); err != nil {
		return fmt.Errorf("cyfr screen could not write %s (%v)", screenDir, err)
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
	err = machine.apply(commands)
	machine.forget()
	if err != nil {
		return errors.New("Showing CYFR on this screen failed. Fix what is shown above, then run `cyfr screen on` again")
	}
	return nil
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

// screenOff leaves the packages, Chrome's profile and the project.
func screenOff(out io.Writer) error {
	if !askTerminal() || !machine.supported() {
		return errors.New("`cyfr screen` runs at a terminal on Ubuntu 26.04 LTS, as your own account")
	}
	commands := []string{
		"{ systemctl disable --now cyfr-screen || true; }",
		"rm -f " + screenUnit + " " + screenAptLine + " " + screenPolicy,
		"systemctl daemon-reload",
		"systemctl enable --now getty@tty1",
	}
	fmt.Fprintln(out, "These commands give this machine's screen back to its login prompt, as root:")
	for _, c := range commands {
		fmt.Fprintf(out, "  %s\n", c)
	}
	err := machine.apply(commands)
	machine.forget()
	if err != nil {
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
// locks: labwc reports the idle time from real input, which no page can
// fake.
const screenIdle = 5 * 60

// screenProxy is CYFR's SOCKS5 proxy on this machine's loopback, the one
// way this device reaches a tailnet address.
const screenProxy = "socks5://127.0.0.1:1055"

// screenShellConfig is the box's own screen's shell in dir, for the CYFR
// at address: the box's key and its client there, kept beside the
// screen's files.
func screenShellConfig(dir, address string, client *http.Client, host string, restart func()) shell.Config {
	return shell.Config{
		Address: address, Client: client, DisplayName: host,
		Record:    filepath.Join(dir, screenDir, "holder.json"),
		Clients:   shell.ClientFile(filepath.Join(dir, screenDir, "client.json")),
		Directory: directoryURL(),
		DataDir:   filepath.Join(dir, "data"),
		Tokens:    screenTokens,
		// .env keeps the setup token after setup: the box brings it only
		// while no one is set up.
		SetupOpen: screenSetupOpen,
		Restart:   restart,
	}
}

// runScreenShell is the screen's session inside labwc: the shell's pages on
// loopback, the on-screen keyboard, swayidle and Chrome on those pages.
// The idle watch and a suspend send this process SIGUSR1, which locks;
// Chrome's exit locks and starts it again on the lock page; this process's
// own end (SIGTERM, SIGINT, SIGHUP) locks before it exits. Any lock ends
// the sessions at the home first, then starts Chrome again, so no page of
// the unlocked session outlives it.
func runScreenShell(ctx context.Context) error {
	_ = holder.HardenProcess()
	dir, err := os.Getwd()
	if err != nil {
		return err
	}
	head, err := currentHead()
	if err != nil {
		return fmt.Errorf("The screen cannot read how CYFR is reached here (%v)", err)
	}
	address := access.Describe(head).Address
	client := &http.Client{}
	chromeArgs := []string{"--no-first-run", "--no-default-browser-check", "--disable-extensions",
		"--ozone-platform=wayland", "--user-data-dir=" + filepath.Join(dir, screenDir, "chrome"), "--app=" + shell.Origin + "/"}

	if head.Mode == access.ModeTailnet {
		proxy, _ := url.Parse(screenProxy)
		client.Transport = &http.Transport{Proxy: http.ProxyURL(proxy)}
		chromeArgs = append(chromeArgs, "--proxy-server="+screenProxy, "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1")
	}

	ctx, stop := signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer stop()
	// A Chrome a killed shell left behind still shows its pages: it ends
	// before this shell starts its own, on the lock page.
	profile := "--user-data-dir=" + filepath.Join(dir, screenDir, "chrome")
	_ = exec.Command("pkill", "-f", "--", profile).Run()
	// So do a keyboard and an idle watch a killed shell left, the watch
	// aimed at that shell's pid.
	_ = exec.Command("pkill", "-x", "wvkbd-mobintl").Run()
	_ = exec.Command("pkill", "-f", "--", "^swayidle -w timeout [0-9]+ kill -USR1 ").Run()
	chrome := &screenChrome{args: chromeArgs}
	host, _ := os.Hostname()
	sh, err := shell.New(screenShellConfig(dir, address, client, host, chrome.restart))
	if err != nil {
		return err
	}
	srv := &shell.Server{Shell: sh, Reachable: func() bool { return screenReachable(client, address) }}
	served := make(chan error, 1)
	go func() { served <- srv.Serve(ctx) }()

	keyboard := screenChild(exec.Command("wvkbd-mobintl"))
	_ = keyboard.Start()
	defer func() {
		if keyboard.Process != nil {
			_ = keyboard.Process.Kill()
			_ = keyboard.Wait()
		}
	}()

	idled := make(chan os.Signal, 1)
	signal.Notify(idled, sigUSR1)
	defer signal.Stop(idled)
	go func() {
		for range idled {
			sh.Lock("Locked after five minutes without use, or for a suspend.")
		}
	}()

	// The idle and suspend lock is swayidle's: a screen without it would
	// stay unlocked unwatched, so its failure to start, or its exit, locks
	// the screen and ends this shell, which the launcher starts again with
	// a new watcher, locked.
	lockNow := strconv.Itoa(os.Getpid())
	idle := screenChild(exec.Command("swayidle", "-w",
		"timeout", strconv.Itoa(screenIdle), "kill -USR1 "+lockNow,
		"before-sleep", "kill -USR1 "+lockNow))
	if err := idle.Start(); err != nil {
		sh.Lock("")
		return fmt.Errorf("The screen's idle lock (swayidle) did not start (%v)", err)
	}
	watching := make(chan error, 1)
	go func() { watching <- idle.Wait() }()
	defer func() { _ = idle.Process.Kill() }()

	browsing, stopBrowsing := context.WithCancel(ctx)
	defer stopBrowsing()
	browser := make(chan error, 1)
	go func() {
		for browsing.Err() == nil {
			if err := chrome.run(browsing); err != nil {
				browser <- err
				return
			}
			if browsing.Err() == nil && sh.Unlocked() {
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
	case err := <-watching:
		ended = fmt.Errorf("The screen's idle lock (swayidle) stopped (%v): the screen locked and starts again", err)
	case err := <-browser:
		ended = fmt.Errorf("Chrome did not start (%v)", err)
	}
	sh.Lock("")
	stopBrowsing()
	return ended
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

// screenSetupOpen is whether no one is set up on the CYFR in the working
// directory yet, as cyfr's log since its start says, read under the
// stack's lock as cyfr setup reads it (readSetUp). The lock is taken
// without waiting: held by a command changing the stack, or with a log
// that cannot be read, setup is taken as closed, so the door decides and
// the next unlock asks again.
func screenSetupOpen(ctx context.Context) bool {
	e, err := openEngine(".")
	if err != nil {
		return false
	}
	unlock, err := e.Lock("screen")
	if err != nil {
		return false
	}
	defer unlock()
	head, err := e.Head()
	if err != nil {
		return false
	}
	return readSetUp(ctx, e, head) == setUpNone
}

// screenTokens reads .env's setup token as the server reads it, each time
// a page needs it, so it never travels in an argument.
func screenTokens() string {
	values, err := access.ReadEnvValues(".env")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(values[setupTokenVar])
}

// screenReachable is whether the home answers now, within two seconds.
func screenReachable(client *http.Client, address string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address+"/", nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

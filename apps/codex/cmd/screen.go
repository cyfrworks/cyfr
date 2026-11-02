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
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/cyfr/codex/internal/access"
	"github.com/spf13/cobra"
)

//go:embed screen
var screenFiles embed.FS

const (
	screenDir     = ".cyfr/screen"
	screenUnit    = "/etc/systemd/system/cyfr-screen.service"
	screenAptLine = "/etc/apt/apt.conf.d/52cyfr-screen"
	chromeDeb     = "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
)

// screenPath is a project path the service's unit can hold as it is.
var screenPath = regexp.MustCompile(`^[A-Za-z0-9/._-]+$`)

var screenCmd = &cobra.Command{
	Use:   "screen",
	Short: "Show CYFR on this machine's own screen, or stop showing it",
	Long:  "Show CYFR full-screen on this machine's own screen at power-on, with no desktop, on Ubuntu 26.04 LTS on amd64. It opens the setup link, which goes to Prism once setup is done. It never starts or stops CYFR.",
}

var screenOnCmd = &cobra.Command{
	Use:   "on",
	Short: "Show CYFR on this machine's own screen; again, rewrite what shows it",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		if err := screenOn(cmd.Context(), true, cmd.OutOrStdout()); err != nil {
			return err
		}
		fmt.Fprintln(cmd.OutOrStdout(), "The screen starts at the next boot. Run `cyfr up`, then `sudo reboot`.")
		return nil
	},
}

var screenOffCmd = &cobra.Command{
	Use:   "off",
	Short: "Give this machine's screen back to its login prompt",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		return screenOff(cmd.OutOrStdout())
	},
}

func init() {
	screenCmd.AddCommand(screenOnCmd, screenOffCmd)
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
	head, err := currentHead()
	if err != nil {
		return err
	}
	if err := writeScreenFiles(head, dir, account); err != nil {
		return fmt.Errorf("cyfr screen could not write %s (%v)", screenDir, err)
	}
	commands := screenCommands(dir)
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
			return errors.New("Nothing was changed. Run `cyfr screen on` again when you want to continue")
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
func screenCommands(dir string) []string {
	base, chrome := machine.installed("labwc") && machine.installed("wvkbd"), machine.installed("google-chrome-stable")
	var commands []string
	if !base || !chrome {
		commands = append(commands, "apt-get update")
	}
	if !base {
		commands = append(commands, "apt-get install -y --no-install-recommends labwc wvkbd")
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
		"install -m 0644 "+files+"/52cyfr-screen "+screenAptLine,
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
		"rm -f " + screenUnit + " " + screenAptLine,
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
// directory, when it has them, for head, the one .env holds after a
// change, so the screen opens CYFR at its address with no `cyfr screen on`.
func followScreen(head access.Head) error {
	if !fileExists(screenDir) {
		return nil
	}
	dir, account, err := screenSite()
	if err == nil {
		err = writeScreenFiles(head, dir, account)
	}
	if err != nil {
		return fmt.Errorf("This machine's screen still opens the old address: cyfr could not rewrite %s (%v). Run `cyfr screen on` to rewrite it", screenDir, err)
	}
	return nil
}

// writeScreenFiles renders the embedded files into the project, at head's
// address: `cyfr screen on` and a change of address (cyfr access) rewrite
// them.
func writeScreenFiles(head access.Head, dir, account string) error {
	proxy := "set --"
	if head.Mode == access.ModeTailnet {
		proxy = `set -- --proxy-server=socks5://127.0.0.1:1055 "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"`
	}
	port := head.Port
	if port == 0 {
		port = 4000
	}
	fill := strings.NewReplacer("@PROXY@", proxy, "@ADDRESS@", access.Describe(head).Address,
		"@PORT@", strconv.Itoa(port), "@DIR@", dir, "@ACCOUNT@", account)
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

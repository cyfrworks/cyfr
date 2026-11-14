// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// dockerPackages are the packages cyfr init installs.
var dockerPackages = []string{"docker.io", "docker-compose-v2", "apparmor"}

// machine is how cyfr observes this machine and changes it. Tests stand
// in for all of it.
var machine = struct {
	// supported is Ubuntu 26.04, run by an account that is not root.
	supported func() bool
	// arch is this program's architecture.
	arch func() string
	// reachable is whether Docker answers this process.
	reachable func() bool
	// installed is whether dpkg holds the package installed.
	installed func(pkg string) bool
	// running is whether the Docker service runs.
	running func() bool
	// groups lists the groups of account, or of this process when account
	// is empty.
	groups func(account string) []string
	// displayManager is whether a display manager has the screen.
	displayManager func() bool
	// screenService is whether the cyfr-screen service is enabled, and
	// whether it runs.
	screenService func() (enabled, active bool)
	// system is the operating system this program runs on.
	system func() string
	// passwordless is whether sudo runs any command now without asking for
	// a password: a login it still keeps, or no entry that asks one.
	passwordless func() bool
	// authenticate is sudo's own password prompt on this terminal; it
	// runs no command.
	authenticate func() error
	// apply runs the commands as root through one sudo.
	apply func(commands []string) error
	// forget invalidates sudo's cached login.
	forget func()
}{
	supported: func() bool {
		raw, _ := os.ReadFile("/etc/os-release")
		lines := strings.Split(string(raw), "\n")
		return runtime.GOOS == "linux" && os.Geteuid() != 0 && slices.Contains(lines, "ID=ubuntu") && slices.Contains(lines, `VERSION_ID="26.04"`)
	},
	arch:      func() string { return runtime.GOARCH },
	reachable: dockerAnswers,
	installed: func(pkg string) bool {
		out, err := exec.Command("dpkg-query", "-W", "-f", "${db:Status-Status}", pkg).Output()
		return err == nil && string(out) == "installed"
	},
	running: func() bool { return exec.Command("systemctl", "is-active", "--quiet", "docker").Run() == nil },
	displayManager: func() bool {
		return exec.Command("systemctl", "is-active", "--quiet", "display-manager").Run() == nil
	},
	screenService: func() (bool, bool) {
		return exec.Command("systemctl", "is-enabled", "--quiet", "cyfr-screen").Run() == nil,
			exec.Command("systemctl", "is-active", "--quiet", "cyfr-screen").Run() == nil
	},
	groups: func(account string) []string {
		args := []string{"-nG"}
		if account != "" {
			args = append(args, account)
		}
		out, _ := exec.Command("id", args...).Output()
		return strings.Fields(string(out))
	},
	system: func() string { return runtime.GOOS },
	// sudo -n -v fails rather than ask, and passes without a password only
	// with the login cached or every entry of the account's NOPASSWD:
	// sudoers' verifypw at its default (all) in sudo's manual, and sudo-rs's
	// one rule, its manual's "sudo -v" sentence. A password any command
	// would ask is asked here first, after the sentence.
	passwordless: func() bool { return exec.Command("sudo", "-n", "-v").Run() == nil },
	authenticate: func() error {
		cmd := exec.Command("sudo", "-v")
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	},
	apply: func(commands []string) error {
		cmd := exec.Command("sudo", "sh", "-c", strings.Join(commands, " && "))
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	},
	forget: func() { _ = exec.Command("sudo", "-k").Run() },
}

// dockerGroup is the group that reaches Docker.
const dockerGroup = "docker"

// administrators are the groups whose members Ubuntu lets administer the
// machine through sudo.
var administrators = []string{"sudo", "admin"}

// mayAdminister refuses, before anything asks, runs or is written, an
// account outside Ubuntu's sudo and admin groups: it says what was checked
// and shows forThem as one sudo line for whoever administers the machine,
// again being the command to run once they have.
func mayAdminister(forThem []string, out io.Writer, again string) error {
	account, err := user.Current()
	if err != nil {
		return err
	}
	if slices.ContainsFunc(machine.groups(account.Username), func(g string) bool { return slices.Contains(administrators, g) }) {
		return nil
	}
	fmt.Fprintf(out, "Your account, %s, is not in the sudo or admin group, so CYFR does not run commands as root for it. Whoever administers this machine can run this for you:\n", account.Username)
	fmt.Fprintf(out, "  sudo sh -c %s\n", shellQuote([]string{strings.Join(forThem, " &&\n    ")}))
	return fmt.Errorf("Nothing was changed. Run `%s` again once they have", again)
}

// passwordRefused is sudo's own prompt refused: nothing has run.
type passwordRefused struct{ again string }

func (p passwordRefused) Error() string {
	return fmt.Sprintf("The password was not accepted, so nothing was changed. Run `%s` again to try again", p.again)
}

// unlockSudo is the password step after mayAdminister and any question,
// before root commands and before anything is written for them. CYFR
// never asks for, reads or keeps a password: when sudo will ask, the one
// sentence before its prompt says whose, and sudo asks on this terminal
// before any command runs (passwordRefused). The caller forgets sudo's
// login (machine.forget).
func unlockSudo(out io.Writer, again string) error {
	if machine.passwordless() {
		return nil
	}
	fmt.Fprintln(out, "Ubuntu will now ask for your password: the one you log in to this machine with. Nothing shows while you type.")
	if machine.authenticate() != nil {
		return passwordRefused{again}
	}
	return nil
}

// dockerAnswers asks Docker for its info. It runs before a project or an
// engine exists.
func dockerAnswers() bool { return exec.Command("docker", "info").Run() == nil }

// requirementCommands are the commands that give account what this machine
// lacks of Docker, each only if needed.
func requirementCommands(account string) []string {
	var commands []string
	missing := slices.DeleteFunc(slices.Clone(dockerPackages), machine.installed)
	if len(missing) > 0 {
		commands = append(commands, "apt-get update", "apt-get install -y --no-install-recommends "+strings.Join(missing, " "))
	}
	if !machine.running() {
		commands = append(commands, "systemctl enable --now docker")
	}
	if !slices.Contains(machine.groups(account), dockerGroup) {
		commands = append(commands, "usermod -aG docker "+account)
	}
	return commands
}

// prepareMachine is cyfr init's first step at a terminal when this
// account cannot reach Docker. On Ubuntu 26.04 it shows what is missing,
// asks, and installs it through one sudo (mayAdminister, unlockSudo); on macOS and Windows it
// waits for Docker Desktop (awaitDockerDesktop). It answers true when init
// ends here, the rest of it run in a process carrying the docker group or
// the installation declined, false when this process goes on to prepare
// the project. Running init again is the retry.
func prepareMachine(ctx context.Context, args []string, out, errOut io.Writer) (bool, error) {
	if !askTerminal() {
		return false, nil
	}
	if system := machine.system(); system == "darwin" || system == "windows" {
		if machine.reachable() {
			return false, nil
		}
		return awaitDockerDesktop(ctx, system, out)
	}
	if !machine.supported() || machine.reachable() {
		return false, nil
	}
	account, err := user.Current()
	if err != nil {
		return false, err
	}
	commands := requirementCommands(account.Username)
	if len(commands) > 0 {
		fmt.Fprintln(out, "CYFR needs Docker on this machine.")
		if err := mayAdminister(commands, out, "cyfr init"); err != nil {
			return false, err
		}
		fmt.Fprintln(out, "These commands install it, as root:")
		for _, c := range commands {
			fmt.Fprintf(out, "  %s\n", c)
		}
		answer, err := ask(ctx, bufio.NewReader(askInput), out, "Install these requirements? (yes/no)", "no")
		if err != nil {
			return false, interruption{errQuestionInterrupted}
		}
		if !strings.EqualFold(answer, "yes") && !strings.EqualFold(answer, "y") {
			fmt.Fprintln(out, "Nothing was installed. Run cyfr init again when you want to continue.")
			return true, nil
		}
		err = unlockSudo(out, "cyfr init")
		if err == nil && machine.apply(commands) != nil {
			err = errors.New("Installing the requirements failed. Fix what is shown above, then run `cyfr init` again")
		}
		machine.forget()
		if err != nil {
			return false, err
		}
		if machine.reachable() {
			return false, nil
		}
	}
	return continueWithGroup("init", args, account.Username, out, errOut)
}

// dockerDesktopPage is where Docker offers Docker Desktop's installer for
// macOS and Windows.
const dockerDesktopPage = "https://www.docker.com/products/docker-desktop/"

// dockerDesktop is where Docker Desktop is installed on system, and the
// folder of the docker program it carries. A test stands in for it.
var dockerDesktop = func(system string) (app, bin string) {
	if system == "darwin" {
		return "/Applications/Docker.app", "/Applications/Docker.app/Contents/Resources/bin"
	}
	app = filepath.Join(os.Getenv("ProgramFiles"), "Docker", "Docker")
	return app, filepath.Join(app, "resources", "bin")
}

// dockerDesktopPrompts are what the system asks while Docker Desktop
// installs: its prompt, not CYFR's.
var dockerDesktopPrompts = map[string]string{
	"darwin":  "While Docker Desktop installs, macOS asks for this Mac's login password or Touch ID.",
	"windows": `While Docker Desktop installs, Windows asks "Do you want to allow this app to make changes to your device?": answer Yes.`,
}

// dockerPoll is how often init asks whether Docker answers yet.
var dockerPoll = 2 * time.Second

// awaitDockerDesktop is init's first step on macOS and Windows while Docker
// does not answer. Without Docker Desktop it offers to open Docker's own
// installer page and says what the installer's prompt will be; declined,
// init ends having written nothing. Then it waits, writing nothing, until
// Docker answers, with Docker Desktop's own docker program on this
// process's PATH, since a terminal opened before the install lacks it; an
// interrupt ends init there.
func awaitDockerDesktop(ctx context.Context, system string, out io.Writer) (bool, error) {
	app, bin := dockerDesktop(system)
	if _, err := os.Stat(app); err != nil {
		fmt.Fprintln(out, "CYFR needs Docker Desktop on this machine.")
		answer, err := ask(ctx, bufio.NewReader(askInput), out, "Open Docker's installer page? (yes/no)", "yes")
		if err != nil {
			return false, interruption{errQuestionInterrupted}
		}
		if !strings.EqualFold(answer, "yes") && !strings.EqualFold(answer, "y") {
			fmt.Fprintln(out, "Nothing was opened or written. Install Docker Desktop, then run cyfr init again.")
			return true, nil
		}
		if err := launchBrowser(dockerDesktopPage); err != nil {
			fmt.Fprintf(out, "Could not open a browser here (%v). Open %s yourself.\n", err, dockerDesktopPage)
		}
		fmt.Fprintln(out, dockerDesktopPrompts[system])
	} else {
		fmt.Fprintln(out, "Docker Desktop is installed and does not answer yet: start it.")
	}
	fmt.Fprintln(out, "CYFR goes on when Docker answers. Nothing is written until then; Ctrl+C stops here.")
	if err := os.Setenv("PATH", os.Getenv("PATH")+string(os.PathListSeparator)+bin); err != nil {
		return false, err
	}
	tick := time.NewTicker(dockerPoll)
	defer tick.Stop()
	for !machine.reachable() {
		select {
		case <-ctx.Done():
			return false, interruption{errQuestionInterrupted}
		case <-tick.C:
		}
	}
	fmt.Fprintln(out, "Docker answers. Going on.")
	return false, nil
}

// upWithGroup is cyfr up's first step, in a terminal older than the
// account's docker group: the same cyfr up, through sg, so no person has to
// refresh the terminal. It answers true when that run did the work.
func upWithGroup(args []string, out, errOut io.Writer) (bool, error) {
	if !machine.supported() {
		return false, nil
	}
	account, err := user.Current()
	if err != nil {
		return false, err
	}
	return continueWithGroup("up", args, account.Username, out, errOut)
}

// sgProgram runs a command with a group the account's processes do not
// carry yet, without a password when /etc/group lists the account in it;
// tests stand in for it.
var sgProgram = "/usr/bin/sg"

// continueWithGroup runs cyfr subcommand again, with the flags the person
// gave, through sg with the docker group, keeping this process's terminal,
// environment and directory. It answers false, having run nothing, when
// /etc/group does not list the account in the group, and when this process
// already has it: sg would give it nothing, and its child would land here
// again.
func continueWithGroup(subcommand string, args []string, account string, out, errOut io.Writer) (bool, error) {
	if !slices.Contains(machine.groups(account), dockerGroup) || slices.Contains(machine.groups(""), dockerGroup) {
		return false, nil
	}
	self, err := os.Executable()
	if err != nil {
		return true, fmt.Errorf("cyfr %s could not find its own program to go on with the docker group (%v). Run `newgrp docker`, or log out and in again, then run `cyfr %s` again", subcommand, err, subcommand)
	}
	cmd := exec.Command(sgProgram, dockerGroup, "-c", shellQuote(append([]string{self, subcommand}, args...)))
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, out, errOut
	err = cmd.Run()
	var exit *exec.ExitError
	switch {
	case errors.As(err, &exit):
		return true, handedOver{exit.ExitCode()}
	case err != nil:
		return true, fmt.Errorf("cyfr %s could not go on with the docker group (%v). Run `newgrp docker`, or log out and in again, then run `cyfr %s` again", subcommand, err, subcommand)
	}
	return true, nil
}

// shellQuote joins argv as one command line for sh -c: each word in single
// quotes, a single quote within it closed, escaped and reopened, so sh
// reads every word back as it is.
func shellQuote(argv []string) string {
	words := make([]string, len(argv))
	for i, w := range argv {
		words[i] = "'" + strings.ReplaceAll(w, "'", `'\''`) + "'"
	}
	return strings.Join(words, " ")
}

// continuationArgs are the arguments of the run a continuation starts:
// each flag the person gave, as --name=value.
func continuationArgs(c *cobra.Command) []string {
	var args []string
	c.Flags().Visit(func(f *pflag.Flag) {
		args = append(args, "--"+f.Name+"="+f.Value.String())
	})
	return args
}

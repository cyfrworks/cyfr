// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// dockerPackages are the packages cyfr init installs.
var dockerPackages = []string{"docker.io", "docker-compose-v2", "apparmor"}

// machineSeams is how cyfr observes a machine and changes it.
type machineSeams struct {
	// supported is Ubuntu 26.04, run by an account that is not root.
	supported func() bool
	// arch is this program's architecture.
	arch func() string
	// reachable is whether Docker answers this process before ctx ends.
	reachable func(ctx context.Context) bool
	// refusal is what asking Docker's info showed where it does not
	// answer this process: the kind of refusal its stderr says and its
	// words (access.ReadDockerRefusal), or that there is no docker program
	// to ask.
	refusal func(ctx context.Context) (kind access.DockerRefusal, said string, absent bool)
	// dockerHere is whether the Docker this process reaches runs its
	// containers on this computer.
	dockerHere func(ctx context.Context) (bool, error)
	// appPresent is whether the CYFR app is installed here, whole or left
	// part way (installedAppPresent).
	appPresent func() bool
	// installed is whether dpkg holds the package installed.
	installed func(pkg string) bool
	// appRelease is the release of the CYFR app this machine holds, as the
	// app's own cyfr answers it within 10 s, on Linux only where dpkg holds
	// its package installed for this machine's architecture; "" where it
	// answers no version, and where it answers nothing.
	appRelease func() string
	// running is whether the Docker service runs.
	running func() bool
	// groups lists the groups of account, or of this process when account
	// is empty.
	groups func(ctx context.Context, account string) []string
	// displayManager is whether a display manager has the screen.
	displayManager func() bool
	// screenService is whether the cyfr-screen service is enabled, and
	// whether it runs (any state but inactive and failed); err is not nil
	// when systemctl gave no state for whether it runs (it could not run,
	// or ran past its bound), active then being no answer.
	screenService func() (enabled, active bool, err error)
	// system is the operating system this program runs on.
	system func() string
	// passwordless is whether sudo runs any command now without asking for
	// a password: a login it still keeps, or no entry that asks one.
	passwordless func() bool
	// terminal is whether this process has a terminal for sudo to ask at.
	terminal func() bool
	// authenticate is sudo's own password prompt on this terminal; it
	// runs no command.
	authenticate func() error
	// appArmor is whether the kernel enforces AppArmor profiles.
	appArmor func() bool
	// appArmorLoaded is whether the kernel holds the profile named name,
	// by its own list of loaded policy, and whether that list is visible
	// here: a container sees no host's.
	appArmorLoaded func(name string) (loaded, visible bool)
	// apply runs the commands as root through one sudo.
	apply func(commands []string) error
	// applyInput runs the commands as root through one sudo, input on
	// their stdin.
	applyInput func(commands []string, input []byte) error
	// forget invalidates sudo's cached login.
	forget func()
}

// machine is this machine, as cyfr observes and changes it. Tests stand
// in for all of it.
var machine = machineSeams{
	supported: func() bool {
		raw, _ := os.ReadFile("/etc/os-release")
		lines := strings.Split(string(raw), "\n")
		return runtime.GOOS == "linux" && os.Geteuid() != 0 && slices.Contains(lines, "ID=ubuntu") && slices.Contains(lines, `VERSION_ID="26.04"`)
	},
	arch:      func() string { return runtime.GOARCH },
	reachable: dockerAnswers,
	refusal: func(ctx context.Context) (access.DockerRefusal, string, bool) {
		_, err := askDocker(ctx, access.Call{Args: []string{"info"}})
		if errors.Is(err, exec.ErrNotFound) {
			return access.RefusalUnsaid, "", true
		}
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			return access.RefusalUnsaid, "", false
		}
		kind, said := access.ReadDockerRefusal(exit.Stderr)
		return kind, said, false
	},
	dockerHere: func(ctx context.Context) (bool, error) {
		return access.DockerIsHere(ctx, dockerProgram{})
	},
	appPresent: installedAppPresent,
	installed: func(pkg string) bool {
		out, err := exec.Command("dpkg-query", "-W", "-f", "${db:Status-Status}", pkg).Output()
		return err == nil && string(out) == "installed"
	},
	appRelease: func() string {
		if runtime.GOOS == "linux" {
			var out strings.Builder
			query := exec.Command("dpkg-query", "-W", "-f", "${db:Status-Status} ${Architecture}", appPackage)
			query.Stdout = &out
			if err := runWithin(10*time.Second, query); err != nil || out.String() != "installed "+runtime.GOARCH {
				return ""
			}
		}
		path, err := appCyfr()
		if err != nil {
			return ""
		}
		var said strings.Builder
		cmd := exec.Command(path, "--version")
		cmd.Env = append(os.Environ(), "CYFR_NO_UPDATE_CHECK=1")
		cmd.Stdout = &said
		err = runWithin(10*time.Second, cmd)
		first, _, _ := strings.Cut(said.String(), "\n")
		answered, ok := strings.CutPrefix(strings.TrimRight(first, "\r"), "cyfr version ")
		if err != nil || !ok || answered == "" {
			return ""
		}
		return answered
	},
	running: func() bool { return exec.Command("systemctl", "is-active", "--quiet", "docker").Run() == nil },
	displayManager: func() bool {
		return exec.Command("systemctl", "is-active", "--quiet", "display-manager").Run() == nil
	},
	screenService: func() (bool, bool, error) {
		enabled := runWithin(10*time.Second, exec.Command("systemctl", "is-enabled", "--quiet", "cyfr-screen")) == nil
		// systemctl is-active prints the unit's state whatever it is, an
		// absent unit's included; no state printed is no answer. Every
		// state but inactive and failed runs: activating is its launcher
		// between two starts of the app.
		var said strings.Builder
		query := exec.Command("systemctl", "is-active", "cyfr-screen")
		query.Stdout = &said
		err := runWithin(10*time.Second, query)
		state := strings.TrimSpace(said.String())
		if state == "" || errors.Is(err, errOverran) {
			if err == nil {
				err = errors.New("it printed no state")
			}
			return enabled, false, fmt.Errorf("systemctl is-active cyfr-screen gave no answer (%v)", err)
		}
		return enabled, state != "inactive" && state != "failed", nil
	},
	groups: func(ctx context.Context, account string) []string {
		args := []string{"-nG"}
		if account != "" {
			args = append(args, account)
		}
		out, _ := exec.CommandContext(ctx, "id", args...).Output()
		return strings.Fields(string(out))
	},
	system: func() string { return runtime.GOOS },
	// sudo -n -v fails rather than ask, and passes without a password only
	// with the login cached or every entry of the account's NOPASSWD:
	// sudoers' verifypw at its default (all) in sudo's manual, and sudo-rs's
	// one rule, its manual's "sudo -v" sentence. A password any command
	// would ask is asked here first, after the sentence.
	passwordless: func() bool { return exec.Command("sudo", "-n", "-v").Run() == nil },
	terminal: func() bool {
		f, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
		if err != nil {
			return false
		}
		f.Close()
		return true
	},
	appArmor: func() bool {
		raw, err := os.ReadFile("/sys/module/apparmor/parameters/enabled")
		return err == nil && strings.TrimSpace(string(raw)) == "Y"
	},
	appArmorLoaded: func(want string) (bool, bool) {
		entries, err := os.ReadDir(appArmorPolicies)
		if err != nil {
			return false, false
		}
		for _, e := range entries {
			name, err := os.ReadFile(filepath.Join(appArmorPolicies, e.Name(), "name"))
			if err == nil && strings.TrimSpace(string(name)) == want {
				return true, true
			}
		}
		return false, true
	},
	authenticate: func() error {
		cmd := exec.Command("sudo", "-v")
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	},
	apply: func(commands []string) error {
		cmd := asRoot(commands)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	},
	applyInput: func(commands []string, input []byte) error {
		cmd := asRoot(commands)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(input), os.Stdout, os.Stderr
		return cmd.Run()
	},
	forget: func() { _ = exec.Command("sudo", "-k").Run() },
}

// rootPath is the PATH the commands run as root find their programs by,
// set before anything runs: never the caller's, which sudo may keep and a
// project's entry may lead.
const rootPath = "/usr/sbin:/usr/bin:/sbin:/bin"

// asRoot is the one sudo that runs commands, joined by &&, as root: sudo
// is the person's own, found as every sudo cyfr runs is, by their PATH; it
// runs /bin/sh by its path, whose first act fixes PATH to rootPath.
func asRoot(commands []string) *exec.Cmd {
	return exec.Command("sudo", "/bin/sh", "-c", "PATH="+rootPath+"; export PATH; "+strings.Join(commands, " && "))
}

// dockerGroup is the group that reaches Docker.
const dockerGroup = "docker"

// administrators are the groups whose members Ubuntu lets administer the
// machine through sudo.
var administrators = []string{"sudo", "admin"}

// administrator is this account's name and whether it is in Ubuntu's sudo
// or admin group.
func administrator() (string, bool, error) {
	account, err := user.Current()
	if err != nil {
		return "", false, err
	}
	return account.Username, slices.ContainsFunc(machine.groups(context.Background(), account.Username), func(g string) bool { return slices.Contains(administrators, g) }), nil
}

// mayAdminister refuses, before anything asks, runs or is written, an
// account outside Ubuntu's sudo and admin groups: it says what was checked
// and shows forThem as one sudo line for whoever administers the machine,
// again being the command to run once they have.
func mayAdminister(forThem []string, out io.Writer, again string) error {
	account, administers, err := administrator()
	if err != nil || administers {
		return err
	}
	fmt.Fprintf(out, "Your account, %s, is not in the sudo or admin group, so CYFR does not run commands as root for it. Whoever administers this machine can run this for you:\n", account)
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
// sentence before its prompt says whose, naming Ubuntu only where it is
// Ubuntu 26.04, and sudo asks on this terminal before any command runs
// (passwordRefused). With no terminal for sudo to ask at, nothing is
// announced and the step refuses at once. The caller forgets sudo's
// login (machine.forget).
func unlockSudo(out io.Writer, again string) error {
	if machine.passwordless() {
		return nil
	}
	if !machine.terminal() {
		return sudoNeedsATerminal(again)
	}
	if machine.supported() {
		fmt.Fprintln(out, "Ubuntu will now ask for your password: the one you log in to this machine with. Nothing shows while you type.")
	} else {
		fmt.Fprintln(out, "This machine will now ask for your password: the one you log in to it with. Nothing shows while you type.")
	}
	if machine.authenticate() != nil {
		return passwordRefused{again}
	}
	return nil
}

// sudoNeedsATerminal is the refusal where sudo would ask for a password
// and there is no terminal for it to ask at.
func sudoNeedsATerminal(again string) error {
	return fmt.Errorf("sudo needs your password and there is no terminal for it to ask at, so nothing was changed. Run `%s` at a terminal", again)
}

// dockerProgram is askDocker as an access.Docker.
type dockerProgram struct{}

func (dockerProgram) Run(ctx context.Context, c access.Call) (access.Result, error) {
	return askDocker(ctx, c)
}

// askDocker runs docker as it is, for what is asked of Docker before a
// project, and so an engine, exists: whether it answers and where it runs
// containers. It changes nothing. ctx's end ends docker.
func askDocker(ctx context.Context, c access.Call) (access.Result, error) {
	if c.Deadline > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, c.Deadline)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, "docker", c.Args...)
	cmd.WaitDelay = dockerWaitDelay
	out, err := cmd.Output()
	res := access.Result{Stdout: out}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		res.ExitCode = exit.ExitCode()
	}
	return res, err
}

// dockerWaitDelay bounds how long an interrupted docker's output may take
// to drain.
const dockerWaitDelay = 10 * time.Second

// dockerAnswers asks Docker for its info. It runs before a project or an
// engine exists.
func dockerAnswers(ctx context.Context) bool {
	_, err := askDocker(ctx, access.Call{Args: []string{"info"}})
	return err == nil
}

// requirementCommands are the commands that give account what this machine
// lacks of Docker, each only if needed.
func requirementCommands(account string) []string {
	var commands []string
	missing := slices.DeleteFunc(slices.Clone(dockerPackages), func(pkg string) bool { return machine.installed(pkg) })
	if len(missing) > 0 {
		commands = append(commands, "apt-get update", "apt-get install -y --no-install-recommends "+strings.Join(missing, " "))
	}
	if !machine.running() {
		commands = append(commands, "systemctl enable --now docker")
	}
	if !slices.Contains(machine.groups(context.Background(), account), dockerGroup) {
		commands = append(commands, "usermod -aG docker "+account)
	}
	return commands
}

// prepareMachine is cyfr init's first step. Where only a new login gives
// this process the docker group (loginIsMissing) it says so and ends init,
// at a terminal or not. Otherwise, at a terminal when this account cannot
// reach Docker: on Ubuntu 26.04 it shows what is missing,
// asks, and installs it through one sudo (mayAdminister, unlockSudo); on macOS and Windows it
// waits for Docker Desktop (awaitDockerDesktop). It answers true when init
// ends here, the rest of it run in a process carrying the docker group or
// the installation declined, false when this process goes on to prepare
// the project. Running init again is the retry.
func prepareMachine(ctx context.Context, args []string, out, errOut io.Writer) (bool, error) {
	// Only a new login cures this, with a terminal or without, so it is
	// said before anything is installed or written.
	if loginIsMissing(ctx) {
		return true, fmt.Errorf("%s. Then run `%s` again", loginAgain, commandSaid(append([]string{"init"}, args...)))
	}
	if !askTerminal() {
		return false, nil
	}
	if system := machine.system(); system == "darwin" || system == "windows" {
		if machine.reachable(ctx) {
			return false, nil
		}
		return awaitDockerDesktop(ctx, system, out)
	}
	if !machine.supported() || machine.reachable(ctx) {
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
		if machine.reachable(ctx) {
			return false, nil
		}
	}
	return continueWithGroup(ctx, append([]string{"init"}, args...), account.Username, out, errOut)
}

// dockerDesktopPage is where Docker offers Docker Desktop's installer for
// macOS and Windows.
const dockerDesktopPage = "https://www.docker.com/products/docker-desktop/"

// dockerEnginePage is Docker's own page on installing it on Linux.
const dockerEnginePage = "https://docs.docker.com/engine/install/"

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
	for !machine.reachable(ctx) {
		select {
		case <-ctx.Done():
			return false, interruption{errQuestionInterrupted}
		case <-tick.C:
		}
	}
	fmt.Fprintln(out, "Docker answers. Going on.")
	return false, nil
}

// dockerAnnotation marks a command that reaches Docker, and with it each
// command under it: the root's one step (withDockerGroup) runs before it.
const dockerAnnotation = "cyfr.docker"

// needsDocker is whether c or a command above it carries dockerAnnotation.
func needsDocker(c *cobra.Command) bool {
	for ; c != nil; c = c.Parent() {
		if c.Annotations[dockerAnnotation] != "" {
			return true
		}
	}
	return false
}

// withDockerGroup is the first step of every command that reaches Docker
// (needsDocker), in a terminal older than the account's docker group: the
// command again, as it was given, through sg, so no person has to refresh
// the terminal and every step of its run reaches Docker. It asks Docker
// nothing unless this process lacks the group /etc/group gives its
// account (staleGroup, two reads of id), so a terminal that holds the
// group, or an account outside it, pays no Docker call; only then does it
// ask whether Docker answers this process all the same, a rootless Docker
// included, within groupProbe. It answers true when the second run did the
// work; with no sg to run it with it says to log in again
// (continueWithGroup). A ctx that ends in the step ends the command: an
// interruption, never carried into its run.
func withDockerGroup(ctx context.Context, c *cobra.Command, args []string, out, errOut io.Writer) (bool, error) {
	if !machine.supported() {
		return false, nil
	}
	account, err := user.Current()
	if err != nil {
		return false, err
	}
	if !staleGroup(ctx, account.Username) {
		return false, stepInterrupted(ctx)
	}
	probe, stop := context.WithTimeout(ctx, groupProbe)
	answers := machine.reachable(probe)
	stop()
	if err := stepInterrupted(ctx); err != nil || answers {
		return false, err
	}
	argv := append(strings.Fields(strings.TrimPrefix(c.CommandPath(), c.Root().Name()+" ")), continuationArgs(c)...)
	if slices.ContainsFunc(args, func(a string) bool { return strings.HasPrefix(a, "-") }) {
		argv = append(argv, "--")
	}
	argv = append(argv, args...)
	return continueWithGroup(ctx, argv, account.Username, out, errOut)
}

// groupProbe bounds the one question the group step asks Docker.
var groupProbe = 10 * time.Second

// stepInterrupted is the interruption of a step whose ctx ended, none
// while it runs.
func stepInterrupted(ctx context.Context) error {
	if ctx.Err() != nil {
		return interruption{errQuestionInterrupted}
	}
	return nil
}

// loginAgain is said where only a new login gives this account the docker
// group: there is no sg, which is also newgrp, both of them an optional
// package's on Ubuntu 26.04.
const loginAgain = "Docker does not answer this account until you log out and in again"

// dockerSeen is what asking Docker showed this process: all the Docker
// sentence is written from (dockerSentence).
type dockerSeen struct {
	// cancelled is the asking ended before Docker was heard.
	cancelled bool
	// hereErr is where Docker runs its containers left unread; here is
	// that its endpoint is this computer's own socket or pipe.
	hereErr error
	here    bool
	answers bool
	// absent is there being no docker program to ask; refusal and said
	// what docker's stderr said where it did not answer.
	absent  bool
	refusal access.DockerRefusal
	said    string
	// stale is the account's docker group being newer than this process,
	// which has no way into it but a new login.
	stale bool
}

// seeDocker asks Docker where it runs its containers, whether it answers
// this process, and where it does not, what it said; stale is the
// membership the caller observed.
func seeDocker(ctx context.Context, stale bool) dockerSeen {
	s := dockerSeen{stale: stale}
	s.here, s.hereErr = machine.dockerHere(ctx)
	if s.hereErr == nil && s.here {
		s.answers = machine.reachable(ctx)
	}
	if !s.answers && (s.hereErr != nil || s.here) {
		s.refusal, s.said, s.absent = machine.refusal(ctx)
	}
	s.cancelled = ctx.Err() != nil
	return s
}

// dockerSentence is the one sentence of why Docker does not answer this
// account, none where it does, and whether installing or starting Docker
// here, or giving the account its group, is what is missing
// (dockerRemedy). It names a cause only where s saw it: a new login only
// for this computer's own socket refusing a process older than the
// account's group, the daemon's own error in its words.
func dockerSentence(s dockerSeen) (why string, fixable bool) {
	switch {
	case s.cancelled:
		return "Docker was not waited for", false
	case s.absent:
		return "Docker is not installed here", true
	case s.hereErr != nil:
		return "Docker did not say where it runs containers", true
	case !s.here:
		return "Docker here runs containers on another computer, so CYFR cannot be set up on this one with it", false
	case s.answers:
		return "", false
	case s.refusal == access.RefusalDenied && s.stale:
		return loginAgain, false
	case s.refusal == access.RefusalDaemon:
		return "Docker's daemon refused this account: " + s.said, false
	case s.refusal == access.RefusalUnsaid && s.said != "":
		return "Docker does not answer this account: " + s.said, false
	case s.said != "":
		return "Docker does not answer this account: " + s.said, true
	}
	return "Docker does not answer this account", true
}

// loginIsMissing is whether only a new login lets this process reach
// Docker: this computer's own Docker does not answer it, /etc/group lists
// its account in the docker group, the process is older than that, there
// is no sg to reach the group with, and Docker's socket refused this
// process when asked: a daemon's own refusal is no missing login.
func loginIsMissing(ctx context.Context) bool {
	if machine.system() != "linux" {
		return false
	}
	if _, err := os.Stat(sgProgram); err == nil {
		return false
	}
	account, err := user.Current()
	if err != nil || !staleGroup(ctx, account.Username) {
		return false
	}
	why, _ := dockerSentence(seeDocker(ctx, true))
	return why == loginAgain
}

// sgProgram runs a command with a group the account's processes do not
// carry yet, without a password when /etc/group lists the account in it;
// tests stand in for it.
var sgProgram = "/usr/bin/sg"

// staleGroup is whether /etc/group lists account in the docker group and
// this process lacks it, being older than that.
func staleGroup(ctx context.Context, account string) bool {
	return slices.Contains(machine.groups(ctx, account), dockerGroup) && !slices.Contains(machine.groups(ctx, ""), dockerGroup)
}

// continueWithGroup runs cyfr again with argv, the command's words and
// the flags and arguments the person gave, through sg with the docker
// group (groupRun), with this process's terminal and directory. It
// answers false, having run nothing, when /etc/group does not list the
// account in the group, and when this process already has it: sg would
// give it nothing, and its child would land here again. With no sg, or a
// program path sg's string cannot carry as it is (groupRun), it runs
// nothing and says why Docker does not answer: to log in again
// (loginAgain) only where its socket refused this process, naming the
// command to run again as the person gave it (commandSaid). A signal that
// ends this process's ctx (Main: SIGINT, SIGTERM, SIGHUP) is passed to the
// second run, so a stop from outside stops the work, and this process
// exits as the second run did: with its status, or with 128 and the number
// of the signal that killed it, as a shell reports one.
func continueWithGroup(ctx context.Context, argv []string, account string, out, errOut io.Writer) (bool, error) {
	if !staleGroup(ctx, account) {
		return false, nil
	}
	again := "Then run `" + commandSaid(argv) + "` again"
	self, err := os.Executable()
	if err != nil {
		return true, fmt.Errorf("cyfr could not find its own program to go on with the docker group (%v). Run `newgrp docker`, or log out and in again. %s", err, again)
	}
	cmd, err := groupRun(sgProgram, self, argv, os.Environ())
	if err != nil {
		why, _ := dockerSentence(seeDocker(ctx, true))
		if why == "" {
			return false, nil
		}
		return true, fmt.Errorf("%s. %s", why, again)
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, out, errOut
	if err := cmd.Start(); err != nil {
		return true, fmt.Errorf("cyfr could not go on with the docker group (%v). Run `newgrp docker`, or log out and in again. %s", err, again)
	}
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = cmd.Process.Signal(syscall.SIGTERM)
		case <-done:
		}
	}()
	err = cmd.Wait()
	close(done)
	var exit *exec.ExitError
	switch {
	case errors.As(err, &exit):
		if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			return true, handedOver{128 + int(status.Signal())}
		}
		return true, handedOver{exit.ExitCode()}
	case err != nil:
		return true, fmt.Errorf("cyfr could not go on with the docker group (%v). Run `newgrp docker`, or log out and in again. %s", err, again)
	}
	return true, nil
}

// groupWord is the one word sg's string carries after this program's
// path, and groupRunVar the variable the second run reads its arguments
// from: sg hands its string to the account's login shell, whatever that
// is (dash, bash, fish, tcsh), and no value of the person's travels where
// a shell reads it.
const (
	groupWord   = "--continue-with-docker-group"
	groupRunVar = "CYFR_DOCKER_GROUP_RUN"
)

// plainPath is the program path sg's string carries as it is: characters
// every shell reads alike, unquoted.
var plainPath = regexp.MustCompile(`^/[A-Za-z0-9/._+-]*$`)

// groupRun is self run again with argv through sg with the docker group,
// for continueWithGroup and setup's work alike, in environ: sg's string is
// `exec <self> --continue-with-docker-group`, and argv travels in
// groupRunVar, JSON in unpadded URL-safe base64, which no shell reads and
// no value breaks out of. A self outside plainPath is refused: the caller
// runs nothing through sg. sg is setuid, so glibc drops its unsafe
// variables (TMPDIR, LD_LIBRARY_PATH, TZDIR, LOCALDOMAIN and the rest)
// from the second run's environment, which keeps every other one: there
// os.TempDir is /tmp. The account's login shell runs its own startup files
// first.
func groupRun(sg, self string, argv, environ []string) (*exec.Cmd, error) {
	if !plainPath.MatchString(self) {
		return nil, fmt.Errorf("the program's path %q is not one sg's command line carries as it is", self)
	}
	if _, err := os.Stat(sg); err != nil {
		return nil, err
	}
	data, err := json.Marshal(argv)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(sg, dockerGroup, "-c", "exec "+self+" "+groupWord)
	cmd.Env = append(slices.DeleteFunc(slices.Clone(environ), func(e string) bool { return strings.HasPrefix(e, groupRunVar+"=") }),
		groupRunVar+"="+base64.RawURLEncoding.EncodeToString(data))
	return cmd, nil
}

// takeGroupRun is the command line of a second run groupRun started:
// args, this process's own, are groupWord alone, and the arguments are
// groupRunVar's. The variable is removed from the environment first,
// whatever the arguments, so nothing this process starts inherits it.
func takeGroupRun(args []string) ([]string, bool, error) {
	value, set := os.LookupEnv(groupRunVar)
	os.Unsetenv(groupRunVar)
	if len(args) != 1 || args[0] != groupWord {
		return nil, false, nil
	}
	if !set {
		return nil, true, errors.New("cyfr was asked to go on with the docker group, but was given no command to go on with")
	}
	data, err := base64.RawURLEncoding.DecodeString(value)
	var argv []string
	if err == nil {
		err = json.Unmarshal(data, &argv)
	}
	if err != nil {
		return nil, true, fmt.Errorf("cyfr was asked to go on with the docker group, but the command it was given is unreadable (%v)", err)
	}
	return argv, true, nil
}

// commandSaid is the command a person runs again: cyfr and argv, each
// word quoted for a shell where it needs it.
func commandSaid(argv []string) string {
	words := []string{"cyfr"}
	for _, w := range argv {
		if w == "" || !plainWord.MatchString(w) {
			w = shellQuote([]string{w})
		}
		words = append(words, w)
	}
	return strings.Join(words, " ")
}

// plainWord is a word a shell reads as it is.
var plainWord = regexp.MustCompile(`^[A-Za-z0-9@%+=:,./_-]+$`)

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
// each flag the person gave, as --name=value, or --name for a switch
// given on.
func continuationArgs(c *cobra.Command) []string {
	var args []string
	c.Flags().VisitAll(func(f *pflag.Flag) {
		if !f.Changed {
			return
		}
		if f.Value.Type() == "bool" && f.Value.String() == "true" {
			args = append(args, "--"+f.Name)
			return
		}
		args = append(args, "--"+f.Name+"="+f.Value.String())
	})
	return args
}

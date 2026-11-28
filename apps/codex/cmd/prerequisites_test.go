// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// sgStandIn records the sg cyfr init continues through and answers status:
// this test binary, run as sg (runStandIn).
func sgStandIn(t *testing.T, status string) string {
	t.Helper()
	sgProgram = filepath.Join(t.TempDir(), "sg")
	standInLink(t, sgProgram)
	record := filepath.Join(t.TempDir(), "sg")
	t.Setenv(fakeSgRecord, record)
	t.Setenv(fakeSgStatus, status)
	return record
}

func prepare(t *testing.T) (bool, string, error) {
	t.Helper()
	var out bytes.Buffer
	continued, err := prepareMachine(context.Background(), []string{"--no-pull"}, &out, &out)
	return continued, out.String(), err
}

// No terminal, another system, and a Docker this account reaches ask
// nothing and change nothing.
func TestInitLeavesAMachineAlone(t *testing.T) {
	for name, set := range map[string]func(s *standIn){
		"no terminal":    func(*standIn) { askTerminal = func() bool { return false } },
		"another system": func(s *standIn) { s.supported = false },
	} {
		t.Run(name, func(t *testing.T) {
			s := standInMachine(t)
			set(s)
			continued, out, err := prepare(t)
			if continued || err != nil || out != "" || s.applied != nil {
				t.Fatalf("continued %t, err %v, applied %v, out %q", continued, err, s.applied, out)
			}
		})
	}
}

// A fresh machine shows the plain commands, asks once, runs them all
// through one sudo, forgets the login and goes on through sg docker with
// the flags given.
func TestInitInstallsThroughOneSudoAndContinues(t *testing.T) {
	s := standInMachine(t)
	record := sgStandIn(t, "0")
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	continued, out, err := prepare(t)
	if !continued || err != nil {
		t.Fatalf("continued %t, err %v\n%s", continued, err, out)
	}
	want := []string{
		"apt-get update",
		"apt-get install -y --no-install-recommends docker.io docker-compose-v2 apparmor",
		"systemctl enable --now docker",
		"usermod -aG docker " + u.Username,
	}
	if len(s.applied) != 1 || !slices.Equal(s.applied[0], want) {
		t.Fatalf("applied %q, want one %q", s.applied, want)
	}
	if s.forgotten != 1 {
		t.Errorf("sudo's login was forgotten %d times", s.forgotten)
	}
	for _, c := range want {
		if !strings.Contains(out, "\n  "+c+"\n") {
			t.Errorf("the preview lacks %q:\n%s", c, out)
		}
	}
	if !strings.Contains(out, "Install these requirements? (yes/no)") {
		t.Errorf("output:\n%s", out)
	}
	if got := sgRan(t, record); !slices.Equal(got, []string{"init", "--no-pull"}) {
		t.Errorf("sg ran init again as %q", got)
	}
}

// sgRan is the second run the sg stand-in was handed, its command line as
// that run reads it (takeGroupRun): sg's string is this program's path and
// groupWord alone, and no value of the person's is in it.
func sgRan(t *testing.T, record string) []string {
	t.Helper()
	self, _ := os.Executable()
	sg, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(sg), "docker\n-c\nexec "+self+" "+groupWord+"\n"; got != want {
		t.Fatalf("sg was given %q, want %q", got, want)
	}
	run, err := os.ReadFile(record + ".run")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv(groupRunVar, string(run))
	argv, continued, err := takeGroupRun([]string{groupWord})
	if !continued || err != nil {
		t.Fatalf("the second run's command line is unreadable: %v", err)
	}
	return argv
}

// Only what is missing is run.
func TestInitRunsOnlyWhatIsMissing(t *testing.T) {
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		set  func(s *standIn)
		want []string
	}{
		"one package missing": {func(s *standIn) {
			s.installed, s.running, s.member = []string{"docker.io", "apparmor"}, true, []string{"docker"}
		}, []string{"apt-get update", "apt-get install -y --no-install-recommends docker-compose-v2"}},
		"the service stopped": {func(s *standIn) {
			s.installed, s.member = dockerPackages, []string{"docker"}
		}, []string{"systemctl enable --now docker"}},
		"the group": {func(s *standIn) {
			s.installed, s.running = dockerPackages, true
		}, []string{"usermod -aG docker " + u.Username}},
	} {
		t.Run(name, func(t *testing.T) {
			s := standInMachine(t)
			sgStandIn(t, "0")
			c.set(s)
			if _, out, err := prepare(t); err != nil || len(s.applied) != 1 || !slices.Equal(s.applied[0], c.want) {
				t.Fatalf("applied %q, want %q, err %v\n%s", s.applied, c.want, err, out)
			}
		})
	}
}

// A machine that has everything, in a terminal older than the group, asks
// nothing and goes on through sg.
func TestInitContinuesInATerminalOlderThanTheGroup(t *testing.T) {
	s := standInMachine(t)
	s.installed, s.running, s.member = dockerPackages, true, []string{"docker"}
	record := sgStandIn(t, "0")
	continued, _, err := prepare(t)
	if !continued || err != nil || s.applied != nil || s.forgotten != 0 {
		t.Fatalf("continued %t, err %v, applied %v, forgotten %d", continued, err, s.applied, s.forgotten)
	}
	if _, err := os.Stat(record); err != nil {
		t.Errorf("sg did not run: %v", err)
	}
}

// Installing and reaching Docker needs no continuation, and a process that
// has the group and still cannot reach Docker goes on as it is: a
// continuation would land here again, and again.
func TestInitNeedsNoContinuation(t *testing.T) {
	t.Run("Docker answers after the install", func(t *testing.T) {
		s := standInMachine(t)
		s.reachableAfter = true
		if continued, _, err := prepare(t); continued || err != nil || len(s.applied) != 1 {
			t.Fatalf("continued %t, err %v, applied %v", continued, err, s.applied)
		}
	})
	t.Run("the process has the group", func(t *testing.T) {
		s := standInMachine(t)
		s.installed, s.running, s.member, s.process = dockerPackages, true, []string{"docker"}, []string{"docker"}
		if continued, _, err := prepare(t); continued || err != nil || s.applied != nil {
			t.Fatalf("continued %t, err %v, applied %v", continued, err, s.applied)
		}
	})
}

// A daemon that stops right after a successful start leaves a process that
// has the group where it was, and sg would give it nothing: init goes on.
func TestInitDoesNotRepeatSgWithTheSameGroup(t *testing.T) {
	s := standInMachine(t)
	s.installed = dockerPackages
	s.member, s.process = []string{"docker"}, []string{"docker"}
	sgStandIn(t, "0")
	for attempt := 1; attempt <= 2; attempt++ {
		askInput = strings.NewReader("yes\n")
		continued, out, err := prepare(t)
		if err != nil {
			t.Fatalf("attempt %d: %v\n%s", attempt, err, out)
		}
		if continued {
			t.Errorf("attempt %d went through sg with the group it has; applied %q", attempt, s.applied)
		}
	}
}

// The real sudo program's calls, a fake standing in for it: whether it
// would ask a password for anything (-n -v, refused), then the sentence
// and its own prompt, then the commands, then sudo -k; a refused password
// runs no command and still forgets the login.
func TestInitRunsTheRealSudo(t *testing.T) {
	production := realMachine
	for name, c := range map[string]struct {
		verdict, err string
		ran          bool
	}{
		"accepted, the install failing": {"0", "Installing the requirements failed. Fix what is shown above, then run `cyfr init` again", true},
		"refused":                       {"1", "The password was not accepted, so nothing was changed. Run `cyfr init` again to try again", false},
	} {
		t.Run(name, func(t *testing.T) {
			standInMachine(t)
			machine.passwordless, machine.authenticate = production.passwordless, production.authenticate
			machine.apply, machine.forget = production.apply, production.forget
			record := fakeSudo(t, c.verdict)
			continued, out, err := prepare(t)
			if continued || err == nil || err.Error() != c.err {
				t.Fatalf("continued = %t, err = %v", continued, err)
			}
			if !strings.HasSuffix(out, "Install these requirements? (yes/no) [no]: "+passwordSentence) {
				t.Errorf("no sentence before sudo's prompt:\n%s", out)
			}
			got, err := os.ReadFile(record)
			if err != nil {
				t.Fatal(err)
			}
			want := []string{"-n -v", "-v"}
			if c.ran {
				want = append(want, "/bin/sh -c PATH="+rootPath+"; export PATH; apt-get update && apt-get install -y --no-install-recommends docker.io docker-compose-v2 apparmor && systemctl enable --now docker && usermod -aG docker "+currentAccount(t))
			}
			want = append(want, "-k")
			if lines := strings.Split(strings.TrimSuffix(string(got), "\n"), "\n"); !slices.Equal(lines, want) {
				t.Fatalf("sudo ran %q, want %q", lines, want)
			}
		})
	}
}

// The one sentence comes right after the answer and right before sudo's
// own prompt, for Ubuntu's sudo group and its older admin group alike.
func TestInitSaysWhosePasswordBeforeSudoAsks(t *testing.T) {
	for _, group := range administrators {
		t.Run(group, func(t *testing.T) {
			s := standInMachine(t)
			s.administrator = []string{group}
			sgStandIn(t, "0")
			var out bytes.Buffer
			s.prompt = func() { out.WriteString("[sudo's prompt]\n") }
			if _, err := prepareMachine(context.Background(), nil, &out, &out); err != nil {
				t.Fatalf("%v\n%s", err, out.String())
			}
			if !strings.Contains(out.String(), "Install these requirements? (yes/no) [no]: "+passwordSentence+"[sudo's prompt]\n") {
				t.Errorf("the sentence is not right before sudo's prompt:\n%s", out.String())
			}
			if strings.Count(out.String(), passwordSentence) != 1 || s.authenticated != 1 || len(s.applied) != 1 || s.forgotten != 1 {
				t.Errorf("authenticated %d, applied %q, forgotten %d:\n%s", s.authenticated, s.applied, s.forgotten, out.String())
			}
		})
	}
}

// A sudo that will not ask (a rule that asks no password, or a login it
// still keeps) gets no sentence and no prompt of its own.
func TestInitSaysNothingWhenSudoWillNotAsk(t *testing.T) {
	s := standInMachine(t)
	s.passwordless = true
	sgStandIn(t, "0")
	_, out, err := prepare(t)
	if err != nil || strings.Contains(out, "password") || s.authenticated != 0 || len(s.applied) != 1 {
		t.Fatalf("err %v, authenticated %d, applied %q:\n%s", err, s.authenticated, s.applied, out)
	}
}

// emptyDir fails the test unless the working directory holds nothing.
func emptyDir(t *testing.T) {
	t.Helper()
	entries, err := os.ReadDir(".")
	if err != nil || len(entries) != 0 {
		t.Errorf("init wrote %v (%v)", entries, err)
	}
}

// A refused password runs no command, says so with the retry, and init
// writes nothing.
func TestInitRefusedPasswordChangesNothing(t *testing.T) {
	s := standInMachine(t)
	s.authErr = errors.New("exit status 1")
	t.Chdir(t.TempDir())
	var out bytes.Buffer
	err := runInit(context.Background(), initOptions{}, &out, &out)
	if err == nil || err.Error() != "The password was not accepted, so nothing was changed. Run `cyfr init` again to try again" {
		t.Fatalf("err = %v\n%s", err, out.String())
	}
	if !strings.HasSuffix(out.String(), passwordSentence) || s.authenticated != 1 || s.applied != nil || s.forgotten != 1 {
		t.Errorf("authenticated %d, applied %q, forgotten %d:\n%s", s.authenticated, s.applied, s.forgotten, out.String())
	}
	emptyDir(t)
}

// An account outside Ubuntu's sudo and admin groups is told so before
// anything is asked, with the commands as one sudo line for whoever
// administers the machine; nothing runs and init writes nothing.
func TestInitTellsAnAccountOutsideTheSudoGroups(t *testing.T) {
	s := standInMachine(t)
	s.administrator = nil
	s.member = []string{"users"}
	account := currentAccount(t)
	t.Chdir(t.TempDir())
	var out bytes.Buffer
	err := runInit(context.Background(), initOptions{}, &out, &out)
	if err == nil || err.Error() != "Nothing was changed. Run `cyfr init` again once they have" {
		t.Fatalf("err = %v\n%s", err, out.String())
	}
	want := "CYFR needs Docker on this machine.\n" +
		"Your account, " + account + ", is not in the sudo or admin group, so CYFR does not run commands as root for it. Whoever administers this machine can run this for you:\n" +
		"  sudo sh -c " + shellQuote([]string{"apt-get update &&\n" +
		"    apt-get install -y --no-install-recommends docker.io docker-compose-v2 apparmor &&\n" +
		"    systemctl enable --now docker &&\n" +
		"    usermod -aG docker " + account}) + "\n"
	if out.String() != want {
		t.Errorf("init printed:\n%s\nwant:\n%s", out.String(), want)
	}
	if s.authenticated != 0 || s.applied != nil {
		t.Errorf("authenticated %d, applied %q", s.authenticated, s.applied)
	}
	emptyDir(t)
}

// desktopStandIn is macOS or Windows (system) at a terminal, its Docker
// answering after polls asks, Docker Desktop installed when installed, the
// browser standing in; opened records what it was asked to open.
func desktopStandIn(t *testing.T, system string, installed bool, polls int) (s *standIn, opened *[]string) {
	t.Helper()
	s = standInMachine(t)
	s.system = system
	app, bin := filepath.Join(t.TempDir(), "Docker"), filepath.Join(t.TempDir(), "bin")
	if installed {
		if err := os.Mkdir(app, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	asked := 0
	machine.reachable = func(context.Context) bool { asked++; return asked > polls }
	opened = new([]string)
	savedDesktop, savedPoll, savedLaunch := dockerDesktop, dockerPoll, launchBrowser
	t.Cleanup(func() { dockerDesktop, dockerPoll, launchBrowser = savedDesktop, savedPoll, savedLaunch })
	dockerDesktop = func(got string) (string, string) {
		if got != system {
			t.Errorf("Docker Desktop's place asked for %q", got)
		}
		return app, bin
	}
	dockerPoll = time.Millisecond
	launchBrowser = func(address string) error {
		*opened = append(*opened, address)
		if system == "windows" {
			return errors.New("no rundll32 to open it with")
		}
		return nil
	}
	t.Chdir(t.TempDir())
	return s, opened
}

const (
	dockerWaits  = "CYFR goes on when Docker answers. Nothing is written until then; Ctrl+C stops here.\n"
	dockerAnswer = "Docker answers. Going on.\n"
)

// On macOS and Windows without Docker Desktop, init offers to open Docker's
// own installer page, says what the system's prompt will be, and goes on
// once Docker answers, with Docker Desktop's docker on its PATH; it asks
// for no password and runs no sudo.
func TestInitOffersDockerDesktopsInstaller(t *testing.T) {
	for system, want := range map[string]string{
		"darwin": "While Docker Desktop installs, macOS asks for this Mac's login password or Touch ID.\n",
		"windows": "Could not open a browser here (no rundll32 to open it with). Open " + dockerDesktopPage + " yourself.\n" +
			`While Docker Desktop installs, Windows asks "Do you want to allow this app to make changes to your device?": answer Yes.` + "\n",
	} {
		t.Run(system, func(t *testing.T) {
			s, opened := desktopStandIn(t, system, false, 3)
			continued, out, err := prepare(t)
			if continued || err != nil {
				t.Fatalf("continued %t, err %v\n%s", continued, err, out)
			}
			if want := "CYFR needs Docker Desktop on this machine.\nOpen Docker's installer page? (yes/no) [yes]: " + want + dockerWaits + dockerAnswer; out != want {
				t.Errorf("init printed:\n%s\nwant:\n%s", out, want)
			}
			if !slices.Equal(*opened, []string{dockerDesktopPage}) {
				t.Errorf("opened %q", *opened)
			}
			_, bin := dockerDesktop(system)
			if !strings.HasSuffix(os.Getenv("PATH"), string(os.PathListSeparator)+bin) {
				t.Errorf("PATH lacks Docker Desktop's docker: %s", os.Getenv("PATH"))
			}
			if s.authenticated != 0 || s.applied != nil {
				t.Errorf("authenticated %d, applied %q", s.authenticated, s.applied)
			}
			emptyDir(t)
		})
	}
}

// Declined, init opens nothing, says the next step and writes nothing.
func TestInitDockerDesktopDeclined(t *testing.T) {
	_, opened := desktopStandIn(t, "darwin", false, 1<<30)
	askInput = strings.NewReader("no\n")
	var out bytes.Buffer
	if err := runInit(context.Background(), initOptions{}, &out, &out); err != nil {
		t.Fatalf("%v\n%s", err, out.String())
	}
	if want := "CYFR needs Docker Desktop on this machine.\nOpen Docker's installer page? (yes/no) [yes]: Nothing was opened or written. Install Docker Desktop, then run cyfr init again.\n"; out.String() != want {
		t.Errorf("init printed:\n%s\nwant:\n%s", out.String(), want)
	}
	if *opened != nil {
		t.Errorf("opened %q", *opened)
	}
	emptyDir(t)
}

// Docker Desktop installed and stopped asks nothing and opens nothing: init
// waits for it to start.
func TestInitWaitsForAnInstalledDockerDesktop(t *testing.T) {
	_, opened := desktopStandIn(t, "windows", true, 2)
	continued, out, err := prepare(t)
	if continued || err != nil {
		t.Fatalf("continued %t, err %v\n%s", continued, err, out)
	}
	if want := "Docker Desktop is installed and does not answer yet: start it.\n" + dockerWaits + dockerAnswer; out != want {
		t.Errorf("init printed:\n%s\nwant:\n%s", out, want)
	}
	if *opened != nil {
		t.Errorf("opened %q", *opened)
	}
}

// An interrupt while init waits for Docker ends it, having written nothing;
// a Docker that answers already is not waited for.
func TestInitDockerDesktopWaitEnds(t *testing.T) {
	t.Run("interrupted", func(t *testing.T) {
		desktopStandIn(t, "darwin", true, 1<<30)
		ctx, cancel := context.WithCancel(context.Background())
		asked := 0
		machine.reachable = func(context.Context) bool {
			if asked++; asked == 3 {
				cancel()
			}
			return false
		}
		var out bytes.Buffer
		err := runInit(ctx, initOptions{}, &out, &out)
		if !errors.Is(err, errQuestionInterrupted) {
			t.Fatalf("err = %v\n%s", err, out.String())
		}
		emptyDir(t)
	})
	t.Run("Docker answers", func(t *testing.T) {
		_, opened := desktopStandIn(t, "darwin", false, 0)
		if continued, out, err := prepare(t); continued || err != nil || out != "" || *opened != nil {
			t.Fatalf("continued %t, err %v, opened %q:\n%s", continued, err, *opened, out)
		}
	})
}

// Declining changes nothing, says so with the next step, and ends init as
// no failure.
func TestInitDeclined(t *testing.T) {
	s := standInMachine(t)
	askInput = strings.NewReader("no\n")
	ended, out, err := prepare(t)
	if !ended || err != nil || !strings.HasSuffix(out, "[no]: Nothing was installed. Run cyfr init again when you want to continue.\n") {
		t.Fatalf("ended %t, err = %v:\n%s", ended, err, out)
	}
	if s.applied != nil || s.forgotten != 0 {
		t.Errorf("applied %v, forgotten %d", s.applied, s.forgotten)
	}
}

// A failed install forgets the login and gives its one line; apt's own
// words are already on the terminal.
func TestInitInstallFails(t *testing.T) {
	s := standInMachine(t)
	s.applyErr = errors.New("exit status 100")
	continued, _, err := prepare(t)
	if continued || err == nil || err.Error() != "Installing the requirements failed. Fix what is shown above, then run `cyfr init` again" {
		t.Fatalf("continued %t, err %v", continued, err)
	}
	if s.forgotten != 1 {
		t.Errorf("sudo's login was forgotten %d times", s.forgotten)
	}
}

// Where there is no sg, which is also newgrp, as on Ubuntu 26.04 without
// util-linux-extra, init advises neither: where Docker's socket refused
// this process it says what gives the account the group, a new login. A
// daemon that is not there is no missing login: init says that instead.
func TestInitSaysLogInAgainWhereThereIsNoNewgrp(t *testing.T) {
	inGroup := func(s *standIn) { s.member = []string{dockerGroup} }
	for name, c := range map[string]struct {
		set func(*standIn)
		// stale is whether the account was in the docker group before
		// init: then nothing is installed, with a terminal or without.
		stale bool
	}{
		"installed before": {func(s *standIn) { inGroup(s); s.installed, s.running = dockerPackages, true }, true},
		"installed before, with no terminal": {func(s *standIn) {
			inGroup(s)
			s.installed, s.running = dockerPackages, true
			askTerminal = func() bool { return false }
		}, true},
		"in the group, Docker not installed": {inGroup, true},
		"in the group, with no terminal":     {func(s *standIn) { inGroup(s); askTerminal = func() bool { return false } }, true},
		"installed by init":                  {func(*standIn) {}, false},
		"added to its groups":                {func(s *standIn) { s.installed, s.running = dockerPackages, true }, false},
	} {
		for _, r := range []struct {
			name, refused string
			login         bool
		}{{"socket refused", socketDenied, true}, {"no daemon", noDaemon, false}} {
			t.Run(name+", "+r.name, func(t *testing.T) {
				s := standInMachine(t)
				s.refused = r.refused
				c.set(s)
				sgProgram = filepath.Join(t.TempDir(), "sg")
				t.Chdir(t.TempDir())
				continued, _, err := prepare(t)
				const want = "Docker does not answer this account until you log out and in again. Then run `cyfr init --no-pull` again"
				if !r.login && err != nil && strings.Contains(err.Error(), loginAgain) {
					t.Fatalf("with no daemon, init said %v", err)
				}
				if r.login && (!continued || err == nil || err.Error() != want) {
					t.Fatalf("continued %t, init said %v, want %q", continued, err, want)
				}
				if r.login && c.stale && (s.applied != nil || s.authenticated != 0) {
					t.Fatalf("init installed %v, asked sudo %d times, before it said so", s.applied, s.authenticated)
				}
				nothingWritten(t)
			})
		}
	}
}

// A Docker whose endpoint is another computer's is no missing login,
// though this process lacks the docker group its account is in: init does
// not say to log in again.
func TestInitSaysNoLoginForADockerElsewhere(t *testing.T) {
	s := standInMachine(t)
	s.member, s.installed, s.running = []string{dockerGroup}, dockerPackages, true
	machine.dockerHere = func(context.Context) (bool, error) { return false, nil }
	askTerminal = func() bool { return false }
	sgProgram = filepath.Join(t.TempDir(), "sg")
	t.Chdir(t.TempDir())
	if _, _, err := prepare(t); err != nil && strings.Contains(err.Error(), loginAgain) {
		t.Fatalf("init said %v", err)
	}
}

// A continued init's status is init's.
func TestInitAnswersTheContinuationsStatus(t *testing.T) {
	s := standInMachine(t)
	s.installed, s.running, s.member = dockerPackages, true, []string{"docker"}
	sgStandIn(t, "7")
	if _, _, err := prepare(t); ExitStatus(err) != 7 {
		t.Fatalf("err = %v, status %d", err, ExitStatus(err))
	}
}

// dockerCommands are the command lines of every command that reaches
// Docker, each as a person may give it, and the second run's.
var dockerCommands = []struct{ args, again []string }{
	{[]string{"up"}, []string{"up"}},
	{[]string{"down"}, []string{"down"}},
	{[]string{"backup"}, []string{"backup"}},
	{[]string{"restore", "snapshot.tar.gz"}, []string{"restore", "snapshot.tar.gz"}},
	{[]string{"restore", "--no-start", "backups/my snap"}, []string{"restore", "--no-start", "backups/my snap"}},
	{[]string{"restore", "--", "-weird"}, []string{"restore", "--", "-weird"}},
	{[]string{"update", "--yes", "--version", "0.6.0-alpha.12"}, []string{"update", "--version=0.6.0-alpha.12", "--yes"}},
	{[]string{"uninstall"}, []string{"uninstall"}},
	{[]string{"access", "local", "--yes"}, []string{"access", "--yes", "local"}},
	{[]string{"access", "--resume"}, []string{"access", "--resume"}},
	{[]string{"access", "status"}, []string{"access", "status"}},
}

// runCommandLine runs the cyfr command line with args as a process of
// its own would, under t's context, and answers its error.
func runCommandLine(t *testing.T, args ...string) error {
	t.Helper()
	var forget func(c *cobra.Command)
	forget = func(c *cobra.Command) {
		c.SetContext(nil)
		c.Flags().Visit(func(f *pflag.Flag) { _ = f.Value.Set(f.DefValue); f.Changed = false })
		for _, sub := range c.Commands() {
			forget(sub)
		}
	}
	forget(rootCmd)
	t.Cleanup(func() { forget(rootCmd); rootCmd.SetArgs(nil) })
	rootCmd.SetArgs(args)
	return Execute(t.Context())
}

// Every command that reaches Docker, in a terminal older than the
// account's docker group, runs itself again through sg, as it was given,
// before anything else; that run's status is its.
func TestContinuesInATerminalOlderThanTheGroup(t *testing.T) {
	for _, c := range dockerCommands {
		for _, status := range []string{"0", "3"} {
			t.Run(strings.Join(c.args, " ")+", status "+status, func(t *testing.T) {
				s := standInMachine(t)
				s.member = []string{"docker"}
				record := sgStandIn(t, status)
				t.Chdir(t.TempDir())
				err := runCommandLine(t, c.args...)
				if got := strconv.Itoa(ExitStatus(err)); err != nil && got != status || err == nil && status != "0" {
					t.Fatalf("err %v, want the status %s", err, status)
				}
				if got := sgRan(t, record); !slices.Equal(got, c.again) {
					t.Errorf("sg ran %q, want %q", got, c.again)
				}
				nothingWritten(t)
			})
		}
	}
}

// Where there is no sg, every command that reaches Docker says, when
// Docker's socket refused this process, that a new login gives the
// account the group, naming the command as the person gave it, flags
// included and quoted where a shell needs it; and runs nothing.
func TestSaysLogInAgainForEachCommandWhereThereIsNoSg(t *testing.T) {
	for _, c := range dockerCommands {
		t.Run(strings.Join(c.args, " "), func(t *testing.T) {
			s := standInMachine(t)
			s.member, s.refused = []string{"docker"}, socketDenied
			sgProgram = filepath.Join(t.TempDir(), "sg")
			t.Chdir(t.TempDir())
			want := "Docker does not answer this account until you log out and in again. Then run `" + commandSaid(c.again) + "` again"
			if err := runCommandLine(t, c.args...); err == nil || err.Error() != want {
				t.Fatalf("err %v, want %q", err, want)
			}
			nothingWritten(t)
		})
	}
}

// The sentence names what changes the command: a person who runs it gets
// the command they gave.
func TestLogInSentenceNamesTheFlagsThatMatter(t *testing.T) {
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"update", "--version", "0.6.0-alpha.12"}, "`cyfr update --version=0.6.0-alpha.12`"},
		{[]string{"restore", "--no-start", "backups/2026"}, "`cyfr restore --no-start backups/2026`"},
		{[]string{"access", "--resume"}, "`cyfr access --resume`"},
		{[]string{"access", "tailnet", "--tailscale-auth-key-file", "key"}, "`cyfr access --tailscale-auth-key-file=key tailnet`"},
		{[]string{"restore", "backups/my snap"}, "`cyfr restore 'backups/my snap'`"},
	} {
		t.Run(strings.Join(c.args, " "), func(t *testing.T) {
			s := standInMachine(t)
			s.member, s.refused = []string{"docker"}, socketDenied
			sgProgram = filepath.Join(t.TempDir(), "sg")
			t.Chdir(t.TempDir())
			if err := runCommandLine(t, c.args...); err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("says %v, want it to name %s", err, c.want)
			}
		})
	}
}

// A program whose path sg's string cannot carry as it is goes through no
// sg: the person is told to log in again.
func TestAPathSgCannotCarryIsToldToLogInAgain(t *testing.T) {
	for _, self := range []string{"/home/ana/my bin/cyfr", "/home/ana/$x/cyfr", "/home/ana/cyfr;id", "relative/cyfr"} {
		if _, err := groupRun("/bin/true", self, []string{"down"}, nil); err == nil {
			t.Errorf("%q went through sg", self)
		}
	}
	if _, err := groupRun("/bin/true", "/home/ana/.local/bin/cyfr-0.6_1+x", []string{"down"}, nil); err != nil {
		t.Errorf("a plain path was refused: %v", err)
	}
}

// The second run reads its command line once and leaves no trace of it
// for anything it starts; an unreadable one is refused.
func TestTheSecondRunTakesItsCommandLineOnce(t *testing.T) {
	cmd, err := groupRun("/bin/true", "/opt/cyfr", []string{"restore", "it's $HOME `id` ;x\nnext"}, []string{groupRunVar + "=old", "KEEP=1"})
	if err != nil {
		t.Fatal(err)
	}
	var run string
	for _, e := range cmd.Env {
		if v, ok := strings.CutPrefix(e, groupRunVar+"="); ok {
			if run != "" {
				t.Fatal("two command lines in the environment")
			}
			run = v
		}
	}
	if !slices.Contains(cmd.Env, "KEEP=1") || strings.ContainsAny(run, "'\"$`;\n =") {
		t.Fatalf("environment %q", cmd.Env)
	}
	t.Setenv(groupRunVar, run)
	argv, continued, err := takeGroupRun([]string{groupWord})
	if err != nil || !continued || !slices.Equal(argv, []string{"restore", "it's $HOME `id` ;x\nnext"}) {
		t.Fatalf("read %q, %v, %v", argv, continued, err)
	}
	if _, left := os.LookupEnv(groupRunVar); left {
		t.Error("the command line is left in the environment")
	}
	t.Setenv(groupRunVar, "not base64!")
	if _, _, err := takeGroupRun([]string{groupWord}); err == nil {
		t.Error("an unreadable command line was taken")
	}
	t.Setenv(groupRunVar, run)
	if _, continued, _ := takeGroupRun([]string{"down"}); continued {
		t.Error("a run not started by groupRun took a command line")
	}
	if _, left := os.LookupEnv(groupRunVar); left {
		t.Error("a run not started by groupRun left the variable for what it starts")
	}
}

// The second run is the first's command, flags and arguments, byte for
// byte, as each login shell the account may have reads sg's string, and
// nothing else runs: dash and bash, and any other shell
// CYFR_TEST_LOGIN_SHELLS names (fish and tcsh, unpacked from Ubuntu's
// packages, ran it here).
func TestSecondRunIsTheSameCommandInEachLoginShell(t *testing.T) {
	shells := append([]string{"/usr/bin/dash", "/usr/bin/bash"}, strings.Fields(os.Getenv("CYFR_TEST_LOGIN_SHELLS"))...)
	for _, line := range [][]string{
		{"restore", "backups/my snap"},
		{"restore", "--no-start", "it's $HOME `id` ;x\nnext"},
		{"restore", "--", "-weird"},
		{"restore", ""},
		{"restore", "snap!1"},
		{"access", "public", "--domain", `ex'ample.com`, "--acme-email", `a"b$c`},
		{"access", "tailnet", "--hostname", "", "--tailscale-auth-key-file", "my keys/key"},
		{"access", "status", "--json"},
		{"update", "--version", "0.6.0-alpha.12"},
		{"backup", `--context=a\\b`},
		{"access", "public", "--acme-email", `a\`, "--domain", "; touch PWNED; #"},
	} {
		t.Run(strings.Join(line, " "), func(t *testing.T) {
			s := standInMachine(t)
			s.member = []string{"docker"}
			record := sgStandIn(t, "0")
			t.Chdir(t.TempDir())
			if err := runCommandLine(t, line...); err != nil && ExitStatus(err) != 0 {
				t.Fatalf("err %v", err)
			}
			sent, err := os.ReadFile(record)
			if err != nil {
				t.Fatal(err)
			}
			run, err := os.ReadFile(record + ".run")
			if err != nil {
				t.Fatal(err)
			}
			want := parsedLine(t, line)
			for _, shell := range shells {
				if _, err := os.Stat(shell); err != nil {
					t.Logf("%s: not here", shell)
					continue
				}
				dir := t.TempDir()
				cmd := exec.Command(shell, "-c", strings.TrimSuffix(strings.TrimPrefix(string(sent), "docker\n-c\n"), "\n"))
				cmd.Dir = dir
				cmd.Env = append(os.Environ(), groupRunVar+"="+string(run), fakeGroupDump+"=1")
				out, err := cmd.CombinedOutput()
				var got struct {
					Args  []string
					Error string
					Left  bool
				}
				if err != nil || json.Unmarshal(out, &got) != nil || got.Error != "<nil>" || got.Left {
					t.Errorf("%s ran %q: %v", filepath.Base(shell), out, err)
					continue
				}
				if entries, _ := os.ReadDir(dir); len(entries) > 0 {
					t.Errorf("%s: something else ran, and wrote %v", filepath.Base(shell), entries)
				}
				if again := parsedLine(t, got.Args); !reflect.DeepEqual(again, want) {
					t.Errorf("%s runs %q: %+v, want %+v", filepath.Base(shell), got.Args, again, want)
				}
			}
		})
	}
}

// parsedLine is a command line as cobra reads it: the command, every flag
// given and its value, and the arguments.
func parsedLine(t *testing.T, args []string) [3]any {
	t.Helper()
	c, rest, err := rootCmd.Find(args)
	if err != nil {
		t.Fatal(err)
	}
	c.Flags().VisitAll(func(f *pflag.Flag) { _ = f.Value.Set(f.DefValue); f.Changed = false })
	if err := c.ParseFlags(rest); err != nil {
		t.Fatal(err)
	}
	flags := map[string]string{}
	c.Flags().VisitAll(func(f *pflag.Flag) {
		if f.Changed {
			flags[f.Name] = f.Value.String()
		}
	})
	return [3]any{c.CommandPath(), flags, c.Flags().Args()}
}

// A command that does not reach Docker is not run again through sg.
func TestCommandsWithoutDockerAreNotContinued(t *testing.T) {
	for _, words := range [][]string{{"init"}, {"log"}, {"status"}, {"internal", "docker-run"}} {
		c, _, err := rootCmd.Find(words)
		if err != nil {
			t.Fatal(err)
		}
		if needsDocker(c) {
			t.Errorf("cyfr %s passes through the docker group step", strings.Join(words, " "))
		}
	}
}

// A command that reaches Docker carries on as it is when Docker already
// answers this account, a rootless Docker or a group the account holds
// already among them, and when sg has nothing to give it; it asks Docker
// nothing unless this process lacks the group its account has.
func TestNeedsNoContinuation(t *testing.T) {
	up, _, err := rootCmd.Find([]string{"up"})
	if err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		set   func(*standIn)
		asked int
	}{
		"Docker answers":     {func(s *standIn) { s.reachable = true }, 1},
		"another system":     {func(s *standIn) { s.supported = false }, 0},
		"not in the group":   {func(s *standIn) { s.member = nil }, 0},
		"the process has it": {func(s *standIn) { s.process = []string{"docker"} }, 0},
	} {
		t.Run(name, func(t *testing.T) {
			s := standInMachine(t)
			s.member = []string{"docker"}
			record := sgStandIn(t, "0")
			c.set(s)
			asked := 0
			reachable := machine.reachable
			machine.reachable = func(ctx context.Context) bool {
				asked++
				return reachable(ctx)
			}
			if continued, err := withDockerGroup(t.Context(), up, nil, &bytes.Buffer{}, &bytes.Buffer{}); continued || err != nil {
				t.Fatalf("continued %t, err %v", continued, err)
			}
			if asked != c.asked {
				t.Errorf("Docker was asked %d times, want %d", asked, c.asked)
			}
			if _, err := os.Stat(record); err == nil {
				t.Error("sg ran")
			}
		})
	}
}

// A Docker that never answers costs a command nothing outside a stale
// group, and within one no more than groupProbe before the second run.
func TestADockerThatNeverAnswersIsNotWaitedFor(t *testing.T) {
	never := func(ctx context.Context) bool {
		<-ctx.Done()
		return false
	}
	t.Run("the process holds the group", func(t *testing.T) {
		s := standInMachine(t)
		s.member, s.process = []string{"docker"}, []string{"docker"}
		machine.reachable = never
		t.Chdir(t.TempDir())
		start := time.Now()
		err := runCommandLine(t, "down")
		if took := time.Since(start); took > 2*time.Second || err == nil || !strings.Contains(err.Error(), "no compose file") {
			t.Fatalf("down answered %v after %s", err, took)
		}
	})
	t.Run("older than the group", func(t *testing.T) {
		s := standInMachine(t)
		s.member = []string{"docker"}
		record := sgStandIn(t, "0")
		machine.reachable = never
		saved := groupProbe
		t.Cleanup(func() { groupProbe = saved })
		groupProbe = 50 * time.Millisecond
		t.Chdir(t.TempDir())
		start := time.Now()
		if err := runCommandLine(t, "down"); ExitStatus(err) != 0 || time.Since(start) > 5*time.Second {
			t.Fatalf("down answered %v after %s", err, time.Since(start))
		}
		if got := sgRan(t, record); !slices.Equal(got, []string{"down"}) {
			t.Errorf("sg ran %q", got)
		}
	})
}

// Ctrl-C in the step ends the command there, as an interruption: nothing
// runs, through sg or in this process.
func TestTheStepInterruptedEndsTheCommand(t *testing.T) {
	s := standInMachine(t)
	s.member = []string{"docker"}
	record := sgStandIn(t, "0")
	ctx, cancel := context.WithCancel(t.Context())
	machine.reachable = func(probe context.Context) bool {
		cancel()
		<-probe.Done()
		return false
	}
	t.Chdir(t.TempDir())
	rootCmd.SetArgs([]string{"access", "status"})
	t.Cleanup(func() { rootCmd.SetArgs(nil) })
	err := Execute(ctx)
	if ExitStatus(err) != exitInterrupted {
		t.Fatalf("access status answered %v", err)
	}
	if _, err := os.Stat(record); err == nil {
		t.Error("sg ran")
	}
}

// A stop from outside reaches the second run, and this process exits as a
// shell reports a run a signal killed: 128 and the signal's number.
func TestAStopReachesTheSecondRun(t *testing.T) {
	s := standInMachine(t)
	s.member = []string{"docker"}
	record := sgStandIn(t, "0")
	t.Setenv(fakeSgWaits, "1")
	ctx, cancel := context.WithCancel(t.Context())
	ended := make(chan error, 1)
	go func() {
		_, err := continueWithGroup(ctx, []string{"down"}, "ana", io.Discard, io.Discard)
		ended <- err
	}()
	for start := time.Now(); ; time.Sleep(20 * time.Millisecond) { // sleep-ok: polls for the stand-in's record, bounded below
		if _, err := os.Stat(record + ".run"); err == nil {
			break
		}
		if time.Since(start) > 20*time.Second {
			t.Fatal("the second run did not start")
		}
	}
	cancel()
	select {
	case err := <-ended:
		if ExitStatus(err) != 128+int(syscall.SIGTERM) {
			t.Fatalf("answered %v, status %d", err, ExitStatus(err))
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the stop did not reach the second run")
	}
}

// The root's one step is every command's: no command below the root sets
// a PersistentPreRun of its own, which would take it away. Whether a
// command reaches Docker is read from what it calls, which no test here
// can read without a list kept by hand: the annotation is held to the
// commands TestContinuesInATerminalOlderThanTheGroup names.
func TestNoCommandTakesTheRootsStepAway(t *testing.T) {
	var walk func(c *cobra.Command)
	walk = func(c *cobra.Command) {
		for _, sub := range c.Commands() {
			if sub.PersistentPreRun != nil || sub.PersistentPreRunE != nil {
				t.Errorf("%s sets a PersistentPreRun of its own", sub.CommandPath())
			}
			walk(sub)
		}
	}
	if rootCmd.PersistentPreRunE == nil {
		t.Error("the root has no step")
	}
	walk(rootCmd)
}

// TestShellQuoteReadsBackWordForWord runs shellQuote's line through sh, as
// sg does: every word comes back as it was, nothing expanded or run.
func TestShellQuoteReadsBackWordForWord(t *testing.T) {
	words := []string{"/usr/local/bin/cyfr", "init", "--hostname=it's", "--domain=$HOME", "a b", ";touch x"}
	out, err := exec.Command("/bin/sh", "-c", shellQuote(append([]string{"printf", "%s\\n"}, words...))).Output()
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n"); !slices.Equal(got, words) {
		t.Errorf("sh read back %q, want %q", got, words)
	}
}

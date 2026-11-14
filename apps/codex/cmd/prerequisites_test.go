// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package cmd

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
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
	self, _ := os.Executable()
	sg, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(sg), "docker\n-c\n"+shellQuote([]string{self, "init", "--no-pull"})+"\n"; got != want {
		t.Errorf("sg ran %q, want %q", got, want)
	}
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
				want = append(want, "sh -c apt-get update && apt-get install -y --no-install-recommends docker.io docker-compose-v2 apparmor && systemctl enable --now docker && usermod -aG docker "+currentAccount(t))
			}
			want = append(want, "-k")
			if lines := strings.Split(strings.TrimSuffix(string(got), "\n"), "\n"); !slices.Equal(lines, want) {
				t.Fatalf("sudo ran %q, want %q", lines, want)
			}
		})
	}
}

func currentAccount(t *testing.T) string {
	t.Helper()
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	return u.Username
}

// passwordSentence is the one line before sudo's own prompt.
const passwordSentence = "Ubuntu will now ask for your password: the one you log in to this machine with. Nothing shows while you type.\n"

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
	machine.reachable = func() bool { asked++; return asked > polls }
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
		machine.reachable = func() bool {
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

// A continued init's status is init's.
func TestInitAnswersTheContinuationsStatus(t *testing.T) {
	s := standInMachine(t)
	s.installed, s.running, s.member = dockerPackages, true, []string{"docker"}
	sgStandIn(t, "7")
	if _, _, err := prepare(t); ExitStatus(err) != 7 {
		t.Fatalf("err = %v, status %d", err, ExitStatus(err))
	}
}

// cyfr up in a terminal older than the group runs itself again through sg.
func TestUpContinuesInATerminalOlderThanTheGroup(t *testing.T) {
	s := standInMachine(t)
	s.member = []string{"docker"}
	record := sgStandIn(t, "0")
	continued, err := upWithGroup(nil, &bytes.Buffer{}, &bytes.Buffer{})
	if !continued || err != nil {
		t.Fatalf("continued %t, err %v", continued, err)
	}
	self, _ := os.Executable()
	sg, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(sg), "docker\n-c\n"+shellQuote([]string{self, "up"})+"\n"; got != want {
		t.Errorf("sg ran %q, want %q", got, want)
	}
}

// cyfr up carries on as it is when sg has nothing to give it.
func TestUpNeedsNoContinuation(t *testing.T) {
	for name, set := range map[string]func(*standIn){
		"another system":     func(s *standIn) { s.supported = false },
		"not in the group":   func(s *standIn) { s.member = nil },
		"the process has it": func(s *standIn) { s.process = []string{"docker"} },
	} {
		t.Run(name, func(t *testing.T) {
			s := standInMachine(t)
			s.member = []string{"docker"}
			set(s)
			record := sgStandIn(t, "0")
			if continued, err := upWithGroup(nil, &bytes.Buffer{}, &bytes.Buffer{}); continued || err != nil {
				t.Fatalf("continued %t, err %v", continued, err)
			}
			if _, err := os.Stat(record); err == nil {
				t.Error("sg ran")
			}
		})
	}
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

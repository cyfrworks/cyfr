//go:build unix

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/access"
)

// workDocker stands in for docker for setup's work, a process of its own.
// It logs each call, keeps the environment its info was asked in, waits
// for <key>.release where <key>.block is, and answers <key>.out and
// <key>.exit: key is the subcommand, up for a compose up and cyfrps for ps.
const workDocker = `#!/bin/sh
d="$FAKE_DOCKER_DIR"
printf '%s\n' "$*" >>"$d/log"
k="$1"
case " $* " in " compose "*" up "*) k=up ;; esac
[ "$k" = ps ] && k=cyfrps
[ "$k" = info ] && env >"$d/environ"
if [ -f "$d/$k.block" ]; then
  printf '%s\n' "$$" >"$d/$k.pid"
  while [ ! -f "$d/$k.release" ]; do sleep 0.02; done
  : >"$d/$k.ended"
fi
[ -f "$d/$k.out" ] && cat "$d/$k.out"
[ -f "$d/$k.exit" ] && exit "$(cat "$d/$k.exit")"
exit 0
`

// workProject is a folder for setup's work to set CYFR up in, the work a
// process of its own over workDocker, and no other docker on its PATH.
type workProject struct {
	localStack
	// tools is the one other folder on PATH.
	tools string
}

func newWorkProject(t *testing.T) workProject {
	t.Helper()
	template, compose := readShippedTemplate(t), shippedCompose(t)
	fake, tools, parent := t.TempDir(), t.TempDir(), t.TempDir()
	dir := filepath.Join(parent, "cyfr")
	p := workProject{localStack{updateScenario: &updateScenario{t: t, project: dir, fake: fake}}, tools}
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env.example"), []byte(template), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "docker-compose.yml"), compose, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fake, "docker"), []byte(workDocker), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"sleep", "cat", "env"} {
		program, err := exec.LookPath(name)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(program, filepath.Join(tools, name)); err != nil {
			t.Fatal(err)
		}
	}
	p.answer("context.out", "unix:///var/run/docker.sock\n")
	t.Setenv("PATH", fake+string(os.PathListSeparator)+tools)
	workSeesDocker(t, fake)

	saved, savedSg, savedDesktop := machine, sgProgram, dockerDesktop
	t.Cleanup(func() { machine, sgProgram, dockerDesktop = saved, savedSg, savedDesktop })
	machine.system = func() string { return "linux" }
	sgProgram = filepath.Join(fake, "no-sg")
	return p
}

// run asks setup's work to set CYFR up in dir, answering the steps it
// reported.
func (p workProject) run(ctx context.Context, dir string) ([]string, error) {
	var steps []string
	_, err := setupWork(ctx, func(s string) { steps = append(steps, s) }, workRun, dir)
	return steps, err
}

func (p workProject) count(prefix string) int {
	n := 0
	for _, line := range p.log() {
		if strings.HasPrefix(line, prefix) {
			n++
		}
	}
	return n
}

func (p workProject) starts() int { return p.count("ENGINE start ") }

func (p workProject) has(name string) bool {
	_, err := os.Stat(filepath.Join(p.fake, name))
	return err == nil
}

// await waits for what to hold.
func (p workProject) await(what string, holds func() bool) {
	p.t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !holds() {
		if time.Now().After(deadline) {
			p.t.Fatalf("waited for %s", what)
		}
		time.Sleep(20 * time.Millisecond) // sleep-ok: the poll of a wait bounded by deadline
	}
}

// blocked waits for docker's key call to block and answers its process.
func (p workProject) blocked(key string) int {
	p.t.Helper()
	var pid int
	p.await("docker "+key, func() bool {
		raw, err := os.ReadFile(filepath.Join(p.fake, key+".pid"))
		if err != nil {
			return false
		}
		pid, err = strconv.Atoi(strings.TrimSpace(string(raw)))
		return err == nil && pid > 0
	})
	return pid
}

func readEnv(t *testing.T, dir string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(dir, ".env"))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// recordWorksStdout answers what setup's work wrote on its stdout, whole.
func recordWorksStdout(t *testing.T) *bytes.Buffer {
	t.Helper()
	said, saved := &bytes.Buffer{}, startWork
	t.Cleanup(func() { startWork = saved })
	startWork = func(args []string) (*workProcess, error) {
		w, err := saved(args)
		if err == nil {
			w.out = io.TeeReader(w.out, said)
		}
		return w, err
	}
	return said
}

// One action sets CYFR up in a folder and starts it once: init's steps
// then the start. Asked again it mints nothing again and starts. Neither
// the setup token nor a setup link is on its stdout.
func TestSetupsWorkSetsUpAFolderAndStartsIt(t *testing.T) {
	p := newWorkProject(t)
	said := recordWorksStdout(t)
	steps, err := p.run(t.Context(), p.project)
	if err != nil || !slices.Equal(steps, []string{"files", "settings", "images", "start"}) {
		t.Fatalf("the run answered %v after %v", err, steps)
	}
	if p.starts() != 1 || p.count("pull ") < 2 {
		t.Fatalf("CYFR was started %d times after %d pulls", p.starts(), p.count("pull "))
	}
	env := readEnv(t, p.project)
	token, _ := parseEnvFile(env).value(setupTokenVar)
	if len(token) != 64 {
		t.Fatalf("no setup token was written")
	}
	if info, err := os.Stat(filepath.Join(p.project, ".env")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf(".env is %v (%v)", info, err)
	}

	steps, err = p.run(t.Context(), p.project)
	if err != nil || !slices.Equal(steps, []string{"start"}) || p.starts() != 2 {
		t.Fatalf("asked again it answered %v after %v, %d starts", err, steps, p.starts())
	}
	if readEnv(t, p.project) != env {
		t.Fatal("asked again it changed .env")
	}
	if out := said.String(); strings.Contains(out, token) || strings.Contains(out, "/setup#") {
		t.Fatal("the work's stdout carries the setup token")
	}
}

// What setup cannot complete is refused in a sentence before anything is
// written or started.
func TestSetupsWorkRefusesBeforeItWrites(t *testing.T) {
	for _, c := range []struct {
		name, words string
		folder      func(t *testing.T, p workProject) string
	}{
		{"Docker not answering", "Docker does not answer this account. Nothing was written", func(_ *testing.T, p workProject) string {
			p.answer("info.exit", "1")
			return filepath.Join(filepath.Dir(p.project), "new")
		}},
		{"Docker on another computer", "containers on another computer", func(_ *testing.T, p workProject) string {
			p.answer("context.out", "tcp://192.0.2.1:2375\n")
			return filepath.Join(filepath.Dir(p.project), "new")
		}},
		{"Docker not saying where it runs", "did not say where it runs containers", func(_ *testing.T, p workProject) string {
			p.answer("context.exit", "1")
			return filepath.Join(filepath.Dir(p.project), "new")
		}},
		{"a name Docker cannot use", "needs a letter a to z or a digit", func(_ *testing.T, p workProject) string {
			return filepath.Join(filepath.Dir(p.project), "---")
		}},
		{"the account's own folder", "choose a folder inside it", func(t *testing.T, p workProject) string {
			home := t.TempDir()
			t.Setenv("HOME", home)
			return home
		}},
		{"a link to the account's own folder", "choose a folder inside it", func(t *testing.T, p workProject) string {
			home := t.TempDir()
			t.Setenv("HOME", home)
			link := filepath.Join(t.TempDir(), "mine")
			if err := os.Symlink(home, link); err != nil {
				t.Fatal(err)
			}
			return link
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			p := newWorkProject(t)
			dir := c.folder(t, p)
			_, before := os.Stat(dir)
			steps, err := p.run(t.Context(), dir)
			if err == nil || !strings.Contains(err.Error(), c.words) || len(steps) != 0 {
				t.Fatalf("it answered %v after %v, want %q", err, steps, c.words)
			}
			if before != nil {
				if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("it made the folder (%v)", err)
				}
			} else if entries, err := os.ReadDir(dir); err != nil || len(entries) != 0 {
				t.Fatalf("it wrote %v (%v)", entries, err)
			}
			if p.starts() != 0 || p.count("pull ") != 0 {
				t.Fatalf("it ran %v", p.log())
			}
		})
	}
}

// A folder that is not there is made, and one with nothing to write .env
// from says so rather than start.
func TestSetupsWorkMakesTheFolder(t *testing.T) {
	p := newWorkProject(t)
	dir := filepath.Join(filepath.Dir(p.project), "not", "there", "yet")
	_, err := p.run(t.Context(), dir)
	if err == nil || !strings.Contains(err.Error(), "no .env.example") || p.starts() != 0 {
		t.Fatalf("it answered %v after %d starts", err, p.starts())
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		t.Fatalf("the folder was not made (%v)", err)
	}
}

// Two setups of one folder are one: the second changes nothing.
func TestSetupsWorkRunsOneSetupAFolder(t *testing.T) {
	p := newWorkProject(t)
	lock := filepath.Join(p.project, setupLockFile)
	if err := os.MkdirAll(filepath.Dir(lock), 0o700); err != nil {
		t.Fatal(err)
	}
	release, busy, err := access.LockFile(lock)
	if err != nil || busy {
		t.Fatalf("the lock was not taken (%v, busy %v)", err, busy)
	}
	defer release()
	_, err = p.run(t.Context(), p.project)
	if err == nil || !strings.Contains(err.Error(), "still running") || p.starts() != 0 {
		t.Fatalf("the second answered %v after %d starts", err, p.starts())
	}
	if _, err := os.Stat(filepath.Join(p.project, ".env")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the second wrote .env (%v)", err)
	}
}

// The folder keeps the name it was chosen by, through a link too: compose
// names the project after it, which is what opens the folder later.
func TestSetupsWorkNamesTheProjectAsTheFolderWasChosen(t *testing.T) {
	p := newWorkProject(t)
	chosen := filepath.Join(t.TempDir(), "chosen")
	if err := os.Symlink(p.project, chosen); err != nil {
		t.Fatal(err)
	}
	if _, err := p.run(t.Context(), chosen); err != nil {
		t.Fatal(err)
	}
	if p.count("compose -p "+access.ProjectName(chosen)+" ") == 0 {
		t.Fatalf("compose was not given the chosen name: %v", p.log())
	}
}

// A start that fails says why, and asked again it starts with what was
// written.
func TestSetupsWorkStartsAgainAfterAFailedStart(t *testing.T) {
	p := newWorkProject(t)
	p.answer("up.exit", "1")
	if _, err := p.run(t.Context(), p.project); err == nil || !strings.Contains(err.Error(), "did not become healthy") {
		t.Fatalf("the failed start answered %v", err)
	}
	env := readEnv(t, p.project)
	if err := os.Remove(filepath.Join(p.fake, "up.exit")); err != nil {
		t.Fatal(err)
	}
	if steps, err := p.run(t.Context(), p.project); err != nil || !slices.Equal(steps, []string{"start"}) || readEnv(t, p.project) != env {
		t.Fatalf("asked again it answered %v after %v", err, steps)
	}
}

// A cancel ends what hangs before the start and starts nothing. A start
// once begun runs to its end, and what asked waits for it.
func TestSetupsWorkCancelled(t *testing.T) {
	for _, c := range []struct {
		during    string
		wroteEnv  bool
		finishing bool
	}{
		{during: "info"},
		{during: "context"},
		{during: "pull", wroteEnv: true},
		{during: "up", wroteEnv: true, finishing: true},
	} {
		t.Run(c.during, func(t *testing.T) {
			p := newWorkProject(t)
			p.answer(c.during+".block", "")
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			ended := make(chan error, 1)
			go func() {
				_, err := p.run(ctx, p.project)
				ended <- err
			}()
			pid := p.blocked(c.during)
			cancel()
			if c.finishing {
				select {
				case err := <-ended:
					t.Fatalf("the start was not waited for: %v", err)
				case <-time.After(500 * time.Millisecond): // sleep-ok: the window a cancelled start must outlive
				}
				p.answer(c.during+".release", "")
			}
			var err error
			select {
			case err = <-ended:
			case <-time.After(20 * time.Second):
				p.answer(c.during+".release", "")
				t.Fatal("the cancel did not end it")
			}
			if c.finishing {
				if err != nil || !p.has("up.ended") || p.starts() != 1 {
					t.Fatalf("the start ended with %v, finished %v", err, p.has("up.ended"))
				}
			} else {
				if err == nil || !strings.Contains(err.Error(), "stopped before CYFR was started") || p.starts() != 0 {
					t.Fatalf("the cancel answered %v after %d starts", err, p.starts())
				}
				p.await("the docker that hung to be gone", func() bool { return syscall.Kill(pid, 0) != nil })
			}
			if _, err := os.Stat(filepath.Join(p.project, ".env")); (err == nil) != c.wroteEnv {
				t.Fatalf(".env written: %v, want %v", err == nil, c.wroteEnv)
			}
			if c.during == "pull" && p.count("pull ") != 1 {
				t.Fatalf("it went on pulling after the cancel: %v", p.log())
			}
		})
	}
}

// A probe or a reading that hangs is not waited for past its caller's
// end, and the docker it waited on ends with it.
func TestSetupsWorkIsNotWaitedForPastItsCaller(t *testing.T) {
	for verb, key := range map[string]string{workProbe: "info", workLook: "context"} {
		t.Run(verb, func(t *testing.T) {
			p := newWorkProject(t)
			args := []string{verb}
			if verb == workLook {
				if _, err := p.run(t.Context(), p.project); err != nil {
					t.Fatal(err)
				}
				args = append(args, p.project)
			}
			p.answer(key+".block", "")
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			ended := make(chan error, 1)
			go func() {
				_, err := setupWork(ctx, nil, args...)
				ended <- err
			}()
			pid := p.blocked(key)
			cancel()
			select {
			case err := <-ended:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("it answered %v", err)
				}
			case <-time.After(20 * time.Second):
				p.answer(key+".release", "")
				t.Fatal("it was waited for")
			}
			p.await("the docker that hung to be gone", func() bool { return syscall.Kill(pid, 0) != nil })
		})
	}
}

// The app may die while the work runs. With its stdin still open the
// work's next step, written to nobody, kills it not. With both pipes gone
// a start begun still finishes.
func TestSetupsWorkOutlivesWhoAskedDuringAStart(t *testing.T) {
	for _, c := range []struct {
		name, during string
		stdinGone    bool
	}{
		{"nobody reads the step that begins the start", "pull", false},
		{"the app died during the start", "up", true},
	} {
		t.Run(c.name, func(t *testing.T) {
			p := newWorkProject(t)
			p.answer(c.during+".block", "")
			work, err := startWork([]string{workRun, p.project})
			if err != nil {
				t.Fatal(err)
			}
			defer work.in.Close()
			p.blocked(c.during)
			if err := work.out.(io.Closer).Close(); err != nil {
				t.Fatal(err)
			}
			if c.stdinGone {
				work.in.Close()
			}
			p.answer(c.during+".release", "")
			if err := work.wait(); err != nil {
				t.Fatalf("the work ended with %v", err)
			}
			if p.starts() != 1 || p.count("compose ") == 0 {
				t.Fatalf("the start did not run: %v", p.log())
			}
		})
	}
}

// What the launcher's environment says of a CYFR reaches neither the
// folder's .env nor Docker.
func TestSetupsWorkTakesNoSettingFromTheLauncher(t *testing.T) {
	p := newWorkProject(t)
	for name, value := range map[string]string{
		"CYFR_PORT": "4999", "CYFR_ACCESS": "public", "COMPOSE_PROJECT_NAME": "launchers",
		setupTokenVar: strings.Repeat("cd", 32), directoryVar: "https://launcher.example",
	} {
		t.Setenv(name, value)
	}
	if _, err := p.run(t.Context(), p.project); err != nil {
		t.Fatal(err)
	}
	if port := portOf(t, p.project); port != "4000" {
		t.Errorf(".env names port %s", port)
	}
	environ, err := os.ReadFile(filepath.Join(p.fake, "environ"))
	if err != nil {
		t.Fatal(err)
	}
	for _, setting := range []string{"CYFR_PORT=", "CYFR_ACCESS=", "COMPOSE_PROJECT_NAME=launchers", setupTokenVar + "=", directoryVar + "="} {
		if strings.Contains(string(environ), setting) {
			t.Errorf("docker was given %s", setting)
		}
	}
}

// sgStandIn is sg as body has it, the group and the command it was given
// recorded in the fake's folder.
func (p workProject) sgStandIn(body string) string {
	p.t.Helper()
	path := filepath.Join(p.tools, "sg")
	script := "#!/bin/sh\nprintf '%s %s\\n' \"$1\" \"$2\" >>'" + filepath.Join(p.fake, "sg") + "'\n" + body
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		p.t.Fatal(err)
	}
	return path
}

// sg as util-linux has it, becoming the command, and as shadow has it,
// its parent, after whatever the account's shell prints as it starts.
const (
	sgBecomes = `exec /bin/sh -c "$3"` + "\n"
	sgParents = "echo 'Welcome back'\necho '{\"not\": \"a message\"}'\n" + `/bin/sh -c "$3"` + "\nexit $?\n"
)

// The docker group reaches only a new process: the work goes through sg
// where this process is older than the account's membership, on any
// Linux, and directly everywhere else.
func TestSetupsWorkReachesTheDockerGroup(t *testing.T) {
	member := []string{dockerGroup}
	for _, c := range []struct {
		name, system    string
		account, mine   []string
		noSg, throughSg bool
		body            string
	}{
		{name: "older than the group, sg becoming it", system: "linux", account: member, throughSg: true, body: sgBecomes},
		{name: "older than the group, sg its parent", system: "linux", account: member, throughSg: true, body: sgParents},
		{name: "already in the group", system: "linux", account: member, mine: member, body: sgBecomes},
		{name: "no member of the group", system: "linux", body: sgBecomes},
		{name: "no sg", system: "linux", account: member, noSg: true, body: sgBecomes},
		{name: "a Mac", system: "darwin", account: member, body: sgBecomes},
	} {
		t.Run(c.name, func(t *testing.T) {
			p := newWorkProject(t)
			machine.system = func() string { return c.system }
			machine.supported = func() bool { return false }
			machine.groups = func(account string) []string {
				if account == "" {
					return c.mine
				}
				return c.account
			}
			if sg := p.sgStandIn(c.body); !c.noSg {
				sgProgram = sg
			}
			if _, err := p.run(t.Context(), p.project); err != nil {
				t.Fatal(err)
			}
			if p.starts() != 1 {
				t.Fatalf("CYFR was started %d times", p.starts())
			}
			got, err := os.ReadFile(filepath.Join(p.fake, "sg"))
			if c.throughSg && string(got) != "docker -c\n" || !c.throughSg && !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("sg was given %q (%v), want it used: %v", got, err, c.throughSg)
			}
		})
	}
}

// A cancel reaches work that has sg for its parent: it is the end of
// stdin, since killing what was started would leave that work running.
func TestSetupsWorkCancelledThroughSg(t *testing.T) {
	p := newWorkProject(t)
	machine.groups = func(account string) []string {
		if account == "" {
			return nil
		}
		return []string{dockerGroup}
	}
	sgProgram = p.sgStandIn(sgParents)
	p.answer("pull.block", "")
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	ended := make(chan error, 1)
	go func() {
		_, err := p.run(ctx, p.project)
		ended <- err
	}()
	pid := p.blocked("pull")
	cancel()
	select {
	case err := <-ended:
		if err == nil || !strings.Contains(err.Error(), "stopped before CYFR was started") {
			t.Fatalf("it answered %v", err)
		}
	case <-time.After(20 * time.Second):
		p.answer("pull.release", "")
		t.Fatal("the cancel did not reach the work")
	}
	p.await("the pull to be gone", func() bool { return syscall.Kill(pid, 0) != nil })
}

// Work that dies without its end is a failure, never taken for done.
func TestSetupsWorkThatDiesIsAFailure(t *testing.T) {
	p := newWorkProject(t)
	machine.groups = func(account string) []string {
		if account == "" {
			return nil
		}
		return []string{dockerGroup}
	}
	sgProgram = p.sgStandIn("echo '{\"type\":\"step\",\"step\":\"start\"}'\nexit 0\n")
	steps, err := p.run(t.Context(), p.project)
	if err == nil || !strings.Contains(err.Error(), "ended before it finished") || !slices.Equal(steps, []string{"start"}) {
		t.Fatalf("it answered %v after %v", err, steps)
	}
}

// Where this process cannot reach Docker itself, older than the docker
// group or without Docker Desktop's docker on its PATH, a folder is still
// set up, opened by the app and its first person sent with the setup
// token of that folder: every reading of Docker is setup's work's.
func TestAFirstPersonWhereOnlySetupsWorkReachesDocker(t *testing.T) {
	for name, only := range map[string]func(p workProject){
		"older than the docker group": func(p workProject) {
			machine.groups = func(account string) []string {
				if account == "" {
					return nil
				}
				return []string{dockerGroup}
			}
			// Docker is on sg's PATH alone.
			p.t.Setenv("PATH", p.tools)
			sgProgram = p.sgStandIn("PATH='" + p.fake + "':\"$PATH\"\nexport PATH\n" + sgBecomes)
		},
		"without Docker Desktop's docker on PATH": func(p workProject) {
			machine.system = func() string { return "darwin" }
			p.t.Setenv("PATH", p.tools)
			dockerDesktop = func(string) (string, string) { return "", p.fake }
		},
	} {
		t.Run(name, func(t *testing.T) {
			p := newWorkProject(t)
			cyfr := servingAccounts(t, "")
			home := "http://localhost:" + strconv.Itoa(cyfr.port)
			var lines []string
			for _, line := range strings.Split(readShippedTemplate(t), "\n") {
				if !strings.HasPrefix(line, "CYFR_PORT=") && !strings.HasPrefix(line, directoryVar+"=") {
					lines = append(lines, line)
				}
			}
			lines = append(lines, "CYFR_PORT="+strconv.Itoa(cyfr.port), directoryVar+"="+home, "")
			if err := os.WriteFile(filepath.Join(p.project, ".env.example"), []byte(strings.Join(lines, "\n")), 0o644); err != nil {
				t.Fatal(err)
			}
			only(p)
			if found, err := exec.LookPath("docker"); err == nil {
				t.Fatalf("this process reaches docker at %s itself", found)
			}
			if _, err := p.run(t.Context(), p.project); err != nil {
				t.Fatal(err)
			}
			p.publishing(p.project, cyfr.port, logNotSetUp)
			a := newLocalApp(t, p.project)
			a.open(home, home)
			a.makeAccount()
			token, _ := parseEnvFile(readEnv(t, p.project)).value(setupTokenVar)
			admission, _ := helloOf(t, cyfr)["admission"].(map[string]any)
			if token == "" || admission["setup"] != token {
				t.Fatalf("the first hello carries no token of that folder's")
			}
		})
	}
}

// An interrupted pull is the last cyfr init makes, and is told as no
// image's failure.
func TestInitsPullsEndAtAnInterrupt(t *testing.T) {
	p := newWorkProject(t)
	t.Chdir(p.project)
	p.answer("pull.block", "")
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	var out, warned bytes.Buffer
	ended := make(chan error, 1)
	go func() { ended <- initProject(ctx, initOptions{}, nil, &out, &warned) }()
	p.blocked("pull")
	cancel()
	select {
	case <-ended:
	case <-time.After(20 * time.Second):
		p.answer("pull.release", "")
		t.Fatal("init did not end")
	}
	if strings.Count(out.String(), "Pulling ") != 1 || strings.Contains(warned.String(), "failed to pull") {
		t.Fatalf("after the interrupt init said:\n%s%s", out.String(), warned.String())
	}
}

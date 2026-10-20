// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package access

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// heldFromOutside reports whether another process cannot take the lock:
// flock(1) -n where it is installed, else a fresh open file description.
func heldFromOutside(t *testing.T, dir string) bool {
	t.Helper()
	lock := filepath.Join(dir, stateDir, lockFile)
	if flock, err := exec.LookPath("flock"); err == nil {
		err := exec.Command(flock, "-n", lock, "true").Run()
		var exit *exec.ExitError
		if err != nil && !errors.As(err, &exit) {
			t.Fatal(err)
		}
		return err != nil
	}
	f, err := os.OpenFile(lock, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	busy, err := lockExclusive(f)
	if err != nil {
		t.Fatal(err)
	}
	return busy
}

// binaryHome is a home whose docker is the fake model in a state file,
// run as a binary through the system implementation.
func binaryHome(t *testing.T, running bool) (*testHome, string) {
	h := newHome(t)
	if running {
		h.fake.startStack(t, h.head())
	}
	state := filepath.Join(t.TempDir(), "docker.json")
	writeFakeState(t, state, h.fake.st)
	h.unlock()
	e, err := Open(h.dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	binaryDocker(e, state)
	h.e = e
	return h, state
}

func alive(pid int) bool { return syscall.Kill(pid, 0) == nil }

func readPID(t *testing.T, path string) int {
	data, _ := os.ReadFile(path)
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatalf("%s holds %q", path, data)
	}
	return pid
}

// A docker child keeps the lock after its holder dies: the descriptor
// passed to the watchdog and on to docker holds it, so the next taker is
// refused, naming the watchdog and its deadline, while the orphan runs,
// and holds it once the orphan ends.
func TestDockerChildKeepsTheLockAfterItsHolderDies(t *testing.T) {
	h, state := binaryHome(t, false)
	dir := t.TempDir()
	st := readFakeState(t, state)
	st.Pause = &fakePause{Match: "ps -a", Paused: filepath.Join(dir, "paused"), Release: filepath.Join(dir, "release")}
	writeFakeState(t, state, st)
	ready := filepath.Join(dir, "ready")
	cmd := exec.Command(exeOrSkip(t), "-access.holder", h.dir, ready, "docker", "ps", "-a")
	cmd.Env = childEnv("ACCESS_HOLDER_STATE=" + state)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.WriteFile(st.Pause.Release, nil, 0o600); cmd.Process.Kill(); cmd.Wait() })
	waitFor(t, 20*time.Second, "the docker call to pause", func() bool { _, err := os.Stat(st.Pause.Paused); return err == nil })
	dockerPID := readPID(t, st.Pause.Paused)

	cmd.Process.Kill()
	cmd.Wait()
	if !heldFromOutside(t, h.dir) {
		t.Fatal("the lock was free while the dead holder's docker child ran")
	}
	var busy *ErrBusy
	_, err := h.e.Lock("next")
	if !errors.As(err, &busy) || busy.WatchdogPID == 0 || busy.Until.IsZero() {
		t.Fatalf("the next taker answered %#v", err)
	}
	if !alive(busy.WatchdogPID) || busy.WatchdogPID == dockerPID || busy.Until.Before(time.Now().Add(50*time.Minute)) {
		t.Errorf("the record names watchdog %d until %s", busy.WatchdogPID, busy.Until)
	}
	want := "Another cyfr command holds this home (`" + busy.Holder + "`), or a docker command it started is still running (watchdog pid `" + strconv.Itoa(busy.WatchdogPID) + "`, which ends by `" + busy.Until.UTC().Format(time.RFC3339) + "` at the latest). Nothing was changed. Wait until it has finished, then run this command again; if the holder was interrupted, run `cyfr access --resume` after that time."
	if msg := busy.Refusal().Message(); msg != want || !strings.HasPrefix(busy.Holder, "cyfr holder on ") {
		t.Errorf("the refusal reads %q", msg)
	}

	os.WriteFile(st.Pause.Release, nil, 0o600)
	waitFor(t, 20*time.Second, "the lock to free once the orphan ended", func() bool { return !heldFromOutside(t, h.dir) })
	unlock, err := h.e.Lock("next")
	if err != nil {
		t.Fatal(err)
	}
	unlock()
	if alive(busy.WatchdogPID) || alive(dockerPID) {
		t.Error("the watchdog or its docker outlived the call")
	}
}

// The watchdog kills a docker call at its deadline, and the call answers
// ErrDeadline: an orphan holds the lock no longer than that.
func TestWatchdogKillsACallAtItsDeadline(t *testing.T) {
	h, _ := binaryHome(t, false)
	unlock, err := h.e.Lock("test")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	pidfile := filepath.Join(t.TempDir(), "pid")
	start := time.Now()
	_, err = h.e.Docker().Run(bg, Call{Args: []string{"sleep-forever", pidfile}, Deadline: time.Second})
	if !errors.Is(err, ErrDeadline) {
		t.Fatalf("the call answered %v", err)
	}
	if took := time.Since(start); took > 15*time.Second {
		t.Errorf("the call took %s", took)
	}
	pid := readPID(t, pidfile)
	waitFor(t, 5*time.Second, "the killed docker to be gone", func() bool { return !alive(pid) })
}

// Every docker child runs with cyfr's environment but every COMPOSE_*
// variable, DOCKER_* kept, in the project directory, in a process group
// of its own; while the lock is held it inherits the lock's descriptor,
// and never otherwise.
func TestSystemDockerChildren(t *testing.T) {
	t.Setenv("COMPOSE_PROFILES", "public,tailnet")
	t.Setenv("COMPOSE_FILE", "elsewhere.yml")
	t.Setenv("compose_project_name", "other")
	t.Setenv("DOCKER_HOST", "unix:///run/fake.sock")
	h, state := binaryHome(t, false)
	if _, err := h.e.Docker().Run(bg, Call{Args: []string{"ps", "-a"}}); err != nil {
		t.Fatal(err)
	}
	unlock, err := h.e.Lock("test")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.e.Docker().Run(bg, Call{Args: []string{"ps", "-a"}}); err != nil {
		t.Fatal(err)
	}
	unlock()
	calls := readFakeState(t, state).Calls
	if len(calls) != 2 {
		t.Fatalf("recorded %v", calls)
	}
	home, err := os.Stat(h.dir)
	if err != nil {
		t.Fatal(err)
	}
	for i, c := range calls {
		if slices.ContainsFunc(c.Env, func(kv string) bool { return strings.HasPrefix(strings.ToUpper(kv), "COMPOSE_") }) {
			t.Errorf("call %d's environment holds %v", i, c.Env)
		}
		if !slices.Contains(c.Env, "DOCKER_HOST=unix:///run/fake.sock") {
			t.Errorf("call %d lost DOCKER_HOST: %v", i, c.Env)
		}
		// The child's working directory is the project's, named with its
		// links resolved where the temporary directory lies behind one, as
		// macOS's /var is a link to /private/var.
		if dir, err := os.Stat(c.Dir); !c.OwnGroup || err != nil || !os.SameFile(dir, home) {
			t.Errorf("call %d ran in group-own %v, directory %s", i, c.OwnGroup, c.Dir)
		}
		if c.LockFD != (i == 1) {
			t.Errorf("call %d holds the lock's descriptor: %v", i, c.LockFD)
		}
	}
}

// Ruling 6's check: COMPOSE_PROFILES=public,tailnet in cyfr's own
// environment starts neither proxy for a local home with builds off.
// Every compose call names its project, its file, its directory and
// exactly the head's profiles, none here.
func TestComposeProfilesInTheEnvironmentStartNeitherProxy(t *testing.T) {
	t.Setenv("COMPOSE_PROFILES", "public,tailnet")
	h, state := binaryHome(t, false)
	env := strings.Replace(h.env(), "CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100", "CYFR_LOCUS_BUILDS_URL=", 1)
	writeFile(t, filepath.Join(h.dir, ".env"), []byte(env))
	head := h.head()
	if len(head.Profiles) != 0 {
		t.Fatalf("the head selects %v", head.Profiles)
	}
	unlock, err := h.e.Lock("up")
	if err != nil {
		t.Fatal(err)
	}
	if rc, err := h.e.Start(bg, "up"); err != nil || rc.Outcome != "ok" {
		t.Fatalf("start answered %+v, %v", rc, err)
	}
	unlock()
	st := readFakeState(t, state)
	for name, ct := range st.Containers {
		if ct.Service == "caddy" || ct.Service == "tailscale" || ct.Service == "locus-builds" {
			t.Errorf("%s started", name)
		}
	}
	for _, c := range st.Calls {
		if slices.ContainsFunc(c.Env, func(kv string) bool { return strings.HasPrefix(kv, "COMPOSE_") }) {
			t.Errorf("%s ran with %v", c, c.Env)
		}
		if c.Args[0] != "compose" {
			continue
		}
		if c.Args[1] != "-p" || c.Args[2] != "home" || c.Args[3] != "-f" || !slices.Contains(c.Args, "--project-directory") {
			t.Errorf("a compose call lacks the explicit selection: %s", c)
		}
		for i, a := range c.Args {
			if a != "--profile" {
				continue
			}
			// The one read of every access mode's services names their
			// profiles; nothing the home starts names any.
			if !slices.Contains(c.Args, "config") || !slices.Contains(accessModeProfiles(), c.Args[i+1]) {
				t.Errorf("a compose call selects profile %s: %s", c.Args[i+1], c)
			}
		}
	}
}

// An orphaned start: the fake docker pauses during the switch's
// start and the command alone is killed. Another command is refused
// while the orphan holds the lock; released, the orphan ends and frees
// it; recovery then converges, and the orphan's start landed before
// recovery's stop and verify, never after it.
func TestOrphanedStartNeverLandsAfterRecovery(t *testing.T) {
	h, state := binaryHome(t, true)
	dir := t.TempDir()
	st := readFakeState(t, state)
	st.Pause = &fakePause{Match: "up -d --no-deps cyfr", Paused: filepath.Join(dir, "paused"), Release: filepath.Join(dir, "release")}
	writeFakeState(t, state, st)
	ready := filepath.Join(dir, "ready")
	cmd := exec.Command(exeOrSkip(t), "-access.holder", h.dir, ready, "switch", ModePublic, id(1))
	cmd.Env = childEnv("ACCESS_HOLDER_STATE="+state, "ACCESS_HOLDER_DOMAIN=home.example.com")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.WriteFile(st.Pause.Release, nil, 0o600); cmd.Process.Kill(); cmd.Wait() })
	waitFor(t, 30*time.Second, "the start to pause", func() bool { _, err := os.Stat(st.Pause.Paused); return err == nil })
	cmd.Process.Kill()
	cmd.Wait()

	if _, err := h.e.Lock("next"); err == nil {
		t.Fatal("another command took the lock while the orphan ran")
	} else if b, ok := err.(*ErrBusy); !ok || b.WatchdogPID == 0 {
		t.Fatalf("another command answered %v", err)
	}
	os.WriteFile(st.Pause.Release, nil, 0o600)
	var unlock func()
	waitFor(t, 30*time.Second, "the orphan to free the lock", func() bool {
		var err error
		unlock, err = h.e.Lock("next")
		return err == nil
	})
	defer unlock()
	landed := len(readFakeState(t, state).Calls)
	receipts, err := h.e.Resume(bg)
	if err != nil || len(receipts) != 1 || receipts[0].Outcome != "ok" {
		t.Fatalf("recovery answered %+v, %v", receipts, err)
	}
	calls := readFakeState(t, state).Calls
	orphan := slices.IndexFunc(calls, func(c fakeCall) bool { return strings.Contains(c.String(), "up -d --no-deps cyfr") })
	if orphan < 0 || orphan >= landed {
		t.Errorf("the orphan's start is call %d, recovery began at %d", orphan, landed)
	}
	final := readFakeState(t, state)
	var live []string
	for _, ct := range final.Containers {
		if running(ct.State) {
			live = append(live, ct.Service)
		}
	}
	slices.Sort(live)
	if want := slices.Sorted(slices.Values(publicStack)); !slices.Equal(live, want) {
		t.Errorf("running %v, want %v", live, want)
	}
	if _, err := os.Stat(filepath.Join(h.dir, stateDir, journalFile)); err == nil {
		t.Error("the journal is left")
	}
}

// Exclusion across PID namespaces: a container holding the lock through
// the bind-mounted project directory excludes the host command, and the
// host's lock excludes the container.
func TestLockExcludesAHolderInAnotherPIDNamespace(t *testing.T) {
	requireDocker(t)
	h := newHome(t)
	h.unlock()
	name := "access-lock-test-" + id(int(time.Now().UnixNano() % 1e9))[24:]
	lock := filepath.Join(h.dir, stateDir, lockFile)
	out, err := exec.Command("docker", "run", "-d", "--rm", "--name", name, "--network", "none", "-v", h.dir+":"+h.dir, "busybox:latest", "flock", "-n", lock, "sleep", "60").CombinedOutput()
	if err != nil {
		t.Fatalf("docker run: %v\n%s", err, out)
	}
	t.Cleanup(func() { exec.Command("docker", "rm", "-f", name).Run() })
	waitFor(t, 30*time.Second, "the container to take the lock", func() bool { return heldFromOutside(t, h.dir) })
	e, _ := Open(h.dir, h.fake)
	_, err = e.Lock("host")
	busy, ok := err.(*ErrBusy)
	if !ok {
		t.Fatalf("the host taking a lock a container holds answered %v", err)
	}
	// The container wrote no holder record; the kernel's lock table names
	// its flock.
	want := "Another cyfr command holds this home (`a process that wrote no holder record`, pid `" + strconv.Itoa(busy.PID) + "`). Nothing was changed. Wait until it has finished, then run this command again."
	if busy.PID <= 0 || busy.Refusal().Message() != want {
		t.Errorf("the refusal reads %q (pid %d)", busy.Refusal().Message(), busy.PID)
	}
	exec.Command("docker", "rm", "-f", name).Run()
	waitFor(t, 30*time.Second, "the container's lock to go", func() bool { return !heldFromOutside(t, h.dir) })
	unlock, err := e.Lock("host")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	err = exec.Command("docker", "run", "--rm", "--network", "none", "-v", h.dir+":"+h.dir, "busybox:latest", "flock", "-n", lock, "true").Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 1 {
		t.Errorf("a container took the lock the host holds: %v", err)
	}
}

// requireDocker skips t, naming why, where docker cannot run busybox: t
// runs a real container. codex-ci.yml's Linux job has Docker and requires
// it to pass.
func requireDocker(t *testing.T) {
	t.Helper()
	if out, err := exec.Command("docker", "info", "--format", "{{.OSType}}").CombinedOutput(); err != nil || strings.TrimSpace(string(out)) != "linux" {
		t.Skipf("needs a Linux Docker engine, and `docker info` answered %v\n%s", err, out)
	}
	if exec.Command("docker", "image", "inspect", "busybox:latest").Run() != nil {
		if out, err := exec.Command("docker", "pull", "-q", "busybox:latest").CombinedOutput(); err != nil {
			t.Skipf("needs busybox:latest, and the pull failed: %v\n%s", err, out)
		}
	}
}

// Between docker calls the holder record names no watchdog: a refusal
// then names the holder and its own pid, never a child that has ended.
func TestHolderRecordNamesOnlyARunningChild(t *testing.T) {
	h, _ := binaryHome(t, false)
	unlock, err := h.e.Lock("test")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if _, err := h.e.Docker().Run(bg, Call{Args: []string{"ps", "-a"}}); err != nil {
		t.Fatal(err)
	}
	other, _ := Open(h.dir, h.fake)
	_, err = other.Lock("next")
	busy, ok := err.(*ErrBusy)
	if !ok || busy.WatchdogPID != 0 || !busy.Until.IsZero() || busy.PID != os.Getpid() {
		t.Fatalf("after the call the next taker answered %#v", err)
	}
	if p := busy.Refusal().Payload; len(p) != 2 || p["pid"] != strconv.Itoa(os.Getpid()) {
		t.Errorf("the refusal names %v", p)
	}
}

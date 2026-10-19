// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/reach"
)

// stateDockerDir names, for a run of this test binary as the cyfr process,
// the directory of the stateDocker it runs the real engine over.
const stateDockerDir = "CYFR_CMD_TEST_DOCKER_STATE"

// stateDocker is a docker daemon the real engine runs over, its state in a
// directory every process of a test shares, so what a killed cyfr did
// stays done: containers.json holds the project's containers (name,
// service, state), calls.log every call, one per line. The configuration
// compose gives is the real Docker Compose's; `compose up` runs the
// services it names (cyfr when it names none), `docker stop` and `docker
// rm -f` stop and remove containers, `ps` lists them, and cyfr is healthy.
// With killAtUp, the process kills itself (SIGKILL) at its first
// `compose up`, as a cyfr that dies inside its start.
type stateDocker struct {
	dir      string
	killAtUp bool
	mu       sync.Mutex
}

type stateContainer struct {
	Service string `json:"service"`
	State   string `json:"state"`
}

func (d *stateDocker) load() map[string]stateContainer {
	cs := map[string]stateContainer{}
	if data, err := os.ReadFile(filepath.Join(d.dir, "containers.json")); err == nil {
		json.Unmarshal(data, &cs)
	}
	return cs
}

func (d *stateDocker) save(cs map[string]stateContainer) {
	data, _ := json.Marshal(cs)
	os.WriteFile(filepath.Join(d.dir, "containers.json"), data, 0600)
}

// calls are the calls every process made, in order.
func (d *stateDocker) calls() []string {
	data, _ := os.ReadFile(filepath.Join(d.dir, "calls.log"))
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
}

// running are the services whose containers run.
func (d *stateDocker) running() []string {
	var services []string
	for _, c := range d.load() {
		if c.State == "running" {
			services = append(services, c.Service)
		}
	}
	slices.Sort(services)
	return services
}

func (d *stateDocker) Run(ctx context.Context, c reach.Call) (reach.Result, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if f, err := os.OpenFile(filepath.Join(d.dir, "calls.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600); err == nil {
		fmt.Fprintln(f, strings.Join(c.Args, " "))
		f.Close()
	}
	project := reach.ProjectName(".")
	cs := d.load()
	switch {
	case c.Args[0] == "compose" && slices.Contains(c.Args, "config"):
		process := exec.CommandContext(ctx, "docker", c.Args...)
		for _, entry := range os.Environ() {
			if !strings.HasPrefix(entry, "COMPOSE_") {
				process.Env = append(process.Env, entry)
			}
		}
		var stdout, stderr bytes.Buffer
		process.Stdout, process.Stderr = &stdout, &stderr
		err := process.Run()
		res := reach.Result{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			res.ExitCode = exit.ExitCode()
			return res, fmt.Errorf("exit status %d", res.ExitCode)
		}
		return res, err
	case c.Args[0] == "compose" && slices.Contains(c.Args, "up"):
		if d.killAtUp {
			killSelf()
			select {}
		}
		services := c.Args[slices.Index(c.Args, "up")+1:]
		services = slices.DeleteFunc(slices.Clone(services), func(s string) bool { return strings.HasPrefix(s, "-") })
		if len(services) == 0 {
			services = []string{"cyfr"}
		}
		for _, s := range services {
			cs[project+"-"+s+"-1"] = stateContainer{Service: s, State: "running"}
		}
		d.save(cs)
	case c.Args[0] == "stop" || c.Args[0] == "rm":
		for _, name := range c.Args[1:] {
			if container, ok := cs[name]; ok {
				container.State = "exited"
				cs[name] = container
			}
			if c.Args[0] == "rm" {
				delete(cs, name)
			}
		}
		d.save(cs)
	case c.Args[0] == "ps" && strings.Contains(strings.Join(c.Args, " "), "label=com.docker.compose.project="):
		var out strings.Builder
		for name, container := range cs {
			fmt.Fprintf(&out, `{"name":%q,"service":%q,"state":%q}`+"\n", name, container.Service, container.State)
		}
		return reach.Result{Stdout: []byte(out.String())}, nil
	case c.Args[0] == "inspect":
		return reach.Result{Stdout: []byte(`{"Status":"running","ExitCode":0,"Health":{"Status":"healthy"}}`)}, nil
	}
	return reach.Result{}, nil
}

// interruptedSwitch is a local home whose stack runs, switched to public
// by `cyfr reach public` in the cyfr process over the real engine, killed
// at the start of the new head, after the commit: its journal unfinished,
// as a cyfr that died leaves it. A daemon call in flight when it died has
// landed meanwhile: the new head's cyfr runs. It answers the docker, the
// project and the switch's request id.
func interruptedSwitch(t *testing.T) (*stateDocker, string, string) {
	t.Helper()
	compose := shippedCompose(t)
	text, _ := newEnvFromTemplate(t, "me@example.com")
	docker := &stateDocker{dir: t.TempDir()}
	t.Setenv(stateDockerDir, docker.dir)
	dir := filepath.Join(t.TempDir(), "home")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	for name, content := range map[string]string{"docker-compose.yml": string(compose), ".env": text, "cyfr.yaml": "name: test\n"} {
		if err := os.WriteFile(name, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	project := reach.ProjectName(".")
	docker.save(map[string]stateContainer{project + "-cyfr-1": {Service: "cyfr", State: "running"}})

	const id = "5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e"
	stdout, stderr, status := runAsCyfr(t, "real-state-kill", dir, "reach", "public", "--domain", "cyfr.example.com", "--yes", "--request-id", id)
	if status != -1 {
		t.Fatalf("the switch was not killed inside its start (exit %d):\n%s\n%s", status, stdout, stderr)
	}
	if _, err := os.Stat(filepath.Join(".cyfr", "journal.json")); err != nil {
		t.Fatalf("the killed switch left no journal: %v", err)
	}
	if mode, _ := projectEnv(t).value("CYFR_REACH"); mode != reach.ModePublic {
		t.Fatalf("the killed switch did not commit .env before its start (CYFR_REACH is %q)", mode)
	}
	if running := docker.running(); len(running) != 0 {
		t.Fatalf("the killed switch left %v running; it stopped the stack before its commit", running)
	}
	docker.save(map[string]stateContainer{project + "-cyfr-1": {Service: "cyfr", State: "running"}})
	if err := os.WriteFile(filepath.Join(docker.dir, "calls.log"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	return docker, dir, id
}

// recoveredUp holds what `cyfr up` must leave after recovering the
// interrupted switch: recovery first (its stop of the running cyfr, then
// two reads of the project, before any start), its start of the committed
// head, then the up's own start; .env's head running, a completed receipt
// for the interrupted request holding that head, and no journal or
// materialized configuration left.
func recoveredUp(t *testing.T, docker *stateDocker, id, out string) {
	t.Helper()
	calls := docker.calls()
	stop := slices.IndexFunc(calls, func(c string) bool { return strings.HasPrefix(c, "stop ") })
	var ups, reads []int
	for i, c := range calls {
		switch {
		case strings.HasPrefix(c, "compose ") && strings.Contains(c, " up "):
			ups = append(ups, i)
		case strings.HasPrefix(c, "ps ") && strings.Contains(c, "label=com.docker.compose.project="):
			reads = append(reads, i)
		}
	}
	readsBefore := 0
	for _, r := range reads {
		if stop >= 0 && r > stop && len(ups) > 0 && r < ups[0] {
			readsBefore++
		}
	}
	if stop < 0 || len(ups) < 2 || stop > ups[0] || readsBefore < 2 {
		t.Errorf("cyfr up did not recover first (stop at %d, %d reads after it, starts at %v):\n%s", stop, readsBefore, ups, strings.Join(calls, "\n"))
	}
	recovered, started := strings.Index(out, "Recovered: The change of how this home is reached (request "+id+") is done."), strings.Index(out, "CYFR server started.")
	if recovered < 0 || started < recovered {
		t.Errorf("cyfr up did not report the recovered change before its own start:\n%s", out)
	}

	e, err := reach.Open(".", docker)
	if err != nil {
		t.Fatal(err)
	}
	head, err := e.Head()
	if err != nil || head.Mode != reach.ModePublic || head.Host != "cyfr.example.com" {
		t.Errorf(".env holds %+v (%v), want the switch's public head", head, err)
	}
	rec, ok, err := e.Receipt(id)
	if err != nil || !ok || rec.State != "completed" || rec.Outcome != "ok" || rec.FinalHead == nil || rec.FinalHead.Digest() != head.Digest() {
		t.Errorf("the interrupted request's receipt is %+v (found %v, %v), want completed ok with .env's head", rec, ok, err)
	}
	if running := docker.running(); !slices.Contains(running, "cyfr") || !slices.Contains(running, "caddy") {
		t.Errorf("%v run, want cyfr and the public head's caddy", running)
	}
	for _, pattern := range []string{"journal.json", "compose.resolved.*"} {
		if left, _ := filepath.Glob(filepath.Join(".cyfr", pattern)); len(left) != 0 {
			t.Errorf("cyfr up left %v", left)
		}
	}
}

// `cyfr up` of a home whose switch a dead cyfr left unfinished, through
// the real engine: recovery runs first, under the lock, stopping and
// verifying what runs before anything starts, rolls the committed switch
// forward and writes its receipt, then the up starts the home as .env says,
// in process and as the cyfr process alike.
func TestUpRecoversAnInterruptedSwitchThroughTheRealEngine(t *testing.T) {
	requireCompose(t)
	t.Run("in process", func(t *testing.T) {
		docker, _, id := interruptedSwitch(t)
		useRealEngine(t, docker)
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()
		var out bytes.Buffer
		if err := runUp(ctx, &out); err != nil {
			t.Fatalf("cyfr up: %v\n%s", err, out.String())
		}
		recoveredUp(t, docker, id, out.String())
	})
	t.Run("as the cyfr process", func(t *testing.T) {
		docker, dir, id := interruptedSwitch(t)
		stdout, stderr, status := runAsCyfr(t, "real-state", dir, "up")
		if status != 0 {
			t.Fatalf("cyfr up exited %d:\n%s\n%s", status, stdout, stderr)
		}
		recoveredUp(t, docker, id, stdout)
	})
}

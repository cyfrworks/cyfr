// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build unix

package reach

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// requireCompose skips t, naming why, where `docker compose version`
// fails: t asks real Docker Compose. The macOS runner has no Docker;
// codex-ci.yml's Linux job has it and requires every test that calls
// this to pass.
func requireCompose(t *testing.T) {
	t.Helper()
	if out, err := exec.Command("docker", "compose", "version").CombinedOutput(); err != nil {
		t.Skipf("needs real Docker Compose, and `docker compose version` failed: %v\n%s", err, out)
	}
}

// realHome is a home with the shipped compose file and .env.example's
// .env, its engine on the real docker.
func realHome(t *testing.T) (*Engine, string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "home")
	os.Mkdir(dir, 0o755)
	writeFile(t, filepath.Join(dir, "docker-compose.yml"), repoFile(t, "docker-compose.yml"))
	writeFile(t, filepath.Join(dir, ".env"), repoFile(t, ".env.example"))
	e, err := Open(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	return e, dir
}

// The positive case against real compose: reach keys reaching cyfr only
// through env_file: .env pass, sources and effective values alike.
func TestRealComposeCheckStackAcceptsReachKeysThroughEnvFile(t *testing.T) {
	requireCompose(t)
	e, _ := realHome(t)
	if err := e.CheckStack(bg); err != nil {
		t.Fatalf("the shipped stack is refused: %v", err)
	}
}

// The negative case: an override that sets CYFR_HOST in cyfr's
// environment, to the very value .env holds, is refused naming the
// override. Compose's flattened configuration is the same with and
// without it, so only the sources show it.
func TestRealComposeCheckStackRefusesAnOverrideSettingAHeadKey(t *testing.T) {
	requireCompose(t)
	e, dir := realHome(t)
	h, err := e.Head()
	if err != nil {
		t.Fatal(err)
	}
	without, err := e.flatten(bg, h)
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "docker-compose.override.yml"), []byte("services:\n  cyfr:\n    environment:\n      - CYFR_HOST=localhost\n"))
	with, err := e.flatten(bg, h)
	if err != nil {
		t.Fatal(err)
	}
	a, _ := parseConfig(without)
	b, _ := parseConfig(with)
	if ea, eb := cyfrEnv(a), cyfrEnv(b); ea["CYFR_HOST"] != "localhost" || eb["CYFR_HOST"] != "localhost" {
		t.Fatalf("compose flattens CYFR_HOST as %q and %q", ea["CYFR_HOST"], eb["CYFR_HOST"])
	}
	if err := e.checkEffective(h, with); err != nil {
		t.Fatalf("the flattened values alone are refused: %v", err)
	}
	err = e.CheckStack(bg)
	var r *Refusal
	if !asRefusal(err, &r) || r.Code != "compose_override_refused" || r.Message() != overrideSets("docker-compose.override.yml", "cyfr", "CYFR_HOST") {
		t.Fatalf("CheckStack answered %v", err)
	}
}

// boxProject is a project directory named uniquely, so its compose
// project collides with no one else's on a shared host.
func boxProject(t *testing.T, compose, env string) (string, string) {
	t.Helper()
	b := make([]byte, 6)
	rand.Read(b)
	name := "reachs1" + hex.EncodeToString(b)
	dir := filepath.Join(t.TempDir(), name)
	os.Mkdir(dir, 0o755)
	writeFile(t, filepath.Join(dir, "compose.yml"), []byte(compose))
	writeFile(t, filepath.Join(dir, ".env"), []byte(env))
	t.Cleanup(func() {
		out, _ := exec.Command("docker", "ps", "-aq", "--filter", "label=com.docker.compose.project="+name).Output()
		if ids := strings.Fields(string(out)); len(ids) > 0 {
			exec.Command("docker", append([]string{"rm", "-f"}, ids...)...).Run()
		}
		exec.Command("docker", "network", "rm", name+"_default").Run()
	})
	return dir, name
}

// The lock stays held while a real `docker compose` call runs, and
// after the command that started it is killed, as flock -n from outside
// shows, until the call ends.
func TestRealComposeCallHoldsTheLock(t *testing.T) {
	requireCompose(t)
	requireDocker(t)
	dir, name := boxProject(t, "services:\n  box:\n    image: busybox:latest\n    network_mode: none\n", "")
	ready := filepath.Join(t.TempDir(), "ready")
	cmd := exec.Command(exeOrSkip(t), "-reach.holder", dir, ready, "docker",
		"compose", "-p", name, "-f", "compose.yml", "--project-directory", ".", "run", "--rm", "--no-deps", "box", "sleep", "6")
	cmd.Env = childEnv()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	waitFor(t, 60*time.Second, "the compose call's container", func() bool {
		out, _ := exec.Command("docker", "ps", "-q", "--filter", "label=com.docker.compose.project="+name).Output()
		return len(strings.TrimSpace(string(out))) > 0
	})
	if !heldFromOutside(t, dir) {
		t.Fatal("the lock is free while its holder's compose call runs")
	}
	cmd.Process.Kill()
	cmd.Wait()
	if !heldFromOutside(t, dir) {
		t.Fatal("the lock went with its holder while the compose call ran")
	}
	waitFor(t, 60*time.Second, "the lock to free once the compose call ended", func() bool { return !heldFromOutside(t, dir) })
}

// A stack shaped like the product's, on busybox: the one start path runs
// real compose on the materialized file, its explicit selection and
// cyfr's Docker health; a switch then starts the public profile's proxy;
// a full stop leaves nothing running and no materialized file.
func TestRealComposeRunsTheMaterializedConfiguration(t *testing.T) {
	requireCompose(t)
	requireDocker(t)
	compose := `services:
  cyfr:
    image: busybox:latest
    init: true
    command: ["sleep", "600"]
    env_file:
      - .env
    environment:
      - CYFR_BIND_ADDRESS=172.16.230.2
      - CYFR_LOCAL_INGRESS_ASSERTED=true
    healthcheck:
      test: ["CMD", "true"]
      interval: 1s
      start_period: 1s
  proxy:
    image: busybox:latest
    init: true
    command: ["sleep", "600"]
    profiles: ["public"]
`
	dir, name := boxProject(t, compose, "CYFR_REACH=local\nCYFR_HOST=localhost\nCYFR_PORT=4000\n")
	e, err := Open(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	sys := e.docker.(*systemDocker)
	sys.watchdog, sys.environ = []string{exeOrSkip(t), "-reach.watchdog"}, func() []string { return childEnv() }
	unlock, err := e.Lock("test")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if rc, err := e.Start(bg, "up"); err != nil || rc.Outcome != "ok" {
		t.Fatalf("start answered %+v, %v", rc, err)
	}
	services := func() []string {
		cs, err := e.observe(bg)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, c := range cs {
			if running(c.State) {
				out = append(out, c.Service)
			}
		}
		slices.Sort(out)
		return out
	}
	if got := services(); !slices.Equal(got, []string{"cyfr"}) {
		t.Errorf("running %v", got)
	}
	p, err := e.Preview(bg, Target{Mode: ModePublic, Domain: "home.example.com"}, "")
	if err != nil {
		t.Fatal(err)
	}
	if rc, err := e.Switch(bg, SwitchRequest{ID: id(1), Target: Target{Mode: ModePublic, Domain: "home.example.com"}, OldDigest: p.OldDigest, NewDigest: p.NewDigest}); err != nil || rc.Outcome != "ok" {
		t.Fatalf("switch answered %+v, %v", rc, err)
	}
	if got := services(); !slices.Equal(got, []string{"cyfr", "proxy"}) {
		t.Errorf("running %v after the switch", got)
	}
	out, _ := exec.Command("docker", "inspect", "--format", `{{range .Config.Env}}{{println .}}{{end}}`, name+"-cyfr-1").Output()
	if !strings.Contains(string(out), "CYFR_REACH=public\n") || !strings.Contains(string(out), "CYFR_HOST=home.example.com\n") {
		t.Errorf("cyfr started with\n%s", out)
	}
	if rc, err := e.Stop(bg, "down", true); err != nil || rc.Outcome != "ok" {
		t.Fatalf("stop answered %+v, %v", rc, err)
	}
	if got := services(); len(got) != 0 {
		t.Errorf("running %v after the stop", got)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, stateDir, resolvedGlob)); len(left) != 0 {
		t.Errorf("materialized files are left: %v", left)
	}
}

// Compose's own diagnostics quote .env's text: a malformed line holding a
// database credential, or a secret interpolated into a value compose
// cannot convert. CheckStack reports what failed, by file and line or by
// configuration path, never that text.
func TestRealComposeDiagnosticsCarryNoEnvValue(t *testing.T) {
	requireCompose(t)
	const secret = "sentinel-secret-from-env"
	for name, c := range map[string]struct{ env, override, says string }{
		"unterminated quote": {env: "DATABASE_URL=\"postgres://alice:" + secret + "@localhost/db\n", says: "it could not read .env at line "},
		"no separator":       {env: "DATABASE_URL postgres://alice:" + secret + "@localhost/db\n", says: "it could not read .env at line "},
		"bad name":           {env: "BROKEN! " + secret + " =value\n", says: "it could not read .env at line "},
		"conversion":         {env: "CYFR_LIMIT=" + secret + "\n", override: "services:\n  cyfr:\n    deploy:\n      resources:\n        limits:\n          cpus: ${CYFR_LIMIT}\n", says: "it refused the value of services[cyfr].deploy.resources.limits.cpus"},
	} {
		t.Run(name, func(t *testing.T) {
			e, dir := realHome(t)
			data, _ := os.ReadFile(filepath.Join(dir, ".env"))
			writeFile(t, filepath.Join(dir, ".env"), append(data, []byte(c.env)...))
			if c.override != "" {
				writeFile(t, filepath.Join(dir, "docker-compose.override.yml"), []byte(c.override))
			}
			err := e.CheckStack(bg)
			if err == nil {
				t.Fatal("the stack was accepted")
			}
			if strings.Contains(err.Error(), secret) || !strings.Contains(err.Error(), c.says) {
				t.Errorf("CheckStack's error reads %v", err)
			}
		})
	}
}

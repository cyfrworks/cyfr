// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"os/signal"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/version"
	"gopkg.in/yaml.v3"
)

// `cyfr update` reads each service of the bundled stack a project's compose
// file lacks, the guards among them, and the shipped compose file lacks
// none.
func TestMissingStackServices(t *testing.T) {
	if got := missingStackServices(filepath.Join("..", "..", "..", "docker-compose.yml")); got != nil {
		t.Errorf("the shipped docker-compose.yml lacks %v", got)
	}

	path := filepath.Join(t.TempDir(), "docker-compose.yml")
	old := `services:
  cyfr:
    image: ghcr.io/cyfrworks/cyfr:latest
  locus-backends:
    image: ghcr.io/cyfrworks/cyfr-locus:latest
  caddy:
    image: caddy:2.11-alpine
    profiles: ["tls"]
`
	if err := os.WriteFile(path, []byte(old), 0644); err != nil {
		t.Fatal(err)
	}
	if got := missingStackServices(path); !slices.Equal(got, []string{"locus-runtime", "locus-builds", "locus-builds-guard", "locus-backends-guard"}) {
		t.Errorf("a compose file with cyfr, locus-backends and caddy lacks %v", got)
	}

	if got := missingStackServices(filepath.Join(t.TempDir(), "missing.yml")); got != nil {
		t.Errorf("a missing compose file lacks %v", got)
	}
}

// unsetenv unsets key for the test and restores it after.
func unsetenv(t *testing.T, key string) {
	t.Setenv(key, "")
	os.Unsetenv(key)
}

// `cyfr update` writes nothing to the shipped docker-compose.yml: its cyfr
// service has every field update requires, its port among them, whatever
// CYFR_PORT the project's .env sets.
func TestUpdateLeavesShippedComposeAlone(t *testing.T) {
	shipped, err := os.ReadFile(filepath.Join("..", "..", "..", "docker-compose.yml"))
	if err != nil {
		t.Fatal(err)
	}
	unsetenv(t, "CYFR_PORT")
	for _, env := range []string{"", "CYFR_PORT=4000\n", "CYFR_PORT=5000\n"} {
		dir := t.TempDir()
		path := filepath.Join(dir, "docker-compose.yml")
		if err := os.WriteFile(path, shipped, 0644); err != nil {
			t.Fatal(err)
		}
		if env != "" {
			if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(env), 0644); err != nil {
				t.Fatal(err)
			}
		}
		if added, err := ensureCyfrComposeFields(path); err != nil || added != nil {
			t.Errorf(".env %q: update added %q (error %v)", env, added, err)
		}
		if got, err := os.ReadFile(path); err != nil || !bytes.Equal(got, shipped) {
			t.Errorf(".env %q: update rewrote the shipped docker-compose.yml (error %v)", env, err)
		}
	}
}

// Every form compose accepts for a `ports` entry reads as the container port
// and protocol compose publishes, its variables expanded as compose expands
// them; an entry compose refuses does not read.
func TestPublishedPort(t *testing.T) {
	env := map[string]string{"CYFR_PORT": "5000", "EMPTY": ""}
	lookup := func(name string) (string, bool) {
		value, ok := env[name]
		return value, ok
	}
	cases := []struct {
		entry string
		want  portSpec
		ok    bool
	}{
		{`"4000"`, portSpec{4000, 4000, "tcp"}, true},
		{`4000`, portSpec{4000, 4000, "tcp"}, true},
		{`"8080:4000"`, portSpec{4000, 4000, "tcp"}, true},
		{`"127.0.0.1:4000:4000"`, portSpec{4000, 4000, "tcp"}, true},
		{`"127.0.0.1::4000"`, portSpec{4000, 4000, "tcp"}, true},
		{`"[::1]:4000:4000"`, portSpec{4000, 4000, "tcp"}, true},
		{`"::1:4000:4000"`, portSpec{4000, 4000, "tcp"}, true},
		{`"4000/udp"`, portSpec{4000, 4000, "udp"}, true},
		{`"127.0.0.1:4000:4000/TCP"`, portSpec{4000, 4000, "tcp"}, true},
		{`"4000:4000/"`, portSpec{4000, 4000, "tcp"}, true},
		{`"3999-4001:3999-4001"`, portSpec{3999, 4001, "tcp"}, true},
		{`"127.0.0.1:${CYFR_PORT:-4000}:${CYFR_PORT:-4000}"`, portSpec{5000, 5000, "tcp"}, true},
		{`"127.0.0.1:${UNSET:-4000}:${UNSET:-4000}"`, portSpec{4000, 4000, "tcp"}, true},
		{`"${EMPTY:-4000}"`, portSpec{4000, 4000, "tcp"}, true},
		{`"${UNSET-4000}"`, portSpec{4000, 4000, "tcp"}, true},
		{`"${EMPTY-4000}"`, portSpec{}, false},
		{`"${CYFR_PORT}"`, portSpec{5000, 5000, "tcp"}, true},
		{`"$CYFR_PORT:$CYFR_PORT/udp"`, portSpec{5000, 5000, "udp"}, true},
		{`"${UNSET:-${CYFR_PORT:-4000}}"`, portSpec{5000, 5000, "tcp"}, true},
		{`"${CYFR_PORT:+4001}"`, portSpec{4001, 4001, "tcp"}, true},
		{`"${EMPTY+4001}"`, portSpec{4001, 4001, "tcp"}, true},
		{`"${EMPTY:+4001}"`, portSpec{}, false},
		{`"${UNSET+4001}"`, portSpec{}, false},
		{`"${CYFR_PORT:?set CYFR_PORT}"`, portSpec{5000, 5000, "tcp"}, true},
		{`"${UNSET:?set UNSET}"`, portSpec{}, false},
		{`"${EMPTY:?set EMPTY}"`, portSpec{}, false},
		{`"$$4000"`, portSpec{}, false},
		{`"${CYFR_PORT"`, portSpec{}, false},
		{`"${}"`, portSpec{}, false},
		{`"${CYFR_PORT!4000}"`, portSpec{}, false},
		{`"4001-4000"`, portSpec{}, false},
		{`"70000"`, portSpec{}, false},
		{`"4000:"`, portSpec{}, false},
		{`{target: 4000, published: "8080"}`, portSpec{4000, 4000, "tcp"}, true},
		{`{target: "${CYFR_PORT:-4000}", host_ip: 127.0.0.1, published: "4000", protocol: UDP, mode: host}`, portSpec{5000, 5000, "udp"}, true},
		{`{published: "4000"}`, portSpec{}, false},
		{`[4000]`, portSpec{}, false},
	}
	for _, c := range cases {
		var doc yaml.Node
		if err := yaml.Unmarshal([]byte(c.entry), &doc); err != nil {
			t.Fatalf("%s: %v", c.entry, err)
		}
		if got, ok := publishedPort(doc.Content[0], lookup); got != c.want || ok != c.ok {
			t.Errorf("%s reads as %v (ok %v), want %v (ok %v)", c.entry, got, ok, c.want, c.ok)
		}
	}
}

// `cyfr update` adds the shipped port line only to a cyfr service that
// publishes no container port of CYFR_PORT's value over tcp, that value taken
// from the environment over the project's .env as compose takes it, an alias
// entry read as the entry it names. It leaves a ports list holding an entry it
// cannot read as it is, and adds nothing when CYFR_PORT does not read as a
// port.
func TestUpdateEnsuresPublishedPort(t *testing.T) {
	shippedLine := requiredPorts[0]
	// Every compose file carries these anchors, for the cases' ports lists
	// to name.
	anchors := "x-ports:\n  - &cyfr \"127.0.0.1:4000:4000\"\n  - &long {target: 4000}\n  - &other \"9090:9090\"\n  - &udp \"4000:4000/udp\"\n"
	cases := []struct {
		ports, env, process string
		added               bool
	}{
		{ports: `["127.0.0.1:4000:4000"]`},
		{ports: `["4000:4000"]`, env: "CYFR_PORT=4000\n"},
		{ports: `["5000:5000"]`, env: "CYFR_PORT=5000\n"},
		{ports: `["3990-4010:3990-4010"]`},
		{ports: `[{target: 4000, published: "4000"}]`},
		{ports: `["4000:4000"]`, env: "CYFR_PORT=5000\n", process: "4000"},
		{ports: `["${UNSET:?set UNSET}"]`},
		{ports: `[*cyfr]`},
		{ports: `[*other, *long]`},
		{env: "CYFR_PORT=abc\n"},
		{ports: `["4000:4000"]`, env: "CYFR_PORT=5000\n", added: true},
		{ports: `["4000:4000/udp"]`, added: true},
		{ports: `["8080:8080"]`, added: true},
		{ports: `[*other, *udp]`, added: true},
		{added: true},
	}
	for _, c := range cases {
		if c.process == "" {
			unsetenv(t, "CYFR_PORT")
		} else {
			t.Setenv("CYFR_PORT", c.process)
		}
		dir := t.TempDir()
		path := filepath.Join(dir, "docker-compose.yml")
		compose := anchors + "services:\n  cyfr:\n    container_name: cyfr\n    volumes: [./data:/app/data, ./aqua:/app/seed/aqua]\n    env_file: [.env]\n"
		if c.ports != "" {
			compose += "    ports: " + c.ports + "\n"
		}
		if err := os.WriteFile(path, []byte(compose), 0644); err != nil {
			t.Fatal(err)
		}
		if c.env != "" {
			if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(c.env), 0644); err != nil {
				t.Fatal(err)
			}
		}
		added, err := ensureCyfrComposeFields(path)
		if err != nil {
			t.Fatalf("ports %s, .env %q: %v", c.ports, c.env, err)
		}
		got, _ := os.ReadFile(path)
		if c.added {
			if !slices.Equal(added, []string{"ports: " + shippedLine}) || !strings.Contains(string(got), shippedLine) {
				t.Errorf("ports %s, .env %q, CYFR_PORT %q: update added %q, writing\n%s", c.ports, c.env, c.process, added, got)
			}
		} else if added != nil || string(got) != compose {
			t.Errorf("ports %s, .env %q, CYFR_PORT %q: update added %q", c.ports, c.env, c.process, added)
		}
	}
}

// `cyfr update` writes the whole compose file back when it adds a field to
// cyfr, and the Locus services keep their hardening: the shared
// x-locus-role block, each worker's merge of it, each guard's own keys
// (a guard merges no role block), and every key each service runs with.
func TestEnsureCyfrComposeFieldsKeepsTheLocusRoleBlock(t *testing.T) {
	shipped, err := os.ReadFile(filepath.Join("..", "..", "..", "docker-compose.yml"))
	if err != nil {
		t.Fatal(err)
	}
	const aqua = "      - ./aqua:/app/seed/aqua\n"
	if n := strings.Count(string(shipped), aqua); n != 1 {
		t.Fatalf("the shipped docker-compose.yml names cyfr's aqua volume %d times, want once", n)
	}
	input := strings.Replace(string(shipped), aqua, "", 1)

	path := filepath.Join(t.TempDir(), "docker-compose.yml")
	if err := os.WriteFile(path, []byte(input), 0644); err != nil {
		t.Fatal(err)
	}
	added, err := ensureCyfrComposeFields(path)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(added, "volumes: ./aqua:/app/seed/aqua") {
		t.Fatalf("added %v, without cyfr's aqua volume, so nothing was written", added)
	}
	output, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	var root yaml.Node
	if err := yaml.Unmarshal(output, &root); err != nil {
		t.Fatalf("the written docker-compose.yml is not YAML: %v", err)
	}
	doc := root.Content[0]
	role := mapValue(doc, "x-locus-role")
	if role == nil || role.Kind != yaml.MappingNode || role.Anchor != "locus-role" {
		t.Fatalf("the written docker-compose.yml has no x-locus-role block anchored &locus-role")
	}
	services := mapValue(doc, "services")
	for _, name := range bundledServices {
		merge := mapValue(mapValue(services, name), "<<")
		if guard := strings.HasSuffix(name, "-guard"); guard && merge != nil {
			t.Errorf("the written %s merges %v; a guard runs with its own keys alone", name, merge.Value)
		} else if !guard && (merge == nil || merge.Kind != yaml.AliasNode || merge.Alias != role) {
			t.Errorf("the written %s does not merge *locus-role", name)
		}
	}

	var before, after map[string]any
	if err := yaml.Unmarshal([]byte(input), &before); err != nil {
		t.Fatal(err)
	}
	if err := yaml.Unmarshal(output, &after); err != nil {
		t.Fatal(err)
	}
	for _, name := range bundledServices {
		was := before["services"].(map[string]any)[name]
		is := after["services"].(map[string]any)[name]
		if was == nil || !reflect.DeepEqual(was, is) {
			t.Errorf("the written %s runs as\n%v\nwant\n%v", name, is, was)
		}
	}
}

// ---- the update ceremony, against a fake docker ---------------------------

// fakeDocker stands in for docker on PATH. It appends each invocation's
// argv to $FAKE_DOCKER_DIR/log, noting for every `-e NAME` whether NAME was
// in its environment (never the value) and whether it runs in a process
// group of its own; it appends the compose file's hash and the count of
// complete snapshots at the call to state. It answers each call from the
// scenario's files: <key>.out on stdout and <key>.exit as its status;
// <key>.signal sends SIGTERM to the updating process first and <key>.block
// waits for <key>.release. eval.live answers that many live reads first.
const fakeDocker = `#!/bin/bash
d="$FAKE_DOCKER_DIR"
note=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[i]}" = -e ]; then
    name="${args[i+1]}"
    if [ -n "${!name+x}" ]; then note+=" {env $name set}"; else note+=" {env $name unset}"; fi
  fi
done
read -r _ _ _ _ pgrp _ < /proc/$$/stat
[ "$pgrp" = "$$" ] || note+=" {shared process group}"
printf '%s%s\n' "$*" "$note" >> "$d/log"
answer() {
  printf '%s %s %s\n' "$1" "$(md5sum < docker-compose.yml | cut -c1-32)" "$(ls backups/*/snapshot.json 2>/dev/null | wc -l)" >> "$d/state"
  [ -f "$d/$1.signal" ] && kill -TERM "$PPID"
  if [ -f "$d/$1.block" ]; then while [ ! -f "$d/$1.release" ]; do sleep 0.02; done; fi
  [ -f "$d/$1.out" ] && cat "$d/$1.out"
  exit "$(cat "$d/$1.exit" 2>/dev/null || echo 0)"
}
if [ "$1" = compose ]; then
  shift
  while [ "$1" = --profile ]; do shift 2; done
  sub="$1"
  shift
  case "$sub" in
    exec) answer rpc ;;
    stop) answer "stop-${1:-all}" ;;
    run)
      n="$(cat "$d/eval.live" 2>/dev/null || echo 0)"
      if [ "$n" -gt 0 ]; then
        echo $((n - 1)) > "$d/eval.live"
        cat "$d/eval-live.out"
        exit 0
      fi
      answer eval ;;
    *) answer "$sub" ;;
  esac
fi
case "$1" in
  pull)
    if [ -f "$d/pull.fail" ] && [[ "$2" == *"$(cat "$d/pull.fail")"* ]]; then exit 1; fi
    answer pull ;;
  run)
    case "$*" in
      *psql*) answer probe ;;
      *pg_dump*) answer dump ;;
    esac ;;
esac
exit 0
`

const (
	testVersion = "0.9.0"
	testRoster  = `{:ok, rows} = Arca.ControlPlane.roster(); IO.puts("CYFR_ROSTER=" <> JSON.encode!(%{self: Atom.to_string(node()), release: Prima.Version.current(), slots: Enum.map(rows, fn r -> %{node: r.node, owner: r.owner, release: r.release, lease_until: DateTime.to_iso8601(r.lease_until)} end)}))`
	testLive    = `IO.puts("CYFR_LIVE_SLOTS=" <> JSON.encode!(%{release: Prima.Version.current(), slots: Cyfr.Release.live_slots()}))`
	keyBase     = "kb-secret-0123456789abcdef"
	keyring     = `{"keys":[{"id":"k1","key":"keyring-secret-value"}]}`
	pgPassword  = "pg-secret-pw-77"
	pgURL       = "postgres://cyfr:" + pgPassword + "@127.0.0.1:5432/cyfr"
)

var (
	digestCyfr  = "sha256:" + strings.Repeat("a", 64)
	digestLocus = "sha256:" + strings.Repeat("b", 64)
	digestCaddy = "sha256:" + strings.Repeat("c", 64)
	takenAt     = time.Date(2026, 10, 16, 12, 0, 0, 0, time.UTC)
)

// updateScenario is one update's project directory and fake docker.
type updateScenario struct {
	t        *testing.T
	project  string
	fake     string
	compose  []byte
	scaffold int
}

// shippedCompose is the repository's docker-compose.yml.
func shippedCompose(t *testing.T) []byte {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "docker-compose.yml"))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// newUpdateScenario makes a project directory holding compose, a SQLite
// cell's data and its .env, and a fake docker answering a running stack of
// every service with an empty offline roster.
func newUpdateScenario(t *testing.T, compose []byte, env map[string]string) *updateScenario {
	s := &updateScenario{t: t, project: t.TempDir(), fake: t.TempDir(), compose: compose}
	t.Chdir(s.project)
	write := func(path, data string, mode os.FileMode) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(data), mode); err != nil {
			t.Fatal(err)
		}
	}
	write("cyfr.yaml", "name: test\n", 0644)
	write(".env", "CYFR_BEHIND_PROXY=true\nCYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\nCYFR_PORT=4000\n", 0600)
	write("docker-compose.yml", string(compose), 0640)
	// Set apart from the umask, so the switch is seen to keep the mode.
	if err := os.Chmod("docker-compose.yml", 0640); err != nil {
		t.Fatal(err)
	}
	write("data/cyfr.db", "sqlite-main", 0644)
	write("data/cyfr.db-wal", "sqlite-wal", 0644)
	write("data/cyfr.db-shm", "sqlite-shm", 0644)
	write("data/components/acme/c.wasm", "component-bytes", 0644)
	write("data/blobs/x", "blob", 0600)
	if err := os.Symlink("components/acme", filepath.Join("data", "current")); err != nil {
		t.Fatal(err)
	}

	write(filepath.Join(s.fake, "docker"), fakeDocker, 0755)
	t.Setenv("PATH", s.fake+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_DOCKER_DIR", s.fake)

	environment := map[string]any{"CYFR_SECRET_KEY_BASE": keyBase, "CYFR_CRYPTO_KEYRING": keyring, "CYFR_HOST": "localhost"}
	for k, v := range env {
		environment[k] = v
	}
	config, _ := json.Marshal(map[string]any{"services": map[string]any{"cyfr": map[string]any{
		"environment": environment,
		"volumes": []map[string]any{
			{"type": "bind", "source": filepath.Join(s.project, "data"), "target": "/app/data", "bind": map[string]any{}},
			{"type": "bind", "source": filepath.Join(s.project, "aqua"), "target": "/app/seed/aqua"},
		},
	}}})
	s.answer("config.out", string(config))
	s.answer("ps.out", "locus-backends-guard\ncyfr\ncaddy\nlocus-runtime\nlocus-builds\nlocus-builds-guard\nlocus-backends\nsidecar\n")
	s.answer("rpc.out", "warming up\nCYFR_ROSTER="+`{"self":"cyfr@abc","release":"0.8.0","slots":[{"node":"cyfr@abc","owner":"o1","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"}]}`+"\n")
	s.answer("eval.out", "booting\nCYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[]}`+"\n")
	s.answer("eval-live.out", "CYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[{"node":"cyfr@abc","owner":"o1","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"}]}`+"\n")
	s.answer("probe.out", "180006\n")
	s.answer("dump.out", "PGDMP custom-format dump")

	oldVersion, oldFetch, oldScaffold, oldNow := version.Version, fetchManifest, updateScaffold, updateNow
	oldWindow, oldPoll := liveSlotsWindow, liveSlotsPoll
	t.Cleanup(func() {
		version.Version, fetchManifest, updateScaffold, updateNow = oldVersion, oldFetch, oldScaffold, oldNow
		liveSlotsWindow, liveSlotsPoll = oldWindow, oldPoll
	})
	version.Version = testVersion
	fetchManifest = func(ctx context.Context, v string) (*release.Manifest, error) {
		return &release.Manifest{Version: v, Images: release.Images{Cyfr: digestCyfr, CyfrLocus: digestLocus, Caddy: digestCaddy}}, nil
	}
	updateScaffold = func(v string) error {
		s.scaffold++
		f, err := os.OpenFile(filepath.Join(s.fake, "log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			return err
		}
		fmt.Fprintf(f, "SCAFFOLD %s\n", v)
		return f.Close()
	}
	updateNow = func() time.Time { return takenAt }
	liveSlotsWindow, liveSlotsPoll = 400*time.Millisecond, 20*time.Millisecond
	return s
}

// answer writes a scenario file of the fake docker.
func (s *updateScenario) answer(name, content string) {
	s.t.Helper()
	if err := os.WriteFile(filepath.Join(s.fake, name), []byte(content), 0644); err != nil {
		s.t.Fatal(err)
	}
}

// run runs `cyfr update` and answers its error and its output; the lock is
// gone after it and no docker child shared cyfr's process group.
func (s *updateScenario) run(ctx context.Context) (string, error) {
	s.t.Helper()
	var out bytes.Buffer
	err := runUpdate(ctx, &out, &out)
	if _, statErr := os.Lstat(filepath.Join(s.project, updateLockName)); !errors.Is(statErr, fs.ErrNotExist) {
		s.t.Errorf("the update lock is left behind (%v)", statErr)
	}
	for _, line := range s.log() {
		if strings.Contains(line, "{shared process group}") {
			s.t.Errorf("a docker child ran in cyfr's process group: %s", line)
		}
	}
	return out.String(), err
}

// log answers the fake docker's invocations, one per line.
func (s *updateScenario) log() []string {
	data, err := os.ReadFile(filepath.Join(s.fake, "log"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		s.t.Fatal(err)
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
}

// hasCall reports whether the log holds a call starting with prefix.
func (s *updateScenario) hasCall(prefix string) bool {
	return slices.ContainsFunc(s.log(), func(line string) bool { return strings.HasPrefix(line, prefix) })
}

// composeUnchanged fails unless docker-compose.yml is the scenario's bytes.
func (s *updateScenario) composeUnchanged() {
	s.t.Helper()
	if got, err := os.ReadFile(filepath.Join(s.project, "docker-compose.yml")); err != nil || !bytes.Equal(got, s.compose) {
		s.t.Errorf("docker-compose.yml changed (error %v)", err)
	}
}

// noBackups fails if the update made a backups directory.
func (s *updateScenario) noBackups() {
	s.t.Helper()
	if _, err := os.Lstat(filepath.Join(s.project, "backups")); !errors.Is(err, fs.ErrNotExist) {
		s.t.Errorf("the update made backups/ (%v)", err)
	}
}

func (s *updateScenario) snapshotDir() string {
	return filepath.Join(s.project, "backups", "20261016T120000Z")
}

// nothingStopped fails if any service was stopped, started or brought up.
func (s *updateScenario) nothingStopped() {
	s.t.Helper()
	for _, sub := range []string{"compose --profile tls --profile locus-builds stop", "compose --profile tls --profile locus-builds start", "compose --profile tls --profile locus-builds up"} {
		if s.hasCall(sub) {
			s.t.Errorf("the update ran %q:\n%s", sub, strings.Join(s.log(), "\n"))
		}
	}
}

// switched spells compose with every managed image line as the switch
// writes it: cyfr and cyfr-locus at the version and digest, the bundled
// Caddy at its own tag and the digest; every other line as it is.
func switched(compose []byte) []byte {
	lines := strings.SplitAfter(string(compose), "\n")
	for i, line := range lines {
		indent, value, ok := strings.Cut(line, "image: ")
		if !ok || strings.TrimSpace(indent) != "" {
			continue
		}
		value = strings.TrimRight(value, "\n")
		switch {
		case strings.HasPrefix(value, "ghcr.io/cyfrworks/cyfr:"):
			value = "ghcr.io/cyfrworks/cyfr:" + testVersion + "@" + digestCyfr
		case strings.HasPrefix(value, "ghcr.io/cyfrworks/cyfr-locus:"):
			value = "ghcr.io/cyfrworks/cyfr-locus:" + testVersion + "@" + digestLocus
		case strings.HasPrefix(value, "caddy:"):
			tag, _, _ := strings.Cut(strings.TrimPrefix(value, "caddy:"), "@")
			value = "caddy:" + tag + "@" + digestCaddy
		}
		lines[i] = indent + "image: " + value + "\n"
	}
	return []byte(strings.Join(lines, ""))
}

const profiles = "compose --profile tls --profile locus-builds "

// The happy path runs the six steps in their order: the configuration and
// the pulls by digest, the roster through the running cyfr, the scaffold
// (the one write before the stop, after every refusal), each service
// stopped in order, the offline re-read until no slot is live,
// the snapshot (snapshot.json last, 0700 and 0600), the image lines
// rewritten, and the start that waits for health.
func TestUpdateRunsTheCeremonyInOrder(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("eval.live", "1")
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	want := []string{
		profiles + "config --format json",
		"pull ghcr.io/cyfrworks/cyfr@" + digestCyfr,
		"pull ghcr.io/cyfrworks/cyfr-locus@" + digestLocus,
		"pull caddy@" + digestCaddy,
		profiles + "ps --services --status running",
		profiles + "exec -T cyfr bin/cyfr rpc " + testRoster,
		"SCAFFOLD " + testVersion,
		profiles + "stop caddy",
		profiles + "stop cyfr",
		profiles + "stop locus-runtime",
		profiles + "stop locus-builds",
		profiles + "stop locus-backends",
		profiles + "stop locus-builds-guard",
		profiles + "stop locus-backends-guard",
		profiles + "stop",
		profiles + "run --rm --no-deps -T cyfr bin/cyfr eval " + testLive,
		profiles + "run --rm --no-deps -T cyfr bin/cyfr eval " + testLive,
		profiles + "up -d --wait --wait-timeout 900",
	}
	if got := s.log(); !slices.Equal(got, want) {
		t.Fatalf("docker ran\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	// Before the switch every call saw the old compose file and no complete
	// snapshot; the start saw the switched file and the snapshot.
	sum := func(data []byte) string { return fmt.Sprintf("%x", md5.Sum(data)) }
	state, _ := os.ReadFile(filepath.Join(s.fake, "state"))
	for _, line := range strings.Split(strings.TrimSpace(string(state)), "\n") {
		fields := strings.Fields(line)
		wantSum, wantSnapshots := sum(s.compose), "0"
		if fields[0] == "up" {
			wantSum, wantSnapshots = sum(switched(s.compose)), "1"
		}
		if fields[1] != wantSum || fields[2] != wantSnapshots {
			t.Errorf("docker %s saw compose %s and %s snapshots, want %s and %s", fields[0], fields[1], fields[2], wantSum, wantSnapshots)
		}
	}

	got, err := os.ReadFile("docker-compose.yml")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, switched(s.compose)) {
		t.Errorf("the switched docker-compose.yml is\n%s", got)
	}
	if n := strings.Count(string(got), "@sha256:"); n != 7 {
		t.Errorf("the switched docker-compose.yml pins %d images, want 7 (cyfr, five cyfr-locus, caddy)", n)
	}
	if info, err := os.Stat("docker-compose.yml"); err != nil || info.Mode().Perm() != 0640 {
		t.Errorf("the switched docker-compose.yml's mode is %v (error %v), want 0640 kept", info.Mode().Perm(), err)
	}

	dir := s.snapshotDir()
	checkMode := func(path string, want os.FileMode) {
		t.Helper()
		info, err := os.Lstat(path)
		if err != nil || info.Mode().Perm() != want {
			t.Errorf("%s: mode %v (error %v), want %v", path, info.Mode().Perm(), err, want)
		}
	}
	checkMode(filepath.Join(s.project, "backups"), 0700)
	checkMode(dir, 0700)
	files := map[string]string{
		"database":                       "sqlite-main",
		"database-wal":                   "sqlite-wal",
		".env":                           "CYFR_BEHIND_PROXY=true\nCYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\nCYFR_PORT=4000\n",
		"storage/components/acme/c.wasm": "component-bytes",
		"storage/blobs/x":                "blob",
	}
	for name, content := range files {
		path := filepath.Join(dir, name)
		if data, err := os.ReadFile(path); err != nil || string(data) != content {
			t.Errorf("%s holds %q (error %v), want %q", name, data, err, content)
		}
		checkMode(path, 0600)
	}
	checkMode(filepath.Join(dir, "storage"), 0700)
	checkMode(filepath.Join(dir, "storage", "components"), 0700)
	if link, err := os.Readlink(filepath.Join(dir, "storage", "current")); err != nil || link != "components/acme" {
		t.Errorf("storage/current is %q (error %v), want the link components/acme", link, err)
	}
	for _, name := range []string{"cyfr.db", "cyfr.db-wal", "cyfr.db-shm"} {
		if _, err := os.Lstat(filepath.Join(dir, "storage", name)); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("storage/ holds the SQLite file %s (%v)", name, err)
		}
	}
	keyringFile, err := os.ReadFile(filepath.Join(dir, "keyring"))
	checkMode(filepath.Join(dir, "keyring"), 0600)
	if err != nil {
		t.Fatal(err)
	}
	parsed := parseEnvFile(string(keyringFile))
	for name, want := range map[string]string{"CYFR_CRYPTO_KEYRING": keyring, "CYFR_SECRET_KEY_BASE": keyBase} {
		if got, ok := parsed.value(name); !ok || got != want {
			t.Errorf("the keyring file reads %s as %q, want %q", name, got, want)
		}
	}
	var snapshot map[string]any
	data, err := os.ReadFile(filepath.Join(dir, "snapshot.json"))
	checkMode(filepath.Join(dir, "snapshot.json"), 0600)
	if err != nil || json.Unmarshal(data, &snapshot) != nil {
		t.Fatalf("snapshot.json: %s (error %v)", data, err)
	}
	wantSnapshot := map[string]any{
		"version":         "0.8.0",
		"taken_at":        "2026-10-16T12:00:00Z",
		"parts":           []any{"database", "database-wal", "storage", "keyring", ".env"},
		"storage_adapter": "local",
		"complete":        true,
	}
	if !reflect.DeepEqual(snapshot, wantSnapshot) {
		t.Errorf("snapshot.json is %v, want %v", snapshot, wantSnapshot)
	}
	entries, _ := os.ReadDir(dir)
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	if !slices.Equal(names, []string{".env", "database", "database-wal", "keyring", "snapshot.json", "storage"}) {
		t.Errorf("the snapshot holds %v", names)
	}

	for _, line := range []string{"stopped caddy in ", "stopped cyfr in ", "stopped locus-backends-guard in ", "stopped sidecar in ", "Updated to release 0.9.0.", "Snapshot of release 0.8.0: " + dir} {
		if !strings.Contains(out, line) {
			t.Errorf("the output lacks %q:\n%s", line, out)
		}
	}
	for _, secret := range []string{keyBase, "keyring-secret-value"} {
		if strings.Contains(out, secret) || strings.Contains(strings.Join(s.log(), "\n"), secret) {
			t.Errorf("a secret reached the output or a docker argv")
		}
	}
}

// On PostgreSQL the update reads the server's major through a postgres
// client container and dumps the database in that major's image, the URL
// reaching each container through its environment and never an argv.
func TestUpdateDumpsPostgresWithoutTheURLOnArgv(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL})
	if err := os.Remove(filepath.Join(s.project, "data", "cyfr.db-wal")); err != nil {
		t.Fatal(err)
	}
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	probe := `run --rm --network host -e CYFR_UPDATE_PG_URL postgres:18 sh -c exec psql "$CYFR_UPDATE_PG_URL" -tAc "SHOW server_version_num" {env CYFR_UPDATE_PG_URL set}`
	dump := `run --rm --network host -e CYFR_UPDATE_PG_URL postgres:18 sh -c exec pg_dump --format=custom --no-owner "$CYFR_UPDATE_PG_URL" {env CYFR_UPDATE_PG_URL set}`
	log := s.log()
	at := func(line string) int { return slices.Index(log, line) }
	if at(profiles+"config --format json") != 0 || at(probe) != 1 || at("pull postgres:18") < 2 || at("pull postgres:18") > at("SCAFFOLD 0.9.0") {
		t.Errorf("the probe does not run before the pulls, the dump image among them:\n%s", strings.Join(log, "\n"))
	}
	eval := at(profiles + "run --rm --no-deps -T cyfr bin/cyfr eval " + testLive)
	if at(dump) < eval || at(dump) > at(profiles+"up -d --wait --wait-timeout 900") {
		t.Errorf("the dump does not run between the offline read and the start:\n%s", strings.Join(log, "\n"))
	}
	whole := strings.Join(log, "\n") + out
	if strings.Contains(whole, pgPassword) || strings.Contains(whole, "127.0.0.1:5432") {
		t.Errorf("the database URL reached a docker argv or the output:\n%s", whole)
	}
	if data, err := os.ReadFile(filepath.Join(s.snapshotDir(), "database")); err != nil || string(data) != "PGDMP custom-format dump" {
		t.Errorf("database holds %q (error %v), want the dump", data, err)
	}
	var snapshot snapshotManifest
	data, _ := os.ReadFile(filepath.Join(s.snapshotDir(), "snapshot.json"))
	if json.Unmarshal(data, &snapshot) != nil || !slices.Equal(snapshot.Parts, []string{"database", "storage", "keyring", ".env"}) {
		t.Errorf("snapshot.json is %s", data)
	}
	// The SQLite files under the storage root are not the database here and
	// are copied with the rest of the root.
	if _, err := os.Stat(filepath.Join(s.snapshotDir(), "storage", "cyfr.db")); err != nil {
		t.Errorf("storage/ lacks the root's cyfr.db on PostgreSQL: %v", err)
	}
}

// With an S3 store the snapshot holds no storage/ and says why.
func TestUpdateSnapshotsWithoutTheS3Store(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_STORAGE": "s3"})
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	if !strings.Contains(out, "The object store (S3) is outside the snapshot; it relies on the bucket's own versioning.") {
		t.Errorf("the output lacks the S3 note:\n%s", out)
	}
	if _, err := os.Lstat(filepath.Join(s.snapshotDir(), "storage")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the snapshot holds storage/ with an S3 store (%v)", err)
	}
	var snapshot snapshotManifest
	data, _ := os.ReadFile(filepath.Join(s.snapshotDir(), "snapshot.json"))
	if json.Unmarshal(data, &snapshot) != nil || snapshot.StorageAdapter != "s3" || !slices.Equal(snapshot.Parts, []string{"database", "database-wal", "keyring", ".env"}) {
		t.Errorf("snapshot.json is %s", data)
	}
}

// A live slot of a node outside this stack refuses before anything stops.
func TestUpdateRefusesAForeignLiveSlot(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("rpc.out", "CYFR_ROSTER="+`{"self":"cyfr@abc","release":"0.8.0","slots":[{"node":"cyfr@abc","owner":"o1","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"},{"node":"cyfr@other-host","owner":"o2","release":"0.7.9","lease_until":"2026-10-16T12:00:12Z"}]}`+"\n")
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "cyfr@other-host (release 0.7.9)") || !strings.Contains(err.Error(), "stop it first") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	if !s.hasCall(profiles + "exec -T cyfr bin/cyfr rpc ") {
		t.Errorf("the update never read the roster")
	}
	// The refusal comes before the one write of the steps before the stop.
	if s.hasCall("SCAFFOLD ") {
		t.Errorf("the update refreshed the scaffold files before refusing:\n%s", strings.Join(s.log(), "\n"))
	}
	s.nothingStopped()
	s.composeUnchanged()
	s.noBackups()
}

// A compose file lacking a bundled service, each guard among them, refuses
// before any docker call, naming the service and `cyfr init --force`.
func TestUpdateRefusesAComposeMissingABundledService(t *testing.T) {
	for _, missing := range []string{"locus-runtime", "locus-builds", "locus-backends", "locus-builds-guard", "locus-backends-guard"} {
		t.Run(missing, func(t *testing.T) {
			var root yaml.Node
			if err := yaml.Unmarshal(shippedCompose(t), &root); err != nil {
				t.Fatal(err)
			}
			services := mapValue(root.Content[0], "services")
			for i := 0; i < len(services.Content); i += 2 {
				if services.Content[i].Value == missing {
					services.Content = slices.Delete(services.Content, i, i+2)
					break
				}
			}
			compose, err := yaml.Marshal(&root)
			if err != nil {
				t.Fatal(err)
			}
			s := newUpdateScenario(t, compose, nil)
			out, err := s.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), missing) || !strings.Contains(err.Error(), "Run 'cyfr init --force' to regenerate docker-compose.yml (.env is kept), then 'cyfr update' again.") {
				t.Fatalf("update answered %v\n%s", err, out)
			}
			if log := s.log(); log != nil {
				t.Errorf("docker ran before the refusal:\n%s", strings.Join(log, "\n"))
			}
			s.composeUnchanged()
			s.noBackups()
		})
	}
}

// A compose file that does not parse refuses; it never reads as one
// lacking nothing.
func TestUpdateRefusesAnUnreadableCompose(t *testing.T) {
	s := newUpdateScenario(t, []byte("services: [unclosed\n"), nil)
	_, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "not valid YAML") || s.log() != nil {
		t.Fatalf("update answered %v with docker calls %v", err, s.log())
	}
}

// A slot still live after the stop, past the lease window, restarts the old
// stack and refuses; the compose file is unchanged and no snapshot is taken.
func TestUpdateRestartsTheOldStackWhileASlotStaysLive(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("eval.live", "100000")
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "cyfr@abc (release 0.8.0)") || !strings.Contains(err.Error(), "old stack was started again") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	log := s.log()
	if last := log[len(log)-1]; last != profiles+"start" {
		t.Errorf("the update ended with %q, want the old stack's start", last)
	}
	if reads := strings.Count(strings.Join(log, "\n"), " eval "); reads < 2 {
		t.Errorf("the offline read ran %d times, want it repeated within the window", reads)
	}
	s.composeUnchanged()
	s.noBackups()
}

// An offline read that errs or does not answer restarts the old stack; a
// roster read that errs or does not answer refuses before anything stops.
// Neither reads as an empty roster.
func TestUpdateReadsNoAnswerAsNoRoster(t *testing.T) {
	bad := map[string]struct{ out, exit string }{
		"error":     {"CYFR_LIVE_SLOTS={\"release\":\"0.8.0\",\"slots\":[]}\n", "1"},
		"no line":   {"** (UndefinedFunctionError) function Cyfr.Release.live_slots/0 is undefined\n", "0"},
		"two lines": {"CYFR_LIVE_SLOTS={\"release\":\"0.8.0\",\"slots\":[]}\nCYFR_LIVE_SLOTS={\"release\":\"0.8.0\",\"slots\":[]}\n", "0"},
		"bad json":  {"CYFR_LIVE_SLOTS={\"release\":\"0.8.0\",\"slots\":\n", "0"},
		"no slots":  {"CYFR_LIVE_SLOTS={\"release\":\"0.8.0\"}\n", "0"},
	}
	for name, answer := range bad {
		t.Run("offline "+name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.answer("eval.out", answer.out)
			s.answer("eval.exit", answer.exit)
			out, err := s.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), "offline roster read") {
				t.Fatalf("update answered %v\n%s", err, out)
			}
			if log := s.log(); log[len(log)-1] != profiles+"start" {
				t.Errorf("the update did not restart the old stack:\n%s", strings.Join(log, "\n"))
			}
			s.composeUnchanged()
			s.noBackups()
		})
		t.Run("roster "+name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.answer("rpc.out", strings.ReplaceAll(strings.ReplaceAll(answer.out, "CYFR_LIVE_SLOTS=", "CYFR_ROSTER="), `"release"`, `"self":"cyfr@abc","release"`))
			s.answer("rpc.exit", answer.exit)
			out, err := s.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), "roster") {
				t.Fatalf("update answered %v\n%s", err, out)
			}
			s.nothingStopped()
			s.composeUnchanged()
			s.noBackups()
		})
	}
}

// A failed stop restarts the old stack.
func TestUpdateRestartsTheOldStackAfterAFailedStop(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("stop-locus-runtime.exit", "1")
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "stop locus-runtime failed") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	if log := s.log(); log[len(log)-1] != profiles+"start" || s.hasCall(profiles+"run") {
		t.Errorf("the update did not restart the old stack at once:\n%s", strings.Join(log, "\n"))
	}
	s.composeUnchanged()
	s.noBackups()
}

// A failed snapshot leaves the stack stopped and reports the reason and the
// partial snapshot: no start of the old stack, no switch.
func TestUpdateLeavesTheStackStoppedAfterAFailedSnapshot(t *testing.T) {
	t.Run("dump", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL})
		s.answer("dump.exit", "1")
		out, err := s.run(context.Background())
		if err == nil || !strings.Contains(err.Error(), "The snapshot failed: pg_dump in postgres:18 failed") || !strings.Contains(err.Error(), "left stopped") || !strings.Contains(err.Error(), s.snapshotDir()) {
			t.Fatalf("update answered %v\n%s", err, out)
		}
		if s.hasCall(profiles+"start") || s.hasCall(profiles+"up") {
			t.Errorf("the update started a stack after a failed snapshot:\n%s", strings.Join(s.log(), "\n"))
		}
		if _, err := os.Lstat(filepath.Join(s.snapshotDir(), "snapshot.json")); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("a failed snapshot has snapshot.json (%v)", err)
		}
		if strings.Contains(err.Error()+out, pgPassword) {
			t.Errorf("the refusal holds the database password")
		}
		s.composeUnchanged()
	})
	t.Run("existing directory", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		if err := os.MkdirAll(s.snapshotDir(), 0700); err != nil {
			t.Fatal(err)
		}
		out, err := s.run(context.Background())
		if err == nil || !strings.Contains(err.Error(), "The snapshot failed") || !strings.Contains(err.Error(), "file exists") {
			t.Fatalf("update answered %v\n%s", err, out)
		}
		if s.hasCall(profiles+"start") || s.hasCall(profiles+"up") {
			t.Errorf("the update started a stack after a failed snapshot")
		}
		if entries, _ := os.ReadDir(s.snapshotDir()); len(entries) != 0 {
			t.Errorf("the update wrote into an existing snapshot directory: %v", entries)
		}
		s.composeUnchanged()
	})
}

// A failed migration or health check after the switch leaves the stack
// stopped, never the old images started, and prints the snapshot and the
// restore command.
func TestUpdateLeavesTheStackStoppedWhenTheNewReleaseFails(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("up.exit", "1")
	out, err := s.run(context.Background())
	if err == nil {
		t.Fatalf("update succeeded\n%s", out)
	}
	if !strings.Contains(err.Error(), "left stopped") || !strings.Contains(err.Error(), "cyfr restore "+s.snapshotDir()) {
		t.Errorf("the refusal is %v", err)
	}
	log := s.log()
	if n := len(log); n < 2 || log[n-2] != profiles+"up -d --wait --wait-timeout 900" || log[n-1] != profiles+"stop" {
		t.Errorf("the update did not stop the stack after the failed start:\n%s", strings.Join(log, "\n"))
	}
	if s.hasCall(profiles + "start") {
		t.Errorf("the update started the old stack over the switch")
	}
	if _, err := os.Stat(filepath.Join(s.snapshotDir(), "snapshot.json")); err != nil {
		t.Errorf("the snapshot is not complete: %v", err)
	}
	if got, _ := os.ReadFile("docker-compose.yml"); !bytes.Equal(got, switched(s.compose)) {
		t.Errorf("docker-compose.yml is not the switched file")
	}
}

// A failed pull leaves the compose file unchanged and nothing stopped: the
// scaffold is not updated and no snapshot is taken.
func TestUpdateRefusesAFailedPull(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("pull.fail", "cyfr-locus@")
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "docker pull ghcr.io/cyfrworks/cyfr-locus@"+digestLocus+" failed") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	want := []string{profiles + "config --format json", "pull ghcr.io/cyfrworks/cyfr@" + digestCyfr, "pull ghcr.io/cyfrworks/cyfr-locus@" + digestLocus}
	if got := s.log(); !slices.Equal(got, want) {
		t.Errorf("docker ran\n%s", strings.Join(got, "\n"))
	}
	if s.scaffold != 0 {
		t.Errorf("the scaffold was updated after a failed pull")
	}
	s.composeUnchanged()
	s.noBackups()
}

// Only image lines naming a manifest repository are rewritten, the guards'
// and Caddy's among them; an override, an interpolated line and a
// look-alike repository are kept byte for byte and reported.
func TestUpdateRewritesOnlyManagedImageLines(t *testing.T) {
	shipped := string(shippedCompose(t))
	replaceImage := func(compose, service, image string) string {
		at := strings.Index(compose, "\n  "+service+":\n")
		if at < 0 {
			t.Fatalf("the shipped compose has no %s", service)
		}
		line := strings.Index(compose[at:], "    image: ") + at
		end := strings.IndexByte(compose[line:], '\n') + line
		return compose[:line] + "    image: " + image + compose[end:]
	}
	compose := replaceImage(shipped, "cyfr", "myregistry.example/cyfr:custom")
	compose = replaceImage(compose, "locus-builds", `"${LOCUS_IMAGE:-ghcr.io/cyfrworks/cyfr-locus:latest}"`)
	compose = replaceImage(compose, "locus-runtime", "ghcr.io/cyfrworks/cyfr-locus-dev:1")
	compose = replaceImage(compose, "locus-backends", "'ghcr.io/cyfrworks/cyfr-locus:latest' # quoted")
	s := newUpdateScenario(t, []byte(compose), nil)
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	want := replaceImage(compose, "locus-backends", "'ghcr.io/cyfrworks/cyfr-locus:"+testVersion+"@"+digestLocus+"' # quoted")
	want = replaceImage(want, "locus-builds-guard", "ghcr.io/cyfrworks/cyfr-locus:"+testVersion+"@"+digestLocus)
	want = replaceImage(want, "locus-backends-guard", "ghcr.io/cyfrworks/cyfr-locus:"+testVersion+"@"+digestLocus)
	_, caddyTag, _ := strings.Cut(string(regexp.MustCompile(`image: caddy:[^@\n]+`).Find([]byte(shipped))), "caddy:")
	want = replaceImage(want, "caddy", "caddy:"+caddyTag+"@"+digestCaddy)
	if got, _ := os.ReadFile("docker-compose.yml"); string(got) != want {
		t.Errorf("the switched docker-compose.yml is\n%s\nwant\n%s", got, want)
	}
	for _, line := range []string{
		"  cyfr: myregistry.example/cyfr:custom\n",
		"  locus-builds: ${LOCUS_IMAGE:-ghcr.io/cyfrworks/cyfr-locus:latest}\n",
		"  locus-runtime: ghcr.io/cyfrworks/cyfr-locus-dev:1\n",
	} {
		if !strings.Contains(out, line) {
			t.Errorf("the output does not report %q:\n%s", line, out)
		}
	}
	if s.hasCall("pull ghcr.io/cyfrworks/cyfr@") || !s.hasCall("pull ghcr.io/cyfrworks/cyfr-locus@"+digestLocus) || !s.hasCall("pull caddy@"+digestCaddy) {
		t.Errorf("the pulls are\n%s", strings.Join(s.log(), "\n"))
	}
}

// A repository is managed exactly when Docker resolves it to a manifest
// repository: no prefix match, no service name.
func TestManagedRepositories(t *testing.T) {
	cases := map[string]bool{
		"ghcr.io/cyfrworks/cyfr:latest":            true,
		"ghcr.io/cyfrworks/cyfr":                   true,
		"ghcr.io/cyfrworks/cyfr-locus:1@sha256:00": true,
		"ghcr.io/cyfrworks/cyfr-locus-x":           false,
		"ghcr.io/cyfrworks/cyfr-locus-dev:1":       false,
		"ghcr.io/cyfrworks/cyfrx":                  false,
		"ghcr.io/cyfrworks/cyfr/sub":               false,
		"ghcr.io:443/cyfrworks/cyfr":               false,
		"caddy":                                    true,
		"caddy:2.11-alpine":                        true,
		"library/caddy:2":                          true,
		"docker.io/caddy:2":                        true,
		"docker.io/library/caddy@sha256:00":        true,
		"index.docker.io/library/caddy":            true,
		"caddy-custom:2":                           false,
		"someone/caddy:2":                          false,
		"localhost/caddy":                          false,
		"localhost:5000/caddy":                     false,
		"myregistry.example/cyfr:custom":           false,
	}
	for ref, want := range cases {
		repo, _, _ := splitImageReference(ref)
		if got := slices.Contains(managedRepositories, normalizeRepository(repo)); got != want {
			t.Errorf("%s managed %v, want %v (normalized %s)", ref, got, want, normalizeRepository(repo))
		}
	}
}

// A manifest that does not verify refuses before any docker call; so does
// one the network cannot reach, naming the release, and a development build.
func TestUpdateRefusesAnUnverifiedManifest(t *testing.T) {
	cases := []struct {
		name  string
		err   error
		build string
		want  string
	}{
		{"unverified", fmt.Errorf("%w: wrong identity", release.ErrUnverified), testVersion, "The manifest of release 0.9.0 did not verify"},
		{"offline", errors.New("dial tcp: lookup github.com: no such host"), testVersion, "cyfr update needs network access to release 0.9.0's manifest"},
		{"dev", nil, "dev", "development build"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			version.Version = c.build
			if c.err != nil {
				fetchManifest = func(context.Context, string) (*release.Manifest, error) { return nil, c.err }
			}
			out, err := s.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("update answered %v\n%s", err, out)
			}
			if log := s.log(); log != nil {
				t.Errorf("docker ran:\n%s", strings.Join(log, "\n"))
			}
			s.composeUnchanged()
		})
	}
}

// A second update refuses while the first holds the lock, naming the file
// and the holder's pid; each run removes only its own lock.
func TestUpdateHoldsOneLock(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("pull.block", "")
	first := make(chan error, 1)
	go func() {
		err := runUpdate(context.Background(), io.Discard, io.Discard)
		first <- err
	}()
	deadline := time.Now().Add(10 * time.Second)
	for !s.hasCall("pull ") {
		if time.Now().After(deadline) {
			t.Fatal("the first update never reached its pull")
		}
		time.Sleep(10 * time.Millisecond)
	}
	var out bytes.Buffer
	err := runUpdate(context.Background(), &out, &out)
	lock := filepath.Join(s.project, updateLockName)
	if err == nil || !strings.Contains(err.Error(), lock) || !strings.Contains(err.Error(), fmt.Sprintf("pid %d", os.Getpid())) {
		t.Errorf("the second update answered %v", err)
	}
	if _, statErr := os.Stat(lock); statErr != nil {
		t.Errorf("the refused update removed the holder's lock: %v", statErr)
	}
	s.answer("pull.release", "")
	if err := <-first; err != nil {
		t.Fatalf("the first update: %v", err)
	}
	if _, err := os.Stat(lock); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the lock is left behind: %v", err)
	}
	if n := strings.Count(strings.Join(s.log(), "\n"), " up -d "); n != 1 {
		t.Errorf("the stack was switched %d times", n)
	}

	// A lock left by a process that died is named for its owner to clear.
	if err := os.WriteFile(lock, []byte("4242\n"), 0600); err != nil {
		t.Fatal(err)
	}
	err = runUpdate(context.Background(), io.Discard, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "pid 4242") || !strings.Contains(err.Error(), "remove the file") {
		t.Errorf("an update beside a stale lock answered %v", err)
	}
	if _, err := os.Stat(lock); err != nil {
		t.Errorf("the refused update removed the stale lock: %v", err)
	}
	os.Remove(lock)
}

// A signal before the stop ends the update with nothing changed; from the
// stop on, the running step finishes and the old stack starts again.
func TestUpdateOnASignal(t *testing.T) {
	cases := []struct {
		at, want string
		restart  bool
	}{
		{"pull", "interrupted before anything stopped", false},
		{"rpc", "interrupted before anything stopped", false},
		{"stop-cyfr", "interrupted during the stop", true},
		{"eval", "interrupted during the offline roster read", true},
	}
	for _, c := range cases {
		t.Run(c.at, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.answer(c.at+".signal", "")
			ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM)
			defer stop()
			out, err := s.run(ctx)
			select {
			case <-ctx.Done():
			case <-time.After(10 * time.Second):
				t.Fatal("the signal never arrived")
			}
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("update answered %v\n%s", err, out)
			}
			log := s.log()
			if c.restart {
				for _, svc := range []string{"caddy", "cyfr", "locus-runtime", "locus-backends-guard"} {
					if !slices.Contains(log, profiles+"stop "+svc) {
						t.Errorf("the stop step did not finish: no stop of %s", svc)
					}
				}
				if log[len(log)-1] != profiles+"start" {
					t.Errorf("the old stack was not started again:\n%s", strings.Join(log, "\n"))
				}
			} else {
				s.nothingStopped()
			}
			s.composeUnchanged()
			s.noBackups()
		})
	}
}

// The switch rewrites only image lines and ensureCyfrComposeFields keeps
// every block it does not own: x-locus-role, each worker's merge of it,
// each guard's own keys and every key a bundled service runs with besides
// its image.
func TestSwitchKeepsTheBundledServicesBlocks(t *testing.T) {
	shipped := shippedCompose(t)
	const aqua = "      - ./aqua:/app/seed/aqua\n"
	input := []byte(strings.Replace(string(shipped), aqua, "", 1))
	path := filepath.Join(t.TempDir(), "docker-compose.yml")
	if err := os.WriteFile(path, input, 0644); err != nil {
		t.Fatal(err)
	}
	m := &release.Manifest{Version: testVersion, Images: release.Images{Cyfr: digestCyfr, CyfrLocus: digestLocus, Caddy: digestCaddy}}
	plan, err := planCompose(path, m, testVersion)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(plan.rewritten, switched(input)) {
		t.Fatalf("the plan rewrites more than the image lines:\n%s", plan.rewritten)
	}
	if err := os.WriteFile(path, plan.rewritten, 0644); err != nil {
		t.Fatal(err)
	}
	if added, err := ensureCyfrComposeFields(path); err != nil || !slices.Contains(added, "volumes: ./aqua:/app/seed/aqua") {
		t.Fatalf("added %v (error %v), without cyfr's aqua volume, so nothing was written", added, err)
	}
	output, _ := os.ReadFile(path)
	var root yaml.Node
	if err := yaml.Unmarshal(output, &root); err != nil {
		t.Fatal(err)
	}
	role := mapValue(root.Content[0], "x-locus-role")
	services := mapValue(root.Content[0], "services")
	for _, name := range bundledServices {
		merge := mapValue(mapValue(services, name), "<<")
		if strings.HasSuffix(name, "-guard") {
			if merge != nil {
				t.Errorf("the written %s merges a block", name)
			}
		} else if merge == nil || merge.Alias != role || role.Anchor != "locus-role" {
			t.Errorf("the written %s does not merge *locus-role", name)
		}
	}
	var before, after map[string]any
	if err := yaml.Unmarshal(input, &before); err != nil {
		t.Fatal(err)
	}
	if err := yaml.Unmarshal(output, &after); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before["x-locus-role"], after["x-locus-role"]) {
		t.Errorf("x-locus-role changed")
	}
	for _, name := range append(slices.Clone(bundledServices), "caddy") {
		was := before["services"].(map[string]any)[name].(map[string]any)
		is := after["services"].(map[string]any)[name].(map[string]any)
		if is["image"] == was["image"] || !strings.Contains(is["image"].(string), "@sha256:") {
			t.Errorf("%s's image is %v", name, is["image"])
		}
		was, is = maps.Clone(was), maps.Clone(is)
		delete(was, "image")
		delete(is, "image")
		if !reflect.DeepEqual(was, is) {
			t.Errorf("the written %s runs as\n%v\nwant\n%v", name, is, was)
		}
	}
}

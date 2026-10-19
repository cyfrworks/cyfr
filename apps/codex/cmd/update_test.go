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
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"os/signal"
	"path"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/reach"
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
    profiles: ["public"]
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
// group of its own; a postgres client's stdin is kept in probe.stdin or
// dump.stdin; it appends the compose file's hash and the count of
// complete snapshots at the call to state. It answers each call from the
// scenario's files: <key>.out on stdout and <key>.exit as its status;
// <key>.edit is appended to docker-compose.yml, as an edit made while the
// update runs; <key>.signal sends SIGTERM to the updating process first and <key>.block
// waits for <key>.release. eval.live answers that many live reads first.
const fakeDocker = `#!/bin/bash
d="$FAKE_DOCKER_DIR"
note=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[i]}" = -e ]; then
    name="${args[i+1]}"
    case "$name" in
      *=*) ;;
      *) if [ -n "${!name+x}" ]; then note+=" {env $name set}"; else note+=" {env $name unset}"; fi ;;
    esac
  fi
done
# ps, not /proc/$$/stat: macOS has no /proc. An empty answer reads as
# a shared group, so a failed lookup never passes the check.
pgrp="$(ps -o pgid= -p $$ 2>/dev/null)"
pgrp="${pgrp//[[:space:]]/}"
[ "$pgrp" = "$$" ] || note+=" {shared process group}"
printf '%s%s\n' "$*" "$note" >> "$d/log"
# md5sum where it exists, BSD md5 otherwise: the bare hex digest either way.
digest() { if command -v md5sum >/dev/null; then md5sum | cut -c1-32; else md5 -q; fi; }
answer() {
  printf '%s %s %s\n' "$1" "$(digest < docker-compose.yml)" "$(ls backups/*/snapshot.json 2>/dev/null | wc -l)" >> "$d/state"
  [ -f "$d/$1.edit" ] && cat "$d/$1.edit" >> docker-compose.yml
  [ -f "$d/$1.signal" ] && kill -TERM "$PPID"
  if [ -f "$d/$1.block" ]; then while [ ! -f "$d/$1.release" ]; do sleep 0.02; done; fi
  [ -f "$d/$1.out" ] && cat "$d/$1.out"
  exit "$(cat "$d/$1.exit" 2>/dev/null || echo 0)"
}
if [ "$1" = compose ]; then
  shift
  while [ "$1" = -p ] || [ "$1" = -f ] || [ "$1" = --project-directory ] || [ "$1" = --profile ]; do shift 2; done
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
      *psql*) cat > "$d/probe.stdin"; answer probe ;;
      *pg_dump*) cat > "$d/dump.stdin"; answer dump ;;
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
	digestCyfr      = "sha256:" + strings.Repeat("a", 64)
	digestLocus     = "sha256:" + strings.Repeat("b", 64)
	digestCaddy     = "sha256:" + strings.Repeat("c", 64)
	digestTailscale = "sha256:" + strings.Repeat("d", 64)
	takenAt         = time.Date(2026, 10, 16, 12, 0, 0, 0, time.UTC)
	testImages      = release.Images{Cyfr: digestCyfr, CyfrLocus: digestLocus, Caddy: digestCaddy, Tailscale: digestTailscale}
)

// scenarioEnv is the .env of the scenarios' home: public at
// cyfr.example.com, builds on.
const scenarioEnv = "CYFR_REACH=public\nCYFR_HOST=cyfr.example.com\nCYFR_PUBLIC_URL=https://cyfr.example.com\nCYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\nCYFR_PORT=4000\n"

// updateScenario is one update's project directory, fake docker and fake
// engine.
type updateScenario struct {
	t        *testing.T
	project  string
	fake     string
	compose  []byte
	engine   *fakeStack
	scaffold int
	// scaffoldFail names the scaffold file whose write fails, the files
	// before it written.
	scaffoldFail string
}

// The scaffold files the scenarios' release manages: two the project
// holds before the update, at oldScaffold, and one the update creates.
var (
	newScaffold = []struct{ name, content string }{
		{"keeper.seccomp.json", `{"defaultAction":"SCMP_ACT_ERRNO","release":"0.9.0"}` + "\n"},
		{"configuration-guide.md", "# Configuration 0.9.0\n"},
		{"wit/cyfr/added.wit", "package cyfr:added;\n"},
	}
	oldScaffold = map[string]string{
		"keeper.seccomp.json":    `{"defaultAction":"SCMP_ACT_ERRNO","release":"0.8.0"}` + "\n",
		"configuration-guide.md": "# Configuration 0.8.0\n",
	}
)

// fakeScaffold is the scenarios' release scaffold: Write writes
// newScaffold into the project for real, logging SCAFFOLD WRITE.
type fakeScaffold struct{ s *updateScenario }

func (f fakeScaffold) Managed() []string {
	var names []string
	for _, file := range newScaffold {
		names = append(names, file.name)
	}
	return names
}

func (f fakeScaffold) Write(overwriteManaged bool) error {
	f.s.logLine("SCAFFOLD WRITE")
	for _, file := range newScaffold {
		if file.name == f.s.scaffoldFail {
			return errors.New("no space left on device")
		}
		if err := os.MkdirAll(filepath.Dir(filepath.Join(f.s.project, file.name)), 0755); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(f.s.project, file.name), []byte(file.content), 0644); err != nil {
			return err
		}
	}
	return nil
}

// logLine appends line to the fake docker's log.
func (s *updateScenario) logLine(line string) {
	f, err := os.OpenFile(filepath.Join(s.fake, "log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		s.t.Fatal(err)
	}
	fmt.Fprintln(f, line)
	if err := f.Close(); err != nil {
		s.t.Fatal(err)
	}
}

// shippedCompose is the repository's docker-compose.yml.
func shippedCompose(t *testing.T) []byte {
	data, err := os.ReadFile(filepath.Join(packageDir, "..", "..", "..", "docker-compose.yml"))
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
	write(".env", scenarioEnv, 0600)
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
	for name, content := range oldScaffold {
		write(name, content, 0644)
	}
	if err := os.Symlink("components/acme", filepath.Join("data", "current")); err != nil {
		t.Fatal(err)
	}

	write(filepath.Join(s.fake, "docker"), fakeDocker, 0755)
	t.Setenv("PATH", s.fake+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_DOCKER_DIR", s.fake)
	s.engine = useFakeEngine(t)
	saved := profiles
	t.Cleanup(func() { profiles = saved })
	profiles = strings.Join(composePrefixArgs(s.project, scenarioHead), " ") + " "

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
	s.answer("ps.out", "locus-backends-guard\ncyfr\ncaddy\ntailscale\nlocus-runtime\nlocus-builds\nlocus-builds-guard\nlocus-backends\nsidecar\n")
	s.answer("rpc.out", "warming up\nCYFR_ROSTER="+`{"self":"cyfr@abc","release":"0.8.0","slots":[{"node":"cyfr@abc","owner":"o1","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"}]}`+"\n")
	s.answer("eval.out", "booting\nCYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[]}`+"\n")
	s.answer("eval-live.out", "CYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[{"node":"cyfr@abc","owner":"o1","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"}]}`+"\n")
	s.answer("probe.out", "180006\n")
	s.answer("dump.out", "PGDMP custom-format dump")

	savedVersion, savedFetch, savedScaffold, savedNow := version.Version, fetchManifest, fetchScaffold, updateNow
	savedWindow, savedPoll := liveSlotsWindow, liveSlotsPoll
	t.Cleanup(func() {
		version.Version, fetchManifest, fetchScaffold, updateNow = savedVersion, savedFetch, savedScaffold, savedNow
		liveSlotsWindow, liveSlotsPoll = savedWindow, savedPoll
	})
	version.Version = testVersion
	fetchManifest = func(ctx context.Context, v string) (*release.Manifest, error) {
		return &release.Manifest{Version: v, Images: testImages}, nil
	}
	fetchScaffold = func(v string) (scaffoldRelease, error) {
		s.scaffold++
		s.logLine("SCAFFOLD FETCH " + v)
		return fakeScaffold{s}, nil
	}
	updateNow = func() time.Time { return takenAt }
	liveSlotsWindow, liveSlotsPoll = 400*time.Millisecond, 20*time.Millisecond
	return s
}

// edit writes content at the project path rel.
func (s *updateScenario) edit(rel, content string) {
	s.t.Helper()
	p := filepath.Join(s.project, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		s.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0644); err != nil {
		s.t.Fatal(err)
	}
}

// answer writes a scenario file of the fake docker.
// addVolume adds volume to the cyfr service's mounts in the scenario's
// `compose config` answer.
func (s *updateScenario) addVolume(volume map[string]any) {
	s.t.Helper()
	raw, err := os.ReadFile(filepath.Join(s.fake, "config.out"))
	if err != nil {
		s.t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(raw, &config); err != nil {
		s.t.Fatal(err)
	}
	cyfr := config["services"].(map[string]any)["cyfr"].(map[string]any)
	cyfr["volumes"] = append(cyfr["volumes"].([]any), volume)
	if raw, err = json.Marshal(config); err != nil {
		s.t.Fatal(err)
	}
	s.answer("config.out", string(raw))
}

func (s *updateScenario) answer(name, content string) {
	s.t.Helper()
	if err := os.WriteFile(filepath.Join(s.fake, name), []byte(content), 0644); err != nil {
		s.t.Fatal(err)
	}
}

// run runs `cyfr update` and answers its error and its output; the lock is
// released after it and no docker child shared cyfr's process group.
func (s *updateScenario) run(ctx context.Context) (string, error) {
	s.t.Helper()
	var out bytes.Buffer
	err := runUpdate(ctx, &out, &out)
	if holder := s.engine.held(); holder != "" {
		s.t.Errorf("the lock is still held, by %s", holder)
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

// startedComposes answers, for each start the fake engine ran through the
// fake docker, the md5 of the compose file that start saw: the old stack's
// start again sees the file the update read, the new release's the
// switched one.
func (s *updateScenario) startedComposes() []string {
	state, _ := os.ReadFile(filepath.Join(s.fake, "state"))
	var sums []string
	for _, line := range strings.Split(strings.TrimSpace(string(state)), "\n") {
		if fields := strings.Fields(line); len(fields) >= 2 && fields[0] == "up" {
			sums = append(sums, fields[1])
		}
	}
	return sums
}

// md5Hex is data's md5, as the fake docker records a compose file's.
func md5Hex(data []byte) string { return fmt.Sprintf("%x", md5.Sum(data)) }

// dockerLog is the log's docker calls alone, the engine's left out; nil
// when docker never ran.
func (s *updateScenario) dockerLog() []string {
	var calls []string
	for _, line := range s.log() {
		if !strings.HasPrefix(line, "ENGINE ") {
			calls = append(calls, line)
		}
	}
	return calls
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
	for _, sub := range []string{profiles + "stop", profiles + "start", profiles + "up", "ENGINE start", "ENGINE stop"} {
		if s.hasCall(sub) {
			s.t.Errorf("the update ran %q:\n%s", sub, strings.Join(s.log(), "\n"))
		}
	}
}

// switched spells compose with every managed image line as the switch
// writes it: cyfr and cyfr-locus at the version and digest, the bundled
// Caddy and Tailscale at their own tags and the digest; every other line as
// it is.
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
		case strings.HasPrefix(value, "tailscale/tailscale:"):
			tag, _, _ := strings.Cut(strings.TrimPrefix(value, "tailscale/tailscale:"), "@")
			value = "tailscale/tailscale:" + tag + "@" + digestTailscale
		}
		lines[i] = indent + "image: " + value + "\n"
	}
	return []byte(strings.Join(lines, ""))
}

// scenarioHead is the reach head scenarioEnv holds.
var scenarioHead = reach.Head{Mode: reach.ModePublic, Host: "cyfr.example.com", PublicURL: "https://cyfr.example.com", Port: 4000, BuildsURL: "http://locus-builds:4100", Profiles: []string{"locus-builds", "public"}}

// profiles is the engine's compose selection for the scenario's head and
// project, as the fake docker logs it (newUpdateScenario sets it).
var profiles string

// started is the engine's start, as the fake engine logs it and the fake
// docker logs the compose call it runs.
func started(cause string) []string {
	return []string{"ENGINE start " + cause, profiles + "up -d"}
}

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
		"ENGINE lock update",
		"ENGINE resume",
		profiles + "config --format json",
		"pull ghcr.io/cyfrworks/cyfr@" + digestCyfr,
		"pull ghcr.io/cyfrworks/cyfr-locus@" + digestLocus,
		"pull caddy@" + digestCaddy,
		"pull tailscale/tailscale@" + digestTailscale,
		profiles + "ps --services --status running",
		profiles + "exec -T cyfr bin/cyfr rpc " + testRoster,
		"SCAFFOLD FETCH " + testVersion,
		"ENGINE cancel-waiting-join",
		"ENGINE close-serve",
		profiles + "stop caddy",
		profiles + "stop tailscale",
		profiles + "stop cyfr",
		profiles + "stop locus-runtime",
		profiles + "stop locus-builds",
		profiles + "stop locus-backends",
		profiles + "stop locus-builds-guard",
		profiles + "stop locus-backends-guard",
		profiles + "stop",
		profiles + "run --rm --no-deps -T cyfr bin/cyfr eval " + testLive,
		profiles + "run --rm --no-deps -T cyfr bin/cyfr eval " + testLive,
		"SCAFFOLD WRITE",
		"ENGINE start update",
		profiles + "up -d",
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
	if n := strings.Count(string(got), "@sha256:"); n != 8 {
		t.Errorf("the switched docker-compose.yml pins %d images, want 8 (cyfr, five cyfr-locus, caddy, tailscale)", n)
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
		"database":                        "sqlite-main",
		"database-wal":                    "sqlite-wal",
		".env":                            scenarioEnv,
		"storage/components/acme/c.wasm":  "component-bytes",
		"storage/blobs/x":                 "blob",
		"compose":                         string(s.compose),
		"scaffold/keeper.seccomp.json":    oldScaffold["keeper.seccomp.json"],
		"scaffold/configuration-guide.md": oldScaffold["configuration-guide.md"],
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
		"parts":           []any{"database", "database-wal", "storage", "scaffold", "keyring", ".env", "compose"},
		"storage_adapter": "local",
		"scaffold":        []any{"keeper.seccomp.json", "configuration-guide.md", "wit/cyfr/added.wit"},
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
	if !slices.Equal(names, []string{".env", "compose", "database", "database-wal", "keyring", "scaffold", "snapshot.json", "storage"}) {
		t.Errorf("the snapshot holds %v", names)
	}
	// The snapshot holds the scaffold files as they stood before the
	// update, and none the update created; the project holds the
	// release's.
	if _, err := os.Lstat(filepath.Join(dir, "scaffold", "wit")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the snapshot holds a scaffold file the update created (%v)", err)
	}
	for _, file := range newScaffold {
		if got := read(t, filepath.Join(s.project, file.name)); got != file.content {
			t.Errorf("the updated project's %s holds %q, want the release's", file.name, got)
		}
	}
	if got := read(t, filepath.Join(s.project, "backups", ".gitignore")); !strings.Contains(got, "\n*\n") {
		t.Errorf("backups/.gitignore is %q, want it to ignore everything", got)
	}

	if !slices.Equal(snapshotParts, []string{"database", "database-wal", "storage", "scaffold", "keyring", ".env", "compose"}) {
		t.Errorf("snapshotParts %v is not the roster this snapshot was taken with", snapshotParts)
	}
	storageRoot := "Storage root /app/data is " + filepath.Join(s.project, "data") + " on the host."
	for _, line := range []string{storageRoot, "stopped caddy in ", "stopped tailscale in ", "stopped cyfr in ", "stopped locus-backends-guard in ", "stopped sidecar in ", "Updated to release 0.9.0.", "Snapshot of release 0.8.0: " + dir} {
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
// reaching each container on its standard input, never an argv or the
// environment of a process outside the container.
func TestUpdateDumpsPostgresWithoutTheURLOnArgv(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL})
	if err := os.Remove(filepath.Join(s.project, "data", "cyfr.db-wal")); err != nil {
		t.Fatal(err)
	}
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	pg18 := pgClientImages[18]
	probe := `run --rm -i --network host ` + pg18 + ` sh -c IFS= read -r CYFR_UPDATE_PG_URL && exec psql "$CYFR_UPDATE_PG_URL" -tAc "SHOW server_version_num"`
	dump := `run --rm -i --network host ` + pg18 + ` sh -c IFS= read -r CYFR_UPDATE_PG_URL && exec pg_dump --format=custom --no-owner "$CYFR_UPDATE_PG_URL"`
	log := s.log()
	at := func(line string) int { return slices.Index(log, line) }
	config := at(profiles + "config --format json")
	if config < 0 || at(probe) != config+1 || at("pull "+pg18) < config+2 || at("pull "+pg18) > at("SCAFFOLD FETCH 0.9.0") {
		t.Errorf("the probe does not run before the pulls, the dump image among them:\n%s", strings.Join(log, "\n"))
	}
	eval := at(profiles + "run --rm --no-deps -T cyfr bin/cyfr eval " + testLive)
	if at(dump) < eval || at(dump) > at(profiles+"up -d") {
		t.Errorf("the dump does not run between the offline read and the start:\n%s", strings.Join(log, "\n"))
	}
	for _, name := range []string{"probe.stdin", "dump.stdin"} {
		if got := read(t, filepath.Join(s.fake, name)); got != pgURL+"\n" {
			t.Errorf("%s holds %q, want the database URL on one line", name, got)
		}
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
	if json.Unmarshal(data, &snapshot) != nil || !slices.Equal(snapshot.Parts, []string{"database", "storage", "scaffold", "keyring", ".env", "compose"}) {
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
	if json.Unmarshal(data, &snapshot) != nil || snapshot.StorageAdapter != "s3" || !slices.Equal(snapshot.Parts, []string{"database", "database-wal", "scaffold", "keyring", ".env", "compose"}) {
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

// A cell on several hosts: one host was updated and started first, so its
// member runs the target release. The next host's update admits that live
// member, before the stop and in the offline read, and goes on; a member
// of another release, or of none, is still refused.
func TestUpdateAdmitsAMemberAlreadyOnTheTargetRelease(t *testing.T) {
	// Read once: each scenario moves the test into its own project.
	compose := shippedCompose(t)
	target := `{"node":"cyfr@first-host","owner":"o2","release":"` + testVersion + `","lease_until":"2026-10-16T12:00:12Z"}`
	s := newUpdateScenario(t, compose, nil)
	s.answer("rpc.out", "CYFR_ROSTER="+`{"self":"cyfr@abc","release":"0.8.0","slots":[{"node":"cyfr@abc","owner":"o1","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"},`+target+`]}`+"\n")
	s.answer("eval.out", "CYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[`+target+`]}`+"\n")
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	if !s.hasCall("ENGINE start update") {
		t.Errorf("the update did not start the switched stack:\n%s", strings.Join(s.log(), "\n"))
	}

	for name, release := range map[string]string{"another release": `"0.7.9"`, "no release": `null`} {
		t.Run(name, func(t *testing.T) {
			other := `{"node":"cyfr@first-host","owner":"o2","release":` + release + `,"lease_until":"2026-10-16T12:00:12Z"}`
			s := newUpdateScenario(t, compose, nil)
			s.answer("rpc.out", "CYFR_ROSTER="+`{"self":"cyfr@abc","release":"0.8.0","slots":[`+other+`]}`+"\n")
			out, err := s.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), "cyfr@first-host") {
				t.Fatalf("update answered %v\n%s", err, out)
			}
			s.nothingStopped()
			s.composeUnchanged()
			s.noBackups()
		})
	}

	// Offline, a member of the target release beside one of another is still
	// refused, once the window closes, and the old stack starts again.
	s = newUpdateScenario(t, compose, nil)
	s.answer("eval.out", "CYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[`+target+`,{"node":"cyfr@old-host","owner":"o3","release":"0.8.0","lease_until":"2026-10-16T12:00:12Z"}]}`+"\n")
	out, err = s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "cyfr@old-host (release 0.8.0)") || strings.Contains(err.Error(), "first-host") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	if !s.hasCall("ENGINE start update") {
		t.Errorf("the old stack was not started again:\n%s", strings.Join(s.log(), "\n"))
	}
	s.composeUnchanged()
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
			if log := s.dockerLog(); log != nil {
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
	if err == nil || !strings.Contains(err.Error(), "not valid YAML") || s.dockerLog() != nil {
		t.Fatalf("update answered %v with docker calls %v", err, s.dockerLog())
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
	if !slices.Equal(log[len(log)-2:], started("update")) {
		t.Errorf("the update ended with %q, want the old stack's start", log[len(log)-2:])
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
			if log := s.log(); !slices.Equal(log[len(log)-2:], started("update")) {
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
	if log := s.log(); !slices.Equal(log[len(log)-2:], started("update")) || s.hasCall(profiles+"run") {
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
		if err == nil || !strings.Contains(err.Error(), "The snapshot failed: pg_dump in "+pgClientImages[18]+" failed") || !strings.Contains(err.Error(), "left stopped") || !strings.Contains(err.Error(), s.snapshotDir()) {
			t.Fatalf("update answered %v\n%s", err, out)
		}
		if s.hasCall("ENGINE start") || s.hasCall(profiles+"up") {
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
		if s.hasCall("ENGINE start") || s.hasCall(profiles+"up") {
			t.Errorf("the update started a stack after a failed snapshot")
		}
		if entries, _ := os.ReadDir(s.snapshotDir()); len(entries) != 0 {
			t.Errorf("the update wrote into an existing snapshot directory: %v", entries)
		}
		s.composeUnchanged()
	})
}

// A failed migration or health check after the switch leaves the stack
// stopped, Serve closed before the stop, never the old images started, and
// prints the snapshot and the restore command.
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
	if n := len(log); n < 3 || !slices.Equal(log[n-3:], []string{profiles + "up -d", "ENGINE close-serve", profiles + "stop"}) {
		t.Errorf("the update did not stop the stack after the failed start:\n%s", strings.Join(log, "\n"))
	}
	if n := strings.Count(strings.Join(log, "\n"), "ENGINE start update"); n != 1 {
		t.Errorf("the update started %d times, want only the new release's start, never the old stack over the switch", n)
	}
	if _, err := os.Stat(filepath.Join(s.snapshotDir(), "snapshot.json")); err != nil {
		t.Errorf("the snapshot is not complete: %v", err)
	}
	if got, _ := os.ReadFile("docker-compose.yml"); !bytes.Equal(got, switched(s.compose)) {
		t.Errorf("docker-compose.yml is not the switched file")
	}
}

// A new release that starts with the machine's tailnet node other than the
// one .env names runs on this machine alone, Serve closed: the update is
// done and never stops it, and it answers the refusal's sentence, which
// says how to serve the home on the tailnet again. So does a restore.
func TestUpdateKeepsAHomeServedLocallyRunning(t *testing.T) {
	want := reach.Refuse("tailnet_node_mismatch", mismatch()).Message()

	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.engine.startReceipt = startedLocalReceipt("start")
	out, err := s.run(context.Background())
	if err == nil || err.Error() != want || ExitStatus(err) != exitStartedLocally || !strings.Contains(out, "Updated to release 0.9.0.") {
		t.Fatalf("update answered %v (exit %d), want %q and exit %d after the report\n%s", err, ExitStatus(err), want, exitStartedLocally, out)
	}
	if log := s.log(); !slices.Equal(log[len(log)-2:], started("update")) {
		t.Errorf("the update did more than start the new release:\n%s", strings.Join(log, "\n"))
	}

	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	r.engine.startReceipt = startedLocalReceipt("start")
	out, err = r.restore(true)
	if err == nil || err.Error() != want || ExitStatus(err) != exitStartedLocally || !strings.Contains(out, "It runs on this machine alone.") {
		t.Fatalf("restore answered %v, want %q\n%s", err, want, out)
	}
	if log := r.log(); !slices.Equal(log[len(log)-2:], started("restore")) {
		t.Errorf("the restore stopped the home it started:\n%s", strings.Join(log, "\n"))
	}
}

// Every docker call update and restore make through the engine's runner
// carries the deadline its step allows, since the runner holds a call
// without one to 120 s: a pull 30 minutes, the PostgreSQL dump and load an
// hour, a stop ten minutes, every other call two. None asks for a
// terminal, which the runner cannot give. Both start through StartWithin,
// waiting 900 s for cyfr's health, as an update's migrations may need.
func TestEveryDockerCallCarriesItsDeadline(t *testing.T) {
	pg := map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL}
	r := newRestoreScenario(t, shippedCompose(t), pg, func(s *updateScenario) { s.answer("dump.out", "PGDMP custom-format dump") })
	r.answer("probe.out", "170004\n")
	if out, err := r.restore(true); err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	allowed := func(c reach.Call) time.Duration {
		line := strings.Join(c.Args, " ")
		switch {
		case c.Args[0] == "pull":
			return pullTimeout
		case strings.Contains(line, "pg_dump") || strings.Contains(line, "pg_restore"):
			return dumpTimeout
		case slices.Contains(c.Args, "stop"):
			return stopTimeout
		}
		return composeRunTimeout
	}
	seen := map[time.Duration]bool{}
	for _, c := range r.engine.calls {
		want := allowed(c)
		seen[want] = true
		if c.Deadline <= 0 || c.Deadline > want || want-c.Deadline > time.Minute {
			t.Errorf("docker %s ran under the deadline %v, want its step's %v", strings.Join(c.Args, " "), c.Deadline, want)
		}
		for _, arg := range c.Args {
			if arg == "-t" || arg == "-it" || arg == "-ti" || arg == "--tty" {
				t.Errorf("docker %s asks for a terminal", strings.Join(c.Args, " "))
			}
		}
	}
	for _, want := range []time.Duration{pullTimeout, dumpTimeout, stopTimeout, composeRunTimeout} {
		if !seen[want] {
			t.Errorf("no call of the update and the restore ran under %v", want)
		}
	}
	if len(r.engine.healths) != 2 || r.engine.healths[0] != startHealth || r.engine.healths[1] != startHealth || startHealth != 900*time.Second {
		t.Errorf("the update's and the restore's starts waited %v for cyfr's health, want 900s each", r.engine.healths)
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
	want := []string{"ENGINE lock update", "ENGINE resume", profiles + "config --format json", "pull ghcr.io/cyfrworks/cyfr@" + digestCyfr, "pull ghcr.io/cyfrworks/cyfr-locus@" + digestLocus}
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
	_, tailscaleTag, _ := strings.Cut(string(regexp.MustCompile(`image: tailscale/tailscale:[^@\n]+`).Find([]byte(shipped))), "tailscale/tailscale:")
	want = replaceImage(want, "tailscale", "tailscale/tailscale:"+tailscaleTag+"@"+digestTailscale)
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
	if s.hasCall("pull ghcr.io/cyfrworks/cyfr@") || !s.hasCall("pull ghcr.io/cyfrworks/cyfr-locus@"+digestLocus) || !s.hasCall("pull caddy@"+digestCaddy) || !s.hasCall("pull tailscale/tailscale@"+digestTailscale) {
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
		"tailscale/tailscale:v1.104.1@sha256:00":   true,
		"docker.io/tailscale/tailscale":            true,
		"tailscale":                                false,
		"tailscale/tailscale-extra:1":              false,
		"ghcr.io/tailscale/tailscale:1":            false,
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
			if log := s.dockerLog(); log != nil {
				t.Errorf("docker ran:\n%s", strings.Join(log, "\n"))
			}
			s.composeUnchanged()
		})
	}
}

// A second update refuses while the first holds the lock, naming its
// holder, before any docker call; the first still holds the lock, and
// releases it at its end. A lock another command holds refuses the same.
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
	calls := len(s.log())
	var out bytes.Buffer
	err := runUpdate(context.Background(), &out, &out)
	if err == nil || !strings.Contains(err.Error(), "Another cyfr command holds this home (`update`)") || !strings.Contains(err.Error(), "Nothing was changed") {
		t.Errorf("the second update answered %v", err)
	}
	if got := s.log(); len(got) != calls {
		t.Errorf("the refused update ran %s", strings.Join(got[calls:], "\n"))
	}
	if holder := s.engine.held(); holder != "update" {
		t.Errorf("the refused update took the first one's lock from it (held by %q)", holder)
	}
	s.answer("pull.release", "")
	if err := <-first; err != nil {
		t.Fatalf("the first update: %v", err)
	}
	if holder := s.engine.held(); holder != "" {
		t.Errorf("the lock is still held, by %s", holder)
	}
	if n := strings.Count(strings.Join(s.log(), "\n"), " up -d"); n != 1 {
		t.Errorf("the stack was switched %d times", n)
	}

	s.engine.holder = "reach tailnet"
	calls = len(s.log())
	err = runUpdate(context.Background(), io.Discard, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "(`reach tailnet`)") {
		t.Errorf("an update beside a held lock answered %v", err)
	}
	if got := s.log(); len(got) != calls {
		t.Errorf("the refused update ran %s", strings.Join(got[calls:], "\n"))
	}
	s.engine.holder = ""
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
				if !slices.Equal(log[len(log)-2:], started("update")) {
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

// Once the switch begins it is never cut short: a signal during the start
// lets the start finish, so the stack is not left half-switched, and the
// update reports the interrupt beside its outcome. Found by review: the
// command's documentation said every step from the stop on ends the update.
func TestUpdateFinishesTheSwitchOnASignal(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("up.signal", "")
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM)
	defer stop()
	out, err := s.run(ctx)
	select {
	case <-ctx.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("the signal never arrived")
	}
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	log := s.log()
	if !slices.Equal(log[len(log)-2:], started("update")) {
		t.Errorf("the start was not the last step:\n%s", strings.Join(log, "\n"))
	}
	if !strings.Contains(out, "An interrupt arrived during the switch") {
		t.Errorf("the update did not report the interrupt:\n%s", out)
	}
	if got, err := os.ReadFile(filepath.Join(s.project, "docker-compose.yml")); err != nil || !bytes.Equal(got, switched(s.compose)) {
		t.Errorf("docker-compose.yml is not the switched file (error %v)", err)
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
	m := &release.Manifest{Version: testVersion, Images: testImages}
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

// The storage root is what cyfr sees under it: a second bind at
// /app/data/components covers the host's ./data/components, so the
// snapshot holds the nested mount's bytes there and nothing of the covered
// host directory, beside the rest of the root.
func TestUpdateSnapshotsNestedStorageMount(t *testing.T) {
	nested := t.TempDir()
	if err := os.MkdirAll(filepath.Join(nested, "acme"), 0700); err != nil {
		t.Fatal(err)
	}
	want := "authoritative nested-mount component bytes"
	if err := os.WriteFile(filepath.Join(nested, "acme", "c.wasm"), []byte(want), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nested, "only-in-mount"), []byte("mounted"), 0600); err != nil {
		t.Fatal(err)
	}
	compose := strings.Replace(string(shippedCompose(t)), "      - ./data:/app/data\n", "      - ./data:/app/data\n      - "+nested+":/app/data/components\n", 1)
	s := newUpdateScenario(t, []byte(compose), nil)
	// A file only the covered host directory holds, which cyfr never sees.
	if err := os.WriteFile(filepath.Join(s.project, "data", "components", "covered"), []byte("covered"), 0600); err != nil {
		t.Fatal(err)
	}
	s.addVolume(map[string]any{"type": "bind", "source": nested, "target": "/app/data/components"})

	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	storage := filepath.Join(s.snapshotDir(), "storage")
	for name, content := range map[string]string{
		"components/acme/c.wasm":   want,
		"components/only-in-mount": "mounted",
		"blobs/x":                  "blob",
	} {
		if data, err := os.ReadFile(filepath.Join(storage, name)); err != nil || string(data) != content {
			t.Errorf("storage/%s holds %q (error %v), want %q", name, data, err, content)
		}
	}
	if _, err := os.Lstat(filepath.Join(storage, "components", "covered")); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("storage/components holds the covered host file (%v)", err)
	}
}

// A mount under the storage root that is no bind (a named volume, a tmpfs)
// holds bytes no host directory names, so the update refuses it before
// anything stops rather than write a snapshot without them.
func TestUpdateRefusesANonBindMountUnderTheStorageRoot(t *testing.T) {
	for _, kind := range []string{"volume", "tmpfs"} {
		t.Run(kind, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.addVolume(map[string]any{"type": kind, "source": "cyfr-components", "target": "/app/data/components"})
			out, err := s.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), kind+" mount at /app/data/components") {
				t.Fatalf("update answered %v\n%s", err, out)
			}
			s.nothingStopped()
			s.composeUnchanged()
			s.noBackups()
		})
	}
}

// A snapshot holds neither the tailnet's state volume nor the reach
// engine's .cyfr/, so a node's keys and the machine's lock, journal and
// receipts never enter a backup: snapshotParts names neither; .cyfr/ beside
// the storage root, or bound under it, is copied nowhere; and the state
// volume mounted under the storage root is refused as every non-bind mount
// there is, before anything stops.
func TestSnapshotsHoldNeitherTheTailnetStateNorTheReachState(t *testing.T) {
	for _, part := range snapshotParts {
		if strings.Contains(part, "tailscale") || strings.Contains(part, ".cyfr") {
			t.Errorf("snapshotParts names %s", part)
		}
	}
	state := map[string]string{"lock": "", "holder": "update pid 1", "journal.json": `{"op":"switch"}`, "receipts/" + strings.Repeat("a", 32) + ".json": `{"state":"completed"}`, "tailscale-serve/serve.json": "{}", "join.json": `{"join_id":"j1"}`}
	writeState := func(root string) {
		for name, content := range state {
			if err := os.MkdirAll(filepath.Dir(filepath.Join(root, name)), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, name), []byte(content+"reach-state-marker"), 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	noState := func(s *updateScenario) {
		t.Helper()
		err := filepath.WalkDir(s.snapshotDir(), func(p string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.Name() == ".cyfr" || entry.Name() == "tailscale-serve" || entry.Name() == "receipts" {
				t.Errorf("the snapshot holds %s", p)
			}
			if entry.Type().IsRegular() && strings.Contains(read(t, p), "reach-state-marker") {
				t.Errorf("the snapshot holds the reach state's %s", p)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}

	s := newUpdateScenario(t, shippedCompose(t), nil)
	writeState(filepath.Join(s.project, ".cyfr"))
	if out, err := s.run(context.Background()); err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	noState(s)

	s = newUpdateScenario(t, shippedCompose(t), nil)
	writeState(filepath.Join(s.project, ".cyfr"))
	s.addVolume(map[string]any{"type": "bind", "source": filepath.Join(s.project, ".cyfr"), "target": "/app/data/reach"})
	if out, err := s.run(context.Background()); err != nil {
		t.Fatalf("update with .cyfr/ bound under the storage root: %v\n%s", err, out)
	}
	noState(s)

	s = newUpdateScenario(t, shippedCompose(t), nil)
	s.addVolume(map[string]any{"type": "volume", "source": reach.ProjectName(s.project) + "_tailscale_state", "target": "/app/data/tailscale"})
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "volume mount at /app/data/tailscale") {
		t.Fatalf("update with the tailnet's state volume under the storage root answered %v\n%s", err, out)
	}
	s.nothingStopped()
	s.noBackups()
}

// setService sets key on the cyfr service in the scenario's `compose
// config` answer.
func (s *updateScenario) setService(key string, value any) {
	s.t.Helper()
	raw, err := os.ReadFile(filepath.Join(s.fake, "config.out"))
	if err != nil {
		s.t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(raw, &config); err != nil {
		s.t.Fatal(err)
	}
	config["services"].(map[string]any)["cyfr"].(map[string]any)[key] = value
	if raw, err = json.Marshal(config); err != nil {
		s.t.Fatal(err)
	}
	s.answer("config.out", string(raw))
}

// Every key compose mounts something with is read, not only `volumes`: a
// service-level tmpfs (a list or one path), a secret or a config whose
// target lies under the storage root, or at the root itself, is no bind
// the snapshot can copy, and volumes_from mounts what the configuration
// does not place; each refuses before anything stops. Found by review: a
// service-level tmpfs under the root was accepted and the update reported
// success.
func TestUpdateRefusesEveryNonBindMountSource(t *testing.T) {
	cases := []struct {
		name, key string
		value     any
		want      string
	}{
		{"tmpfs list", "tmpfs", []string{"/app/data/components:rw,size=64m"}, "tmpfs mount at /app/data/components"},
		{"tmpfs path", "tmpfs", "/app/data/components", "tmpfs mount at /app/data/components"},
		{"tmpfs over the root", "tmpfs", []string{"/app/data"}, "on no bind mount"},
		{"secret", "secrets", []map[string]any{{"source": "blob", "target": "/app/data/blobs/key"}}, "secret mount at /app/data/blobs/key"},
		{"config", "configs", []map[string]any{{"source": "settings", "target": "/app/data/settings.json"}}, "config mount at /app/data/settings.json"},
		{"volumes_from", "volumes_from", []string{"service:other"}, "volumes_from"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.setService(c.key, c.value)
			out, err := s.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("update answered %v, want a refusal naming %q\n%s", err, c.want, out)
			}
			s.nothingStopped()
			s.composeUnchanged()
			s.noBackups()
		})
	}

	// A secret at its default place, outside the storage root, is no bar.
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.setService("secrets", []map[string]any{{"source": "token"}})
	if out, err := s.run(context.Background()); err != nil {
		t.Fatalf("a secret under /run/secrets refused the update: %v\n%s", err, out)
	}
}

// Nested binds supplied deepest first, each covering files of the one above
// it: the snapshot holds every layer's own bytes in its place and none a
// deeper layer covers.
func TestUpdateSnapshotsNestedMountsInAnyOrder(t *testing.T) {
	parent, child, deepest := t.TempDir(), t.TempDir(), t.TempDir()
	write := func(dir, rel, content string) {
		t.Helper()
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(parent, "parent-only", "parent")
	write(parent, "acme/covered-parent", "hidden")
	write(parent, "acme/deep/c.wasm", "hidden-parent")
	write(child, "child-only", "child")
	write(child, "deep/covered-child", "hidden")
	write(child, "deep/c.wasm", "hidden-child")
	write(deepest, "c.wasm", "deepest bytes")
	compose := strings.Replace(string(shippedCompose(t)), "      - ./data:/app/data\n",
		"      - ./data:/app/data\n      - "+deepest+":/app/data/components/acme/deep\n      - "+child+":/app/data/components/acme\n      - "+parent+":/app/data/components\n", 1)
	s := newUpdateScenario(t, []byte(compose), nil)
	write(filepath.Join(s.project, "data"), "components/covered-root", "hidden")
	for _, v := range []map[string]any{
		{"type": "bind", "source": deepest, "target": "/app/data/components/acme/deep"},
		{"type": "bind", "source": child, "target": "/app/data/components/acme"},
		{"type": "bind", "source": parent, "target": "/app/data/components"},
	} {
		s.addVolume(v)
	}
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	for rel, want := range map[string]string{
		"components/parent-only":      "parent",
		"components/acme/child-only":  "child",
		"components/acme/deep/c.wasm": "deepest bytes",
	} {
		if got, err := os.ReadFile(filepath.Join(s.snapshotDir(), "storage", rel)); err != nil || string(got) != want {
			t.Errorf("storage/%s holds %q (error %v), want %q", rel, got, err, want)
		}
	}
	for _, rel := range []string{"components/covered-root", "components/acme/covered-parent", "components/acme/deep/covered-child"} {
		if _, err := os.Lstat(filepath.Join(s.snapshotDir(), "storage", rel)); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("storage/%s, a covered file, is in the snapshot (%v)", rel, err)
		}
	}
}

// A failure writing the scaffold files, or a switch that fails after them,
// puts every scaffold file back from the snapshot, the one the update
// created removed, and starts the old stack again under its own files.
func TestUpdatePutsTheScaffoldBackWhenTheSwitchFails(t *testing.T) {
	// A compose file edited while the update ran is the person's: the switch
	// refuses it and the old stack stays stopped rather than start under it.
	for name, c := range map[string]struct {
		prepare func(s *updateScenario)
		restart bool
		want    string
	}{
		"the scaffold write": {func(s *updateScenario) { s.scaffoldFail = "wit/cyfr/added.wit" }, true, "The old stack was started again"},
		"the switch":         {func(s *updateScenario) { s.answer("stop-cyfr.edit", "# edited while the update ran\n") }, false, "The old stack is left stopped"},
	} {
		t.Run(name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			c.prepare(s)
			out, err := s.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), "the scaffold files were put back from the snapshot "+s.snapshotDir()) || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("update answered %v\n%s", err, out)
			}
			want := []string{}
			if c.restart {
				want = []string{md5Hex(s.compose)}
			}
			if got := s.startedComposes(); !slices.Equal(got, want) {
				t.Errorf("the stack started under %v, want %v (the old stack again: %v, the new one never):\n%s", got, want, c.restart, strings.Join(s.log(), "\n"))
			}
			for name, content := range oldScaffold {
				if got := read(t, filepath.Join(s.project, name)); got != content {
					t.Errorf("%s holds %q, want it as it stood before the update", name, got)
				}
			}
			if got := read(t, filepath.Join(s.project, "wit", "cyfr", "added.wit")); got != "<absent>" {
				t.Errorf("the scaffold file the update created stayed: %q", got)
			}
		})
	}

	// Scaffold files that cannot be put back leave the stack stopped: the
	// old stack never starts under the release's files.
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.scaffoldFail = "wit/cyfr/added.wit"
	saved := fetchScaffold
	fetchScaffold = func(v string) (scaffoldRelease, error) {
		r, err := saved(v)
		return unreadableSnapshot{r, s}, err
	}
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "could not be put back from the snapshot") || !strings.Contains(err.Error(), "left stopped") || !strings.Contains(err.Error(), "cyfr restore "+s.snapshotDir()) {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	if s.hasCall("ENGINE start") || s.hasCall(profiles+"up") {
		t.Errorf("a stack was started under scaffold files not put back:\n%s", strings.Join(s.log(), "\n"))
	}
}

// unreadableSnapshot is a scaffold whose Write first turns the snapshot's
// copy of the seccomp profile into a directory, which does not read as the
// file, then writes as fakeScaffold does.
type unreadableSnapshot struct {
	scaffoldRelease
	s *updateScenario
}

func (u unreadableSnapshot) Write(overwriteManaged bool) error {
	held := filepath.Join(u.s.snapshotDir(), "scaffold", "keeper.seccomp.json")
	if err := os.Remove(held); err != nil {
		return err
	}
	if err := os.Mkdir(held, 0700); err != nil {
		return err
	}
	return u.scaffoldRelease.Write(overwriteManaged)
}

// A restore that has not been declared refuses the update before anything
// is pulled or stopped.
func TestUpdateRefusesAnUndeclaredRestore(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), map[string]string{restoreBarrier: "/p/backups/20261016T120000Z"})
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "has not finished") || !strings.Contains(err.Error(), "cyfr restore /p/backups/20261016T120000Z") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	s.nothingStopped()
	s.noBackups()
	if s.hasCall("pull ") || s.scaffold != 0 {
		t.Errorf("the update pulled or fetched the scaffold before refusing:\n%s", strings.Join(s.log(), "\n"))
	}
}

// opusProbeCompose is the assessment probe's project: a cyfr service whose
// data mount has another source than the default.
const opusProbeCompose = `services:
  cyfr:
    image: alpine:3.22
    container_name: cyfr
    env_file:
      - .env
    ports:
      - "127.0.0.1:${CYFR_PORT:-4000}:${CYFR_PORT:-4000}"
    volumes:
VOLUMES`

// A mount at a default's container target, whatever its syntax, keeps its
// source: no second mount at /app/data or /app/seed/aqua is added beside
// it, so compose resolves the target to the customized source, before and
// after. A target bound by no entry gets the default once.
func TestEnsureCyfrComposeFieldsKeepsACustomizedMount(t *testing.T) {
	cases := map[string]struct{ volumes, env string }{
		"short":              {"      - ./alternate-data:/app/data\n      - ./my-aqua:/app/seed/aqua\n", ""},
		"short with options": {"      - ./alternate-data:/app/data:rw,z\n      - ./my-aqua:/app/seed/aqua:ro\n", ""},
		"trailing slash":     {"      - ./alternate-data:/app/data/\n      - ./my-aqua:/app/seed/aqua/\n", ""},
		"long": {"      - type: bind\n        source: ./alternate-data\n        target: /app/data\n" +
			"      - type: bind\n        source: ./my-aqua\n        target: /app/seed/aqua\n        read_only: true\n", ""},
		"interpolated source": {"      - ${DATA_DIR:-./alternate-data}:/app/data\n      - ./my-aqua:/app/seed/aqua\n", ""},
		"interpolated target": {"      - ./alternate-data:${DATA_TARGET}\n      - ./my-aqua:/app/seed/aqua\n", "DATA_TARGET=/app/data\n"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "docker-compose.yml")
			input := strings.Replace(opusProbeCompose, "VOLUMES", c.volumes, 1)
			if err := os.WriteFile(path, []byte(input), 0644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("CYFR_PORT=4000\n"+c.env), 0600); err != nil {
				t.Fatal(err)
			}
			before := resolvedDataSource(t, dir)
			added, err := ensureCyfrComposeFields(path)
			if err != nil || len(added) != 0 {
				t.Fatalf("ensureCyfrComposeFields added %v (error %v) to a project binding both targets", added, err)
			}
			if got, _ := os.ReadFile(path); string(got) != input {
				t.Errorf("docker-compose.yml was rewritten:\n%s", got)
			}
			if after := resolvedDataSource(t, dir); before != "" && after != before {
				t.Errorf("compose resolves /app/data to %s after the update, %s before", after, before)
			}
		})
	}

	// An anchored entry is read through its alias.
	t.Run("alias", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "docker-compose.yml")
		input := "x-data: &data ./alternate-data:/app/data\n" + strings.Replace(opusProbeCompose, "VOLUMES", "      - *data\n      - ./my-aqua:/app/seed/aqua\n", 1)
		if err := os.WriteFile(path, []byte(input), 0644); err != nil {
			t.Fatal(err)
		}
		if added, err := ensureCyfrComposeFields(path); err != nil || len(added) != 0 {
			t.Fatalf("ensureCyfrComposeFields added %v (error %v)", added, err)
		}
	})

	// The defaults land once, and a second run adds nothing.
	t.Run("missing", func(t *testing.T) {
		dir := t.TempDir()
		path := filepath.Join(dir, "docker-compose.yml")
		if err := os.WriteFile(path, []byte(strings.Replace(opusProbeCompose, "    volumes:\nVOLUMES", "", 1)), 0644); err != nil {
			t.Fatal(err)
		}
		added, err := ensureCyfrComposeFields(path)
		if err != nil || !slices.Equal(added, []string{"volumes: ./data:/app/data", "volumes: ./aqua:/app/seed/aqua"}) {
			t.Fatalf("ensureCyfrComposeFields added %v (error %v)", added, err)
		}
		if added, err := ensureCyfrComposeFields(path); err != nil || len(added) != 0 {
			t.Errorf("a second run added %v (error %v)", added, err)
		}
		got, _ := os.ReadFile(path)
		if n := strings.Count(string(got), ":/app/data"); n != 1 {
			t.Errorf("docker-compose.yml mounts /app/data %d times:\n%s", n, got)
		}
	})
}

// resolvedDataSource answers the source compose resolves the cyfr
// service's /app/data mount to in the project at dir, "" when no docker
// compose is on PATH to ask.
func resolvedDataSource(t *testing.T, dir string) string {
	t.Helper()
	if exec.Command("docker", "compose", "version").Run() != nil {
		t.Log("no docker compose on PATH: the resolution is not compared")
		return ""
	}
	out, err := exec.Command("docker", "compose", "--project-directory", dir, "-f", filepath.Join(dir, "docker-compose.yml"), "config", "--format", "json").Output()
	if err != nil {
		t.Fatalf("docker compose config: %v", err)
	}
	var config composeConfig
	if err := json.Unmarshal(out, &config); err != nil {
		t.Fatal(err)
	}
	var sources []string
	for _, v := range config.Services["cyfr"].Volumes {
		if path.Clean(v.Target) == "/app/data" {
			sources = append(sources, v.Source)
		}
	}
	if len(sources) != 1 || !strings.HasSuffix(sources[0], "alternate-data") {
		t.Errorf("compose resolves /app/data to %v, want the customized source alone", sources)
	}
	return strings.Join(sources, ",")
}

// A target missing from a list the service inherits through a YAML merge
// key is added to a copy of that list, which keeps every inherited mount;
// a service that extends another adds nothing unless compose's own
// resolution says the target is unbound, and that resolution decides.
func TestEnsureCyfrComposeFieldsKeepsInheritedMounts(t *testing.T) {
	write := func(t *testing.T, input string) (string, string) {
		dir := t.TempDir()
		path := filepath.Join(dir, "docker-compose.yml")
		if err := os.WriteFile(path, []byte(input), 0644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("CYFR_PORT=4000\n"), 0600); err != nil {
			t.Fatal(err)
		}
		return dir, path
	}
	const service = `    image: alpine:3.22
    container_name: cyfr
    env_file: [.env]
    ports:
      - "127.0.0.1:${CYFR_PORT:-4000}:${CYFR_PORT:-4000}"
`
	t.Run("merge key, one target inherited", func(t *testing.T) {
		dir, path := write(t, "x-base: &base\n  volumes:\n    - ./alternate-data:/app/data\nservices:\n  cyfr:\n    <<: *base\n"+service)
		before := resolvedDataSource(t, dir)
		added, err := ensureCyfrComposeFields(path)
		if err != nil || !slices.Equal(added, []string{"volumes: ./aqua:/app/seed/aqua"}) {
			t.Fatalf("ensureCyfrComposeFields added %v (error %v)", added, err)
		}
		if after := resolvedDataSource(t, dir); after != before {
			t.Errorf("compose resolves /app/data to %s after, %s before", after, before)
		}
		got, _ := os.ReadFile(path)
		var root yaml.Node
		if err := yaml.Unmarshal(got, &root); err != nil {
			t.Fatalf("the written file is not YAML: %v\n%s", err, got)
		}
		volumes, own := serviceVolumes(mapValue(mapValue(root.Content[0], "services"), "cyfr"), 0)
		if !own || len(volumes.Content) != 2 || volumes.Content[0].Value != "./alternate-data:/app/data" {
			t.Errorf("the cyfr service's own volumes are %v, want the inherited mount and the added one:\n%s", volumes, got)
		}
	})
	t.Run("extends", func(t *testing.T) {
		_, path := write(t, "services:\n  base:\n    image: alpine:3.22\n    volumes:\n      - ./alternate-data:/app/data\n      - ./my-aqua:/app/seed/aqua\n  cyfr:\n    extends: base\n"+service)
		if added, err := ensureCyfrComposeFields(path); err != nil || len(added) != 0 {
			t.Fatalf("ensureCyfrComposeFields added %v (error %v) to a service whose volumes another file holds", added, err)
		}
		if added, err := ensureComposeFields(path, map[string]bool{"/app/data": true}); err != nil || !slices.Equal(added, []string{"volumes: ./aqua:/app/seed/aqua"}) {
			t.Fatalf("ensureComposeFields added %v (error %v), want the one target compose resolves unbound", added, err)
		}
	})
	t.Run("resolved by compose", func(t *testing.T) {
		// An override file binds both targets: the file alone shows none.
		_, path := write(t, "services:\n  cyfr:\n"+service)
		if added, err := ensureComposeFields(path, map[string]bool{"/app/data": true, "/app/seed/aqua": true}); err != nil || len(added) != 0 {
			t.Fatalf("ensureComposeFields added %v (error %v) at targets compose resolves bound", added, err)
		}
	})
}

// A list the cyfr service anchors, which another service may alias, is not
// appended to: the other service's mounts and ports stay as they are.
func TestEnsureCyfrComposeFieldsLeavesAnAnchoredListAlone(t *testing.T) {
	path := filepath.Join(t.TempDir(), "docker-compose.yml")
	input := `services:
  cyfr:
    image: alpine:3.22
    container_name: cyfr
    env_file: &env [.env.shared]
    ports: &ports
      - "8080:8080"
    volumes: &shared
      - ./alternate-data:/app/data
  other:
    image: alpine:3.22
    env_file: *env
    ports: *ports
    volumes: *shared
`
	if err := os.WriteFile(path, []byte(input), 0644); err != nil {
		t.Fatal(err)
	}
	if added, err := ensureComposeFields(path, map[string]bool{"/app/data": true}); err != nil || len(added) != 0 {
		t.Fatalf("ensureComposeFields added %v (error %v) to lists another service aliases", added, err)
	}
	if got, _ := os.ReadFile(path); string(got) != input {
		t.Errorf("docker-compose.yml was rewritten:\n%s", got)
	}
}

// requireCompose skips t, naming why, where `docker compose version` fails:
// t asks real Docker Compose how it resolves the files the CLI writes or
// stages. The macOS runner has no Docker; codex-ci.yml's Linux job has it
// and requires every test that calls this to pass.
func requireCompose(t *testing.T) {
	t.Helper()
	if out, err := exec.Command("docker", "compose", "version").CombinedOutput(); err != nil {
		t.Skipf("needs real Docker Compose, and `docker compose version` failed: %v\n%s", err, out)
	}
}

// The tests that call requireCompose are exactly the ones codex-ci.yml's
// Linux job requires to pass, so none of them can skip there unseen.
func TestComposeTestsAreTheOnesCIRequires(t *testing.T) {
	sources, err := filepath.Glob("*_test.go")
	if err != nil {
		t.Fatal(err)
	}
	var calling []string
	fset := token.NewFileSet()
	for _, name := range sources {
		file, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil || !strings.HasPrefix(fn.Name.Name, "Test") {
				continue
			}
			ast.Inspect(fn.Body, func(node ast.Node) bool {
				if call, ok := node.(*ast.CallExpr); ok {
					if ident, ok := call.Fun.(*ast.Ident); ok && ident.Name == "requireCompose" {
						calling = append(calling, fn.Name.Name)
						return false
					}
				}
				return true
			})
		}
	}
	slices.Sort(calling)
	calling = slices.Compact(calling)

	data, err := os.ReadFile(filepath.Join("..", "..", "..", ".github", "workflows", "codex-ci.yml"))
	if err != nil {
		t.Fatal(err)
	}
	var workflow struct {
		Jobs map[string]struct {
			Steps []struct {
				Env map[string]string `yaml:"env"`
			} `yaml:"steps"`
		} `yaml:"jobs"`
	}
	if err := yaml.Unmarshal(data, &workflow); err != nil {
		t.Fatal(err)
	}
	var required []string
	for _, step := range workflow.Jobs["test"].Steps {
		required = append(required, strings.Fields(step.Env["COMPOSE_TESTS"])...)
	}
	slices.Sort(required)
	if len(calling) == 0 || !slices.Equal(calling, required) {
		t.Errorf("the tests that call requireCompose are %v; codex-ci.yml's test job requires %v", calling, required)
	}
}

// composeConfigOf runs docker with args, COMPOSE_FILE left out of its
// environment, and answers the configuration it prints.
func composeConfigOf(t *testing.T, args ...string) composeConfig {
	t.Helper()
	cmd := exec.Command("docker", args...)
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "COMPOSE_FILE=") {
			cmd.Env = append(cmd.Env, entry)
		}
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("docker %v: %v\n%s", args, err, &stderr)
	}
	var config composeConfig
	if err := json.Unmarshal(out, &config); err != nil {
		t.Fatal(err)
	}
	return config
}

// The updater already accepts service-level YAML merges (serviceImage).
// Adding a direct volumes key must not shadow mounts inherited that way.
func TestEnsureCyfrComposeFieldsAddsNothingWhenAMergeKeyBindsBothTargets(t *testing.T) {
	requireCompose(t)
	dir := t.TempDir()
	file := filepath.Join(dir, "docker-compose.yml")
	input := `x-base: &base
  volumes:
    - ./alternate-data:/app/data
    - ./my-aqua:/app/seed/aqua
services:
  cyfr:
    <<: *base
    image: alpine:3.22
    container_name: cyfr
    env_file: [.env]
    ports:
      - "127.0.0.1:${CYFR_PORT:-4000}:${CYFR_PORT:-4000}"
`
	if err := os.WriteFile(file, []byte(input), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("CYFR_PORT=4000\n"), 0600); err != nil {
		t.Fatal(err)
	}
	before := resolvedDataSource(t, dir)
	added, err := ensureCyfrComposeFields(file)
	if err != nil {
		t.Fatal(err)
	}
	after := resolvedDataSource(t, dir)
	if len(added) != 0 || after != before {
		t.Fatalf("inherited target changed: added=%v, /app/data before=%s after=%s", added, before, after)
	}
}

// A list referenced by cyfr is not owned solely by cyfr. Adding a missing
// default must materialize a private list, preserving the shared anchor.
func TestEnsureComposeFieldsCopiesASharedAnchorBeforeAddingADefault(t *testing.T) {
	requireCompose(t)
	dir := t.TempDir()
	t.Chdir(dir)
	const input = `x-volumes: &shared
  - ./alternate-data:/app/data
services:
  cyfr:
    image: alpine:3.22
    container_name: cyfr
    env_file: [.env]
    ports:
      - "127.0.0.1:${CYFR_PORT:-4000}:${CYFR_PORT:-4000}"
    volumes: *shared
  other:
    image: alpine:3.22
    volumes: *shared
`
	if err := os.WriteFile("docker-compose.yml", []byte(input), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(".env", []byte("CYFR_PORT=4000\n"), 0600); err != nil {
		t.Fatal(err)
	}
	before := composeConfigOf(t, "compose", "config", "--format", "json")
	// This is the switchImages path, supplied with preflight's resolved
	// targets, not just the standalone ensureCyfrComposeFields helper.
	added, err := ensureComposeFields(filepath.Join(dir, "docker-compose.yml"), map[string]bool{"/app/data": true})
	if err != nil {
		t.Fatal(err)
	}
	after := composeConfigOf(t, "compose", "config", "--format", "json")
	if !reflect.DeepEqual(before.Services["other"].Volumes, after.Services["other"].Volumes) {
		t.Fatalf("adding cyfr defaults %v changed another service's mounts: before=%+v after=%+v", added, before.Services["other"].Volumes, after.Services["other"].Volumes)
	}
	found := false
	for _, volume := range after.Services["cyfr"].Volumes {
		if volume.Target == "/app/seed/aqua" {
			found = true
		}
	}
	if !found {
		t.Fatal("cyfr did not receive its missing default mount")
	}
}

// unpinnedPostgresImages answers the entries of images that are not the
// pinned client of the major they are keyed by: postgres:<major>.<minor>
// and a sha256 digest, the major the key.
func unpinnedPostgresImages(images map[int]string) []string {
	pinned := regexp.MustCompile(`^postgres:([0-9]+)\.[0-9]+@sha256:[0-9a-f]{64}$`)
	var bad []string
	for _, major := range slices.Sorted(maps.Keys(images)) {
		m := pinned.FindStringSubmatch(images[major])
		if m == nil || m[1] != fmt.Sprint(major) {
			bad = append(bad, fmt.Sprintf("%d: %s", major, images[major]))
		}
	}
	return bad
}

// The PostgreSQL client images the update and the restore run with the
// database URL are each pinned by digest to the major they serve, the
// probe's among them; no other PostgreSQL image is spelled in the CLI's
// sources; and the pin of each major CI's PostgreSQL service runs is the
// release CI runs.
func TestPostgresClientImagesArePinned(t *testing.T) {
	if bad := unpinnedPostgresImages(pgClientImages); len(bad) != 0 {
		t.Errorf("unpinned PostgreSQL client images: %v", bad)
	}
	for name, planted := range map[string]map[int]string{
		"a floating tag":         {18: "postgres:18"},
		"a tag without a digest": {18: "postgres:18.6"},
		"another major's image":  {17: pgClientImages[18]},
	} {
		if bad := unpinnedPostgresImages(planted); len(bad) != 1 {
			t.Errorf("%s was not refused: %v", name, bad)
		}
	}
	if _, ok := pgClientImages[pgProbeMajor]; !ok {
		t.Errorf("the probe's major %d has no pinned image", pgProbeMajor)
	}

	sources, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	spelled := 0
	for _, name := range sources {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		spelled += strings.Count(string(data), `"postgres:`)
	}
	if spelled != len(pgClientImages) {
		t.Errorf("the CLI's sources spell %d PostgreSQL images, want only the %d pins", spelled, len(pgClientImages))
	}

	workflow, err := os.ReadFile(filepath.Join("..", "..", "..", ".github", "workflows", "test.yml"))
	if err != nil {
		t.Fatal(err)
	}
	services := regexp.MustCompile(`(?m)^\s*image:\s*postgres:(([0-9]+)\.[0-9]+)\s*$`).FindAllStringSubmatch(string(workflow), -1)
	if len(services) == 0 {
		t.Fatal("test.yml runs no PostgreSQL service image this test can read")
	}
	for _, service := range services {
		var major int
		fmt.Sscan(service[2], &major)
		if pin := pgClientImages[major]; !strings.HasPrefix(pin, "postgres:"+service[1]+"@") {
			t.Errorf("CI's PostgreSQL service runs postgres:%s, and the CLI pins %q for %d", service[1], pin, major)
		}
	}
}

// A PostgreSQL server of a major no pinned client serves refuses the
// update before anything is pulled or stopped, naming the major.
func TestUpdateRefusesAPostgresMajorWithoutAPinnedClient(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL})
	s.answer("probe.out", "190001\n")
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "the PostgreSQL server is version 19") || !strings.Contains(err.Error(), "nothing was changed") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	if s.hasCall("pull ") || slices.ContainsFunc(s.log(), func(line string) bool { return strings.Contains(line, "postgres:19") }) {
		t.Errorf("the update pulled or ran an image for the unpinned major:\n%s", strings.Join(s.log(), "\n"))
	}
	s.nothingStopped()
	s.composeUnchanged()
	s.noBackups()
}

// A compose file whose missing fields cannot be written fails the switch:
// the file the update read is put back whole and the old stack starts
// again under it, and nothing is passed off as a note. When the file
// cannot be put back either, the old stack is not started under the
// switched file and the snapshot is named.
func TestSwitchFailsWhenTheComposeFieldsCannotBeWritten(t *testing.T) {
	// cyfr's container_name, a field the switch adds when it is missing.
	const name = "    container_name: cyfr\n"
	shipped := string(shippedCompose(t))
	if !strings.Contains(shipped, name) {
		t.Fatal("the shipped compose file names no container_name: cyfr")
	}
	compose := []byte(strings.Replace(shipped, name, "", 1))
	for _, c := range []struct {
		name     string
		failures int
		want     string
		restart  bool
	}{
		{"the fields' write fails", 1, "it was put back as the update read it", true},
		{"the put-back fails too", 2, "cyfr restore ", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newUpdateScenario(t, compose, nil)
			calls := 0
			original := replaceCompose
			t.Cleanup(func() { replaceCompose = original })
			replaceCompose = func(path string, data []byte, mode os.FileMode) error {
				if calls++; calls <= c.failures {
					return fmt.Errorf("write %s: planted failure", path)
				}
				return original(path, data, mode)
			}
			out, err := s.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), "could not gain the fields cyfr requires") || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("update answered %v\n%s", err, out)
			}
			if strings.Contains(out, "Note:") {
				t.Errorf("the failure was reported as a note:\n%s", out)
			}
			want := []string{}
			if c.restart {
				want = []string{md5Hex(s.compose)}
			}
			if got := s.startedComposes(); !slices.Equal(got, want) {
				t.Errorf("the stack started under %v, want %v (the old stack again: %v, the new release never):\n%s", got, want, c.restart, strings.Join(s.log(), "\n"))
			}
			if c.restart {
				s.composeUnchanged()
			}
		})
	}
}

// The fields' rewrite replaces the compose file whole and keeps its mode.
func TestComposeFieldsRewriteKeepsTheFileMode(t *testing.T) {
	const aqua = "      - ./aqua:/app/seed/aqua\n"
	path := filepath.Join(t.TempDir(), "docker-compose.yml")
	if err := os.WriteFile(path, []byte(strings.Replace(string(shippedCompose(t)), aqua, "", 1)), 0600); err != nil {
		t.Fatal(err)
	}
	if added, err := ensureCyfrComposeFields(path); err != nil || len(added) == 0 {
		t.Fatalf("added %v (error %v)", added, err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Errorf("the rewritten compose file is %v (error %v), want 0600", info.Mode().Perm(), err)
	}
	if entries, _ := os.ReadDir(filepath.Dir(path)); len(entries) != 1 {
		t.Errorf("the rewrite left %d files beside the compose file", len(entries)-1)
	}
}

// 'cyfr up' refuses while an update holds the lock, in the window where the
// update has stopped the stack and copies its data, and runs no docker.
func TestUpRefusesWhileAnUpdateHoldsTheLock(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("eval.block", "")
	done := make(chan error, 1)
	go func() { done <- runUpdate(context.Background(), io.Discard, io.Discard) }()
	offline := profiles + "run --rm --no-deps -T cyfr bin/cyfr eval " + testLive
	deadline := time.Now().Add(10 * time.Second)
	for !s.hasCall(offline) {
		if time.Now().After(deadline) {
			s.answer("eval.release", "")
			t.Fatal("the update never reached its offline read")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !s.hasCall(profiles + "stop") {
		t.Fatalf("the update reached its offline read with nothing stopped:\n%s", strings.Join(s.log(), "\n"))
	}
	calls := len(s.log())
	err := upCmd.RunE(upCmd, nil)
	s.answer("eval.release", "")
	if err == nil || !strings.Contains(err.Error(), "Another cyfr command holds this home (`update`)") || !strings.Contains(err.Error(), "Nothing was changed") {
		t.Errorf("cyfr up answered %v, want the refusal naming the lock's holder", err)
	}
	if got := s.log(); len(got) != calls {
		t.Errorf("cyfr up ran docker while the update held the lock: %s", strings.Join(got[calls:], "\n"))
	}
	if err := <-done; err != nil {
		t.Fatalf("the update: %v", err)
	}
	if holder := s.engine.held(); holder != "" {
		t.Errorf("the lock stands after the update (held by %s), so cyfr up would still refuse", holder)
	}
}

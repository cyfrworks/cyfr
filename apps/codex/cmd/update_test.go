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
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/access"
	"github.com/cyfr/codex/internal/apparmor"
	"github.com/cyfr/codex/internal/release"
	"github.com/cyfr/codex/internal/version"
	"gopkg.in/yaml.v3"
)

// unsetenv unsets key for the test and restores it after.
func unsetenv(t *testing.T, key string) {
	t.Setenv(key, "")
	os.Unsetenv(key)
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
// update runs; the schema read finds the running cyfr from cyfrps.* and
// answers from schema.*, through it or offline; the list of a project's
// networks answers from network-ls-<project>.*, a line of id and compose
// network name each, the containers attached to network id from
// network-ours-<id>.* (this project's) and network-all-<id>.*, and its
// removal from network-rm-<id>.*; an `up -d --no-deps`, the start of the
// services beside the head's, answers from up-no-deps.*; <key>.signal
// sends SIGTERM to the updating process first and <key>.block waits for
// <key>.release. eval.live answers that many live reads first.
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
  [ -f "$d/$1.err" ] && cat "$d/$1.err" >&2
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
    up) case "$*" in *--no-deps*) answer up-no-deps ;; *) answer up ;; esac ;;
    ps) case "$*" in *--format*) answer stack ;; *) answer ps ;; esac ;;
    config) case "$*" in *--services*) answer services ;; *) answer config ;; esac ;;
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
  inspect) answer inspect ;;
  network)
    last="${@: -1}"
    case "$2" in
      ls) answer "network-ls-${last##*=}" ;;
      rm) answer "network-rm-$3" ;;
    esac ;;
  ps)
    case "$*" in
      *'.Label "com.docker.compose.service"'*) last="${@: -1}"; answer "containers-${last##*=}" ;;
      *network=*)
        n="$*"
        n="${n##*network=}"
        n="${n%% *}"
        case "$*" in *compose.project=*) answer "network-ours-$n" ;; *) answer "network-all-$n" ;; esac ;;
      *) answer cyfrps ;;
    esac ;;
  rm) answer rm ;;
  exec) answer schema ;;
  pull)
    if [ -f "$d/pull.fail" ] && [[ "$2" == *"$(cat "$d/pull.fail")"* ]]; then exit 1; fi
    answer pull ;;
  run)
    case "$*" in
      *CYFR_SCHEMA*) answer schema ;;
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
	testSchema  = `IO.puts("CYFR_SCHEMA=" <> Arca.SchemaFingerprint.current()); IO.puts("CYFR_RELEASE=" <> Prima.Version.current())`
	// testSchemaContainer names the scenarios' offline read's container.
	testSchemaContainer = "cyfr-schema-read-test"
	keyBase             = "kb-secret-0123456789abcdef"
	keyring             = `{"keys":[{"id":"k1","key":"keyring-secret-value"}]}`
	pgPassword          = "pg-secret-pw-77"
	pgURL               = "postgres://cyfr:" + pgPassword + "@127.0.0.1:5432/cyfr"
)

var (
	digestCyfr      = "sha256:" + strings.Repeat("a", 64)
	digestLocus     = "sha256:" + strings.Repeat("b", 64)
	digestCaddy     = "sha256:" + strings.Repeat("c", 64)
	digestTailscale = "sha256:" + strings.Repeat("d", 64)
	takenAt         = time.Date(2026, 10, 16, 12, 0, 0, 0, time.UTC)
	// schemaRelease is the release's schema fingerprint, which the
	// scenarios' running cyfr answers too; schemaOther is another schema's.
	schemaRelease = strings.Repeat("5e", 32)
	schemaOther   = strings.Repeat("a0", 32)
	testImages    = release.Images{Cyfr: digestCyfr, CyfrLocus: digestLocus, Caddy: digestCaddy, Tailscale: digestTailscale}
)

// scenarioEnv is the .env of the scenarios' home: public at
// cyfr.example.com, builds on.
const scenarioEnv = "CYFR_ACCESS=public\nCYFR_HOST=cyfr.example.com\nCYFR_PUBLIC_URL=https://cyfr.example.com\nCYFR_PORT=4000\n"

// stackImage is the image the scenarios' cyfr service runs, through which
// a snapshot reads the storage.
const stackImage = "ghcr.io/cyfrworks/cyfr:0.8.0"

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
	// examples are the .env.example each release's scaffold ships, by
	// version; a release with none ships none.
	examples map[string]string
	// composes are the docker-compose.yml each release's scaffold ships,
	// by version; a release with none ships the repository's.
	composes map[string]string
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

// fakeScaffold is the scenarios' scaffold of release v: Write writes
// newScaffold into the project for real, logging SCAFFOLD WRITE, and File
// answers the .env.example the scenario gives v.
type fakeScaffold struct {
	s *updateScenario
	v string
}

func (f fakeScaffold) File(name string) ([]byte, bool) {
	if name == "docker-compose.yml" {
		if compose, ok := f.s.composes[f.v]; ok {
			return []byte(compose), true
		}
		return shippedCompose(f.s.t), true
	}
	example, ok := f.s.examples[f.v]
	if name != ".env.example" || !ok {
		return nil, false
	}
	return []byte(example), true
}

func (f fakeScaffold) Managed() []string {
	var names []string
	for _, file := range newScaffold {
		names = append(names, file.name)
	}
	return names
}

func (f fakeScaffold) Check() error { return nil }

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
	profiles = strings.Join(composePrefixArgs(access.ProjectName(s.project), scenarioHead), " ") + " "

	environment := map[string]any{"CYFR_SECRET_KEY_BASE": keyBase, "CYFR_CRYPTO_KEYRING": keyring, "CYFR_HOST": "localhost"}
	for k, v := range env {
		environment[k] = v
	}
	config, _ := json.Marshal(map[string]any{"services": map[string]any{"cyfr": map[string]any{
		"image":       stackImage,
		"environment": environment,
		"volumes": []map[string]any{
			{"type": "bind", "source": filepath.Join(s.project, "data"), "target": "/app/data", "bind": map[string]any{}},
			{"type": "bind", "source": filepath.Join(s.project, "aqua"), "target": "/app/seed/aqua"},
		},
	}}})
	s.answer("config.out", string(config))
	s.answer("ps.out", "locus-guard\ncyfr\ncaddy\ntailscale\nlocus\nsidecar\n")
	s.answer("rpc.out", "warming up\nCYFR_ROSTER="+`{"self":"cyfr@abc","release":"0.8.0","slots":[{"node":"cyfr@abc","owner":"o1","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"}]}`+"\n")
	s.answer("eval.out", "booting\nCYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[]}`+"\n")
	s.answer("eval-live.out", "CYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[{"node":"cyfr@abc","owner":"o1","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"}]}`+"\n")
	s.answer("cyfrps.out", "c0ffee\n")
	s.answer("services.out", strings.Join(stackServices, "\n")+"\n")
	s.stackAnswer(nil)
	s.answer("schema.out", "booting\nCYFR_SCHEMA="+schemaRelease+"\nCYFR_RELEASE=0.8.0\n")
	s.answer("probe.out", "180006\n")
	s.answer("dump.out", "PGDMP custom-format dump")

	savedVersion, savedFetch, savedScaffold, savedNow := version.Version, fetchManifest, fetchScaffold, updateNow
	savedWindow, savedPoll := liveSlotsWindow, liveSlotsPoll
	savedName := schemaContainerName
	schemaContainerName = func() string { return testSchemaContainer }
	t.Cleanup(func() {
		schemaContainerName = savedName
		version.Version, fetchManifest, fetchScaffold, updateNow = savedVersion, savedFetch, savedScaffold, savedNow
		liveSlotsWindow, liveSlotsPoll = savedWindow, savedPoll
	})
	version.Version = testVersion
	fetchManifest = func(ctx context.Context, v string) (*release.Manifest, error) {
		return &release.Manifest{Version: v, Images: testImages, SchemaFingerprint: schemaRelease}, nil
	}
	fetchScaffold = func(v string) (scaffoldRelease, error) {
		s.scaffold++
		s.logLine("SCAFFOLD FETCH " + v)
		return fakeScaffold{s, v}, nil
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

// stackServices are the services the scenarios' started stack runs, as
// `docker compose config --services` names them under the head.
var stackServices = []string{"caddy", "cyfr", "locus", "locus-guard"}

// stackAnswer sets the started stack's containers, as `docker compose ps
// --format json` writes them, one line each: every service of
// stackServices running and healthy, but those states names, each as
// "state" or "state/health".
func (s *updateScenario) stackAnswer(states map[string]string) {
	s.t.Helper()
	var lines []string
	for _, svc := range stackServices {
		state, health := "running", "healthy"
		if given, ok := states[svc]; ok {
			state, health, _ = strings.Cut(given, "/")
		}
		line, _ := json.Marshal(map[string]string{"Name": "p-" + svc + "-1", "Service": svc, "State": state, "Health": health})
		lines = append(lines, string(line))
	}
	s.answer("stack.out", strings.Join(lines, "\n")+"\n")
}

// homeStep is `cyfr update`'s home step, the change confirmed.
func homeStep(ctx context.Context, out, errOut io.Writer) error {
	return runHomeUpdate(ctx, out, errOut, updateOptions{yes: true})
}

// run runs `cyfr update` and answers its error and its output; the lock is
// released after it and no docker child shared cyfr's process group.
func (s *updateScenario) run(ctx context.Context) (string, error) {
	s.t.Helper()
	var out bytes.Buffer
	err := homeStep(ctx, &out, &out)
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

// schemaRead is the docker log of the schema read, which runs before the
// lock: the running cyfr found by its compose labels and asked, or, with
// none running, a one-off container of its image that mounts nothing,
// skips the entrypoint, has no network and never pulls.
func (s *updateScenario) schemaRead(running bool) []string {
	reads := []string{"ps -q --filter label=com.docker.compose.project=" + access.ProjectName(s.project) + " --filter label=com.docker.compose.service=cyfr --filter status=running"}
	if running {
		return append(reads, "exec c0ffee bin/cyfr rpc "+testSchema)
	}
	// The image the compose file named when the update read it.
	original := filepath.Join(s.t.TempDir(), "docker-compose.yml")
	if err := os.WriteFile(original, s.compose, 0600); err != nil {
		s.t.Fatal(err)
	}
	image := imagesFromCompose(original, nil)[0]
	return append(reads,
		"run --rm --name "+testSchemaContainer+" --pull never --network none --read-only --user app --entrypoint /usr/bin/timeout -e CYFR_ACCESS=local -e CYFR_SECRET_KEY_BASE "+image+" 90 /app/bin/cyfr eval "+testSchema+" {env CYFR_SECRET_KEY_BASE set}",
		"rm -f "+testSchemaContainer)
}

// scenarioHead is the access head scenarioEnv holds.
var scenarioHead = access.Head{Mode: access.ModePublic, Host: "cyfr.example.com", PublicURL: "https://cyfr.example.com", Port: 4000, Profiles: []string{"public"}}

// profiles is the engine's compose selection for the scenario's head and
// project, as the fake docker logs it (newUpdateScenario sets it).
var profiles string

// started is the engine's start, as the fake engine logs it and the fake
// docker logs the compose call it runs.
func started(cause string) []string {
	return []string{"ENGINE start " + cause, profiles + "up -d"}
}

// startedAndUp is the new release's start, as started logs it, then the
// update's wait for every service of the stack it started.
func startedAndUp() []string {
	return append(started("update"), profiles+"config --services", profiles+"ps --format json")
}

// The happy path runs the six steps in their order: the configuration, the
// release's scaffold fetched and the pulls by digest of its compose file's
// images, the roster through the running cyfr, each service stopped in
// order, the offline re-read until no slot is live, the snapshot
// (snapshot.json last, 0700 and 0600), the release's compose file written
// pinned, and the start that waits for cyfr's health, then every service's.
func TestUpdateRunsTheCeremonyInOrder(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("eval.live", "1")
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	want := append(s.offerReads(),
		"ENGINE lock update",
		"ENGINE resume",
		profiles+"config --format json")
	want = append(append(want, s.placeReads()...),
		"SCAFFOLD FETCH "+testVersion,
		"pull ghcr.io/cyfrworks/cyfr@"+digestCyfr,
		"pull ghcr.io/cyfrworks/cyfr-locus@"+digestLocus,
		"pull caddy@"+digestCaddy,
		"pull tailscale/tailscale@"+digestTailscale,
		profiles+"ps --services --status running",
		profiles+"exec -T cyfr bin/cyfr rpc "+testRoster,
		"ENGINE cancel-waiting-join",
		"ENGINE hold update",
		"ENGINE close-serve",
		profiles+"stop caddy",
		profiles+"stop tailscale",
		profiles+"stop cyfr",
		profiles+"stop locus",
		profiles+"stop locus-guard",
		profiles+"stop",
		profiles+"run --rm --no-deps -T cyfr bin/cyfr eval "+testLive,
		profiles+"run --rm --no-deps -T cyfr bin/cyfr eval "+testLive)
	want = append(append(want, s.snapshotReads()...),
		containerList(access.ProjectName(s.project)),
		networkList(access.ProjectName(s.project)),
		"ENGINE release",
		"SCAFFOLD WRITE",
		"ENGINE start update",
		profiles+"up -d",
		profiles+"config --services",
		profiles+"ps --format json",
	)
	logged := s.namedLog()
	if !slices.Equal(logged, want) {
		t.Fatalf("docker ran\n%s\nwant\n%s", strings.Join(logged, "\n"), strings.Join(want, "\n"))
	}

	// Before the switch every call saw the old compose file, and every one
	// before the list of the project's networks no complete snapshot; the
	// start saw the switched file and the snapshot.
	sum := func(data []byte) string { return fmt.Sprintf("%x", md5.Sum(data)) }
	state, _ := os.ReadFile(filepath.Join(s.fake, "state"))
	for _, line := range strings.Split(strings.TrimSpace(string(state)), "\n") {
		fields := strings.Fields(line)
		wantSum, wantSnapshots := sum(s.compose), "0"
		switch {
		case fields[0] == "up" || fields[0] == "services" || fields[0] == "stack":
			wantSum, wantSnapshots = sum(switched(s.compose)), "1"
		case strings.HasPrefix(fields[0], "network-ls-") || strings.HasPrefix(fields[0], "containers-"):
			wantSnapshots = "1"
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
	if n := strings.Count(string(got), "@sha256:"); n != 5 {
		t.Errorf("the switched docker-compose.yml pins %d images, want 5 (cyfr, locus and locus-guard on cyfr-locus, caddy, tailscale)", n)
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
	// The update names the root with its links resolved: macOS's temporary
	// directory lies under /var, a link to /private/var.
	hostRoot, err := filepath.EvalSymlinks(filepath.Join(s.project, "data"))
	if err != nil {
		t.Fatal(err)
	}
	storageRoot := "Storage root /app/data is " + hostRoot + " on the host."
	for _, line := range []string{storageRoot, "stopped caddy in ", "stopped tailscale in ", "stopped cyfr in ", "stopped locus-guard in ", "stopped sidecar in ", "Updated to release 0.9.0.", "Snapshot of release 0.8.0: " + dir} {
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
	if config < 0 || at(probe) != config+1 || at("pull "+pg18) < config+2 || at("pull "+pg18) > at(profiles+"exec -T cyfr bin/cyfr rpc "+testRoster) {
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
	// The refusal writes no scaffold file.
	if s.hasCall("SCAFFOLD WRITE") {
		t.Errorf("the update refreshed the scaffold files before refusing:\n%s", strings.Join(s.log(), "\n"))
	}
	s.nothingStopped()
	s.composeUnchanged()
	s.noBackups()
}

// A cell on several hosts: one host was updated and started first, so its
// member runs the target release. The next host's update admits that live
// member, before the stop and in the offline read, and goes on; a member
// of another release is refused.
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

	t.Run("another release", func(t *testing.T) {
		other := `{"node":"cyfr@first-host","owner":"o2","release":"0.7.9","lease_until":"2026-10-16T12:00:12Z"}`
		s := newUpdateScenario(t, compose, nil)
		s.answer("rpc.out", "CYFR_ROSTER="+`{"self":"cyfr@abc","release":"0.8.0","slots":[`+other+`]}`+"\n")
		out, err := s.run(context.Background())
		if err == nil || !strings.Contains(err.Error(), "cyfr@first-host (release 0.7.9)") {
			t.Fatalf("update answered %v\n%s", err, out)
		}
		s.nothingStopped()
		s.composeUnchanged()
		s.noBackups()
	})

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
	s.answer("stop-locus.exit", "1")
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "stop locus failed") {
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
	// The boot's refusal, whichever part of cyfr logged it, is said.
	const fatal = "[Arca] FATAL: /app/data/cyfr.db was built from a different schema (a0a0); this release's schema is 5e5e. There is no upgrade path."
	s.answer("logs.out", "starting\n12:00:00.000 [error] "+fatal+"\n")
	out, err := s.run(context.Background())
	if err == nil {
		t.Fatalf("update succeeded\n%s", out)
	}
	want := "Release 0.9.0 did not start (cyfr did not become healthy (docker compose up: exit status 1)); the stack is left stopped.\n" +
		"A service refused to boot, and its log says why:\n  " + fatal + "\n" +
		"The snapshot of release 0.8.0 is " + s.snapshotDir() + "; restore it with:\n  cyfr restore " + s.snapshotDir()
	if err.Error() != want {
		t.Errorf("the refusal is\n%v\nwant\n%s", err, want)
	}
	log := s.log()
	if n := len(log); n < 4 || !slices.Equal(log[n-4:], []string{profiles + "up -d", "ENGINE close-serve", profiles + "stop", profiles + "logs --no-color --no-log-prefix --tail 200"}) {
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
	want := access.Refuse("tailnet_node_mismatch", mismatch()).Message()

	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.engine.startReceipt = startedLocalReceipt("start")
	out, err := s.run(context.Background())
	if err == nil || err.Error() != want || ExitStatus(err) != exitStartedLocally || !strings.Contains(out, "Updated to release 0.9.0.") {
		t.Fatalf("update answered %v (exit %d), want %q and exit %d after the report\n%s", err, ExitStatus(err), want, exitStartedLocally, out)
	}
	if log := s.log(); !slices.Equal(log[len(log)-4:], startedAndUp()) {
		t.Errorf("the update did more than start the new release and wait for it:\n%s", strings.Join(log, "\n"))
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
	allowed := func(c access.Call) time.Duration {
		line := strings.Join(c.Args, " ")
		switch {
		case c.Args[0] == "pull":
			return pullTimeout
		case strings.Contains(line, "pg_dump") || strings.Contains(line, "pg_restore"):
			return dumpTimeout
		case stackReadCall(c.Args):
			return stackReadBackstop
		case slices.Contains(c.Args, "stop") || c.Args[0] == "network" || line == containerList(access.ProjectName(".")):
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
// scaffold fetched is not written and no snapshot is taken.
func TestUpdateRefusesAFailedPull(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("pull.fail", "cyfr-locus@")
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "docker pull ghcr.io/cyfrworks/cyfr-locus@"+digestLocus+" failed") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	want := append(append(s.offerReads(), "ENGINE lock update", "ENGINE resume", profiles+"config --format json"), s.placeReads()...)
	want = append(want, "SCAFFOLD FETCH "+testVersion, "pull ghcr.io/cyfrworks/cyfr@"+digestCyfr, "pull ghcr.io/cyfrworks/cyfr-locus@"+digestLocus)
	if got := s.namedLog(); !slices.Equal(got, want) {
		t.Errorf("docker ran\n%s", strings.Join(got, "\n"))
	}
	s.composeUnchanged()
	s.noBackups()
}

// Of the release's compose file only image lines naming a manifest
// repository are pinned, the guards' and Caddy's among them; an override,
// an interpolated line and a look-alike repository are written byte for
// byte as the release ships them. The person's file's own such lines are
// reported, as the release's file does not keep them, and only the
// release's managed images are pulled.
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
	compose = replaceImage(compose, "locus", `"${LOCUS_IMAGE:-ghcr.io/cyfrworks/cyfr-locus:latest}"`)
	compose = replaceImage(compose, "locus-guard", "'ghcr.io/cyfrworks/cyfr-locus:latest' # quoted")
	s := newUpdateScenario(t, []byte(compose), nil)
	s.composes = map[string]string{testVersion: compose}
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	want := replaceImage(compose, "locus-guard", "'ghcr.io/cyfrworks/cyfr-locus:"+testVersion+"@"+digestLocus+"' # quoted")
	_, caddyTag, _ := strings.Cut(string(regexp.MustCompile(`image: caddy:[^@\n]+`).Find([]byte(shipped))), "caddy:")
	want = replaceImage(want, "caddy", "caddy:"+caddyTag+"@"+digestCaddy)
	_, tailscaleTag, _ := strings.Cut(string(regexp.MustCompile(`image: tailscale/tailscale:[^@\n]+`).Find([]byte(shipped))), "tailscale/tailscale:")
	want = replaceImage(want, "tailscale", "tailscale/tailscale:"+tailscaleTag+"@"+digestTailscale)
	if got, _ := os.ReadFile("docker-compose.yml"); string(got) != want {
		t.Errorf("the switched docker-compose.yml is\n%s\nwant\n%s", got, want)
	}
	for _, line := range []string{
		"  cyfr: myregistry.example/cyfr:custom\n",
		"  locus: ${LOCUS_IMAGE:-ghcr.io/cyfrworks/cyfr-locus:latest}\n",
	} {
		if !strings.Contains(out, line) {
			t.Errorf("the output does not report %q:\n%s", line, out)
		}
	}
	if s.hasCall("pull ghcr.io/cyfrworks/cyfr@") || !s.hasCall("pull ghcr.io/cyfrworks/cyfr-locus@"+digestLocus) || !s.hasCall("pull caddy@"+digestCaddy) || !s.hasCall("pull tailscale/tailscale@"+digestTailscale) {
		t.Errorf("the pulls are\n%s", strings.Join(s.log(), "\n"))
	}
}

// lastReleaseCompose is the compose file of the last release's shape,
// three Locus containers (testdata/three-container, as main shipped it at
// bfb14c188), its images on release 0.8.0.
func lastReleaseCompose(t *testing.T) string {
	t.Helper()
	old := read(t, filepath.Join(packageDir, "testdata", "three-container", "compose.yml"))
	for _, edit := range []struct{ from, to string }{
		{"ghcr.io/cyfrworks/cyfr:latest", "ghcr.io/cyfrworks/cyfr:0.8.0@" + digestOld},
		{"ghcr.io/cyfrworks/cyfr-locus:latest", "ghcr.io/cyfrworks/cyfr-locus:0.8.0@" + digestOld},
	} {
		if !strings.Contains(old, edit.from) {
			t.Fatalf("the three-container docker-compose.yml holds no %q", edit.from)
		}
		old = strings.ReplaceAll(old, edit.from, edit.to)
	}
	return old
}

// An install whose docker-compose.yml is the last release's shape, with a
// service of the person's own they accept to lose, is switched to the
// release's own file, its images pinned to the manifest's digests, every
// other line of the old file gone: the snapshot holds the file it
// replaced, and the update says once where it is and which of its image
// lines the release's file does not keep, as the offer said before.
func TestUpdateWritesTheReleasesComposeFile(t *testing.T) {
	shipped := lastReleaseCompose(t)
	old := strings.Replace(shipped, "\n  caddy:\n", "\n  sidecar:\n    image: alpine:3.22\n  caddy:\n", 1)
	s := newUpdateScenario(t, []byte(old), nil)
	// Release 0.8.0 shipped its shape; the sidecar is the person's own,
	// whose loss the update asks about first.
	s.composes = map[string]string{"0.8.0": shipped}
	askWith(t, true, strings.NewReader("yes\n"))
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	if got := read(t, filepath.Join(s.project, "docker-compose.yml")); got != string(switched(shippedCompose(t))) {
		t.Errorf("the switched docker-compose.yml is not the release's, pinned:\n%s", got)
	}
	if info, err := os.Stat(filepath.Join(s.project, "docker-compose.yml")); err != nil || info.Mode().Perm() != 0640 {
		t.Errorf("the switched docker-compose.yml's mode is %v (error %v), want 0640 kept", info.Mode().Perm(), err)
	}
	if held := read(t, filepath.Join(s.snapshotDir(), "compose")); held != old {
		t.Errorf("the snapshot's compose is not the file the update replaced:\n%s", held)
	}
	sentence := "docker-compose.yml is now release 0.9.0's own file; the one it replaced, with any edits you made to it, is " + filepath.Join(s.snapshotDir(), "compose") + ", to copy back from what you still need. Its image lines cyfr update does not manage are not in the new file: sidecar: alpine:3.22.\n"
	if n := strings.Count(out, sentence); n != 1 {
		t.Errorf("the update said %d times %q:\n%s", n, sentence, out)
	}
	for _, line := range []string{
		"replaces docker-compose.yml with release 0.9.0's own",
		"Image lines cyfr update does not manage, which release 0.9.0's docker-compose.yml does not keep:\n  sidecar: alpine:3.22\n",
	} {
		if !strings.Contains(out, line) {
			t.Errorf("the offer lacks %q:\n%s", line, out)
		}
	}
	if !s.hasCall("pull ghcr.io/cyfrworks/cyfr-locus@"+digestLocus) || s.hasCall("pull alpine") {
		t.Errorf("the pulls are not the release's file's:\n%s", strings.Join(s.log(), "\n"))
	}
}

// An install of the three-container release, its docker-compose.yml and
// .env.example as that release shipped them (testdata/three-container),
// updated to this tree's: no old service's name refuses it; its compose
// file, the release's own, is replaced without a word about edits; each
// old Locus service stops with the rest; this project's networks, listed
// by its compose label, that the new file does not use are removed after
// the stop and the snapshot and before the switch, each after this
// project's containers on it, and no other network; the offer names each
// image that changes, never an old service; and .env loses
// CYFR_LOCUS_BUILDS_URL, which this release does not read, takes the new
// shipped CYFR_PRIVATE_EGRESS_TARGETS, keeps the builds key, and a worker
// list the person set naming locus-runtime is left and reported by its key
// and its line in .env as the update leaves it, with what to write there,
// never its value.
// cyfrBackendsURL is the CYFR_LOCUS_BACKENDS_URL the cyfr service of the
// compose file at composePath starts with under the .env at envPath, its
// `${NAME:-default}` read as compose reads it: .env's value unless empty,
// else the default.
func cyfrBackendsURL(t *testing.T, composePath, envPath string) string {
	t.Helper()
	var doc struct {
		Services map[string]struct {
			Environment []string `yaml:"environment"`
		} `yaml:"services"`
	}
	if err := yaml.Unmarshal([]byte(read(t, composePath)), &doc); err != nil {
		t.Fatal(err)
	}
	held, err := access.ReadEnvValues(envPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range doc.Services["cyfr"].Environment {
		value, ok := strings.CutPrefix(entry, "CYFR_LOCUS_BACKENDS_URL=")
		if !ok {
			continue
		}
		if inner, ok := strings.CutPrefix(value, "${CYFR_LOCUS_BACKENDS_URL:-"); ok && strings.HasSuffix(inner, "}") {
			if set := held["CYFR_LOCUS_BACKENDS_URL"]; set != "" {
				return set
			}
			return strings.TrimSuffix(inner, "}")
		}
		return value
	}
	return held["CYFR_LOCUS_BACKENDS_URL"]
}

// threeContainerBuildsKey is the builds key the three-container scenario's
// .env holds.
const threeContainerBuildsKey = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1"

// retiredNetworks are the networks the three-container release declares
// and this one does not use, in order; the scenario's network i is net<i>,
// its one container of the project ctrnet<i>.
var retiredNetworks = []string{"locus-backends", "locus-builds", "locus-runtime"}

// answerNetworks answers the list of the scenario's project's networks
// with lines, each a network's id and compose name.
func (s *updateScenario) answerNetworks(lines ...string) {
	s.answer("network-ls-"+access.ProjectName(s.project)+".out", strings.Join(lines, "\n")+"\n")
}

// containerList is the list of the compose project's containers
// removeContainers reads, each container's id and compose service.
func containerList(project string) string {
	return `ps -a --no-trunc --format {{.ID}} {{.Label "com.docker.compose.service"}} --filter label=com.docker.compose.project=` + project
}

// answerContainers answers the list of the scenario's project's containers
// with lines, each a container's id and compose service.
func (s *updateScenario) answerContainers(lines ...string) {
	s.answer("containers-"+access.ProjectName(s.project)+".out", strings.Join(lines, "\n")+"\n")
}

// networkList is the list of the compose project's networks removeNetworks
// reads, each network's id and compose name.
func networkList(project string) string {
	return `network ls --format {{.ID}} {{.Label "com.docker.compose.network"}} --filter label=com.docker.compose.project=` + project
}

// newThreeContainerScenario is an update from the three-container release
// with builds on: every service of its stack running, the builder and its
// guard among them, the project's networks those the release declares,
// each retired one holding one container of the project, and .env as that
// release left it.
func newThreeContainerScenario(t *testing.T) *updateScenario {
	old := lastReleaseCompose(t)
	s := newUpdateScenario(t, []byte(old), nil)
	s.composes = map[string]string{"0.8.0": old}
	s.examples = map[string]string{
		"0.8.0":     read(t, filepath.Join(packageDir, "testdata", "three-container", "env.example")),
		testVersion: readShippedTemplate(t),
	}
	s.answer("ps.out", "locus-backends-guard\ncyfr\ncaddy\nlocus-runtime\nlocus-builds\nlocus-builds-guard\nlocus-backends\n")
	networks := []string{"netd default", "nete edge"}
	for i, name := range retiredNetworks {
		id := fmt.Sprintf("net%d", i)
		networks = append(networks, id+" "+name)
		s.answer("network-ours-"+id+".out", "ctr"+id+"\n")
		s.answer("network-all-"+id+".out", "ctr"+id+"\n")
	}
	s.answerNetworks(networks...)
	s.answerContainers("c0 cyfr", "c1 locus-runtime", "c2 locus-builds", "c3 locus-builds-guard", "c4 locus-backends", "c5 locus-backends-guard", "c6 caddy")
	s.edit(".env", scenarioEnv+
		"CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\n"+
		"CYFR_LOCUS_BUILDS_KEY="+threeContainerBuildsKey+"\n"+
		"CYFR_PRIVATE_EGRESS_TARGETS=locus-backends\n"+
		"CYFR_LOCUS_RUNTIME_WORKERS=wrk_locus=http://locus-runtime:4200\n"+
		"LOCUS_RUNTIME_MEMORY_LIMIT=4GB\n")
	return s
}

// withProfiles adds to the scenario's `compose config` answer each named
// service with its profiles, as compose writes the services its selection
// runs.
func (s *updateScenario) withProfiles(profiles map[string][]string) {
	s.t.Helper()
	raw, err := os.ReadFile(filepath.Join(s.fake, "config.out"))
	if err != nil {
		s.t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(raw, &config); err != nil {
		s.t.Fatal(err)
	}
	for name, p := range profiles {
		config["services"].(map[string]any)[name] = map[string]any{"profiles": p}
	}
	if raw, err = json.Marshal(config); err != nil {
		s.t.Fatal(err)
	}
	s.answer("config.out", string(raw))
}

// buildsSelection is the compose selection the three-container stack with
// builds on runs under: the scenario's head and the builds' own profile.
func (s *updateScenario) buildsSelection() string {
	h := scenarioHead
	h.Profiles = []string{"public", "locus-builds"}
	return strings.Join(composePrefixArgs(access.ProjectName(s.project), h), " ") + " "
}

// The three-container release ran its builder and the builder's guard
// under a profile of their own, which .env's head does not name: the
// update lists and stops its stack under that profile beside the head's,
// so the network the builder's guard sits on is removed once both are
// stopped.
func TestUpdateStopsTheThreeContainerBuildsUnderTheirProfile(t *testing.T) {
	s := newThreeContainerScenario(t)
	s.withProfiles(buildsProfiles)
	if out, err := s.run(context.Background()); err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	log, builds := s.log(), s.buildsSelection()
	for _, call := range []string{builds + "ps --services --status running", builds + "stop caddy", builds + "stop cyfr", builds + "stop"} {
		if !slices.Contains(log, call) {
			t.Errorf("the update did not run %q:\n%s", call, strings.Join(log, "\n"))
		}
	}
	if stopped, removed := slices.Index(log, builds+"stop"), slices.Index(log, "network rm net1"); removed < 0 || removed < stopped || slices.Index(log, "rm ctrnet1") < stopped {
		t.Errorf("the network locus-builds was not removed after the builds stopped:\n%s", strings.Join(log, "\n"))
	}
}

// A failure before the switch, after the stop, starts the old stack again
// as it ran: the head's services through the engine's start, then the
// builder and its guard under the builds' own profile.
func TestUpdateRecoveryStartsTheThreeContainerBuildsAgain(t *testing.T) {
	s := newThreeContainerScenario(t)
	s.withProfiles(buildsProfiles)
	s.answer("network-rm-net0.exit", "1")
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "could not remove the network locus-backends") || !strings.Contains(err.Error(), "The old stack was started again; docker-compose.yml is unchanged") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	s.composeUnchanged()
	want := append(started("update"), s.buildsSelection()+"up -d --no-deps locus-builds locus-builds-guard")
	if log := s.log(); len(log) < len(want) || !slices.Equal(log[len(log)-len(want):], want) {
		t.Errorf("the old stack was not started again as it ran:\n%s", strings.Join(log, "\n"))
	}
}

// buildsProfiles are the three-container stack's services under a profile,
// as its compose file declares them.
var buildsProfiles = map[string][]string{"caddy": {"public"}, "locus-builds": {"locus-builds"}, "locus-builds-guard": {"locus-builds"}}

// The recovery after a failure before the switch starts exactly the
// services that ran: with the builder running and its guard, a dependency
// of its under the same profile, stopped, the builder starts alone and
// nothing it depends on starts.
func TestUpdateRecoveryStartsNoServiceTheBuildsDependOn(t *testing.T) {
	s := newThreeContainerScenario(t)
	s.withProfiles(buildsProfiles)
	s.answer("ps.out", "locus-backends-guard\ncyfr\ncaddy\nlocus-runtime\nlocus-builds\nlocus-backends\n")
	s.answer("network-rm-net0.exit", "1")
	if out, err := s.run(context.Background()); err == nil || !strings.Contains(err.Error(), "The old stack was started again; docker-compose.yml is unchanged") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	want := append(started("update"), s.buildsSelection()+"up -d --no-deps locus-builds")
	if log := s.log(); len(log) < len(want) || !slices.Equal(log[len(log)-len(want):], want) {
		t.Errorf("the recovery did not start the builder alone:\n%s", strings.Join(log, "\n"))
	}
}

// A recovery whose head's services started and whose builder did not says
// so, naming the services and the command that starts them, never that
// 'cyfr up' starts the old stack.
func TestUpdateRecoveryWhoseBuildsDoNotStartSaysWhatStartsThem(t *testing.T) {
	s := newThreeContainerScenario(t)
	s.withProfiles(buildsProfiles)
	s.answer("network-rm-net0.exit", "1")
	s.answer("up-no-deps.exit", "1")
	out, err := s.run(context.Background())
	said := ".\nThe old stack was started again and docker-compose.yml is unchanged, but locus-builds, locus-builds-guard did not start ("
	starts := "); 'docker compose --profile locus-builds up -d locus-builds locus-builds-guard' starts them"
	if err == nil || strings.Count(err.Error(), said) != 1 || !strings.HasSuffix(err.Error(), starts) || strings.Contains(err.Error(), "'cyfr up'") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
}

// A recovery whose own start fails says 'cyfr up' starts the old stack and,
// since that starts none of the services that ran beside it, which they
// are and what starts them.
func TestUpdateRecoveryWhoseStartFailsSaysTheBuildsStayStopped(t *testing.T) {
	s := newThreeContainerScenario(t)
	s.withProfiles(buildsProfiles)
	s.answer("network-rm-net0.exit", "1")
	s.engine.startErr = errors.New("cyfr did not become healthy")
	out, err := s.run(context.Background())
	said := "; docker-compose.yml is unchanged, so 'cyfr up' starts it. These services are not started, since .env selects none of their profiles: locus-builds, locus-builds-guard; 'docker compose --profile locus-builds up -d locus-builds locus-builds-guard' starts them."
	if err == nil || !strings.HasSuffix(err.Error(), said) || strings.Count(err.Error(), said) != 1 {
		t.Fatalf("update answered %v\n%s", err, out)
	}
}

func TestUpdateFromThreeContainers(t *testing.T) {
	s := newThreeContainerScenario(t)
	const buildsKey = threeContainerBuildsKey
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	if got := read(t, filepath.Join(s.project, "docker-compose.yml")); got != string(switched(shippedCompose(t))) {
		t.Errorf("the switched docker-compose.yml is not the release's, pinned:\n%s", got)
	}
	// The first start after the update: the release's cyfr holds the
	// backends' URL beside the builds key it kept, so its boot never
	// refuses the key alone.
	if url := cyfrBackendsURL(t, filepath.Join(s.project, "docker-compose.yml"), filepath.Join(s.project, ".env")); url == "" {
		t.Error("the updated stack's cyfr would start with the builds key and no CYFR_LOCUS_BACKENDS_URL")
	}
	log := s.log()
	for _, call := range []string{profiles + "stop caddy", profiles + "stop cyfr", profiles + "stop"} {
		if !slices.Contains(log, call) {
			t.Errorf("the update did not run %q:\n%s", call, strings.Join(log, "\n"))
		}
	}
	project := access.ProjectName(s.project)
	want := []string{"rm c1 c2 c3 c4 c5", networkList(project)}
	for i := range retiredNetworks {
		id := fmt.Sprintf("net%d", i)
		want = append(want,
			"ps -a -q --no-trunc --filter network="+id+" --filter label=com.docker.compose.project="+project,
			"ps -a -q --no-trunc --filter network="+id,
			"rm ctr"+id,
			"network rm "+id)
	}
	var removal []string
	for _, line := range log {
		if strings.HasPrefix(line, "network ") || strings.HasPrefix(line, "rm ") || strings.Contains(line, "--filter network=") {
			removal = append(removal, line)
		}
	}
	if !slices.Equal(removal, want) {
		t.Errorf("the networks' removal ran\n%s\nwant\n%s", strings.Join(removal, "\n"), strings.Join(want, "\n"))
	}
	first, write := slices.Index(log, want[0]), slices.Index(log, "SCAFFOLD WRITE")
	if stopped := slices.Index(log, profiles+"stop"); first < stopped || write < first {
		t.Errorf("the networks were not removed between the stop and the switch:\n%s", strings.Join(log, "\n"))
	}
	got, err := access.ReadEnvValues(filepath.Join(s.project, ".env"))
	if err != nil {
		t.Fatal(err)
	}
	// The bound the person gave the old runtime container is a setting the
	// release no longer reads: it goes from .env, named.
	for _, retired := range []string{"CYFR_LOCUS_BUILDS_URL", "LOCUS_RUNTIME_MEMORY_LIMIT"} {
		if _, held := got[retired]; held {
			t.Errorf(".env still holds %s", retired)
		}
	}
	for name, want := range map[string]string{
		"CYFR_LOCUS_BUILDS_KEY":       buildsKey,
		"CYFR_PRIVATE_EGRESS_TARGETS": "locus",
		"CYFR_LOCUS_RUNTIME_WORKERS":  "wrk_locus=http://locus-runtime:4200",
	} {
		if got[name] != want {
			t.Errorf(".env's %s is %q, want %q", name, got[name], want)
		}
	}
	for _, said := range []string{
		"\nstopped locus-backends-guard, locus-runtime, locus-builds, locus-builds-guard, locus-backends in ",
		"Removed from .env the settings release 0.8.0 shipped and release 0.9.0 no longer reads: CYFR_LOCUS_BUILDS_URL, LOCUS_RUNTIME_MEMORY_LIMIT.\n",
		"Set in .env to release 0.9.0's shipped values the settings that held release 0.8.0's: CYFR_PRIVATE_EGRESS_TARGETS=locus.\n",
		"Removed this project's containers of services release 0.9.0 does not run: locus-backends, locus-backends-guard, locus-builds, locus-builds-guard, locus-runtime.\n",
		"Removed this project's networks release 0.9.0 does not use: locus-backends, locus-builds, locus-runtime.\n",
		"Its images change:\n  ghcr.io/cyfrworks/cyfr: 0.8.0@sha256:" + strings.Repeat("c", 12) + "… → 0.9.0@sha256:" + strings.Repeat("a", 12) + "…\n" +
			"  ghcr.io/cyfrworks/cyfr-locus: 0.8.0@sha256:" + strings.Repeat("c", 12) + "… → 0.9.0@sha256:" + strings.Repeat("b", 12) + "…\n  caddy: ",
		"These .env settings name a service release 0.9.0's docker-compose.yml no longer runs, and cyfr update left them as you set them:\n" +
			"  CYFR_LOCUS_RUNTIME_WORKERS, line 7, names locus-runtime: put locus in place of locus-runtime in its URL, keeping the rest of the line as it is\n" +
			"Until each of these lines is changed so and 'cyfr up' is run, CYFR cannot reach locus.\n",
		"docker-compose.yml is now release 0.9.0's own file; the one it replaced, with any edits you made to it, is " + filepath.Join(s.snapshotDir(), "compose") + ", to copy back from what you still need.\n",
	} {
		if n := strings.Count(out, said); n != 1 {
			t.Errorf("the update said %d times %q:\n%s", n, said, out)
		}
	}
	for _, unsaid := range []string{editedOffer, "http://locus-runtime:4200", "stopped locus-runtime in ", "  locus-runtime: "} {
		if strings.Contains(out, unsaid) {
			t.Errorf("the update said %q:\n%s", unsaid, out)
		}
	}
}

// A line the person set that names a retired service is reported with the
// exact edit, in its own terms: in a list, the service's name replaced by
// the one the release ships, the rest of the list kept; in a URL, its host
// so replaced. The report says CYFR cannot reach Locus until each line is
// changed and 'cyfr up' is run, and says none of the lines' values.
func TestUpdateSaysTheEditOfAListAndOfAURLLine(t *testing.T) {
	s := newThreeContainerScenario(t)
	env := read(t, filepath.Join(s.project, ".env"))
	s.edit(".env", strings.Replace(env, "CYFR_PRIVATE_EGRESS_TARGETS=locus-backends\n", "CYFR_PRIVATE_EGRESS_TARGETS=locus-backends,api.example.com\n", 1))
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	report := "These .env settings name a service release 0.9.0's docker-compose.yml no longer runs, and cyfr update left them as you set them:\n" +
		"  CYFR_LOCUS_RUNTIME_WORKERS, line 7, names locus-runtime: put locus in place of locus-runtime in its URL, keeping the rest of the line as it is\n" +
		"  CYFR_PRIVATE_EGRESS_TARGETS, line 6, names locus-backends: put locus in place of locus-backends in that line, keeping the rest of it as it is\n" +
		"Until each of these lines is changed so and 'cyfr up' is run, CYFR cannot reach locus.\n"
	if n := strings.Count(out, report); n != 1 {
		t.Errorf("the update reported %d times %q:\n%s", n, report, out)
	}
	got, err := access.ReadEnvValues(filepath.Join(s.project, ".env"))
	if err != nil {
		t.Fatal(err)
	}
	if got["CYFR_PRIVATE_EGRESS_TARGETS"] != "locus-backends,api.example.com" {
		t.Errorf(".env's egress line is %q", got["CYFR_PRIVATE_EGRESS_TARGETS"])
	}
	for _, shown := range []string{"api.example.com", "http://locus-runtime:4200", "wrk_locus="} {
		if strings.Contains(out, shown) {
			t.Errorf("the update said %q:\n%s", shown, out)
		}
	}
}

// A retired network another Compose project's container is attached to
// is not removed: the update fails before the switch, naming the network
// and the container, and the old stack starts again under its own file.
func TestUpdateRefusesARetiredNetworkAnotherProjectUses(t *testing.T) {
	old := lastReleaseCompose(t)
	s := newUpdateScenario(t, []byte(old), nil)
	s.composes = map[string]string{"0.8.0": old}
	s.answerNetworks("net0 locus-backends")
	s.answer("network-ours-net0.out", "ctrours\n")
	s.answer("network-all-net0.out", "ctrours\n0123456789abcdef0123\n")
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "cyfr update could not remove the network locus-backends, which release 0.9.0 does not use (container 0123456789ab of another Compose project is attached to it)") || !strings.Contains(err.Error(), "The old stack was started again; docker-compose.yml is unchanged") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	s.composeUnchanged()
	for _, line := range s.log() {
		if strings.HasPrefix(line, "network rm") || strings.HasPrefix(line, "rm ") || line == "SCAFFOLD WRITE" {
			t.Errorf("the refused update ran %q", line)
		}
	}
	if log := s.log(); !slices.Equal(log[len(log)-2:], started("update")) {
		t.Errorf("the old stack was not started again:\n%s", strings.Join(log, "\n"))
	}
}

// The bundled stack is a service named cyfr and a service running the
// Locus image, under any name: a compose file without either is refused
// before any docker call, naming `cyfr init --force`, and one with both
// and no other of the stack's names is updated to the release's file.
func TestUpdateRefusesAComposeWithoutTheStack(t *testing.T) {
	shipped := string(shippedCompose(t))
	for name, c := range map[string]struct{ from, to, lacks string }{
		"no cyfr":        {"\n  cyfr:\n", "\n  app:\n", "a service named cyfr"},
		"no locus image": {"ghcr.io/cyfrworks/cyfr-locus:latest", "registry.example/locus:1", "a service running ghcr.io/cyfrworks/cyfr-locus"},
	} {
		t.Run(name, func(t *testing.T) {
			s := newUpdateScenario(t, []byte(strings.ReplaceAll(shipped, c.from, c.to)), nil)
			out, err := s.run(context.Background())
			if err == nil || !strings.Contains(err.Error(), c.lacks) || !strings.Contains(err.Error(), "Run 'cyfr init --force' to regenerate docker-compose.yml (.env is kept), then 'cyfr update' again.") {
				t.Fatalf("update answered %v\n%s", err, out)
			}
			if log := s.dockerLog(); log != nil {
				t.Errorf("docker ran before the refusal:\n%s", strings.Join(log, "\n"))
			}
			s.composeUnchanged()
			s.noBackups()
		})
	}

	minimal := "services:\n  cyfr:\n    image: ghcr.io/cyfrworks/cyfr:0.8.0@" + digestOld + "\n  workers:\n    image: ghcr.io/cyfrworks/cyfr-locus:0.8.0@" + digestOld + "\n"
	s := newUpdateScenario(t, []byte(minimal), nil)
	s.composes = map[string]string{"0.8.0": minimal}
	if out, err := s.run(context.Background()); err != nil {
		t.Fatalf("an update of cyfr and one Locus service answered %v\n%s", err, out)
	}
	if got := read(t, filepath.Join(s.project, "docker-compose.yml")); got != string(switched(shippedCompose(t))) {
		t.Errorf("the switched docker-compose.yml is not the release's, pinned:\n%s", got)
	}
}

// The update is done when the stack it started is: a service that is not
// healthy (one with a health check) or running (one without) within the
// bound fails the update with its name and the command that shows why,
// the stack stopped, the snapshot and the restore command said, and never
// the update's done.
func TestUpdateFailsWhenAServiceDoesNotComeUp(t *testing.T) {
	for name, c := range map[string]struct {
		states map[string]string
		want   string
	}{
		"restart loop": {map[string]string{"locus": "restarting/starting"}, "locus (restarting)"},
		"unhealthy":    {map[string]string{"locus-guard": "running/unhealthy"}, "locus-guard (unhealthy)"},
		"no health":    {map[string]string{"locus": "exited/"}, "locus (exited)"},
		"two":          {map[string]string{"locus": "running/starting", "locus-guard": "restarting/"}, "locus (starting), locus-guard (restarting)"},
	} {
		t.Run(name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			saved, savedPoll := stackHealthWindow, stackHealthPoll
			t.Cleanup(func() { stackHealthWindow, stackHealthPoll = saved, savedPoll })
			stackHealthWindow, stackHealthPoll = 300*time.Millisecond, 20*time.Millisecond
			s.stackAnswer(c.states)
			out, err := s.run(context.Background())
			if err == nil {
				t.Fatalf("update succeeded\n%s", out)
			}
			var services []string
			for svc := range c.states {
				services = append(services, svc)
			}
			slices.Sort(services)
			for _, want := range []string{
				"Release 0.9.0 did not start",
				c.want,
				"see why with 'docker compose logs " + strings.Join(services, " ") + "'",
				"the stack is left stopped",
				"The snapshot of release 0.8.0 is " + s.snapshotDir() + "; restore it with:\n  cyfr restore " + s.snapshotDir(),
			} {
				if !strings.Contains(err.Error(), want) {
					t.Errorf("the refusal lacks %q:\n%v", want, err)
				}
			}
			if strings.Contains(out, "Updated to release") {
				t.Errorf("the update said it was done:\n%s", out)
			}
			log := s.log()
			if at := slices.Index(log, profiles+"up -d"); at < 0 || !slices.Contains(log[at:], "ENGINE close-serve") || !slices.Contains(log[at:], profiles+"stop") {
				t.Errorf("the update did not stop the stack after the start:\n%s", strings.Join(log, "\n"))
			}
		})
	}
}

// The wait for the started stack outlasts every shipped health check's
// time to call its service unhealthy: start_period and retries × (interval
// + timeout), with Docker's defaults where a check leaves one out.
func TestStackHealthWindowCoversTheShippedHealthChecks(t *testing.T) {
	var compose struct {
		Services map[string]struct {
			Healthcheck *struct {
				Interval    string `yaml:"interval"`
				Timeout     string `yaml:"timeout"`
				StartPeriod string `yaml:"start_period"`
				Retries     int    `yaml:"retries"`
			} `yaml:"healthcheck"`
		} `yaml:"services"`
	}
	if err := yaml.Unmarshal(shippedCompose(t), &compose); err != nil {
		t.Fatal(err)
	}
	duration := func(s string, fallback time.Duration) time.Duration {
		if s == "" {
			return fallback
		}
		d, err := time.ParseDuration(s)
		if err != nil {
			t.Fatalf("a health check's duration %q does not read: %v", s, err)
		}
		return d
	}
	checks := 0
	for name, svc := range compose.Services {
		check := svc.Healthcheck
		if check == nil {
			continue
		}
		checks++
		retries := check.Retries
		if retries == 0 {
			retries = 3
		}
		worst := duration(check.StartPeriod, 0) + time.Duration(retries)*(duration(check.Interval, 30*time.Second)+duration(check.Timeout, 30*time.Second))
		if worst >= stackHealthWindow {
			t.Errorf("%s's health check takes up to %v to call it unhealthy, not within the wait's %v", name, worst, stackHealthWindow)
		}
	}
	if checks == 0 {
		t.Fatal("the shipped docker-compose.yml has no health check")
	}
}

// A .env line holding the value the release being left shipped in its
// .env.example, where the new release's ships another, takes the new
// value, said once; a line the person changed that names a service the
// release no longer runs, in any form the setting takes (a URL, a host
// and port, an id=URL list), is reported by its key, its line and the
// host it names, never its value, with what to write there, and left; a
// key assigned more than once is the person's, none of its lines changed,
// and reported; every other line the person set, a commented example's
// included, stays as it is and is not named.
func TestUpdateRewritesTheReleasesDefaultsInEnv(t *testing.T) {
	legacy := strings.Replace(string(shippedCompose(t)), "\n  caddy:\n", "\n  locus-legacy:\n    image: ghcr.io/cyfrworks/cyfr-locus:0.8.0\n  caddy:\n", 1)
	s := newUpdateScenario(t, []byte(legacy), nil)
	s.composes = map[string]string{"0.8.0": legacy}
	s.examples = map[string]string{
		"0.8.0": "CYFR_DEFAULTED=old\nCYFR_CHANGED=old\nCYFR_SAME=same\nCYFR_LEGACY_URL=http://locus-legacy:4100\n# CYFR_COMMENTED=old\nCYFR_TWICE=old\n",
		"0.9.0": "CYFR_DEFAULTED=new\nCYFR_CHANGED=new\nCYFR_SAME=same\nCYFR_LEGACY_URL=http://locus:4100\nCYFR_COMMENTED=new\nCYFR_TWICE=new\n",
	}
	lines := "CYFR_DEFAULTED=old\nCYFR_CHANGED=mine\nCYFR_SAME=same\nCYFR_LEGACY_URL=http://locus-legacy:4200/?token=tok-secret-123\nCYFR_COMMENTED=old\nCYFR_PEER=locus-legacy:7\nCYFR_OTHER=http://locus:1\nCYFR_NAMED_URLS=wrk_one=http://locus:4201,wrk_locus=http://locus-legacy:4201\nCYFR_TWICE=mine\nCYFR_TWICE=old\n"
	env := scenarioEnv + lines
	s.edit(".env", env)
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	got, err := access.ReadEnvValues(filepath.Join(s.project, ".env"))
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{
		"CYFR_DEFAULTED":  "new",
		"CYFR_CHANGED":    "mine",
		"CYFR_SAME":       "same",
		"CYFR_LEGACY_URL": "http://locus-legacy:4200/?token=tok-secret-123",
		"CYFR_COMMENTED":  "old",
		"CYFR_PEER":       "locus-legacy:7",
		"CYFR_OTHER":      "http://locus:1",
	} {
		if got[name] != want {
			t.Errorf(".env's %s is %q, want %q", name, got[name], want)
		}
	}
	if held := read(t, filepath.Join(s.project, ".env")); !strings.Contains(held, "\nCYFR_TWICE=mine\nCYFR_TWICE=old\n") {
		t.Errorf("the update changed a line of a key assigned twice:\n%s", held)
	}
	said := "Set in .env to release 0.9.0's shipped values the settings that held release 0.8.0's: CYFR_DEFAULTED=new.\n"
	if n := strings.Count(out, said); n != 1 {
		t.Errorf("the update said %d times %q:\n%s", n, said, out)
	}
	report := "These .env settings name a service release 0.9.0's docker-compose.yml no longer runs, and cyfr update left them as you set them:\n" +
		"  CYFR_LEGACY_URL, line 8, names locus-legacy: put locus in place of locus-legacy in its URL, keeping the rest of the line as it is\n" +
		"  CYFR_NAMED_URLS, line 12, names locus-legacy: name a service release 0.9.0's docker-compose.yml runs there\n" +
		"  CYFR_PEER, line 10, names locus-legacy: name a service release 0.9.0's docker-compose.yml runs there\n" +
		"Until each of these lines is changed so and 'cyfr up' is run, CYFR cannot reach locus.\n"
	if n := strings.Count(out, report); n != 1 {
		t.Errorf("the update reported %d times %q:\n%s", n, report, out)
	}
	twice := "These .env settings are assigned more than once, so they are yours and cyfr update changed none of their lines:\n" +
		"  CYFR_TWICE, lines 13 and 14: release 0.9.0 ships CYFR_TWICE=new\n"
	if n := strings.Count(out, twice); n != 1 {
		t.Errorf("the update reported %d times %q:\n%s", n, twice, out)
	}
	for _, shown := range []string{"CYFR_CHANGED", "CYFR_SAME", "CYFR_COMMENTED", "CYFR_OTHER", "tok-secret-123", "4200", "locus-legacy:7", "wrk_"} {
		if strings.Contains(out, shown) {
			t.Errorf("the update said %q:\n%s", shown, out)
		}
	}
	if kept := read(t, filepath.Join(s.snapshotDir(), ".env")); kept != env {
		t.Errorf("the snapshot's .env is %q, not .env as it stood", kept)
	}
}

// editedOffer is what the update says of a docker-compose.yml other than
// the one release 0.8.0 shipped, before it asks anything.
const editedOffer = "docker-compose.yml is not the file release 0.8.0 shipped: these lines differ, image lines aside (- the release's, + yours):\n"

// editedRefusal is the update's refusal of an edited docker-compose.yml
// with no terminal to ask on, --yes or not.
const editedRefusal = "Nothing changed: docker-compose.yml is not the file release 0.8.0 shipped, and there is no terminal to ask on whether to replace it; --yes does not answer this question. Run 'cyfr update' at a terminal"

// A docker-compose.yml that is not the file the release being left
// shipped, its image lines aside, is said before anything stops: the lines
// that differ, no environment value among them, that going on writes the
// release's file and the snapshot keeps the person's, and a sentence of
// its own when a difference is a managed service's volumes. Then the
// update asks, --yes or not, the answer defaulting to no; declined, or
// with no terminal to ask on, nothing changes and the stack runs on; yes
// replaces the file, the person's kept in the snapshot.
func TestUpdateAsksBeforeReplacingAnEditedComposeFile(t *testing.T) {
	shipped := string(shippedCompose(t))
	edit := func(from, to string) string {
		t.Helper()
		if !strings.Contains(shipped, from) {
			t.Fatalf("the shipped docker-compose.yml holds no %q", from)
		}
		return strings.Replace(shipped, from, to, 1)
	}
	edited := edit("    environment:\n", "    environment:\n      - CYFR_MINE=secret-in-compose\n")
	question := "Replace docker-compose.yml with release 0.9.0's and update this CYFR? (yes/no) [no]: "
	going := "Going on writes release 0.9.0's docker-compose.yml in its place; the snapshot keeps yours, with your changes, for you to carry over by hand.\n"
	volumes := "The differences change the volumes of cyfr: release 0.9.0's file mounts only its own, so the stack would start without the data the folders you mount there hold.\n"
	for name, c := range map[string]struct {
		compose  string
		terminal bool
		answer   string
		volumes  bool
	}{
		"declined":    {edited, true, "no\n", false},
		"no terminal": {edited, false, "", false},
		"data bind":   {edit("      - ./data:/app/data\n", "      - /srv/cyfr-data:/app/data\n"), false, "", true},
		"nested bind": {edit("      - ./data:/app/data\n", "      - ./data:/app/data\n      - /srv/components:/app/data/components\n"), false, "", true},
	} {
		t.Run(name, func(t *testing.T) {
			s := newUpdateScenario(t, []byte(c.compose), nil)
			askWith(t, c.terminal, strings.NewReader(c.answer))
			out, err := s.run(context.Background())
			switch {
			case c.terminal && (err != nil || !strings.HasSuffix(out, question+"Nothing changed. Run cyfr update again when you want this release.\n")):
				t.Fatalf("a declined update answered %v:\n%s", err, out)
			case !c.terminal && (err == nil || err.Error() != editedRefusal):
				t.Fatalf("the update answered %v, want %q:\n%s", err, editedRefusal, out)
			}
			for _, line := range []string{editedOffer, going} {
				if !strings.Contains(out, line) {
					t.Errorf("the update did not say %q:\n%s", line, out)
				}
			}
			if strings.Contains(out, volumes) != c.volumes {
				t.Errorf("the update said the volumes sentence %v, want %v:\n%s", !c.volumes, c.volumes, out)
			}
			if strings.Contains(out, "secret-in-compose") {
				t.Errorf("the update printed an environment value:\n%s", out)
			}
			s.nothingStopped()
			s.composeUnchanged()
			s.noBackups()
		})
	}
	if !strings.Contains(edited, "CYFR_MINE") {
		t.Fatal("no edit")
	}

	s := newUpdateScenario(t, []byte(edited), nil)
	askWith(t, true, strings.NewReader("yes\n"))
	out, err := s.run(context.Background())
	if err != nil || !strings.Contains(out, editedOffer+"  +       - CYFR_MINE=…\n") || !strings.Contains(out, question) {
		t.Fatalf("an accepted update answered %v:\n%s", err, out)
	}
	if got := read(t, filepath.Join(s.project, "docker-compose.yml")); got != string(switched(shippedCompose(t))) {
		t.Errorf("the accepted update did not write the release's file:\n%s", got)
	}
	if held := read(t, filepath.Join(s.snapshotDir(), "compose")); held != edited {
		t.Errorf("the snapshot does not hold the edited file")
	}
}

// The wait and the cleanup after it run under the head the start started:
// a .env change of the switch that moves cyfr's port changes the head, and
// the wait and the stop run under the new one.
func TestUpdateWaitsUnderTheHeadItStarted(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.examples = map[string]string{
		"0.8.0": "CYFR_PORT=4000\n",
		"0.9.0": "CYFR_PORT=4100\n",
	}
	saved, savedPoll := stackHealthWindow, stackHealthPoll
	t.Cleanup(func() { stackHealthWindow, stackHealthPoll = saved, savedPoll })
	stackHealthWindow, stackHealthPoll = 300*time.Millisecond, 20*time.Millisecond
	s.stackAnswer(map[string]string{"locus": "restarting/"})
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "locus (restarting)") {
		t.Fatalf("update answered %v\n%s", err, out)
	}
	env := envAssignments(filepath.Join(s.project, ".env"))
	b, err := access.ResolveBoot(access.BootInput{File: env, Process: env, Release: true})
	if err != nil || b.Head.Port != 4100 {
		t.Fatalf("the switched .env's head is %+v (error %v), want one on port 4100", b.Head, err)
	}
	started := strings.Join(composePrefixArgs(access.ProjectName(s.project), b.Head), " ") + " "
	log := s.log()
	for _, call := range []string{started + "up -d", started + "config --services", started + "ps --format json", started + "stop"} {
		if !slices.Contains(log, call) {
			t.Errorf("the update did not run %q:\n%s", call, strings.Join(log, "\n"))
		}
	}
}

// The wait has one deadline: a docker call that does not answer ends it
// there, with the services not seen up named, never a fresh allowance per
// read.
func TestUpdateBoundsItsWaitByOneDeadline(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	saved, savedPoll := stackHealthWindow, stackHealthPoll
	t.Cleanup(func() { stackHealthWindow, stackHealthPoll = saved, savedPoll })
	stackHealthWindow, stackHealthPoll = 300*time.Millisecond, 20*time.Millisecond
	s.answer("stack.block", "")
	t.Cleanup(func() { s.answer("stack.release", "") })
	done := make(chan error, 1)
	go func() {
		_, err := s.run(context.Background())
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "did not come up within 300ms") || !strings.Contains(err.Error(), "docker compose logs caddy cyfr") {
			t.Fatalf("update answered %v", err)
		}
	case <-time.After(20 * time.Second):
		s.answer("stack.release", "")
		<-done
		t.Fatal("the wait outlived its deadline")
	}
}

// An update of a CYFR on its release already starts it and waits for every
// service of the stack: an update run again after one whose services did
// not come up waits again, its matching pins no reason to skip the wait.
func TestUpdateWaitsAgainOnItsRelease(t *testing.T) {
	s := newUpdateScenario(t, switched(shippedCompose(t)), nil)
	saved, savedPoll := stackHealthWindow, stackHealthPoll
	t.Cleanup(func() { stackHealthWindow, stackHealthPoll = saved, savedPoll })
	stackHealthWindow, stackHealthPoll = 300*time.Millisecond, 20*time.Millisecond
	s.stackAnswer(map[string]string{"locus": "restarting/"})
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "locus (restarting)") || !strings.Contains(err.Error(), "docker compose logs locus") {
		t.Fatalf("an update on its release answered %v\n%s", err, out)
	}
	if !slices.Contains(s.log(), profiles+"ps --format json") {
		t.Errorf("the update did not wait for the stack:\n%s", strings.Join(s.log(), "\n"))
	}
	s.noBackups()
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
		err := homeStep(context.Background(), io.Discard, io.Discard)
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
	err := homeStep(context.Background(), &out, &out)
	if err == nil || !strings.Contains(err.Error(), "Another cyfr command holds CYFR's lock (`update`)") || !strings.Contains(err.Error(), "Nothing was changed") {
		t.Errorf("the second update answered %v", err)
	}
	// The refused update ran the offer's reads alone, which write nothing.
	if got := s.log()[calls:]; !slices.Equal(got, s.offerReads()) {
		t.Errorf("the refused update ran %s", strings.Join(got, "\n"))
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

	// The home is on the release now: its compose file goes back to the
	// one before, so the next update has a change to make.
	s.edit("docker-compose.yml", string(s.compose))
	s.engine.holder = "access tailnet"
	calls = len(s.log())
	err = homeStep(context.Background(), io.Discard, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "(`access tailnet`)") {
		t.Errorf("an update beside a held lock answered %v", err)
	}
	// The refused update ran the offer's reads alone, which write nothing.
	if got := s.log()[calls:]; !slices.Equal(got, s.offerReads()) {
		t.Errorf("the refused update ran %s", strings.Join(got, "\n"))
	}
	s.engine.holder = ""
}

// A signal before the stop ends the update with nothing changed; from the
// stop on, the running step finishes and the old stack starts again, a
// snapshot the signal landed in kept complete and nothing switched. The
// snapshot's one docker call is a PostgreSQL home's dump, so that row is
// the one place the check after the snapshot is held (the Compose proof's
// update cases run on SQLite and reach no further than the offline read).
func TestUpdateOnASignal(t *testing.T) {
	pg := map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL}
	cases := []struct {
		at, want string
		restart  bool
		env      map[string]string
		snapshot bool
	}{
		{"pull", "interrupted before anything stopped", false, nil, false},
		{"rpc", "interrupted before anything stopped", false, nil, false},
		{"stop-cyfr", "interrupted during the stop", true, nil, false},
		{"eval", "interrupted during the offline roster read", true, nil, false},
		{"dump", "interrupted during the snapshot (complete at", true, pg, true},
	}
	for _, c := range cases {
		t.Run(c.at, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), c.env)
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
				for _, svc := range []string{"caddy", "cyfr", "locus", "locus-guard"} {
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
			if c.snapshot {
				if _, err := os.Stat(filepath.Join(s.snapshotDir(), "snapshot.json")); err != nil {
					t.Errorf("the snapshot the signal landed in is not complete (%v)", err)
				}
			} else {
				s.noBackups()
			}
		})
	}
}

// Once the switch begins it is never cut short: a signal during the start
// lets the start finish, so the stack is not left half-switched, and the
// update reports the interrupt beside its outcome.
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
	if !slices.Equal(log[len(log)-4:], startedAndUp()) {
		t.Errorf("the start was not the last step:\n%s", strings.Join(log, "\n"))
	}
	if !strings.Contains(out, "An interrupt arrived during the switch") {
		t.Errorf("the update did not report the interrupt:\n%s", out)
	}
	if got, err := os.ReadFile(filepath.Join(s.project, "docker-compose.yml")); err != nil || !bytes.Equal(got, switched(s.compose)) {
		t.Errorf("docker-compose.yml is not the switched file (error %v)", err)
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
	// Both releases ship the nested bind, so the updated stack reads the
	// components where the snapshot found them; a bind the person added is
	// asked about first (TestUpdateAsksBeforeReplacingAnEditedComposeFile).
	s.composes = map[string]string{"0.8.0": compose, testVersion: compose}
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
	if got := read(t, filepath.Join(s.project, "docker-compose.yml")); !strings.Contains(got, "      - "+nested+":/app/data/components\n") {
		t.Errorf("the updated stack no longer binds the components the snapshot holds:\n%s", got)
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

// A snapshot holds neither the tailnet's state volume nor the access
// engine's .cyfr/, so a node's keys and the machine's lock, journal and
// receipts never enter a backup: snapshotParts names neither; .cyfr/ beside
// the storage root, or bound under it, is copied nowhere; and the state
// volume mounted under the storage root is refused as every non-bind mount
// there is, before anything stops.
func TestSnapshotsHoldNeitherTheTailnetStateNorTheAccessState(t *testing.T) {
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
			if err := os.WriteFile(filepath.Join(root, name), []byte(content+"access-state-marker"), 0600); err != nil {
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
			if entry.Type().IsRegular() && strings.Contains(read(t, p), "access-state-marker") {
				t.Errorf("the snapshot holds the access state's %s", p)
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
	// Its mount point in data/, as the stack's start made it.
	if err := os.Mkdir(filepath.Join(s.project, "data", "reach"), 0o755); err != nil {
		t.Fatal(err)
	}
	if out, err := s.run(context.Background()); err != nil {
		t.Fatalf("update with .cyfr/ bound under the storage root: %v\n%s", err, out)
	}
	noState(s)

	s = newUpdateScenario(t, shippedCompose(t), nil)
	s.addVolume(map[string]any{"type": "volume", "source": access.ProjectName(s.project) + "_tailscale_state", "target": "/app/data/tailscale"})
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
// does not place; each refuses before anything stops.
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
	s.composes = map[string]string{"0.8.0": compose, testVersion: compose}
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

// The settings the release this CYFR runs shipped in its .env.example, set
// or commented, that the new release's .env.example no longer declares
// leave .env at the switch, named and never shown with their values: the
// new server refuses to boot on a name it does not read. A setting both
// releases declare stays, a commented one too, and so does every name the
// old .env.example never shipped, the person's own. The snapshot keeps .env
// as it stood, and a switch that fails puts it back.
func TestUpdateRemovesTheSettingsTheReleaseRetired(t *testing.T) {
	examples := map[string]string{
		"0.8.0": "# Shipped.\nCYFR_KEPT=\nCYFR_RETIRED=\n# CYFR_RETIRED_COMMENTED=postgres\nCYFR_NOW_COMMENTED=\n",
		"0.9.0": "CYFR_KEPT=\n# CYFR_NOW_COMMENTED=\nCYFR_ADDED=\n",
	}
	env := scenarioEnv + "CYFR_KEPT=1\nCYFR_RETIRED=secret-value\nCYFR_RETIRED_COMMENTED=2\nCYFR_NOW_COMMENTED=3\nCYFR_MINE=4\n"
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.examples = examples
	s.edit(".env", env)
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	got, err := access.ReadEnvValues(filepath.Join(s.project, ".env"))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"CYFR_RETIRED", "CYFR_RETIRED_COMMENTED"} {
		if _, held := got[name]; held {
			t.Errorf("%s, retired by 0.9.0, is still in .env", name)
		}
	}
	for name, value := range map[string]string{"CYFR_KEPT": "1", "CYFR_NOW_COMMENTED": "3", "CYFR_MINE": "4", "CYFR_ACCESS": "public"} {
		if got[name] != value {
			t.Errorf("%s is %q, want %q kept", name, got[name], value)
		}
	}
	if !strings.Contains(out, "Removed from .env the settings release 0.8.0 shipped and release 0.9.0 no longer reads: CYFR_RETIRED, CYFR_RETIRED_COMMENTED.") ||
		strings.Contains(out, "secret-value") {
		t.Errorf("the update did not say what it removed, or showed a value:\n%s", out)
	}
	if kept := read(t, filepath.Join(s.snapshotDir(), ".env")); kept != env {
		t.Errorf("the snapshot's .env is %q, not .env as it stood", kept)
	}

	failed := newUpdateScenario(t, shippedCompose(t), nil)
	failed.examples = examples
	failed.edit(".env", env)
	failed.answer("stop-cyfr.edit", "# edited while the update ran\n")
	if _, err := failed.run(context.Background()); err == nil {
		t.Fatal("a switch over an edited compose file did not fail")
	}
	if back := read(t, filepath.Join(failed.project, ".env")); back != env {
		t.Errorf("a failed switch left .env as %q, not put back", back)
	}

	same := newUpdateScenario(t, shippedCompose(t), nil)
	same.examples = map[string]string{"0.8.0": examples["0.9.0"], "0.9.0": examples["0.9.0"]}
	same.edit(".env", env)
	if out, err := same.run(context.Background()); err != nil || strings.Contains(out, "Removed from .env") {
		t.Fatalf("releases that ship the same names removed something: %v\n%s", err, out)
	}
}

// CYFR_HEADLESS, the switch that turned a CYFR's pages off, is retired:
// an update from a release whose .env.example offered it to this tree's,
// both on one schema, takes it out of a .env that set it and says so,
// since every CYFR serves its pages and the new server refuses the name.
func TestUpdateRetiresTheHeadlessSwitch(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(packageDir, "..", "..", "..", ".env.example"))
	if err != nil {
		t.Fatal(err)
	}
	now := string(data)
	older := now + "\n# A headless node: the API, /mcp and public tinctures, and no browser\n# page.\n# CYFR_HEADLESS=on\n"
	env := scenarioEnv + "CYFR_HEADLESS=on\n"
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.examples = map[string]string{"0.8.0": older, "0.9.0": now}
	s.edit(".env", env)
	out, err := s.run(context.Background())
	if err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	if got, want := read(t, filepath.Join(s.project, ".env")), scenarioEnv+appArmorEnv+"="+apparmor.ProfileName+"\n"; got != want {
		t.Errorf(".env after the update is %q, want %q", got, want)
	}
	if !strings.Contains(out, "Removed from .env the settings release 0.8.0 shipped and release 0.9.0 no longer reads: CYFR_HEADLESS.\n") {
		t.Errorf("the update did not say it removed CYFR_HEADLESS:\n%s", out)
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
	if s.hasCall("pull ") || s.hasCall("SCAFFOLD FETCH "+testVersion) {
		t.Errorf("the update pulled or fetched the scaffold before refusing:\n%s", strings.Join(s.log(), "\n"))
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

// 'cyfr up' refuses while an update holds the lock, in the window where the
// update has stopped the stack and copies its data, and runs no docker.
func TestUpRefusesWhileAnUpdateHoldsTheLock(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("eval.block", "")
	done := make(chan error, 1)
	go func() { done <- homeStep(context.Background(), io.Discard, io.Discard) }()
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
	if err == nil || !strings.Contains(err.Error(), "Another cyfr command holds CYFR's lock (`update`)") || !strings.Contains(err.Error(), "Nothing was changed") {
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

// askWith answers the home step's question from answer on a terminal, or
// with no terminal when terminal is false, for the test.
func askWith(t *testing.T, terminal bool, answer io.Reader) {
	t.Helper()
	savedTerminal, savedInput := askTerminal, askInput
	t.Cleanup(func() { askTerminal, askInput = savedTerminal, savedInput })
	askTerminal = func() bool { return terminal }
	askInput = answer
}

// offerReads are what the offer reads before the lock: the schema read
// through the running cyfr, then the scaffold of the release it answers,
// whose compose file tells a person's changes apart.
func (s *updateScenario) offerReads() []string {
	return append(s.schemaRead(true), "SCAFFOLD FETCH 0.8.0")
}

// onlyReadTheSchema fails unless the update ran only the offer's reads
// (offerReads), with no engine call, the lock among them, and changed no
// file.
func (s *updateScenario) onlyReadTheSchema() {
	s.t.Helper()
	if log := s.log(); !slices.Equal(log, s.offerReads()) {
		s.t.Errorf("the update ran:\n%s", strings.Join(log, "\n"))
	}
	s.composeUnchanged()
	s.noBackups()
}

// nothingRan fails unless the update made no docker call and no engine
// call, the lock among them, and changed no file.
func (s *updateScenario) nothingRan() {
	s.t.Helper()
	if log := s.log(); len(log) != 0 {
		s.t.Errorf("the update ran:\n%s", strings.Join(log, "\n"))
	}
	s.composeUnchanged()
	s.noBackups()
}

// The home step shows what the update changes before it takes the lock:
// the release the home is on, that the release's compose file replaces
// its own, each managed image line that changes and where the release
// notes are; then it asks.
// No, or no answer, changes nothing and says so, as no failure; with no
// terminal and no --yes the change is shown and not made; yes makes it.
func TestUpdateShowsTheChangeAndAsks(t *testing.T) {
	compose := strings.Replace(string(shippedCompose(t)), "image: ghcr.io/cyfrworks/cyfr:latest", "image: ghcr.io/cyfrworks/cyfr:0.8.0@"+digestOld, 1)
	for name, c := range map[string]struct {
		terminal bool
		answer   string
		says     string
	}{
		"no":          {true, "no\n", ""},
		"no answer":   {true, "", ""},
		"no terminal": {false, "yes\n", "Nothing changed: there is no terminal to confirm the update on. Run it again with --yes to make it, or at a terminal"},
	} {
		t.Run(name, func(t *testing.T) {
			s := newUpdateScenario(t, []byte(compose), nil)
			askWith(t, c.terminal, strings.NewReader(c.answer))
			var out bytes.Buffer
			err := runHomeUpdate(context.Background(), &out, &out, updateOptions{})
			switch {
			case c.says == "" && (err != nil || !strings.HasSuffix(out.String(), "Update this CYFR? (yes/no) [no]: Nothing changed. Run cyfr update again when you want this release.\n")):
				t.Fatalf("a declined update answered %v:\n%s", err, out.String())
			case c.says != "" && (err == nil || err.Error() != c.says):
				t.Fatalf("the update answered %v, want %q:\n%s", err, c.says, out.String())
			}
			for _, line := range []string{
				"This CYFR is on release 0.8.0; this cyfr is release 0.9.0.\n",
				"Updating it stops the stack, snapshots it into backups/, replaces docker-compose.yml with release 0.9.0's own, the snapshot keeping this one with any edits you made to it, and starts it. Its images change:\n",
				"  ghcr.io/cyfrworks/cyfr: 0.8.0@sha256:" + strings.Repeat("c", 12) + "… → 0.9.0@sha256:" + strings.Repeat("a", 12) + "…\n",
				"  ghcr.io/cyfrworks/cyfr-locus: latest → 0.9.0@sha256:" + strings.Repeat("b", 12) + "…\n",
				"Read the release notes first: https://github.com/cyfrworks/cyfr/releases/tag/0.9.0\n",
			} {
				if !strings.Contains(out.String(), line) {
					t.Errorf("the offer lacks %q:\n%s", line, out.String())
				}
			}
			if asked := strings.Contains(out.String(), "Update this CYFR? (yes/no) [no]: "); asked != c.terminal {
				t.Errorf("asked = %v on a terminal = %v:\n%s", asked, c.terminal, out.String())
			}
			s.onlyReadTheSchema()
		})
	}

	s := newUpdateScenario(t, []byte(compose), nil)
	askWith(t, true, strings.NewReader("yes\n"))
	var out bytes.Buffer
	if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{}); err != nil || !strings.Contains(out.String(), "Updated to release 0.9.0.") {
		t.Fatalf("a confirmed update answered %v:\n%s", err, out.String())
	}
	if got := read(t, filepath.Join(s.project, "docker-compose.yml")); got != string(switched([]byte(compose))) {
		t.Errorf("the confirmed update left docker-compose.yml as:\n%s", got)
	}
}

// The CYFR app's Update CYFR page shows the change --offer answers, which
// makes none, with its confirmation: the folder, the exact release and
// the compose file's bytes as the offer read them. A run confirmed with
// it makes the change with no terminal and no --yes where it reads the
// same three itself; a compose file rewritten since, even where the change
// it words is the same, and the same file in another folder are refused
// before anything stops. A home on its release already is answered as
// current.
func TestTheAppsConfirmedChangeIsMadeOnlyAsItWasRead(t *testing.T) {
	compose := strings.Replace(string(shippedCompose(t)), "image: ghcr.io/cyfrworks/cyfr:latest", "image: ghcr.io/cyfrworks/cyfr:0.8.0@"+digestOld, 1)
	askWith(t, false, strings.NewReader(""))
	var out bytes.Buffer
	lastLine := func() []byte {
		return []byte(out.String()[strings.LastIndex(strings.TrimSuffix(out.String(), "\n"), "\n")+1:])
	}
	offer := func() shownChange {
		t.Helper()
		out.Reset()
		if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{offer: true}); err != nil {
			t.Fatalf("the offer answered %v:\n%s", err, out.String())
		}
		var shown shownChange
		if err := json.Unmarshal(lastLine(), &shown); err != nil || shown.Current != "" || shown.Confirmation == "" ||
			!strings.Contains(shown.Change, "This CYFR is on release 0.8.0; this cyfr is release 0.9.0.\n") {
			t.Fatalf("the offer is %q (%v)", out.String(), err)
		}
		return shown
	}
	refused := func(confirmation string) {
		t.Helper()
		out.Reset()
		err := runHomeUpdate(context.Background(), &out, &out, updateOptions{confirmed: confirmation})
		if err == nil || err.Error() != "What updating this CYFR changes is not the change the CYFR app showed, so nothing was changed. Open Update CYFR in the app again to see the change as it is now" {
			t.Fatalf("a change other than the one read answered %v:\n%s", err, out.String())
		}
	}

	s := newUpdateScenario(t, []byte(compose), nil)
	shown := offer()
	s.onlyReadTheSchema()
	s.composeUnchanged()
	// The same change in words, from a file that is not the one read.
	if err := os.WriteFile("docker-compose.yml", []byte(compose+"# edited after the offer\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	refused(shown.Confirmation)
	if err := os.WriteFile("docker-compose.yml", []byte(compose), 0o644); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{confirmed: shown.Confirmation}); err != nil ||
		!strings.Contains(out.String(), "Updated to release 0.9.0.") || strings.Contains(out.String(), "Update this CYFR?") {
		t.Fatalf("the change read, confirmed, answered %v:\n%s", err, out.String())
	}
	if got := read(t, filepath.Join(s.project, "docker-compose.yml")); got != string(switched([]byte(compose))) {
		t.Errorf("the confirmed change left docker-compose.yml as:\n%s", got)
	}

	// The same file in another folder.
	s = newUpdateScenario(t, []byte(compose), nil)
	refused(shown.Confirmation)
	s.onlyReadTheSchema()
	s.composeUnchanged()

	s = newUpdateScenario(t, switched(shippedCompose(t)), nil)
	out.Reset()
	shown = shownChange{}
	if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{offer: true}); err != nil ||
		json.Unmarshal(lastLine(), &shown) != nil || shown.Change != "" || shown.Confirmation != "" || !strings.HasPrefix(shown.Current, "This CYFR is on release 0.9.0 already") {
		t.Fatalf("a home on its release is offered %q (%v)", out.String(), err)
	}
	s.composeUnchanged()
}

// The CYFR app's page is the question a changed compose file is asked at:
// its offer shows the file's differences, no environment value among
// them, and a change confirmed with that offer's confirmation replaces the
// file, the person's kept in the snapshot, as a yes at a terminal does.
func TestTheAppsOfferShowsAChangedComposeFileAndItsConfirmationReplacesIt(t *testing.T) {
	edited := strings.Replace(string(shippedCompose(t)), "    environment:\n", "    environment:\n      - CYFR_MINE=secret-in-compose\n", 1)
	askWith(t, false, strings.NewReader(""))
	s := newUpdateScenario(t, []byte(edited), nil)
	var out bytes.Buffer
	if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{offer: true}); err != nil {
		t.Fatalf("the offer answered %v:\n%s", err, out.String())
	}
	text := strings.TrimSuffix(out.String(), "\n")
	var shown shownChange
	if err := json.Unmarshal([]byte(text[strings.LastIndex(text, "\n")+1:]), &shown); err != nil || shown.Confirmation == "" ||
		!strings.Contains(shown.Change, editedOffer+"  +       - CYFR_MINE=…\n") ||
		!strings.Contains(shown.Change, "Going on writes release 0.9.0's docker-compose.yml in its place") {
		t.Fatalf("the offer of a changed compose file is %q (%v)", out.String(), err)
	}
	if strings.Contains(out.String(), "secret-in-compose") {
		t.Errorf("the offer printed an environment value:\n%s", out.String())
	}
	s.composeUnchanged()
	out.Reset()
	if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{confirmed: shown.Confirmation}); err != nil ||
		!strings.Contains(out.String(), "Updated to release 0.9.0.") || strings.Contains(out.String(), "(yes/no)") {
		t.Fatalf("the confirmed change answered %v:\n%s", err, out.String())
	}
	if got := read(t, filepath.Join(s.project, "docker-compose.yml")); got != string(switched(shippedCompose(t))) {
		t.Errorf("the confirmed change left docker-compose.yml as:\n%s", got)
	}
}

// The schema read's refusal is said with .env's values blanked, as the
// engine redacts what docker says: a diagnostic of docker's can quote
// them.
func TestTheSchemaReadsRefusalSaysNoValueOfEnv(t *testing.T) {
	newUpdateScenario(t, shippedCompose(t), nil)
	if err := os.WriteFile(".env", []byte(scenarioEnv+"CYFR_SECRET_KEY_BASE="+keyBase+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	saved := schemaDocker
	t.Cleanup(func() { schemaDocker = saved })
	schemaDocker = func(context.Context, []string, ...string) (string, error) {
		return "", fmt.Errorf("Error response from daemon: invalid env %s", keyBase)
	}
	var out bytes.Buffer
	err := runHomeUpdate(context.Background(), &out, &out, updateOptions{yes: true})
	if err == nil || !strings.HasPrefix(err.Error(), "cyfr update could not read which schema") {
		t.Fatalf("the update answered %v", err)
	}
	if strings.Contains(err.Error(), keyBase) || strings.Contains(out.String(), keyBase) {
		t.Fatalf("the refusal says .env's value: %v\n%s", err, out.String())
	}
}

// digestOld is an older release's cyfr digest.
var digestOld = "sha256:" + strings.Repeat("c", 64)

// A home whose compose file names this release's digests already gets no
// stop and no snapshot; one on a newer release than this cyfr is refused,
// nothing run; neither asks.
func TestUpdateLeavesAHomeOnItsReleaseAndRefusesANewerOne(t *testing.T) {
	askWith(t, true, strings.NewReader("yes\n"))
	s := newUpdateScenario(t, switched(shippedCompose(t)), nil)
	out, err := s.run(context.Background())
	if err != nil || !strings.Contains(out, "This CYFR is on release 0.9.0 already, so there is nothing to switch; cyfr update starts it and waits for every service of its stack.\nStarting release 0.9.0...\nRelease 0.9.0 is up.\n") || strings.Contains(out, "Update this CYFR?") {
		t.Fatalf("a home on its release answered %v:\n%s", err, out)
	}
	if log := s.log(); !slices.Equal(log, append([]string{"ENGINE lock update", "ENGINE resume"}, startedAndUp()...)) {
		t.Errorf("a home on its release ran:\n%s", strings.Join(log, "\n"))
	}
	s.noBackups()

	newer := strings.ReplaceAll(string(switched(shippedCompose(t))), "ghcr.io/cyfrworks/cyfr:"+testVersion+"@", "ghcr.io/cyfrworks/cyfr:1.0.0-rc.1@")
	s = newUpdateScenario(t, []byte(newer), nil)
	out, err = s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "This CYFR is on release 1.0.0-rc.1, newer than this cyfr's 0.9.0, and cyfr update never moves a CYFR to an older release") || !strings.Contains(err.Error(), "restore a snapshot taken on it with 'cyfr restore backups/<timestamp>'") {
		t.Fatalf("a home on a newer release answered %v:\n%s", err, out)
	}
	s.nothingRan()

	// A pre-release of this release is older than it: the home moves on.
	older := strings.ReplaceAll(string(switched(shippedCompose(t))), "ghcr.io/cyfrworks/cyfr:"+testVersion+"@", "ghcr.io/cyfrworks/cyfr:0.9.0-rc.1@")
	s = newUpdateScenario(t, []byte(older), nil)
	if out, err := s.run(context.Background()); err != nil || !strings.Contains(out, "This CYFR is on release 0.9.0-rc.1; this cyfr is release 0.9.0.") || !strings.Contains(out, "Updated to release 0.9.0.") {
		t.Fatalf("a home on this release's pre-release answered %v:\n%s", err, out)
	}
}

// The change made is the one shown: a compose file rewritten between the
// offer and the lock refuses, nothing stopped.
func TestUpdateRefusesAComposeChangedAfterTheOffer(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	askWith(t, true, readerFunc(func(p []byte) (int, error) {
		if err := os.WriteFile(filepath.Join(s.project, "docker-compose.yml"), append(slices.Clone(s.compose), "# edited\n"...), 0640); err != nil {
			return 0, err
		}
		return copy(p, "yes\n"), io.EOF
	}))
	var out bytes.Buffer
	err := runHomeUpdate(context.Background(), &out, &out, updateOptions{})
	if err == nil || err.Error() != "docker-compose.yml changed after cyfr update showed what it changes; nothing was changed. Run 'cyfr update' again" {
		t.Fatalf("the update answered %v:\n%s", err, out.String())
	}
	s.nothingStopped()
	s.noBackups()
	if holder := s.engine.held(); holder != "" {
		t.Errorf("the lock is still held, by %s", holder)
	}
}

type readerFunc func(p []byte) (int, error)

func (f readerFunc) Read(p []byte) (int, error) { return f(p) }

// The whole verb in a home: the program is the newest release, and the
// update goes on to the home, confirmed by --yes.
func TestUpdateGoesOnToTheHome(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	saved := latestRelease
	t.Cleanup(func() { latestRelease = saved })
	latestRelease = func(context.Context) (string, error) { return testVersion, nil }
	var out bytes.Buffer
	if err := runUpdate(context.Background(), &out, &out, updateOptions{yes: true}); err != nil {
		t.Fatalf("cyfr update --yes: %v\n%s", err, out.String())
	}
	if text := out.String(); !strings.Contains(text, "cyfr 0.9.0 is the newest release.\n") || !strings.Contains(text, "Updated to release 0.9.0.") || strings.Contains(text, "Update this CYFR?") {
		t.Errorf("cyfr update --yes in a home said:\n%s", text)
	}
	if n := strings.Count(strings.Join(s.log(), "\n"), " up -d"); n != 1 {
		t.Errorf("the stack was switched %d times", n)
	}
}

// A home on release 1.0.0 is refused by a cyfr of 0.9.0 before anything
// stops, whatever its compose file's tags say: named 1.0.0, the offer
// refuses with nothing run; latest, or a set of cyfr tags that differ, the
// roster the running cyfr answers says 1.0.0 and the update refuses there.
// A home whose cyfr is not running is held to the release its image
// answers offline, before the snapshot, the old stack started again.
func TestUpdateRefusesAHomeOnANewerReleaseWhateverItsTags(t *testing.T) {
	askWith(t, true, strings.NewReader("yes\n"))
	shipped := string(shippedCompose(t))
	roster := "CYFR_ROSTER=" + `{"self":"cyfr@abc","release":"1.0.0","slots":[{"node":"cyfr@abc","owner":"o1","release":"1.0.0","lease_until":"2026-10-16T12:00:10Z"}]}` + "\n"
	plain := strings.Replace(shipped, "image: ghcr.io/cyfrworks/cyfr:latest", "image: ghcr.io/cyfrworks/cyfr:1.0.0@"+digestOld, 1)
	mixed := strings.Replace(plain, "\nservices:\n", "\nservices:\n  extra:\n    image: ghcr.io/cyfrworks/cyfr:0.8.0\n", 1)
	if plain == shipped || mixed == plain {
		t.Fatal("the planted composes changed nothing")
	}
	for name, compose := range map[string]string{"named": plain, "latest": shipped, "mixed": mixed} {
		t.Run(name, func(t *testing.T) {
			s := newUpdateScenario(t, []byte(compose), nil)
			s.composes = map[string]string{"0.8.0": compose}
			s.answer("rpc.out", roster)
			out, err := s.run(context.Background())
			for _, part := range []string{"release 1.0.0, newer than this cyfr's 0.9.0, and cyfr update never moves a CYFR to an older release", "Nothing was changed"} {
				if err == nil || !strings.Contains(err.Error(), part) {
					t.Fatalf("a home on 1.0.0 answered %v, want %q:\n%s", err, part, out)
				}
			}
			if name == "named" {
				s.nothingRan()
				return
			}
			s.nothingStopped()
			s.noBackups()
			s.composeUnchanged()
		})
	}

	t.Run("not running", func(t *testing.T) {
		s := newUpdateScenario(t, []byte(shipped), nil)
		s.answer("ps.out", "locus\nlocus-guard\n")
		s.answer("eval.out", "CYFR_LIVE_SLOTS="+`{"release":"1.0.0","slots":[]}`+"\n")
		out, err := s.run(context.Background())
		if err == nil || !strings.Contains(err.Error(), "This CYFR is on release 1.0.0, newer than this cyfr's 0.9.0") || !strings.Contains(err.Error(), "The old stack was started again") {
			t.Fatalf("a stopped home on 1.0.0 answered %v:\n%s", err, out)
		}
		s.noBackups()
		s.composeUnchanged()
		if s.hasCall("SCAFFOLD WRITE") {
			t.Error("the refused update wrote the scaffold")
		}
	})
}

// An interrupt while the update asks ends it there, without an answer,
// nothing run and nothing changed.
func TestUpdateQuestionEndsOnAnInterrupt(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	started, unblock := make(chan struct{}), make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { close(unblock) })
	askWith(t, true, readerFunc(func([]byte) (int, error) {
		once.Do(func() { close(started) })
		<-unblock
		return 0, io.EOF
	}))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var out bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- runHomeUpdate(ctx, &out, &out, updateOptions{}) }()
	select {
	case <-started:
	case <-time.After(10 * time.Second):
		t.Fatal("the update never asked")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, errUpdateInterrupted) || ExitStatus(err) != exitInterrupted {
			t.Errorf("the interrupted question answered %v (exit %d)", err, ExitStatus(err))
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the question did not end on the interrupt")
	}
	if !strings.Contains(out.String(), "Update this CYFR? (yes/no) [no]: ") {
		t.Errorf("the update did not ask:\n%s", out.String())
	}
	s.onlyReadTheSchema()
}

// The schema the running CYFR's database was built from is read before
// anything stops, through the running cyfr, and one other than the
// release's, or an answer that does not read, refuses with nothing pulled,
// stopped, snapshotted or written.
func TestUpdateRefusesAnotherSchemaBeforeAnythingStops(t *testing.T) {
	unreadable := func(reason string) string {
		return "cyfr update could not read which schema this CYFR's database was built from (" + reason + "), and release 0.9.0 runs only on a database built from its own schema; nothing was stopped or changed. Fix the cause and run 'cyfr update' again"
	}
	for name, c := range map[string]struct{ out, exit, want string }{
		"another schema": {"booting\nCYFR_SCHEMA=" + schemaOther + "\n", "0",
			"This CYFR's database was built from schema a0a0a0a0a0a0…, and release 0.9.0 runs only on a database built from schema 5e5e5e5e5e5e…: there is no upgrade path between them, so nothing was stopped or changed.\n" +
				"To start over on release 0.9.0, keeping nothing of this CYFR: run 'cyfr uninstall' here, then delete this directory by hand (with sudo: CYFR's container owns data/) and remove the volumes it names, then install release 0.9.0 with: curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | CYFR_VERSION=0.9.0 sh"},
		"no answer":         {"booting\n", "0", unreadable("0 lines starting CYFR_SCHEMA=, want one")},
		"two answers":       {"CYFR_SCHEMA=" + schemaRelease + "\nCYFR_SCHEMA=" + schemaRelease + "\n", "0", unreadable("2 lines starting CYFR_SCHEMA=, want one")},
		"not a fingerprint": {"CYFR_SCHEMA=sha256:" + schemaRelease + "\n", "0", unreadable(`the answer "sha256:` + schemaRelease + `" is not a schema fingerprint`)},
	} {
		t.Run(name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.answer("schema.out", c.out)
			s.answer("schema.exit", c.exit)
			out, err := s.run(context.Background())
			if err == nil || err.Error() != c.want {
				t.Fatalf("the update answered %v, want\n%s\n%s", err, c.want, out)
			}
			// Nothing before the refusal but the read: no lock, no
			// recovery, no configuration.
			if got, want := s.log(), s.schemaRead(true); !slices.Equal(got, want) {
				t.Errorf("docker ran\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
			s.nothingStopped()
			s.composeUnchanged()
			s.noBackups()
		})
	}

	// A read that fails is no answer either.
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("schema.exit", "1")
	out, err := s.run(context.Background())
	if err == nil || !strings.HasPrefix(err.Error(), "cyfr update could not read which schema this CYFR's database was built from (") || !strings.HasSuffix(err.Error(), "), and release 0.9.0 runs only on a database built from its own schema; nothing was stopped or changed. Fix the cause and run 'cyfr update' again") {
		t.Fatalf("a failed read answered %v\n%s", err, out)
	}
	if s.hasCall("pull ") {
		t.Errorf("the update pulled after a failed schema read:\n%s", strings.Join(s.log(), "\n"))
	}
	s.nothingStopped()
	s.composeUnchanged()
	s.noBackups()
}

// With cyfr stopped, the schema is read offline in a one-off container of
// its image, and refuses as the running read does; the release's own
// schema goes on with the update.
func TestUpdateReadsTheSchemaOfAStoppedCyfrOffline(t *testing.T) {
	stopped := func(t *testing.T) *updateScenario {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.answer("cyfrps.out", "")
		s.answer("ps.out", "locus\nlocus-guard\n")
		return s
	}

	s := stopped(t)
	s.answer("schema.out", "CYFR_SCHEMA="+schemaOther+"\n")
	out, err := s.run(context.Background())
	if err == nil || !strings.HasPrefix(err.Error(), "This CYFR's database was built from schema a0a0a0a0a0a0…, and release 0.9.0 runs only on a database built from schema 5e5e5e5e5e5e…") {
		t.Fatalf("a stopped cyfr of another schema answered %v\n%s", err, out)
	}
	if got, want := s.log(), s.schemaRead(false); !slices.Equal(got, want) {
		t.Errorf("docker ran\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	s.nothingStopped()
	s.composeUnchanged()
	s.noBackups()

	// An image that is not on the machine is not pulled: the read fails,
	// and the update refuses.
	s = stopped(t)
	s.answer("schema.err", "Unable to find image 'ghcr.io/cyfrworks/cyfr:0.8.0' locally\n")
	s.answer("schema.exit", "125")
	if _, err := s.run(context.Background()); err == nil || !strings.HasPrefix(err.Error(), "cyfr update could not read which schema this CYFR's database was built from (docker run failed: exit status 125: Unable to find image") {
		t.Fatalf("a stopped cyfr whose image is missing answered %v", err)
	}
	if got, want := s.log(), s.schemaRead(false); !slices.Equal(got, want) {
		t.Errorf("docker ran\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	s = stopped(t)
	out, err = s.run(context.Background())
	if err != nil || !strings.Contains(out, "Updated to release 0.9.0.") {
		t.Fatalf("a stopped cyfr of the release's schema answered %v\n%s", err, out)
	}
	if got := s.log(); len(got) < 3 || !slices.Equal(got[:3], s.schemaRead(false)) {
		t.Errorf("the schema was not read offline first:\n%s", strings.Join(got, "\n"))
	}
}

// treeOf is every path under dir with its bytes, mode and owner, so a test
// sees any write, chmod or chown beneath it.
func treeOf(t *testing.T, dir string) map[string]string {
	t.Helper()
	tree := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		entry := fmt.Sprintf("%v %v", info.Mode(), fileOwner(info))
		if info.Mode().IsRegular() {
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			entry += " " + md5Hex(data)
		}
		tree[path] = entry
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return tree
}

// A refused update changes nothing before its refusal: an access switch an
// interrupted command left is not recovered (no docker call, the stack not
// stopped or started, the journal as it was), and the lock writes no
// state, since the schema read and its refusal come before the lock.
func TestUpdateRefusesBeforeTheLockAndAnyRecovery(t *testing.T) {
	requireCompose(t)
	d, dir, _ := interruptedSwitch(t)
	useRealEngine(t, d)
	savedVersion, savedFetch, savedRead := version.Version, fetchManifest, schemaDocker
	t.Cleanup(func() { version.Version, fetchManifest, schemaDocker = savedVersion, savedFetch, savedRead })
	version.Version = testVersion
	fetchManifest = func(context.Context, string) (*release.Manifest, error) {
		return &release.Manifest{Version: testVersion, Images: testImages, SchemaFingerprint: schemaRelease}, nil
	}
	var reads [][]string
	schemaDocker = func(ctx context.Context, env []string, args ...string) (string, error) {
		reads = append(reads, args)
		if args[0] == "ps" {
			return "c0ffee\n", nil
		}
		return "CYFR_SCHEMA=" + schemaOther + "\n", nil
	}
	before := treeOf(t, dir)

	var out bytes.Buffer
	err := runHomeUpdate(context.Background(), &out, &out, updateOptions{yes: true})
	if err == nil || !strings.HasPrefix(err.Error(), "This CYFR's database was built from schema a0a0a0a0a0a0…") {
		t.Fatalf("the update answered %v\n%s", err, out.String())
	}
	if len(reads) != 2 || reads[0][0] != "ps" || !slices.Equal(reads[1], []string{"exec", "c0ffee", "bin/cyfr", "rpc", testSchema}) {
		t.Errorf("the schema read ran %q", reads)
	}
	if calls := d.calls(); !slices.Equal(calls, []string{""}) {
		t.Errorf("the update ran docker through the engine before its refusal:\n%s", strings.Join(calls, "\n"))
	}
	if running := d.running(); !slices.Equal(running, []string{"cyfr"}) {
		t.Errorf("the stack runs %q, want cyfr as it ran", running)
	}
	if after := treeOf(t, dir); !maps.Equal(after, before) {
		t.Errorf("the project changed before the refusal:\nbefore %v\nafter  %v", before, after)
	}
}

// The offline read of a stopped CYFR changes none of its files: the data's
// owner and mode and the Aqua files stay as they were, since the one-off
// container mounts nothing and skips the entrypoint that seeds and chowns.
func TestUpdateOfflineReadLeavesTheDataAndAquaAlone(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("cyfrps.out", "")
	s.answer("schema.out", "CYFR_SCHEMA="+schemaOther+"\n")
	s.edit("aqua/aqua.md", "# the person's own Aqua\n")
	before := treeOf(t, s.project)
	if _, err := s.run(context.Background()); err == nil {
		t.Fatal("the update of another schema went ahead")
	}
	if after := treeOf(t, s.project); !maps.Equal(after, before) {
		t.Errorf("the project changed:\nbefore %v\nafter  %v", before, after)
	}
	read := s.schemaRead(false)[1]
	for _, flag := range []string{" -v ", " --volume", " --mount", " --volumes-from"} {
		if strings.Contains(read, flag) {
			t.Errorf("the offline read mounts something (%s): %s", flag, read)
		}
	}
	if got := s.log(); !slices.Equal(got, s.schemaRead(false)) {
		t.Errorf("docker ran\n%s", strings.Join(got, "\n"))
	}
}

// A read cancelled while the offline container runs removes that
// container by its name, as every end of the read does: the docker client
// a cancellation stops leaves the container running.
func TestUpdateRemovesTheOfflineReadsContainerWhenCancelled(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("cyfrps.out", "")
	s.answer("schema.block", "")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := s.run(ctx)
		done <- err
	}()
	deadline := time.Now().Add(10 * time.Second)
	for !s.hasCall("run --rm --name " + testSchemaContainer) {
		if time.Now().After(deadline) {
			t.Fatal("the offline read never started")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	if err := <-done; err == nil {
		t.Fatal("a cancelled update went ahead")
	}
	s.answer("schema.release", "")
	if got := s.log(); !slices.Equal(got, s.schemaRead(false)) {
		t.Errorf("docker ran\n%s\nwant the read and the removal of its container by name\n%s", strings.Join(got, "\n"), strings.Join(s.schemaRead(false), "\n"))
	}
	s.nothingStopped()
	s.noBackups()
}

// A running stack's stop is held (the engine's Hold) until the switch: an
// update that leaves the old stack stopped on purpose before it, after a
// failed snapshot or under a compose file edited meanwhile, releases the
// hold and starts nothing; one that starts the old stack again closes it by
// that start; a release that fails before the switch starts the old stack
// again; a hold that cannot be recorded stops nothing.
func TestUpdateHoldsTheStackUntilItsSwitch(t *testing.T) {
	order := func(t *testing.T, s *updateScenario, lines ...string) {
		t.Helper()
		log, last := s.log(), -1
		for _, line := range lines {
			i := slices.Index(log, line)
			if i <= last {
				t.Fatalf("%q is not after %v in\n%s", line, lines, strings.Join(log, "\n"))
			}
			last = i
		}
	}
	t.Run("a failed snapshot", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		if err := os.MkdirAll(s.snapshotDir(), 0700); err != nil {
			t.Fatal(err)
		}
		if _, err := s.run(context.Background()); err == nil || !strings.HasPrefix(err.Error(), "The snapshot failed") {
			t.Fatalf("update answered %v", err)
		}
		order(t, s, "ENGINE hold update", "ENGINE close-serve", profiles+"stop caddy", "ENGINE release")
		if s.hasCall("ENGINE start") {
			t.Errorf("the update started a stack after a failed snapshot:\n%s", strings.Join(s.log(), "\n"))
		}
	})
	t.Run("a compose file edited during the stop", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.answer("stop-cyfr.edit", "# edited while the update ran\n")
		s.answer("eval.out", "CYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[{"node":"cyfr@other","owner":"o2","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"}]}`+"\n")
		_, err := s.run(context.Background())
		if err == nil || !strings.Contains(err.Error(), "The old stack is left stopped: docker-compose.yml changed while cyfr update ran") {
			t.Fatalf("update answered %v", err)
		}
		order(t, s, "ENGINE hold update", profiles+"stop caddy", "ENGINE release")
		if s.hasCall("ENGINE start") {
			t.Errorf("the update started the old stack under an edited compose file:\n%s", strings.Join(s.log(), "\n"))
		}
	})
	// A release that fails where the update leaves the stack stopped on
	// purpose promises no stopped stack: its answer says the next cyfr
	// command may start CYFR. The engine's recovery does when the removal
	// failed (TestAHoldWhoseReleaseFailsIsStartedByTheNextCommand) and does
	// not when only the directory's sync failed after it
	// (TestAHoldWhoseReleaseSyncFailsStartsNothing).
	unreleased := "Clearing the record of the stop could not be confirmed (access: remove journal.json: input/output error), so the next cyfr command may start CYFR as .env and docker-compose.yml then hold it"
	t.Run("a failed snapshot whose release fails", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		if err := os.MkdirAll(s.snapshotDir(), 0700); err != nil {
			t.Fatal(err)
		}
		s.engine.releaseErr = errors.New("access: remove journal.json: input/output error")
		_, err := s.run(context.Background())
		want := "The snapshot failed: mkdir backups/20261016T120000Z: file exists.\n" + unreleased + "; docker-compose.yml is unchanged; no snapshot directory was made. Fix the cause and run 'cyfr update' again"
		if err == nil || err.Error() != want {
			t.Fatalf("update answered %v, want %q", err, want)
		}
		if s.hasCall("ENGINE start") {
			t.Errorf("the update started a stack after a failed snapshot:\n%s", strings.Join(s.log(), "\n"))
		}
	})
	t.Run("an edited compose file whose release fails", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.answer("stop-cyfr.edit", "# edited while the update ran\n")
		s.answer("eval.out", "CYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[{"node":"cyfr@other","owner":"o2","release":"0.8.0","lease_until":"2026-10-16T12:00:10Z"}]}`+"\n")
		s.engine.releaseErr = errors.New("access: remove journal.json: input/output error")
		_, err := s.run(context.Background())
		want := "A slot is still live 400ms after the stop: cyfr@other (release 0.8.0). A server outside this stack holds it; stop that server first.\nThe old stack is stopped: docker-compose.yml changed while cyfr update ran and is kept as it is. " + unreleased
		if err == nil || err.Error() != want {
			t.Fatalf("update answered %v, want %q", err, want)
		}
		if s.hasCall("ENGINE start") {
			t.Errorf("the update started the old stack under an edited compose file:\n%s", strings.Join(s.log(), "\n"))
		}
	})
	t.Run("a release that fails", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.engine.releaseErr = errors.New("access: remove journal.json: input/output error")
		_, err := s.run(context.Background())
		want := "cyfr update could not release its record of the stop (access: remove journal.json: input/output error).\nThe old stack was started again; docker-compose.yml is unchanged"
		if err == nil || err.Error() != want {
			t.Fatalf("update answered %v, want %q", err, want)
		}
		order(t, s, "ENGINE hold update", "ENGINE release", "ENGINE start update")
		if s.hasCall("SCAFFOLD WRITE") {
			t.Errorf("the update switched after its release failed:\n%s", strings.Join(s.log(), "\n"))
		}
		s.composeUnchanged()
	})
	t.Run("a hold that cannot be recorded", func(t *testing.T) {
		s := newUpdateScenario(t, shippedCompose(t), nil)
		s.engine.holdErr = errors.New("access: write journal.json: no space left on device")
		_, err := s.run(context.Background())
		want := "cyfr update could not record that it stops the running stack (access: write journal.json: no space left on device); the running stack was not touched, and docker-compose.yml is unchanged"
		if err == nil || err.Error() != want {
			t.Fatalf("update answered %v, want %q", err, want)
		}
		s.nothingStopped()
		s.noBackups()
	})
}

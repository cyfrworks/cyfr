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
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// restoreFakeDocker is fakeDocker with the two offline evals told apart:
// the declaration answers from mark.*, the live read as fakeDocker's eval;
// pg_restore keeps its stdin in pgrestore.stdin and answers from
// pgrestore.*.
const restoreFakeDocker = `#!/bin/bash
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
  printf '%s %s\n' "$1" "$(md5sum < docker-compose.yml | cut -c1-32)" >> "$d/state"
  [ -f "$d/$1.signal" ] && kill -TERM "$PPID"
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
      case "$*" in *mark_restore*) answer mark ;; esac
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
  pull) answer pull ;;
  run)
    case "$*" in
      *pg_restore*) cat > "$d/pgrestore.stdin"; answer pgrestore ;;
      *psql*) answer probe ;;
      *pg_dump*) answer dump ;;
    esac ;;
esac
exit 0
`

const (
	testMark     = `IO.puts("CYFR_RESTORE_ID=" <> Cyfr.Release.mark_restore())`
	testRestored = "rst_0192f0a1-7c4e-7d2a-9b1e-3f5a6b7c8d9e"
	sqliteBytes  = "SQLite format 3\x00main"
	editedEnv    = "CYFR_BEHIND_PROXY=true\nCYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\nCYFR_PORT=4999\n"
)

// restoreScenario is an update scenario whose update has taken a snapshot,
// with the fake docker swapped for restoreFakeDocker and its log cleared.
type restoreScenario struct {
	*updateScenario
	dir string
	// env is .env as the snapshot holds it.
	env []byte
}

// newRestoreScenario runs `cyfr update` over a SQLite cell, prepare given
// the scenario first to shape it, and answers the scenario with the
// snapshot taken and every docker call of the update forgotten.
func newRestoreScenario(t *testing.T, compose []byte, env map[string]string, prepare func(*updateScenario)) *restoreScenario {
	s := newUpdateScenario(t, compose, env)
	for name, data := range map[string]string{"data/cyfr.db": sqliteBytes, "data/cyfr.db-wal": "sqlite-wal"} {
		if err := os.WriteFile(filepath.Join(s.project, name), []byte(data), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if prepare != nil {
		prepare(s)
	}
	if out, err := s.run(context.Background()); err != nil {
		t.Fatalf("update: %v\n%s", err, out)
	}
	r := &restoreScenario{updateScenario: s, dir: s.snapshotDir()}
	var err error
	if r.env, err = os.ReadFile(filepath.Join(s.project, ".env")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.fake, "docker"), []byte(restoreFakeDocker), 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"log", "state"} {
		if err := os.Remove(filepath.Join(s.fake, name)); err != nil {
			t.Fatal(err)
		}
	}
	s.answer("mark.out", "starting the repo\nCYFR_RESTORE_ID="+testRestored+"\n")
	return r
}

// restore runs `cyfr restore` of the scenario's snapshot; the lock is gone
// after it and no docker child shared cyfr's process group.
func (r *restoreScenario) restore(start bool) (string, error) {
	r.t.Helper()
	var out bytes.Buffer
	err := runRestore(context.Background(), r.dir, start, &out, &out)
	if _, statErr := os.Lstat(filepath.Join(r.project, updateLockName)); !errors.Is(statErr, fs.ErrNotExist) {
		r.t.Errorf("the lock is left behind (%v)", statErr)
	}
	for _, line := range r.log() {
		if strings.Contains(line, "{shared process group}") {
			r.t.Errorf("a docker child ran in cyfr's process group: %s", line)
		}
	}
	return out.String(), err
}

// edit writes content at the project path rel.
func (r *restoreScenario) edit(rel, content string) {
	r.t.Helper()
	p := filepath.Join(r.project, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0644); err != nil {
		r.t.Fatal(err)
	}
}

// read answers the bytes at path, "<absent>" when there are none.
func read(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "<absent>"
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// stoppedUndeclared fails unless the restore stopped every running service and
// neither declared the restore nor started anything.
func (r *restoreScenario) stoppedUndeclared() {
	r.t.Helper()
	log := r.log()
	for _, svc := range []string{"caddy", "cyfr", "locus-backends-guard"} {
		if !slices.Contains(log, profiles+"stop "+svc) {
			r.t.Errorf("the restore did not stop %s:\n%s", svc, strings.Join(log, "\n"))
		}
	}
	for _, line := range log {
		if strings.Contains(line, "mark_restore") || strings.Contains(line, " up ") || strings.HasSuffix(line, " start") {
			r.t.Errorf("the restore ran %q", line)
		}
	}
}

// configAsBefore fails unless docker-compose.yml and .env hold before.
func (r *restoreScenario) configAsBefore(compose, env string) {
	r.t.Helper()
	if got := read(r.t, filepath.Join(r.project, "docker-compose.yml")); got != compose {
		r.t.Errorf("docker-compose.yml is not as it was before the restore")
	}
	if got := read(r.t, filepath.Join(r.project, ".env")); got != env {
		r.t.Errorf(".env holds %q, want it as it was, %q", got, env)
	}
}

// The ceremony in order on a cell whose storage root has a bind mounted
// under it: the stop, the configuration read with the snapshot's
// docker-compose.yml back, the live read, the parts put back, the
// declaration and then the start. Every byte cyfr sees comes back to the
// host path it sees it through, the nested bind's at its own source; what
// was written since is gone, and the host bytes a nested bind covers are
// left alone.
func TestRestorePutsEveryPartBackAndDeclaresBeforeTheStart(t *testing.T) {
	nested := t.TempDir()
	for name, content := range map[string]string{"acme/c.wasm": "nested component", "kept": "kept bytes"} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(nested, name)), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(nested, name), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	compose := strings.Replace(string(shippedCompose(t)), "      - ./data:/app/data\n", "      - ./data:/app/data\n      - "+nested+":/app/data/components\n", 1)
	r := newRestoreScenario(t, []byte(compose), nil, func(s *updateScenario) {
		s.addVolume(map[string]any{"type": "bind", "source": nested, "target": "/app/data/components"})
		if err := os.WriteFile(filepath.Join(s.project, "data", "components", "covered"), []byte("covered"), 0600); err != nil {
			t.Fatal(err)
		}
	})

	// The cell moves on after the snapshot: the switch rewrote the image
	// lines, .env and every part change, and a migration left a -shm.
	r.edit(".env", editedEnv)
	r.edit("data/cyfr.db", "migrated database")
	r.edit("data/cyfr.db-wal", "migrated wal")
	r.edit("data/cyfr.db-shm", "migrated shm")
	r.edit("data/blobs/x", "rewritten")
	r.edit("data/blobs/new", "written after the snapshot")
	r.edit("data/components/covered", "covered, edited")
	if err := os.Remove(filepath.Join(nested, "acme", "c.wasm")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nested, "after"), []byte("after"), 0600); err != nil {
		t.Fatal(err)
	}

	out, err := r.restore(true)
	if err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	want := []string{
		profiles + "ps --services --status running",
		profiles + "stop caddy",
		profiles + "stop cyfr",
		profiles + "stop locus-runtime",
		profiles + "stop locus-builds",
		profiles + "stop locus-backends",
		profiles + "stop locus-builds-guard",
		profiles + "stop locus-backends-guard",
		profiles + "stop",
		profiles + "config --format json",
		profiles + "run --rm --no-deps -T cyfr bin/cyfr eval " + testLive,
		profiles + "run --rm --no-deps -T cyfr bin/cyfr eval " + testMark,
		profiles + "up -d --wait --wait-timeout 900",
	}
	if got := r.log(); !slices.Equal(got, want) {
		t.Fatalf("docker ran\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	// The stop saw the switched compose file; from the configuration read
	// on, every call saw the snapshot's.
	sum := func(data []byte) string { return fmt.Sprintf("%x", md5.Sum(data)) }
	for _, line := range strings.Split(strings.TrimSpace(read(t, filepath.Join(r.fake, "state"))), "\n") {
		fields := strings.Fields(line)
		wantSum := sum([]byte(compose))
		if fields[0] == "ps" || strings.HasPrefix(fields[0], "stop-") {
			wantSum = sum(switched([]byte(compose)))
		}
		if fields[1] != wantSum {
			t.Errorf("docker %s saw another compose file than the one it should", fields[0])
		}
	}

	// The host bytes the nested bind covers are cyfr's to see through no
	// path, so they stay as they are.
	for rel, content := range map[string]string{
		"docker-compose.yml":          compose,
		".env":                        string(r.env),
		"data/cyfr.db":                sqliteBytes,
		"data/cyfr.db-wal":            "sqlite-wal",
		"data/cyfr.db-shm":            "<absent>",
		"data/blobs/x":                "blob",
		"data/blobs/new":              "<absent>",
		"data/components/covered":     "covered, edited",
		"data/components/acme/c.wasm": "component-bytes",
		"data/components/kept":        "<absent>",
	} {
		if got := read(t, filepath.Join(r.project, rel)); got != content {
			t.Errorf("%s holds %q, want %q", rel, got, content)
		}
	}
	if link, err := os.Readlink(filepath.Join(r.project, "data", "current")); err != nil || link != "components/acme" {
		t.Errorf("data/current is %q (error %v), want the link components/acme", link, err)
	}
	for rel, content := range map[string]string{"acme/c.wasm": "nested component", "kept": "kept bytes", "after": "<absent>"} {
		if got := read(t, filepath.Join(nested, rel)); got != content {
			t.Errorf("the nested bind's %s holds %q, want %q", rel, got, content)
		}
	}
	if info, err := os.Stat(filepath.Join(r.project, ".env")); err != nil || info.Mode().Perm() != 0600 {
		t.Errorf(".env's mode is %v (error %v), want 0600", info.Mode().Perm(), err)
	}
	if info, err := os.Stat(filepath.Join(r.project, "docker-compose.yml")); err != nil || info.Mode().Perm() != 0640 {
		t.Errorf("docker-compose.yml's mode is %v (error %v), want 0640 kept", info.Mode().Perm(), err)
	}
	if !strings.Contains(out, "Declared restore "+testRestored+";") {
		t.Errorf("the output does not name the restore id:\n%s", out)
	}
	for _, secret := range []string{keyBase, "keyring-secret-value"} {
		if strings.Contains(out, secret) || strings.Contains(strings.Join(r.log(), "\n"), secret) {
			t.Errorf("a secret reached the output or a docker argv")
		}
	}
	// The snapshot is left as it was, for another restore.
	if _, err := readSnapshot(r.dir); err != nil {
		t.Errorf("the snapshot no longer reads: %v", err)
	}
}

// A snapshot taken with no WAL leaves none beside the restored file.
func TestRestoreRemovesAWALTheSnapshotDoesNotHold(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, func(s *updateScenario) {
		if err := os.Remove(filepath.Join(s.project, "data", "cyfr.db-wal")); err != nil {
			t.Fatal(err)
		}
	})
	r.edit("data/cyfr.db-wal", "a later WAL")
	if out, err := r.restore(false); err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	if got := read(t, filepath.Join(r.project, "data", "cyfr.db-wal")); got != "<absent>" {
		t.Errorf("the restored database has the WAL %q beside it", got)
	}
}

// A live slot on any host, of any release, the snapshot's own included,
// refuses once the window closes: the stack stays stopped, nothing is put
// back and docker-compose.yml and .env are as they were.
func TestRestoreRefusesALiveMemberOfAnyRelease(t *testing.T) {
	compose := shippedCompose(t)
	for name, release := range map[string]string{"the snapshot's": `"0.8.0"`, "the running": `"0.9.0"`, "another": `"0.7.0"`, "none": `null`} {
		t.Run(name, func(t *testing.T) {
			r := newRestoreScenario(t, compose, nil, nil)
			r.edit(".env", editedEnv)
			r.edit("data/blobs/x", "rewritten")
			r.answer("eval.out", "CYFR_LIVE_SLOTS="+`{"release":"0.8.0","slots":[{"node":"cyfr@other-host","owner":"o2","release":`+release+`,"lease_until":"2026-10-16T12:00:12Z"}]}`+"\n")
			before := read(t, filepath.Join(r.project, "docker-compose.yml"))
			out, err := r.restore(true)
			if err == nil || !strings.Contains(err.Error(), "cyfr@other-host") || !strings.Contains(err.Error(), "whole cell stopped") || !strings.Contains(err.Error(), "left stopped") {
				t.Fatalf("restore answered %v\n%s", err, out)
			}
			r.stoppedUndeclared()
			r.configAsBefore(before, editedEnv)
			if got := read(t, filepath.Join(r.project, "data", "blobs", "x")); got != "rewritten" {
				t.Errorf("a part was put back before the refusal: blobs/x holds %q", got)
			}
		})
	}

	// A read that errs or does not answer refuses the same way; it never
	// reads as no slot.
	r := newRestoreScenario(t, compose, nil, nil)
	r.answer("eval.out", "** (UndefinedFunctionError) function Cyfr.Release.live_slots/0 is undefined\n")
	before := read(t, filepath.Join(r.project, "docker-compose.yml"))
	if out, err := r.restore(true); err == nil || !strings.Contains(err.Error(), "offline roster read") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	r.stoppedUndeclared()
	r.configAsBefore(before, string(r.env))
}

// A declaration that fails, prints no id or prints one that does not read
// leaves the stack stopped and never starts it, the parts being back.
func TestRestoreNeverStartsAnUndeclaredRestore(t *testing.T) {
	compose := shippedCompose(t)
	for name, answer := range map[string]struct{ out, exit string }{
		"error":    {"CYFR_RESTORE_ID=" + testRestored + "\n", "1"},
		"no line":  {"** (UndefinedFunctionError) function Cyfr.Release.mark_restore/0 is undefined\n", "1"},
		"two ids":  {"CYFR_RESTORE_ID=rst_a\nCYFR_RESTORE_ID=rst_b\n", "0"},
		"empty id": {"CYFR_RESTORE_ID=\n", "0"},
		"bad id":   {"CYFR_RESTORE_ID=rst a\n", "0"},
	} {
		t.Run(name, func(t *testing.T) {
			r := newRestoreScenario(t, compose, nil, nil)
			r.edit("data/blobs/x", "rewritten")
			r.answer("mark.out", answer.out)
			r.answer("mark.exit", answer.exit)
			out, err := r.restore(true)
			if err == nil || !strings.Contains(err.Error(), "could not be declared") || !strings.Contains(err.Error(), "must not start undeclared") || !strings.Contains(err.Error(), testMark) {
				t.Fatalf("restore answered %v\n%s", err, out)
			}
			log := r.log()
			if last := log[len(log)-1]; last != profiles+"run --rm --no-deps -T cyfr bin/cyfr eval "+testMark {
				t.Errorf("the restore went on past the failed declaration to %q", last)
			}
			if slices.ContainsFunc(log, func(line string) bool { return strings.Contains(line, " up ") || strings.HasSuffix(line, " start") }) {
				t.Errorf("the restore started the stack:\n%s", strings.Join(log, "\n"))
			}
			if got := read(t, filepath.Join(r.project, "data", "blobs", "x")); got != "blob" {
				t.Errorf("blobs/x holds %q, want the snapshot's", got)
			}
		})
	}
}

// --no-start declares the restore and starts nothing.
func TestRestoreNoStartDeclaresAndLeavesTheStackStopped(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	out, err := r.restore(false)
	if err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	log := r.log()
	if last := log[len(log)-1]; last != profiles+"run --rm --no-deps -T cyfr bin/cyfr eval "+testMark {
		t.Errorf("the restore ended with %q, want the declaration", last)
	}
	if !strings.Contains(out, "Declared restore "+testRestored) || !strings.Contains(out, "left stopped (--no-start)") {
		t.Errorf("the output is\n%s", out)
	}
}

// A start that fails after the declaration stops the stack again and says
// the restore is declared.
func TestRestoreStopsAStackThatDoesNotStart(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	r.answer("up.exit", "1")
	out, err := r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "left stopped") || !strings.Contains(err.Error(), testRestored+" is declared") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	if log := r.log(); log[len(log)-1] != profiles+"stop" {
		t.Errorf("the restore did not stop the stack after the failed start:\n%s", strings.Join(log, "\n"))
	}
}

// On PostgreSQL the dump goes through pg_restore in the server's own major,
// on its stdin, the URL in the container's environment and never on an
// argv or in the output; a pg_restore that fails is not declared.
func TestRestoreLoadsTheDumpWithoutTheURLOnArgv(t *testing.T) {
	compose := shippedCompose(t)
	pg := map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL}
	newPG := func(t *testing.T) *restoreScenario {
		r := newRestoreScenario(t, compose, pg, func(s *updateScenario) { s.answer("dump.out", "PGDMP custom-format dump") })
		r.answer("probe.out", "170004\n")
		return r
	}
	r := newPG(t)
	out, err := r.restore(true)
	if err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	probe := `run --rm --network host -e CYFR_UPDATE_PG_URL postgres:18 sh -c exec psql "$CYFR_UPDATE_PG_URL" -tAc "SHOW server_version_num" {env CYFR_UPDATE_PG_URL set}`
	load := "run --rm -i --network host -e CYFR_UPDATE_PG_URL postgres:17 sh -c " + restoreScript + " {env CYFR_UPDATE_PG_URL set}"
	log := r.log()
	at := func(line string) int { return slices.Index(log, line) }
	config, live, mark := at(profiles+"config --format json"), at(profiles+"run --rm --no-deps -T cyfr bin/cyfr eval "+testLive), at(profiles+"run --rm --no-deps -T cyfr bin/cyfr eval "+testMark)
	if !(config >= 0 && config < at(probe) && at(probe) < live && live < at(load) && at(load) < mark && mark < at(profiles+"up -d --wait --wait-timeout 900")) {
		t.Errorf("the probe, the live read, the load and the declaration are out of order:\n%s", strings.Join(log, "\n"))
	}
	if got := read(t, filepath.Join(r.fake, "pgrestore.stdin")); got != "PGDMP custom-format dump" {
		t.Errorf("pg_restore read %q, want the dump", got)
	}
	if whole := strings.Join(log, "\n") + out; strings.Contains(whole, pgPassword) || strings.Contains(whole, "127.0.0.1:5432") {
		t.Errorf("the database URL reached a docker argv or the output:\n%s", whole)
	}

	r = newPG(t)
	r.answer("pgrestore.out", "pg_restore: error: "+pgURL+"\n")
	r.answer("pgrestore.exit", "1")
	out, err = r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "pg_restore in postgres:17 failed") || !strings.Contains(err.Error(), "not declared restored") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	if strings.Contains(err.Error()+out, pgPassword) {
		t.Errorf("the refusal holds the database password")
	}
	r.stoppedUndeclared()
}

// With an S3 store the restore says the object store is outside the
// snapshot and puts back the rest.
func TestRestoreStatesTheS3Limit(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), map[string]string{"CYFR_STORAGE": "s3"}, nil)
	out, err := r.restore(true)
	if err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	if !strings.Contains(out, s3OutsideSnapshot) {
		t.Errorf("the output lacks the S3 limit:\n%s", out)
	}
}

// A snapshot that is incomplete or whose layout cyfr restore cannot invert
// refuses before any docker call, the project unchanged.
func TestRestoreRefusesASnapshotItCannotInvert(t *testing.T) {
	compose := shippedCompose(t)
	manifest := func(edit func(m map[string]any)) func(r *restoreScenario) {
		return func(r *restoreScenario) {
			var m map[string]any
			if err := json.Unmarshal([]byte(read(t, filepath.Join(r.dir, "snapshot.json"))), &m); err != nil {
				t.Fatal(err)
			}
			edit(m)
			data, _ := json.Marshal(m)
			if err := os.WriteFile(filepath.Join(r.dir, "snapshot.json"), data, 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	file := func(name, content string) func(r *restoreScenario) {
		return func(r *restoreScenario) {
			if err := os.WriteFile(filepath.Join(r.dir, name), []byte(content), 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	remove := func(name string) func(r *restoreScenario) {
		return func(r *restoreScenario) {
			if err := os.RemoveAll(filepath.Join(r.dir, name)); err != nil {
				t.Fatal(err)
			}
		}
	}
	cases := []struct {
		name    string
		breakIt func(r *restoreScenario)
		want    string
	}{
		{"no snapshot.json", remove("snapshot.json"), "incomplete snapshot"},
		{"not complete", manifest(func(m map[string]any) { m["complete"] = false }), "does not say complete"},
		{"no release", manifest(func(m map[string]any) { m["version"] = "" }), "names no release"},
		{"unknown adapter", manifest(func(m map[string]any) { m["storage_adapter"] = "gcs" }), "neither local nor s3"},
		{"unknown field", manifest(func(m map[string]any) { m["mounts"] = []string{"components"} }), "not a snapshot's"},
		{"unknown part", manifest(func(m map[string]any) { m["parts"] = append(m["parts"].([]any), "caddy") }), `lists "caddy"`},
		{"part twice", manifest(func(m map[string]any) { m["parts"] = append(m["parts"].([]any), "keyring") }), "twice"},
		{"part unlisted", manifest(func(m map[string]any) { m["parts"] = []any{"database", "database-wal", "storage", ".env", "compose"} }), "does not list the part keyring"},
		{"storage against s3", manifest(func(m map[string]any) { m["storage_adapter"] = "s3" }), "lists storage true"},
		{"part missing", remove("database-wal"), "lists database-wal, which is not there"},
		{"entry unlisted", file("notes", "mine"), "holds notes"},
		{"database of no kind", file("database", "not a database"), "neither a SQLite file nor"},
		{"keyring with no key", file("keyring", "OTHER='x'\n"), "holds neither"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRestoreScenario(t, compose, nil, nil)
			c.breakIt(r)
			before := read(t, filepath.Join(r.project, "docker-compose.yml"))
			out, err := r.restore(true)
			if err == nil || !strings.Contains(err.Error(), c.want) || !strings.Contains(err.Error(), "nothing was changed") {
				t.Fatalf("restore answered %v, want a refusal naming %q\n%s", err, c.want, out)
			}
			if log := r.log(); log != nil {
				t.Errorf("docker ran before the refusal:\n%s", strings.Join(log, "\n"))
			}
			r.configAsBefore(before, string(r.env))
		})
	}
}

// A configuration the snapshot does not fit refuses once the stack is
// stopped, before the live read and before any part is put back, and puts
// docker-compose.yml and .env back as they were: a mount under the storage
// root with no place in the snapshot, a mount that is no bind, a storage
// root holding the project, a keyring other than the snapshot's, another
// database or another storage adapter.
func TestRestoreRefusesAConfigurationTheSnapshotDoesNotFit(t *testing.T) {
	compose := shippedCompose(t)
	nested := t.TempDir()
	cases := []struct {
		name    string
		breakIt func(r *restoreScenario)
		want    string
	}{
		{"unplaced mount", func(r *restoreScenario) {
			r.addVolume(map[string]any{"type": "bind", "source": nested, "target": "/app/data/elsewhere"})
		}, "no place storage/elsewhere"},
		{"mount of the wrong kind", func(r *restoreScenario) {
			r.addVolume(map[string]any{"type": "bind", "source": nested, "target": "/app/data/blobs/x"})
		}, "not a regular file"},
		{"no bind", func(r *restoreScenario) {
			r.addVolume(map[string]any{"type": "volume", "source": "cyfr-blobs", "target": "/app/data/blobs"})
		}, "volume mount at /app/data/blobs"},
		{"volumes_from", func(r *restoreScenario) { r.setService("volumes_from", []string{"service:other"}) }, "volumes_from"},
		{"a storage root holding the project", func(r *restoreScenario) {
			r.setService("volumes", []map[string]any{{"type": "bind", "source": r.project, "target": "/app/data"}})
		}, "holds the project or the snapshot"},
		{"another keyring", func(r *restoreScenario) {
			env := map[string]any{"CYFR_SECRET_KEY_BASE": keyBase, "CYFR_CRYPTO_KEYRING": `{"keys":[]}`}
			r.setService("environment", env)
		}, "its CYFR_CRYPTO_KEYRING is not the one"},
		{"a keyring setting missing", func(r *restoreScenario) {
			r.setService("environment", map[string]any{"CYFR_SECRET_KEY_BASE": keyBase})
		}, "its CYFR_CRYPTO_KEYRING is not the one"},
		{"another database", func(r *restoreScenario) {
			r.setService("environment", map[string]any{"CYFR_SECRET_KEY_BASE": keyBase, "CYFR_CRYPTO_KEYRING": keyring, "CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL})
		}, "its database is postgres"},
		{"another storage", func(r *restoreScenario) {
			r.setService("environment", map[string]any{"CYFR_SECRET_KEY_BASE": keyBase, "CYFR_CRYPTO_KEYRING": keyring, "CYFR_STORAGE": "s3"})
		}, "its storage is s3"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRestoreScenario(t, compose, nil, nil)
			c.breakIt(r)
			r.edit(".env", editedEnv)
			r.edit("data/blobs/new", "written after the snapshot")
			before := read(t, filepath.Join(r.project, "docker-compose.yml"))
			out, err := r.restore(true)
			if err == nil || !strings.Contains(err.Error(), c.want) || !strings.Contains(err.Error(), "left stopped") || !strings.Contains(err.Error(), "as they were") {
				t.Fatalf("restore answered %v, want a refusal naming %q\n%s", err, c.want, out)
			}
			if strings.Contains(err.Error()+out, "keyring-secret-value") || strings.Contains(err.Error()+out, pgPassword) {
				t.Errorf("the refusal holds a secret")
			}
			r.stoppedUndeclared()
			if slices.Contains(r.log(), profiles+"run --rm --no-deps -T cyfr bin/cyfr eval "+testLive) {
				t.Errorf("the restore read the live slots of a configuration it refuses")
			}
			r.configAsBefore(before, editedEnv)
			if got := read(t, filepath.Join(r.project, "data", "blobs", "new")); got != "written after the snapshot" {
				t.Errorf("a part was put back before the refusal")
			}
		})
	}
}

// `cyfr restore` takes exactly one argument, a snapshot directory; anything
// else is a usage error before anything is read or stopped.
func TestRestoreUsage(t *testing.T) {
	if err := restoreCmd.Args(restoreCmd, nil); err == nil {
		t.Error("cyfr restore with no argument was accepted")
	}
	if err := restoreCmd.Args(restoreCmd, []string{"a", "b"}); err == nil {
		t.Error("cyfr restore with two arguments was accepted")
	}
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	for _, bad := range []string{filepath.Join(r.project, "backups", "missing"), filepath.Join(r.project, "cyfr.yaml")} {
		err := runRestore(context.Background(), bad, true, &bytes.Buffer{}, &bytes.Buffer{})
		if err == nil || !strings.Contains(err.Error(), "Usage: cyfr restore <snapshot>") {
			t.Errorf("cyfr restore %s answered %v", bad, err)
		}
	}
	if log := r.log(); log != nil {
		t.Errorf("docker ran:\n%s", strings.Join(log, "\n"))
	}
}

// A restore refuses while an update or another restore holds the lock the
// two share.
func TestRestoreSharesTheUpdateLock(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	lock := filepath.Join(r.project, updateLockName)
	if err := os.WriteFile(lock, []byte("4242\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(lock) })
	err := runRestore(context.Background(), r.dir, true, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "update or restore holds") || !strings.Contains(err.Error(), "pid 4242") || !strings.Contains(err.Error(), "'cyfr restore' again") {
		t.Errorf("a restore beside a held lock answered %v", err)
	}
	if log := r.log(); log != nil {
		t.Errorf("docker ran:\n%s", strings.Join(log, "\n"))
	}
}

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
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/reach"
)

// restoreFakeDocker is fakeDocker with the two offline evals told apart:
// the declaration answers from mark.*, the live read as fakeDocker's eval;
// pg_restore keeps its stdin in pgrestore.stdin and answers from
// pgrestore.*; <key>.kill kills the calling process with SIGKILL, as a
// crash would. A call naming the staged compose file sees that file, every
// other docker-compose.yml.
const restoreFakeDocker = `#!/bin/bash
d="$FAKE_DOCKER_DIR"
file=docker-compose.yml
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
  printf '%s %s\n' "$1" "$(digest < "$file")" >> "$d/state"
  if [ -f "$d/$1.kill" ]; then kill -KILL "$PPID"; exit 0; fi
  [ -f "$d/$1.signal" ] && kill -TERM "$PPID"
  [ -f "$d/$1.out" ] && cat "$d/$1.out"
  exit "$(cat "$d/$1.exit" 2>/dev/null || echo 0)"
}
if [ "$1" = compose ]; then
  shift
  while [ "$1" = -p ] || [ "$1" = -f ] || [ "$1" = --project-directory ] || [ "$1" = --profile ]; do
    if [ "$1" = -f ] && [ "$2" = .docker-compose.yml.restore ]; then file="$2"; fi
    shift 2
  done
  sub="$1"
  shift
  case "$sub" in
    exec) answer rpc ;;
    stop) answer "stop-${1:-all}" ;;
    config)
      # compose merges .env (env_file) into the service's environment, so
      # the restore's bar reaches the answer as .env sets it.
      # The engine's editor writes the bar bare, or single-quoted when it
      # needs quoting.
      v="$(sed -n -e "s/^CYFR_RESTORE_INCOMPLETE='\(.*\)'\$/\1/p" -e "t" -e "s/^CYFR_RESTORE_INCOMPLETE=\([^'].*\)\$/\1/p" .env 2>/dev/null | tail -n 1)"
      if [ -n "$v" ] && [ ! -f "$d/config.nobar" ]; then
        printf 'config %s\n' "$(digest < "$file")" >> "$d/state"
        if [ -f "$d/config.kill" ]; then kill -KILL "$PPID"; exit 0; fi
        sed "s|\"environment\":{|\"environment\":{\"CYFR_RESTORE_INCOMPLETE\":\"$v\",|" "$d/config.out"
        exit "$(cat "$d/config.exit" 2>/dev/null || echo 0)"
      fi
      answer config ;;
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
	// testOffline is an offline eval the restore runs, its own bar lifted
	// in the one-off container.
	testOffline  = "run --rm --no-deps -T -e CYFR_RESTORE_INCOMPLETE= cyfr bin/cyfr eval "
	testMark     = `IO.puts("CYFR_RESTORE_ID=" <> Cyfr.Release.mark_restore())`
	testRestored = "rst_0192f0a1-7c4e-7d2a-9b1e-3f5a6b7c8d9e"
	sqliteBytes  = "SQLite format 3\x00main"
	// editedEnv is .env as the home holds it after the snapshot: another
	// line beside the same reach.
	editedEnv = scenarioEnv + "CYFR_CPU_LIMIT=2\n"
)

// stagedConfig is the restore's read of the configuration the snapshot's
// compose file gives, staged beside docker-compose.yml, override files
// after it: under the snapshot's head's profiles, the project named.
func (r *restoreScenario) stagedConfig(overrides ...string) string {
	files := "-f " + stagedCompose
	for _, o := range overrides {
		files += " -f " + o
	}
	return "compose -p " + reach.ProjectName(r.project) + " " + files + " --project-directory . --profile locus-builds --profile public config --format json"
}

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

// restore runs `cyfr restore` of the scenario's snapshot; the lock is
// released after it and no docker child shared cyfr's process group.
func (r *restoreScenario) restore(start bool) (string, error) {
	r.t.Helper()
	var out bytes.Buffer
	err := runRestore(context.Background(), r.dir, start, &out, &out)
	if holder := r.engine.held(); holder != "" {
		r.t.Errorf("the lock is still held, by %s", holder)
	}
	for _, line := range r.log() {
		if strings.Contains(line, "{shared process group}") {
			r.t.Errorf("a docker child ran in cyfr's process group: %s", line)
		}
	}
	return out.String(), err
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
		if strings.Contains(line, "mark_restore") || strings.Contains(line, " up ") || strings.HasPrefix(line, "ENGINE start") || strings.HasPrefix(line, "ENGINE forget-join") {
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
		"ENGINE lock restore",
		"ENGINE resume",
		profiles + "ps --services --status running",
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
		profiles + "rm --force cyfr",
		r.stagedConfig(),
		profiles + testOffline + testLive,
		profiles + testOffline + testMark,
		"ENGINE forget-join",
		"ENGINE start restore",
		profiles + "up -d",
	}
	if got := r.log(); !slices.Equal(got, want) {
		t.Fatalf("docker ran\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	// The stop and the removal of the stopped cyfr container saw the switched
	// compose file; from the configuration read on, every call saw the
	// snapshot's.
	sum := func(data []byte) string { return fmt.Sprintf("%x", md5.Sum(data)) }
	for _, line := range strings.Split(strings.TrimSpace(read(t, filepath.Join(r.fake, "state"))), "\n") {
		fields := strings.Fields(line)
		wantSum := sum([]byte(compose))
		if fields[0] == "ps" || fields[0] == "rm" || strings.HasPrefix(fields[0], "stop-") {
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
		// The scaffold files as they stood before the update, the keeper's
		// seccomp profile among them; the one the update created is gone.
		"keeper.seccomp.json":    oldScaffold["keeper.seccomp.json"],
		"configuration-guide.md": oldScaffold["configuration-guide.md"],
		"wit/cyfr/added.wit":     "<absent>",
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
// leaves the stack stopped and never starts it, the parts being back; the
// bar stays in .env, so a later 'cyfr up' refuses too.
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
			if err == nil || !strings.Contains(err.Error(), "could not be declared") || !strings.Contains(err.Error(), "barred from starting undeclared") || !strings.Contains(err.Error(), testMark) {
				t.Fatalf("restore answered %v\n%s", err, out)
			}
			log := r.log()
			if last := log[len(log)-1]; last != profiles+testOffline+testMark {
				t.Errorf("the restore went on past the failed declaration to %q", last)
			}
			if slices.ContainsFunc(log, func(line string) bool { return strings.Contains(line, " up ") || strings.HasSuffix(line, " start") }) {
				t.Errorf("the restore started the stack:\n%s", strings.Join(log, "\n"))
			}
			if got := read(t, filepath.Join(r.project, "data", "blobs", "x")); got != "blob" {
				t.Errorf("blobs/x holds %q, want the snapshot's", got)
			}
			r.barred()
			if got, want := read(t, filepath.Join(r.project, ".env")), string(barredEnv(t, r.env, r.dir)); got != want {
				t.Errorf(".env holds %q, want the snapshot's with the bar, %q", got, want)
			}
		})
	}
}

// barred fails unless .env bars the snapshot's restore and 'cyfr up'
// refuses before any docker call.
func (r *restoreScenario) barred() {
	r.t.Helper()
	if snapshot, ok := restoreBarred(filepath.Join(r.project, ".env")); !ok || snapshot != r.dir {
		r.t.Errorf(".env bars %q (%v), want the restore of %s barred", snapshot, ok, r.dir)
	}
	calls := len(r.log())
	err := upCmd.RunE(upCmd, nil)
	if err == nil || !strings.Contains(err.Error(), "has not been declared") || !strings.Contains(err.Error(), "cyfr restore "+r.dir) {
		r.t.Errorf("cyfr up answered %v, want the refusal of an undeclared restore", err)
	}
	if got := r.log(); len(got) != calls {
		r.t.Errorf("cyfr up ran docker on a barred cell: %s", strings.Join(got[calls:], "\n"))
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
	if last := log[len(log)-2:]; !slices.Equal(last, []string{profiles + testOffline + testMark, "ENGINE forget-join"}) {
		t.Errorf("the restore ended with %q, want the declaration, then the join's record forgotten", last)
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

// A failed start can leave Serve's open configuration published (written,
// then its directory sync failed), so the stop after a restored stack does
// not start closes Serve first, as every other stop does: at each docker
// compose stop of the restore Serve's configuration is the empty one.
func TestRestoreClosesServeBeforeTheStopAfterAFailedStart(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	r.answer("up.exit", "1")
	serve := filepath.Join(r.project, ".cyfr", "tailscale-serve", "serve.json")
	stops := 0
	opened := openEngine
	t.Cleanup(func() { openEngine = opened })
	openEngine = func(dir string) (stackEngine, error) {
		e, err := opened(dir)
		if err != nil {
			return nil, err
		}
		docker := observedDocker(func(ctx context.Context, c reach.Call) (reach.Result, error) {
			if slices.Contains(c.Args, "stop") {
				stops++
				if got, err := os.ReadFile(serve); err != nil || strings.TrimSpace(string(got)) != "{}" {
					t.Errorf("at the restore's docker compose stop #%d Serve was %q (%v), want {}", stops, got, err)
				}
			}
			return e.Docker().Run(ctx, c)
		})
		return failedStartOpensServe{e, serve, docker}, nil
	}
	out, err := r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "; it is left stopped.\nThe restore "+testRestored+" is declared") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	if log := r.log(); !slices.Equal(log[len(log)-2:], []string{"ENGINE close-serve", profiles + "stop"}) {
		t.Errorf("the restore did not close Serve, then stop the stack, after the failed start:\n%s", strings.Join(log, "\n"))
	}
}

// A restored stack that does not start, whose Serve then does not close,
// is left as it is: nothing is stopped, and the restore says the stack may
// still be running with Serve open.
func TestRestoreStopsNothingAfterAFailedStartWhileServeDoesNotClose(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	r.answer("up.exit", "1")
	opened := openEngine
	t.Cleanup(func() { openEngine = opened })
	openEngine = func(dir string) (stackEngine, error) {
		e, err := opened(dir)
		if err != nil {
			return nil, err
		}
		return &closeServeFailsAfterStart{stackEngine: e, err: errors.New("no space left on device")}, nil
	}
	out, err := r.restore(true)
	log := r.log()
	want := "The restored stack did not start (cyfr did not become healthy (docker compose up: exit status 1)), and Tailscale Serve could not be closed (no space left on device), so nothing was stopped and the stack may still be running with Serve open; stop it with 'cyfr down'.\nThe restore " + testRestored + " is declared and the next start takes it; read 'cyfr logs', fix the cause and run 'cyfr up'"
	if err == nil || err.Error() != want {
		t.Fatalf("restore answered %v, want %q\n%s\n%s", err, want, out, strings.Join(log, "\n"))
	}
	if last := log[len(log)-1]; strings.Contains(last, "stop") {
		t.Errorf("the restore stopped the stack with Serve not closed:\n%s", strings.Join(log, "\n"))
	}
}

// closeServeFailsAfterStart is an engine whose CloseServe fails with err
// once a start has been asked of it.
type closeServeFailsAfterStart struct {
	stackEngine
	started bool
	err     error
}

func (e *closeServeFailsAfterStart) StartWithin(ctx context.Context, cause string, health time.Duration) (reach.Receipt, error) {
	e.started = true
	return e.stackEngine.StartWithin(ctx, cause, health)
}

func (e *closeServeFailsAfterStart) CloseServe(ctx context.Context) error {
	if e.started {
		return e.err
	}
	return e.stackEngine.CloseServe(ctx)
}

// failedStartOpensServe is an engine whose failed start leaves Serve's open
// configuration at serve, as the engine's start does when Serve's
// directory sync fails after the configuration was written; its docker
// calls run through docker.
type failedStartOpensServe struct {
	stackEngine
	serve  string
	docker reach.Docker
}

func (e failedStartOpensServe) StartWithin(ctx context.Context, cause string, health time.Duration) (reach.Receipt, error) {
	rec, err := e.stackEngine.StartWithin(ctx, cause, health)
	if err == nil {
		return rec, errors.New("the start this engine fails succeeded")
	}
	if werr := os.WriteFile(e.serve, []byte(`{"TCP":{"443":{"HTTPS":true}},"Web":{"${TS_CERT_DOMAIN}:443":{"Handlers":{"/":{"Proxy":"http://cyfr:4401"}}}}}`), 0644); werr != nil {
		return rec, werr
	}
	return rec, err
}

func (e failedStartOpensServe) Docker() reach.Docker { return e.docker }

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
	probe := `run --rm -i --network host ` + pgClientImages[18] + ` sh -c IFS= read -r CYFR_UPDATE_PG_URL && exec psql "$CYFR_UPDATE_PG_URL" -tAc "SHOW server_version_num"`
	load := "run --rm -i --network host " + pgClientImages[17] + " sh -c " + restoreScript
	log := r.log()
	at := func(line string) int { return slices.Index(log, line) }
	config, live, mark := at(r.stagedConfig()), at(profiles+testOffline+testLive), at(profiles+testOffline+testMark)
	if !(config >= 0 && config < at(probe) && at(probe) < live && live < at(load) && at(load) < mark && mark < at(profiles+"up -d")) {
		t.Errorf("the probe, the live read, the load and the declaration are out of order:\n%s", strings.Join(log, "\n"))
	}
	if got := read(t, filepath.Join(r.fake, "pgrestore.stdin")); got != pgURL+"\nPGDMP custom-format dump" {
		t.Errorf("pg_restore's container read %q, want the URL on its first line, then the dump", got)
	}
	if !strings.HasPrefix(restoreScript, "IFS= read -r CYFR_UPDATE_PG_URL && ") {
		t.Errorf("the restore script does not read the URL from its first line: %s", restoreScript)
	}
	if whole := strings.Join(log, "\n") + out; strings.Contains(whole, pgPassword) || strings.Contains(whole, "127.0.0.1:5432") {
		t.Errorf("the database URL reached a docker argv or the output:\n%s", whole)
	}

	r = newPG(t)
	r.answer("pgrestore.out", "pg_restore: error: "+pgURL+"\n")
	r.answer("pgrestore.exit", "1")
	out, err = r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "pg_restore in "+pgClientImages[17]+" failed") || !strings.Contains(err.Error(), "not declared restored") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	if strings.Contains(err.Error()+out, pgPassword) {
		t.Errorf("the refusal holds the database password")
	}
	r.stoppedUndeclared()
	r.barred()
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
		{"part unlisted", manifest(func(m map[string]any) {
			m["parts"] = []any{"database", "database-wal", "storage", "scaffold", ".env", "compose"}
		}), "does not list the part keyring"},
		{"storage against s3", manifest(func(m map[string]any) { m["storage_adapter"] = "s3" }), "lists storage true"},
		{"part missing", remove("database-wal"), "lists database-wal, which is not there"},
		{"entry unlisted", file("notes", "mine"), "holds notes"},
		{"database of no kind", file("database", "not a database"), "neither a SQLite file nor"},
		{"keyring with no key", file("keyring", "OTHER='x'\n"), "holds neither"},
		{"no scaffold part", manifest(func(m map[string]any) {
			m["parts"] = []any{"database", "database-wal", "storage", "keyring", ".env", "compose"}
		}), "does not list the part scaffold"},
		{"scaffold file not managed", manifest(func(m map[string]any) { m["scaffold"] = []any{"docker-compose.yml"} }), "which cyfr update does not manage"},
		{"scaffold path outside", manifest(func(m map[string]any) { m["scaffold"] = []any{"../keeper.seccomp.json"} }), "which is no path in the project"},
		{"scaffold file twice", manifest(func(m map[string]any) { m["scaffold"] = append(m["scaffold"].([]any), "keeper.seccomp.json") }), "scaffold file keeper.seccomp.json twice"},
		{"scaffold file unlisted", file("scaffold/notes.md", "mine"), "scaffold/ holds notes.md"},
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
				t.Errorf("docker or the engine ran before the refusal:\n%s", strings.Join(log, "\n"))
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
			if slices.Contains(r.log(), profiles+testOffline+testLive) {
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

// A restore refuses while another command holds the stack's lock, naming
// it, before any docker call; and does nothing while recovery leaves a
// change unfinished.
func TestRestoreSharesTheStacksLock(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	r.engine.holder = "update"
	err := runRestore(context.Background(), r.dir, true, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "Another cyfr command holds this home (`update`)") {
		t.Errorf("a restore beside a held lock answered %v", err)
	}
	if log := r.log(); log != nil {
		t.Errorf("docker ran:\n%s", strings.Join(log, "\n"))
	}
	r.engine.holder = ""

	r.engine.resume = []reach.Receipt{{RequestID: strings.Repeat("e", 32), Op: "switch", State: "accepted", Phase: "uncertain", Code: "reach_uncertain", Payload: map[string]string{"observed": "caddy"}}}
	err = runRestore(context.Background(), r.dir, true, &bytes.Buffer{}, &bytes.Buffer{})
	if want := reach.Refuse("reach_uncertain", map[string]string{"observed": "caddy"}).Message(); err == nil || err.Error() != want {
		t.Errorf("a restore after an unfinished recovery answered %v, want %q", err, want)
	}
	if calls := r.dockerLog(); calls != nil {
		t.Errorf("docker ran:\n%s", strings.Join(calls, "\n"))
	}
}

// TestRestoreProcessHelper is `cyfr restore` in a process of its own, for
// TestRestoreCrashLeavesTheCellBarredOrUntouched to kill; it runs only
// under that test.
func TestRestoreProcessHelper(t *testing.T) {
	snapshot := os.Getenv("CYFR_TEST_RESTORE_SNAPSHOT")
	if snapshot == "" {
		t.Skip("run by TestRestoreCrashLeavesTheCellBarredOrUntouched")
	}
	useFakeEngine(t)
	if err := runRestore(context.Background(), snapshot, true, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(0)
}

// A restore killed at any step leaves a cell that either is untouched
// (killed before the bar) or is barred from starting: .env carries the bar,
// so 'cyfr up' refuses and the image's entrypoint refuses every new
// container, and the stopped cyfr container that predates the bar is gone
// before anything of the snapshot lands. Killed once the restore is
// declared, the bar is down. Run again, the restore puts every part back
// and declares it.
func TestRestoreCrashLeavesTheCellBarredOrUntouched(t *testing.T) {
	compose := shippedCompose(t)
	for _, c := range []struct {
		kill string
		// barred: the bar is up; landed: the parts are back.
		barred, landed bool
	}{
		{"stop-cyfr", false, false},
		{"rm", true, false},
		{"config", true, false},
		{"eval", true, false},
		{"mark", true, true},
		{"up", false, true},
	} {
		t.Run(c.kill, func(t *testing.T) {
			r := newRestoreScenario(t, compose, nil, nil)
			r.edit(".env", editedEnv)
			r.edit("data/blobs/x", "rewritten")
			r.answer(c.kill+".kill", "")
			cmd := exec.Command(os.Args[0], "-test.run=^TestRestoreProcessHelper$", "-test.count=1")
			cmd.Env = append(os.Environ(), "CYFR_TEST_RESTORE_SNAPSHOT="+r.dir)
			out, err := cmd.CombinedOutput()
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.Sys().(syscall.WaitStatus).Signal() != syscall.SIGKILL {
				t.Fatalf("the restore was not killed at %s (%v):\n%s", c.kill, err, out)
			}

			log := r.log()
			rm := slices.Index(log, profiles+"rm --force cyfr")
			if c.kill != "stop-cyfr" && (rm < 0 || slices.Index(log, r.stagedConfig()) >= 0 && slices.Index(log, r.stagedConfig()) < rm) {
				t.Errorf("the stopped cyfr container was not removed before the configuration read:\n%s", strings.Join(log, "\n"))
			}
			snapshot, barred := restoreBarred(filepath.Join(r.project, ".env"))
			if barred != c.barred || barred && snapshot != r.dir {
				t.Errorf("killed at %s, .env bars %q (%v), want barred %v", c.kill, snapshot, barred, c.barred)
			}
			if got, want := read(t, filepath.Join(r.project, "data", "blobs", "x")), map[bool]string{true: "blob", false: "rewritten"}[c.landed]; got != want {
				t.Errorf("killed at %s, blobs/x holds %q, want %q", c.kill, got, want)
			}
			switch {
			case c.barred:
				r.barred()
			case !c.landed:
				if got := read(t, filepath.Join(r.project, ".env")); got != editedEnv {
					t.Errorf("killed before the bar, .env holds %q, want it as it was", got)
				}
			default:
				if got := read(t, filepath.Join(r.project, ".env")); got != string(r.env) {
					t.Errorf("killed after the declaration, .env holds %q, want the snapshot's", got)
				}
			}

			// The lock dies with the restore that held it; the restore runs
			// again from the start and lowers the bar.
			if err := os.Remove(filepath.Join(r.fake, c.kill+".kill")); err != nil {
				t.Fatal(err)
			}
			if out, err := r.restore(true); err != nil {
				t.Fatalf("the restore run again: %v\n%s", err, out)
			}
			if _, barred := restoreBarred(filepath.Join(r.project, ".env")); barred {
				t.Errorf("the restore run again left the bar up")
			}
			if got := read(t, filepath.Join(r.project, "data", "blobs", "x")); got != "blob" {
				t.Errorf("the restore run again left blobs/x %q", got)
			}
		})
	}
}

// A snapshot's compose file that does not give the cyfr service .env
// refuses before any part lands: nothing would bar a start. The two files
// go back as they were, which lowers the bar.
func TestRestoreRefusesAConfigurationTheBarCannotReach(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	r.edit(".env", editedEnv)
	r.edit("data/blobs/x", "rewritten")
	r.answer("config.nobar", "")
	before := read(t, filepath.Join(r.project, "docker-compose.yml"))
	out, err := r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "does not take CYFR_RESTORE_INCOMPLETE from .env") || !strings.Contains(err.Error(), "nothing of the snapshot was put back") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	r.stoppedUndeclared()
	r.configAsBefore(before, editedEnv)
	if got := read(t, filepath.Join(r.project, "data", "blobs", "x")); got != "rewritten" {
		t.Errorf("a part was put back: blobs/x holds %q", got)
	}
}

// A legitimate snapshot can predate env_file: the update adds that field
// only after taking its snapshot. Kill restore at its read of the
// snapshot's configuration, before it can validate and reject that config.
// The compose file in place must still carry the durable bar to boot: the
// snapshot's, which would not, is staged beside it and never in place.
func TestRestoreKilledAtItsConfigurationReadLeavesComposeBarred(t *testing.T) {
	requireCompose(t)
	realDocker, err := exec.LookPath("docker")
	if err != nil {
		t.Fatal(err)
	}
	compose := string(shippedCompose(t))
	const envFile = "    env_file:\n      - .env\n"
	if !strings.Contains(compose, envFile) {
		t.Fatal("fixture no longer contains cyfr env_file")
	}
	compose = strings.Replace(compose, envFile, "", 1)
	// The old deployment can supply its settings explicitly rather than
	// loading the whole .env into the container; that is valid Compose.
	compose = strings.Replace(compose, "    environment:\n", "    environment:\n      - CYFR_SECRET_KEY_BASE="+keyBase+"\n      - 'CYFR_CRYPTO_KEYRING="+keyring+"'\n", 1)
	r := newRestoreScenario(t, []byte(compose), nil, nil)
	before := read(t, filepath.Join(r.project, "docker-compose.yml"))
	if before == compose {
		t.Fatal("update did not install its new compose configuration")
	}
	r.edit("data/blobs/x", "post-update bytes")
	r.answer("config.kill", "")
	cmd := exec.Command(os.Args[0], "-test.run=^TestRestoreProcessHelper$", "-test.count=1")
	cmd.Env = append(os.Environ(), "CYFR_TEST_RESTORE_SNAPSHOT="+r.dir)
	out, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.Sys().(syscall.WaitStatus).Signal() != syscall.SIGKILL {
		t.Fatalf("restore was not killed at config: %v\n%s", err, out)
	}
	if got := read(t, filepath.Join(r.project, "docker-compose.yml")); got == compose {
		t.Fatal("the snapshot's compose, which gives cyfr no bar, was put in place before its configuration was read")
	}
	if got := read(t, filepath.Join(r.project, stagedCompose)); got != compose {
		t.Fatal("the snapshot's compose was not staged beside docker-compose.yml")
	}
	if got := read(t, filepath.Join(r.project, "data/blobs/x")); got != "post-update bytes" {
		t.Fatalf("unexpected data replacement before config: %q", got)
	}
	if snapshot, barred := restoreBarred(filepath.Join(r.project, ".env")); !barred || snapshot != r.dir {
		t.Fatalf("host marker missing: %q, %v", snapshot, barred)
	}
	r.barred() // The CLI refuses; verify the independent container route.
	cmd = exec.Command(realDocker, "compose", "--project-directory", r.project, "-f", filepath.Join(r.project, "docker-compose.yml"), "config", "--format", "json")
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err = cmd.Output()
	if err != nil {
		t.Fatalf("real compose config: %v\n%s", err, &stderr)
	}
	var config composeConfig
	if err := json.Unmarshal(out, &config); err != nil {
		t.Fatal(err)
	}
	got := serviceSetting(config.Services["cyfr"].Environment, restoreBarrier)
	if got != r.dir {
		t.Fatalf("snapshot compose is live over post-update data, but real Compose gives boot %s=%q; host .env is barred and declaration never ran", restoreBarrier, got)
	}

	// Run to its end, the restore refuses the snapshot whose compose file
	// gives cyfr no bar, and puts the configuration back as it was.
	if err := os.Remove(filepath.Join(r.fake, "config.kill")); err != nil {
		t.Fatal(err)
	}
	r.answer("config.nobar", "")
	if out, err := r.restore(true); err == nil || !strings.Contains(err.Error(), "does not take CYFR_RESTORE_INCOMPLETE from .env") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	if got := read(t, filepath.Join(r.project, "docker-compose.yml")); got != before {
		t.Error("the refused restore left another compose file in place")
	}
	if got := read(t, filepath.Join(r.project, stagedCompose)); got != "<absent>" {
		t.Error("the refused restore left its staged compose file")
	}
}

// restoreBarred reads the bar as compose gives it to the cyfr service's
// entrypoint: the last assignment, in any form, quoted or not; withBarrier
// takes every earlier assignment out, in any form, so the one it writes is
// the only one.
func TestRestoreBarReadsEveryAssignment(t *testing.T) {
	for text, want := range map[string]string{
		"A=1\n":                      "",
		"CYFR_RESTORE_INCOMPLETE=\n": "",
		"CYFR_RESTORE_INCOMPLETE='/p/backups/x'\n":                 "/p/backups/x",
		"CYFR_RESTORE_INCOMPLETE=\nCYFR_RESTORE_INCOMPLETE=/p/b\n": "/p/b",
		"CYFR_RESTORE_INCOMPLETE=/p/b\nCYFR_RESTORE_INCOMPLETE=\n": "",
		"export CYFR_RESTORE_INCOMPLETE=/p/b\n":                    "/p/b",
		"CYFR_RESTORE_INCOMPLETE: /p/b\n":                          "/p/b",
		"# CYFR_RESTORE_INCOMPLETE=/p/b\n":                         "",
	} {
		path := filepath.Join(t.TempDir(), ".env")
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
		if got, barred := restoreBarred(path); got != want || barred != (want != "") {
			t.Errorf("restoreBarred(%q) = %q, %v; want %q", text, got, barred, want)
		}
	}
	got := string(barredEnv(t, []byte("A=1\nexport CYFR_RESTORE_INCOMPLETE='old'\nB=2\nCYFR_RESTORE_INCOMPLETE: \n"), "/p/backups/x"))
	if want := "A=1\nB=2\nCYFR_RESTORE_INCOMPLETE=/p/backups/x\n"; got != want {
		t.Errorf("withBarrier answered %q, want %q", got, want)
	}
	if got := string(barredEnv(t, nil, "/p/b")); got != "CYFR_RESTORE_INCOMPLETE=/p/b\n" {
		t.Errorf("withBarrier of no .env answered %q", got)
	}
}

// restoreBarrierFixture is tests/fixtures/restore_barrier.json, the one
// definition of the restore's bar the CLI, the server's settings roster
// and the image's entrypoint each hold their side to.
type restoreBarrierFixture struct {
	Name           string `json:"name"`
	BarredExit     int    `json:"barred_exit"`
	DeclareExpr    string `json:"declare_expr"`
	DeclaredPrefix string `json:"declared_prefix"`
}

func readRestoreBarrierFixture(t *testing.T) restoreBarrierFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "restore_barrier.json"))
	if err != nil {
		t.Fatalf("read the fixture: %v", err)
	}
	var f restoreBarrierFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	if f.Name == "" || f.BarredExit == 0 || f.DeclareExpr == "" || f.DeclaredPrefix == "" {
		t.Fatalf("the fixture lacks what this test reads: %+v", f)
	}
	return f
}

// The bar's name, the declaration the restore runs, the line it reads
// back and the offline eval's form are the shared fixture's: the
// scenario tests hold every offline eval to testOffline and the
// declaration to testMark, and this holds both to the fixture.
func TestRestoreBarrierIsTheSharedFixture(t *testing.T) {
	f := readRestoreBarrierFixture(t)
	for _, c := range []struct{ what, got, want string }{
		{"restoreBarrier", restoreBarrier, f.Name},
		{"markRestoreExpr", markRestoreExpr, f.DeclareExpr},
		{"restoreDeclared", restoreDeclared, f.DeclaredPrefix},
		{"testMark", testMark, f.DeclareExpr},
		{"testOffline", testOffline, "run --rm --no-deps -T -e " + f.Name + "= cyfr bin/cyfr eval "},
	} {
		if c.got != c.want {
			t.Errorf("%s is %q; the fixture gives %q", c.what, c.got, c.want)
		}
	}
	if !strings.Contains(f.DeclareExpr, `"`+f.DeclaredPrefix+`"`) {
		t.Errorf("the fixture's declaration %q does not print %q", f.DeclareExpr, f.DeclaredPrefix)
	}
}

// The image's entrypoint refuses to run anything while the bar is set,
// exiting as the shared fixture says, and runs the command when it is
// unset or empty, as the restore's own offline evals set it; it spells the
// fixture's name.
func TestEntrypointRefusesWhileTheRestoreIsBarred(t *testing.T) {
	f := readRestoreBarrierFixture(t)
	entrypoint := filepath.Join("..", "..", "..", "docker-entrypoint.sh")
	source, err := os.ReadFile(entrypoint)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(source), `[ -n "${`+f.Name+`:-}" ]`) {
		t.Fatalf("docker-entrypoint.sh does not test %s", f.Name)
	}
	bin := t.TempDir()
	ran := filepath.Join(bin, "ran")
	for name, body := range map[string]string{
		"setpriv": "#!/bin/sh\necho \"$@\" > " + ran + "\n",
		"chown":   "#!/bin/sh\nexit 0\n",
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0755); err != nil {
			t.Fatal(err)
		}
	}
	run := func(env ...string) (string, error) {
		os.Remove(ran)
		cmd := exec.Command("sh", entrypoint, "bin/cyfr", "start")
		cmd.Env = append([]string{"PATH=" + bin + string(os.PathListSeparator) + os.Getenv("PATH")}, env...)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	out, err := run(f.Name + "=/p/backups/20261016T120000Z")
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != f.BarredExit || !strings.Contains(out, "has not been declared") || !strings.Contains(out, "cyfr restore /p/backups/20261016T120000Z") {
		t.Errorf("the barred entrypoint answered %v:\n%s", err, out)
	}
	if _, err := os.Stat(ran); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("the barred entrypoint ran its command")
	}
	for _, env := range [][]string{nil, {f.Name + "="}} {
		if out, err := run(env...); err != nil {
			t.Errorf("the entrypoint with %v answered %v:\n%s", env, err, out)
		}
		if got := read(t, ran); !strings.Contains(got, "bin/cyfr start") {
			t.Errorf("the entrypoint with %v ran %q, want the command", env, got)
		}
	}
}

// The staged configuration is read as compose will read it in place: with
// the project's override file after it. COMPOSE_FILE in cyfr's environment
// names nothing, since the engine's runner takes every COMPOSE_* out of a
// docker call's.
func TestRestoreReadsTheStagedConfigurationAsComposeWill(t *testing.T) {
	compose := shippedCompose(t)
	r := newRestoreScenario(t, compose, nil, nil)
	r.edit("docker-compose.override.yml", "services: {}\n")
	t.Setenv("COMPOSE_FILE", "other.yml")
	if out, err := r.restore(false); err != nil {
		t.Fatalf("restore: %v\n%s", err, out)
	}
	if !slices.Contains(r.log(), r.stagedConfig("docker-compose.override.yml")) {
		t.Errorf("the staged configuration was read without the override file:\n%s", strings.Join(r.log(), "\n"))
	}
}

// A snapshot's .env becomes the project's, so the restore refuses it as
// the engine refuses a home's .env (reach.CheckEnvFile), with its
// sentence, before anything stops: a COMPOSE_* setting in any form, and a
// head that does not boot, its CYFR_PUBLIC_URL not its host's, or no
// CYFR_REACH at all.
func TestRestoreRefusesASnapshotEnvTheEngineRefusesBeforeAnythingStops(t *testing.T) {
	compose := shippedCompose(t)
	for name, edit := range map[string]func(env string) string{
		"COMPOSE_FILE":                func(env string) string { return env + "COMPOSE_FILE=other.yml\n" },
		"export COMPOSE_PROFILES":     func(env string) string { return env + "export COMPOSE_PROFILES=public\n" },
		"COMPOSE_PROJECT_NAME: other": func(env string) string { return env + "COMPOSE_PROJECT_NAME: other\n" },
		"a public URL not the host's": func(env string) string {
			return strings.Replace(env, "CYFR_PUBLIC_URL=https://cyfr.example.com\n", "CYFR_PUBLIC_URL=https://elsewhere.example.com\n", 1)
		},
		"no CYFR_REACH": func(env string) string { return strings.Replace(env, "CYFR_REACH=public\n", "", 1) },
	} {
		t.Run(name, func(t *testing.T) {
			r := newRestoreScenario(t, compose, nil, nil)
			snapshotEnv := filepath.Join(r.dir, ".env")
			edited := edit(string(r.env))
			if edited == string(r.env) {
				t.Fatalf("the edit changed nothing in %q", r.env)
			}
			if err := os.WriteFile(snapshotEnv, []byte(edited), 0600); err != nil {
				t.Fatal(err)
			}
			var refusal *reach.Refusal
			if !errors.As(reach.CheckEnvFile(snapshotEnv), &refusal) {
				t.Fatalf("the engine does not refuse the snapshot's .env:\n%s", edited)
			}
			r.edit("data/blobs/x", "rewritten")
			before := read(t, filepath.Join(r.project, "docker-compose.yml"))
			out, err := r.restore(true)
			if err == nil || !strings.Contains(err.Error(), refusal.Message()) || !strings.Contains(err.Error(), "nothing was changed") {
				t.Fatalf("restore answered %v, want the refusal %q\n%s", err, refusal.Message(), out)
			}
			if log := r.log(); log != nil {
				t.Errorf("docker or the engine ran before the refusal:\n%s", strings.Join(log, "\n"))
			}
			r.configAsBefore(before, string(r.env))
		})
	}
}

// All four default override filenames are tested with docker-compose.yml
// as the sole base file. Explicit -f selection must resolve the same
// configuration that a normal compose invocation sees after publication.
func TestRestoreStagedComposeResolvesAsTheDefaultOverrideSet(t *testing.T) {
	requireCompose(t)
	for _, override := range []string{"compose.override.yml", "compose.override.yaml", "docker-compose.override.yml", "docker-compose.override.yaml"} {
		t.Run(override, func(t *testing.T) {
			t.Chdir(t.TempDir())
			const base = "services:\n  cyfr:\n    image: alpine:3.22\n    env_file: [.env]\n"
			for name, content := range map[string]string{
				"docker-compose.yml": base,
				stagedCompose:        base,
				".env":               restoreBarrier + "=/snapshot\n",
				override:             "services:\n  cyfr:\n    environment:\n      " + restoreBarrier + ": ''\n      CYFR_DATA_PATH: /custom-data\n",
			} {
				if err := os.WriteFile(name, []byte(content), 0600); err != nil {
					t.Fatal(err)
				}
			}
			r := &restorer{}
			args, err := r.stagedComposeArgs("config", "--format", "json")
			if err != nil {
				t.Fatal(err)
			}
			staged := composeConfigOf(t, args...).Services["cyfr"]
			if err := r.publishCompose(); err != nil {
				t.Fatal(err)
			}
			active := composeConfigOf(t, "compose", "config", "--format", "json").Services["cyfr"]
			if !reflect.DeepEqual(staged.Environment, active.Environment) {
				t.Fatalf("staged resolution differs from default Compose with %s: barrier staged=%q active=%q; data path staged=%q active=%q", override,
					serviceSetting(staged.Environment, restoreBarrier), serviceSetting(active.Environment, restoreBarrier),
					serviceSetting(staged.Environment, "CYFR_DATA_PATH"), serviceSetting(active.Environment, "CYFR_DATA_PATH"))
			}
		})
	}
}

// The restore's staged read selects what the engine's own compose calls
// select but the file: the same project and the same profiles of the
// head, through the real engine and Docker Compose.
func TestRestoreStagedReadSelectsAsTheEngine(t *testing.T) {
	requireCompose(t)
	dir := filepath.Join(t.TempDir(), "_My.Home-1")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	for name, content := range map[string]string{
		"docker-compose.yml": "services:\n  cyfr:\n    image: alpine:3.22\n    env_file: [.env]\n  locus-builds:\n    image: alpine:3.22\n    profiles: [locus-builds]\n",
		".env":               "CYFR_REACH=local\nCYFR_LOCUS_BUILDS_URL=http://locus-builds:4100\n",
	} {
		if err := os.WriteFile(name, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	useRealEngine(t, nil)
	e, err := openEngine(".")
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := e.Lock("test")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	head, err := e.Head()
	if err != nil {
		t.Fatal(err)
	}
	engine, err := e.ComposeArgs(context.Background(), head, "ps")
	if err != nil {
		t.Fatal(err)
	}
	r := &restorer{updater: updater{head: head}}
	staged, err := r.stagedComposeArgs("ps")
	if err != nil {
		t.Fatal(err)
	}
	selection := func(args []string) []string {
		var kept []string
		for i := 0; i+1 < len(args); i++ {
			if args[i] == "-p" || args[i] == "--profile" || args[i] == "--project-directory" {
				kept = append(kept, args[i], args[i+1])
			}
		}
		return kept
	}
	if got, want := selection(staged), selection(engine); !slices.Equal(got, want) || !slices.Contains(want, "locus-builds") {
		t.Errorf("the staged read selects %v, the engine's compose calls %v", got, want)
	}
}

// A file set compose would not load as the restore reads it refuses before
// anything lands: another main file name beside docker-compose.yml, or more
// than one override file.
func TestRestoreRefusesAComposeFileSetItCannotStage(t *testing.T) {
	compose := shippedCompose(t)
	for name, files := range map[string][]string{
		"another main file":  {"compose.yaml"},
		"two override files": {"compose.override.yml", "docker-compose.override.yml"},
	} {
		t.Run(name, func(t *testing.T) {
			r := newRestoreScenario(t, compose, nil, nil)
			for _, file := range files {
				r.edit(file, "services: {}\n")
			}
			r.edit("data/blobs/x", "rewritten")
			before := read(t, filepath.Join(r.project, "docker-compose.yml"))
			out, err := r.restore(true)
			if err == nil || !strings.Contains(err.Error(), files[0]) || !strings.Contains(err.Error(), "nothing of the snapshot was put back") {
				t.Fatalf("restore answered %v\n%s", err, out)
			}
			r.stoppedUndeclared()
			r.configAsBefore(before, string(r.env))
			if slices.ContainsFunc(r.log(), func(line string) bool { return strings.Contains(line, " config ") }) {
				t.Errorf("the restore read a configuration it cannot stage:\n%s", strings.Join(r.log(), "\n"))
			}
		})
	}

	// A project whose one compose file has another name would not load
	// the docker-compose.yml the restore puts back beside it.
	r := newRestoreScenario(t, compose, nil, nil)
	if err := os.Rename(filepath.Join(r.project, "docker-compose.yml"), filepath.Join(r.project, "compose.yaml")); err != nil {
		t.Fatal(err)
	}
	out, err := r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "the project's compose file is compose.yaml") || !strings.Contains(err.Error(), "nothing of the snapshot was put back") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	if slices.ContainsFunc(r.log(), func(line string) bool { return strings.Contains(line, " config ") }) {
		t.Errorf("the restore read a configuration it cannot stage:\n%s", strings.Join(r.log(), "\n"))
	}
}

// A restore onto a PostgreSQL server of a major no pinned client serves
// refuses before any part lands, naming the major, and pulls nothing.
func TestRestoreRefusesAPostgresMajorWithoutAPinnedClient(t *testing.T) {
	pg := map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL}
	r := newRestoreScenario(t, shippedCompose(t), pg, func(s *updateScenario) { s.answer("dump.out", "PGDMP custom-format dump") })
	r.answer("probe.out", "130022\n")
	out, err := r.restore(true)
	if err == nil || !strings.Contains(err.Error(), "the PostgreSQL server is version 13") {
		t.Fatalf("restore answered %v\n%s", err, out)
	}
	if slices.ContainsFunc(r.log(), func(line string) bool {
		return strings.Contains(line, "pg_restore") || strings.Contains(line, "postgres:13")
	}) {
		t.Errorf("the restore loaded the dump or ran an image for the unpinned major:\n%s", strings.Join(r.log(), "\n"))
	}
}

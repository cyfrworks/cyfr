// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// The updater already accepts service-level YAML merges (serviceImage).
// Adding a direct volumes key must not shadow mounts inherited that way.
func TestAstraT4InheritedMountsKeepTheirSources(t *testing.T) {
	if err := exec.Command("docker", "compose", "version").Run(); err != nil {
		t.Fatalf("this review regression requires real Docker Compose: %v", err)
	}
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

// A legitimate snapshot can predate env_file: the update adds that field
// only after taking its snapshot. Kill restore at its read of the
// snapshot's configuration, before it can validate and reject that config.
// The compose file in place must still carry the durable bar to boot: the
// snapshot's, which would not, is staged beside it and never in place.
func TestAstraT4CrashCannotExposeUnbarredSnapshotCompose(t *testing.T) {
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
	if err := os.Remove(filepath.Join(r.project, updateLockName)); err != nil {
		t.Fatal(err)
	}
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

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func astraT4R2Compose(t *testing.T, args ...string) composeConfig {
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

// All four default override filenames are tested with docker-compose.yml
// as the sole base file. Explicit -f selection must resolve the same
// configuration that a normal compose invocation sees after publication.
func TestAstraT4R2StagedConfigMatchesDefaultOverride(t *testing.T) {
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
			staged := astraT4R2Compose(t, args...).Services["cyfr"]
			if err := r.publishCompose(); err != nil {
				t.Fatal(err)
			}
			active := astraT4R2Compose(t, "compose", "config", "--format", "json").Services["cyfr"]
			if !reflect.DeepEqual(staged.Environment, active.Environment) {
				t.Fatalf("staged resolution differs from default Compose with %s: barrier staged=%q active=%q; data path staged=%q active=%q", override,
					serviceSetting(staged.Environment, restoreBarrier), serviceSetting(active.Environment, restoreBarrier),
					serviceSetting(staged.Environment, "CYFR_DATA_PATH"), serviceSetting(active.Environment, "CYFR_DATA_PATH"))
			}
		})
	}
}

// A list referenced by cyfr is not owned solely by cyfr. Adding a missing
// default must materialize a private list, preserving the shared anchor.
func TestAstraT4R2AddingDefaultDoesNotMutateOtherService(t *testing.T) {
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
	before := astraT4R2Compose(t, "compose", "config", "--format", "json")
	// This is the switchImages path, supplied with preflight's resolved
	// targets, not just the standalone ensureCyfrComposeFields helper.
	added, err := ensureComposeFields(filepath.Join(dir, "docker-compose.yml"), map[string]bool{"/app/data": true})
	if err != nil {
		t.Fatal(err)
	}
	after := astraT4R2Compose(t, "compose", "config", "--format", "json")
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

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

// Each diagnosis is a whole line of the form Docker 29 and Compose 2.40
// write it, here as they wrote it on this project's verification host
// (the secret is where they quote a value), and says only fixed words and
// what the engine knows: a file it passes compose, a service of the
// project's configuration, a configuration path under one, a line or a
// port. Text that reads like a form inside another line is no diagnosis.
func TestDiagnosesSayOnlyWhatTheEngineKnows(t *testing.T) {
	const secret = "sentinel-diagnosis-secret"
	h := newHome(t)
	dir := h.e.dir
	env := filepath.Join(dir, ".env")
	for _, c := range []struct{ stderr, says string }{
		{"Cannot connect to the Docker daemon at unix:///nonexistent. Is the docker daemon running?\n", "the Docker daemon is not reachable"},
		{"failed to connect to the docker API at unix:///nonexistent; check if the path is correct and if the daemon is running: dial unix /nonexistent: connect: no such file or directory\n", "the Docker daemon is not reachable"},
		{"permission denied while trying to connect to the docker API at unix:///run/docker.sock\n", "this user may not use the Docker daemon"},
		{"permission denied while trying to connect to the Docker daemon socket at unix:///run/docker.sock: Get \"http://%2Frun%2Fdocker.sock/v1.51/containers/json\": dial unix /run/docker.sock: connect: permission denied\n", "this user may not use the Docker daemon"},
		{"failed to read " + env + ": line 7: unexpected character \"!\" in variable name \"" + secret + "! x\"\n", "it could not read .env at line 7"},
		{"failed to read " + env + ": line 3: unterminated quoted value \"" + secret + "\n", "it could not read .env at line 3"},
		{"failed to read " + env + ": required variable X is missing a value: " + secret + "\n", "it could not read .env"},
		{"failed to read " + filepath.Join(dir, secret) + ": line 1: key cannot contain a space\n", "it could not read an env file"},
		{"failed to read /elsewhere/" + secret + ": line 1: unterminated quoted value \"postgres://alice:no such service: " + secret + "@db\n", "it could not read an env file"},
		{"failed to read file \"" + filepath.Join(dir, "docker-compose.yml") + "\": open: permission denied\n", "it could not read docker-compose.yml"},
		{"decoding failed due to the following error(s):\n\n'services[cyfr].deploy.resources.limits.cpus' strconv.ParseFloat: parsing \"" + secret + "\": invalid syntax\n", "it refused the value of services[cyfr].deploy.resources.limits.cpus"},
		{"decoding failed due to the following error(s):\n\n'services[cyfr].mem_limit' invalid size: '" + secret + "'\n", "it refused the value of services[cyfr].mem_limit"},
		{"'services[" + secret + "].mem_limit' invalid size: 'x'\n", "it refused a value of the configuration"},
		{"'services[cyfr].x.y" + secret + " z' invalid\n", ""},
		{"Error response from daemon: failed to set up container networking: driver failed programming external connectivity on endpoint home-cyfr-1 (b122d9ad2417): Bind for 127.0.0.1:47391 failed: port is already allocated\n", "port 47391 is already in use"},
		{"Error response from daemon: failed to set up container networking: driver failed programming external connectivity on endpoint " + secret + " (e4565bb9): failed to bind host port 127.0.0.1:47392/tcp: address already in use\n", "port 47392 is already in use"},
		{" cyfr Error pull access denied for " + secret + ", repository does not exist or may require 'docker login'\nError response from daemon: pull access denied for " + secret + ", repository does not exist or may require 'docker login'\n", "an image could not be found or pulled"},
		{"Error response from daemon: failed to resolve reference \"docker.io/library/busybox:" + secret + "\": docker.io/library/busybox:" + secret + ": not found\n", "an image could not be found or pulled"},
		{"Error response from daemon: No such image: " + secret + ":latest\n", "an image could not be found or pulled"},
		{"no such service: locus-backends\n", "it has no service locus-backends"},
		{"no such service: " + secret + "\n", "it has no such service"},
		{"failed to read /x/.env: line 2: unterminated quoted value \"a\nno such service: cyfr", "it could not read an env file"},
		{"error: the value " + secret + " no such service: cyfr\n", ""},
	} {
		got := h.e.callFailed("docker compose config", &CallError{ExitCode: 1}, []byte(c.stderr))
		want := "docker compose config failed (docker exited with status 1)"
		if c.says != "" {
			want = "docker compose config failed (docker exited with status 1: " + c.says + ")"
		}
		if got != want || strings.Contains(got, secret) {
			t.Errorf("%q\nsays  %q\nwant  %q", c.stderr, got, want)
		}
	}
	if !errors.Is(&CallError{Deadline: true}, ErrDeadline) {
		t.Error("a call killed at its deadline is not ErrDeadline")
	}
}

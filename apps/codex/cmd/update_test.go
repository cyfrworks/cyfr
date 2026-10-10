// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// `cyfr update` notes each service of the bundled stack a project's compose
// file lacks, and the shipped compose file lacks none.
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
	if got := missingStackServices(path); !slices.Equal(got, []string{"opus", "locus-builds"}) {
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

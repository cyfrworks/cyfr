// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// answering is a docker that answers each command its one text.
type answering struct {
	answers map[string]string
	calls   [][]string
}

func (d *answering) Run(_ context.Context, c Call) (Result, error) {
	d.calls = append(d.calls, c.Args)
	return Result{Stdout: []byte(d.answers[c.Args[0]])}, nil
}

// Only a container that runs, of this very folder's project, publishing
// the port on 127.0.0.1 at that port, is the folder's.
func TestPublishedByIsTheFoldersOwnRunningContainer(t *testing.T) {
	root := t.TempDir()
	dir, namesake := filepath.Join(root, "a", "cyfr"), filepath.Join(root, "b", "cyfr")
	for _, d := range []string{dir, namesake} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	linked := filepath.Join(root, "linked")
	if err := os.Symlink(dir, linked); err != nil {
		linked = dir // no links on this system
	}
	type container = map[string]any
	served := func(change func(container)) string {
		c := container{"id": "c1", "running": true, "paused": false, "restarting": false, "started": "t1", "dir": dir,
			"ports": map[string]any{"4000/tcp": []map[string]string{{"HostIp": "127.0.0.1", "HostPort": "4000"}}}}
		change(c)
		raw, _ := json.Marshal(c)
		return string(raw)
	}
	at := func(ip, port string) any {
		return map[string]any{"4000/tcp": []map[string]string{{"HostIp": ip, "HostPort": port}}}
	}
	for _, tc := range []struct {
		name   string
		change func(container)
		is     bool
	}{
		{"its own", func(container) {}, true},
		{"its own, the folder named through a link", func(c container) { c["dir"] = linked }, true},
		{"another folder's of the same name", func(c container) { c["dir"] = namesake }, false},
		{"no folder named", func(c container) { c["dir"] = "" }, false},
		{"not running", func(c container) { c["running"] = false }, false},
		{"paused", func(c container) { c["paused"] = true }, false},
		{"restarting", func(c container) { c["restarting"] = true }, false},
		{"publishing nothing", func(c container) { c["ports"] = map[string]any{"4000/tcp": nil} }, false},
		{"publishing another port", func(c container) { c["ports"] = at("127.0.0.1", "4100") }, false},
		{"publishing on every address", func(c container) { c["ports"] = at("0.0.0.0", "4000") }, false},
		{"publishing on ::1", func(c container) { c["ports"] = at("::1", "4000") }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := &answering{answers: map[string]string{"ps": "c1\n", "inspect": served(tc.change) + "\n"}}
			got, ok, err := PublishedBy(t.Context(), d, dir, "cyfr", 4000)
			if err != nil || ok != tc.is || ok && got != (Published{ID: "c1", Started: "t1"}) {
				t.Fatalf("got %+v, %v, %v", got, ok, err)
			}
			for _, filter := range []string{"label=com.docker.compose.project=cyfr", "label=com.docker.compose.service=cyfr",
				"label=com.docker.compose.oneoff=False", "status=running"} {
				if !slices.Contains(d.calls[0], filter) {
					t.Errorf("ps was not asked %s: %v", filter, d.calls[0])
				}
			}
		})
	}
	if _, ok, err := PublishedBy(t.Context(), &answering{answers: map[string]string{}}, dir, "cyfr", 4000); ok || err != nil {
		t.Fatalf("no container: %v, %v", ok, err)
	}
}

// Only a Docker reached through a socket or a pipe runs its containers on
// this computer.
func TestDockerIsHereOnlyThroughASocketOrAPipe(t *testing.T) {
	for endpoint, want := range map[string]bool{
		"unix:///var/run/docker.sock":               true,
		"npipe:////./pipe/dockerDesktopLinuxEngine": true,
		"tcp://192.0.2.1:2375":                      false,
		"tcp://127.0.0.1:2375":                      false,
		"ssh://ada@box":                             false,
		"":                                          false,
	} {
		got, err := DockerIsHere(t.Context(), &answering{answers: map[string]string{"context": endpoint + "\n"}})
		if err != nil || got != want {
			t.Errorf("%q: %v, %v", endpoint, got, err)
		}
	}
}

// A folder is read from its file alone: the environment sets none of what
// is read, directly, through an interpolation or through a bare name.
func TestReadProjectAloneTakesNothingFromTheEnvironment(t *testing.T) {
	for k, v := range map[string]string{
		"CYFR_PORT": "4999", "CYFR_ACCESS": "public", "CYFR_DIRECTORY_URL": "https://launcher.example",
		"CYFR_SETUP_TOKEN": "launchers", "LAUNCHER": "4888", "INFILE": "4777",
	} {
		t.Setenv(k, v)
	}
	for _, tc := range []struct {
		env  string
		port int
		want map[string]string
	}{
		{"CYFR_ACCESS=local\nCYFR_PORT=4100\n", 4100, map[string]string{"CYFR_DIRECTORY_URL": "", "CYFR_SETUP_TOKEN": ""}},
		{"CYFR_ACCESS=local\nINFILE=4300\nCYFR_PORT=${INFILE}\n", 4300, map[string]string{"INFILE": "4300"}},
		{"CYFR_ACCESS=local\nCYFR_PORT=${LAUNCHER}\nCYFR_DIRECTORY_URL\nCYFR_SETUP_TOKEN\n", 4000,
			map[string]string{"CYFR_DIRECTORY_URL": "", "CYFR_SETUP_TOKEN": ""}},
	} {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(tc.env), 0o600); err != nil {
			t.Fatal(err)
		}
		values, head, err := ReadProjectAlone(dir)
		if err != nil || head.Mode != ModeLocal || head.Port != tc.port {
			t.Fatalf("%q read as %+v, %v", tc.env, head, err)
		}
		for k, v := range tc.want {
			if values[k] != v {
				t.Errorf("%q: %s is %q, want %q", tc.env, k, values[k], v)
			}
		}
	}
	if _, _, err := ReadProjectAlone(t.TempDir()); err == nil {
		t.Error("a folder with no .env read as a CYFR")
	}
}

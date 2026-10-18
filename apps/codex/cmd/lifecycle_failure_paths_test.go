// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// A start and an update never overlap: while cyfr up is inside its
// docker compose up, an update refuses at once on the lock the start
// holds, before it stops or dumps anything, and the start then ends and
// releases it.
func TestUpAndUpdateCannotOverlapTheirDockerOperations(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), map[string]string{"CYFR_DATABASE": "postgres", "CYFR_DATABASE_URL": pgURL})
	s.answer("up.block", "")
	s.answer("dump.block", "")
	savedTransport := http.DefaultTransport
	t.Cleanup(func() { http.DefaultTransport = savedTransport })
	http.DefaultTransport = roundTripper(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("{}")), Request: request}, nil
	})
	var work sync.WaitGroup
	t.Cleanup(func() {
		s.answer("up.release", "")
		s.answer("dump.release", "")
		work.Wait()
	})
	upResult := make(chan error, 1)
	work.Add(1)
	go func() { defer work.Done(); upResult <- upCmd.RunE(upCmd, nil) }()
	deadline := time.Now().Add(5 * time.Second)
	for !s.hasCall(profiles + "up -d") {
		if time.Now().After(deadline) {
			t.Fatal("cyfr up never reached its blocked Docker operation")
		}
		time.Sleep(10 * time.Millisecond)
	}
	updateResult := make(chan error, 1)
	work.Add(1)
	go func() { defer work.Done(); updateResult <- runUpdate(context.Background(), io.Discard, io.Discard) }()
	deadline = time.Now().Add(5 * time.Second)
	for !strings.Contains(strings.Join(s.log(), "\n"), "exec pg_dump") {
		select {
		case err := <-updateResult:
			if err == nil || !strings.Contains(err.Error(), updateLockName) || !strings.Contains(err.Error(), fmt.Sprintf("pid %d", os.Getpid())) {
				t.Fatalf("the competing update did not refuse the start's lock: %v", err)
			}
			if s.hasCall(profiles + "stop") {
				t.Fatalf("the refused update stopped the stack:\n%s", strings.Join(s.log(), "\n"))
			}
			s.answer("up.release", "")
			select {
			case err := <-upResult:
				if err != nil {
					t.Fatalf("cyfr up answered %v", err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("cyfr up did not finish its released Docker operation")
			}
			if _, err := os.Lstat(filepath.Join(s.project, updateLockName)); !errors.Is(err, fs.ErrNotExist) {
				t.Errorf("cyfr up left its lock behind (%v)", err)
			}
			return
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("the competing update neither refused nor reached its database dump")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !s.hasCall(profiles + "stop") {
		t.Fatal("the update reached its database dump before stopping the stack")
	}
	s.answer("up.release", "")
	select {
	case err := <-upResult:
		if err == nil {
			t.Fatal("cyfr up completed successfully while the update held its lock after stopping the stack, while its database dump was blocked")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cyfr up did not finish its released Docker operation")
	}
}

// A compose file that changed while the stack was stopped is the person's:
// the update detects it, keeps it on disk, starts nothing under it, and
// says the stack is left stopped, never that the file is unchanged.
func TestUpdateRefusesRestartUnderAnUnreadComposeFile(t *testing.T) {
	s := newUpdateScenario(t, shippedCompose(t), nil)
	s.answer("stop-cyfr.edit", "\nname: compose-changed-during-update\n")
	out, err := s.run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "changed while cyfr update ran") {
		t.Fatalf("the update did not detect the changed compose file: %v\n%s", err, out)
	}
	data, readErr := os.ReadFile(filepath.Join(s.project, "docker-compose.yml"))
	if readErr != nil || !strings.Contains(string(data), "name: compose-changed-during-update") {
		t.Fatalf("the changed file was not left on disk: %v", readErr)
	}
	if s.hasCall(profiles+"start") || s.hasCall(profiles+"up") {
		t.Fatalf("the update detected an unread compose file but started a stack using it:\n%s", strings.Join(s.log(), "\n"))
	}
	if !strings.Contains(err.Error(), "left stopped") || strings.Contains(err.Error(), "is unchanged") {
		t.Errorf("the refusal does not say the stack is left stopped, or says the file is unchanged: %v", err)
	}
}

// init --force that cannot remove one of the files it re-fetches names
// what is on disk after the download: the files it removed and the download
// laid down again, or the ones it removed and the download did not.
func TestInitForceDescribesFilesMissingAfterDownloadFailure(t *testing.T) {
	for _, c := range []struct {
		name     string
		download func(string) error
		want     string
		missing  bool
	}{
		{"the download fails", nil, "docker-compose.yml and keeper.seccomp.json were removed and are missing: the download did not lay them down again", true},
		{"the download lays them down", func(string) error {
			for _, name := range []string{"docker-compose.yml", "keeper.seccomp.json"} {
				if err := os.WriteFile(name, []byte("fetched\n"), 0644); err != nil {
					return err
				}
			}
			return nil
		}, "docker-compose.yml, keeper.seccomp.json and cyfr.yaml were laid down again", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := newUpdateScenario(t, shippedCompose(t), nil)
			if err := os.WriteFile(filepath.Join(s.project, "keeper.seccomp.json"), []byte("{}\n"), 0644); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(s.project, "Caddyfile", "kept"), 0755); err != nil {
				t.Fatal(err)
			}
			savedTransport, savedDownload := http.DefaultTransport, downloadScaffold
			t.Cleanup(func() { http.DefaultTransport, downloadScaffold = savedTransport, savedDownload })
			http.DefaultTransport = roundTripper(func(*http.Request) (*http.Response, error) {
				return nil, fmt.Errorf("the scaffold download is offline")
			})
			if c.download != nil {
				downloadScaffold = c.download
			}
			savedForce, _ := initCmd.Flags().GetBool("force")
			t.Cleanup(func() { _ = initCmd.Flags().Set("force", fmt.Sprint(savedForce)) })
			if err := initCmd.Flags().Set("force", "true"); err != nil {
				t.Fatal(err)
			}
			err := initCmd.RunE(initCmd, nil)
			if err == nil || !strings.Contains(err.Error(), "could not remove Caddyfile") || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("init answered %v, want it to say %q", err, c.want)
			}
			for _, name := range []string{"docker-compose.yml", "keeper.seccomp.json"} {
				if _, statErr := os.Stat(filepath.Join(s.project, name)); errors.Is(statErr, fs.ErrNotExist) != c.missing {
					t.Errorf("%s: %v, want missing %v", name, statErr, c.missing)
				}
			}
			if c.missing && strings.Contains(err.Error(), "laid down again.") && !strings.Contains(err.Error(), "cyfr.yaml was laid down again") {
				t.Errorf("init claims a missing file was laid down again: %v", err)
			}
		})
	}
}

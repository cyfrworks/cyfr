// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// fakeShell names the behaviour the test binary takes when it is run as a
// shell for a reading (TestMain): muteAfterCreate answers Chrome's first
// answers and the creation of a target, as the headless shell does, then
// nothing.
const (
	fakeShell       = "CYFR_BROWSER_FAKE_SHELL"
	muteAfterCreate = "mute-after-create"
)

func TestMain(m *testing.M) {
	if os.Getenv(fakeShell) == muteAfterCreate {
		muteShell()
		return
	}
	os.Exit(m.Run())
}

// muteShell writes its pid beside its profile's folder, makes a file in its
// profile, and answers on fd 4 the commands it reads on fd 3 until a target
// is created; after that it reads on and answers nothing.
func muteShell() {
	for _, a := range os.Args[1:] {
		if profile, ok := strings.CutPrefix(a, "--user-data-dir="); ok {
			_ = os.WriteFile(os.Getenv("FAKE_PID_FILE"), []byte(strconv.Itoa(os.Getpid())), 0o600)
			_ = os.MkdirAll(profile+"/Default", 0o700)
			_ = os.WriteFile(profile+"/Default/Preferences", []byte("{}"), 0o600)
		}
	}
	commands, answers := bufio.NewReader(os.NewFile(3, "commands")), os.NewFile(4, "answers")
	mute := false
	for {
		line, err := commands.ReadBytes(0)
		if err != nil {
			os.Exit(0)
		}
		var command struct {
			ID     int64  `json:"id"`
			Method string `json:"method"`
		}
		if mute || json.Unmarshal(bytes.TrimSuffix(line, []byte{0}), &command) != nil {
			continue
		}
		result := map[string]any{}
		switch command.Method {
		case "Browser.getVersion":
			result["userAgent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/156.0.8078.108 Safari/537.36"
		case "Target.getTargets":
			result["targetInfos"] = []any{}
		case "Target.createTarget":
			result["targetId"] = "T1"
			mute = true
		}
		answer, _ := json.Marshal(map[string]any{"id": command.ID, "result": result})
		_, _ = answers.Write(append(answer, 0))
	}
}

// readingHome is a browser's home with its Chrome temporary folder made,
// and the file the fake shell writes its pid in.
func readingHome(t *testing.T) (string, string) {
	home := t.TempDir()
	if err := chromeTemp(home); err != nil {
		t.Fatal(err)
	}
	return home, home + "/fake.pid"
}

// A reading whose shell answers the creation of its target and then
// nothing ends at its one deadline: the shell is killed and its profile
// removed, and the start is refused with the reading's error.
func TestAReadingHoldsToItsDeadline(t *testing.T) {
	home, pidFile := readingHome(t)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	env := append(os.Environ(), fakeShell+"="+muteAfterCreate, "FAKE_PID_FILE="+pidFile)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	start := time.Now()
	ended := make(chan error, 1)
	var log bytes.Buffer
	go func() {
		_, err := ownName(ctx, self, home, nil, env, &log)
		ended <- err
	}()
	select {
	case err = <-ended:
	case <-time.After(10 * time.Second):
		t.Fatal("the reading did not end at its deadline")
	}
	if took := time.Since(start); err == nil || !strings.HasPrefix(err.Error(), "Chrome did not say how it names itself") ||
		took > 3*time.Second {
		t.Fatalf("a reading whose shell went mute answered %v after %v", err, took)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(must(os.ReadFile(pidFile)))))
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("the mute shell %d is still there: %v", pid, err)
	}
	if left := must(os.ReadDir(home + "/" + chromeTmp)); len(left) != 0 || log.Len() != 0 {
		t.Fatalf("the reading left %v in Chrome's temporary folder, and said %q", left, log.String())
	}
}

// A reading whose shell ends before it answers, having written its
// throwaway profile, says so and leaves no profile behind.
func TestAFailedReadingRemovesItsProfile(t *testing.T) {
	home, _ := readingHome(t)
	shell := home + "/shell"
	script := "#!/bin/sh\nfor a; do case $a in --user-data-dir=*) d=${a#--user-data-dir=};" +
		" mkdir \"$d/Default\" && echo \"$d\" > " + home + "/read;; esac; done\nexit 1\n"
	if err := os.WriteFile(shell, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	var log bytes.Buffer
	agent, err := ownName(context.Background(), shell, home, nil, os.Environ(), &log)
	if err == nil || !strings.HasPrefix(err.Error(), "Chrome ended") {
		t.Fatalf("a reading whose Chrome ended answered %v, %v", agent, err)
	}
	read, err := os.ReadFile(home + "/read")
	if err != nil {
		t.Fatalf("the shell was not given its profile: %v", err)
	}
	if profile := strings.TrimSpace(string(read)); !readingName.MatchString(strings.TrimPrefix(profile, home+"/"+chromeTmp+"/")) {
		t.Fatalf("the profile %q is not a reading's in Chrome's temporary folder", profile)
	}
	if left := must(os.ReadDir(home + "/" + chromeTmp)); len(left) != 0 || log.Len() != 0 {
		t.Fatalf("the reading left %v in Chrome's temporary folder, and said %q", left, log.String())
	}
}

// A reading whose profile cannot be removed says so in the driver's log.
func TestAProfileLeftIsSaid(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root removes a folder its mode closes")
	}
	home, _ := readingHome(t)
	shell := home + "/shell"
	script := "#!/bin/sh\nfor a; do case $a in --user-data-dir=*) d=${a#--user-data-dir=};" +
		" mkdir \"$d/Default\" && touch \"$d/Default/Preferences\" && chmod 500 \"$d/Default\";; esac; done\nexit 1\n"
	if err := os.WriteFile(shell, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	var log bytes.Buffer
	_, err := ownName(context.Background(), shell, home, nil, os.Environ(), &log)
	left := must(os.ReadDir(home + "/" + chromeTmp))
	for _, entry := range left {
		_ = os.Chmod(home+"/"+chromeTmp+"/"+entry.Name()+"/Default", 0o700)
	}
	if err == nil || len(left) != 1 || !strings.Contains(log.String(), "the profile Chrome's name was read in is not removed") {
		t.Fatalf("an unremovable profile was not said: %v, left %v, said %q", err, left, log.String())
	}
}

// Chrome's temporary folder is a real folder of the home: one the home
// links elsewhere is refused by name and nothing behind the link is read
// or removed. Only real folders of a reading's name or Chrome's lock
// names are swept: a file, a link and a folder of another name are kept.
func TestChromeTempIsTheHomesOwnAndSweepsOnlyItsOwn(t *testing.T) {
	home, elsewhere := t.TempDir(), t.TempDir()
	behind := elsewhere + "/" + readingPrefix + "1"
	if err := os.Mkdir(behind, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, home+"/"+chromeTmp); err != nil {
		t.Fatal(err)
	}
	if err := chromeTemp(home); err == nil || err.Error() != "the home's tmp is not a folder of its own" {
		t.Fatalf("a linked temporary folder was taken: %v", err)
	}
	if _, err := os.Stat(behind); err != nil {
		t.Fatalf("a folder behind the link was removed: %v", err)
	}
	home = t.TempDir()
	dir := home + "/" + chromeTmp
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	kept := []string{readingPrefix + "2", "own-name.notes", readingPrefix + "notes", readingPrefix + "3"}
	check(t, os.WriteFile(dir+"/"+kept[0], []byte("x"), 0o600))
	check(t, os.WriteFile(dir+"/"+kept[1], []byte("x"), 0o600))
	check(t, os.Mkdir(dir+"/"+kept[2], 0o700))
	check(t, os.Symlink(elsewhere, dir+"/"+kept[3]))
	check(t, os.Mkdir(dir+"/"+readingPrefix+"4", 0o700))
	check(t, chromeTemp(home))
	var names []string
	for _, entry := range must(os.ReadDir(dir)) {
		names = append(names, entry.Name())
	}
	if strings.Join(names, " ") != strings.Join([]string{kept[0], kept[3], kept[2], kept[1]}, " ") {
		t.Fatalf("the sweep left %v", names)
	}
	if _, err := os.Stat(behind); err != nil {
		t.Fatalf("a folder behind a link was removed: %v", err)
	}
}

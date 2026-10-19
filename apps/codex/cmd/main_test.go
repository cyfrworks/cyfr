// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"

	"github.com/cyfr/codex/internal/reach"
)

// watchdogChild marks a run of this test binary that a test started as the
// engine's watchdog: one the dispatch below does not take exits at once
// rather than run the suite.
const watchdogChild = "CYFR_CMD_TEST_WATCHDOG_CHILD"

// asCyfr marks a run of this test binary that a test started as the cyfr
// process (runAsCyfr), its value how the fake engine answers each start
// and switch: started-local, every one started on this machine only, the
// machine's tailnet node not .env's; https-off, every start on this machine
// only, the tailnet's HTTPS off; resumed-local, recovery finishing a switch
// whose start was on this machine only; failed-start, every start failing;
// real-mismatch, the real engine over a docker whose tailnet machine is
// another node (tailnetDocker); real-state, the real engine over the
// stateDocker in CYFR_CMD_TEST_DOCKER_STATE, and real-state-kill the same,
// killed at its first `compose up`.
const asCyfr = "CYFR_CMD_TEST_AS_CYFR"

// TestMain runs the package's tests under a home of their own: init and
// the commands that sign in save the CLI's config under ~/.cyfr, and no
// test reads or writes the home of the person running it.
//
// The reach engine runs each docker call through `cyfr internal
// docker-run`, a re-exec of the running binary, which under go test is
// this test binary: run so, it serves the call through the command tree as
// cyfr does, and the command exits with the call's status.
func TestMain(m *testing.M) {
	if len(os.Args) > 2 && os.Args[1] == internalCmd.Name() && os.Args[2] == dockerRunCmd.Name() {
		rootCmd.SetArgs(os.Args[1:])
		_ = rootCmd.Execute()
		os.Exit(2)
	}
	// Run as the cyfr process, it is the process main runs (Run), its exit
	// status the one cyfr exits with, over a fake engine.
	if scenario := os.Getenv(asCyfr); scenario == "real-mismatch" {
		openEngine = func(dir string) (stackEngine, error) {
			e, err := reach.Open(dir, &tailnetDocker{node: "cyfr-1.tail1234.ts.net", id: "nBBBBBBBBBCNTRL"})
			if err != nil {
				return nil, err
			}
			return e, nil
		}
		os.Exit(Run(context.Background()))
	}
	if scenario := os.Getenv(asCyfr); scenario == "real-state" || scenario == "real-state-kill" {
		docker := &stateDocker{dir: os.Getenv(stateDockerDir), killAtUp: scenario == "real-state-kill"}
		openEngine = func(dir string) (stackEngine, error) {
			e, err := reach.Open(dir, docker)
			if err != nil {
				return nil, err
			}
			return e, nil
		}
		os.Exit(Run(context.Background()))
	}
	if scenario := os.Getenv(asCyfr); scenario != "" {
		s := installFakeEngine(nil)
		switch scenario {
		case "started-local":
			local := startedLocalReceipt("switch")
			s.startReceipt, s.switchReceipt = startedLocalReceipt("start"), &local
		case "https-off":
			s.startReceipt = startedLocalFor("start", "tailnet_https_off", httpsOff())
		case "resumed-local":
			s.resume = []reach.Receipt{startedLocalReceipt("switch")}
		case "failed-start":
			s.startErr = errors.New("cyfr did not become healthy")
		}
		os.Exit(Run(context.Background()))
	}
	if os.Getenv(watchdogChild) != "" {
		fmt.Fprintln(os.Stderr, "the test binary was run as the watchdog, and the dispatch did not take it")
		os.Exit(99)
	}
	home, err := os.MkdirTemp("", "cyfr-cmd-test-home-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Setenv("HOME", home)
	os.Setenv("USERPROFILE", home)
	code := m.Run()
	os.RemoveAll(home)
	os.Exit(code)
}

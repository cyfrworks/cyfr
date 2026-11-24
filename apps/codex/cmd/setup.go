// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(setupCmd)
}

var setupCmd = &cobra.Command{
	Use:     "setup",
	Short:   "Set up CYFR in the current directory from the CYFR app",
	GroupID: "server",
	Long: `Open the CYFR app with the current directory suggested on its setup screen, under Or set up CYFR on this computer, whose Set up and start does what 'cyfr init' then 'cyfr up' do there, asking nothing; 'cyfr init' sets CYFR up at a terminal. A CYFR app already open is shown as it is, with the folder it suggests.

cyfr setup needs the CYFR app installed: on Linux the cyfr-desktop package (/opt/cyfr/CYFR), on macOS CYFR.app in /Applications, on Windows the CYFR installer's install for this account. It refuses without it, and on a Linux machine with neither DISPLAY nor WAYLAND_DISPLAY set, which has no display for the app.

Exit status 1: the app was not opened, the message saying why.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		dir, err := os.Getwd()
		if err != nil {
			return fmt.Errorf("cyfr setup cannot read the current directory (%v)", err)
		}
		return runSetup(dir, cmd.OutOrStdout())
	},
}

// installedApp is where the CYFR app's installer puts its executable on
// this system: the cyfr-desktop package's on Linux, CYFR.app's in
// /Applications on macOS, and on Windows the per-user MSI's, under the
// account's LocalAppData, in the folder its package's name names
// (apps/codex/desktop/scripts/build.mjs). A test stands in for it.
var installedApp = func() string {
	switch runtime.GOOS {
	case "darwin":
		return "/Applications/CYFR.app/Contents/MacOS/CYFR"
	case "windows":
		local := os.Getenv("LOCALAPPDATA")
		if local == "" {
			return ""
		}
		return filepath.Join(local, "Programs", "cyfr-desktop", "CYFR.exe")
	}
	return "/opt/cyfr/CYFR"
}

// errNoApp and errNoDisplay are cyfr setup's refusals.
var (
	errNoApp     = errors.New("cyfr setup opens the CYFR app, which is not installed here. Run cyfr init at a terminal.")
	errNoDisplay = errors.New("This machine has no display for the CYFR app. Run cyfr init here instead.")
)

// runSetup is `cyfr setup` in dir: the installed app started with dir as
// the folder it suggests, without waiting for it. The app, not this
// process, sets CYFR up there; a second app shows the first instead.
func runSetup(dir string, out io.Writer) error {
	app := installedApp()
	if info, err := os.Stat(app); app == "" || err != nil || info.IsDir() {
		return errNoApp
	}
	if !hasDisplay() {
		return errNoDisplay
	}
	opened := exec.Command(app, "--setup-project="+dir)
	if err := opened.Start(); err != nil {
		return fmt.Errorf("cyfr setup could not open the CYFR app (%v). Run cyfr init at a terminal", err)
	}
	fmt.Fprintf(out, "Opened the CYFR app, with %s to set CYFR up in under Or set up CYFR on this computer. An app that was open already is shown as it was.\n", dir)
	return nil
}

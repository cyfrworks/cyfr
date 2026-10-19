// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"runtime"

	"github.com/cyfr/codex/internal/config"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(openCmd)
}

var openCmd = &cobra.Command{
	Use:     "open",
	Short:   "Open the home in your browser",
	GroupID: "identity",
	Long: `Open the home's address in your default browser: the --url, the
--context's address, or the current context's.

It opens the address and nothing more. No session travels from the command
line to the browser: sign in there as you always do.`,
	Example: `  cyfr open
  cyfr open --context home`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			cfg = config.DefaultForLocal()
		}
		address := serverURL(cfg)

		parsed, err := url.Parse(address)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			return fmt.Errorf("%q is not a web address to open: give the home's https:// or http:// address", address)
		}

		if err := openBrowser(address); err != nil {
			fmt.Printf("Open %s in your browser.\n", address)
			return fmt.Errorf("Could not open a browser here: %w", err)
		}
		fmt.Printf("Opened %s\n", address)
		return nil
	},
}

// openBrowser hands address to this system's opener and waits for it,
// which returns once the browser has it. A test stands in for it.
var openBrowser = func(address string) error {
	name, args := browserCommand(runtime.GOOS, address)
	if _, err := exec.LookPath(name); err != nil {
		return errors.New("no " + name + " to open it with")
	}
	opener := exec.Command(name, args...)
	// An opener that falls back to a browser in the terminal needs it.
	opener.Stdin, opener.Stdout, opener.Stderr = os.Stdin, os.Stdout, os.Stderr
	return opener.Run()
}

// browserCommand is the command that opens address on the system goos:
// open on macOS, the URL protocol handler on Windows (start is a shell
// built-in, and a shell would read the address's & as its own), and
// xdg-open elsewhere.
func browserCommand(goos, address string) (string, []string) {
	switch goos {
	case "darwin":
		return "open", []string{address}
	case "windows":
		return "rundll32", []string{"url.dll,FileProtocolHandler", address}
	default:
		return "xdg-open", []string{address}
	}
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"regexp"
	"strconv"

	"github.com/cyfr/codex/internal/reach"
	"github.com/spf13/cobra"
)

const (
	setupTokenVar = "CYFR_SETUP_TOKEN"
	adminEmailVar = "CYFR_PLATFORM_ADMIN_EMAILS"
)

// setupTokenPattern is the setup token's one form, the one `cyfr init`
// mints and the boot accepts.
var setupTokenPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func init() {
	setupCmd.AddCommand(setupLinkCmd)
	rootCmd.AddCommand(setupCmd)
}

var setupCmd = &cobra.Command{
	Use:     "setup",
	Short:   "Set up this home's administrator from this machine",
	GroupID: "server",
	Long:    "A home `cyfr init` was given no operator email holds a setup token in .env (CYFR_SETUP_TOKEN). 'cyfr setup link' prints the link that sets up its administrator, which opens on this machine alone.",
}

var setupLinkCmd = &cobra.Command{
	Use:   "link",
	Short: "Print the link that sets up this home's administrator, to open on this machine",
	Long:  "Print http://localhost:<CYFR_PORT>/setup#t=<CYFR_SETUP_TOKEN> from the .env in the current directory. The link opens on this machine's loopback address alone; the token rides in the fragment, which no request carries. A home whose .env names its administrators (CYFR_PLATFORM_ADMIN_EMAILS) has no setup link, and the command says so.",
	Args:  cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		link, err := setupLink(".env")
		if err != nil {
			return err
		}
		fmt.Fprintln(cmd.OutOrStdout(), link)
		return nil
	},
}

// setupLink is the first-run setup link of the home whose .env is at path,
// or the sentence that says why it has none.
func setupLink(path string) (string, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", errors.New("There is no .env here, so no setup link: run this command in the home's directory, or `cyfr init` to make a new home")
	}
	if err != nil {
		return "", fmt.Errorf("%s does not read (%v)", path, err)
	}
	f := parseEnvFile(string(data))
	token, _ := f.value(setupTokenVar)
	admins, _ := f.value(adminEmailVar)
	switch {
	case token == "" && admins != "":
		return "", errors.New("This home has no setup link: .env names its administrators in CYFR_PLATFORM_ADMIN_EMAILS, and each of them signs in")
	case token == "":
		return "", errors.New(".env holds no CYFR_SETUP_TOKEN, so this home has no setup link. Name its administrators in CYFR_PLATFORM_ADMIN_EMAILS in .env, then run `cyfr up`")
	case admins != "":
		return "", refusalError{reach.Refuse("setup_token_with_admins", nil)}
	case !setupTokenPattern.MatchString(token):
		return "", refusalError{reach.Refuse("setup_token_refused", map[string]string{"why": "malformed"})}
	}
	port := "4000"
	if p, ok := f.value("CYFR_PORT"); ok && p != "" {
		if n, err := strconv.Atoi(p); err != nil || n < 1 || n > 65535 || strconv.Itoa(n) != p {
			return "", fmt.Errorf("CYFR_PORT in .env is %q, which is not a port from 1 to 65535, so the setup link has no address", p)
		}
		port = p
	}
	return "http://localhost:" + port + "/setup#t=" + token, nil
}

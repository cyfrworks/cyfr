// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os/user"
)

// systemAppRoad is Linux's: the system's package tool installs the
// release's verified DEB.
func systemAppRoad() appRoad { return debRoad{} }

// debRoad updates the cyfr-desktop package: apt installs the release's
// DEB once root has checked its copy against the signed sum (stageApp), as
// one root command bounded by appReplaceWithin. dpkg puts back the files
// of an install that fails while it unpacks; one ended part way leaves
// dpkg interrupted, and apt refuses every install, saying so, until an
// administrator runs dpkg --configure -a (the README's update section).
type debRoad struct{}

func (debRoad) fetch(ctx context.Context, out io.Writer, _, target string) (*staged, error) {
	return fetchInstaller(ctx, out, target, "linux", machine.arch())
}

// elevate takes sudo's login, refusing an account that may not
// administer this machine before anything asks (mayAdminister,
// unlockSudo); the login is forgotten once the update is done.
func (debRoad) elevate(out io.Writer, again string, ask bool) (func(), error) {
	if err := mayAdminister([]string{"apt-get install -y ./" + appPackage + "_RELEASE.deb"}, out, again); err != nil {
		return nil, err
	}
	if !ask && !machine.passwordless() {
		return nil, sudoNeedsATerminal(again)
	}
	if err := unlockSudo(out, again); err != nil {
		var refused passwordRefused
		if errors.As(err, &refused) {
			return nil, fmt.Errorf("The password was not accepted, so nothing was changed and CYFR runs as it did. Run '%s' again to try again", again)
		}
		return nil, err
	}
	return machine.forget, nil
}

func (debRoad) replace(out io.Writer, s *staged, older bool) error {
	options := []string{"--reinstall"}
	if older {
		options = append(options, "--allow-downgrades")
	}
	fmt.Fprintln(out, "Installing the CYFR app's package with apt...")
	account, err := user.Current()
	if err != nil {
		return fmt.Errorf("cyfr update could not tell which account runs it (%v); nothing was replaced", err)
	}
	if err := applyWithin(appReplaceWithin, []string{stageApp(s.file, s.sum, account.Username, options...)}); err != nil {
		return fmt.Errorf("apt could not install the CYFR app's package (%w)", err)
	}
	return nil
}

// finish keeps nothing: dpkg's own transaction is the package's going back.
func (debRoad) finish(io.Writer, *staged, bool) error { return nil }

func (debRoad) closesTheBox() ([]string, []string) {
	return []string{"systemctl stop cyfr-screen"}, []string{"systemctl start cyfr-screen"}
}

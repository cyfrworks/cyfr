// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/cyfr/codex/internal/scaffold"
)

// appArmorTarget is where this machine keeps the cyfr-locus profile, which
// the host loads from there at every boot. It is the machine's, shared by
// every CYFR on it.
const appArmorTarget = "/etc/apparmor.d/cyfr-locus"

// appArmorRemoval is the command that takes the profile off this machine,
// which no CYFR command runs.
const appArmorRemoval = "sudo sh -c 'apparmor_parser -R " + appArmorTarget + " && rm " + appArmorTarget + "'"

// ensureAppArmor makes the kernel hold the project's cyfr-locus profile
// (scaffold.AppArmorProfile) before anything of the stack starts: Docker
// refuses a Locus container whose profile is not loaded. It does nothing
// where the system is not Linux, AppArmor is off, the project ships no
// profile, or /etc/apparmor.d/cyfr-locus holds the project's bytes: a
// process that is not root cannot list the loaded profiles, and that file
// is what the install loaded and what the host loads at boot. Otherwise,
// at a terminal on Ubuntu 26.04, it shows the two commands that install
// and load the profile, asks, and runs them as root through one sudo
// (mayAdminister, unlockSudo); anywhere else it refuses with the one
// command to run. again is the command the person ran, to run again.
func ensureAppArmor(ctx context.Context, out io.Writer, again string) error {
	if machine.system() != "linux" || !machine.appArmor() {
		return nil
	}
	want, err := os.ReadFile(scaffold.AppArmorProfile)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil
	case err != nil:
		return fmt.Errorf("CYFR could not read %s (%v), so nothing was started. Fix the cause, then run `%s` again", scaffold.AppArmorProfile, err, again)
	}
	if have, err := machine.appArmorProfile(); err == nil && bytes.Equal(have, want) {
		return nil
	}
	source, err := filepath.Abs(scaffold.AppArmorProfile)
	if err != nil {
		return fmt.Errorf("CYFR could not find %s (%v), so nothing was started. Fix the cause, then run `%s` again", scaffold.AppArmorProfile, err, again)
	}
	commands := []string{
		"install -m 0644 " + shellQuote([]string{source}) + " " + appArmorTarget,
		"apparmor_parser -r -W " + appArmorTarget,
	}
	if !askTerminal() || !machine.supported() {
		return fmt.Errorf("Locus runs under the AppArmor profile cyfr-locus, which this machine has not loaded, so nothing was started. Run `sudo sh -c %s`, then run `%s` again", shellQuote([]string{strings.Join(commands, " && ")}), again)
	}
	fmt.Fprintln(out, "Locus runs under the AppArmor profile cyfr-locus, and this machine has not loaded the current one.")
	if err := mayAdminister(commands, out, again); err != nil {
		return err
	}
	fmt.Fprintln(out, "These commands load it, as root:")
	for _, c := range commands {
		fmt.Fprintf(out, "  %s\n", c)
	}
	answer, err := ask(ctx, bufio.NewReader(askInput), out, "Load it? (yes/no)", "no")
	if err != nil {
		return interruption{errors.New("Interrupted; the AppArmor profile cyfr-locus was not loaded, so nothing was started.")}
	}
	if !strings.EqualFold(answer, "yes") && !strings.EqualFold(answer, "y") {
		return fmt.Errorf("The AppArmor profile cyfr-locus was not loaded, so nothing was started. Run `%s` again when you want to go on", again)
	}
	err = unlockSudo(out, again)
	if err == nil && machine.apply(commands) != nil {
		err = fmt.Errorf("Loading the AppArmor profile cyfr-locus failed, so nothing was started. Fix what is shown above, then run `%s` again", again)
	}
	machine.forget()
	return err
}

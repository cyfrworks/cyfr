// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/cyfr/codex/internal/apparmor"
	"github.com/spf13/cobra"
)

// appArmorTarget is where this machine keeps the cyfr-locus profile, which
// the host loads from there at every boot. It is the machine's, shared by
// every CYFR on it.
const appArmorTarget = apparmor.Target

// appArmorPolicies is the kernel's list of the policy it holds loaded, one
// folder per profile with the profile's name in its name file.
const appArmorPolicies = "/sys/kernel/security/apparmor/policy/profiles"

// appArmorRemoval is the command that takes the profile off this machine,
// which no CYFR command runs.
const appArmorRemoval = "sudo sh -c 'apparmor_parser -R " + appArmorTarget + " && rm " + appArmorTarget + "'"

// loadAppArmor is the one command that installs and loads the profile
// built into this cyfr: cyfr prints it, and root writes and loads it. The
// keeper names the same command when its boot finds the host's profile is
// not its release's (cyfr-locus's stage.LoadProfile).
const loadAppArmor = "cyfr apparmor-profile | sudo sh -c 'cat > " + appArmorTarget + " && apparmor_parser -r -W " + appArmorTarget + "'"

// appArmorCommands are the root commands that install and load the profile,
// which they read on their input: the bytes built into this cyfr, never a
// file a project's writer could change between the question and the write.
var appArmorCommands = []string{"cat > " + appArmorTarget, "apparmor_parser -r -W " + appArmorTarget}

// ensureAppArmor offers this machine the AppArmor profile cyfr-locus built
// into this cyfr before anything of the stack starts. Which profile is
// enforced is the keeper's to prove, at its boot, where it refuses under
// any other and names the one command; cyfr reads no copy on disk. It
// offers the profile where the kernel holds none named cyfr-locus, which
// Docker refuses a Locus container without, and, when release is set (init
// and update, which bring a release's profile), wherever the kernel holds
// one. On Ubuntu 26.04 with AppArmor on, at a terminal, it shows the two
// commands, asks, and runs them through one sudo (unlockSudo) with the
// profile as their input. Without a terminal it refuses where the kernel
// holds none, naming the one command, and otherwise says that command and
// goes on. Anywhere else, another system, a container that sees no host's
// policy, AppArmor off, it does nothing. again is the command the person
// ran, to run again.
func ensureAppArmor(ctx context.Context, out io.Writer, again string, release bool) error {
	if machine.system() != "linux" || !machine.appArmor() || !machine.supported() {
		return nil
	}
	loaded, visible := machine.appArmorLoaded()
	if !visible || (loaded && !release) {
		return nil
	}
	if !askTerminal() {
		if loaded {
			fmt.Fprintf(out, "Locus runs under the AppArmor profile cyfr-locus, which nothing here can ask to load as this cyfr has it. Where the machine's is another, the Locus services refuse to start and name the command that loads it:\n  %s\n", loadAppArmor)
			return nil
		}
		return fmt.Errorf("Locus runs under the AppArmor profile cyfr-locus, which this machine has not loaded, so nothing was started. Run `%s`, then run `%s` again", loadAppArmor, again)
	}
	if loaded {
		fmt.Fprintln(out, "Locus runs under the AppArmor profile cyfr-locus, which this cyfr carries as its release has it.")
	} else {
		fmt.Fprintln(out, "Locus runs under the AppArmor profile cyfr-locus, which this machine has not loaded.")
	}
	account, administers, err := administrator()
	if err != nil {
		return err
	}
	if !administers {
		fmt.Fprintf(out, "Your account, %s, is not in the sudo or admin group, so CYFR does not run commands as root for it. Whoever administers this machine can run this for you:\n  %s\n", account, loadAppArmor)
		return fmt.Errorf("Nothing was changed. Run `%s` again once they have", again)
	}
	fmt.Fprintln(out, "These commands load it, as root, the profile built into this cyfr as their input:")
	for _, c := range appArmorCommands {
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
	if err == nil && machine.applyInput(appArmorCommands, apparmor.Profile) != nil {
		err = fmt.Errorf("Loading the AppArmor profile cyfr-locus failed, so nothing was started. Fix what is shown above, then run `%s` again", again)
	}
	machine.forget()
	return err
}

var appArmorProfileCmd = &cobra.Command{
	Use:     "apparmor-profile",
	Short:   "Print the AppArmor profile the Locus services run under",
	GroupID: "server",
	Long: `Prints the AppArmor profile cyfr-locus built into this cyfr, the one every Locus container runs under on a host with AppArmor, for root to install and load:

  ` + loadAppArmor + `

cyfr init and update run those two steps through one sudo at a terminal on Ubuntu 26.04, and up, restore and access do where the machine has loaded none; the keeper names this command when its boot finds the host's profile is not its release's.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		_, err := cmd.OutOrStdout().Write(apparmor.Profile)
		return err
	},
}

func init() {
	rootCmd.AddCommand(appArmorProfileCmd)
}

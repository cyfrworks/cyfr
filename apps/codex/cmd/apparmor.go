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

// appArmorPolicies is the kernel's list of the policy it holds loaded, one
// folder per profile with the profile's name in its name file.
const appArmorPolicies = "/sys/kernel/security/apparmor/policy/profiles"

// appArmorEnv is the .env setting that names, to docker-compose.yml's
// security_opt, the profile the Locus services run under: cyfr's own, set
// by init and update to the profile built into cyfr.
const appArmorEnv = "CYFR_LOCUS_APPARMOR"

// loadAppArmorFormat is the one command that installs and loads the
// profile built into this cyfr, its name in place of %[1]s: cyfr prints
// the profile, and root writes and loads it. The keeper names the same
// command when its boot finds it does not run under its release's profile
// (cyfr-locus's stage.LoadProfile).
const loadAppArmorFormat = "cyfr apparmor-profile | sudo sh -c 'cat > /etc/apparmor.d/%[1]s && apparmor_parser -r -W /etc/apparmor.d/%[1]s'"

// loadAppArmor is that command for this release's profile.
var loadAppArmor = fmt.Sprintf(loadAppArmorFormat, apparmor.ProfileName)

// appArmorRemoval is the command that takes the profile named name off
// this machine.
func appArmorRemoval(name string) string {
	return "sudo sh -c 'apparmor_parser -R " + apparmor.Target(name) + " && rm " + apparmor.Target(name) + "'"
}

// appArmorCommands are the root commands that install and load the profile
// named name, which they read on their input: the bytes built into this
// cyfr, never a file a project's writer could change between the question
// and the write.
func appArmorCommands(name string) []string {
	return []string{"cat > " + apparmor.Target(name), "apparmor_parser -r -W " + apparmor.Target(name)}
}

// ensureAppArmor offers this machine the profile built into this cyfr
// (offerAppArmor) and forgets sudo's login after.
func ensureAppArmor(ctx context.Context, out io.Writer, again string) error {
	held, err := offerAppArmor(ctx, out, again)
	if held {
		machine.forget()
	}
	return err
}

// offerAppArmor offers this machine the profile built into this cyfr where
// the kernel does not hold it, by its name, which carries its content: an
// older profile is another name. On Ubuntu 26.04 with AppArmor on, at a
// terminal, it shows the two commands, asks, and runs them through one
// sudo (unlockSudo) with the profile as their input, answering whether it
// holds sudo's login, which the caller forgets. Without a terminal it
// refuses, naming the one command. Anywhere else, another system, a
// container that sees no host's policy, AppArmor off, it does nothing.
// Which profile a container runs under is the keeper's to prove at its
// boot. again is the command the person ran, to run again.
func offerAppArmor(ctx context.Context, out io.Writer, again string) (bool, error) {
	if machine.system() != "linux" || !machine.appArmor() || !machine.supported() {
		return false, nil
	}
	if loaded, visible := machine.appArmorLoaded(apparmor.ProfileName); loaded || !visible {
		return false, nil
	}
	if !askTerminal() {
		return false, fmt.Errorf("Locus runs under the AppArmor profile %s, which this machine has not loaded, so nothing was changed. Run `%s`, then run `%s` again", apparmor.ProfileName, loadAppArmor, again)
	}
	fmt.Fprintf(out, "Locus runs under the AppArmor profile %s, which this machine has not loaded.\n", apparmor.ProfileName)
	account, administers, err := administrator()
	if err != nil {
		return false, err
	}
	if !administers {
		fmt.Fprintf(out, "Your account, %s, is not in the sudo or admin group, so CYFR does not run commands as root for it. Whoever administers this machine can run this for you:\n  %s\n", account, loadAppArmor)
		return false, fmt.Errorf("Nothing was changed. Run `%s` again once they have", again)
	}
	fmt.Fprintln(out, "These commands load it, as root, the profile built into this cyfr as their input:")
	for _, c := range appArmorCommands(apparmor.ProfileName) {
		fmt.Fprintf(out, "  %s\n", c)
	}
	answer, err := ask(ctx, bufio.NewReader(askInput), out, "Load it? (yes/no)", "no")
	if err != nil {
		return false, interruption{errors.New("Interrupted; the AppArmor profile was not loaded, so nothing was changed.")}
	}
	if !strings.EqualFold(answer, "yes") && !strings.EqualFold(answer, "y") {
		return false, fmt.Errorf("The AppArmor profile was not loaded, so nothing was changed. Run `%s` again when you want to go on", again)
	}
	if err := unlockSudo(out, again); err != nil {
		return true, err
	}
	if machine.applyInput(appArmorCommands(apparmor.ProfileName), apparmor.Profile) != nil {
		return true, fmt.Errorf("Loading the AppArmor profile %s failed, so nothing was changed. Fix what is shown above, then run `%s` again", apparmor.ProfileName, again)
	}
	return true, nil
}

// retireAppArmor takes off this machine the profile named old, which an
// update has replaced and no longer runs under, through sudo's login when
// the update holds it, and says the command that does so when it cannot.
func retireAppArmor(out io.Writer, old string) {
	if old == "" || old == apparmor.ProfileName {
		return
	}
	if loaded, _ := machine.appArmorLoaded(old); !loaded {
		return
	}
	if unlockSudo(out, "") != nil || machine.apply([]string{"apparmor_parser -R " + apparmor.Target(old), "rm " + apparmor.Target(old)}) != nil {
		fmt.Fprintf(out, "This machine still holds the AppArmor profile %s, which this CYFR no longer runs under; this command removes it:\n  %s\n", old, appArmorRemoval(old))
	}
}

var appArmorProfileCmd = &cobra.Command{
	Use:     "apparmor-profile",
	Short:   "Print the AppArmor profile the Locus services run under",
	GroupID: "server",
	Long: `Prints the AppArmor profile built into this cyfr, the one every Locus container runs under on a host with AppArmor, under its name, which carries its content (` + "`cyfr-locus-`" + ` and 12 hex digits), for root to install and load:

  ` + loadAppArmor + `

cyfr init, update, up, restore and access run those two steps through one sudo at a terminal on Ubuntu 26.04 where the machine has not loaded this name; the keeper names this command when its boot finds it does not run under its release's profile.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, _ []string) error {
		_, err := cmd.OutOrStdout().Write(apparmor.Profile)
		return err
	},
}

func init() {
	rootCmd.AddCommand(appArmorProfileCmd)
}

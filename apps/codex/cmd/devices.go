// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"fmt"

	"github.com/cyfr/codex/internal/access"
)

// vmDevice is a device a person's computer of their own runs through,
// which docker-compose.yml gives the Locus services from the .env setting
// env: path, the device's own, where this machine has it, and empty where
// it does not, which the container is given /dev/null for and the keeper
// reads as no device. The value is no preference: cyfr init and every
// cyfr update write it from what the machine has, and every command that
// reaches Docker refuses any other (refuseDevices).
type vmDevice struct {
	env, path string
	// minor is the device's minor number among the misc devices (major
	// 10), the numbers the keeper reads it by (deviceHeld).
	minor uint32
}

var vmDevices = []vmDevice{
	{env: "CYFR_LOCUS_KVM", path: "/dev/kvm", minor: 232},
	{env: "CYFR_LOCUS_TUN", path: "/dev/net/tun", minor: 200},
}

// setting is the value d's setting holds on this machine.
func (d vmDevice) setting() string {
	if machine.device(d.path, d.minor) {
		return d.path
	}
	return ""
}

// deviceEdits are the device settings values, .env's as read, do not hold
// as this machine has them, each with the value it takes.
func deviceEdits(values map[string]string) map[string]string {
	set := map[string]string{}
	for _, d := range vmDevices {
		if want := d.setting(); values[d.env] != want {
			set[d.env] = want
		}
	}
	return set
}

// devicesFirstPassed is whether writing this machine's devices over
// values, .env's as read, gives the Locus services every device where
// values did not: the keeper then runs each person's programs in a
// computer of their own and retires every folder they kept before, so
// the update that does so says it before it changes anything.
func devicesFirstPassed(values map[string]string) bool {
	before, after := true, true
	for _, d := range vmDevices {
		before = before && values[d.env] == d.path
		after = after && d.setting() == d.path
	}
	return after && !before
}

// devicesSignInAgain is what that update says.
const devicesSignInAgain = "From this update on, this machine runs each person's programs in a computer of their own, and every folder their programs keep now is removed: each person's programs sign in again."

// refuseDevices refuses a .env in the working directory whose device
// setting is neither empty nor its device's own path, before anything is
// passed to Docker; command is the command the person ran, as they run it
// again (commandSaid). A .env that does not read is left to the command,
// which refuses it with its own sentence.
func refuseDevices(command string) error {
	values, err := access.ReadEnvValues(".env")
	if err != nil {
		return nil
	}
	for _, d := range vmDevices {
		if v := values[d.env]; v != "" && v != d.path {
			return fmt.Errorf("%s in .env is neither empty nor %s, and cyfr writes it from what this machine has, so nothing was changed. Run `cyfr init` here, which writes it again, then run `%s` again", d.env, d.path, command)
		}
	}
	return nil
}

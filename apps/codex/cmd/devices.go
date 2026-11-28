// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/cyfr/codex/internal/access"
)

// vmDevice is a device a person's computer of their own runs through,
// which docker-compose.yml gives the Locus services from the .env setting
// env: path, the device's own, where this machine has both devices as such
// a computer needs them, and empty where it does not, which the container
// is given /dev/null for and the keeper reads as no device. The value is no
// preference: cyfr init writes it for a project it makes, cyfr update and
// cyfr restore write it from what the machine has, and the commands that
// start the stack as .env stands refuse any other (refuseDevices).
type vmDevice struct{ env, path string }

var vmDevices = []vmDevice{
	{env: access.KVMSetting, path: "/dev/kvm"},
	{env: access.TunSetting, path: "/dev/net/tun"},
}

// machineDevices are the device settings as this machine gives them:
// each device's path where it has both (machine.devices), both empty
// where it lacks either.
func machineDevices() map[string]string {
	has := machine.devices()
	set := map[string]string{}
	for _, d := range vmDevices {
		set[d.env] = ""
		if has {
			set[d.env] = d.path
		}
	}
	return set
}

// noDevices are the device settings that give the Locus services none.
func noDevices() map[string]string {
	set := map[string]string{}
	for _, d := range vmDevices {
		set[d.env] = ""
	}
	return set
}

// passes is whether values, .env's as read, give the Locus services both
// devices: the keeper then runs each person's programs in a computer of
// their own wherever it can.
func passes(values map[string]string) bool {
	for _, d := range vmDevices {
		if values[d.env] != d.path {
			return false
		}
	}
	return true
}

// deviceEdits are the device settings values, .env's as read, do not hold
// as want gives them, each with the value it takes; an absent line reads
// as empty, as compose reads it.
func deviceEdits(values, want map[string]string) map[string]string {
	set := map[string]string{}
	for _, d := range vmDevices {
		if values[d.env] != want[d.env] {
			set[d.env] = want[d.env]
		}
	}
	return set
}

// newDevices are the device settings init gives the .env of a project it
// makes: this machine's, unless Docker holds volumes of the project's
// name, which an earlier CYFR in this folder left and a person's data
// outlives (cyfr uninstall keeps them), or cannot say whether it does:
// their kept folders are a person's, and only the update that first gives
// the devices removes them, saying so first. project is the compose
// project's name where the caller chose it, the working directory's
// otherwise.
func newDevices(ctx context.Context, project string) map[string]string {
	want := machineDevices()
	if !passes(want) {
		return want
	}
	if held, err := projectVolumes(ctx, project); err != nil || held {
		return noDevices()
	}
	return want
}

// projectVolumes is whether Docker holds volumes of the compose project, as
// compose labels them, asked through the engine's runner. A Docker not
// installed, as init may not have installed it yet, holds none.
func projectVolumes(ctx context.Context, project string) (bool, error) {
	dir, err := filepath.Abs(".")
	if err != nil {
		return false, err
	}
	if project == "" {
		project = access.ProjectName(dir)
	}
	e, err := openEngineAs(dir, project)
	if err != nil {
		return false, err
	}
	res, err := e.Docker().Run(ctx, access.Call{Args: []string{"volume", "ls", "-q", "--filter", "label=com.docker.compose.project=" + project}, Deadline: composeRunTimeout})
	switch {
	case errors.Is(err, exec.ErrNotFound):
		return false, nil
	case err != nil:
		return false, err
	case res.ExitCode != 0:
		return false, fmt.Errorf("docker volume ls exited %d", res.ExitCode)
	}
	return len(strings.Fields(string(res.Stdout))) > 0, nil
}

// What cyfr says of the devices. devicesSignInAgain is said, before
// anything changes, by the update that first gives the Locus services both
// devices, which only cyfr update does: the keeper then retires every
// folder kept before. devicesUpdateGives is said where this machine could
// run them and the command leaves them unpassed; devicesGone where an
// update or a restore takes them away, since the machine no longer has
// them, which removes nothing.
const (
	devicesSignInAgain = "This machine can run virtual machines. After this update, CYFR checks each time it starts whether it can run each person's programs in a small computer of their own, and does so where it can. The first start that does removes the folder each program keeps today, with its sign-in and whatever it saved there: each person signs their programs in again."
	devicesUpdateGives = "This machine can run each person's programs in a small computer of their own. `cyfr update` turns that on here, and says first what it removes."
	devicesGone        = "This machine no longer has what a person's own computer needs, so from this update on each person's programs run in a space of their own here. A program whose folder was made in a person's own computer does not start, and its folder cannot be reset, until the machine has it again and `cyfr update` has run."
)

// refuseDevices refuses a .env in the working directory that names, at a
// device setting, anything but empty or its device's own path on a machine
// that has both devices, before anything is passed to Docker: Docker
// refuses to start a container given a device the machine lacks, and cyfr
// hands it none. command is the command the person ran, as they run it
// again (commandSaid). A .env that does not read is left to the command,
// which refuses it with its own sentence.
func refuseDevices(command string) error {
	values, err := access.ReadEnvValues(".env")
	if err != nil {
		return nil
	}
	has := machineDevices()
	for _, d := range vmDevices {
		if v := values[d.env]; v != "" && v != has[d.env] {
			return fmt.Errorf("%s in .env is not a device this machine has for CYFR, so nothing was started. Run `cyfr update` here, which writes what this machine has, then run `%s` again", d.env, command)
		}
	}
	return nil
}

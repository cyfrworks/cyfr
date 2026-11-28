// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A snapshot's .env is the machine's it was taken on: cyfr restore gives
// each device line it assigns this machine's as its stack ran before the
// restore, the device's path only where the .env before passed both and
// this machine still has both, and never first gives them, since a
// restore asks nothing; a line the snapshot does not assign, as a release
// before them declares none, stays unassigned. Before anything stops it
// says that cyfr update turns them on where this machine could run them
// and the restore leaves them unpassed, and that programs kept in a
// person's own computer do not start where the machine no longer has
// them.
func TestRestoreKeepsTheDevicesThisMachinesStackRanWith(t *testing.T) {
	both := deviceLines("/dev/kvm", "/dev/net/tun")
	for name, c := range map[string]struct {
		snapshot, before string
		has              bool
		restored         string
		says             string
	}{
		"ran with them, has them":           {both, both, true, both, ""},
		"ran without them, has them":        {both, "", true, deviceLines("", ""), devicesUpdateGives},
		"ran with them, has them no longer": {both, both, false, deviceLines("", ""), devicesGone},
		"ran without them, has none":        {both, "", false, deviceLines("", ""), ""},
		"a snapshot with no device line":    {"", both, true, "", devicesUpdateGives},
		"a snapshot of a machine with none": {deviceLines("", ""), both, true, both, ""},
	} {
		t.Run(name, func(t *testing.T) {
			r := newRestoreScenario(t, shippedCompose(t), nil, nil)
			devicesHere(t, c.has)
			if err := os.WriteFile(filepath.Join(r.dir, ".env"), append(r.env, c.snapshot...), 0o600); err != nil {
				t.Fatal(err)
			}
			r.edit(".env", string(r.live)+c.before)
			out, err := r.restore(true)
			if err != nil {
				t.Fatalf("restore: %v\n%s", err, out)
			}
			if got, want := read(t, filepath.Join(r.project, ".env")), string(r.env)+c.restored; got != want {
				t.Errorf("the restored .env is %q, want %q", got, want)
			}
			lines := strings.SplitN(out, "\n", 3)
			said := ""
			if strings.Contains(out, devicesUpdateGives) || strings.Contains(out, devicesGone) {
				said = lines[1]
			}
			if !strings.HasPrefix(lines[0], "Restoring the snapshot of release ") || said != c.says {
				t.Errorf("the restore said %q after its first line, want %q:\n%s", said, c.says, out)
			}
		})
	}
}

// A restore refused after it put the snapshot's .env, this machine's
// devices in it, in place puts .env back as it was, devices and all.
func TestARefusedRestorePutsTheDevicesBackAsTheyWere(t *testing.T) {
	r := newRestoreScenario(t, shippedCompose(t), nil, nil)
	devicesHere(t, true)
	if err := os.WriteFile(filepath.Join(r.dir, ".env"), append(r.env, deviceLines("/dev/kvm", "/dev/net/tun")...), 0o600); err != nil {
		t.Fatal(err)
	}
	r.setService("volumes_from", []string{"service:other"})
	before := string(r.live) + deviceLines("", "")
	r.edit(".env", before)
	compose := read(t, filepath.Join(r.project, "docker-compose.yml"))
	if out, err := r.restore(true); err == nil || !strings.Contains(err.Error(), "volumes_from") {
		t.Fatalf("restore answered %v, want its refusal of the configuration\n%s", err, out)
	}
	r.configAsBefore(compose, before)
}

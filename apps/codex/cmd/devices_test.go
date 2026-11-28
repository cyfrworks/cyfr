// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/access"
)

const (
	kvmEnv = "CYFR_LOCUS_KVM"
	tunEnv = "CYFR_LOCUS_TUN"
)

// devicesHere stands in for a machine that has the devices at paths, each
// asked for by its own misc minor, and no other.
func devicesHere(t *testing.T, paths ...string) {
	t.Helper()
	minors := map[string]uint32{"/dev/kvm": 232, "/dev/net/tun": 200}
	saved := machine.device
	t.Cleanup(func() { machine.device = saved })
	machine.device = func(path string, minor uint32) bool {
		return slices.Contains(paths, path) && minors[path] == minor
	}
}

// deviceLines is .env's device settings as values give them, unset or
// empty, or a path: kvm, then tun.
func deviceLines(kvm, tun string) string {
	return kvmEnv + "=" + kvm + "\n" + tunEnv + "=" + tun + "\n"
}

// deviceMachines are machines with both devices, with the tun device
// alone, as a Linux host without KVM, and with neither, as Docker
// Desktop: the settings each writes, and their opposites, which another
// machine's .env would hold.
var deviceMachines = map[string]struct {
	has                []string
	kvm, tun           string
	otherKVM, otherTUN string
}{
	"both":      {[]string{"/dev/kvm", "/dev/net/tun"}, "/dev/kvm", "/dev/net/tun", "", ""},
	"tun alone": {[]string{"/dev/net/tun"}, "", "/dev/net/tun", "/dev/kvm", ""},
	"none":      {nil, "", "", "/dev/kvm", "/dev/net/tun"},
}

// devicesAre fails unless .env holds kvm and tun as its device settings.
func devicesAre(t *testing.T, kvm, tun string) {
	t.Helper()
	values, err := access.ReadEnvValues(".env")
	if err != nil {
		t.Fatal(err)
	}
	if values[kvmEnv] != kvm || values[tunEnv] != tun {
		t.Errorf(".env's devices are %s=%q and %s=%q, want %q and %q", kvmEnv, values[kvmEnv], tunEnv, values[tunEnv], kvm, tun)
	}
}

// init writes each device the machine has as its own path and each it
// lacks as empty, into a new .env and over what an existing one held.
func TestInitWritesTheDevicesThisMachineHas(t *testing.T) {
	for name, m := range deviceMachines {
		t.Run(name, func(t *testing.T) {
			devicesHere(t, m.has...)
			newInitProject(t)
			useFakeEngine(t)
			var out bytes.Buffer
			if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
				t.Fatalf("init: %v\n%s", err, out.String())
			}
			devicesAre(t, m.kvm, m.tun)

			if err := os.WriteFile(".env", []byte("CYFR_ACCESS=local\nCYFR_PORT=4000\n"+deviceLines(m.otherKVM, m.otherTUN)), 0o600); err != nil {
				t.Fatal(err)
			}
			out.Reset()
			if err := runInit(context.Background(), initOptions{noPull: true}, &out, &out); err != nil {
				t.Fatalf("init on an existing .env: %v\n%s", err, out.String())
			}
			devicesAre(t, m.kvm, m.tun)
		})
	}
}

// cyfr update writes them so too, at the switch and on a home on its
// release already.
func TestUpdateWritesTheDevicesThisMachineHas(t *testing.T) {
	for name, m := range deviceMachines {
		for release, compose := range map[string]func(*testing.T) []byte{
			"switch":         shippedCompose,
			"on its release": func(t *testing.T) []byte { return switched(shippedCompose(t)) },
		} {
			t.Run(name+", "+release, func(t *testing.T) {
				devicesHere(t, m.has...)
				s := newUpdateScenario(t, compose(t), nil)
				s.edit(".env", scenarioEnv+deviceLines(m.otherKVM, m.otherTUN))
				if out, err := s.run(context.Background()); err != nil {
					t.Fatalf("update: %v\n%s", err, out)
				}
				devicesAre(t, m.kvm, m.tun)
			})
		}
	}
}

// The update that first gives the Locus services both devices, where
// .env named not both of them and the machine has both, says before it
// changes anything that each person's programs sign in again: in the
// change it shows before its question, so declined it has changed
// nothing, in the change the CYFR app's page shows, and on a home on its
// release, before its start. No other update says it.
func TestUpdateSaysProgramsSignInAgainWhenItFirstPassesTheDevices(t *testing.T) {
	for name, c := range map[string]struct {
		has  []string
		env  string
		says bool
	}{
		"none named, both here": {[]string{"/dev/kvm", "/dev/net/tun"}, "", true},
		"tun named, both here":  {[]string{"/dev/kvm", "/dev/net/tun"}, deviceLines("", "/dev/net/tun"), true},
		"both named, both here": {[]string{"/dev/kvm", "/dev/net/tun"}, deviceLines("/dev/kvm", "/dev/net/tun"), false},
		"none named, tun here":  {[]string{"/dev/net/tun"}, "", false},
		"none named, none here": {nil, "", false},
		"both named, none here": {nil, deviceLines("/dev/kvm", "/dev/net/tun"), false},
	} {
		t.Run(name, func(t *testing.T) {
			devicesHere(t, c.has...)
			said := func(out string) bool { return strings.Contains(out, devicesSignInAgain+"\n") }

			s := newUpdateScenario(t, shippedCompose(t), nil)
			s.edit(".env", scenarioEnv+c.env)
			askWith(t, true, strings.NewReader("no\n"))
			var out bytes.Buffer
			if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{}); err != nil || !strings.HasSuffix(out.String(), "Update this CYFR? (yes/no) [no]: Nothing changed. Run cyfr update again when you want this release.\n") {
				t.Fatalf("a declined update answered %v:\n%s", err, out.String())
			}
			if said(out.String()) != c.says {
				t.Errorf("the offer says programs sign in again: %t, want %t:\n%s", said(out.String()), c.says, out.String())
			}
			s.onlyReadTheSchema()
			if got := read(t, filepath.Join(s.project, ".env")); got != scenarioEnv+c.env {
				t.Errorf("a declined update left .env as %q", got)
			}

			out.Reset()
			if err := runHomeUpdate(context.Background(), &out, &out, updateOptions{offer: true}); err != nil {
				t.Fatalf("the app's offer answered %v:\n%s", err, out.String())
			}
			lines := strings.Split(strings.TrimSpace(out.String()), "\n")
			var shown shownChange
			if err := json.Unmarshal([]byte(lines[len(lines)-1]), &shown); err != nil {
				t.Fatalf("the app's offer is %q (%v)", out.String(), err)
			}
			if said(shown.Change) != c.says {
				t.Errorf("the app's offer says programs sign in again: %t, want %t:\n%s", said(shown.Change), c.says, shown.Change)
			}

			s = newUpdateScenario(t, switched(shippedCompose(t)), nil)
			s.edit(".env", scenarioEnv+c.env)
			got, err := s.run(context.Background())
			if err != nil {
				t.Fatalf("an update on its release answered %v:\n%s", err, got)
			}
			first := "This CYFR is on release 0.9.0 already, so there is nothing to switch; cyfr update starts it and waits for every service of its stack.\n"
			want := first + "Starting release 0.9.0...\n"
			if c.says {
				want = first + devicesSignInAgain + "\nStarting release 0.9.0...\n"
			}
			if !strings.Contains(got, want) {
				t.Errorf("an update on its release does not say %q before its start:\n%s", want, got)
			}
		})
	}
}

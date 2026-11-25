// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"encoding/json"
	"strings"
	"testing"
)

const bootID = "27da53b6-f0ac-42cb-aa29-20cb9b3c5631"

func TestNewHelloReadsTheBootIdentityFile(t *testing.T) {
	h, err := NewHello(bootID + "\n")
	if err != nil {
		t.Fatal(err)
	}
	if h != (Hello{V: HelloVersion, Type: HelloType, BootID: bootID}) {
		t.Fatalf("hello %+v", h)
	}
}

func TestNewHelloRefusesWhatIsNotAUUID(t *testing.T) {
	for _, raw := range []string{"", "\n", "not-a-uuid", strings.ToUpper(bootID), bootID + "0"} {
		if _, err := NewHello(raw); err == nil {
			t.Errorf("NewHello(%q) was accepted", raw)
		}
	}
}

func TestParseHelloRoundTripsNewHello(t *testing.T) {
	h, err := NewHello(bootID)
	if err != nil {
		t.Fatal(err)
	}
	line, err := json.Marshal(h)
	if err != nil {
		t.Fatal(err)
	}
	got, err := ParseHello(append(line, '\n'))
	if err != nil {
		t.Fatal(err)
	}
	if got != h {
		t.Fatalf("got %+v, want %+v", got, h)
	}
}

func TestParseHelloRefusesAnythingButAHelloOfThisVersion(t *testing.T) {
	for name, line := range map[string]string{
		"another version": `{"v":2,"type":"hello","boot_id":"` + bootID + `"}`,
		"no version":      `{"type":"hello","boot_id":"` + bootID + `"}`,
		"another type":    `{"v":1,"type":"spawned","boot_id":"` + bootID + `"}`,
		"a bad boot id":   `{"v":1,"type":"hello","boot_id":"boot"}`,
		"no boot id":      `{"v":1,"type":"hello"}`,
		"not JSON":        `hello`,
	} {
		if _, err := ParseHello([]byte(line + "\n")); err == nil {
			t.Errorf("%s: %s was accepted", name, line)
		}
	}
}

func TestBootArgsCarryV1sArguments(t *testing.T) {
	args := strings.Fields(BootArgs())
	for _, want := range []string{"page_reporting.page_reporting_order=0", "i8042.noaux", "i8042.nomux",
		"i8042.nopnp", "i8042.dumbkbd", "lsm=landlock,yama", "reboot=k", "panic=-1"} {
		if !contains(args, want) {
			t.Errorf("BootArgs() %q lacks %s", BootArgs(), want)
		}
	}
	if last := args[len(args)-1]; last != "init="+GuestAgent || GuestAgent != "/usr/local/bin/cyfr-guest" {
		t.Errorf("BootArgs() ends with %q, not init=/usr/local/bin/cyfr-guest", last)
	}
}

func TestBootArgsWithoutOrderZeroLeaveTheKernelsOrder(t *testing.T) {
	args := bootArgs(false)
	if strings.Contains(args, "page_reporting") {
		t.Fatalf("bootArgs(false) %q names page reporting", args)
	}
	if want := strings.Replace(BootArgs(), " page_reporting.page_reporting_order=0", "", 1); args != want {
		t.Fatalf("bootArgs(false) is %q, not BootArgs() without the order: %q", args, want)
	}
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

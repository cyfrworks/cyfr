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
	for _, console := range []bool{false, true} {
		args := strings.Fields(BootArgs(console))
		for _, want := range []string{"page_reporting.page_reporting_order=0", "i8042.noaux", "i8042.nomux",
			"i8042.nopnp", "i8042.dumbkbd", "lsm=landlock,yama", "reboot=k", "panic=-1"} {
			if !contains(args, want) {
				t.Errorf("BootArgs(%v) %q lacks %s", console, BootArgs(console), want)
			}
		}
		if last := args[len(args)-1]; last != "init="+GuestAgent || GuestAgent != "/usr/local/bin/cyfr-guest" {
			t.Errorf("BootArgs(%v) ends with %q, not init=/usr/local/bin/cyfr-guest", console, last)
		}
	}
}

// A machine that serves has no serial console: its guest is given none,
// and only guest-check's boots with one.
func TestOnlyAMachineWithAConsoleBootsWithOne(t *testing.T) {
	for _, arg := range strings.Fields(BootArgs(false)) {
		if strings.HasPrefix(arg, "console=") {
			t.Fatalf("BootArgs(false) %q names a console", BootArgs(false))
		}
	}
	if !contains(strings.Fields(BootArgs(true)), "console=ttyS0") {
		t.Fatalf("BootArgs(true) %q has no serial console", BootArgs(true))
	}
}

func TestBootArgsWithoutOrderZeroLeaveTheKernelsOrder(t *testing.T) {
	args := bootArgs(false, true)
	if strings.Contains(args, "page_reporting") {
		t.Fatalf("bootArgs(false, true) %q names page reporting", args)
	}
	if want := strings.Replace(BootArgs(true), " page_reporting.page_reporting_order=0", "", 1); args != want {
		t.Fatalf("bootArgs(false, true) is %q, not BootArgs(true) without the order: %q", args, want)
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

// A hello refused carries the guest's line in its error quoted and cut, so
// the keeper's log line that names the error holds no byte of the guest's
// raw (logx.Untrusted): here a carriage return, which JSON allows between
// members, before a forged line, and a megabyte beside it.
func TestARefusedHelloCarriesTheGuestsLineQuoted(t *testing.T) {
	line := `{"v":1,"type":"hullo",` + "\r" + `"x":"[cyfr-locus] error: forged","pad":"` + strings.Repeat("x", 1<<20) + `"}`
	_, err := ParseHello([]byte(line))
	if err == nil || strings.ContainsAny(err.Error(), "\r\n") || len(err.Error()) > 300 {
		t.Fatalf("the refusal is %d bytes: %.120q", len(err.Error()), err)
	}
}

// A hello that does not decode, its number past every integer, is refused
// in a short error, the decoder's words, which quote the guest's literal,
// quoted and cut (logx.Untrusted).
func TestAnUndecodableHelloCarriesNoLongLiteral(t *testing.T) {
	line := `{"v":1` + strings.Repeat("9", 1<<20) + `,"type":"hello"}`
	_, err := ParseHello([]byte(line))
	if err == nil || len(err.Error()) > 300 {
		t.Fatalf("the refusal is %d bytes: %.120q", len(err.Error()), err)
	}
}

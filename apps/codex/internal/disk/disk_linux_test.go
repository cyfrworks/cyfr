// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package disk

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDetectReadsThisMachine runs the real detector over the running system,
// for a temporary directory and for this package's directory. The machine's
// answer is not known here, only that each is a State.
func TestDetectReadsThisMachine(t *testing.T) {
	for _, dir := range []string{t.TempDir(), "."} {
		r := Detect(dir)
		for _, s := range []State{r.Root, r.Data} {
			if s != Encrypted && s != Unencrypted && s != Unknown {
				t.Fatalf("Detect(%s) = %+v, a state outside the three", dir, r)
			}
		}
		t.Logf("this machine, %s: %q", dir, r.Capabilities())
	}
}

// TestStatDeviceReadsBlockNodes checks statDevice's decoding against every
// block device node sysfs and /dev agree on, and that a directory reports its
// filesystem's number rather than its own st_rdev of 0:0.
func TestStatDeviceReadsBlockNodes(t *testing.T) {
	major, minor, err := statDevice(t.TempDir())
	if err != nil || major == 0 && minor == 0 {
		t.Errorf("statDevice(dir) = %d:%d, %v; want its filesystem's number", major, minor, err)
	}

	entries, err := os.ReadDir("/sys/dev/block")
	if err != nil {
		t.Skipf("no sysfs: %v", err)
	}
	checked := 0
	for _, e := range entries {
		uevent, err := os.ReadFile(filepath.Join("/sys/dev/block", e.Name(), "uevent"))
		if err != nil {
			continue
		}
		var name string
		for line := range strings.Lines(string(uevent)) {
			if v, ok := strings.CutPrefix(strings.TrimSpace(line), "DEVNAME="); ok {
				name = v
			}
		}
		info, err := os.Stat("/dev/" + name)
		if name == "" || err != nil || info.Mode()&fs.ModeDevice == 0 || info.Mode()&fs.ModeCharDevice != 0 {
			continue
		}
		major, minor, err := statDevice("/dev/" + name)
		if got := fmt.Sprintf("%d:%d", major, minor); err != nil || got != e.Name() {
			t.Errorf("statDevice(/dev/%s) = %s, %v; want %s", name, got, err, e.Name())
		}
		checked++
	}
	if checked == 0 {
		t.Skip("no block device nodes under /dev")
	}
	t.Logf("checked %d block device nodes", checked)
}

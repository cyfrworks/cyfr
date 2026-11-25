// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"encoding/json"
	"os"
	"os/exec"
	"runtime"
	"testing"

	"golang.org/x/sys/unix"
)

// The space's first process reads its spec and the init reads it again
// after a collection: no file of the first read closes the descriptor.
func TestTheSpacesSpecIsReadAgainAfterACollection(t *testing.T) {
	if os.Getenv("CYFR_STAGE_SPEC_READER") == "1" {
		if _, err := readSpaceSpec(); err != nil {
			t.Fatal(err)
		}
		runtime.GC()
		runtime.GC()
		if _, err := readSpaceSpec(); err != nil {
			t.Fatal("the second read:", err)
		}
		return
	}
	fd, err := unix.MemfdCreate("spec", 0)
	if err != nil {
		t.Fatal(err)
	}
	spec := os.NewFile(uintptr(fd), "spec")
	defer spec.Close()
	if err := json.NewEncoder(spec).Encode(validSpec()); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestTheSpacesSpecIsReadAgainAfterACollection$", "-test.count=1")
	cmd.ExtraFiles = []*os.File{spec}
	cmd.Env = append(os.Environ(), "CYFR_STAGE_SPEC_READER=1")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%s (%v)", out, err)
	}
}

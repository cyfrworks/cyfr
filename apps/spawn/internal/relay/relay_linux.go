// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package relay

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"os"

	"golang.org/x/sys/unix"

	"github.com/cyfr/spawn/internal/logx"
)

// File descriptors of a relay process; 0-2 are /dev/null, /dev/null and
// the spawner's stderr. ControlFD is present only when the spec says so.
const (
	SpecFD    = 3
	StdinFD   = 4
	StdoutFD  = 5
	StderrFD  = 6
	ControlFD = 7
)

// Main runs `cyfr-spawn relay`.
func Main() int {
	data, err := io.ReadAll(io.LimitReader(os.NewFile(SpecFD, "spec"), 4096))
	if err != nil {
		return failf("spec: %v", err)
	}
	var spec Spec
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&spec); err != nil {
		return failf("spec: undecodable")
	}
	files := make([]*os.File, 0, 3)
	for _, fd := range []int{StdinFD, StdoutFD, StderrFD} {
		// Non-blocking descriptors join the runtime poller, so closing one
		// interrupts a pending read or write.
		if err := unix.SetNonblock(fd, true); err != nil {
			return failf("fd %d: %v", fd, err)
		}
		files = append(files, os.NewFile(uintptr(fd), "backend"))
	}
	var control Control
	if spec.Control {
		// FileConn duplicates the descriptor into a polled socket, so the
		// original is closed once it is wrapped.
		f := os.NewFile(ControlFD, "control")
		conn, err := net.FileConn(f)
		_ = f.Close()
		if err != nil {
			return failf("fd %d: %v", ControlFD, err)
		}
		sock, ok := conn.(*net.UnixConn)
		if !ok {
			_ = conn.Close()
			return failf("fd %d is not a unix socket", ControlFD)
		}
		control = sock
	}
	if err := Run(spec, files[0], files[1], files[2], control, DialTimeout); err != nil {
		return failf("%v", err)
	}
	return 0
}

func failf(format string, args ...any) int {
	logx.New("cyfr-spawn").Error("relay: "+format, args...)
	return 1
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package relay

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"

	"golang.org/x/sys/unix"

	"github.com/cyfr/keeper/internal/logx"
)

// File descriptors of a relay process; 0-2 are /dev/null, /dev/null and
// the keeper's stderr. ControlFD and RelayFD are present only when the
// spec says so; a relay without a control channel has fd 7 closed.
const (
	SpecFD    = 3
	StdinFD   = 4
	StdoutFD  = 5
	StderrFD  = 6
	ControlFD = 7
	RelayFD   = 8
)

// Main runs `cyfr-keeper relay`.
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
	var control, relay Control
	if spec.Control {
		if control, err = socketAt(ControlFD); err != nil {
			return failf("%v", err)
		}
	}
	if spec.Relay {
		if relay, err = socketAt(RelayFD); err != nil {
			return failf("%v", err)
		}
	}
	if err := Run(spec, files[0], files[1], files[2], control, relay, DialTimeout); err != nil {
		return failf("%v", err)
	}
	return 0
}

// socketAt wraps the unix socket on fd. FileConn duplicates the descriptor
// into a polled socket, so the original is closed once it is wrapped.
func socketAt(fd int) (Control, error) {
	f := os.NewFile(uintptr(fd), "socket")
	conn, err := net.FileConn(f)
	_ = f.Close()
	if err != nil {
		return nil, fmt.Errorf("fd %d: %w", fd, err)
	}
	sock, ok := conn.(*net.UnixConn)
	if !ok {
		_ = conn.Close()
		return nil, fmt.Errorf("fd %d is not a unix socket", fd)
	}
	return sock, nil
}

func failf(format string, args ...any) int {
	logx.New("cyfr-keeper").Error("relay: "+format, args...)
	return 1
}

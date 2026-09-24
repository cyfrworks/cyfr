// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command residue-canary plants and looks for what a process can leave
// behind outside its processes, for the image tests of cyfr-keeper's pooled
// uids (tests/bridge-image/residue.test.mjs, tests/builder-image). It uses
// only the standard library, so it builds as one file:
//
//	CGO_ENABLED=0 go build -o canary residue-canary.go
//
//	canary plant <tag> <path>...   write <tag> to each path (a path ending in
//	                               / becomes a directory tree its owner made
//	                               unwritable) and create a System V shared
//	                               memory segment, semaphore set and message
//	                               queue and a POSIX message queue keyed by
//	                               <tag>
//	canary probe <tag> <path>...   report what of those can be found
//
// Each prints one JSON object: for every path and IPC kind, "ok" or the
// errno name the kernel answered with (plant), or "absent", "denied" or
// "present" (probe).
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

const ipcCreat = 0o1000

func main() {
	if len(os.Args) < 3 || (os.Args[1] != "plant" && os.Args[1] != "probe") {
		fmt.Fprintln(os.Stderr, "usage: canary plant|probe <tag> <path>...")
		os.Exit(64)
	}
	tag, paths := os.Args[2], os.Args[3:]
	key := ipcKey(tag)
	report := map[string]any{"uid": os.Getuid()}
	files := map[string]string{}
	if os.Args[1] == "plant" {
		for _, p := range paths {
			files[p] = result(plantPath(p, tag))
		}
		report["shm"] = result(sysvGet(syscall.SYS_SHMGET, key, 4096, ipcCreat|0o600))
		report["sem"] = result(sysvGet(syscall.SYS_SEMGET, key, 1, ipcCreat|0o600))
		report["msg"] = result(sysvGet(syscall.SYS_MSGGET, key, ipcCreat|0o600, 0))
		report["mqueue"] = result(mqOpen(tag, syscall.O_CREAT|syscall.O_RDWR))
	} else {
		for _, p := range paths {
			files[p] = presence(probePath(p, tag))
		}
		report["shm"] = presence(sysvGet(syscall.SYS_SHMGET, key, 0, 0))
		report["sem"] = presence(sysvGet(syscall.SYS_SEMGET, key, 0, 0))
		report["msg"] = presence(sysvGet(syscall.SYS_MSGGET, key, 0, 0))
		report["mqueue"] = presence(mqOpen(tag, syscall.O_RDONLY))
	}
	report["files"] = files
	_ = json.NewEncoder(os.Stdout).Encode(report)
}

// ipcKey derives a non-zero System V key from the tag.
func ipcKey(tag string) uintptr {
	h := fnv.New32a()
	h.Write([]byte(tag))
	return uintptr(h.Sum32()&0x7fffffff | 1)
}

func plantPath(p, tag string) error {
	if !strings.HasSuffix(p, "/") {
		return os.WriteFile(p, []byte(tag), 0o600)
	}
	inner := filepath.Join(p, "sealed")
	if err := os.MkdirAll(inner, 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(inner, "canary"), []byte(tag), 0o600); err != nil {
		return err
	}
	if err := os.Chmod(inner, 0o500); err != nil {
		return err
	}
	return os.Chmod(p, 0o500)
}

func probePath(p, tag string) error {
	if strings.HasSuffix(p, "/") {
		p = filepath.Join(p, "sealed", "canary")
	}
	data, err := os.ReadFile(p)
	if err == nil && string(data) != tag {
		return fmt.Errorf("unexpected content")
	}
	return err
}

func sysvGet(call, key, a, b uintptr) error {
	if _, _, errno := syscall.Syscall(call, key, a, b); errno != 0 {
		return errno
	}
	return nil
}

func mqOpen(tag string, flags int) error {
	name, err := syscall.BytePtrFromString(tag)
	if err != nil {
		return err
	}
	fd, _, errno := syscall.Syscall6(syscall.SYS_MQ_OPEN, uintptr(unsafe.Pointer(name)), uintptr(flags), 0o600, 0, 0, 0)
	if errno != 0 {
		return errno
	}
	return syscall.Close(int(fd))
}

func result(err error) string {
	var errno syscall.Errno
	switch {
	case err == nil:
		return "ok"
	case errors.As(err, &errno):
		return errnoName(errno)
	default:
		return err.Error()
	}
}

func presence(err error) string {
	switch {
	case err == nil:
		return "present"
	case errors.Is(err, syscall.ENOENT):
		return "absent"
	case errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM):
		return "denied"
	default:
		return result(err)
	}
}

func errnoName(errno syscall.Errno) string {
	for name, value := range map[string]syscall.Errno{
		"EACCES": syscall.EACCES, "EEXIST": syscall.EEXIST, "ENOENT": syscall.ENOENT, "ENOSPC": syscall.ENOSPC,
		"ENOSYS": syscall.ENOSYS, "ENOTDIR": syscall.ENOTDIR, "EPERM": syscall.EPERM, "EROFS": syscall.EROFS,
	} {
		if errno == value {
			return name
		}
	}
	return errno.Error()
}

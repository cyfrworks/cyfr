// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"

	"github.com/cyfr/codex/internal/access"
)

// stackReadCall reports whether args are a snapshot's read through the
// stack (stackReadArgs).
func stackReadCall(args []string) bool {
	i := slices.Index(args, "--entrypoint")
	return len(args) > 0 && args[0] == "run" && i >= 0 && i+1 < len(args) && args[i+1] == "tar"
}

// standInStackRead answers a snapshot's read through the stack as the
// container would, logged as the fake docker logs a call: the archive
// tar.out holds when the scenario wrote one (the storage closed to this
// account), else the archive of the call's members, each read through the
// binds the call mounts as the container sees them (standInTar). tar.exit
// is its exit status when the scenario sets one.
func standInStackRead(c access.Call) (access.Result, error) {
	d := os.Getenv("FAKE_DOCKER_DIR")
	f, err := os.OpenFile(filepath.Join(d, "log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return access.Result{}, err
	}
	fmt.Fprintln(f, strings.Join(c.Args, " "))
	f.Close()
	if raw, err := os.ReadFile(filepath.Join(d, "tar.exit")); err == nil {
		var status int
		fmt.Sscan(string(raw), &status)
		return access.Result{ExitCode: status, Stderr: []byte("tar: the scenario's failure\n")}, nil
	}
	if canned, err := os.Open(filepath.Join(d, "tar.out")); err == nil {
		defer canned.Close()
		_, err := io.Copy(c.Stdout, canned)
		return access.Result{}, err
	}
	binds, dir, members, missingOK, err := parseStackRead(c.Args)
	if err != nil {
		return access.Result{ExitCode: 2, Stderr: []byte(err.Error())}, nil
	}
	if err := standInTar(c.Stdout, binds, dir, members, missingOK); err != nil {
		return access.Result{ExitCode: 2, Stderr: []byte(err.Error())}, nil
	}
	return access.Result{}, nil
}

// parseStackRead reads stackReadArgs back: the binds mounted, tar's
// directory, its members and whether a member may be absent.
func parseStackRead(args []string) (binds []composeMount, dir string, members []string, missingOK bool, err error) {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--mount":
			fields, err := csv.NewReader(strings.NewReader(args[i+1])).Read()
			if err != nil {
				return nil, "", nil, false, err
			}
			var b composeMount
			for _, field := range fields {
				key, value, _ := strings.Cut(field, "=")
				switch key {
				case "type":
					b.Type = value
				case "source":
					b.Source = value
				case "target":
					b.Target = value
				}
			}
			binds = append(binds, b)
			i++
		case "--ignore-failed-read":
			missingOK = true
		case "-C":
			dir = args[i+1]
			i++
		case "-cf":
			return binds, dir, args[i+2:], missingOK, nil
		}
	}
	return nil, "", nil, false, errors.New("the stack read names no archive")
}

// standInTar writes to w the archive tar writes of members under the
// container directory dir, as the container sees them through binds: each
// container path read through the bind with the longest target holding
// it, a directory's entries those of its host directory and the binds
// mounted directly in it, links archived as links.
func standInTar(w io.Writer, binds []composeMount, dir string, members []string, missingOK bool) error {
	tw := tar.NewWriter(w)
	host := func(p string) (string, bool) { return mountedHost(binds, p) }
	var add func(p, name string) error
	add = func(p, name string) error {
		h, ok := host(p)
		if !ok {
			return fmt.Errorf("tar: %s: no bind holds it", p)
		}
		info, err := os.Lstat(h)
		if err != nil {
			return err
		}
		link := ""
		if info.Mode()&fs.ModeSymlink != 0 {
			if link, err = os.Readlink(h); err != nil {
				return err
			}
		}
		hdr, err := tar.FileInfoHeader(info, link)
		if err != nil {
			return err
		}
		hdr.Name = name
		if info.IsDir() {
			hdr.Name += "/"
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		switch {
		case info.Mode().IsRegular():
			f, err := os.Open(h)
			if err != nil {
				return err
			}
			_, err = io.Copy(tw, f)
			f.Close()
			return err
		case !info.IsDir():
			return nil
		}
		entries, err := os.ReadDir(h)
		if err != nil {
			return err
		}
		var children []string
		for _, e := range entries {
			children = append(children, e.Name())
		}
		for _, b := range binds {
			if t := path.Clean(b.Target); path.Dir(t) == p && !slices.Contains(children, path.Base(t)) {
				children = append(children, path.Base(t))
			}
		}
		slices.Sort(children)
		for _, child := range children {
			if err := add(path.Join(p, child), name+"/"+child); err != nil {
				return err
			}
		}
		return nil
	}
	for _, m := range members {
		p := path.Join(dir, m)
		if _, ok := host(p); ok && missingOK {
			if h, _ := host(p); func() bool { _, err := os.Lstat(h); return errors.Is(err, fs.ErrNotExist) }() {
				continue
			}
		}
		if err := add(p, m); err != nil {
			return err
		}
	}
	return tw.Close()
}

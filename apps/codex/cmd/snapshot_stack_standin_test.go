// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"bytes"
	"context"
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

// stackReadCall reports whether args are a read through the stack
// (stackRunArgs).
func stackReadCall(args []string) bool {
	return len(args) > 0 && args[0] == "run" && slices.Contains(args, "--entrypoint") && slices.ContainsFunc(args, func(a string) bool { return strings.HasPrefix(a, "cyfr-snapshot-read-") })
}

// standInAsRoot, when a test sets it, gives the stand-in a root's reading
// of the storage for one read (closeStorage), and answers what takes it
// back.
var standInAsRoot func() (restore func())

// standInStackRead answers a read through the stack as its container
// would, from the scenario's binds, logged as the fake docker logs a call:
// realpath resolves in the container's view, find lists it as its
// -printf writes, and tar archives it. The storage's archive (tar -T -)
// is the scenario's tar.out when it wrote one, fails with tar.exit, and
// streams nothing until the call is ended while tar.stall exists.
func standInStackRead(ctx context.Context, c access.Call) (access.Result, error) {
	d := os.Getenv("FAKE_DOCKER_DIR")
	f, err := os.OpenFile(filepath.Join(d, "log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return access.Result{}, err
	}
	fmt.Fprintln(f, strings.Join(c.Args, " "))
	f.Close()
	binds, program, args := parseStackRun(c.Args)
	storage := program == "tar" && slices.Contains(args, "-T")
	if storage {
		if raw, err := os.ReadFile(filepath.Join(d, "tar.exit")); err == nil {
			var status int
			fmt.Sscan(string(raw), &status)
			return access.Result{ExitCode: status, Stderr: []byte("tar: the scenario's failure\n")}, nil
		}
		if _, err := os.Stat(filepath.Join(d, "tar.stall")); err == nil {
			<-ctx.Done()
			return access.Result{ExitCode: 137}, nil
		}
		if canned, err := os.Open(filepath.Join(d, "tar.out")); err == nil {
			defer canned.Close()
			_, err := io.Copy(c.Stdout, canned)
			return access.Result{}, err
		}
	}
	if standInAsRoot != nil {
		defer standInAsRoot()()
	}
	v := containerView{binds: binds}
	var stdin []byte
	if c.Stdin != nil {
		stdin, _ = io.ReadAll(c.Stdin)
	}
	switch program {
	case "realpath":
		real, err := v.realpath(args[len(args)-1], 0)
		if err != nil {
			return access.Result{ExitCode: 1, Stderr: []byte(err.Error())}, nil
		}
		fmt.Fprintln(c.Stdout, real)
	case "find":
		err = v.find(c.Stdout, args)
	case "tar":
		err = v.tar(c.Stdout, args, stdin)
	default:
		err = fmt.Errorf("the stand-in runs no %s", program)
	}
	if err != nil {
		return access.Result{ExitCode: 2, Stderr: []byte(err.Error())}, nil
	}
	return access.Result{}, nil
}

// parseStackRun reads stackRunArgs back: the binds mounted, the program
// and its arguments.
func parseStackRun(args []string) (binds []composeMount, program string, rest []string) {
	i := slices.Index(args, "--entrypoint")
	program = args[i+1]
	i += 2
	for ; i < len(args) && args[i] == "--mount"; i += 2 {
		fields, _ := csv.NewReader(strings.NewReader(args[i+1])).Read()
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
		if b.Type == "bind" {
			binds = append(binds, b)
		}
	}
	return binds, program, args[i+1:]
}

// containerView is the filesystem a container sees through binds: each
// container path read through the bind with the longest target holding
// it, a directory's entries those of its host directory and the binds
// mounted directly in it.
type containerView struct{ binds []composeMount }

func (v containerView) host(p string) (string, error) {
	h, ok := mountedHost(v.binds, p)
	if !ok {
		return "", fmt.Errorf("%s: no bind holds it", p)
	}
	return h, nil
}

func (v containerView) lstat(p string) (string, os.FileInfo, error) {
	h, err := v.host(p)
	if err != nil {
		return "", nil, err
	}
	info, err := os.Lstat(h)
	return h, info, err
}

// children are the names in the container directory p.
func (v containerView) children(p, h string) ([]string, error) {
	entries, err := os.ReadDir(h)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	for _, b := range v.binds {
		if t := path.Clean(b.Target); path.Dir(t) == p && !slices.Contains(names, path.Base(t)) {
			names = append(names, path.Base(t))
		}
	}
	slices.Sort(names)
	return names, nil
}

// realpath resolves p's links in the container's view, as realpath -e.
func (v containerView) realpath(p string, depth int) (string, error) {
	if depth > 40 {
		return "", errors.New("realpath: too many levels of links")
	}
	parts := strings.Split(strings.Trim(path.Clean(p), "/"), "/")
	cur := "/"
	for i, part := range parts {
		next := path.Join(cur, part)
		if _, ok := mountedHost(v.binds, next); !ok {
			// A directory of the image's own, above every bind.
			cur = next
			continue
		}
		h, info, err := v.lstat(next)
		if err != nil {
			return "", err
		}
		if info.Mode()&fs.ModeSymlink != 0 {
			target, err := os.Readlink(h)
			if err != nil {
				return "", err
			}
			if !path.IsAbs(target) {
				target = path.Join(cur, target)
			}
			return v.realpath(path.Join(append([]string{target}, parts[i+1:]...)...), depth+1)
		}
		cur = next
	}
	return cur, nil
}

// find writes the listing find DIR [-maxdepth 1] -printf '%D %i %y %s %p\0'
// writes.
func (v containerView) find(w io.Writer, args []string) error {
	shallow := slices.Contains(args, "-maxdepth")
	var walk func(p string, depth int) error
	walk = func(p string, depth int) error {
		if _, ok := mountedHost(v.binds, p); !ok {
			// A directory of the image's own that binds are mounted in:
			// it holds them alone.
			fmt.Fprintf(w, "0 0 d 0 %s\x00", p)
			if shallow && depth == 1 {
				return nil
			}
			for _, b := range v.binds {
				if t := path.Clean(b.Target); path.Dir(t) == p {
					if err := walk(t, depth+1); err != nil {
						return err
					}
				}
			}
			return nil
		}
		h, info, err := v.lstat(p)
		if err != nil {
			return err
		}
		kind := "f"
		switch m := info.Mode(); {
		case m.IsDir():
			kind = "d"
		case m&fs.ModeSymlink != 0:
			kind = "l"
		case m&fs.ModeNamedPipe != 0:
			kind = "p"
		case !m.IsRegular():
			kind = "c"
		}
		fmt.Fprintf(w, "%s %s %d %s\x00", standInID(info, h), kind, info.Size(), p)
		if !info.IsDir() || shallow && depth == 1 {
			return nil
		}
		names, err := v.children(p, h)
		if err != nil {
			return err
		}
		for _, name := range names {
			if err := walk(path.Join(p, name), depth+1); err != nil {
				return err
			}
		}
		return nil
	}
	return walk(args[0], 0)
}

// tar writes the archive tar -C / -cf - writes of its members, named after
// -- or read NUL-separated from stdin (-T -); --dereference follows a
// member that is a link, and --no-recursion archives a directory alone.
func (v containerView) tar(w io.Writer, args []string, stdin []byte) error {
	var members []string
	if i := slices.Index(args, "--"); i >= 0 {
		members = args[i+1:]
	}
	if slices.Contains(args, "-T") {
		for _, name := range bytes.Split(stdin, []byte{0}) {
			if len(name) > 0 {
				members = append(members, string(name))
			}
		}
	}
	follow, recurse := slices.Contains(args, "--dereference"), !slices.Contains(args, "--no-recursion")
	tw := tar.NewWriter(w)
	var add func(name string) error
	add = func(name string) error {
		p := "/" + name
		h, info, err := v.lstat(p)
		if err != nil {
			return err
		}
		link := ""
		if info.Mode()&fs.ModeSymlink != 0 {
			if follow {
				if info, err = os.Stat(h); err != nil {
					return err
				}
			} else if link, err = os.Readlink(h); err != nil {
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
		if info.Mode().IsRegular() {
			f, err := os.Open(h)
			if err != nil {
				return err
			}
			_, err = io.Copy(tw, f)
			f.Close()
			return err
		}
		if !info.IsDir() || !recurse {
			return nil
		}
		names, err := v.children(p, h)
		if err != nil {
			return err
		}
		for _, child := range names {
			if err := add(name + "/" + child); err != nil {
				return err
			}
		}
		return nil
	}
	for _, m := range members {
		if err := add(m); err != nil {
			return err
		}
	}
	return tw.Close()
}

// standInArchive is the archive of the storage root the stack would
// stream for the scenario: tar of every entry under data, as its container
// sees it through the scenario's one bind.
func standInArchive(t interface{ Fatal(...any) }, project string, names ...string) string {
	v := containerView{binds: []composeMount{{Type: "bind", Source: filepath.Join(project, "data"), Target: "/app/data"}}}
	var list bytes.Buffer
	var b bytes.Buffer
	if err := v.find(&list, []string{"/app/data"}); err != nil {
		t.Fatal(err)
	}
	var stdin []byte
	for _, record := range bytes.Split(list.Bytes(), []byte{0}) {
		fields := strings.SplitN(string(record), " ", 5)
		if len(fields) == 5 && !slices.Contains(names, path.Base(fields[4])) {
			stdin = append(append(stdin, rootRel(fields[4])...), 0)
		}
	}
	if err := v.tar(&b, []string{"--no-recursion", "-T", "-"}, stdin); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

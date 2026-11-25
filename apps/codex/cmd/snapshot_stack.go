// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// A snapshot reads CYFR's storage (the SQLite database with its
// write-ahead log, and the local storage root) through the stack itself,
// as the server sees it: one-off containers of the image the cyfr service
// runs, each mount of the service's resolved configuration mounted read
// only where the service mounts it, run as the container's root holding no
// capability but reading past permissions (DAC_READ_SEARCH). They run only
// programs that read (realpath, find and tar) and write nothing: their root
// filesystem and every mount are read only, which also keeps a read from
// changing an access time, they never pull, have no network and log
// nothing, and the image's entrypoint (which hands /app/data to the image's
// user) is skipped. tar streams to cyfr's standard output, and cyfr, run as
// the person, writes every file of the snapshot itself, so the snapshot is
// the person's whatever owns the storage. It is the one way the snapshot
// reads the storage, on every platform.
//
// What the snapshot holds is what the host copy before it held: the
// database the service opens, its links resolved, and the write-ahead log
// beside that file; the storage root as the service sees it, links kept as
// links, without the database's files or the access engine's state, which
// are left out by which file they are (device and inode), however a mount
// spells their path.

// Each read through the stack ends when it has streamed nothing for
// stackReadStall, and in any case at stackReadBackstop, the bound the
// engine's watchdog holds a call to after cyfr itself is gone; a large
// healthy copy keeps making progress and is never cut off by its size.
var (
	stackReadStall    = 10 * time.Minute
	stackReadBackstop = 24 * time.Hour
)

// stackEntry is one entry of a listing through the stack: the container
// path, its type as find writes it (f, d, l, ...), its size and its
// identity, device and inode.
type stackEntry struct {
	path string
	kind byte
	size int64
	id   string
}

// stackRunArgs are the docker arguments of a read through the stack named
// name that runs program with args, the service's mounts all read only,
// stdin open when the program reads its standard input.
func stackRunArgs(name string, c *stackConfig, stdin bool, program string, args ...string) []string {
	run := []string{"run", "--rm", "--name", name, "--pull", "never", "--network", "none", "--log-driver", "none",
		"--user", "0:0", "--cap-drop", "ALL", "--cap-add", "DAC_READ_SEARCH", "--security-opt", "no-new-privileges", "--read-only"}
	if stdin {
		run = append(run, "-i")
	}
	run = append(run, "--entrypoint", program)
	for _, m := range c.mounts {
		run = append(run, "--mount", mountSpec(m))
	}
	return append(append(run, c.image), args...)
}

// mountSpec is the service's mount m as docker's --mount, read only.
func mountSpec(m composeMount) string {
	fields := []string{"type=" + m.Type}
	if m.Source != "" {
		fields = append(fields, mountField("source", m.Source))
	}
	return strings.Join(append(fields, mountField("target", m.Target), "readonly"), ",")
}

// mountField is key=value as one field of docker's --mount, which reads
// its fields as CSV: quoted, its quotes doubled, when value holds a comma
// or a quote.
func mountField(key, value string) string {
	field := key + "=" + value
	if strings.ContainsAny(value, `,"`) {
		return `"` + strings.ReplaceAll(field, `"`, `""`) + `"`
	}
	return field
}

// stackRunName names one read through the stack, so its container can be
// ended and removed whatever ends the read early.
func stackRunName() string {
	var b [6]byte
	rand.Read(b[:])
	return "cyfr-snapshot-read-" + hex.EncodeToString(b[:])
}

// runThroughStack runs program through the stack, stdin its standard
// input, streaming its standard output into consume as it arrives. The run
// ends when consume is done, when the stream makes no progress for
// stackReadStall, or at stackReadBackstop; whatever ends it early, its
// container is ended and removed (access.Call.RemoveOnEnd), by the
// engine's watchdog also when cyfr itself is gone. base is the
// command's context before the stop, which an interrupt ends, and one
// free of the interrupt from the stop on, as every step's there is.
func (u *updater) runThroughStack(base context.Context, stdin []byte, consume func(io.Reader) error, program string, args ...string) error {
	ctx, cancel := context.WithTimeout(base, stackReadBackstop)
	defer cancel()
	name := stackRunName()
	var in io.Reader
	if stdin != nil {
		in = bytes.NewReader(stdin)
	}
	pr, pw := io.Pipe()
	ran := make(chan error, 1)
	go func() {
		err := u.dockerRemoving(ctx, name, in, pw, stackRunArgs(name, u.config, stdin != nil, program, args...)...)
		if err != nil {
			pw.CloseWithError(runFailed{err})
		} else {
			pw.Close()
		}
		ran <- err
	}()
	watched := &progressReader{r: pr, at: time.Now()}
	stalled := make(chan struct{})
	go func() {
		tick := time.NewTicker(stackReadStall / 10)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				if watched.idle() >= stackReadStall {
					close(stalled)
					cancel()
					return
				}
			}
		}
	}()
	err := consume(watched)
	if err != nil {
		cancel()
	}
	// What follows is read, so the run is never left writing to no one.
	_, _ = io.Copy(io.Discard, pr)
	pr.Close()
	runErr := <-ran
	cancel()
	select {
	case <-stalled:
		return fmt.Errorf("the stack's read of its storage made no progress for %s, so it was ended", stackReadStall)
	default:
	}
	switch {
	case err != nil && !errors.As(err, new(runFailed)):
		return err
	case runErr != nil:
		return fmt.Errorf("the stack's read of its storage through its image %s failed (%v); a stack that never ran may lack the image: run 'cyfr up' or 'docker compose pull cyfr' first", u.config.image, runErr)
	}
	return nil
}

// progressReader is r, noting when it last gave bytes.
type progressReader struct {
	r  io.Reader
	mu sync.Mutex
	at time.Time
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	if n > 0 {
		p.mu.Lock()
		p.at = time.Now()
		p.mu.Unlock()
	}
	return n, err
}

func (p *progressReader) idle() time.Duration {
	p.mu.Lock()
	defer p.mu.Unlock()
	return time.Since(p.at)
}

// runFailed ends a stream when its run failed, so the reader stops at the
// run's failure, which is said, not the stream's.
type runFailed struct{ error }

func (r runFailed) Unwrap() error { return r.error }

// listThroughStack lists dir through the stack, every entry under it, or
// with shallow those directly in it, dir itself first; links are listed,
// never followed.
func (u *updater) listThroughStack(base context.Context, dir string, shallow bool) ([]stackEntry, error) {
	args := []string{dir}
	if shallow {
		args = append(args, "-maxdepth", "1")
	}
	args = append(args, "-printf", `%D %i %y %s %p\0`)
	var entries []stackEntry
	err := u.runThroughStack(base, nil, func(r io.Reader) error {
		records := bufio.NewReader(r)
		for {
			record, err := records.ReadString(0)
			if errors.Is(err, io.EOF) && record == "" {
				return nil
			}
			if err != nil {
				return err
			}
			e, ok := parseStackEntry(strings.TrimSuffix(record, "\x00"))
			if !ok {
				return fmt.Errorf("the stack's listing of %s holds %q, which does not read", dir, record)
			}
			entries = append(entries, e)
		}
	}, "find", args...)
	return entries, err
}

// parseStackEntry reads one record of find's -printf '%D %i %y %s %p'.
func parseStackEntry(record string) (stackEntry, bool) {
	fields := strings.SplitN(record, " ", 5)
	if len(fields) != 5 || len(fields[2]) != 1 || !path.IsAbs(fields[4]) {
		return stackEntry{}, false
	}
	size, err := strconv.ParseInt(fields[3], 10, 64)
	if err != nil {
		return stackEntry{}, false
	}
	return stackEntry{path: path.Clean(fields[4]), kind: fields[2][0], size: size, id: fields[0] + ":" + fields[1]}, true
}

// placeDatabase reads, before anything stops, where the SQLite database
// the service opens is, its links resolved as the server resolves them
// (realpath), and refuses one that is not there or not a regular file.
func (u *updater) placeDatabase() error {
	c := u.config
	if c.adapter != "sqlite" {
		return nil
	}
	var out strings.Builder
	err := u.runThroughStack(u.ctx, nil, func(r io.Reader) error {
		_, err := io.Copy(&out, io.LimitReader(r, 64<<10))
		return err
	}, "realpath", "-e", "--", c.dbPath)
	real := strings.TrimSuffix(out.String(), "\n")
	if err != nil || !path.IsAbs(real) || strings.Contains(real, "\n") {
		return fmt.Errorf("The SQLite database %s is not there as the cyfr service sees it, so cyfr %s cannot snapshot it; nothing was changed", c.dbPath, u.command)
	}
	entries, err := u.listThroughStack(u.ctx, path.Dir(real), true)
	if err != nil {
		return fmt.Errorf("cyfr %s could not read the SQLite database %s through the stack (%v); nothing was changed", u.command, c.dbPath, err)
	}
	if i := slices.IndexFunc(entries, func(e stackEntry) bool { return e.path == real }); i < 0 || entries[i].kind != 'f' {
		return fmt.Errorf("The SQLite database %s (%s as the cyfr service sees it) is not a regular file, so cyfr %s cannot snapshot it; nothing was changed", c.dbPath, real, u.command)
	}
	c.dbReal = real
	return nil
}

// readThroughStack writes what the snapshot holds of CYFR's storage into
// the new snapshot directory dir, read through the stack, and answers the
// parts it wrote: database and, when it holds anything, database-wal for
// SQLite, then storage for local storage.
func (u *updater) readThroughStack(dir string) ([]string, error) {
	c := u.config
	free := context.WithoutCancel(u.ctx)
	// Listed with the stack stopped: the database's files, by which file
	// they are, and the storage root.
	var listing []stackEntry
	if c.storage == "local" {
		entries, err := u.listThroughStack(free, c.dataPath, false)
		if err != nil {
			return nil, err
		}
		listing = entries
	}
	left := map[string]bool{}
	var parts []string
	if c.adapter == "sqlite" {
		trio := listing
		if c.storage != "local" || !underPath(c.dbReal, c.dataPath) {
			entries, err := u.listThroughStack(free, path.Dir(c.dbReal), true)
			if err != nil {
				return nil, err
			}
			trio = entries
		}
		var db, wal *stackEntry
		for i, e := range trio {
			switch e.path {
			case c.dbReal:
				db = &trio[i]
			case c.dbReal + "-wal":
				wal = &trio[i]
			case c.dbReal + "-shm":
			default:
				continue
			}
			left[e.id] = true
		}
		if db == nil || db.kind != 'f' {
			return nil, fmt.Errorf("the SQLite database %s is no longer a regular file", c.dbReal)
		}
		members := []string{rootRel(c.dbReal)}
		switch {
		case wal == nil:
			// No write-ahead log is there: none is the database's.
		case wal.kind == 'f' && wal.size == 0:
		case wal.kind == 'f' || wal.kind == 'l':
			// A log reached through a link is read where it leads.
			members = append(members, rootRel(c.dbReal+"-wal"))
		default:
			return nil, fmt.Errorf("the SQLite write-ahead log %s-wal is neither a file nor a link to one", c.dbReal)
		}
		w := &stackWriter{c: c, dir: dir, out: u.out}
		args := append([]string{"--dereference", "--hard-dereference", "-C", "/", "-cf", "-", "--"}, members...)
		if err := u.runThroughStack(free, nil, func(r io.Reader) error { return w.writeDatabase(tar.NewReader(r)) }, "tar", args...); err != nil {
			return nil, err
		}
		if !w.database {
			return nil, fmt.Errorf("the stack's read of its storage holds no SQLite database at %s", c.dbReal)
		}
		parts = append(parts, "database")
		if len(members) > 1 {
			if !w.wal {
				return nil, fmt.Errorf("the stack's read of its storage holds no write-ahead log at %s-wal, which is there", c.dbReal)
			}
			parts = append(parts, "database-wal")
		}
	}
	if c.storage == "local" {
		for _, e := range listing {
			if slices.Contains(c.state, e.path) {
				// The access engine's state is no part of any snapshot,
				// whatever mount reaches it.
				left[e.id] = true
			}
		}
		var list bytes.Buffer
		var skipped []string
		for _, e := range listing {
			if left[e.id] || slices.ContainsFunc(skipped, func(s string) bool { return underPath(e.path, s) }) {
				skipped = append(skipped, e.path)
				continue
			}
			list.WriteString(rootRel(e.path))
			list.WriteByte(0)
		}
		if err := os.Mkdir(filepath.Join(dir, "storage"), 0700); err != nil {
			return nil, err
		}
		root, err := os.OpenRoot(filepath.Join(dir, "storage"))
		if err != nil {
			return nil, err
		}
		defer root.Close()
		w := &stackWriter{c: c, dir: dir, out: u.out, storage: root, made: map[string]bool{".": true}}
		args := []string{"--hard-dereference", "--no-recursion", "--null", "--verbatim-files-from", "-C", "/", "-cf", "-", "-T", "-"}
		if err := u.runThroughStack(free, list.Bytes(), func(r io.Reader) error { return w.writeStorage(tar.NewReader(r)) }, "tar", args...); err != nil {
			return nil, err
		}
		if !w.rootSeen {
			return nil, fmt.Errorf("the stack's read of its storage holds no storage root at %s", c.dataPath)
		}
		parts = append(parts, "storage")
	}
	return parts, nil
}

// rootRel is the container path p relative to the container's root, as
// tar run with -C / names it.
func rootRel(p string) string { return strings.TrimPrefix(path.Clean(p), "/") }

// underPath reports whether the container path p is root or lies under it.
func underPath(p, root string) bool {
	return p == root || strings.HasPrefix(p, strings.TrimSuffix(root, "/")+"/")
}

// stackWriter writes an archive the stack streamed into the snapshot. The
// archive comes from storage the server and its components write, so it
// is untrusted: every entry is placed by its container path, an absolute
// name or one that climbs is refused, the storage root's entries land
// under the snapshot's storage directory through an os.Root, each under a
// directory this archive made (so never through a link it holds, which
// stays a link), and only files, directories and links are written, files
// 0600 and directories 0700, as the copy before it wrote them.
type stackWriter struct {
	c       *stackConfig
	dir     string
	out     io.Writer
	storage *os.Root
	// made are the storage directories this archive made, by their path
	// under the root ("." the root itself).
	made                    map[string]bool
	database, wal, rootSeen bool
}

// nextEntry answers the archive's next entry and its container path, or
// io.EOF at its end.
func nextEntry(tr *tar.Reader) (*tar.Header, string, error) {
	h, err := tr.Next()
	if err != nil {
		if errors.Is(err, io.EOF) {
			return nil, "", io.EOF
		}
		return nil, "", fmt.Errorf("the stack's read of its storage did not read as an archive (%w)", err)
	}
	name := path.Clean(filepath.ToSlash(h.Name))
	if path.IsAbs(name) || name == ".." || strings.HasPrefix(name, "../") {
		return nil, "", fmt.Errorf("the stack's read of its storage holds %q, which lies outside what it was asked for", h.Name)
	}
	return h, "/" + name, nil
}

// writeDatabase writes the database's archive: the database and its
// write-ahead log, each a file, their links followed.
func (w *stackWriter) writeDatabase(tr *tar.Reader) error {
	for {
		h, p, err := nextEntry(tr)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		switch {
		case p == w.c.dbReal && h.Typeflag == tar.TypeReg:
			w.database = true
			err = copyTo(tr, filepath.Join(w.dir, "database"))
		case p == w.c.dbReal+"-wal" && h.Typeflag == tar.TypeReg:
			if h.Size == 0 {
				continue
			}
			w.wal = true
			err = copyTo(tr, filepath.Join(w.dir, "database-wal"))
		default:
			err = fmt.Errorf("the stack's read of the SQLite database holds %s, which is no part of it", p)
		}
		if err != nil {
			return err
		}
	}
}

// writeStorage writes the storage root's archive under the snapshot's
// storage directory.
func (w *stackWriter) writeStorage(tr *tar.Reader) error {
	for {
		h, p, err := nextEntry(tr)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		if !underPath(p, w.c.dataPath) {
			return fmt.Errorf("the stack's read of its storage holds %s, which is no part of a snapshot", p)
		}
		rel := strings.TrimPrefix(strings.TrimPrefix(p, w.c.dataPath), "/")
		if err := w.storageEntry(h, tr, cmpString(rel, "."), p); err != nil {
			return err
		}
	}
}

// storageEntry writes h at rel under the snapshot's storage directory.
func (w *stackWriter) storageEntry(h *tar.Header, body io.Reader, rel, p string) error {
	if rel == "." {
		if h.Typeflag != tar.TypeDir {
			return fmt.Errorf("the storage root %s is not a directory", p)
		}
		w.rootSeen = true
		return nil
	}
	if !w.made[path.Dir(rel)] {
		return fmt.Errorf("the stack's read of its storage holds %s in no directory it holds before it", p)
	}
	switch h.Typeflag {
	case tar.TypeDir:
		if err := w.storage.Mkdir(rel, 0700); err != nil {
			return err
		}
		w.made[rel] = true
		return nil
	case tar.TypeSymlink:
		return w.storage.Symlink(h.Linkname, rel)
	case tar.TypeReg:
		f, err := w.storage.OpenFile(rel, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		_, err = io.Copy(f, body)
		return errors.Join(err, f.Sync(), f.Close())
	case tar.TypeLink:
		return fmt.Errorf("the stack's read of its storage holds %s as a hard link, which it was asked to archive whole", p)
	default:
		fmt.Fprintf(w.out, "Skipped %s, neither a file, a directory nor a link.\n", p)
		return nil
	}
}

// cmpString is s, or fallback when s is empty.
func cmpString(s, fallback string) string {
	if s != "" {
		return s
	}
	return fallback
}

// stateIn answers the container paths at which the service's binds show
// the project's access state, .cyfr/ (state, a host path with its links
// resolved), each bind's source taken as written and resolved.
func stateIn(mounts []composeMount, state string) []string {
	var paths []string
	for _, b := range mounts {
		if b.Type != "bind" || b.Source == "" {
			continue
		}
		for _, source := range []string{b.Source, resolvedOr(b.Source)} {
			if rel, err := filepath.Rel(source, state); err == nil && filepath.IsLocal(rel) {
				p := path.Join(b.Target, filepath.ToSlash(rel))
				if !slices.Contains(paths, p) {
					paths = append(paths, p)
				}
			}
		}
	}
	return paths
}

// resolvedOr is p with its links resolved, or p where they do not resolve.
func resolvedOr(p string) string {
	if resolved, err := filepath.EvalSymlinks(p); err == nil {
		return resolved
	}
	return p
}

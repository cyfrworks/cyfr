// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
)

// A snapshot reads CYFR's storage (the SQLite database and the local
// storage root) through the stack itself: a one-off container of the
// image the cyfr service runs, with the binds that make up what the
// snapshot reads mounted read only where the service mounts them, runs
// tar as the container's root and streams the archive to cyfr's standard
// output. cyfr, running as the person, writes every file of the snapshot
// itself, so the snapshot is the person's whatever owns the storage (on
// native Linux the server's container owns it once the stack has run).
// It is the one way the snapshot reads the storage, on every platform.
//
// The container never pulls, has no network, holds no capability but
// reading past permissions (DAC_READ_SEARCH), skips the image's
// entrypoint (which hands /app/data to the image's user) and writes
// nothing: its root filesystem and every bind are read only, which also
// keeps a read from changing an access time.

// stackRead is one tar run through the stack: dir, a container path, the
// directory tar archives from, and members, the names under it.
type stackRead struct {
	dir     string
	members []string
	// missingOK lets a member be absent: the SQLite write-ahead log.
	missingOK bool
}

// stackReadArgs are the docker arguments of the run that archives r: the
// image the cyfr service runs, each of binds mounted read only at its
// target, tar its command.
func stackReadArgs(image string, binds []composeMount, r stackRead) []string {
	args := []string{"run", "--rm", "--pull", "never", "--network", "none", "--user", "0:0",
		"--cap-drop", "ALL", "--cap-add", "DAC_READ_SEARCH", "--security-opt", "no-new-privileges",
		"--read-only", "--entrypoint", "tar"}
	for _, b := range binds {
		args = append(args, "--mount", "type=bind,"+mountField("source", b.Source)+","+mountField("target", b.Target)+",readonly")
	}
	args = append(args, image, "--hard-dereference")
	if r.missingOK {
		args = append(args, "--ignore-failed-read")
	}
	return append(append(args, "-C", r.dir, "-cf", "-"), r.members...)
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

// stackReads are the runs that read what the snapshot holds of c: the
// storage root whole, the database among it where it lies there, and the
// SQLite database with its write-ahead log on their own otherwise.
func stackReads(c *stackConfig) []stackRead {
	var reads []stackRead
	if c.storage == "local" {
		reads = append(reads, stackRead{dir: c.dataPath, members: []string{"."}})
	}
	if c.adapter == "sqlite" && (c.storage != "local" || !underPath(c.dbPath, c.dataPath)) {
		base := path.Base(c.dbPath)
		reads = append(reads, stackRead{dir: path.Dir(c.dbPath), members: []string{base, base + "-wal"}, missingOK: true})
	}
	return reads
}

// underPath reports whether the container path p is root or lies under it.
func underPath(p, root string) bool {
	return p == root || strings.HasPrefix(p, strings.TrimSuffix(root, "/")+"/")
}

// readThroughStack writes what the snapshot holds of CYFR's storage into
// the new snapshot directory dir, read through the stack (stackReads), and
// answers the parts it wrote: database and, when it holds anything,
// database-wal for SQLite, then storage for local storage.
func (u *updater) readThroughStack(dir string) ([]string, error) {
	c := u.config
	w := &stackWriter{c: c, dir: dir, out: u.out, made: map[string]bool{".": true}}
	if c.storage == "local" {
		if err := os.Mkdir(filepath.Join(dir, "storage"), 0700); err != nil {
			return nil, err
		}
		root, err := os.OpenRoot(filepath.Join(dir, "storage"))
		if err != nil {
			return nil, err
		}
		defer root.Close()
		w.storage = root
	}
	for _, r := range stackReads(c) {
		if err := u.streamStackRead(r, w); err != nil {
			return nil, err
		}
	}
	var parts []string
	if c.adapter == "sqlite" {
		if !w.database {
			return nil, fmt.Errorf("the stack's read of its storage holds no SQLite database at %s", c.dbPath)
		}
		parts = append(parts, "database")
		if w.wal {
			parts = append(parts, "database-wal")
		}
	}
	if c.storage == "local" {
		parts = append(parts, "storage")
	}
	return parts, nil
}

// streamStackRead runs r through the stack and writes its archive with w
// as it arrives.
func (u *updater) streamStackRead(r stackRead, w *stackWriter) error {
	ctx, cancel := u.detached(dumpTimeout)
	defer cancel()
	pr, pw := io.Pipe()
	ran := make(chan error, 1)
	go func() {
		err := u.docker(ctx, nil, pw, stackReadArgs(u.config.image, u.config.reads, r)...)
		if err != nil {
			pw.CloseWithError(runFailed{err})
		} else {
			pw.Close()
		}
		ran <- err
	}()
	err := w.write(tar.NewReader(pr), r.dir)
	if err != nil {
		cancel()
	}
	// What follows the archive's end is read, so the run is never left
	// writing to no one.
	_, _ = io.Copy(io.Discard, pr)
	pr.Close()
	runErr := <-ran
	switch {
	case err != nil && !errors.As(err, new(runFailed)):
		return err
	case runErr != nil:
		return fmt.Errorf("the stack's read of %s through its image %s failed (%v); a stack that never ran may lack the image: run 'cyfr up' or 'docker compose pull cyfr' first", r.dir, u.config.image, runErr)
	}
	return nil
}

// runFailed ends the archive's stream when its run failed, so the reader
// stops at the run's failure, which is said, not the stream's.
type runFailed struct{ error }

func (r runFailed) Unwrap() error { return r.error }

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
	made          map[string]bool
	database, wal bool
}

// write writes every entry of the archive tr, whose names lie under the
// container directory dir.
func (w *stackWriter) write(tr *tar.Reader, dir string) error {
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("the stack's read of its storage did not read as an archive (%w)", err)
		}
		name := path.Clean(filepath.ToSlash(h.Name))
		if path.IsAbs(name) || name == ".." || strings.HasPrefix(name, "../") {
			return fmt.Errorf("the stack's read of its storage holds %q, which lies outside %s", h.Name, dir)
		}
		if err := w.entry(h, tr, path.Join(dir, name)); err != nil {
			return err
		}
	}
}

// entry writes the archive entry h, at the container path p.
func (w *stackWriter) entry(h *tar.Header, body io.Reader, p string) error {
	c := w.c
	switch {
	case c.adapter == "sqlite" && p == c.dbPath:
		if h.Typeflag != tar.TypeReg {
			return fmt.Errorf("the SQLite database %s is not a regular file", p)
		}
		w.database = true
		return copyTo(body, filepath.Join(w.dir, "database"))
	case c.adapter == "sqlite" && p == c.dbPath+"-wal":
		if h.Typeflag != tar.TypeReg || h.Size == 0 {
			return nil
		}
		w.wal = true
		return copyTo(body, filepath.Join(w.dir, "database-wal"))
	case c.adapter == "sqlite" && p == c.dbPath+"-shm":
		return nil
	case slices.ContainsFunc(c.state, func(state string) bool { return underPath(p, state) }):
		// The access engine's state is no part of any snapshot, whatever
		// mount reaches it.
		return nil
	case w.storage != nil && underPath(p, c.dataPath):
		rel := strings.TrimPrefix(strings.TrimPrefix(p, c.dataPath), "/")
		return w.storageEntry(h, body, cmpString(rel, "."), p)
	}
	return fmt.Errorf("the stack's read of its storage holds %s, which is no part of a snapshot", p)
}

// storageEntry writes h at rel under the snapshot's storage directory.
func (w *stackWriter) storageEntry(h *tar.Header, body io.Reader, rel, p string) error {
	if rel == "." {
		if h.Typeflag != tar.TypeDir {
			return fmt.Errorf("the storage root %s is not a directory", p)
		}
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

// stateIn answers the container paths at which the binds show the
// project's access state, .cyfr/ (state, a host path), its links resolved
// on both sides where they resolve.
func stateIn(binds []composeMount, state string) []string {
	var paths []string
	for _, b := range binds {
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

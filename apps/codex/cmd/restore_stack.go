// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
)

// A restore writes CYFR's storage (the SQLite database with its
// write-ahead log, and the local storage root) through the stack, the
// mirror of the snapshot's read (snapshot_stack.go): one-off containers of
// the image the restored configuration's cyfr service runs, each mount of
// that service where the service mounts it, the binds the put-back
// replaces writable and every other read only, as the container's root
// holding no capability but writing past permissions, its root
// filesystem read only, never pulling, with no network or log, the
// image's entrypoint skipped. They run only these programs, each on what
// cyfr hands it: rm on the list of entries cyfr computed from the stack's
// own listing, tar extracting the archive cyfr builds from the snapshot,
// and dd writing one file in place where a mount is that file. What they
// write is root's in the container; the declaration's offline run, which
// runs the image's entrypoint, hands the storage root to the image's user
// before the restore ends, as every start does.

// restoreWrite is what the put-back writes through the stack, read once
// the stack is stopped and the cluster's live slots are read: the
// container paths of the mounts it writes, the entries the storage's
// clear removes, and the places it must not write over.
type restoreWrite struct {
	// storageWritable are the targets of the binds the storage's clear and
	// archive write, the one the storage root lies on and each under it
	// (writableMounts); every other write writes the binds of the files it
	// writes alone (holding).
	storageWritable []string
	// clear are the entries under the storage root the put-back removes,
	// the topmost of each tree.
	clear []string
	// targets are the container paths at which a mount of the cyfr
	// service lies under the storage root, each its kind in the listing
	// (find's %y); a file one is written in place.
	targets map[string]byte
	// walls are the container paths the snapshot's storage may hold a
	// directory at and nothing else: the storage root, each mount
	// target's and the database's directories on the way to it; kept,
	// those it may hold nothing at or under: the database's files and the
	// engine's state.
	walls map[string]bool
	kept  []string
	// staged are the places the database's write stages its files at
	// (stagedNames), by the database's path and, where one is there, as
	// the storage's listing spells it: the clear removes one left there,
	// and the snapshot's storage may hold nothing at or under one.
	staged []string
	// trio are the database's files there now, by path.
	trio map[string]stackEntry
}

// placeRestoredDatabase makes the place the put-back writes through the
// stack ready, before the cluster's live slots are read: the snapshot's
// image on this machine, pulled when it is not, as a start would pull it;
// each missing source of a bind the put-back writes made, as the person,
// as the put-back made it before; and, for SQLite, the database the
// restored service opens, its links resolved through the stack as the
// server resolves them (dbReal), and whether it is there.
func (r *restorer) placeRestoredDatabase() error {
	c := r.config
	if c.adapter != "sqlite" && c.storage != "local" {
		return nil
	}
	if err := r.haveImage(); err != nil {
		return err
	}
	if err := r.makeSources(); err != nil {
		return err
	}
	if c.adapter != "sqlite" {
		return nil
	}
	real, there, entry, err := r.placeThroughStack(context.WithoutCancel(r.ctx), c.dbPath)
	switch {
	case err != nil:
		return fmt.Errorf("cyfr restore could not read the SQLite database %s through the stack: %v", c.dbPath, err)
	case !there && entry != nil:
		return fmt.Errorf("the SQLite database %s is a link to nothing", c.dbPath)
	case there && (entry == nil || entry.kind != 'f'):
		return fmt.Errorf("the SQLite database %s (%s as the cyfr service sees it) is not a regular file", c.dbPath, real)
	}
	if _, _, ok := holdingMount(c.mounts, real); !ok {
		return fmt.Errorf("the SQLite database %s (%s as the cyfr service sees it) is on no bind mount of the cyfr service", c.dbPath, real)
	}
	c.dbReal = real
	// An empty file is no database: SQLite reads it as one with no table,
	// and a missing file bind's source is made as one (makeSources).
	r.sqliteLive = there && entry.size > 0
	return nil
}

// haveImage makes sure the image the restored cyfr service runs is on this
// machine, pulling it, said first, when it is not: a restore onto a new
// machine has no image of the snapshot's release until it is pulled.
func (r *restorer) haveImage() error {
	ctx, cancel := r.detached(composeRunTimeout)
	_, err := r.dockerOutput(ctx, nil, "image", "inspect", "--format", "{{.Id}}", r.config.image)
	cancel()
	if err == nil {
		return nil
	}
	fmt.Fprintf(r.out, "The snapshot's image %s is not on this machine; pulling it...\n", r.config.image)
	ctx, cancel = r.detached(pullTimeout)
	defer cancel()
	if err := r.docker(ctx, nil, nil, "pull", r.config.image); err != nil {
		return fmt.Errorf("docker pull %s failed (%v), and cyfr restore writes the storage through that image", r.config.image, err)
	}
	return nil
}

// writableMounts are the binds the put-back writes: storage, the one the
// storage root lies on and each under it, for local storage; database,
// those the database, its write-ahead log and its shared-memory index lie
// on, for SQLite (the database's unresolved path before it is placed).
// Each write through the stack is given only its own as writable.
func (c *stackConfig) writableMounts() (storage, database []composeMount) {
	add := func(mounts []composeMount, m composeMount) []composeMount {
		if slices.ContainsFunc(mounts, func(o composeMount) bool { return path.Clean(o.Target) == path.Clean(m.Target) }) {
			return mounts
		}
		return append(mounts, m)
	}
	if c.storage == "local" {
		if m, _, ok := holdingMount(c.mounts, c.dataPath); ok {
			storage = add(storage, m)
		}
		for _, n := range mountsUnder(c.mounts, c.dataPath) {
			if !c.notStorage(path.Clean(n.mount.Target)) {
				storage = add(storage, n.mount)
			}
		}
	}
	if c.adapter == "sqlite" {
		for _, suffix := range []string{"", "-wal", "-shm"} {
			if m, _, ok := holdingMount(c.mounts, cmpString(c.dbReal, c.dbPath)+suffix); ok {
				database = add(database, m)
			}
		}
	}
	return storage, database
}

// notStorage reports whether the container path target, a mount's under
// the storage root, is no part of the storage: one of the database's
// files, at the path the service opens it or the one it resolves to, or
// the engine's state or a part of it (stateIn), which no snapshot's
// storage holds and the storage's writes never write.
func (c *stackConfig) notStorage(target string) bool {
	if c.adapter == "sqlite" {
		for _, db := range []string{c.dbPath, c.dbReal} {
			if db != "" && (target == db || target == db+"-wal" || target == db+"-shm") {
				return true
			}
		}
	}
	return slices.ContainsFunc(c.state, func(s string) bool { return underPath(target, s) })
}

// targets are the mounts' container targets.
func targets(mounts []composeMount) []string {
	var out []string
	for _, m := range mounts {
		out = append(out, path.Clean(m.Target))
	}
	return out
}

// makeSources makes each missing source of a bind the put-back writes, as
// the person, as the put-back made it before: a directory, or an empty
// file where the snapshot places a file (a mount under the storage root,
// or the database's own, its log's or its index's). Then each such bind's
// missing mount point in the bind it lies in, of the source's kind, as a
// start makes it: a run through the stack mounts the bind it lies in read
// only, where docker cannot make it. One this person may not look for is
// left as it is, a stack that ran having made it.
func (r *restorer) makeSources() error {
	c := r.config
	storage, database := c.writableMounts()
	writable := append(storage, database...)
	for _, m := range writable {
		target := path.Clean(m.Target)
		file := c.adapter == "sqlite" && slices.ContainsFunc([]string{"", "-wal", "-shm"}, func(suffix string) bool { return target == path.Clean(c.dbPath)+suffix })
		if rel, ok := strings.CutPrefix(target, strings.TrimSuffix(c.dataPath, "/")+"/"); ok && c.storage == "local" {
			if info, err := os.Lstat(filepath.Join(r.snap.path("storage"), filepath.FromSlash(rel))); err == nil && info.Mode().IsRegular() {
				file = true
			}
		}
		made, err := makeAbsent(m.Source, file)
		r.made = append(r.made, made...)
		if err != nil {
			return fmt.Errorf("cyfr restore could not make %s, the cyfr service's mount at %s, which is not there (%v)", m.Source, target, err)
		}
	}
	for _, m := range writable {
		target := path.Clean(m.Target)
		others := slices.DeleteFunc(slices.Clone(c.mounts), func(o composeMount) bool { return path.Clean(o.Target) == target })
		point, ok := mountedHost(others, target)
		if !ok {
			continue
		}
		info, err := os.Stat(m.Source)
		if err != nil {
			continue
		}
		made, err := makeAbsent(point, !info.IsDir())
		r.made = append(r.made, made...)
		if err != nil && !errors.Is(err, fs.ErrPermission) {
			return fmt.Errorf("cyfr restore could not make %s, where the cyfr service's mount at %s lies (%v)", point, target, err)
		}
	}
	return nil
}

// makeAbsent makes p, an empty file 0600 when file or else a directory
// 0700, its directories first, when nothing is there, and answers what it
// may have made, the topmost first; nothing is changed where something
// is, or where this person may not look.
func makeAbsent(p string, file bool) ([]string, error) {
	var made []string
	for q := p; ; q = filepath.Dir(q) {
		if _, err := os.Lstat(q); !errors.Is(err, fs.ErrNotExist) || filepath.Dir(q) == q {
			break
		}
		made = append([]string{q}, made...)
	}
	if len(made) == 0 {
		return nil, nil
	}
	if !file {
		return made, os.MkdirAll(p, 0700)
	}
	if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
		return made, err
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return made, err
	}
	return made, f.Close()
}

// planWrite reads, as the last step before the put-back, what it writes
// through the stack (restoreWrite), and refuses a snapshot whose storage
// would write where the put-back must not: over the database's files or
// the engine's state, something other than a directory where a mount lies
// beneath, or where the database's directory goes, or a kind of entry
// other than the mount's at a mount's place.
func (r *restorer) planWrite() error {
	c := r.config
	if c.adapter != "sqlite" && c.storage != "local" {
		return nil
	}
	listing, trio, left, err := r.storageEntries(context.WithoutCancel(r.ctx))
	if err != nil {
		return err
	}
	storage, _ := c.writableMounts()
	w := &restoreWrite{trio: trio, targets: map[string]byte{}, walls: map[string]bool{}, storageWritable: targets(storage)}
	if c.storage == "local" {
		kinds := map[string]byte{}
		for _, e := range listing {
			kinds[e.path] = e.kind
		}
		w.walls[c.dataPath] = true
		wall := func(p string) {
			for q := path.Dir(p); underPath(q, c.dataPath); q = path.Dir(q) {
				w.walls[q] = true
			}
		}
		for _, n := range mountsUnder(c.mounts, c.dataPath) {
			target := path.Clean(n.mount.Target)
			w.targets[target] = kinds[target]
			wall(target)
		}
		if c.adapter == "sqlite" {
			wall(c.dbReal)
			w.kept = append(w.kept, c.dbReal, c.dbReal+"-wal", c.dbReal+"-shm")
		}
		staged := map[string]bool{}
		if c.adapter == "sqlite" {
			w.staged = stagedNames(c.dbReal)
			for _, p := range w.staged {
				if e, there := trio[p]; there {
					staged[e.id] = true
				}
			}
		}
		for _, e := range listing {
			switch {
			case staged[e.id]:
				w.staged = append(w.staged, e.path)
			case left[e.id]:
				w.kept = append(w.kept, e.path)
				wall(e.path)
			}
		}
		w.kept = append(w.kept, c.state...)
		w.clear = clearList(listing, c.dataPath, w)
		root, err := os.OpenRoot(r.snap.path("storage"))
		if err != nil {
			return err
		}
		defer root.Close()
		if err := w.walkStorage(root, c.dataPath, func(string, string, fs.DirEntry) error { return nil }); err != nil {
			return err
		}
	}
	r.write = w
	return nil
}

// clearList is what the storage's clear removes of listing, the stack's
// listing of the storage root root: every entry under it but the kept
// ones (by identity, w.kept from the listing, each with all beneath it),
// the mount targets and every directory on the way to a mount target or
// a kept entry (w.walls), each tree named once by its topmost entry. A
// link is an entry like any other, removed as itself.
func clearList(listing []stackEntry, root string, w *restoreWrite) []string {
	kept, removed := map[string]bool{}, map[string]bool{}
	for _, p := range w.kept {
		kept[p] = true
	}
	beneath := func(p string, in map[string]bool) bool {
		for q := path.Dir(p); underPath(q, root) && q != root; q = path.Dir(q) {
			if in[q] {
				return true
			}
		}
		return false
	}
	var list []string
	for _, e := range listing {
		_, target := w.targets[e.path]
		switch {
		case e.path == root || !underPath(e.path, root):
		case kept[e.path] || beneath(e.path, kept):
		case w.walls[e.path] || target:
		case beneath(e.path, removed):
		default:
			removed[e.path] = true
			list = append(list, e.path)
		}
	}
	return list
}

// walkStorage walks the snapshot's storage/ through root, which no walk
// leaves, never following a link, and hands visit each entry under it
// with its container path under the storage root dataPath, parents before
// children, refusing one the put-back must not write: at or under a kept
// path, other than a directory at a wall, other than a directory or a
// regular file at a mount's place as the mount is.
func (w *restoreWrite) walkStorage(root *os.Root, dataPath string, visit func(rel, p string, d fs.DirEntry) error) error {
	return fs.WalkDir(root.FS(), ".", func(rel string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		p := path.Join(dataPath, rel)
		refuse := func(why string) error {
			return fmt.Errorf("The snapshot's storage holds %s, %s, so cyfr restore cannot put it back", rel, why)
		}
		if slices.ContainsFunc(w.kept, func(k string) bool { return underPath(p, k) }) {
			return refuse("where the database's files or the access engine's state lie")
		}
		if slices.ContainsFunc(w.staged, func(k string) bool { return underPath(p, k) }) {
			return refuse("where cyfr restore stages the database's files")
		}
		kind, target := w.targets[p]
		switch {
		case w.walls[p] && !d.IsDir():
			return refuse("which is not a directory, where the storage holds one")
		case target && kind == 'd' && !d.IsDir():
			return refuse("which is not a directory, where a mount of the cyfr service is one")
		case target && kind != 'd' && !d.Type().IsRegular():
			return refuse("which is not a file, where a mount of the cyfr service is one")
		}
		return visit(rel, p, d)
	})
}

// writeStorage writes the snapshot's storage/ back through the stack: the
// clear's list removed, then the archive of storage/ (storageArchive)
// extracted at the storage root, then each mount that is one file written
// in place.
func (r *restorer) writeStorage() error {
	c, w := r.config, r.write
	free := context.WithoutCancel(r.ctx)
	if len(w.clear) > 0 {
		var list bytes.Buffer
		for _, p := range w.clear {
			list.WriteString(p)
			list.WriteByte(0)
		}
		if err := r.runStack(free, stackCall{stdin: &list, writable: w.storageWritable}, "xargs", "-0", "-r", "rm", "-rf", "--"); err != nil {
			return err
		}
	}
	root, err := os.OpenRoot(r.snap.path("storage"))
	if err != nil {
		return err
	}
	defer root.Close()
	var inPlace []string
	pr, pw := io.Pipe()
	go func() {
		pw.CloseWithError(w.storageArchive(pw, root, c.dataPath, r.out, &inPlace))
	}()
	err = r.runStack(free, stackCall{stdin: pr, writable: w.storageWritable}, "tar", "-x", "-f", "-", "-C", c.dataPath, "--no-same-owner", "--no-overwrite-dir")
	pr.CloseWithError(errors.New("the write ended"))
	if err != nil {
		return err
	}
	for _, rel := range inPlace {
		if err := r.writeInPlace(free, path.Join(c.dataPath, rel), func() (io.ReadCloser, error) { return root.Open(rel) }); err != nil {
			return err
		}
	}
	return nil
}

// storageArchive writes into out the archive the storage's put-back
// extracts at the storage root, built by cyfr from the snapshot's
// storage/ (walkStorage), which the person may have edited, so nothing it
// holds lands anywhere but in the storage root: each name relative and
// clean, under a directory the archive holds before it (or one the root
// holds already, a wall), never under a link; directories 0700, regular
// files 0600, links as the links they are, owned by root; a mount that is
// one file is left out and named in inPlace; anything else is skipped and
// said, as the copy before it did.
func (w *restoreWrite) storageArchive(out io.Writer, root *os.Root, dataPath string, said io.Writer, inPlace *[]string) error {
	tw := tar.NewWriter(out)
	err := w.walkStorage(root, dataPath, func(rel, p string, d fs.DirEntry) error {
		if !filepath.IsLocal(rel) || path.Clean(rel) != rel {
			return fmt.Errorf("the snapshot's storage holds %q, which is no path under it", rel)
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		h := &tar.Header{Name: rel, ModTime: info.ModTime(), Uid: 0, Gid: 0, Format: tar.FormatPAX}
		switch mode := d.Type(); {
		case d.IsDir():
			h.Typeflag, h.Name, h.Mode = tar.TypeDir, rel+"/", 0o700
		case mode&fs.ModeSymlink != 0:
			link, err := root.Readlink(rel)
			if err != nil {
				return err
			}
			h.Typeflag, h.Linkname, h.Mode = tar.TypeSymlink, link, 0o777
		case mode.IsRegular():
			if kind, target := w.targets[p]; target && kind != 'd' {
				*inPlace = append(*inPlace, rel)
				return nil
			}
			h.Typeflag, h.Mode, h.Size = tar.TypeReg, 0o600, info.Size()
		default:
			fmt.Fprintf(said, "Skipped %s, neither a file, a directory nor a link.\n", path.Join("storage", rel))
			return nil
		}
		if err := tw.WriteHeader(h); err != nil {
			return err
		}
		if h.Typeflag != tar.TypeReg {
			return nil
		}
		f, err := root.Open(rel)
		if err != nil {
			return err
		}
		defer f.Close()
		n, err := io.Copy(tw, f)
		if err == nil && n != h.Size {
			err = fmt.Errorf("the snapshot's storage/%s changed while it was read", rel)
		}
		return err
	})
	if err != nil {
		return err
	}
	return tw.Close()
}

// writeInPlace writes the bytes open answers over the container path p,
// a mount that is one file, in place (a mount point cannot be renamed
// over), and syncs it, with that mount alone writable; nil open empties
// it.
func (r *restorer) writeInPlace(base context.Context, p string, open func() (io.ReadCloser, error)) error {
	var in io.Reader = bytes.NewReader(nil)
	if open != nil {
		f, err := open()
		if err != nil {
			return err
		}
		defer f.Close()
		in = f
	}
	return r.runStack(base, stackCall{stdin: in, writable: r.config.holding(p)}, "dd", "of="+p, "bs=1M", "conv=fsync", "status=none")
}

// holding are the targets of the mounts the container paths ps lie on,
// each once: what a write of those paths alone writes.
func (c *stackConfig) holding(ps ...string) []string {
	out := []string{}
	for _, p := range ps {
		if m, _, ok := holdingMount(c.mounts, p); ok && !slices.Contains(out, path.Clean(m.Target)) {
			out = append(out, path.Clean(m.Target))
		}
	}
	return out
}

// stagedName is the name of the restore's own beside the container path p
// that a file is written at, synced, before it is renamed over p, so p is
// never a file half written. A restore cut short leaves it, and the next
// one writes it again.
func stagedName(p string) string { return path.Join(path.Dir(p), "."+path.Base(p)+".restore") }

// stagedNames are the names the database db and its write-ahead log are
// staged at, which are the database's files wherever they are named.
func stagedNames(db string) []string { return []string{stagedName(db), stagedName(db + "-wal")} }

// writeDatabase puts the SQLite file back, and its write-ahead log as the
// snapshot holds it, through the stack: each is extracted at its staged
// name (a fresh file 0600) at the mount it lies on and synced; then the
// old log and shared-memory index go, each removed, or emptied in place
// where a mount is that file, which SQLite reads as no log, so the
// restored file is never read with another file's log; then the file and
// after it its log are renamed into place, or written in place and synced
// where a mount is that file, and the directory is synced. Where each
// place can be renamed over, each file is whole at every step, but the
// database is not one state throughout: from the old log's removal to the
// last rename it is a whole SQLite file without what a log held (the old
// file without its log, then the snapshot's without its own). That is
// only under the restore's bar, where nothing reads it but the same
// restore run again, which puts every part back. A file written in place
// and cut short is half written: the restore run again finds the bar this
// one left and puts it back whole (refuseLiveMembers).
func (r *restorer) writeDatabase() error {
	c, w := r.config, r.write
	free := context.WithoutCancel(r.ctx)
	// Each run writes the binds of the files it writes alone.
	run := func(writes []string, stdin io.Reader, program string, args ...string) error {
		return r.runStack(free, stackCall{stdin: stdin, writable: c.holding(writes...)}, program, args...)
	}
	isTarget := func(p string) bool {
		return slices.ContainsFunc(c.mounts, func(m composeMount) bool { return path.Clean(m.Target) == p })
	}
	type file struct{ part, p string }
	files := []file{{"database", c.dbReal}}
	if r.snap.parts["database-wal"] {
		files = append(files, file{"database-wal", c.dbReal + "-wal"})
	}
	open := func(f file) func() (io.ReadCloser, error) {
		return func() (io.ReadCloser, error) { return os.Open(r.snap.path(f.part)) }
	}
	var staged []file
	for _, f := range files {
		if !isTarget(f.p) {
			staged = append(staged, f)
		}
	}
	if len(staged) > 0 {
		// The staged files lie in the database's folder, on the bind that
		// holds that folder (not the database's own where it is a file bind).
		m, _, _ := holdingMount(c.mounts, stagedName(staged[0].p))
		var rels, names []string
		var opens []func() (io.ReadCloser, error)
		for _, f := range staged {
			_, rel, _ := holdingMount(c.mounts, stagedName(f.p))
			rels, names, opens = append(rels, strings.TrimPrefix(rel, "/")), append(names, stagedName(f.p)), append(opens, open(f))
		}
		pr, pw := io.Pipe()
		go func() { pw.CloseWithError(filesArchive(pw, rels, opens)) }()
		err := run(names, pr, "tar", "-x", "-f", "-", "-C", path.Clean(m.Target), "--no-same-owner", "--no-overwrite-dir")
		pr.CloseWithError(errors.New("the write ended"))
		if err == nil {
			err = run(names, nil, "sync", append([]string{"--"}, names...)...)
		}
		if err != nil {
			return err
		}
	}
	var remove []string
	for _, suffix := range []string{"-shm", "-wal"} {
		p := c.dbReal + suffix
		if _, there := w.trio[p]; !there {
			continue
		}
		if isTarget(p) {
			if err := r.writeInPlace(free, p, nil); err != nil {
				return err
			}
			continue
		}
		remove = append(remove, p)
	}
	if len(remove) > 0 {
		if err := run(remove, nil, "rm", append([]string{"-f", "--"}, remove...)...); err != nil {
			return err
		}
	}
	for _, f := range files {
		var err error
		if isTarget(f.p) {
			err = r.writeInPlace(free, f.p, open(f))
		} else {
			err = run([]string{stagedName(f.p), f.p}, nil, "mv", "-f", "-T", "--", stagedName(f.p), f.p)
		}
		if err != nil {
			return err
		}
	}
	if len(staged) > 0 {
		return run([]string{stagedName(c.dbReal)}, nil, "sync", "--", path.Dir(c.dbReal))
	}
	return nil
}

// filesArchive writes into out the archive of files at rels, clean
// relative paths in one directory, that directory's own directories
// before them (0700, kept as they are where they are there), each file
// 0600 with the bytes its open answers, owned by root.
func filesArchive(out io.Writer, rels []string, opens []func() (io.ReadCloser, error)) error {
	tw := tar.NewWriter(out)
	var dirs []string
	for d := path.Dir(rels[0]); d != "."; d = path.Dir(d) {
		dirs = append([]string{d}, dirs...)
	}
	for _, d := range dirs {
		if err := tw.WriteHeader(&tar.Header{Name: d + "/", Typeflag: tar.TypeDir, Mode: 0o700, Format: tar.FormatPAX}); err != nil {
			return err
		}
	}
	for i, rel := range rels {
		if err := archiveFile(tw, rel, opens[i]); err != nil {
			return err
		}
	}
	return tw.Close()
}

// archiveFile writes the file open answers into tw at rel, 0600.
func archiveFile(tw *tar.Writer, rel string, open func() (io.ReadCloser, error)) error {
	f, err := open()
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.(interface{ Stat() (os.FileInfo, error) }).Stat()
	if err != nil {
		return err
	}
	if err := tw.WriteHeader(&tar.Header{Name: rel, Typeflag: tar.TypeReg, Mode: 0o600, Size: info.Size(), ModTime: info.ModTime(), Format: tar.FormatPAX}); err != nil {
		return err
	}
	_, err = io.Copy(tw, f)
	return err
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

// The Chrome the driver starts is fetched as a program fetches itself:
// Chrome for Testing's chrome build, the current stable for this
// machine's architecture, into the kept home. Nothing of it is in the
// image. No version is pinned and no checksum is shipped. The list on
// googlechromelabs.github.io decides one thing alone, the current
// stable's version number, read as digits and dots and nothing else; the
// driver builds that version's archive address itself, on
// storage.googleapis.com, from the number and this machine's platform,
// and follows no address a list gives. A version lower than the one the
// home holds replaces nothing. So the worst a wrong list does is name a
// version the storage does not hold, a failed check, or keep a home on the
// Chrome it has.
//
// The home holds each Chrome as a version folder of its own,
// $HOME/cyfr-browser/versions/<version>, and the start runs the newest.
// A download is kept as it arrives, in $HOME/cyfr-browser/.partial-<version>.zip:
// one that is cut off, at the start's bound or by the link, is taken up at
// the next start with a range request, and is unpacked only once it is
// whole, at the length the server said, in a staging folder inside the
// home; the finished folder is published with one rename, so a folder
// under versions is always whole, and only then are older versions
// removed. A partial for a version that is no longer the current stable
// is discarded. Everything is in the home, so its bound counts it. The
// list is read at a start at most once a day ($HOME/cyfr-browser/checked
// records the last time it was asked), and a partial is taken up at any
// start, always before Chrome starts; the home's lock, held by the driver
// that has it until that driver ends, keeps a second start from
// writing the partial or fetching while a Chrome runs. A check or a
// download that fails never keeps a Chrome already in the home from
// starting.

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

const (
	defaultSource  = "https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_STABLE"
	defaultStorage = "https://storage.googleapis.com/chrome-for-testing-public"
	// checkEvery is how often a start asks the list for a newer stable.
	checkEvery = 24 * time.Hour
	// firstWait bounds the first fetch, which the person's first open
	// waits for, inside the host's bound on a start and its hello.
	firstWait = 80 * time.Second
	// updateWait bounds a fetch of a newer stable, after which the Chrome
	// already in the home starts.
	updateWait = 30 * time.Second
	// The list is a version number, the archive is bounded, and so is what
	// it unpacks to.
	maxList     = 64
	maxArchive  = 1 << 30
	maxUnpacked = 3 << 29
	// listWait bounds asking the list.
	listWait = 15 * time.Second
	// What the person and Aqua read when the home holds no Chrome: one
	// that could not be fetched at all, or one whose download went on and
	// is not whole yet.
	notDownloaded    = "The browser could not be downloaded; try again in a moment."
	stillDownloading = "The browser is still downloading; try again in a moment."
)

var (
	errNotDownloaded    = errors.New(notDownloaded)
	errStillDownloading = errors.New(stillDownloading)
	versionName         = regexp.MustCompile(`^[0-9]{1,6}(\.[0-9]{1,6}){3}$`)
	contentRange        = regexp.MustCompile(`^bytes ([0-9]+)-([0-9]+)/([0-9]+)$`)
)

// store is the home's Chrome: its versions, its last check, the list
// that names the current stable and the storage its archives are on.
type store struct {
	dir      string
	source   string
	storage  string
	platform string
	client   *http.Client
	now      func() time.Time
}

// newStore is the store in home, its version read from source and its
// archives fetched from storage, for this machine. Either may be a file:
// address, which the image suite serves its own from; a person's row
// carries no argument, so both are always the defaults.
func newStore(home, source, storage string) (*store, error) {
	if home == "" {
		return nil, errors.New("HOME names no folder")
	}
	platform, err := platformOf(runtime.GOARCH)
	if err != nil {
		return nil, err
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.RegisterProtocol("file", http.NewFileTransport(http.Dir("/")))
	return &store{
		dir:      filepath.Join(home, "cyfr-browser"),
		source:   source,
		storage:  strings.TrimRight(storage, "/"),
		platform: platform,
		client:   &http.Client{Transport: transport},
		now:      time.Now,
	}, nil
}

// platformOf is Chrome for Testing's name for an architecture's build.
func platformOf(arch string) (string, error) {
	switch arch {
	case "amd64":
		return "linux64", nil
	case "arm64":
		return "linux-arm64", nil
	}
	return "", fmt.Errorf("Chrome for Testing has no build for %s", arch)
}

// chrome answers the Chrome to start, fetching one first when the home
// holds none, a day has passed since the list was last asked, or a
// download a start cut off waits to be taken up, and release, which lets
// the home's lock go: the caller holds it until its Chrome has ended, so no
// other start fetches meanwhile. A failed check or fetch is said on log.
// With no Chrome in the home it is errStillDownloading when this start's
// download went on but is not whole, and errNotDownloaded when it made no
// progress; a start that finds another holding the lock fetches nothing.
func (s *store) chrome(ctx context.Context, log io.Writer) (string, func(), error) {
	if err := os.MkdirAll(filepath.Join(s.dir, "versions"), 0o700); err != nil {
		return "", nil, err
	}
	release, held, err := s.lock()
	if err != nil {
		return "", nil, err
	}
	if !held {
		if have := s.newest(); have != "" {
			return s.path(have), func() {}, nil
		}
		return "", nil, errStillDownloading
	}
	s.sweep()
	have := s.newest()
	progressed := false
	if want := s.wanted(ctx, have, log); want != "" {
		wait := updateWait
		if have == "" {
			wait = firstWait
		}
		fetchCtx, cancel := context.WithTimeout(ctx, wait)
		gained, err := s.fetch(fetchCtx, want)
		cancel()
		if err != nil {
			fmt.Fprintf(log, "cyfr-browser: fetching Chrome %s: %v\n", want, err)
		}
		progressed = gained > 0 && s.partial(want) != ""
		have = s.newest()
	}
	switch {
	case have != "":
		return s.path(have), release, nil
	case progressed:
		release()
		return "", nil, errStillDownloading
	default:
		release()
		return "", nil, errNotDownloaded
	}
}

func (s *store) path(version string) string {
	return filepath.Join(s.dir, "versions", version, "chrome")
}

// wanted is the version to fetch at this start, or "": the current stable
// when the list is due to be asked and names one newer than have, every
// partial of another version then discarded; else a partial newer than
// have, taken up where it stopped.
func (s *store) wanted(ctx context.Context, have string, log io.Writer) string {
	if have == "" || s.due() {
		listCtx, cancel := context.WithTimeout(ctx, listWait)
		version, err := s.ask(listCtx)
		cancel()
		if err == nil {
			s.dropPartials(version)
			if have == "" || newer(version, have) {
				return version
			}
			return ""
		}
		fmt.Fprintln(log, "cyfr-browser: asking for the current Chrome:", err)
	}
	if partial := s.newestPartial(); partial != "" && (have == "" || newer(partial, have)) {
		return partial
	}
	return ""
}

// ask reads the current stable's version from the list. The asking is
// recorded whether or not it is answered, so a list that does not answer
// is asked again only a day later.
func (s *store) ask(ctx context.Context) (string, error) {
	now := s.now()
	stamp := filepath.Join(s.dir, "checked")
	if err := os.WriteFile(stamp, nil, 0o600); err != nil {
		return "", err
	}
	if err := os.Chtimes(stamp, now, now); err != nil {
		return "", err
	}
	return s.latest(ctx)
}

// due says whether a day has passed since the list was last asked, or the
// clock stands before that time.
func (s *store) due() bool {
	info, err := os.Stat(filepath.Join(s.dir, "checked"))
	if err != nil {
		return true
	}
	now := s.now()
	return now.Before(info.ModTime()) || now.Sub(info.ModTime()) >= checkEvery
}

// latest is the current stable's version number, as the list says it:
// digits and dots, and at most the line's end after them.
func (s *store) latest(ctx context.Context) (string, error) {
	body, _, err := s.get(ctx, s.source)
	if err != nil {
		return "", err
	}
	defer body.Close()
	data, err := io.ReadAll(io.LimitReader(body, maxList+1))
	if err != nil {
		return "", err
	}
	version := strings.TrimSuffix(strings.TrimSuffix(string(data), "\n"), "\r")
	if len(data) > maxList || !versionName.MatchString(version) {
		return "", fmt.Errorf("the list names no version: %.40q", data)
	}
	return version, nil
}

// archive is version's chrome build on the storage, for this platform: an
// address the driver builds, never one a list gives.
func (s *store) archive(version string) string {
	return s.storage + "/" + version + "/" + s.platform + "/chrome-" + s.platform + ".zip"
}

// fetch downloads version's archive into its partial, from where an
// earlier start left it, and once it is whole unpacks it in a staging
// folder inside the home and publishes the finished Chrome with one rename,
// removing every other version. It answers the bytes this start added. A
// download that is cut off keeps its partial for the next start; an
// archive that is whole but does not read is discarded, and nothing is
// published.
func (s *store) fetch(ctx context.Context, version string) (int64, error) {
	partial := filepath.Join(s.dir, ".partial-"+version+".zip")
	gained, err := s.download(ctx, s.archive(version), partial)
	if err != nil {
		return gained, err
	}
	staging, err := os.MkdirTemp(s.dir, ".staging-")
	if err != nil {
		return gained, err
	}
	defer os.RemoveAll(staging)
	unpacked := filepath.Join(staging, "unpacked")
	if err := unzip(partial, unpacked); err != nil {
		_ = os.Remove(partial)
		return gained, err
	}
	// The archive's room is given back before the version is published.
	if err := os.Remove(partial); err != nil {
		return gained, err
	}
	built := filepath.Join(unpacked, "chrome-"+s.platform)
	if !executable(filepath.Join(built, "chrome")) {
		return gained, fmt.Errorf("the archive of %s holds no chrome-%s/chrome", version, s.platform)
	}
	if err := os.Rename(built, filepath.Join(s.dir, "versions", version)); err != nil {
		return gained, err
	}
	return gained, s.keepOnly(version)
}

// download brings path to the whole of address: from the byte it holds,
// by a range request, or from the first byte when the server answers the
// whole archive. It is whole only at the length the server said, the
// whole archive's length or the range's total, and answers the bytes it
// added, which stay in path when it is cut off.
func (s *store) download(ctx context.Context, address, path string) (int64, error) {
	var have int64
	if info, err := os.Stat(path); err == nil {
		have = info.Size()
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return 0, err
	}
	if have > 0 {
		request.Header.Set("Range", fmt.Sprintf("bytes=%d-", have))
	}
	response, err := s.client.Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	var total int64
	flags := os.O_WRONLY | os.O_CREATE
	switch response.StatusCode {
	case http.StatusOK:
		// The whole archive, a range asked for or not: from its first byte.
		have, total = 0, response.ContentLength
		flags |= os.O_TRUNC
	case http.StatusPartialContent:
		m := contentRange.FindStringSubmatch(response.Header.Get("Content-Range"))
		if m == nil {
			return 0, fmt.Errorf("the archive's range reads %q", response.Header.Get("Content-Range"))
		}
		first, _ := strconv.ParseInt(m[1], 10, 64)
		total, _ = strconv.ParseInt(m[3], 10, 64)
		if first != have {
			return 0, fmt.Errorf("the archive's range starts at %d, not at the %d bytes kept", first, have)
		}
		flags |= os.O_APPEND
	case http.StatusRequestedRangeNotSatisfiable:
		// What was kept is no part of the archive as it stands: start again.
		_ = os.Remove(path)
		return 0, errors.New("what was kept of the archive is past its length, so it starts again")
	default:
		return 0, fmt.Errorf("%s answered %s", address, response.Status)
	}
	switch {
	case total < 0:
		return 0, errors.New("the archive's length is not said, so it cannot be known whole")
	case total > maxArchive:
		return 0, fmt.Errorf("the archive is %d bytes, past %d", total, maxArchive)
	}
	file, err := os.OpenFile(path, flags, 0o600)
	if err != nil {
		return 0, err
	}
	written, err := io.Copy(file, io.LimitReader(response.Body, total-have))
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return written, err
	}
	if have+written != total {
		return written, fmt.Errorf("the archive holds %d of its %d bytes", have+written, total)
	}
	return written, nil
}

// get opens address, answered 200, with its length (-1 when unknown).
func (s *store) get(ctx context.Context, address string) (io.ReadCloser, int64, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, 0, err
	}
	response, err := s.client.Do(request)
	if err != nil {
		return nil, 0, err
	}
	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		return nil, 0, fmt.Errorf("%s answered %s", address, response.Status)
	}
	return response.Body, response.ContentLength, nil
}

// newest is the newest whole version in the home, or "".
func (s *store) newest() string {
	entries, err := os.ReadDir(filepath.Join(s.dir, "versions"))
	if err != nil {
		return ""
	}
	best := ""
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() && versionName.MatchString(name) &&
			executable(filepath.Join(s.dir, "versions", name, "chrome")) && (best == "" || newer(name, best)) {
			best = name
		}
	}
	return best
}

// keepOnly removes every version but keep.
func (s *store) keepOnly(keep string) error {
	entries, err := os.ReadDir(filepath.Join(s.dir, "versions"))
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Name() != keep {
			if err := os.RemoveAll(filepath.Join(s.dir, "versions", entry.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}

// sweep removes the staging folders a start that was ended mid-unpack
// left; none of them was published. Only the lock's holder sweeps.
func (s *store) sweep() {
	matches, _ := filepath.Glob(filepath.Join(s.dir, ".staging-*"))
	for _, path := range matches {
		_ = os.RemoveAll(path)
	}
}

// lock takes the home's lock if no other start holds it: held, and the
// release that lets it go.
func (s *store) lock() (func(), bool, error) {
	file, err := os.OpenFile(filepath.Join(s.dir, ".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, false, err
	}
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return func() { file.Close() }, true, nil
}

// partial is version's partial download, or "".
func (s *store) partial(version string) string {
	path := filepath.Join(s.dir, ".partial-"+version+".zip")
	if _, err := os.Stat(path); err != nil {
		return ""
	}
	return path
}

// partials are the versions of the partial downloads the home holds.
func (s *store) partials() []string {
	matches, _ := filepath.Glob(filepath.Join(s.dir, ".partial-*.zip"))
	var versions []string
	for _, path := range matches {
		version := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(path), ".partial-"), ".zip")
		if versionName.MatchString(version) {
			versions = append(versions, version)
		}
	}
	return versions
}

func (s *store) newestPartial() string {
	best := ""
	for _, version := range s.partials() {
		if best == "" || newer(version, best) {
			best = version
		}
	}
	return best
}

// dropPartials discards every partial download but current's.
func (s *store) dropPartials(current string) {
	for _, version := range s.partials() {
		if version != current {
			_ = os.Remove(filepath.Join(s.dir, ".partial-"+version+".zip"))
		}
	}
}

// newer says whether dotted version a is past b.
func newer(a, b string) bool {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(as) && i < len(bs); i++ {
		x, _ := strconv.Atoi(as[i])
		y, _ := strconv.Atoi(bs[i])
		if x != y {
			return x > y
		}
	}
	return len(as) > len(bs)
}

func executable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o100 != 0
}

// unzip unpacks archive into dir, which it makes, through a handle
// confined to dir (os.Root): every folder, file and link is made there,
// and nothing that would lead out of dir, by any chain of names and links,
// is followed. A link may name only a place below its own folder, never an
// absolute path and never a climb, and no entry is made over another.
// Chrome for Testing's archive holds no link. At most maxUnpacked bytes
// are written in all.
func unzip(archive, dir string) error {
	r, err := zip.OpenReader(archive)
	if err != nil {
		return fmt.Errorf("the archive does not read: %w", err)
	}
	defer r.Close()
	if err := os.Mkdir(dir, 0o700); err != nil {
		return err
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	defer root.Close()
	return extract(root, r.File)
}

// extract makes files in root, which is all it reaches.
func extract(root *os.Root, files []*zip.File) error {
	left := int64(maxUnpacked)
	for _, f := range files {
		name, err := entryName(f.Name)
		if err != nil {
			return err
		}
		mode := f.Mode()
		switch {
		case mode.IsDir():
			err = root.MkdirAll(name, 0o755)
		case mode&fs.ModeSymlink != 0:
			err = extractLink(root, name, f)
		case mode.IsRegular():
			left, err = extractFile(root, name, f, left)
		default:
			err = fmt.Errorf("the archive holds %s, which is no file, folder or link", f.Name)
		}
		if err != nil {
			return fmt.Errorf("the archive's %s: %w", f.Name, err)
		}
	}
	return nil
}

// entryName is an archive entry's name as a path below the folder.
func entryName(name string) (string, error) {
	clean := path.Clean(strings.TrimSuffix(name, "/"))
	if clean == "." || clean == ".." || path.IsAbs(clean) || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("the archive names %s, outside its folder", name)
	}
	return clean, nil
}

func extractLink(root *os.Root, name string, f *zip.File) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	target, err := io.ReadAll(io.LimitReader(rc, 4096))
	rc.Close()
	if err != nil {
		return err
	}
	link := string(target)
	if link == "" || path.IsAbs(link) || slices.Contains(strings.Split(link, "/"), "..") {
		return fmt.Errorf("its link names %q, which is not a place below its own folder", link)
	}
	if err := parent(root, name); err != nil {
		return err
	}
	return root.Symlink(link, name)
}

func extractFile(root *os.Root, name string, f *zip.File, left int64) (int64, error) {
	if err := parent(root, name); err != nil {
		return left, err
	}
	rc, err := f.Open()
	if err != nil {
		return left, err
	}
	defer rc.Close()
	file, err := root.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, f.Mode().Perm()|0o600)
	if err != nil {
		return left, err
	}
	written, err := io.Copy(file, io.LimitReader(rc, left+1))
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return left, fmt.Errorf("it does not read whole: %w", err)
	}
	if written > left {
		return left, fmt.Errorf("the archive unpacks past %d bytes", maxUnpacked)
	}
	return left - written, nil
}

func parent(root *os.Root, name string) error {
	if dir := path.Dir(name); dir != "." {
		return root.MkdirAll(dir, 0o755)
	}
	return nil
}

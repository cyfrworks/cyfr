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
// A fetch downloads and unpacks in a staging folder inside the home and
// publishes the finished folder with one rename, so a folder under
// versions is always whole; only then are older versions removed. The
// list is read at a start at most once a day ($HOME/cyfr-browser/checked
// records the last time it was asked), always before Chrome starts, so
// nothing is fetched while a Chrome runs; a check or a download that
// fails never keeps a Chrome already in the home from starting.

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
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
	// notDownloaded is what the person and Aqua read when the home holds
	// no Chrome and none could be fetched.
	notDownloaded = "The browser could not be downloaded; try again in a moment."
)

var (
	errNotDownloaded = errors.New(notDownloaded)
	versionName      = regexp.MustCompile(`^[0-9]{1,6}(\.[0-9]{1,6}){3}$`)
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
// holds none or a day has passed since the list was last asked. A failed
// check or fetch is said on log; with no Chrome in the home it is
// errNotDownloaded.
func (s *store) chrome(ctx context.Context, log io.Writer) (string, error) {
	if err := os.MkdirAll(filepath.Join(s.dir, "versions"), 0o700); err != nil {
		return "", err
	}
	s.sweep()
	have := s.newest()
	if have == "" || s.due() {
		wait := updateWait
		if have == "" {
			wait = firstWait
		}
		fetchCtx, cancel := context.WithTimeout(ctx, wait)
		err := s.update(fetchCtx, have)
		cancel()
		if err != nil {
			fmt.Fprintln(log, "cyfr-browser: fetching Chrome:", err)
		}
		have = s.newest()
	}
	if have == "" {
		return "", errNotDownloaded
	}
	return filepath.Join(s.dir, "versions", have, "chrome"), nil
}

// update asks the list for the current stable and, when it is newer than
// have, fetches and publishes it and removes every other version. The
// asking is recorded whether or not it is answered, so a list that does
// not answer is asked again only a day later.
func (s *store) update(ctx context.Context, have string) error {
	now := s.now()
	stamp := filepath.Join(s.dir, "checked")
	if err := os.WriteFile(stamp, nil, 0o600); err != nil {
		return err
	}
	if err := os.Chtimes(stamp, now, now); err != nil {
		return err
	}
	version, err := s.latest(ctx)
	if err != nil {
		return err
	}
	if have != "" && !newer(version, have) {
		return nil
	}
	if err := s.fetch(ctx, version, s.archive(version)); err != nil {
		return err
	}
	return s.keepOnly(version)
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

// fetch downloads version's archive and unpacks it in a staging folder
// inside the home, then publishes the finished Chrome with one rename. A
// fetch that fails, or an archive that does not read whole, publishes
// nothing and leaves nothing behind.
func (s *store) fetch(ctx context.Context, version, address string) error {
	staging, err := os.MkdirTemp(s.dir, ".staging-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(staging)
	archive := filepath.Join(staging, "chrome.zip")
	if err := s.download(ctx, address, archive); err != nil {
		return err
	}
	unpacked := filepath.Join(staging, "unpacked")
	if err := unzip(archive, unpacked); err != nil {
		return err
	}
	// The archive's room is given back before the version is published.
	if err := os.Remove(archive); err != nil {
		return err
	}
	built := filepath.Join(unpacked, "chrome-"+s.platform)
	if !executable(filepath.Join(built, "chrome")) {
		return fmt.Errorf("the archive of %s holds no chrome-%s/chrome", version, s.platform)
	}
	return os.Rename(built, filepath.Join(s.dir, "versions", version))
}

// download writes address to path, all of it or an error.
func (s *store) download(ctx context.Context, address, path string) error {
	body, length, err := s.get(ctx, address)
	if err != nil {
		return err
	}
	defer body.Close()
	if length > maxArchive {
		return fmt.Errorf("the archive is %d bytes, past %d", length, maxArchive)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	written, err := io.Copy(file, io.LimitReader(body, maxArchive+1))
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	switch {
	case err != nil:
		return err
	case written > maxArchive:
		return fmt.Errorf("the archive runs past %d bytes", maxArchive)
	case length >= 0 && written != length:
		return fmt.Errorf("the archive ended after %d of its %d bytes", written, length)
	}
	return nil
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

// sweep removes the staging folders a start that was ended mid-fetch
// left; none of them was published.
func (s *store) sweep() {
	matches, _ := filepath.Glob(filepath.Join(s.dir, ".staging-*"))
	for _, path := range matches {
		_ = os.RemoveAll(path)
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

// unzip unpacks archive into root, which it makes: every entry inside
// root, a link only to a place inside it, and no more than maxUnpacked
// bytes in all.
func unzip(archive, root string) error {
	r, err := zip.OpenReader(archive)
	if err != nil {
		return fmt.Errorf("the archive does not read: %w", err)
	}
	defer r.Close()
	if err := os.Mkdir(root, 0o700); err != nil {
		return err
	}
	left := int64(maxUnpacked)
	for _, f := range r.File {
		path, err := inside(root, f.Name)
		if err != nil {
			return err
		}
		mode := f.Mode()
		switch {
		case mode.IsDir():
			err = os.MkdirAll(path, 0o755)
		case mode&fs.ModeSymlink != 0:
			err = unzipLink(root, path, f)
		case mode.IsRegular():
			left, err = unzipFile(path, f, left)
		default:
			err = fmt.Errorf("the archive holds %s, which is no file, folder or link", f.Name)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func inside(root, name string) (string, error) {
	clean := filepath.Clean(name)
	if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("the archive names %s, outside its folder", name)
	}
	return filepath.Join(root, clean), nil
}

func unzipLink(root, path string, f *zip.File) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	target, err := io.ReadAll(io.LimitReader(rc, 4096))
	rc.Close()
	if err != nil {
		return err
	}
	resolved := filepath.Join(filepath.Dir(path), string(target))
	if filepath.IsAbs(string(target)) || !strings.HasPrefix(resolved, root+string(filepath.Separator)) {
		return fmt.Errorf("the archive's link %s leads outside its folder", f.Name)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.Symlink(string(target), path)
}

func unzipFile(path string, f *zip.File, left int64) (int64, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return left, err
	}
	rc, err := f.Open()
	if err != nil {
		return left, err
	}
	defer rc.Close()
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, f.Mode().Perm()|0o600)
	if err != nil {
		return left, err
	}
	written, err := io.Copy(file, io.LimitReader(rc, left+1))
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return left, fmt.Errorf("the archive's %s does not read whole: %w", f.Name, err)
	}
	if written > left {
		return left, fmt.Errorf("the archive unpacks past %d bytes", maxUnpacked)
	}
	return left - written, nil
}

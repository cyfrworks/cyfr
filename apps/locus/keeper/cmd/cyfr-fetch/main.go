// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-fetch runs a program that is not on npm from the person's
// own folder, fetching it there first, pinned and checksummed, when it is
// not there yet. A program row's command names it after its driver word:
//
//	cyfr-fetch NAME VERSION ARCH=URL#SHA512… [--] [ARG…]
//
// NAME is a plain file name (`[a-z0-9][a-z0-9._-]*`, at most 64
// characters) and VERSION likewise (`[0-9A-Za-z][0-9A-Za-z._-]*`). Each
// ARCH is a Go GOARCH name, given at most once, with an https URL and the
// download's SHA-512 as 128 hex digits of either case. The pairs end at
// `--` or at the first argument that is not of the form ARCH=…; the
// arguments after them are the program's own. The pair for the machine's
// architecture is the one used; none for it is an error naming the
// architecture.
//
// The program lives at $HOME/.local/share/cyfr/programs/NAME/VERSION/NAME.
// When that is a regular executable file it is run with no network.
// Otherwise the command takes an exclusive lock on the version folder
// (created 0700 as needed), so a second first run waits and then runs what
// the first installed; removes the temporary files (`.fetch-…`) an
// interrupted earlier run left there; says once on standard error what it
// fetches; and downloads the URL into a temporary file there, hashing it as
// it writes, within ten minutes, at most 2 GiB, following redirects only to
// https. A download that fails its checksum is removed and nothing is
// installed. A URL whose path ends in .tar.gz or .tgz must hold exactly one
// entry, a regular file of any name, which is the program; any other URL's
// download is the program itself. A program larger than 1 GiB is refused.
// The program is written 0755 under a temporary name in the version folder
// and renamed into place, so the folder only ever holds it whole.
//
// The program then replaces the command (execve) with argv[0] NAME, the
// program's arguments, and the environment unchanged. The command reads
// and writes nothing of the person's folder beyond the programs folder,
// and uses Go's default proxy settings. Its words go to standard error,
// prefixed `cyfr-fetch:`, where the person reads them on the row's
// terminal; a run that starts the program says nothing more. It exits 2 on
// a usage error, 1 when the fetch, its check or its extraction fails, and
// 126 or 127 when the program cannot be run.
package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha512"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"
	"time"
)

const (
	maxDownload  = 2 << 30
	maxProgram   = 1 << 30
	fetchTimeout = 10 * time.Minute
	// tempPrefix begins every temporary file's name in a version folder;
	// a NAME begins with a letter or digit, so never with it.
	tempPrefix = ".fetch-"
)

const usage = "usage: cyfr-fetch NAME VERSION ARCH=URL#SHA512... [--] [ARG...]"

var (
	namePattern    = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	versionPattern = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$`)
	pairPattern    = regexp.MustCompile(`^[a-z0-9]+=`)
	sumPattern     = regexp.MustCompile(`^[0-9A-Fa-f]{128}$`)
)

// usageError is an error in the command's arguments.
type usageError struct{ error }

// program is what a run names: the program, the download for this
// machine's architecture with its SHA-512 in lowercase hex, and the
// program's own arguments.
type program struct {
	name, version string
	url, sum      string
	args          []string
}

func main() {
	p, err := parse(os.Args[1:], runtime.GOARCH)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cyfr-fetch:", err)
		fmt.Fprintln(os.Stderr, "cyfr-fetch:", usage)
		os.Exit(2)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "cyfr-fetch: no home folder to install into:", err)
		os.Exit(1)
	}
	f := fetcher{client: &http.Client{}, notice: os.Stderr, maxDownload: maxDownload, maxProgram: maxProgram}
	path, err := f.install(home, p)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cyfr-fetch:", err)
		os.Exit(1)
	}
	err = syscall.Exec(path, append([]string{p.name}, p.args...), os.Environ())
	fmt.Fprintf(os.Stderr, "cyfr-fetch: %s %s did not start: %v\n", p.name, p.version, err)
	if errors.Is(err, syscall.ENOENT) {
		os.Exit(127)
	}
	os.Exit(126)
}

// parse reads a run's arguments for the architecture arch.
func parse(args []string, arch string) (program, error) {
	if len(args) < 3 {
		return program{}, usageError{errors.New("a name, a version and a download for each architecture are needed")}
	}
	p := program{name: args[0], version: args[1]}
	if !namePattern.MatchString(p.name) {
		return program{}, usageError{fmt.Errorf("%q is no program name: [a-z0-9][a-z0-9._-]*, at most 64 characters", p.name)}
	}
	if !versionPattern.MatchString(p.version) {
		return program{}, usageError{fmt.Errorf("%q is no version: [0-9A-Za-z][0-9A-Za-z._-]*, at most 64 characters", p.version)}
	}
	type pin struct{ url, sum string }
	pins := map[string]pin{}
	rest := args[2:]
	for i, arg := range rest {
		if arg == "--" {
			p.args = rest[i+1:]
			break
		}
		if !pairPattern.MatchString(arg) {
			p.args = rest[i:]
			break
		}
		name, download, _ := strings.Cut(arg, "=")
		at := strings.LastIndex(download, "#")
		if at < 0 {
			return program{}, usageError{fmt.Errorf("the %s download names no SHA-512 after a #", name)}
		}
		raw, sum := download[:at], download[at+1:]
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "https" || u.Host == "" {
			return program{}, usageError{fmt.Errorf("the %s download %q is no https URL", name, raw)}
		}
		if !sumPattern.MatchString(sum) {
			return program{}, usageError{fmt.Errorf("the %s download's SHA-512 is not 128 hex digits", name)}
		}
		if _, seen := pins[name]; seen {
			return program{}, usageError{fmt.Errorf("the architecture %s is given twice", name)}
		}
		pins[name] = pin{raw, strings.ToLower(sum)}
	}
	if len(pins) == 0 {
		return program{}, usageError{errors.New("no download is given")}
	}
	chosen, ok := pins[arch]
	if !ok {
		return program{}, usageError{fmt.Errorf("%s %s has no download for this machine's architecture, %s", p.name, p.version, arch)}
	}
	p.url, p.sum = chosen.url, chosen.sum
	return p, nil
}

// fetcher fetches programs over client within the bounds, saying what it
// fetches on notice.
type fetcher struct {
	client      *http.Client
	notice      io.Writer
	maxDownload int64
	maxProgram  int64
}

// install is the path of p's program in home, fetched there first when it
// is not installed yet.
func (f fetcher) install(home string, p program) (string, error) {
	dir := filepath.Join(home, ".local", "share", "cyfr", "programs", p.name, p.version)
	path := filepath.Join(dir, p.name)
	if installed(path) {
		return path, nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("the folder for %s %s cannot be made: %w", p.name, p.version, err)
	}
	// The lock makes the sweep below safe: every temporary file in the
	// folder belongs to a run that no longer holds it, and so has died.
	lock, err := os.Open(dir)
	if err != nil {
		return "", err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return "", fmt.Errorf("the folder for %s %s cannot be locked: %w", p.name, p.version, err)
	}
	if installed(path) {
		return path, nil
	}
	if err := sweep(dir); err != nil {
		return "", err
	}
	fmt.Fprintf(f.notice, "cyfr-fetch: fetching %s %s\n", p.name, p.version)
	download, err := f.download(dir, p)
	if err != nil {
		return "", err
	}
	defer os.Remove(download)
	staged := download
	if u, _ := url.Parse(p.url); strings.HasSuffix(u.Path, ".tar.gz") || strings.HasSuffix(u.Path, ".tgz") {
		if staged, err = f.extract(dir, download, p); err != nil {
			return "", err
		}
		defer os.Remove(staged)
	} else if info, err := os.Stat(download); err != nil {
		return "", err
	} else if info.Size() > f.maxProgram {
		return "", fmt.Errorf("%s %s is larger than %d bytes, so nothing was installed", p.name, p.version, f.maxProgram)
	}
	if err := os.Chmod(staged, 0o755); err != nil {
		return "", err
	}
	if err := os.Rename(staged, path); err != nil {
		return "", fmt.Errorf("%s %s cannot be put in place: %w", p.name, p.version, err)
	}
	return path, nil
}

func installed(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}

// sweep removes the temporary files an interrupted run left in dir.
func sweep(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), tempPrefix) {
			if err := os.Remove(filepath.Join(dir, e.Name())); err != nil && !errors.Is(err, fs.ErrNotExist) {
				return err
			}
		}
	}
	return nil
}

// download is a temporary file in dir holding p's download, which matched
// its SHA-512.
func (f fetcher) download(dir string, p program) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), fetchTimeout)
	defer cancel()
	client := *f.client
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if req.URL.Scheme != "https" {
			return fmt.Errorf("a redirect to %s, which is not https", req.URL.Redacted())
		}
		if len(via) >= 10 {
			return errors.New("more than 10 redirects")
		}
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.url, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("fetching %s %s failed, so nothing was installed: %w", p.name, p.version, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("fetching %s %s was answered %s, so nothing was installed", p.name, p.version, resp.Status)
	}
	tmp, err := os.CreateTemp(dir, tempPrefix+"*")
	if err != nil {
		return "", err
	}
	kept := false
	defer func() {
		if !kept {
			_ = tmp.Close()
			_ = os.Remove(tmp.Name())
		}
	}()
	hash := sha512.New()
	n, err := io.Copy(io.MultiWriter(tmp, hash), io.LimitReader(resp.Body, f.maxDownload+1))
	if err != nil {
		return "", fmt.Errorf("fetching %s %s broke off, so nothing was installed: %w", p.name, p.version, err)
	}
	if n > f.maxDownload {
		return "", fmt.Errorf("the download of %s %s is larger than %d bytes, so nothing was installed", p.name, p.version, f.maxDownload)
	}
	if hex.EncodeToString(hash.Sum(nil)) != p.sum {
		return "", fmt.Errorf("the download of %s %s failed its checksum, so nothing was installed", p.name, p.version)
	}
	if err := tmp.Sync(); err != nil {
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	kept = true
	return tmp.Name(), nil
}

// extract is a temporary file in dir holding the one regular file of the
// tar.gz archive at archive.
func (f fetcher) extract(dir, archive string, p program) (string, error) {
	in, err := os.Open(archive)
	if err != nil {
		return "", err
	}
	defer in.Close()
	refused := func(why string) error {
		return fmt.Errorf("the download of %s %s %s, so nothing was installed", p.name, p.version, why)
	}
	gz, err := gzip.NewReader(in)
	if err != nil {
		return "", refused("is no gzip archive")
	}
	tr := tar.NewReader(gz)
	header, err := tr.Next()
	switch {
	case errors.Is(err, io.EOF):
		return "", refused("holds no file")
	case err != nil:
		return "", refused("does not read as a tar archive")
	case header.Typeflag != tar.TypeReg:
		return "", refused(fmt.Sprintf("holds %q, which is not a regular file", header.Name))
	case header.Size > f.maxProgram:
		return "", refused(fmt.Sprintf("holds a program larger than %d bytes", f.maxProgram))
	}
	out, err := os.CreateTemp(dir, tempPrefix+"*")
	if err != nil {
		return "", err
	}
	kept := false
	defer func() {
		if !kept {
			_ = out.Close()
			_ = os.Remove(out.Name())
		}
	}()
	if _, err := io.Copy(out, io.LimitReader(tr, f.maxProgram)); err != nil {
		return "", refused("does not read as a tar archive")
	}
	switch _, err := tr.Next(); {
	case err == nil:
		return "", refused("holds more than one entry")
	case !errors.Is(err, io.EOF):
		return "", refused("does not read as a tar archive")
	}
	if err := out.Sync(); err != nil {
		return "", err
	}
	if err := out.Close(); err != nil {
		return "", err
	}
	kept = true
	return out.Name(), nil
}

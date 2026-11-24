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
// The program lives at
// $HOME/.local/share/cyfr/programs/NAME/VERSION-SHA512/NAME: the version
// folder is named by the version and the download's whole SHA-512, so a
// row whose checksum changes names another folder, and its program is
// fetched and checked anew. The whole hash and not a prefix of it, so the
// folder names the pin exactly, and a name of at most 193 bytes fits a
// file name's 255. Every folder from $HOME/.local down to the version
// folder is made 0700 when missing and opened by its name in the last,
// never through a link, and must be a folder of this user's own
// (internal/homepath); one that is not is refused, and nothing is fetched,
// written or run. The program must be a regular executable file and no link; when
// it is, it is run with no network, and when it is anything else it is
// refused. When it is missing the command takes an exclusive lock on the
// version folder, so a second first run waits and then runs what the
// first installed; removes the temporary files (`.fetch-…`) an
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
// The pin proves the download: the bytes fetched were the release its
// checksum names when they were installed. It proves nothing of the file
// later: the person's own processes may change it in their folder, and a
// run starts what is there.
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
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/cyfr/locus/keeper/internal/homepath"
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
// is not installed yet. Every folder on the way is reached by
// internal/homepath, opened by name in the last and never through a link.
func (f fetcher) install(home string, p program) (string, error) {
	dir, err := homepath.Root(home)
	if err != nil {
		return "", fmt.Errorf("the home folder (~) %w, so nothing was fetched or run", reason(err))
	}
	shown := "~"
	for _, step := range []struct{ name, role string }{
		{".local", "The home folder's .local folder"},
		{"share", "The .local/share folder"},
		{"cyfr", "CYFR's data folder"},
		{"programs", "CYFR's programs folder"},
		{p.name, "The folder of " + p.name},
		{p.version + "-" + p.sum, "The folder of " + p.name + " " + p.version},
	} {
		shown += "/" + step.name
		next, err := dir.Folder(step.name, true)
		dir.Close()
		if err != nil {
			return "", fmt.Errorf("%s (%s) %w, so nothing was fetched or run", step.role, shown, reason(err))
		}
		dir = next
	}
	defer dir.Close()
	path := filepath.Join(dir.Path(), p.name)
	if ok, err := installed(dir, p, shown); err != nil {
		return "", err
	} else if ok {
		return path, nil
	}
	// The lock makes the sweep below safe: every temporary file in the
	// folder belongs to a run that no longer holds it, and so has died.
	if err := syscall.Flock(int(dir.Fd()), syscall.LOCK_EX); err != nil {
		return "", fmt.Errorf("the folder of %s %s cannot be locked: %w", p.name, p.version, err)
	}
	if ok, err := installed(dir, p, shown); err != nil {
		return "", err
	} else if ok {
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
	defer dir.Remove(download)
	staged := download
	if u, _ := url.Parse(p.url); strings.HasSuffix(u.Path, ".tar.gz") || strings.HasSuffix(u.Path, ".tgz") {
		if staged, err = f.extract(dir, download, p); err != nil {
			return "", err
		}
		defer dir.Remove(staged)
	} else if info, err := dir.Lstat(download); err != nil {
		return "", err
	} else if info.Size > f.maxProgram {
		return "", fmt.Errorf("%s %s is larger than %d bytes, so nothing was installed", p.name, p.version, f.maxProgram)
	}
	program, err := dir.Open(staged, os.O_RDONLY, 0)
	if err != nil {
		return "", err
	}
	err = program.Chmod(0o755)
	program.Close()
	if err != nil {
		return "", err
	}
	if err := dir.Rename(staged, p.name); err != nil {
		return "", fmt.Errorf("%s %s cannot be put in place: %w", p.name, p.version, err)
	}
	return path, nil
}

// reason is what a folder on the way is, in the command's words.
func reason(err error) error {
	if homepath.Refused(err) {
		return homepath.ErrNotOwn
	}
	return fmt.Errorf("cannot be made or read (%w)", errors.Unwrap(err))
}

// installed is true when p's program is in place in dir, a regular
// executable file, and false when nothing is there; anything else there is
// refused. shown is its folder as the person reads it.
func installed(dir *homepath.Dir, p program, shown string) (bool, error) {
	info, err := dir.Lstat(p.name)
	switch {
	case homepath.Absent(err):
		return false, nil
	case err != nil:
		return false, err
	case info.Mode.IsRegular() && info.Mode.Perm()&0o111 != 0:
		return true, nil
	}
	return false, fmt.Errorf("the installed %s %s (%s/%s) is a link or not an executable file, so it is not run", p.name, p.version, shown, p.name)
}

// sweep removes the temporary files an interrupted run left in dir.
func sweep(dir *homepath.Dir) error {
	names, err := dir.Names()
	if err != nil {
		return err
	}
	for _, name := range names {
		if strings.HasPrefix(name, tempPrefix) {
			if err := dir.Remove(name); err != nil && !homepath.Absent(err) {
				return err
			}
		}
	}
	return nil
}

// download is a temporary file in dir, by its name, holding p's download,
// which matched its SHA-512.
func (f fetcher) download(dir *homepath.Dir, p program) (string, error) {
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
	tmp, name, err := dir.CreateTemp(tempPrefix)
	if err != nil {
		return "", err
	}
	kept := false
	defer func() {
		if !kept {
			_ = tmp.Close()
			_ = dir.Remove(name)
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
	return name, nil
}

// extract is a temporary file in dir, by its name, holding the one regular
// file of the tar.gz archive named archive there.
func (f fetcher) extract(dir *homepath.Dir, archive string, p program) (string, error) {
	in, err := dir.Open(archive, os.O_RDONLY, 0)
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
	out, name, err := dir.CreateTemp(tempPrefix)
	if err != nil {
		return "", err
	}
	kept := false
	defer func() {
		if !kept {
			_ = out.Close()
			_ = dir.Remove(name)
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
	return name, nil
}

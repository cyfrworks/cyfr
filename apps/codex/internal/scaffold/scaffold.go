// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package scaffold

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/release"
)

// The release assets the scaffold comes from, by version tag. They are
// variables so tests can point them at an httptest server.
var (
	urlTemplate      = "https://github.com/cyfrworks/cyfr/releases/download/%s/cyfr-scaffold.tar.gz"
	checksumTemplate = "https://github.com/cyfrworks/cyfr/releases/download/%s/checksums.txt"
)

const (
	maxFileSize    = 10 << 20 // 10 MB per file
	maxTarballSize = 64 << 20 // 64 MB whole tarball
	requestTimeout = 60 * time.Second
)

// Download fetches the scaffold tarball for the given version and extracts it
// into the current working directory. Files that already exist on disk are
// skipped (idempotent). Version "dev" or "" is a no-op.
func Download(version string) error {
	r, err := Fetch(version)
	if err != nil {
		return err
	}
	return r.Write(false)
}

// Release is a release's scaffold tarball, verified and read whole, with
// nothing of it written yet: `cyfr update` fetches it before the stack
// stops, snapshots the bytes of every file it manages (Managed), and
// writes it (Write(true)) only once the snapshot is complete.
type Release struct {
	entries []entry
}

// entry is one tarball entry kept: a directory, or a regular file and its
// bytes.
type entry struct {
	name string
	dir  bool
	mode os.FileMode
	data []byte
}

// Managed answers the managed files Write(true) overwrites or creates, in
// the tarball's order.
func (r *Release) Managed() []string {
	var names []string
	for _, e := range r.entries {
		if !e.dir && IsManaged(e.name) {
			names = append(names, e.name)
		}
	}
	return names
}

// Write extracts the release into the current working directory. When
// overwriteManaged is true, managed files are replaced with the tarball
// contents, each through a temporary file renamed over it, so a managed
// file is its old bytes or its new ones; other files retain the
// skip-if-exists behavior.
func (r *Release) Write(overwriteManaged bool) error {
	for _, e := range r.entries {
		if e.dir {
			if err := os.MkdirAll(e.name, 0755); err != nil {
				return fmt.Errorf("mkdir %s: %w", e.name, err)
			}
			continue
		}
		managed := overwriteManaged && IsManaged(e.name)
		// Skip non-managed files that already exist (idempotent).
		if !managed {
			if _, err := os.Stat(e.name); err == nil {
				continue
			}
		}
		if err := os.MkdirAll(filepath.Dir(e.name), 0755); err != nil {
			return fmt.Errorf("mkdir parent %s: %w", e.name, err)
		}
		if managed {
			if err := ReplaceFile(e.name, e.data, e.mode); err != nil {
				return fmt.Errorf("write %s: %w", e.name, err)
			}
			continue
		}
		f, err := os.OpenFile(e.name, os.O_CREATE|os.O_WRONLY|os.O_EXCL, e.mode)
		if err != nil {
			if os.IsExist(err) {
				continue // race: created between Stat and OpenFile
			}
			return fmt.Errorf("create %s: %w", e.name, err)
		}
		_, err = f.Write(e.data)
		if err = errors.Join(err, f.Close()); err != nil {
			return fmt.Errorf("write %s: %w", e.name, err)
		}
	}
	return nil
}

// ReplaceFile writes data over the file at name, mode, through a synced
// temporary file beside it renamed into place, so name holds its old
// bytes or data whole.
func ReplaceFile(name string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(name), "."+filepath.Base(name)+".scaffold-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(data)
	if err = errors.Join(err, tmp.Chmod(mode), tmp.Sync(), tmp.Close()); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), name)
}

// The AQUA files the scaffold ships and owns, so `cyfr update` refreshes
// them with each release: the soul at aqua/aqua.md, the shipped roles at
// aqua/roles/<name>.md, and every file under a shipped scroll's directory
// aqua/skills/<name>/. Each kind is an explicit roster of the names the
// seed tree ships, so a member's own aqua/roles/custom.md or
// aqua/skills/mine/SKILL.md matches neither and is preserved on update.
// TestBundledPromptsMatchSeed binds both rosters to the seed tree the
// tarball is packed from.
const aquaSoul = "aqua/aqua.md"

var shippedRoles = map[string]bool{
	"artisan":  true,
	"builder":  true,
	"explorer": true,
	"planner":  true,
	"web":      true,
}

var shippedScrolls = map[string]bool{
	"canvas":                 true,
	"capability-acquisition": true,
}

// isManagedAqua reports whether path is one of the AQUA files the scaffold
// ships: the soul, a shipped role, or a file inside a shipped scroll.
func isManagedAqua(path string) bool {
	if path == aquaSoul {
		return true
	}
	if rest, ok := strings.CutPrefix(path, "aqua/roles/"); ok {
		name, isMarkdown := strings.CutSuffix(rest, ".md")
		return isMarkdown && shippedRoles[name]
	}
	if rest, ok := strings.CutPrefix(path, "aqua/skills/"); ok {
		name, _, inside := strings.Cut(rest, "/")
		return inside && shippedScrolls[name]
	}
	return false
}

// SeccompProfile is the keeper's seccomp profile, which the locus-runtime service of
// docker-compose.yml names beside it. It follows the image it lets start,
// so `cyfr update`, which pulls the image, refreshes it too.
const SeccompProfile = "keeper.seccomp.json"

// Guides are the guides the scaffold tarball ships at a project's root
// (scripts/scaffold-tarball.sh's items), each managed, so `cyfr update`
// refreshes it. `cyfr init` and `cyfr update` name them from here, and
// TestShippedGuidesAreManaged binds the tarball's list and the repository's
// root guides to this one.
var Guides = []string{
	"configuration-guide.md",
	"component-guide.md",
	"tincture-guide.md",
	"integration-guide.md",
	"identity-guide.md",
	"devices-guide.md",
}

// IsManaged returns true for files that are maintained by cyfr and should be
// overwritten during an upgrade (guides, WIT interface definitions, the
// keeper's seccomp profile, and the shipped AQUA soul, roles and scrolls).
// It is the one policy for what `cyfr update` overwrites, snapshots and
// `cyfr restore` puts back.
func IsManaged(path string) bool {
	if path == SeccompProfile || slices.Contains(Guides, path) {
		return true
	}
	// Everything under wit/ is managed.
	if strings.HasPrefix(path, "wit/") || path == "wit" {
		return true
	}
	// The shipped AQUA files are managed; a member's own roles and scrolls
	// are preserved.
	return isManagedAqua(path)
}

// Fetch downloads the scaffold tarball for version and reads it whole,
// writing nothing. Every integrity failure — a checksums.txt that does not
// verify, a tarball that is not the one it names — wraps release.ErrUnverified; only a download that fails is a
// transport error. Version "dev" or "" answers an empty release.
func Fetch(version string) (*Release, error) {
	if version == "dev" || version == "" {
		return &Release{}, nil
	}

	url := fmt.Sprintf(urlTemplate, version)

	client := &http.Client{Timeout: requestTimeout}

	// The tarball carries docker-compose.yml, which names the images `cyfr
	// up` will pull and run (cyfr, cyfr-locus and caddy) — verify it
	// against the release's checksums.txt, itself verified as signed by
	// the release workflow for this version, before downloading or
	// extracting a byte of it. `cyfr upgrade` verifies the CLI's archive
	// the same way (release.FetchBinary).
	want, err := fetchScaffoldChecksum(client, version)
	if err != nil {
		return nil, err
	}

	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("download scaffold: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download scaffold: HTTP %d from %s", resp.StatusCode, url)
	}

	tarball, err := io.ReadAll(io.LimitReader(resp.Body, maxTarballSize+1))
	if err != nil {
		return nil, fmt.Errorf("download scaffold: %w", err)
	}
	if len(tarball) > maxTarballSize {
		// Larger than any scaffold a release ships, so not the one its
		// signed checksums.txt names.
		return nil, fmt.Errorf("%w: the scaffold download exceeds the %d-byte limit", release.ErrUnverified, int64(maxTarballSize))
	}

	got := sha256.Sum256(tarball)
	if hex.EncodeToString(got[:]) != want {
		return nil, fmt.Errorf("%w: scaffold checksum mismatch for %s: the download does not match the release's signed checksums.txt", release.ErrUnverified, version)
	}

	gr, err := gzip.NewReader(bytes.NewReader(tarball))
	if err != nil {
		return nil, fmt.Errorf("decompress scaffold: %w", err)
	}
	defer gr.Close()

	r := &Release{}
	tr := tar.NewReader(gr)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read scaffold tar: %w", err)
		}

		name := filepath.Clean(hdr.Name)

		// Path traversal protection: reject absolute paths and ".." components.
		if filepath.IsAbs(name) || strings.HasPrefix(name, "..") || strings.Contains(name, string(filepath.Separator)+"..") {
			continue
		}

		switch hdr.Typeflag {
		case tar.TypeDir:
			r.entries = append(r.entries, entry{name: name, dir: true})

		case tar.TypeReg:
			data, err := io.ReadAll(io.LimitReader(tr, maxFileSize+1))
			if err != nil {
				return nil, fmt.Errorf("read %s: %w", name, err)
			}
			if len(data) > maxFileSize {
				return nil, fmt.Errorf("%s exceeds the %d-byte scaffold file limit", name, int64(maxFileSize))
			}
			r.entries = append(r.entries, entry{name: name, mode: os.FileMode(hdr.Mode)&0755 | 0644, data: data})
		}
	}

	return r, nil
}

// fetchScaffoldChecksum answers the sha256 (hex) the release's signed
// checksums.txt names for cyfr-scaffold.tar.gz (release.VerifiedChecksum).
// A release without an entry fails closed as unverified — the CLI and the
// release ship in lockstep, so a missing line means a broken release, never
// an older layout to tolerate.
func fetchScaffoldChecksum(client *http.Client, version string) (string, error) {
	return release.VerifiedChecksum(context.Background(), client, fmt.Sprintf(checksumTemplate, version), version, "cyfr-scaffold.tar.gz")
}

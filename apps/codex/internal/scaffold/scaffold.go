// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package scaffold

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	urlTemplate      = "https://github.com/cyfrworks/cyfr/releases/download/%s/cyfr-scaffold.tar.gz"
	checksumTemplate = "https://github.com/cyfrworks/cyfr/releases/download/%s/checksums.txt"
	maxFileSize      = 10 << 20 // 10 MB per file
	maxTarballSize   = 64 << 20 // 64 MB whole tarball
	requestTimeout   = 60 * time.Second
)

// Download fetches the scaffold tarball for the given version and extracts it
// into the current working directory. Files that already exist on disk are
// skipped (idempotent). Version "dev" or "" is a no-op.
func Download(version string) error {
	return extract(version, false)
}

// Update fetches the scaffold tarball for the given version and extracts it
// into the current working directory. Managed files (guides, wit/
// definitions, the shipped AQUA soul, roles and scrolls) are overwritten
// with the latest content. Component files that already exist are skipped;
// new components are created. Version "dev" or "" is a no-op.
func Update(version string) error {
	return extract(version, true)
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

// isManaged returns true for files that are maintained by cyfr and should be
// overwritten during an upgrade (guides, WIT interface definitions, and the
// shipped AQUA soul, roles and scrolls).
func isManaged(path string) bool {
	switch path {
	case "component-guide.md", "tincture-guide.md", "integration-guide.md":
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

// extract fetches the scaffold tarball and extracts it. When overwriteManaged
// is true, managed files are replaced with the tarball contents; other files
// retain the existing skip-if-exists behavior.
func extract(version string, overwriteManaged bool) error {
	if version == "dev" || version == "" {
		return nil
	}

	url := fmt.Sprintf(urlTemplate, version)

	client := &http.Client{Timeout: requestTimeout}

	// The tarball carries docker-compose.yml, Dockerfile.node and the bridge
	// source that `cyfr up` will build and run — verify it against the
	// release's cosign-signed checksums.txt before extracting a byte. The
	// release binary itself gets the same treatment from install.sh.
	want, err := fetchScaffoldChecksum(client, version)
	if err != nil {
		return err
	}

	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("download scaffold: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download scaffold: HTTP %d from %s", resp.StatusCode, url)
	}

	tarball, err := io.ReadAll(io.LimitReader(resp.Body, maxTarballSize+1))
	if err != nil {
		return fmt.Errorf("download scaffold: %w", err)
	}
	if len(tarball) > maxTarballSize {
		return fmt.Errorf("download scaffold: exceeds the %d-byte limit", int64(maxTarballSize))
	}

	got := sha256.Sum256(tarball)
	if hex.EncodeToString(got[:]) != want {
		return fmt.Errorf("scaffold checksum mismatch for %s: the download does not match the release's checksums.txt", version)
	}

	gr, err := gzip.NewReader(bytes.NewReader(tarball))
	if err != nil {
		return fmt.Errorf("decompress scaffold: %w", err)
	}
	defer gr.Close()

	tr := tar.NewReader(gr)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("read scaffold tar: %w", err)
		}

		name := filepath.Clean(hdr.Name)

		// Path traversal protection: reject absolute paths and ".." components.
		if filepath.IsAbs(name) || strings.HasPrefix(name, "..") || strings.Contains(name, string(filepath.Separator)+"..") {
			continue
		}

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(name, 0755); err != nil {
				return fmt.Errorf("mkdir %s: %w", name, err)
			}

		case tar.TypeReg:
			managed := overwriteManaged && isManaged(name)

			// Skip non-managed files that already exist (idempotent).
			if !managed {
				if _, err := os.Stat(name); err == nil {
					continue
				}
			}

			if err := os.MkdirAll(filepath.Dir(name), 0755); err != nil {
				return fmt.Errorf("mkdir parent %s: %w", name, err)
			}

			var flags int
			if managed {
				flags = os.O_CREATE | os.O_WRONLY | os.O_TRUNC
			} else {
				flags = os.O_CREATE | os.O_WRONLY | os.O_EXCL
			}

			f, err := os.OpenFile(name, flags, os.FileMode(hdr.Mode)&0755|0644)
			if err != nil {
				if os.IsExist(err) {
					continue // race: created between Stat and OpenFile
				}
				return fmt.Errorf("create %s: %w", name, err)
			}

			written, err := io.Copy(f, io.LimitReader(tr, maxFileSize+1))
			if err != nil {
				f.Close()
				return fmt.Errorf("write %s: %w", name, err)
			}
			if written > maxFileSize {
				f.Close()
				return fmt.Errorf("%s exceeds the %d-byte scaffold file limit", name, int64(maxFileSize))
			}
			f.Close()
		}
	}

	return nil
}

// fetchScaffoldChecksum reads the release's checksums.txt and returns the
// expected sha256 (hex) for cyfr-scaffold.tar.gz. A release without an
// entry fails closed — the CLI and the release ship in lockstep, so a
// missing line means a broken release, never an older layout to tolerate.
func fetchScaffoldChecksum(client *http.Client, version string) (string, error) {
	url := fmt.Sprintf(checksumTemplate, version)

	resp, err := client.Get(url)
	if err != nil {
		return "", fmt.Errorf("download checksums.txt: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download checksums.txt: HTTP %d from %s", resp.StatusCode, url)
	}

	scanner := bufio.NewScanner(io.LimitReader(resp.Body, 1<<20))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 2 && filepath.Base(fields[1]) == "cyfr-scaffold.tar.gz" {
			return strings.ToLower(fields[0]), nil
		}
	}
	if err := scanner.Err(); err != nil {
		return "", fmt.Errorf("read checksums.txt: %w", err)
	}

	return "", fmt.Errorf("checksums.txt for %s has no cyfr-scaffold.tar.gz entry", version)
}

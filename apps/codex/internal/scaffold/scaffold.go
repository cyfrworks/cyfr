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
// into the current working directory. Managed files (docs, wit/ definitions)
// are overwritten with the latest content. Component files that already exist
// are skipped; new components are created. Version "dev" or "" is a no-op.
func Update(version string) error {
	return extract(version, true)
}

// bundledAquaPrompts is the set of aqua/ prompt files we ship and own. These
// get overwritten on `cyfr update` so users receive improvements to the default
// agent prompts.
//
// Important: aqua/agent.json is NOT in this list — once init writes it, the
// user owns it (e.g. they may add custom agents via `aqua create` (with
// type=orchestrator) which mutates agent.json). User-created prompt files
// (e.g. aqua_custom.md) are also preserved because they're not in this list.
var bundledAquaPrompts = map[string]bool{
	"aqua/aqua.md":          true,
	"aqua/aqua_builder.md":  true,
	"aqua/aqua_artisan.md":  true,
	"aqua/aqua_arcade.md":   true,
	"aqua/aqua_explorer.md": true,
	"aqua/aqua_planner.md":  true,
	"aqua/aqua_web.md":      true,
}

// isManaged returns true for files that are maintained by cyfr and should be
// overwritten during an upgrade (docs, WIT interface definitions, bundled
// aqua prompt files).
func isManaged(path string) bool {
	switch path {
	case "component-guide.md", "tincture-guide.md", "integration-guide.md":
		return true
	}
	// Everything under wit/ is managed.
	if strings.HasPrefix(path, "wit/") || path == "wit" {
		return true
	}
	// Specific bundled aqua prompts are managed; agent.json and any
	// user-created prompts are preserved.
	if bundledAquaPrompts[path] {
		return true
	}
	return false
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

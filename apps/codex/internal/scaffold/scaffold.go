package scaffold

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	urlTemplate    = "https://github.com/cyfrworks/cyfr/releases/download/v%s/cyfr-scaffold.tar.gz"
	maxFileSize    = 10 << 20 // 10 MB per file
	requestTimeout = 60 * time.Second
)

// Download fetches the scaffold tarball for the given version and extracts it
// into the current working directory. Files that already exist on disk are
// skipped (idempotent). Version "dev" or "" is a no-op.
func Download(version string) error {
	if version == "dev" || version == "" {
		return nil
	}

	url := fmt.Sprintf(urlTemplate, version)

	client := &http.Client{Timeout: requestTimeout}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("download scaffold: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download scaffold: HTTP %d from %s", resp.StatusCode, url)
	}

	gr, err := gzip.NewReader(resp.Body)
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
			// Skip files that already exist (idempotent).
			if _, err := os.Stat(name); err == nil {
				continue
			}

			if err := os.MkdirAll(filepath.Dir(name), 0755); err != nil {
				return fmt.Errorf("mkdir parent %s: %w", name, err)
			}

			f, err := os.OpenFile(name, os.O_CREATE|os.O_WRONLY|os.O_EXCL, os.FileMode(hdr.Mode)&0755|0644)
			if err != nil {
				if os.IsExist(err) {
					continue // race: created between Stat and OpenFile
				}
				return fmt.Errorf("create %s: %w", name, err)
			}

			if _, err := io.Copy(f, io.LimitReader(tr, maxFileSize)); err != nil {
				f.Close()
				return fmt.Errorf("write %s: %w", name, err)
			}
			f.Close()
		}
	}

	// Ensure component subdirs exist even when tarball has no reagent examples yet.
	_ = os.MkdirAll("components/reagents/local", 0755)

	return nil
}

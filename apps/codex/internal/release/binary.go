// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package release

import (
	"archive/tar"
	"archive/zip"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path"
	"strings"
)

const (
	// ChecksumsURLTemplate is the release's checksums.txt, by version tag;
	// its sigstore bundle is the same URL with BundleSuffix appended.
	ChecksumsURLTemplate = "https://github.com/cyfrworks/cyfr/releases/download/%s/checksums.txt"
	// assetURLTemplate is a release asset, by version tag and file name.
	assetURLTemplate = "https://github.com/cyfrworks/cyfr/releases/download/%s/%s"

	// maxChecksumsSize bounds checksums.txt and its bundle, each.
	maxChecksumsSize = 1 << 20
	// maxArchiveSize bounds a CLI archive as downloaded and maxBinarySize
	// the binary it holds, each far above what a release ships.
	maxArchiveSize = 256 << 20
	maxBinarySize  = 512 << 20
)

// checksumsURLTemplate and binaryURLTemplate are the URLs FetchBinary
// reads, variables so tests can point them at an httptest server.
var (
	checksumsURLTemplate = ChecksumsURLTemplate
	binaryURLTemplate    = assetURLTemplate
)

// VerifiedChecksum reads the checksums.txt at checksumsURL and its bundle,
// verifies the bundle as the release workflow's keyless signature for
// version under TrustMaterial (VerifyBlob), and only then answers the
// sha256 (lower-case hex) the verified bytes name for the asset file
// name. A checksums.txt that does not verify, and one without a line for
// asset, refuse with an error wrapping ErrUnverified; a download that
// fails is a transport error.
func VerifiedChecksum(ctx context.Context, client *http.Client, checksumsURL, version, asset string) (string, error) {
	checksums, err := FetchBounded(ctx, client, checksumsURL, maxChecksumsSize)
	if err != nil {
		return "", fmt.Errorf("checksums.txt: %w", err)
	}
	bundle, err := FetchBounded(ctx, client, checksumsURL+BundleSuffix, maxChecksumsSize)
	if err != nil {
		return "", fmt.Errorf("checksums.txt's signature: %w", err)
	}
	trusted, err := TrustMaterial(ctx)
	if err != nil {
		return "", err
	}
	if err := VerifyBlob(checksums, bundle, version, trusted); err != nil {
		return "", fmt.Errorf("checksums.txt for %s: %w", version, err)
	}
	scanner := bufio.NewScanner(bytes.NewReader(checksums))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 2 && path.Base(fields[1]) == asset {
			return strings.ToLower(fields[0]), nil
		}
	}
	if err := scanner.Err(); err != nil {
		return "", fmt.Errorf("read checksums.txt: %w", err)
	}
	return "", fmt.Errorf("%w: the signed checksums.txt for %s has no %s entry", ErrUnverified, version, asset)
}

// ArchiveName is the CLI archive the release ships for a platform, as
// .goreleaser.yml's archives name it: a zip for Windows, else a gzipped
// tar.
func ArchiveName(version, goos, goarch string) string {
	ext := "tar.gz"
	if goos == "windows" {
		ext = "zip"
	}
	return fmt.Sprintf("cyfr_%s_%s_%s.%s", version, goos, goarch, ext)
}

// BinaryName is the CLI's file name in its archive on goos.
func BinaryName(goos string) string {
	if goos == "windows" {
		return "cyfr.exe"
	}
	return "cyfr"
}

// FetchBinary downloads release version's CLI archive for goos/goarch and
// answers the binary it holds. The archive's sha256 is compared with the
// line of the release's checksums.txt that VerifiedChecksum answers, so
// nothing of the archive is read before checksums.txt verifies as the
// release workflow's signature for version and the archive is the file it
// names. Every integrity failure wraps ErrUnverified; a download that
// fails is a transport error.
func FetchBinary(ctx context.Context, version, goos, goarch string) ([]byte, error) {
	if !IsVersion(version) {
		return nil, fmt.Errorf("%w: %q is not a release version (MAJOR.MINOR.PATCH, or with a pre-release)", ErrUnverified, version)
	}
	client := &http.Client{}
	archive := ArchiveName(version, goos, goarch)
	want, err := VerifiedChecksum(ctx, client, fmt.Sprintf(checksumsURLTemplate, version), version, archive)
	if err != nil {
		return nil, err
	}
	data, err := FetchBounded(ctx, client, fmt.Sprintf(binaryURLTemplate, version, archive), maxArchiveSize)
	if err != nil {
		return nil, err
	}
	if got := sha256.Sum256(data); hex.EncodeToString(got[:]) != want {
		return nil, fmt.Errorf("%w: %s does not match the release's signed checksums.txt", ErrUnverified, archive)
	}
	binary, err := extractBinary(data, goos)
	if err != nil {
		return nil, fmt.Errorf("%w: %s: %v", ErrUnverified, archive, err)
	}
	return binary, nil
}

// extractBinary answers the regular file named BinaryName(goos) at the top
// of the archive, bounded by maxBinarySize.
func extractBinary(data []byte, goos string) ([]byte, error) {
	name := BinaryName(goos)
	read := func(r io.Reader) ([]byte, error) {
		body, err := io.ReadAll(io.LimitReader(r, maxBinarySize+1))
		if err != nil {
			return nil, err
		}
		if len(body) > maxBinarySize {
			return nil, fmt.Errorf("%s exceeds the %d-byte limit", name, int64(maxBinarySize))
		}
		if len(body) == 0 {
			return nil, fmt.Errorf("%s is empty", name)
		}
		return body, nil
	}
	if goos == "windows" {
		zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
		if err != nil {
			return nil, err
		}
		for _, f := range zr.File {
			if f.Name == name && f.Mode().IsRegular() {
				rc, err := f.Open()
				if err != nil {
					return nil, err
				}
				defer rc.Close()
				return read(rc)
			}
		}
		return nil, fmt.Errorf("it holds no %s", name)
	}
	gz, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil, fmt.Errorf("it holds no %s", name)
		}
		if err != nil {
			return nil, err
		}
		if strings.TrimPrefix(hdr.Name, "./") == name && hdr.Typeflag == tar.TypeReg {
			return read(tr)
		}
	}
}

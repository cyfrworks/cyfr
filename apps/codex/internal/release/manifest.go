// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package release

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"time"

	"github.com/sigstore/sigstore-go/pkg/bundle"
	"github.com/sigstore/sigstore-go/pkg/root"
	"github.com/sigstore/sigstore-go/pkg/tuf"
	"github.com/sigstore/sigstore-go/pkg/verify"
	"github.com/theupdateframework/go-tuf/v2/metadata/fetcher"
)

const (
	// ManifestURLTemplate is the release's manifest, by version tag; its
	// sigstore bundle is the same URL with BundleSuffix appended.
	ManifestURLTemplate = "https://github.com/cyfrworks/cyfr/releases/download/%s/release.json"
	// BundleSuffix names a signed file's sigstore bundle beside it.
	BundleSuffix = ".sigstore.json"
	// Issuer is the OIDC issuer of the release workflow's keyless identity.
	Issuer = "https://token.actions.githubusercontent.com"
	// identityTemplate is the release workflow's certificate identity for a
	// version tag.
	identityTemplate = "https://github.com/cyfrworks/cyfr/.github/workflows/release.yml@refs/tags/%s"
)

// The repositories the manifest's three digests are for, as a compose
// image line names them once normalized (docker.io/library/ for an
// official image).
const (
	RepoCyfr      = "ghcr.io/cyfrworks/cyfr"
	RepoCyfrLocus = "ghcr.io/cyfrworks/cyfr-locus"
	RepoCaddy     = "docker.io/library/caddy"
)

// ErrUnverified marks every refusal of a release file's authenticity: an
// unsigned or wrongly signed file, another identity or issuer, another
// version, a malformed manifest, a download that is not the file a signed
// one names. A transport failure is not wrapped in it.
var ErrUnverified = errors.New("release not verified")

// Images holds each shipped image's digest, `sha256:` and 64 hex digits.
type Images struct {
	Cyfr      string `json:"cyfr"`
	CyfrLocus string `json:"cyfr_locus"`
	Caddy     string `json:"caddy"`
}

// Manifest is a release's `release.json`. `cyfr update` reads its images;
// its Scaffold digest is not compared when the scaffold downloads, because
// the scaffold is verified against the release's checksums.txt, signed on
// its own by the same workflow identity and verified before a byte of the
// tarball is read (internal/scaffold), which `cyfr init` relies on too
// without a manifest.
type Manifest struct {
	Version  string `json:"version"`
	Images   Images `json:"images"`
	Scaffold string `json:"scaffold"`
}

// Identity is the certificate identity the release workflow signs under for
// the tag version.
func Identity(version string) string { return fmt.Sprintf(identityTemplate, version) }

// Digest answers the manifest's digest for repo (one of the Repo constants).
func (m *Manifest) Digest(repo string) (string, bool) {
	switch repo {
	case RepoCyfr:
		return m.Images.Cyfr, true
	case RepoCyfrLocus:
		return m.Images.CyfrLocus, true
	case RepoCaddy:
		return m.Images.Caddy, true
	}
	return "", false
}

// digestPattern is the one digest form the manifest carries: a lower-case
// sha256, so a digest compares byte for byte with the one a registry
// reports.
var digestPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// ParseManifest reads data as a release manifest of exactly its shape: the
// keys version, images and scaffold, images holding exactly cyfr, cyfr_locus
// and caddy, every value a string, the version a bare MAJOR.MINOR.PATCH and
// every digest `sha256:` and 64 lower-case hex digits. Keys match exactly
// (encoding/json's case-folding does not apply), and a missing, unknown or
// repeated key, a null, another type or anything after the object refuses.
func ParseManifest(data []byte) (*Manifest, error) {
	top, err := strictObject(data, "version", "images", "scaffold")
	if err != nil {
		return nil, fmt.Errorf("%w: release.json: %v", ErrUnverified, err)
	}
	images, err := strictObject(top["images"], "cyfr", "cyfr_locus", "caddy")
	if err != nil {
		return nil, fmt.Errorf("%w: release.json images: %v", ErrUnverified, err)
	}

	var m Manifest
	fields := []struct {
		name string
		raw  json.RawMessage
		into *string
	}{
		{"version", top["version"], &m.Version},
		{"scaffold", top["scaffold"], &m.Scaffold},
		{"images.cyfr", images["cyfr"], &m.Images.Cyfr},
		{"images.cyfr_locus", images["cyfr_locus"], &m.Images.CyfrLocus},
		{"images.caddy", images["caddy"], &m.Images.Caddy},
	}
	for _, f := range fields {
		if !bytes.HasPrefix(f.raw, []byte(`"`)) {
			return nil, fmt.Errorf("%w: release.json %s is not a string", ErrUnverified, f.name)
		}
		if err := json.Unmarshal(f.raw, f.into); err != nil {
			return nil, fmt.Errorf("%w: release.json %s: %v", ErrUnverified, f.name, err)
		}
	}

	if !bareSemver.MatchString(m.Version) {
		return nil, fmt.Errorf("%w: release.json version %q is not a bare MAJOR.MINOR.PATCH", ErrUnverified, m.Version)
	}
	for _, f := range fields[1:] {
		if !digestPattern.MatchString(*f.into) {
			return nil, fmt.Errorf("%w: release.json %s %q is not sha256: and 64 lower-case hex digits", ErrUnverified, f.name, *f.into)
		}
	}
	return &m, nil
}

// strictObject reads data as one JSON object holding exactly the keys
// named, each once, and nothing after it, and answers each key's raw value.
func strictObject(data []byte, keys ...string) (map[string]json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if delim, ok := tok.(json.Delim); !ok || delim != '{' {
		return nil, errors.New("not an object")
	}
	want := make(map[string]bool, len(keys))
	for _, k := range keys {
		want[k] = true
	}
	out := make(map[string]json.RawMessage, len(keys))
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, _ := tok.(string)
		if !want[key] {
			return nil, fmt.Errorf("unknown key %q", key)
		}
		if _, seen := out[key]; seen {
			return nil, fmt.Errorf("key %q repeated", key)
		}
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return nil, err
		}
		out[key] = raw
	}
	if _, err := dec.Token(); err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("data after the object")
	}
	for _, k := range keys {
		if _, ok := out[k]; !ok {
			return nil, fmt.Errorf("key %q missing", k)
		}
	}
	return out, nil
}

// TrustMaterial is the sigstore trust root verification runs under. The
// production value is the public-good instance's trusted root, fetched
// through sigstore-go's TUF client from the TUF root embedded in this
// binary and cached under the user's home. Tests replace the variable;
// nothing a release download carries ever becomes trust material.
//
// The TUF client's default fetcher uses http.DefaultClient, which has no
// timeout and ignores ctx, so the fetcher here gets a client bounded by
// fetchTimeout whose every request carries ctx.
var TrustMaterial = func(ctx context.Context) (root.TrustedMaterial, error) {
	opts := tuf.DefaultOptions()
	f := fetcher.NewDefaultFetcher()
	f.SetHTTPClient(&http.Client{Timeout: fetchTimeout, Transport: contextTransport{ctx}})
	opts.Fetcher = f
	trusted, err := root.FetchTrustedRootWithOptions(opts)
	if err != nil {
		return nil, fmt.Errorf("fetch the Sigstore trusted root: %w", err)
	}
	return trusted, nil
}

// contextTransport sends each request under ctx, so cancelling the caller's
// context stops a fetch whose request was built without it.
type contextTransport struct{ ctx context.Context }

func (t contextTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	return http.DefaultTransport.RoundTrip(req.WithContext(t.ctx))
}

// VerifyBlob verifies bundleJSON as the release workflow's keyless
// signature over artifact for the tag version: the certificate's subject
// alternative name is exactly Identity(version) and its OIDC issuer exactly
// Issuer, it chains to trusted's Fulcio CA and carries an SCT from one of
// its CT logs, and the signature is in one of its transparency logs and was
// observed (an integrated or RFC 3161 timestamp) while the certificate was
// valid. Trust comes from trusted alone, never from the bundle.
func VerifyBlob(artifact, bundleJSON []byte, version string, trusted root.TrustedMaterial) error {
	if !bareSemver.MatchString(version) {
		return fmt.Errorf("%w: %q is not a release version (MAJOR.MINOR.PATCH)", ErrUnverified, version)
	}
	if trusted == nil {
		return fmt.Errorf("%w: no trust material", ErrUnverified)
	}

	var b bundle.Bundle
	if err := b.UnmarshalJSON(bundleJSON); err != nil {
		return fmt.Errorf("%w: the signature bundle: %w", ErrUnverified, err)
	}

	identity, err := verify.NewShortCertificateIdentity(Issuer, "", Identity(version), "")
	if err != nil {
		return fmt.Errorf("%w: %w", ErrUnverified, err)
	}
	verifier, err := verify.NewVerifier(trusted,
		verify.WithTransparencyLog(1),
		verify.WithObserverTimestamps(1),
		verify.WithSignedCertificateTimestamps(1),
	)
	if err != nil {
		return fmt.Errorf("%w: %w", ErrUnverified, err)
	}
	policy := verify.NewPolicy(
		verify.WithArtifact(bytes.NewReader(artifact)),
		verify.WithCertificateIdentity(identity),
	)
	if _, err := verifier.Verify(&b, policy); err != nil {
		return fmt.Errorf("%w: not signed by the release workflow for %s: %w", ErrUnverified, version, err)
	}
	return nil
}

// VerifyManifest verifies data's bundle, parses it and refuses a manifest
// of another version than version.
func VerifyManifest(data, bundleJSON []byte, version string, trusted root.TrustedMaterial) (*Manifest, error) {
	if err := VerifyBlob(data, bundleJSON, version, trusted); err != nil {
		return nil, err
	}
	m, err := ParseManifest(data)
	if err != nil {
		return nil, err
	}
	if m.Version != version {
		return nil, fmt.Errorf("%w: the manifest is release %s, this CLI is release %s", ErrUnverified, m.Version, version)
	}
	return m, nil
}

const (
	// maxManifestSize bounds release.json and its bundle each; both are a
	// few kilobytes.
	maxManifestSize = 1 << 20
	fetchTimeout    = 60 * time.Second
)

// manifestURLTemplate is ManifestURLTemplate, a variable so tests can point
// it at an httptest server.
var manifestURLTemplate = ManifestURLTemplate

// FetchManifest downloads release.json and its bundle for version and
// answers it verified. A dev build has no release to fetch. A download
// that fails is a transport error naming its URL; everything about the
// bytes themselves refuses with ErrUnverified.
func FetchManifest(ctx context.Context, version string) (*Manifest, error) {
	if !bareSemver.MatchString(version) {
		return nil, fmt.Errorf("this CLI is version %q, not a release build, so it has no signed release manifest to update from", version)
	}
	client := &http.Client{Timeout: fetchTimeout}
	url := fmt.Sprintf(manifestURLTemplate, version)
	data, err := FetchBounded(ctx, client, url, maxManifestSize)
	if err != nil {
		return nil, err
	}
	bundleJSON, err := FetchBounded(ctx, client, url+BundleSuffix, maxManifestSize)
	if err != nil {
		return nil, err
	}
	trusted, err := TrustMaterial(ctx)
	if err != nil {
		return nil, err
	}
	return VerifyManifest(data, bundleJSON, version, trusted)
}

// FetchBounded GETs url and answers its body, refusing a status other
// than 200 and a body over limit bytes. Its errors name the URL and are
// transport errors, never ErrUnverified.
func FetchBounded(ctx context.Context, client *http.Client, url string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("download %s: %w", url, err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("download %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download %s: HTTP %d", url, resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, fmt.Errorf("download %s: %w", url, err)
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("download %s: exceeds the %d-byte limit", url, limit)
	}
	return body, nil
}

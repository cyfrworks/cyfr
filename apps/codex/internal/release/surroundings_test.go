// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package release

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/sigstore/sigstore-go/pkg/root"
)

// What fails around a release, not in it, never refuses the release's
// authenticity: the trust root that cannot be fetched, a host that refuses
// the connection, answers 503 or does not answer in time, and an
// installer's download cut off each answer an error that does not wrap
// ErrUnverified, which the app's update service answers as a release it
// cannot reach (its caller then takes the sudo road). A release fetched
// whole whose digest is not the signed one is ErrUnverified.
func TestTheSurroundingsOfAReleaseAreNotItsRefusal(t *testing.T) {
	const version = "0.9.0"
	asset := PackageName(version, "linux", "amd64")
	fetch := func(ctx context.Context) error {
		sum, err := PackageChecksum(ctx, version, "linux", "amd64")
		if err == nil {
			_, err = FetchPackage(ctx, version, "linux", "amd64", sum)
		}
		return err
	}
	for _, c := range []struct {
		name string
		set  func(t *testing.T, r *binaryRelease)
	}{
		{"the trust root cannot be fetched", func(t *testing.T, r *binaryRelease) {
			TrustMaterial = func(context.Context) (root.TrustedMaterial, error) {
				return nil, fmt.Errorf("fetch the Sigstore trusted root: %w", errors.New("dial tcp: lookup tuf-repo-cdn.sigstore.dev: no such host"))
			}
		}},
		{"the release's host refuses the connection", func(t *testing.T, r *binaryRelease) {
			gone := httptest.NewServer(http.NotFoundHandler())
			gone.Close()
			checksumsURLTemplate, downloadURLTemplate = gone.URL+"/%s/checksums.txt", gone.URL+"/%s/%s"
		}},
		{"the release's host answers 503", func(t *testing.T, r *binaryRelease) {
			busy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusServiceUnavailable)
			}))
			t.Cleanup(busy.Close)
			checksumsURLTemplate = busy.URL + "/%s/checksums.txt"
		}},
		{"the release's host does not answer in time", func(t *testing.T, r *binaryRelease) {
			slow := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, req *http.Request) {
				<-req.Context().Done()
			}))
			t.Cleanup(slow.Close)
			checksumsURLTemplate = slow.URL + "/%s/checksums.txt"
		}},
		{"the installer's download is cut off", func(t *testing.T, r *binaryRelease) {
			body := r.assets[asset]
			cut := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				w.Header().Set("Content-Length", strconv.Itoa(len(body)+100))
				_, _ = w.Write(body)
			}))
			t.Cleanup(cut.Close)
			downloadURLTemplate = cut.URL + "/%s/%s"
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := newBinaryRelease(t, version)
			r.serve(t)
			c.set(t, r)
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			err := fetch(ctx)
			if err == nil || errors.Is(err, ErrUnverified) {
				t.Errorf("answered %v, want an error that is not ErrUnverified", err)
			}
			t.Logf("answered %v", err)
		})
	}
	r := newBinaryRelease(t, version)
	r.assets[asset] = []byte("not the installer checksums.txt names")
	r.serve(t)
	if err := fetch(context.Background()); !errors.Is(err, ErrUnverified) {
		t.Errorf("a fetched installer that is not the signed one answered %v, want ErrUnverified", err)
	}
}

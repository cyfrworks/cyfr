// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

type reservedNameTransport struct{ base http.RoundTripper }

func (r reservedNameTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.URL.Path == "/v1/namespaces/personal/claim" {
		return &http.Response{StatusCode: 403, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"errors":[{"code":"RESERVED","message":"the handle is reserved"}]}`)), Request: req}, nil
	}
	return r.base.RoundTrip(req)
}

func TestSetup_AReservedNameOffersAnother(t *testing.T) {
	home := newFakeHome(t)
	b := newBox(t, home, t.TempDir())
	base := b.shell.cfg.Client.Transport
	if base == nil {
		base = http.DefaultTransport
	}
	b.shell.cfg.Client = &http.Client{Transport: reservedNameTransport{base: base}}
	b.setUp("adminx")
	b.post("/saved", nil)
	if page := b.page(); !strings.Contains(page, `action="/name"`) {
		b.post("/name", url.Values{"name": {"alice2"}})
		t.Fatalf("reserved name offers no rename; stored name after rename attempt=%q; page=%s", b.shell.making.attempt.Name, page)
	}
}

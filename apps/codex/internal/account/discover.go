// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// Discovered is the directory a CYFR names on its sign-in page: the URL
// whole, base path included, the origin its account pages are served at,
// and the host that is their passkeys' relying party.
type Discovered struct {
	Directory string
	Origin    string
	RPID      string
}

// Why a sign-in page names no directory the app can use
// (tests/fixtures/login_directory.json, pages[].refused).
var (
	ErrDirectoryMissing   = errors.New("missing")
	ErrDirectoryDuplicate = errors.New("duplicate")
	ErrDirectoryInvalid   = errors.New("invalid")
)

const directoryAttribute = "data-account-directory"

var directoryAttr = regexp.MustCompile(`\s` + directoryAttribute + `="([^"]*)"`)

// maxLoginPage bounds the sign-in page read: it is one server-rendered
// page.
const maxLoginPage = 1 << 20

// ReadDirectory reads the directory from a sign-in page's HTML: the one
// data-account-directory attribute, double-quoted and HTML-escaped as
// Prism renders it, holding an https directory URL. No attribute, more
// than one, or one in another form or naming anything else is refused.
func ReadDirectory(page []byte) (Discovered, error) {
	switch bytes.Count(page, []byte(directoryAttribute)) {
	case 0:
		return Discovered{}, ErrDirectoryMissing
	case 1:
	default:
		return Discovered{}, ErrDirectoryDuplicate
	}
	m := directoryAttr.FindSubmatch(page)
	if m == nil {
		return Discovered{}, ErrDirectoryInvalid
	}
	dir := html.UnescapeString(string(m[1]))
	origin, host, ok := DirectoryOrigin(dir)
	if !ok || !strings.HasPrefix(dir, "https://") {
		return Discovered{}, ErrDirectoryInvalid
	}
	return Discovered{Directory: dir, Origin: origin, RPID: host}, nil
}

// Discover reads the directory home names on its sign-in page (/login)
// with one GET that carries no credential and follows no redirect,
// bounded in time and size. Anything but a 200 page naming one valid
// directory is refused.
func Discover(ctx context.Context, client *http.Client, home string) (Discovered, error) {
	if !IsHome(home) {
		return Discovered{}, fmt.Errorf("%q is not a CYFR's address", home)
	}
	c := http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Timeout:       10 * time.Second,
	}
	if client != nil {
		c.Transport = client.Transport
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, home+"/login", nil)
	if err != nil {
		return Discovered{}, err
	}
	req.Header.Set("Accept", "text/html")
	resp, err := c.Do(req)
	if err != nil {
		return Discovered{}, fmt.Errorf("%w (%v)", ErrUnreachable, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Discovered{}, fmt.Errorf("the sign-in page at %s answered HTTP %d", home, resp.StatusCode)
	}
	page, err := io.ReadAll(io.LimitReader(resp.Body, maxLoginPage+1))
	if err != nil {
		return Discovered{}, fmt.Errorf("%w (%v)", ErrUnreachable, err)
	}
	if len(page) > maxLoginPage {
		return Discovered{}, fmt.Errorf("the sign-in page at %s is larger than a sign-in page", home)
	}
	d, err := ReadDirectory(page)
	if err != nil {
		return Discovered{}, fmt.Errorf("the sign-in page at %s names no directory the app can use (%w)", home, err)
	}
	return d, nil
}

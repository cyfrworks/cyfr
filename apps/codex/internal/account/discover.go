// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"golang.org/x/net/html"
)

// Discovered is the directory a CYFR names on its sign-in page: the URL
// whole, base path included, and the origin its account pages are served
// at.
type Discovered struct {
	Directory string
	Origin    string
}

// Why a sign-in page names no directory the app can use
// (tests/fixtures/login_directory.json, pages[].refused).
var (
	errDirectoryMissing   = errors.New("missing")
	errDirectoryDuplicate = errors.New("duplicate")
	errDirectoryInvalid   = errors.New("invalid")
)

const directoryAttribute = "data-account-directory"

// maxLoginPage bounds the sign-in page read: it is one server-rendered
// page.
const maxLoginPage = 1 << 20

// readDirectory reads the directory from a sign-in page's HTML: the one
// data-account-directory attribute of any element, read as HTML reads
// attributes, so the name in text or inside another attribute's value is
// no attribute. Its value is an https directory URL. No such attribute,
// more than one, or one naming anything else is refused.
func readDirectory(page []byte) (Discovered, error) {
	var values []string
	z := html.NewTokenizer(bytes.NewReader(page))
	for {
		switch z.Next() {
		case html.ErrorToken:
			return directoryOf(values)
		case html.StartTagToken, html.SelfClosingTagToken:
			for _, a := range z.Token().Attr {
				if a.Namespace == "" && a.Key == directoryAttribute {
					values = append(values, a.Val)
				}
			}
		}
	}
}

func directoryOf(values []string) (Discovered, error) {
	switch len(values) {
	case 0:
		return Discovered{}, errDirectoryMissing
	case 1:
	default:
		return Discovered{}, errDirectoryDuplicate
	}
	dir := values[0]
	origin, _, ok := DirectoryOrigin(dir)
	if !ok || !strings.HasPrefix(dir, "https://") {
		return Discovered{}, errDirectoryInvalid
	}
	return Discovered{Directory: dir, Origin: origin}, nil
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
	d, err := readDirectory(page)
	if err != nil {
		return Discovered{}, fmt.Errorf("the sign-in page at %s names no directory the app can use (%w)", home, err)
	}
	return d, nil
}

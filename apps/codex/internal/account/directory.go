// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

// DefaultDirectory is the directory an account lives at unless
// CYFR_DIRECTORY_URL names another.
const DefaultDirectory = "https://cyfr.run"

// ErrUnreachable is a request that got no answer: the network failed or
// the server answered 5xx. A write may have landed, so it is sent again
// with the same bytes (the directory) or reconciled by a read (the
// registry's claim).
var ErrUnreachable = errors.New("unreachable")

// maxPages bounds a log read, as the account pages bound it.
const maxPages = 64

// call sends one request and answers its status and body; ErrUnreachable
// for no answer or a 5xx.
func call(ctx context.Context, client *http.Client, method, address string, body []byte) (int, []byte, error) {
	if client == nil {
		client = http.DefaultClient
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, address, reader)
	if err != nil {
		return 0, nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("%w (%v)", ErrUnreachable, err)
	}
	defer resp.Body.Close()
	answer, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return 0, nil, fmt.Errorf("%w (%v)", ErrUnreachable, err)
	}
	if resp.StatusCode >= 500 {
		return 0, nil, fmt.Errorf("%w (HTTP %d)", ErrUnreachable, resp.StatusCode)
	}
	return resp.StatusCode, answer, nil
}

// DirectoryRefusal is the directory's refusal of a read or a write: its
// status, its code (stale_head, duplicate_key, unverified, invalid,
// wrong_directory, gone, not_found, ...) and what it names beside it.
type DirectoryRefusal struct {
	Status     int
	Code       string
	Reason     string
	Head       string
	RetryAfter int
}

func (e *DirectoryRefusal) Error() string {
	if e.Reason != "" {
		return e.Code + ": " + e.Reason
	}
	return e.Code
}

// Written is the directory's answer to a write: created, exists (the same
// bytes are already there) or accepted, and the head an exists names.
type Written struct {
	Identifier string `json:"identifier"`
	Seq        int64  `json:"seq"`
	EntryHash  string `json:"entry_hash"`
	Result     string `json:"result"`
	Head       string `json:"head"`
}

// Config is a directory's one dynamic answer, /account/config.json: its
// URL, the registry it names, and the policy a first claim accepts, or
// nil for a registry that asks for none.
type Config struct {
	Directory string  `json:"directory"`
	Registry  string  `json:"registry"`
	Policy    *Policy `json:"policy"`
}

// Policy is the registry's policy a first claim accepts.
type Policy struct {
	Version string `json:"version"`
	URL     string `json:"url"`
}

// Directory is a directory's HTTP: its configuration, its log reads and
// its signed writes (cyfr-directory/v2).
type Directory struct {
	URL    string
	Client *http.Client
}

// Origin is the directory's origin, where its account pages live.
func (d Directory) Origin() string {
	o, _, ok := DirectoryOrigin(d.URL)
	if !ok {
		return d.URL
	}
	return o
}

// Config reads the directory's /account/config.json.
func (d Directory) Config(ctx context.Context) (Config, error) {
	status, body, err := call(ctx, d.Client, http.MethodGet, d.Origin()+"/account/config.json", nil)
	if err != nil {
		return Config{}, err
	}
	var c Config
	if status != http.StatusOK || json.Unmarshal(body, &c) != nil || !IsDirectoryURL(c.Directory) || !IsHome(c.Registry) ||
		(c.Policy != nil && (c.Policy.Version == "" || c.Policy.URL == "")) {
		return Config{}, fmt.Errorf("the account service at %s answered no configuration", d.Origin())
	}
	return c, nil
}

// Register registers a genesis: created, or exists for the same bytes.
func (d Directory) Register(ctx context.Context, genesis map[string]any) (Written, error) {
	return d.write(ctx, "/directory/v1/register", genesis)
}

// Append appends one entry to identifier's log: accepted, or exists when
// that entry is already the one after its prev.
func (d Directory) Append(ctx context.Context, identifier string, entry map[string]any) (Written, error) {
	return d.write(ctx, "/directory/v1/"+identifier+"/append", entry)
}

func (d Directory) write(ctx context.Context, path string, entry map[string]any) (Written, error) {
	raw, err := JCS(normal(entry))
	if err != nil {
		return Written{}, err
	}
	status, body, err := call(ctx, d.Client, http.MethodPost, d.URL+path, raw)
	if err != nil {
		return Written{}, err
	}
	var w Written
	if status == http.StatusOK && json.Unmarshal(body, &w) == nil &&
		(w.Result == "created" || w.Result == "exists" || w.Result == "accepted") {
		return w, nil
	}
	return Written{}, readRefusal(status, body)
}

func readRefusal(status int, body []byte) *DirectoryRefusal {
	var m struct {
		Error      string `json:"error"`
		Reason     string `json:"reason"`
		Head       string `json:"head"`
		RetryAfter int    `json:"retry_after"`
	}
	_ = json.Unmarshal(body, &m)
	if m.Error == "" {
		m.Error = "HTTP " + strconv.Itoa(status)
	}
	return &DirectoryRefusal{Status: status, Code: m.Error, Reason: m.Reason, Head: m.Head, RetryAfter: m.RetryAfter}
}

// Read reads identifier's log from its genesis, page by page, and walks
// it: the verified state. A tombstoned account is gone and one the
// directory does not hold not_found (*DirectoryRefusal); a log that does
// not verify or does not reach the head the directory names is refused.
func (d Directory) Read(ctx context.Context, identifier string) (State, error) {
	var entries []any
	after := int64(-1)
	for range maxPages {
		status, body, err := call(ctx, d.Client, http.MethodGet,
			d.URL+"/directory/v1/"+identifier+"?after="+strconv.FormatInt(after, 10), nil)
		if err != nil {
			return State{}, err
		}
		if status != http.StatusOK {
			return State{}, readRefusal(status, body)
		}
		v, err := Decode(body)
		page, ok := v.(map[string]any)
		list, isList := page["entries"].([]any)
		from, fromOK := ms(page["from"])
		if err != nil || !ok || !isList || page["identifier"] != identifier || !fromOK || from != after+1 {
			return State{}, errors.New("the account service answered a page that is not this account's")
		}
		entries = append(entries, list...)
		if page["next"] == nil {
			s, err := Walk(entries)
			if err != nil {
				return State{}, fmt.Errorf("the account's log does not verify: %w", err)
			}
			length, _ := ms(page["length"])
			if s.Identifier != identifier || s.Head != page["head"] || s.Seq+1 != length {
				return State{}, errors.New("the account service answered a log that does not reach its head")
			}
			return s, nil
		}
		next, ok := ms(page["next"])
		if !ok || len(list) == 0 || next != after+int64(len(list)) {
			return State{}, errors.New("the account service answered a page that does not follow the last")
		}
		after = next
	}
	return State{}, errors.New("the account's log is longer than the command line reads")
}

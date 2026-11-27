// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package workerwire is Prima.WorkerWire in Go: how the worker protocol
// crosses HTTP. Every request is a POST whose x-cyfr-auth header carries
// a package workerauth header for its body; a WorkerAPI request's route
// is /worker/v1/<callback>. A request body is {"v": 3, "op": <callback>,
// "args": {...}}, written in that order (RequestBody) and read whatever
// the order (ReadRequestBody); an answer is {"v": 3, "ok": value} or
// {"v": 3, "error": <name>, ...} (Ok, Error, ReadAnswer). Prima's module is
// the one definition and tests/fixtures/worker_api.json holds this
// package to it.
package workerwire

import (
	"errors"
	"sort"
	"strings"

	"github.com/cyfr/locus/keeper/internal/wire/macenvelope"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
)

const (
	// Version is the wire's version, every body's and answer's v.
	Version = 3
	// AuthHeader is the header a workerauth header travels in.
	AuthHeader = macenvelope.AuthHeader
	// MaxBodyBytes is the most bytes a request body spans
	// (Prima.HostAPI.max_body_bytes/0), on CYFR's listener and on the
	// worker service's alike.
	MaxBodyBytes = 1 << 20
	workerPrefix = "/worker/v1/"
)

var (
	ErrUnknownVersion = errors.New("unknown_version")
	ErrMalformed      = errors.New("malformed")
)

// WorkerCallbacks are Prima.WorkerAPI's callbacks.
var WorkerCallbacks = []string{"start", "kill", "status"}

// WorkerRoute is the route a WorkerAPI request of callback is posted to.
func WorkerRoute(callback string) string { return workerPrefix + callback }

// WorkerCallback is the callback a worker route names.
func WorkerCallback(path string) (string, bool) {
	for _, c := range WorkerCallbacks {
		if WorkerRoute(c) == path {
			return c, true
		}
	}
	return "", false
}

// memoryEnds are the memory limits a report names
// (Prima.HostAPI.memory_ends/0).
var memoryEnds = []string{"cap", "either", "machine"}

// MaxReportAttempts is the most attempts one runner_exited report names:
// as many as fit MaxBodyBytes when every identifier it carries is the
// longest the protocol allows with every byte of it escaped, and its
// memory the longest it may carry.
var MaxReportAttempts = func() int {
	worst := strings.Repeat(`"`, macenvelope.MaxText)
	entry, _ := wirejson.Write(worst)
	longest := ""
	for _, m := range memoryEnds {
		if len(m) > len(longest) {
			longest = m
		}
	}
	empty, _ := wirejson.Write(RequestBody("runner_exited", map[string]any{
		"attempts": []any{}, "member": worst, "memory": longest, "runner": worst,
	}))
	return (MaxBodyBytes - len(empty) + 1) / (len(entry) + 1)
}()

// BaseURL is the base URL text spells, with no trailing slash: an http or
// https URL with a host, and no user information, path, query or fragment,
// its parts read as Elixir's URI.parse/1 reads them.
func BaseURL(text string) (string, bool) {
	u := parseURI(text)
	if (u.scheme != "http" && u.scheme != "https") || u.host == nil || *u.host == "" ||
		u.userinfo != nil || u.query != nil || u.fragment != nil || (u.path != "" && u.path != "/") {
		return "", false
	}
	return strings.TrimRight(text, "/"), true
}

type uri struct {
	scheme   string
	userinfo *string
	host     *string
	path     string
	query    *string
	fragment *string
}

func alpha(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }
func digit(c byte) bool { return c >= '0' && c <= '9' }

// parseURI reads text as URI.parse/1 does, by RFC 3986's appendix B,
// ^(([a-z][a-z0-9+\-.]*):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?
// without case, the fragment's . stopping at a line feed; and an
// authority as (^(.*)@)?(\[[a-zA-Z0-9:.]*\]|[^:]*)(:(\d*))?, its
// userinfo's . likewise, an empty userinfo none and a host its brackets
// trimmed.
func parseURI(text string) uri {
	var u uri
	rest := text
	if len(text) > 0 && alpha(text[0]) {
		i := 1
		for i < len(text) && (alpha(text[i]) || digit(text[i]) || strings.IndexByte("+-.", text[i]) >= 0) {
			i++
		}
		if i < len(text) && text[i] == ':' {
			u.scheme = strings.ToLower(text[:i])
			rest = text[i+1:]
		}
	}
	if strings.HasPrefix(rest, "//") {
		after := rest[2:]
		end := strings.IndexAny(after, "/?#")
		if end < 0 {
			end = len(after)
		}
		u.userinfo, u.host = splitAuthority(after[:end])
		rest = after[end:]
	}
	end := strings.IndexAny(rest, "?#")
	if end < 0 {
		end = len(rest)
	}
	u.path, rest = rest[:end], rest[end:]
	if strings.HasPrefix(rest, "?") {
		q := rest[1:]
		if i := strings.IndexByte(q, '#'); i >= 0 {
			q, rest = q[:i], q[i:]
		} else {
			rest = ""
		}
		u.query = &q
	}
	if strings.HasPrefix(rest, "#") {
		f := rest[1:]
		if i := strings.IndexByte(f, '\n'); i >= 0 {
			f = f[:i]
		}
		u.fragment = &f
	}
	return u
}

func splitAuthority(authority string) (userinfo, host *string) {
	rest := authority
	line := authority
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	if at := strings.LastIndexByte(line, '@'); at >= 0 {
		if at > 0 {
			info := authority[:at]
			userinfo = &info
		}
		rest = authority[at+1:]
	}
	h := rest[:bracketed(rest)]
	if h == "" {
		return userinfo, nil
	}
	h = strings.TrimRight(strings.TrimLeft(h, "["), "]")
	return userinfo, &h
}

// bracketed is the length of the host at the head of rest: a bracketed
// address of letters, digits, : and ., or everything to the first colon.
func bracketed(rest string) int {
	if strings.HasPrefix(rest, "[") {
		i := 1
		for i < len(rest) && (alpha(rest[i]) || digit(rest[i]) || rest[i] == ':' || rest[i] == '.') {
			i++
		}
		if i < len(rest) && rest[i] == ']' {
			return i + 1
		}
	}
	if i := strings.IndexByte(rest, ':'); i >= 0 {
		return i
	}
	return len(rest)
}

// RequestBody is the request body for callback with args: v, then op,
// then args, in that order as it is written.
func RequestBody(callback string, args any) wirejson.Ordered {
	return wirejson.Ordered{{Name: "v", Value: Version}, {Name: "op", Value: callback}, {Name: "args", Value: args}}
}

// ReadRequestBody is the callback and args a decoded body carries, read as
// a callback of callbacks. The version is read first: an object whose v is
// absent or not the integer 3 is ErrUnknownVersion. A body that is not an
// object, has a member besides v, op and args, names no callback of
// callbacks, or whose args is not an object is ErrMalformed.
func ReadRequestBody(callbacks []string, body any) (string, map[string]any, error) {
	o, ok := body.(map[string]any)
	if !ok {
		return "", nil, ErrMalformed
	}
	if !isVersion(o["v"]) {
		return "", nil, ErrUnknownVersion
	}
	op, isText := o["op"].(string)
	args, isObject := o["args"].(map[string]any)
	if len(o) != 3 || !isText || !isObject {
		return "", nil, ErrMalformed
	}
	for _, c := range callbacks {
		if c == op {
			return op, args, nil
		}
	}
	return "", nil, ErrMalformed
}

func isVersion(v any) bool {
	n, ok := wirejson.Uint(v, Version)
	return ok && n == Version
}

// Ok is the answer carrying value: v, then ok.
func Ok(value any) wirejson.Ordered {
	return wirejson.Ordered{{Name: "v", Value: Version}, {Name: "ok", Value: value}}
}

// Error is the answer refusing with name and fields beside it: v, then
// error, then the fields by name; a field named v or error is the answer's
// own, never the caller's.
func Error(name string, fields map[string]any) wirejson.Ordered {
	names := make([]string, 0, len(fields))
	for n := range fields {
		if n != "v" && n != "error" {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	out := wirejson.Ordered{{Name: "v", Value: Version}, {Name: "error", Value: name}}
	for _, n := range names {
		out = append(out, wirejson.Member{Name: n, Value: fields[n]})
	}
	return out
}

// Reading is what an answer says.
type Reading int

const (
	// Lost is no answer at this version, as a client counts an answer
	// that never arrived.
	Lost Reading = iota
	Answered
	Refused
)

// ReadAnswer reads a decoded answer: {"v": 3, "ok": value} and nothing
// else is Answered with value; {"v": 3, "error": name, ...} with a string
// name and no ok is Refused with name and its other members; anything
// else is Lost.
func ReadAnswer(answer any) (r Reading, value any, name string, fields map[string]any) {
	o, ok := answer.(map[string]any)
	if !ok || !isVersion(o["v"]) {
		return Lost, nil, "", nil
	}
	if v, has := o["ok"]; has {
		if len(o) == 2 {
			return Answered, v, "", nil
		}
		return Lost, nil, "", nil
	}
	n, isText := o["error"].(string)
	if !isText {
		return Lost, nil, "", nil
	}
	fields = make(map[string]any, len(o)-2)
	for k, v := range o {
		if k != "v" && k != "error" {
			fields[k] = v
		}
	}
	return Refused, nil, n, fields
}

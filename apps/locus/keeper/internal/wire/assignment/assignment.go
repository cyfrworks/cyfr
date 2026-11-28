// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package assignment is Prima.Assignment's read in Go, the worker
// service's: the assignment a start hands it, read without the assign key,
// which only CYFR holds, so nothing it reads authorizes anything; CYFR
// verifies the token when the runner attaches.
//
// A token is base64url(payload) "." base64url(mac), both unpadded, the
// MAC 32 bytes, re-encoding to itself; its payload one JSON object of v
// (1) and each member of its type, nothing else, an absent optional member
// none and never null. Read refuses unknown_version for another integer v
// and malformed for anything else it refuses.
//
// It refuses what Prima refuses in every member it reads, the component's
// type and canonical reference among them, and in the parts of the
// authority it reads (package authority). The actor, and the rest of the
// authority, it holds as a JSON object, read no further and passes on:
// CYFR's own rules for them are CYFR's at attach. So a start whose actor,
// or an unread part of whose authority, Prima would refuse is accepted
// here and refused when its runner attaches, where Prima's service answers
// it malformed at once. tests/fixtures/worker_auth.json's assignment_reads
// and assignment_service_reads hold both.
package assignment

import (
	"errors"
	"regexp"
	"strings"

	"github.com/cyfr/locus/keeper/internal/wire/authority"
	"github.com/cyfr/locus/keeper/internal/wire/macenvelope"
	"github.com/cyfr/locus/keeper/internal/wire/wirejson"
	"github.com/cyfr/locus/keeper/internal/wire/workerwire"
)

// Version is the version an assignment carries as v.
const Version = 1

// MaxList is the most intercepted names and declared needs an assignment
// carries.
const MaxList = 256

var (
	ErrMalformed      = errors.New("malformed")
	ErrUnknownVersion = errors.New("unknown_version")
)

// Step is the step of a turn that dispatched an assignment.
type Step struct {
	ID         string
	Generation uint64
}

// Component is the component an assignment runs.
type Component struct {
	Ref, Type, Digest string
	DeclaredNeeds     []string
	ActivationDigest  string // empty for none
}

// Assignment is an assignment as its token carries it; times are Unix
// milliseconds, and an absent optional member is empty. The actor, and
// the authority's parts the service does not read, are kept only in
// Token, which is what is passed on: never a re-encoding of them.
type Assignment struct {
	// Token is the token read, as it was given.
	Token             string
	Generation        uint64
	Service, Boot     string
	Member            string
	HostURL           string
	IssuedAt, ClaimBy uint64
	ExecutionID       string
	Attempt           string
	Fence             uint64
	ParentExecutionID string
	RootExecutionID   string
	Step              *Step
	AthanorID         string
	Authority         authority.Authority
	Component         Component
	InputDigest       string
	TimeoutMs         uint64
	Deadline          uint64
	LeaseUntil        uint64
	Intercepted       []string
}

var members = map[string]bool{
	"v": true, "generation": true, "service": true, "boot": true, "member": true, "host_url": true,
	"issued_at": true, "claim_by": true, "execution_id": true, "attempt": true, "fence": true,
	"parent_execution_id": true, "root_execution_id": true, "step": true, "athanor_id": true,
	"actor": true, "authority": true, "component": true, "input_digest": true, "timeout_ms": true,
	"deadline": true, "lease_until": true, "intercepted": true,
}

var componentMembers = map[string]bool{"ref": true, "type": true, "digest": true, "declared_needs": true, "activation_digest": true}

var (
	digest     = regexp.MustCompile(`\Asha256:[0-9a-f]{64}\z`)
	need       = regexp.MustCompile(`\A[a-z][a-z0-9_-]{0,31}\z`)
	toolAction = regexp.MustCompile(`\A[a-z0-9_-]+\.[a-z0-9_-]+\z`)
)

// split is a token's payload: two base64url parts, the second 32 bytes,
// that re-encode, unpadded, to the token.
func split(token string) ([]byte, bool) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return nil, false
	}
	payload, okPayload := macenvelope.DecodeURL(parts[0])
	mac, okMAC := macenvelope.DecodeURL(parts[1])
	if !okPayload || !okMAC || len(mac) != 32 ||
		macenvelope.EncodeURL(payload)+"."+macenvelope.EncodeURL(mac) != token {
		return nil, false
	}
	return payload, true
}

// Read reads a token.
func Read(token string) (Assignment, error) {
	payload, ok := split(token)
	if !ok {
		return Assignment{}, ErrMalformed
	}
	wire, err := wirejson.Object(payload)
	if err != nil {
		return Assignment{}, ErrMalformed
	}
	switch v := wire["v"]; {
	case v == nil:
		return Assignment{}, ErrMalformed
	case !wirejson.IsInteger(v):
		return Assignment{}, ErrMalformed
	default:
		if n, one := wirejson.Uint(v, Version); !one || n != Version {
			return Assignment{}, ErrUnknownVersion
		}
	}
	a, ok := decode(wire)
	if !ok {
		return Assignment{}, ErrMalformed
	}
	a.Token = token
	return a, nil
}

type reader struct {
	wire map[string]any
	ok   bool
}

func (r *reader) present(name string) bool { _, has := r.wire[name]; return has }

func (r *reader) id(name string) string {
	s, isText := r.wire[name].(string)
	if !isText || !macenvelope.Text(s) {
		r.ok = false
	}
	return s
}

func (r *reader) optionalID(name string) string {
	if !r.present(name) {
		return ""
	}
	return r.id(name)
}

func (r *reader) count(name string, least uint64) uint64 {
	n, inRange := wirejson.Uint(r.wire[name], wirejson.MaxSafeInteger)
	if !inRange || n < least {
		r.ok = false
	}
	return n
}

func (r *reader) digest(v any) string {
	s, isText := v.(string)
	if !isText || !digest.MatchString(s) {
		r.ok = false
	}
	return s
}

func decode(wire map[string]any) (Assignment, bool) {
	for name := range wire {
		if !members[name] {
			return Assignment{}, false
		}
	}
	r := &reader{wire: wire, ok: true}
	a := Assignment{
		Generation: r.count("generation", 1),
		Service:    r.id("service"), Boot: r.id("boot"), Member: r.id("member"),
		IssuedAt: r.count("issued_at", 0), ClaimBy: r.count("claim_by", 0),
		ExecutionID: r.id("execution_id"), Attempt: r.id("attempt"), Fence: r.count("fence", 1),
		ParentExecutionID: r.optionalID("parent_execution_id"), RootExecutionID: r.id("root_execution_id"),
		AthanorID: r.id("athanor_id"), InputDigest: r.digest(wire["input_digest"]),
		TimeoutMs: r.count("timeout_ms", 1), Deadline: r.count("deadline", 0), LeaseUntil: r.count("lease_until", 0),
	}
	if r.present("host_url") {
		url, isText := wire["host_url"].(string)
		if base, ok := workerwire.BaseURL(url); !isText || !ok || base != url {
			return Assignment{}, false
		}
		a.HostURL = url
	}
	if r.present("step") {
		step, isObject := wire["step"].(map[string]any)
		if !isObject || len(step) != 2 {
			return Assignment{}, false
		}
		sr := &reader{wire: step, ok: true}
		a.Step = &Step{ID: sr.id("id"), Generation: sr.count("generation", 0)}
		if !sr.ok {
			return Assignment{}, false
		}
	}
	if _, isObject := wire["actor"].(map[string]any); !isObject {
		return Assignment{}, false
	}
	wireAuthority, isObject := wire["authority"].(map[string]any)
	if !isObject {
		return Assignment{}, false
	}
	auth, err := authority.Read(wireAuthority)
	if err != nil {
		return Assignment{}, false
	}
	a.Authority = auth
	component, ok := readComponent(wire["component"])
	if !ok {
		return Assignment{}, false
	}
	a.Component = component
	names, isList := wire["intercepted"].([]any)
	if !isList || len(names) > MaxList {
		return Assignment{}, false
	}
	for _, n := range names {
		s, isText := n.(string)
		if !isText || len(s) < 3 || len(s) > 256 || !toolAction.MatchString(s) {
			return Assignment{}, false
		}
		a.Intercepted = append(a.Intercepted, s)
	}
	return a, r.ok
}

func readComponent(v any) (Component, bool) {
	o, isObject := v.(map[string]any)
	if !isObject {
		return Component{}, false
	}
	for name := range o {
		if !componentMembers[name] {
			return Component{}, false
		}
	}
	ref, okRef := o["ref"].(string)
	needs, okNeeds := o["declared_needs"].([]any)
	kind, okType := o["type"].(string)
	if !okRef || !okNeeds || len(needs) > MaxList || !okType || !validType(kind) || !canonicalRef(ref, kind) {
		return Component{}, false
	}
	r := &reader{ok: true}
	c := Component{Ref: ref, Type: kind, Digest: r.digest(o["digest"])}
	for _, n := range needs {
		s, isText := n.(string)
		if !isText || !need.MatchString(s) {
			return Component{}, false
		}
		c.DeclaredNeeds = append(c.DeclaredNeeds, s)
	}
	if a, given := o["activation_digest"]; given {
		c.ActivationDigest = r.digest(a)
	}
	return c, r.ok
}

// The component types an assignment names (Prima.ComponentRef.valid_types/0),
// and the shorthands and the source type a reference's prefix may spell.
var (
	types       = []string{"catalyst", "reagent", "formula", "tincture"}
	shorthands  = map[string]string{"c": "catalyst", "r": "reagent", "f": "formula", "t": "tincture"}
	sourceTypes = []string{"agent"}
	semver      = regexp.MustCompile(`\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\+[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*)?\z`)
)

func validType(t string) bool {
	for _, v := range types {
		if v == t {
			return true
		}
	}
	return false
}

// canonicalRef is whether ref names its component once, as
// Prima.ComponentRef spells it, of type kind: an identifier that parses,
// typed, as kind, and writes back as itself.
func canonicalRef(ref, kind string) bool {
	if !macenvelope.Text(ref) {
		return false
	}
	prefix, rest, typed := strings.Cut(ref, ":")
	if !typed || strings.Contains(prefix, ".") {
		return false
	}
	expanded, short := shorthands[prefix]
	if !short {
		expanded = prefix
		if !validType(prefix) && prefix != sourceTypes[0] {
			return false
		}
	}
	nsName, version := rest, ""
	if i := strings.LastIndex(rest, ":"); i >= 0 {
		nsName, version = rest[:i], rest[i+1:]
	}
	if version == "latest" || (version != "" && !semver.MatchString(version)) {
		return false
	}
	i := strings.LastIndex(nsName, ".")
	if i <= 0 || i == len(nsName)-1 {
		return false
	}
	written := expanded + ":" + nsName
	if version != "" {
		written += ":" + version
	}
	return expanded == kind && written == ref
}

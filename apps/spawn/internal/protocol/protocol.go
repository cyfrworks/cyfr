// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package protocol defines the messages between `cyfr-spawn serve` and its
// client over the inherited socket (fd 3): one JSON object per line, each
// carrying `"v": 1` and a `type`.
//
// Client to spawner:
//
//	{"v":1,"type":"spawn","id":…,"pool":…,"argv":[…],"env":{…},"rlimits":{…},"attach":{"path":…,"token":…}}
//	{"v":1,"type":"signal","spawn_id":…,"sig":"SIGTERM"}
//	{"v":1,"type":"release","spawn_id":…,"grace_ms":…}
//	{"v":1,"type":"pool","id":…,"pool":…}
//
// Spawner to client:
//
//	{"v":1,"type":"spawned","id":…,"spawn_id":…,"uid":…,"pid":…}
//	{"v":1,"type":"error","id":…,"spawn_id":…,"code":…}   (id or spawn_id names the request)
//	{"v":1,"type":"exited","spawn_id":…,"code":…,"signal":…}
//	{"v":1,"type":"released","spawn_id":…}
//	{"v":1,"type":"pool","id":…,"pool":…,"size":…,"free":…,"quarantined":…}
//
// `exited` is sent once, when a spawn's leader process is reaped. `released`
// is sent once, when the spawn's uid has been retired, whether retirement
// followed a `release` or the leader's exit.
//
// The client's environment carries ChannelEnv, the name /proc/self/fd/3
// links to for the channel socket (`socket:[inode]`), so a client whose
// runtime opens descriptors of its own before it can inspect fd 3 tells the
// inherited channel from one of those.
package protocol

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strings"
)

// Version is the protocol version every message carries as `v`.
const Version = 1

// ChannelEnv is the client environment variable naming the channel socket.
const ChannelEnv = "CYFR_SPAWN_CHANNEL"

// Message types.
const (
	TypeSpawn    = "spawn"
	TypeSignal   = "signal"
	TypeRelease  = "release"
	TypePool     = "pool"
	TypeSpawned  = "spawned"
	TypeError    = "error"
	TypeExited   = "exited"
	TypeReleased = "released"
)

// Error codes carried by an `error` reply.
const (
	CodeBadRequest   = "bad_request"
	CodeUnknownPool  = "unknown_pool"
	CodeCapacity     = "capacity"
	CodeExecFailed   = "exec_failed"
	CodeUnknownSpawn = "unknown_spawn"
	CodeNotRunning   = "not_running"
	CodeInternal     = "internal"
)

// Bounds on a request.
const (
	MaxLineBytes  = 1 << 20
	MaxArgs       = 256
	MaxEnv        = 256
	MaxValueBytes = 32 << 10
	MaxSpecBytes  = 256 << 10
	MaxGraceMs    = 60_000
	MaxSocketPath = 107
)

// Signals a `signal` request may name.
var Signals = []string{"SIGTERM", "SIGKILL", "SIGINT", "SIGHUP", "SIGQUIT", "SIGUSR1", "SIGUSR2"}

// ReservedEnv are names the spawner sets itself or that belong to CYFR and
// the bridge; a spawn request may not carry them.
var ReservedEnv = []string{"PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PWD"}

// ReservedEnvPrefixes are name prefixes a spawn request may not carry.
var ReservedEnvPrefixes = []string{"CYFR_", "MCP_BRIDGE_"}

var (
	idPattern      = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,64}$`)
	poolPattern    = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
	spawnIDPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)
	tokenPattern   = regexp.MustCompile(`^[0-9a-f]{64}$`)
	envNamePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)
)

// Limits are the resource limits applied to a spawned process; each is set
// as both its soft and hard limit.
type Limits struct {
	Nofile uint64 `json:"nofile"`
	Nproc  uint64 `json:"nproc"`
	Core   uint64 `json:"core"`
	Fsize  uint64 `json:"fsize"`
}

// Ceilings are the default limits and the most a request may ask for.
var Ceilings = Limits{Nofile: 1024, Nproc: 128, Core: 0, Fsize: 256 << 20}

// Rlimits is a request's optional lowering of the ceilings.
type Rlimits struct {
	Nofile *uint64 `json:"nofile,omitempty"`
	Nproc  *uint64 `json:"nproc,omitempty"`
	Core   *uint64 `json:"core,omitempty"`
	Fsize  *uint64 `json:"fsize,omitempty"`
}

// Resolve returns the ceilings lowered by whatever r sets. r may be nil.
func (r *Rlimits) Resolve() Limits {
	out := Ceilings
	if r == nil {
		return out
	}
	for _, f := range []struct {
		v   *uint64
		dst *uint64
	}{{r.Nofile, &out.Nofile}, {r.Nproc, &out.Nproc}, {r.Core, &out.Core}, {r.Fsize, &out.Fsize}} {
		if f.v != nil {
			*f.dst = *f.v
		}
	}
	return out
}

func (r *Rlimits) validate() error {
	if r == nil {
		return nil
	}
	for _, f := range []struct {
		name    string
		v       *uint64
		ceiling uint64
		min     uint64
	}{
		{"nofile", r.Nofile, Ceilings.Nofile, 16},
		{"nproc", r.Nproc, Ceilings.Nproc, 1},
		{"core", r.Core, Ceilings.Core, 0},
		{"fsize", r.Fsize, Ceilings.Fsize, 1},
	} {
		if f.v != nil && (*f.v > f.ceiling || *f.v < f.min) {
			return fmt.Errorf("rlimits.%s must be within %d..%d", f.name, f.min, f.ceiling)
		}
	}
	return nil
}

// Attach names the socket a relay connects to and the token it presents.
type Attach struct {
	Path  string `json:"path"`
	Token string `json:"token"`
}

// ValidateAttach checks an attach target: an absolute, clean socket path
// that fits a sockaddr_un, and a 64-hex-digit token.
func ValidateAttach(a Attach) error {
	if !filepath.IsAbs(a.Path) || filepath.Clean(a.Path) != a.Path || len(a.Path) > MaxSocketPath || strings.ContainsRune(a.Path, 0) {
		return errors.New("attach.path must be a clean absolute path of at most 107 bytes")
	}
	if !tokenPattern.MatchString(a.Token) {
		return errors.New("attach.token must be 64 lowercase hex digits")
	}
	return nil
}

// Request is any client message; Type selects which fields apply.
type Request struct {
	V       int               `json:"v"`
	Type    string            `json:"type"`
	ID      string            `json:"id,omitempty"`
	Pool    string            `json:"pool,omitempty"`
	Argv    []string          `json:"argv,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	Rlimits *Rlimits          `json:"rlimits,omitempty"`
	Attach  *Attach           `json:"attach,omitempty"`
	SpawnID string            `json:"spawn_id,omitempty"`
	Sig     string            `json:"sig,omitempty"`
	GraceMs *int64            `json:"grace_ms,omitempty"`
}

// RequestError is a refused request: the code to reply with, the request's
// id or spawn_id when it had a valid one, and a detail for the spawner's
// log. The detail never quotes an environment value.
type RequestError struct {
	Code    string
	ID      string
	SpawnID string
	Detail  string
}

func (e *RequestError) Error() string { return e.Code + ": " + e.Detail }

// Reply returns the `error` message answering this refusal.
func (e *RequestError) Reply() ErrorReply {
	return NewError(e.ID, e.SpawnID, e.Code)
}

// ParseRequest decodes and validates one line. Unknown fields, fields that
// do not belong to the request's type and out-of-bounds values are refused.
func ParseRequest(line []byte) (*Request, *RequestError) {
	var req Request
	dec := json.NewDecoder(bytes.NewReader(line))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		return nil, &RequestError{Code: CodeBadRequest, Detail: "not a request object: " + scrubJSONError(err)}
	}
	if dec.More() {
		return nil, &RequestError{Code: CodeBadRequest, Detail: "trailing data after the request object"}
	}
	refuse := func(detail string) *RequestError {
		e := &RequestError{Code: CodeBadRequest, Detail: detail}
		if idPattern.MatchString(req.ID) {
			e.ID = req.ID
		}
		if spawnIDPattern.MatchString(req.SpawnID) {
			e.SpawnID = req.SpawnID
		}
		return e
	}
	if req.V != Version {
		return nil, refuse(fmt.Sprintf("v must be %d", Version))
	}
	switch req.Type {
	case TypeSpawn:
		if err := validateSpawn(&req); err != nil {
			return nil, refuse(err.Error())
		}
	case TypeSignal:
		if !req.only("spawn_id", "sig") {
			return nil, refuse("signal carries only spawn_id and sig")
		}
		if !spawnIDPattern.MatchString(req.SpawnID) {
			return nil, refuse("spawn_id must be 32 lowercase hex digits")
		}
		if !contains(Signals, req.Sig) {
			return nil, refuse("sig must be one of " + strings.Join(Signals, ", "))
		}
	case TypeRelease:
		if !req.only("spawn_id", "grace_ms") {
			return nil, refuse("release carries only spawn_id and grace_ms")
		}
		if !spawnIDPattern.MatchString(req.SpawnID) {
			return nil, refuse("spawn_id must be 32 lowercase hex digits")
		}
		if req.GraceMs == nil || *req.GraceMs < 0 || *req.GraceMs > MaxGraceMs {
			return nil, refuse(fmt.Sprintf("grace_ms must be within 0..%d", MaxGraceMs))
		}
	case TypePool:
		if !req.only("id", "pool") {
			return nil, refuse("pool carries only id and pool")
		}
		if !idPattern.MatchString(req.ID) {
			return nil, refuse("id must match " + idPattern.String())
		}
		if !poolPattern.MatchString(req.Pool) {
			return nil, refuse("pool must match " + poolPattern.String())
		}
	default:
		return nil, refuse("unknown type")
	}
	return &req, nil
}

func validateSpawn(req *Request) error {
	if !req.only("id", "pool", "argv", "env", "rlimits", "attach") {
		return errors.New("spawn carries only id, pool, argv, env, rlimits and attach")
	}
	if !idPattern.MatchString(req.ID) {
		return errors.New("id must match " + idPattern.String())
	}
	if !poolPattern.MatchString(req.Pool) {
		return errors.New("pool must match " + poolPattern.String())
	}
	if err := ValidateCommand(req.Argv, req.Env); err != nil {
		return err
	}
	if err := req.Rlimits.validate(); err != nil {
		return err
	}
	if req.Attach == nil {
		return errors.New("attach is required")
	}
	return ValidateAttach(*req.Attach)
}

// ValidateCommand checks an argv and environment block: 1..MaxArgs
// arguments with a non-empty first, at most MaxEnv variables with valid,
// unreserved names, no NUL byte anywhere, and MaxSpecBytes in total.
func ValidateCommand(argv []string, env map[string]string) error {
	if len(argv) == 0 || len(argv) > MaxArgs {
		return fmt.Errorf("argv must hold 1..%d arguments", MaxArgs)
	}
	if argv[0] == "" {
		return errors.New("argv[0] must not be empty")
	}
	total := 0
	for i, a := range argv {
		if strings.ContainsRune(a, 0) {
			return fmt.Errorf("argv[%d] contains a NUL byte", i)
		}
		total += len(a) + 1
	}
	if len(env) > MaxEnv {
		return fmt.Errorf("env holds more than %d variables", MaxEnv)
	}
	for name, value := range env {
		if err := ValidateEnvName(name); err != nil {
			return err
		}
		if len(value) > MaxValueBytes || strings.ContainsRune(value, 0) {
			return fmt.Errorf("env %s: value must be at most %d bytes with no NUL byte", name, MaxValueBytes)
		}
		total += len(name) + len(value) + 2
	}
	if total > MaxSpecBytes {
		return fmt.Errorf("argv and env exceed %d bytes", MaxSpecBytes)
	}
	return nil
}

// ValidateEnvName refuses a malformed or reserved variable name.
func ValidateEnvName(name string) error {
	if !envNamePattern.MatchString(name) {
		return fmt.Errorf("env name %q must match %s", name, envNamePattern)
	}
	if contains(ReservedEnv, name) {
		return fmt.Errorf("env name %s is reserved", name)
	}
	for _, prefix := range ReservedEnvPrefixes {
		if strings.HasPrefix(name, prefix) {
			return fmt.Errorf("env name %s uses the reserved prefix %s", name, prefix)
		}
	}
	return nil
}

// only reports whether every field set on r is among the named ones.
func (r *Request) only(fields ...string) bool {
	set := map[string]bool{
		"id":       r.ID != "",
		"pool":     r.Pool != "",
		"argv":     r.Argv != nil,
		"env":      r.Env != nil,
		"rlimits":  r.Rlimits != nil,
		"attach":   r.Attach != nil,
		"spawn_id": r.SpawnID != "",
		"sig":      r.Sig != "",
		"grace_ms": r.GraceMs != nil,
	}
	for _, f := range fields {
		delete(set, f)
	}
	for _, present := range set {
		if present {
			return false
		}
	}
	return true
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// scrubJSONError keeps a decode error's class without echoing input text,
// which could be an environment value.
func scrubJSONError(err error) string {
	var syntax *json.SyntaxError
	var typ *json.UnmarshalTypeError
	switch {
	case errors.As(err, &syntax):
		return fmt.Sprintf("syntax error at offset %d", syntax.Offset)
	case errors.As(err, &typ):
		return fmt.Sprintf("field %s has the wrong type", typ.Field)
	case strings.HasPrefix(err.Error(), "json: unknown field "):
		return strings.TrimPrefix(err.Error(), "json: ")
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		return "incomplete object"
	default:
		return "undecodable"
	}
}

// Spawned acknowledges a spawn: the spawn id, its uid and the leader's pid.
type Spawned struct {
	V       int    `json:"v"`
	Type    string `json:"type"`
	ID      string `json:"id"`
	SpawnID string `json:"spawn_id"`
	UID     int    `json:"uid"`
	PID     int    `json:"pid"`
}

// NewSpawned builds a `spawned` reply.
func NewSpawned(id, spawnID string, uid, pid int) Spawned {
	return Spawned{V: Version, Type: TypeSpawned, ID: id, SpawnID: spawnID, UID: uid, PID: pid}
}

// ErrorReply refuses the request named by ID (spawn, pool) or SpawnID
// (signal, release).
type ErrorReply struct {
	V       int    `json:"v"`
	Type    string `json:"type"`
	ID      string `json:"id,omitempty"`
	SpawnID string `json:"spawn_id,omitempty"`
	Code    string `json:"code"`
}

// NewError builds an `error` reply.
func NewError(id, spawnID, code string) ErrorReply {
	return ErrorReply{V: Version, Type: TypeError, ID: id, SpawnID: spawnID, Code: code}
}

// Exited reports a leader's end: its exit code, or the signal that ended it.
type Exited struct {
	V       int     `json:"v"`
	Type    string  `json:"type"`
	SpawnID string  `json:"spawn_id"`
	Code    *int    `json:"code"`
	Signal  *string `json:"signal"`
}

// NewExited builds an `exited` reply; exactly one of code and signal is set.
func NewExited(spawnID string, code *int, signal *string) Exited {
	return Exited{V: Version, Type: TypeExited, SpawnID: spawnID, Code: code, Signal: signal}
}

// Released reports that a spawn's uid has been retired.
type Released struct {
	V       int    `json:"v"`
	Type    string `json:"type"`
	SpawnID string `json:"spawn_id"`
}

// NewReleased builds a `released` reply.
func NewReleased(spawnID string) Released {
	return Released{V: Version, Type: TypeReleased, SpawnID: spawnID}
}

// PoolReply answers a `pool` request.
type PoolReply struct {
	V           int    `json:"v"`
	Type        string `json:"type"`
	ID          string `json:"id"`
	Pool        string `json:"pool"`
	Size        int    `json:"size"`
	Free        int    `json:"free"`
	Quarantined int    `json:"quarantined"`
}

// NewPoolReply builds a `pool` reply.
func NewPoolReply(id, pool string, size, free, quarantined int) PoolReply {
	return PoolReply{V: Version, Type: TypePool, ID: id, Pool: pool, Size: size, Free: free, Quarantined: quarantined}
}

// Encode renders a reply as one line.
func Encode(reply any) ([]byte, error) {
	data, err := json.Marshal(reply)
	if err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

// LineReader splits the channel into lines of at most MaxLineBytes. A longer
// line is discarded through its newline and reported as too long.
type LineReader struct {
	r *bufio.Reader
}

// NewLineReader wraps r.
func NewLineReader(r io.Reader) *LineReader {
	return &LineReader{r: bufio.NewReaderSize(r, 64<<10)}
}

// Next returns the next line without its newline. At end of input it
// returns io.EOF; a final line without a newline is discarded.
func (l *LineReader) Next() (line []byte, tooLong bool, err error) {
	var buf []byte
	for {
		chunk, err := l.r.ReadSlice('\n')
		if len(buf)+len(chunk) > MaxLineBytes+1 {
			tooLong = true
			buf = nil
		} else if !tooLong {
			buf = append(buf, chunk...)
		}
		switch {
		case err == nil:
			if tooLong {
				return nil, true, nil
			}
			return buf[:len(buf)-1], false, nil
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		default:
			return nil, false, err
		}
	}
}

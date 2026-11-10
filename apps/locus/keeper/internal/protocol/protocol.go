// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package protocol defines the messages between `cyfr-locus serve` and its
// client over the inherited socket (fd 3): one JSON object per line, each
// carrying `"v": 1` and a `type`.
//
// Client to keeper:
//
//	{"v":1,"type":"spawn","id":…,"pool":…,"argv":[…],"env":{…},"rlimits":{…},"memory_bytes":…,"cpu_quota":…,"control":true,"isolation":"netns","attach":{"path":…,"token":…},"home_mode":"kept","home_path":…,"home_uid":…,"home_max_bytes":…,"pty":true,"hosts":[…]}
//	{"v":1,"type":"signal","spawn_id":…,"sig":"SIGTERM"}
//	{"v":1,"type":"release","spawn_id":…,"grace_ms":…}
//	{"v":1,"type":"pool","id":…,"pool":…}
//	{"v":1,"type":"home_make","id":…,"path":…,"uid":…}
//	{"v":1,"type":"home_measure","id":…,"path":…,"uid":…}
//	{"v":1,"type":"home_retire","id":…,"path":…,"uid":…}
//
// Keeper to client:
//
//	{"v":1,"type":"spawned","id":…,"spawn_id":…,"uid":…,"pid":…}
//	{"v":1,"type":"error","id":…,"spawn_id":…,"code":…}   (id or spawn_id names the request)
//	{"v":1,"type":"exited","spawn_id":…,"code":…,"signal":…,"memory_exceeded":…}
//	{"v":1,"type":"released","spawn_id":…}
//	{"v":1,"type":"pool","id":…,"pool":…,"size":…,"free":…,"quarantined":…}
//	{"v":1,"type":"home_made","id":…}
//	{"v":1,"type":"home_measured","id":…,"bytes":…}
//	{"v":1,"type":"home_retired","id":…}
//
// `exited` is sent once, when a spawn's leader process is reaped. `released`
// is sent once, when the spawn's uid has been retired, whether retirement
// followed a `release` or the leader's exit.
//
// A spawn's `env` is the whole environment block its command receives
// beside the variables the stage sets itself (PATH, HOME, USER, LOGNAME and
// TMPDIR): nothing of the keeper's or the client's environment is
// inherited, so the request names exactly the variables that reach the
// command, and a reserved name (ReservedEnv, ReservedEnvPrefixes) is
// refused.
//
// A spawn's required `memory_bytes`, from MinMemoryBytes to MaxMemoryBytes,
// bounds the memory of everything the spawn runs, whatever its pool: the
// keeper puts the command in a cgroup of its own (package cgroup) limited
// to that many bytes with no swap, so its processes, the pages of what it writes to
// a tmpfs home and the kernel memory charged to it never exceed the bound
// together. When they cannot stay under it the kernel kills every process
// of the spawn, and the leader's `exited` carries `"memory_exceeded": true`,
// read from the cgroup's own counters and never inferred from the signal;
// every other `exited` carries false. A keeper that cannot give a spawn
// such a cgroup refuses the request as CodeMemoryUnavailable: the bound is
// enforced or the command does not run. Missing, null and zero
// `memory_bytes` are refused as CodeBadRequest. The group's memory.high is
// nine tenths of the bound, so a growing spawn is throttled and reclaimed
// before the kernel kills it at the bound.
//
// A spawn's required `cpu_quota`, from MinCPUQuota to MaxCPUQuota, is the
// microseconds of CPU time its group may use in every CPUPeriod (100000
// microseconds): 100000 is one CPU, 200000 two. It is written to the same
// group's cpu.max before the command starts, and a keeper whose cgroup has
// no CPU controller cannot give a spawn its group at all, so it refuses
// every spawn as CodeMemoryUnavailable alike. Missing, null and zero
// `cpu_quota` are refused as CodeBadRequest.
//
// A spawn with `"control": true` also gets a control channel: the keeper
// makes an AF_UNIX stream socketpair, installs one end as the command's file
// descriptor 3 and hands the other to the spawn's relay, which carries it
// over the attach connection as frame.StreamControl in both directions,
// bytes verbatim in frames of at most frame.MaxPayload; the keeper never
// reads them. A zero-length control frame from the relay reports that every
// holder of the command's end has closed it or exited; one from the client
// closes the command's reading side, so the command reads end of file. A
// `release` ends the channel with the command's processes. Any pool may
// serve such a spawn; a long-lived command is ended only by a `release`, by
// its own exit or by the loss of the client, whichever pool it came from.
//
// A spawn's `isolation` is IsolationNetns or absent, and is present exactly
// when its pool is isolated (`--pool <name>:<first>-<last>:netns` on the
// keeper's command line): the keeper refuses the one without the other as
// CodeBadRequest. An isolated spawn's command runs in a user and network
// namespace cloned for it, whose loopback stays down and whose only
// mapping is the pooled uid and gid to themselves, so the command keeps
// its uid, its home and its cgroup and has no route to anything: a
// descriptor it inherited is its only way out. It holds no capability in
// any of the five sets and runs with no_new_privs.
//
// A spawn's `home_mode` is HomeScratch, today's home scrubbed at
// retirement, or HomeKept, a home that outlives the spawn: absent reads as
// HomeScratch. A kept spawn names its home's clean absolute `home_path`
// and the home's own `home_uid`, and may bound it by `home_max_bytes`;
// those three are refused without HomeKept. A spawn's `pty` asks for a
// pseudo-terminal; absent reads as false. The `home_make`, `home_measure`
// and `home_retire` requests name a kept home by `path` and `uid`.
//
// The keeper runs a kept spawn under its home_uid in its home_path, both
// within its `--kept-homes <root>:<first>-<last>` (a home directly under the
// root, a uid of the range), and takes no uid of the pool for it; a kept
// spawn whose home already holds home_max_bytes is refused as
// CodeHomeOverCap. A `pty` spawn's stdin, stdout and stderr are a
// pseudo-terminal, which its stdout frames carry; its stderr ends at once.
// The home requests act as helpers running as the home's uid: `home_make`
// makes the home 0700, `home_measure` answers the bytes allocated under it,
// and `home_retire` ends every process of the uid and removes the home.
//
// A spawn's `hosts` names the only hosts its command may reach beyond
// the resolver and the deployment's private hosts: 1..MaxHosts distinct
// exact hostnames (ValidHost: lowercase, no wildcard, scheme, port or
// trailing dot, and no address literal), never on an isolated spawn, which
// reaches nothing.
// Absent keeps the island's public-hosts rule. A keeper given `--guard`
// resolves the names at the spawn, and only then, and has the island's
// egress guard admit those addresses for the spawn's uid and refuse it
// every other public one (package guard); a spawn without `hosts` has the
// guard clear the uid back to the island's rule. Either is confirmed
// before the command starts: a name that resolves to no address refuses
// the spawn as CodeHostsUnresolved, and a guard that does not confirm, or
// a keeper given no `--guard` for a spawn naming hosts, as
// CodeGuardUnavailable; no such spawn is ever started open. A guard
// confirms only once its greeting names the keeper's own network
// namespace: one that names another (a guard restarted into a new
// namespace while the keeper's still runs in the old) confirms nothing,
// and every spawn of a keeper given `--guard` is refused until the service
// is recreated behind it.
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

// IsolationNetns is the one value a spawn's `isolation` takes: a user and
// network namespace of the spawn's own.
const IsolationNetns = "netns"

// A spawn's `home_mode` values.
const (
	HomeScratch = "scratch"
	HomeKept    = "kept"
)

// ChannelEnv is the client environment variable naming the channel socket.
const ChannelEnv = "KEEPER_CHANNEL"

// KeptHomesEnv is the client environment variable naming the kept-homes root
// and uid range, `<root>:<first>-<last>`, as the keeper's --kept-homes names
// them; absent for a keeper that keeps no homes.
const KeptHomesEnv = "KEEPER_KEPT_HOMES"

// Message types.
const (
	TypeSpawn        = "spawn"
	TypeSignal       = "signal"
	TypeRelease      = "release"
	TypePool         = "pool"
	TypeHomeMake     = "home_make"
	TypeHomeMeasure  = "home_measure"
	TypeHomeRetire   = "home_retire"
	TypeSpawned      = "spawned"
	TypeError        = "error"
	TypeExited       = "exited"
	TypeReleased     = "released"
	TypeHomeMade     = "home_made"
	TypeHomeMeasured = "home_measured"
	TypeHomeRetired  = "home_retired"
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
	// CodeMemoryUnavailable refuses a spawn whose memory and CPU bounds the
	// keeper cannot enforce where it runs.
	CodeMemoryUnavailable = "memory_unavailable"
	// CodeHomeOverCap refuses a kept spawn whose home already holds its
	// home_max_bytes.
	CodeHomeOverCap = "home_over_cap"
	// CodeUIDBusy refuses a home_make or a kept spawn on a kept home's uid
	// that is not free for it: retiring (its last spawn released, its
	// processes not yet all ended), quarantined (a retirement that could not
	// finish), or live under another home. A client drawing a uid for a new
	// home takes another.
	CodeUIDBusy = "uid_busy"
	// CodeHostsUnresolved refuses a spawn one of whose hosts resolves to no
	// address.
	CodeHostsUnresolved = "hosts_unresolved"
	// CodeGuardUnavailable refuses a spawn whose egress the island's guard
	// did not confirm: no guard (--guard), a guard that cannot be reached
	// or judges another network namespace, or one that refused the change.
	CodeGuardUnavailable = "guard_unavailable"
)

// Bounds on a request. These, Signals, ReservedEnv, Ceilings and Floors
// are the shared vectors' request_bounds, signals, reserved_env and
// rlimits, which CYFR's codec holds too.
const (
	MaxLineBytes  = 1 << 20
	MaxArgs       = 256
	MaxEnv        = 256
	MaxValueBytes = 32 << 10
	MaxSpecBytes  = 256 << 10
	MaxGraceMs    = 60_000
	MaxSocketPath = 107
	// MinMemoryBytes is the least a spawn's memory bound may be: the stage
	// and a command's start fit under it.
	MinMemoryBytes = 16 << 20
	// MaxMemoryBytes is the most a spawn's memory bound may be, a number
	// every client's JSON carries exactly.
	MaxMemoryBytes = 1 << 40
	// CPUPeriod is the period, in microseconds, a spawn's cpu_quota is a
	// share of.
	CPUPeriod = 100_000
	// MinCPUQuota is the least a spawn's CPU quota may be, the kernel's
	// own least: a hundredth of a CPU.
	MinCPUQuota = 1_000
	// MaxCPUQuota is the most a spawn's CPU quota may be: 1024 CPUs.
	MaxCPUQuota = 1024 * CPUPeriod
	// MaxHomePathBytes is the longest a kept home's path may be, PATH_MAX
	// less its NUL.
	MaxHomePathBytes = 4095
	// MaxUID is the highest uid a kept home may own: (uid_t)-1 is no uid.
	MaxUID = 4294967294
	// MaxHomeBytes is the most a kept home's bound may be, a number every
	// client's JSON carries exactly.
	MaxHomeBytes = 1 << 50
	// MaxHosts is the most hosts a spawn may name.
	MaxHosts = 32
)

// Signals a `signal` request may name.
var Signals = []string{"SIGTERM", "SIGKILL", "SIGINT", "SIGHUP", "SIGQUIT", "SIGUSR1", "SIGUSR2"}

// ReservedEnv are names the keeper sets itself or that belong to CYFR and
// Locus; a spawn request may not carry them.
var ReservedEnv = []string{"PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PWD"}

// ReservedEnvPrefixes are name prefixes a spawn request may not carry:
// CYFR's, Locus's and the keeper's own, which ChannelEnv carries. The list
// is the shared vectors' reserved_env_prefixes, which CYFR and Locus hold
// too.
var ReservedEnvPrefixes = []string{"CYFR_", "LOCUS_", "KEEPER_"}

var (
	idPattern      = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,64}$`)
	poolPattern    = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
	spawnIDPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)
	tokenPattern   = regexp.MustCompile(`^[0-9a-f]{64}$`)
	envNamePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)
	// hostPattern is an exact hostname of the egress domain grammar
	// (Prima.Destination's): lowercase labels of letters, digits, hyphens
	// and underscores, neither starting nor ending with a hyphen, of at
	// most 63 bytes each, joined by dots.
	hostPattern = regexp.MustCompile(`^[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?(?:\.[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?)*$`)
)

// MaxHostBytes is the longest a host may be.
const MaxHostBytes = 253

// ValidHost reports whether host is an exact hostname a spawn may name:
// never an address literal, so a name whose last label is all digits
// (1.1.1.1, 10.0.0.1) is refused, as the pattern refuses IPv6's colons and
// brackets.
func ValidHost(host string) bool {
	if len(host) > MaxHostBytes || !hostPattern.MatchString(host) {
		return false
	}
	last := host[strings.LastIndexByte(host, '.')+1:]
	return strings.Trim(last, "0123456789") != ""
}

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

// Unlimited is RLIM_INFINITY: no limit at all.
const Unlimited = ^uint64(0)

// KeptUnbounded names the limits a kept spawn takes no default for: its
// file size, since its disk is bounded by its home_max_bytes and the kept
// homes' volume, and a program a person installs may write a file past
// the ceiling. A request may still lower each to the ceilings' range.
var KeptUnbounded = []string{"fsize"}

// Floors are the least a request may lower each limit to.
var Floors = Limits{Nofile: 16, Nproc: 1, Core: 0, Fsize: 1}

// Rlimits is a request's optional lowering of the ceilings.
type Rlimits struct {
	Nofile *uint64 `json:"nofile,omitempty"`
	Nproc  *uint64 `json:"nproc,omitempty"`
	Core   *uint64 `json:"core,omitempty"`
	Fsize  *uint64 `json:"fsize,omitempty"`
}

// ResolveKept is Resolve for a kept spawn: a limit KeptUnbounded names
// that r does not set is Unlimited.
func (r *Rlimits) ResolveKept() Limits {
	out := r.Resolve()
	if r == nil || r.Fsize == nil {
		out.Fsize = Unlimited
	}
	return out
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
		{"nofile", r.Nofile, Ceilings.Nofile, Floors.Nofile},
		{"nproc", r.Nproc, Ceilings.Nproc, Floors.Nproc},
		{"core", r.Core, Ceilings.Core, Floors.Core},
		{"fsize", r.Fsize, Ceilings.Fsize, Floors.Fsize},
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
	// MemoryBytes is required for a spawn and absent for other requests.
	MemoryBytes *uint64 `json:"memory_bytes,omitempty"`
	// CPUQuota is required for a spawn and absent for other requests.
	CPUQuota *uint64 `json:"cpu_quota,omitempty"`
	Control  bool    `json:"control,omitempty"`
	// Isolation is IsolationNetns for a spawn of an isolated pool and
	// empty for any other.
	Isolation string  `json:"isolation,omitempty"`
	Attach    *Attach `json:"attach,omitempty"`
	SpawnID   string  `json:"spawn_id,omitempty"`
	Sig       string  `json:"sig,omitempty"`
	GraceMs   *int64  `json:"grace_ms,omitempty"`
	// HomeMode is HomeScratch, HomeKept or empty (HomeScratch); HomePath,
	// HomeUID and HomeMaxBytes are set only on a HomeKept spawn.
	HomeMode     string  `json:"home_mode,omitempty"`
	HomePath     string  `json:"home_path,omitempty"`
	HomeUID      *uint64 `json:"home_uid,omitempty"`
	HomeMaxBytes *uint64 `json:"home_max_bytes,omitempty"`
	Pty          *bool   `json:"pty,omitempty"`
	// Hosts are the only hosts a spawn may reach (beside the resolver and
	// the private hosts); absent keeps the island's public-hosts rule.
	Hosts []string `json:"hosts,omitempty"`
	// Path and UID name the kept home of a home request.
	Path string  `json:"path,omitempty"`
	UID  *uint64 `json:"uid,omitempty"`

	// present names the members the line carried, whatever their values:
	// a member is judged by its presence, never by a zero value standing
	// in for absence, so `"home_mode": ""` or `"control": false` on a
	// request that does not carry them is refused, as CYFR's codec refuses
	// them (Prima.KeeperProtocol).
	present map[string]bool
}

// RequestError is a refused request: the code to reply with, the request's
// id or spawn_id when it had a valid one, and a detail for the keeper's
// log. The detail never quotes an environment value.
type RequestError struct {
	Code    string
	ID      string
	SpawnID string
	Detail  string
}

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
	var members map[string]json.RawMessage
	if err := json.Unmarshal(line, &members); err != nil {
		return nil, &RequestError{Code: CodeBadRequest, Detail: "not a request object: " + scrubJSONError(err)}
	}
	req.present = make(map[string]bool, len(members))
	var null string
	for name, value := range members {
		req.present[name] = true
		if string(bytes.TrimSpace(value)) == "null" && (null == "" || name < null) {
			null = name
		}
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
	// No member is ever null: an absent member is left out.
	if null != "" {
		return nil, refuse(null + " must not be null")
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
	case TypeHomeMake, TypeHomeMeasure, TypeHomeRetire:
		if !req.only("id", "path", "uid") {
			return nil, refuse(req.Type + " carries only id, path and uid")
		}
		if !idPattern.MatchString(req.ID) {
			return nil, refuse("id must match " + idPattern.String())
		}
		if err := validateHomePath("path", req.Path); err != nil {
			return nil, refuse(err.Error())
		}
		if err := validateUID("uid", req.UID); err != nil {
			return nil, refuse(err.Error())
		}
	default:
		return nil, refuse("unknown type")
	}
	return &req, nil
}

func validateSpawn(req *Request) error {
	if !req.only("id", "pool", "argv", "env", "rlimits", "memory_bytes", "cpu_quota", "control", "isolation", "attach", "home_mode", "home_path", "home_uid", "home_max_bytes", "pty", "hosts") {
		return errors.New("spawn carries only id, pool, argv, env, rlimits, memory_bytes, cpu_quota, control, isolation, attach, home_mode, home_path, home_uid, home_max_bytes, pty and hosts")
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
	if req.MemoryBytes == nil {
		return errors.New("memory_bytes is required")
	}
	if m := *req.MemoryBytes; m < MinMemoryBytes || m > MaxMemoryBytes {
		return fmt.Errorf("memory_bytes must be within %d..%d", uint64(MinMemoryBytes), uint64(MaxMemoryBytes))
	}
	if req.CPUQuota == nil {
		return errors.New("cpu_quota is required")
	}
	if q := *req.CPUQuota; q < MinCPUQuota || q > MaxCPUQuota {
		return fmt.Errorf("cpu_quota must be within %d..%d", uint64(MinCPUQuota), uint64(MaxCPUQuota))
	}
	if req.present["isolation"] && req.Isolation != IsolationNetns {
		return errors.New("isolation must be " + IsolationNetns)
	}
	if req.Attach == nil {
		return errors.New("attach is required")
	}
	if err := ValidateAttach(*req.Attach); err != nil {
		return err
	}
	if err := validateHosts(req); err != nil {
		return err
	}
	return validateHome(req)
}

// validateHosts checks a spawn's hosts: when present, 1..MaxHosts distinct
// exact hostnames, on a spawn that is not isolated.
func validateHosts(req *Request) error {
	if !req.present["hosts"] {
		return nil
	}
	if req.present["isolation"] {
		return errors.New("an isolated spawn reaches nothing: it takes no hosts")
	}
	if len(req.Hosts) == 0 || len(req.Hosts) > MaxHosts {
		return fmt.Errorf("hosts must hold 1..%d hostnames", MaxHosts)
	}
	seen := make(map[string]bool, len(req.Hosts))
	for i, host := range req.Hosts {
		if !ValidHost(host) {
			return fmt.Errorf("hosts[%d] must be an exact lowercase hostname of at most %d bytes", i, MaxHostBytes)
		}
		if seen[host] {
			return fmt.Errorf("hosts[%d] is named twice", i)
		}
		seen[host] = true
	}
	return nil
}

func validateHome(req *Request) error {
	mode := req.HomeMode
	if !req.present["home_mode"] {
		mode = HomeScratch
	}
	switch mode {
	case HomeScratch:
		if req.present["home_path"] || req.present["home_uid"] || req.present["home_max_bytes"] {
			return errors.New("home_path, home_uid and home_max_bytes need home_mode " + HomeKept)
		}
		return nil
	case HomeKept:
	default:
		return errors.New("home_mode must be " + HomeScratch + " or " + HomeKept)
	}
	if !req.present["home_path"] {
		return errors.New("home_path is required with home_mode " + HomeKept)
	}
	if err := validateHomePath("home_path", req.HomePath); err != nil {
		return err
	}
	if err := validateUID("home_uid", req.HomeUID); err != nil {
		return err
	}
	if b := req.HomeMaxBytes; b != nil && (*b < 1 || *b > MaxHomeBytes) {
		return fmt.Errorf("home_max_bytes must be within 1..%d", uint64(MaxHomeBytes))
	}
	return nil
}

// validateHomePath checks a kept home's path: absolute and clean, as
// filepath.Clean leaves it, with no NUL and at most MaxHomePathBytes.
func validateHomePath(field, p string) error {
	if !filepath.IsAbs(p) || filepath.Clean(p) != p || len(p) > MaxHomePathBytes || strings.ContainsRune(p, 0) {
		return fmt.Errorf("%s must be a clean absolute path of at most %d bytes", field, MaxHomePathBytes)
	}
	return nil
}

func validateUID(field string, uid *uint64) error {
	if uid == nil || *uid < 1 || *uid > MaxUID {
		return fmt.Errorf("%s must be within 1..%d", field, uint64(MaxUID))
	}
	return nil
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

// only reports whether every member the line carried is among the named
// ones, v and type aside.
func (r *Request) only(fields ...string) bool {
	allowed := make(map[string]bool, len(fields)+2)
	for _, f := range append(fields, "v", "type") {
		allowed[f] = true
	}
	for name := range r.present {
		if !allowed[name] {
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

// ErrorReply refuses the request named by ID (spawn, pool, home) or SpawnID
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

// Exited reports a leader's end: its exit code, or the signal that ended it,
// and whether the kernel killed processes of the spawn at its memory bound.
type Exited struct {
	V              int     `json:"v"`
	Type           string  `json:"type"`
	SpawnID        string  `json:"spawn_id"`
	Code           *int    `json:"code"`
	Signal         *string `json:"signal"`
	MemoryExceeded bool    `json:"memory_exceeded"`
}

// NewExited builds an `exited` reply; exactly one of code and signal is set.
func NewExited(spawnID string, code *int, signal *string, memoryExceeded bool) Exited {
	return Exited{V: Version, Type: TypeExited, SpawnID: spawnID, Code: code, Signal: signal, MemoryExceeded: memoryExceeded}
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

// HomeMade acknowledges a `home_make`.
type HomeMade struct {
	V    int    `json:"v"`
	Type string `json:"type"`
	ID   string `json:"id"`
}

// NewHomeMade builds a `home_made` reply.
func NewHomeMade(id string) HomeMade {
	return HomeMade{V: Version, Type: TypeHomeMade, ID: id}
}

// HomeMeasured answers a `home_measure` with the bytes the home holds.
type HomeMeasured struct {
	V     int    `json:"v"`
	Type  string `json:"type"`
	ID    string `json:"id"`
	Bytes uint64 `json:"bytes"`
}

// NewHomeMeasured builds a `home_measured` reply.
func NewHomeMeasured(id string, bytes uint64) HomeMeasured {
	return HomeMeasured{V: Version, Type: TypeHomeMeasured, ID: id, Bytes: bytes}
}

// HomeRetired acknowledges a `home_retire`.
type HomeRetired struct {
	V    int    `json:"v"`
	Type string `json:"type"`
	ID   string `json:"id"`
}

// NewHomeRetired builds a `home_retired` reply.
func NewHomeRetired(id string) HomeRetired {
	return HomeRetired{V: Version, Type: TypeHomeRetired, ID: id}
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

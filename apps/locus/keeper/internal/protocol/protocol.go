// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package protocol defines the messages between `cyfr-locus serve` and its
// clients, one role process each, over each one's inherited socket (fd 3):
// one JSON object per line, each carrying `"v": 9` and a `type`.
//
// Each role's channel is its own. A request names only what is its role's:
// a pool another role draws from is unknown (CodeUnknownPool), a spawn
// another role holds unknown (CodeUnknownSpawn), a place another role holds
// absent, as it is to a spawn, an assign and a measure, and a kept home on
// a role whose sessions keep none unavailable (CodeUnavailable). Every
// reply and every report of a spawn goes to the channel of the role that
// asked for it.
//
// Client to keeper:
//
//	{"v":9,"type":"place","id":…,"kind":…,"athanor":…,"subject":…,"athanor_max_bytes":…}
//	{"v":9,"type":"drop","place":…}
//	{"v":9,"type":"assign","id":…,"place":…,"kind":…,"athanor":…,"subject":…}
//	{"v":9,"type":"spawn","id":…,"place":…,"pool":…,"argv":[…],"env":{…},"rlimits":{…},"control":true,"attach":{"path":…,"token":…},"home_mode":"kept","home":…,"home_max_bytes":…,"pty":{"rows":…,"cols":…},"hosts":[…],"packs":{"athanor":…,"digest":…}}
//	{"v":9,"type":"signal","spawn_id":…,"sig":"SIGTERM"}
//	{"v":9,"type":"resize","spawn_id":…,"rows":…,"cols":…}
//	{"v":9,"type":"release","spawn_id":…,"grace_ms":…}
//	{"v":9,"type":"measure","id":…,"place":…}
//	{"v":9,"type":"pool","id":…,"pool":…}
//	{"v":9,"type":"home_make","id":…,"home":…,"athanor":…}
//	{"v":9,"type":"home_measure","id":…,"home":…}
//	{"v":9,"type":"home_reset","id":…,"home":…}
//	{"v":9,"type":"home_retire","id":…,"home":…}
//	{"v":9,"type":"home_list","id":…,"after":…}
//	{"v":9,"type":"report","id":…,"after":…}
//	{"v":9,"type":"packs_hold","id":…,"athanor":…,"lifetime":…,"digest":…}
//	{"v":9,"type":"packs_put","id":…,"athanor":…,"lifetime":…,"digest":…,"seq":…,"last":…,"data":…}
//
// Keeper to client:
//
//	{"v":9,"type":"placed","id":…,"memory_bytes":…}
//	{"v":9,"type":"assigned","id":…}
//	{"v":9,"type":"spawned","id":…,"spawn_id":…,"uid":…,"pid":…}
//	{"v":9,"type":"error","id":…,"spawn_id":…,"code":…}   (id or spawn_id names the request; a spawn refused once made carries both)
//	{"v":9,"type":"error","id":…,"code":"no_memory","held":{"need":…,"free":…,"mine":[{"kind":…,"subject":…,"bytes":…}],"others_bytes":…}}
//	{"v":9,"type":"give_way","place":…}
//	{"v":9,"type":"exited","spawn_id":…,"code":…,"signal":…,"memory":null | "cap" | "machine" | "either"}
//	{"v":9,"type":"measured","id":…,"kind":…,"athanor":…,"subject":…,"bytes":…,"lesser":…,"age_ms":…}
//	{"v":9,"type":"released","spawn_id":…}
//	{"v":9,"type":"pool","id":…,"pool":…,"size":…,"free":…,"quarantined":…}
//	{"v":9,"type":"home_made","id":…,"uid":…}
//	{"v":9,"type":"home_measured","id":…,"bytes":…}
//	{"v":9,"type":"home_retired","id":…}
//	{"v":9,"type":"homes","id":…,"ids":[…],"next":…}
//	{"v":9,"type":"reported","id":…,"report":{"boot":…,"budget":…,"work":…,"floor":…,"used":…,"counters":[…],"next":…}}
//	{"v":9,"type":"packs","id":…,"state":"held" | "missing" | "taken"}
//
// A place follows one piece of work from before its preparation to its
// release. The client names it with an `id` of its own minted before any
// preparation, with its `kind` (Kinds) and, where it has them, the
// `athanor` it is for, of the grammar every Locus wire gives an athanor's
// id, and its `subject` (a program's or a terminal's row), of the id
// grammar, and the keeper answers `placed` once it has room for it (below);
// a place of an id the keeper already holds, and one of a kind its role
// does not place, are refused as CodeBadRequest: only the role that keeps
// the warm floor (`--role …:floor`) places and assigns a runner's kinds,
// warm and run, and every other role only build, program and terminal. A `drop` frees a place no
// spawn has named, as when its preparation fails, its waiter cancels or
// whom it was for dies, one still waiting for room among them; it is
// never answered, and a place the keeper no
// longer holds leaves it with nothing to do. An `assign` has an `id` of its
// own beside the `place` it names and gives that place another kind,
// athanor and subject, as a runner given work or back at rest; it is
// answered under that id alone, `assigned` once applied, or refused as
// CodeBadRequest where the keeper holds no such place, or where a spawn
// naming packs claimed it and the assign names another athanor. A `spawn` names its
// place, which no other spawn may name: one naming a place the keeper does
// not hold, one still waiting for room, or one another spawn named, is
// refused as CodeBadRequest. Only
// the keeper frees a place a spawn named: a spawn refused before the keeper
// made anything of it is refused under its `id` alone and frees its place
// before the refusal is sent, and every other place is free at its spawn's
// `released`. A spawn refused after the keeper made it, as one whose
// command could not be executed, is refused under its `id` and the
// `spawn_id` the keeper gave it, and gets no `exited` and one `released`
// under that `spawn_id` once its cleanup is done and its place freed. A
// group that cannot be removed keeps its place, read and measured, and its
// removal is retried once a second: only its success frees the place and
// sends its `released`.
//
// `exited` is sent at most once and always before `released`: when a spawn's
// leader process is reaped or, where retirement's bounded wait for that ran
// out and the counters hold a kill for memory, then, with SIGKILL. A leader
// retirement stopped waiting for with no such kill has none. `released` is
// sent once, when the spawn's uid has been retired and its group removed,
// whether retirement followed a `release`, the leader's exit or the spawn's
// refusal, and no exit follows it.
//
// A spawn's `env` is the whole environment block its command receives
// beside the variables the stage sets itself (PATH, HOME, USER, LOGNAME and
// TMPDIR): nothing of the keeper's or any client's environment is
// inherited, so the request names exactly the variables that reach the
// command, and a reserved name (ReservedEnv, ReservedEnvPrefixes) is
// refused.
//
// The keeper is the one admission of all a machine's Locus work (package
// admission, plan 2.9): every role's places are charged against one memory
// bound, W, the warm floor's F kept apart where a role keeps it. A place is
// answered `placed` once it fits, in arrival order, with the `memory_bytes`
// its spawn will be bounded to; while it does not, the idle runners that
// cover what it needs are each sent a `give_way` naming their place, on
// the floor's role's channel, and that role releases each one only if it
// is still idle. A place that finds no room within RoomWait, or that no
// pool of W could hold, is refused CodeNoMemory with `held`: what it
// needs, what is free, the charges of its own athanor's places (the
// subject only of places of the asking role) and the sum of all others'.
// A session's place may carry `athanor_max_bytes`, the ceiling of its
// athanor's sessions here, which it is admitted within.
//
// A spawn names no bound: the keeper sets each one's by its place's kind
// (admission.LimitsOf), a runner's and a build's fixed, a session's half of
// W, never under its allowance, each with its processors, and a spawn
// carrying `memory_bytes` or `cpu_quota` is refused as CodeBadRequest. The
// keeper puts the command in a cgroup of its own limited to that many bytes
// with no swap, so its processes, the pages of what it writes to a tmpfs
// home and the kernel memory charged to it never exceed the bound
// together. When they cannot stay under it the kernel kills every process
// of the spawn, and the leader's `exited` carries `"memory": "cap"`. A kill
// for a limit above the spawn's, the container's or the machine's, carries
// `"memory": "machine"`, whatever the spawn's own bound counted before it.
// A kill the counters cannot lay to one of the two carries
// `"memory": "either"` and never "cap". All are read from the cgroup's own
// counters and never inferred from the signal; an `exited` of no kill, or of
// counters that could not be read, carries null. A keeper that cannot give
// a spawn such a cgroup, its CPU controller included, refuses the request
// as CodeMemoryUnavailable: the bound is enforced or the command does not
// run.
//
// The keeper reads every spawn's group once a second, whatever its kind:
// the `bytes` of its cgroup that cannot be given back, anon + shmem +
// kernel - slab_reclaimable from one read of its memory.stat, so the tmpfs
// pages it wrote count and the file cache it was charged does not. Where
// the kernel's memory.stat has no `kernel` line (before 5.18) `lesser` is
// true and `bytes` the lesser sum, of the parts of it that it names. A
// `measure` has an id of its own and names a place, and is answered under
// that id alone, as a home request is, from the last reading, never by a
// read of its own: `measured` with the place's kind, athanor and subject of
// the moment, the reading and its `age_ms`. A place the keeper does not
// hold, and one with no reading yet, are refused as CodeUnmeasured: no
// reading is ever answered as zero.
//
// The keeper counts who used what (package admission's counters): for each
// role, UTC day, athanor, kind and subject, a `counter` of the bytes its
// places' latest readings hold now, the `mib_ms` and `measured_ms` its
// readings measured, its `peak_bytes`, and the kills for memory at its
// places' releases, each `cap`, `machine` or `either` as the `exited`
// said. A counter's `athanor` and `subject` are absent where its places had
// none. A `report` has an id of its own and an `after`, a whole number
// within 0..MaxRev, and is answered `reported` under that id: the asking
// role's counters whose `rev` is past `after`, by rev, at most
// admission.ReportCounters of them, with `next`, the last one's rev, when
// more follow; another role's counters are never in it. Beside them it
// carries the keeper's `boot`, an id minted at each start, the machine's
// `budget`, `work` (W), `floor` (F where kept, else 0) and `used`, every
// charge outside the floor, and its `wall`: the keeper's own decision at
// its start of whether it gives each person a VM of their own, WallGiven,
// or spaces on the shared kernel, WallNoRoom where a first session in a VM
// does not fit and WallLacking for anything else it lacks (package serve's
// wallOf). Nothing a client sends sets it. Each change of a counter takes its role's next
// rev, from 1 at each boot, which is why every report carries the boot. A
// counter goes 48 hours after its last change, never while it holds bytes.
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
// its own exit or by the end of the client that asked for it, whichever
// pool it came from.
//
// Every spawn's command runs in a space of its own: a user, network and
// IPC namespace cloned for it, whose only mapping is its uid and gid to
// themselves, so the command keeps its uid, its home and its cgroup, holds
// no capability in any of the five sets, runs with no_new_privs under a
// filter that refuses every namespace and mount, and shares no abstract
// socket or System V object with anything else. What the space reaches is
// its pool's (`--pool <name>:<first>-<last>:<reach>` on the keeper's command
// line, package pool): a relay pool's space has its loopback down and no
// route, so a descriptor it inherited is its only way out; a routed pool's
// space has its own loopback, which no other space shares, and the one
// route its island's guard makes for it (package guard), whose resolver
// answers at 127.0.0.11:53 in the space itself.
//
// A spawn's `home_mode` is HomeScratch, today's home scrubbed at
// retirement, or HomeKept, a home that outlives the spawn: absent reads as
// HomeScratch. A kept spawn names its kept home by its id, `home`, and may
// bound it by `home_max_bytes`; both are refused without HomeKept. A
// spawn's `pty` asks for a pseudo-terminal of its `rows` and `cols`,
// exactly those two members, each 1..MaxPtySize; absent, the spawn has
// none. The `home_make`, `home_measure`, `home_reset` and `home_retire`
// requests name a kept home by its id, `home`, as a kept spawn does, and
// `home_make` names whose it is too, its `athanor`.
//
// The keeper alone knows its kept homes. Each person, an athanor, has one
// disk under its `--kept-homes <root>:<first>-<last>` (package home), owned
// by one uid of the range that is the disk's for its life: a home of each
// of the person's program rows, `programs/<home>`, and `work`, which every
// program of the person shares at /work. The keeper keeps its record of
// each disk, its uid and the homes it holds, beside the disk and never
// walks inside it; `home_make` alone names the athanor, and every other
// request finds a home by its id. A keeper given no --kept-homes refuses
// every home request and every kept spawn as CodeUnavailable. The keeper
// runs a kept spawn under its disk's uid in its home, with the disk's work
// folder at /work and no other home in sight, and takes no uid of the pool
// for it; one naming a home no disk holds is refused as CodeHomeAbsent, one
// whose place is another athanor's than its disk's as CodeBadRequest, and
// one whose home already holds home_max_bytes as CodeHomeOverCap. A `pty`
// spawn's stdin, stdout and stderr are a pseudo-terminal of the size it
// names, which its stdout frames carry; its stderr ends at once. A `resize`
// sets that terminal's size to its `rows` and `cols`, bounded as a spawn's
// `pty`, and the kernel signals SIGWINCH to the terminal's foreground
// process group; like `signal` it has no reply but a refusal:
// CodeUnknownSpawn for a spawn the keeper does not hold and CodeBadRequest
// for one without a pseudo-terminal.
//
// The home requests act as helpers running as the disk's uid, one request
// of a home at a time, each on a goroutine of its own, so two requests of
// one home sent together are applied in either order. `home_make` answers
// `home_made` with the disk's uid once the home is made on the disk of its
// athanor: the disk is made first if it is not, under the lowest uid of the
// range that no entry under the root owns, no disk's record holds, no
// process holds (the keeper's own read of /proc), no make holds
// and the keeper does not hold as retiring, quarantined or live; with every
// uid taken it is refused as CodeCapacity, and with a root or a /proc that
// cannot be read as CodeUnavailable. One naming a home another athanor's
// disk holds is refused as CodeBadRequest. `home_measure` answers
// `home_measured` with the bytes allocated under the home, an empty home's
// zero among them, or is refused as CodeHomeAbsent for a home no disk
// holds. `home_reset` ends every session of the home, by its group, and
// makes the home again empty, answered `home_made` with the disk's uid;
// `home_retire` ends them and removes the home from its disk, answered
// `home_retired`. Neither touches the disk's other homes, its work folder
// or its uid, and each answers `home_retired` for a home no disk holds.
// `home_list` answers `homes`: the ids of the homes the disks hold after
// its `after` (every home without one), in byte order, at most
// MaxHomeListIDs of them, with `next`, the last of them, when more follow,
// which the next `home_list` names as its `after`.
//
// A spawn's `hosts` names the only hosts its command may reach beyond
// the resolver and the deployment's private hosts: 1..MaxHosts distinct
// exact hostnames (ValidHost: lowercase, no wildcard, scheme, port or
// trailing dot, and no address literal). Absent keeps the island's
// public-hosts rule. A relay pool's spawn, which reaches nothing, is refused
// one as CodeBadRequest. The keeper resolves the names at the spawn, and only
// then, and has the guard make the space's route with exactly those
// addresses and no other public one; a spawn without `hosts` has a route of
// the island's rule. Each space has its own route, so the hosts of one
// session never change another's. The route is confirmed before the
// command starts: a name that resolves to no address refuses the spawn as
// CodeHostsUnresolved, and a guard that does not confirm the route as
// CodeGuardUnavailable; no routed spawn is ever started without its route.
// A guard confirms only once its greeting names the keeper's own network
// namespace: one that names another (a guard restarted into a new
// namespace while the keeper's still runs in the old) confirms nothing,
// and every routed spawn is refused until the service is recreated behind
// it. When the keeper's connection to the guard ends, the guard having
// died or its answer failed, the keeper kills every routed spawn before it
// dials again, and those spawns end as any killed spawn does.
//
// The keeper holds a read-only copy of each person's packs, one generation
// for each set digest, under its kept-homes root (package packview, which
// defines the stream, its manifest, the bounds and the cleanup rule). A
// `packs_hold` names an `athanor`, the `lifetime` of the start it is for
// and a set `digest` (`sha256:` and 64 lowercase hex digits), and is
// answered `packs` with `state` "held" when the keeper holds that
// generation complete and now holds it for the lifetime, or "missing".
// A `packs_put` sends the generation's stream, one part of at most
// MaxPackPartBytes bytes in base64 as its `data`, `seq` from 0 by one,
// `last` on the final part; each part is answered "taken", the last
// "held". A put refused (its stream, a bound, a manifest the files do not
// match, a seq out of order, a put idle or running past its bound) is
// refused as CodePacksRefused and leaves nothing behind; a put's first part
// while another put of its athanor is under way is refused as
// CodePacksBusy, and one while the most puts at once are under way as
// CodeUnavailable. A spawn's `packs` names a generation by
// its athanor and digest: the athanor must be its place's when the spawn
// claims it, which no assign changes from then, and the generation
// complete; the stage binds it read only at
// /run/cyfr/scrolls in the space, and binds nothing for a generation that
// holds no pack. A keeper given no --kept-homes, and a role whose spawns
// keep no home, refuse every packs request as CodeUnavailable.
//
// The client's environment carries ChannelEnv, the name /proc/self/fd/3
// links to for the channel socket (`socket:[inode]`), so a client whose
// runtime opens descriptors of its own before it can inspect fd 3 tells the
// inherited channel from one of those.
package protocol

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/cyfr/locus/keeper/internal/home"
)

// Version is the protocol version every message carries as `v`.
const Version = 9

// A place's kinds: a runner at rest and one given a run, a build, and a
// program's and a terminal's session.
const (
	KindWarm     = "warm"
	KindRun      = "run"
	KindBuild    = "build"
	KindProgram  = "program"
	KindTerminal = "terminal"
)

// Kinds are every kind a place may be.
var Kinds = []string{KindWarm, KindRun, KindBuild, KindProgram, KindTerminal}

// An `exited`'s `memory` values beside null.
const (
	// MemoryCap says that the spawn reached its own memory bound.
	MemoryCap = "cap"
	// MemoryMachine says that a limit above the spawn's, the container's or
	// the machine's, ended it.
	MemoryMachine = "machine"
	// MemoryEither says that one of the two ended it and that the counters
	// do not say which.
	MemoryEither = "either"
)

// A spawn's `home_mode` values.
const (
	HomeScratch = "scratch"
	HomeKept    = "kept"
)

// ChannelEnv is the client environment variable naming the channel socket.
const ChannelEnv = "KEEPER_CHANNEL"

// RunDirEnv is the client environment variable naming its role's run
// folder, which is at the same path inside its space and outside it: the
// client listens there for its spawns' relays.
const RunDirEnv = "KEEPER_RUN_DIR"

// Message types.
const (
	TypePlace        = "place"
	TypeDrop         = "drop"
	TypeAssign       = "assign"
	TypePlaced       = "placed"
	TypeAssigned     = "assigned"
	TypeSpawn        = "spawn"
	TypeSignal       = "signal"
	TypeResize       = "resize"
	TypeRelease      = "release"
	TypePool         = "pool"
	TypeMeasure      = "measure"
	TypeHomeMake     = "home_make"
	TypeHomeMeasure  = "home_measure"
	TypeHomeReset    = "home_reset"
	TypeHomeRetire   = "home_retire"
	TypeHomeList     = "home_list"
	TypeSpawned      = "spawned"
	TypeError        = "error"
	TypeExited       = "exited"
	TypeReleased     = "released"
	TypeMeasured     = "measured"
	TypeHomeMade     = "home_made"
	TypeHomeMeasured = "home_measured"
	TypeHomeRetired  = "home_retired"
	TypeHomes        = "homes"
	TypeReport       = "report"
	TypeReported     = "reported"
	TypePacksHold    = "packs_hold"
	TypePacksPut     = "packs_put"
	TypePacks        = "packs"
	TypeGiveWay      = "give_way"
)

// A `report`'s `wall` values: the keeper gives each person a VM of their
// own, or spaces because a first session in a VM does not fit its work
// pool, or spaces because it lacks anything else the wall needs.
const (
	WallGiven   = "given"
	WallNoRoom  = "no_room"
	WallLacking = "lacking"
)

// A `packs` reply's states.
const (
	PacksHeld    = "held"
	PacksMissing = "missing"
	PacksTaken   = "taken"
)

// Error codes carried by an `error` reply.
const (
	CodeBadRequest  = "bad_request"
	CodeUnknownPool = "unknown_pool"
	// CodeCapacity refuses a spawn its pool has no free uid for, and a
	// home_make of a new home with every kept uid taken.
	CodeCapacity     = "capacity"
	CodeExecFailed   = "exec_failed"
	CodeUnknownSpawn = "unknown_spawn"
	CodeNotRunning   = "not_running"
	CodeInternal     = "internal"
	// CodeMemoryUnavailable refuses a spawn whose memory and CPU bounds the
	// keeper cannot enforce where it runs.
	CodeMemoryUnavailable = "memory_unavailable"
	// CodeUnmeasured refuses a measure of a place the keeper does not hold
	// or that has no reading yet: what it uses is unknown.
	CodeUnmeasured = "unmeasured"
	// CodeHomeOverCap refuses a kept spawn whose home already holds its
	// home_max_bytes.
	CodeHomeOverCap = "home_over_cap"
	// CodeUIDBusy refuses a kept spawn on a disk's uid that is not free for
	// it: retiring (its last spawn released, its processes not yet all
	// ended) for longer than the spawn waits, or quarantined (a retirement
	// that could not finish).
	CodeUIDBusy = "uid_busy"
	// CodeHomeAbsent refuses a kept spawn or a home_measure naming a kept
	// home no disk holds.
	CodeHomeAbsent = "home_absent"
	// CodeUnavailable refuses every home request and kept spawn of a keeper
	// that keeps no homes (no --kept-homes), and a home_make whose root or
	// /proc cannot be read.
	CodeUnavailable = "unavailable"
	// CodeHostsUnresolved refuses a spawn one of whose hosts resolves to no
	// address.
	CodeHostsUnresolved = "hosts_unresolved"
	// CodeGuardUnavailable refuses a spawn whose egress the island's guard
	// did not confirm: no guard (--guard), a guard that cannot be reached
	// or judges another network namespace, or one that refused the change.
	CodeGuardUnavailable = "guard_unavailable"
	// CodePacksRefused refuses a packs_put whose stream the keeper does not
	// take (package packview): the put leaves nothing behind.
	CodePacksRefused = "packs_refused"
	// CodePacksBusy refuses a packs_put's first part while another put of
	// its athanor is under way: the start it is for holds again.
	CodePacksBusy = "packs_busy"
	// CodeNoMemory refuses a place the pool found no room for within
	// RoomWait, or could never hold; its reply carries Held.
	CodeNoMemory = "no_memory"
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
	// MaxUID is the highest uid or gid an account may hold: (uid_t)-1 is
	// no id.
	MaxUID = 4294967294
	// MaxHomeBytes is the most a kept home's bound may be, a number every
	// client's JSON carries exactly.
	MaxHomeBytes = 1 << 50
	// MaxAthanorBytes is the most a session's athanor ceiling may be, a
	// number every client's JSON carries exactly.
	MaxAthanorBytes = 1 << 50
	// MaxHosts is the most hosts a spawn may name.
	MaxHosts = 32
	// MaxPtySize is the most rows, and the most columns, a pseudo-terminal
	// may have.
	MaxPtySize = 1000
	// MaxHomeListIDs is the most ids one `homes` reply carries: a page of
	// the longest ids fits one frame's payload (frame.MaxPayload).
	MaxHomeListIDs = 512
	// MaxPackPartBytes is the most one packs_put part carries, before its
	// base64: a part's line stays within MaxLineBytes.
	MaxPackPartBytes = 512 << 10
	// MaxPackSeq is the highest seq a packs_put may carry: a set's stream
	// at its bounds is far fewer parts.
	MaxPackSeq = 1 << 16
	// MaxRev is the most a report's `after` may be, the most every client's
	// JSON carries exactly.
	MaxRev = 1<<53 - 1
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
	// athanorPattern is an athanor's id as every Locus wire gives it: 1 to
	// 256 printable ASCII characters, no space. Prima.RunnerControl's @id
	// holds the grammar.
	athanorPattern = regexp.MustCompile(`^[\x21-\x7E]{1,256}$`)
	// lifetimePattern is a start's lifetime as the backends wire gives it
	// (Prima.LocusBackends' lt_ ids), which the keeper keeps opaque.
	lifetimePattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	// digestPattern is a set digest: `sha256:` and 64 lowercase hex digits.
	digestPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
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
var Ceilings = Limits{Nofile: 1024, Nproc: 1024, Core: 0, Fsize: 256 << 20}

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

// SpawnPacks names a pack generation by its athanor and set digest.
type SpawnPacks struct {
	Athanor string `json:"athanor"`
	Digest  string `json:"digest"`
}

// Part is a parsed packs_put's part, decoded from its base64.
func (r *Request) Part() []byte { return r.part }

// ValidDigest reports whether d is a set digest.
func ValidDigest(d string) bool { return digestPattern.MatchString(d) }

// PtySize is a pseudo-terminal's size; a spawn's `pty` carries both members.
type PtySize struct {
	Rows *uint64 `json:"rows"`
	Cols *uint64 `json:"cols"`
}

// validatePtySize checks a pseudo-terminal's rows and columns: each present
// and within 1..MaxPtySize.
func validatePtySize(field string, rows, cols *uint64) error {
	for _, f := range []struct {
		name string
		v    *uint64
	}{{"rows", rows}, {"cols", cols}} {
		if f.v == nil || *f.v < 1 || *f.v > MaxPtySize {
			return fmt.Errorf("%s%s must be within 1..%d", field, f.name, MaxPtySize)
		}
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
	Control bool              `json:"control,omitempty"`
	Attach  *Attach           `json:"attach,omitempty"`
	// Place names a spawn's and a measure's place, and the place a drop or
	// an assign acts on.
	Place string `json:"place,omitempty"`
	// Kind, Athanor and Subject are whose a place or an assign says it is.
	Kind    string `json:"kind,omitempty"`
	Athanor string `json:"athanor,omitempty"`
	Subject string `json:"subject,omitempty"`
	// AthanorMax is a session's place's ceiling of its athanor's sessions.
	AthanorMax *uint64 `json:"athanor_max_bytes,omitempty"`
	SpawnID    string  `json:"spawn_id,omitempty"`
	Sig        string  `json:"sig,omitempty"`
	GraceMs    *int64  `json:"grace_ms,omitempty"`
	// HomeMode is HomeScratch, HomeKept or empty (HomeScratch);
	// HomeMaxBytes is set only on a HomeKept spawn.
	HomeMode     string  `json:"home_mode,omitempty"`
	HomeMaxBytes *uint64 `json:"home_max_bytes,omitempty"`
	// Home is the id of the kept home a HomeKept spawn or a home request
	// names (home.ValidID).
	Home string `json:"home,omitempty"`
	// After is what a home_list's or a report's page follows.
	After *Cursor `json:"after,omitempty"`
	// Pty is the size of a spawn's pseudo-terminal; nil, it has none.
	Pty *PtySize `json:"pty,omitempty"`
	// Hosts are the only hosts a spawn may reach (beside the resolver and
	// the private hosts); absent keeps the island's public-hosts rule.
	Hosts []string `json:"hosts,omitempty"`
	// Rows and Cols are a resize's new size.
	Rows *uint64 `json:"rows,omitempty"`
	Cols *uint64 `json:"cols,omitempty"`
	// Lifetime, Digest, Seq, Last and Data are a packs request's.
	Lifetime string  `json:"lifetime,omitempty"`
	Digest   string  `json:"digest,omitempty"`
	Seq      *uint64 `json:"seq,omitempty"`
	Last     *bool   `json:"last,omitempty"`
	Data     *string `json:"data,omitempty"`
	// Packs names the generation a spawn's space binds.
	Packs *SpawnPacks `json:"packs,omitempty"`

	// part is a packs_put's data, decoded.
	part []byte

	// present names the members the line carried, whatever their values:
	// a member is judged by its presence, never by a zero value standing
	// in for absence, so `"home_mode": ""` or `"control": false` on a
	// request that does not carry them is refused, as CYFR's codec refuses
	// them (Prima.KeeperProtocol).
	present map[string]bool
}

// Cursor is a request's `after`, remembering which JSON it was: a string,
// the kept home id a home_list's page follows, or a whole number within
// 0..MaxRev, the rev a report's page follows. Any other value decodes, so
// that its request is refused under its id.
type Cursor struct {
	form cursorForm
	id   string
	rev  uint64
}

type cursorForm uint8

const (
	cursorOther cursorForm = iota
	cursorID
	cursorRev
)

// revPattern is a JSON whole number: no sign, fraction or exponent.
var revPattern = regexp.MustCompile(`^(?:0|[1-9][0-9]*)$`)

// AfterID is the cursor of a home_list after the kept home id.
func AfterID(id string) *Cursor { return &Cursor{form: cursorID, id: id} }

// ID is the kept home id a string cursor names; "" for none and for any
// other cursor.
func (c *Cursor) ID() string {
	if c == nil || c.form != cursorID {
		return ""
	}
	return c.id
}

// Rev is the rev a whole-number cursor names, and whether it is one.
func (c *Cursor) Rev() (uint64, bool) {
	if c == nil || c.form != cursorRev {
		return 0, false
	}
	return c.rev, true
}

// UnmarshalJSON remembers a string, or a whole number within 0..MaxRev, and
// any other value as neither.
func (c *Cursor) UnmarshalJSON(data []byte) error {
	*c = Cursor{}
	switch {
	case len(data) > 0 && data[0] == '"':
		var id string
		if err := json.Unmarshal(data, &id); err != nil {
			return err
		}
		*c = Cursor{form: cursorID, id: id}
	case revPattern.Match(data):
		if rev, err := strconv.ParseUint(string(data), 10, 64); err == nil && rev <= MaxRev {
			*c = Cursor{form: cursorRev, rev: rev}
		}
	}
	return nil
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
	case TypeResize:
		if !req.only("spawn_id", "rows", "cols") {
			return nil, refuse("resize carries only spawn_id, rows and cols")
		}
		if !spawnIDPattern.MatchString(req.SpawnID) {
			return nil, refuse("spawn_id must be 32 lowercase hex digits")
		}
		if err := validatePtySize("", req.Rows, req.Cols); err != nil {
			return nil, refuse(err.Error())
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
	case TypeMeasure:
		if !req.only("id", "place") {
			return nil, refuse("measure carries only id and place")
		}
		if !idPattern.MatchString(req.ID) {
			return nil, refuse("id must match " + idPattern.String())
		}
		if !idPattern.MatchString(req.Place) {
			return nil, refuse("place must match " + idPattern.String())
		}
	case TypePlace:
		if !req.only("id", "kind", "athanor", "subject", "athanor_max_bytes") {
			return nil, refuse("place carries only id, kind, athanor, subject and athanor_max_bytes")
		}
		if !idPattern.MatchString(req.ID) {
			return nil, refuse("id must match " + idPattern.String())
		}
		if err := validateWhose(&req); err != nil {
			return nil, refuse(err.Error())
		}
		if m := req.AthanorMax; m != nil {
			if req.Kind != KindProgram && req.Kind != KindTerminal || !req.present["athanor"] {
				return nil, refuse("athanor_max_bytes is a session's place's, of its athanor")
			}
			if *m == 0 || *m > MaxAthanorBytes {
				return nil, refuse(fmt.Sprintf("athanor_max_bytes must be within 1..%d", uint64(MaxAthanorBytes)))
			}
		}
	case TypeAssign:
		if !req.only("id", "place", "kind", "athanor", "subject") {
			return nil, refuse("assign carries only id, place, kind, athanor and subject")
		}
		if !idPattern.MatchString(req.ID) {
			return nil, refuse("id must match " + idPattern.String())
		}
		if !idPattern.MatchString(req.Place) {
			return nil, refuse("place must match " + idPattern.String())
		}
		if err := validateWhose(&req); err != nil {
			return nil, refuse(err.Error())
		}
	case TypeDrop:
		if !req.only("place") {
			return nil, refuse("drop carries only place")
		}
		if !idPattern.MatchString(req.Place) {
			return nil, refuse("place must match " + idPattern.String())
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
	case TypeHomeMake:
		if !req.only("id", "home", "athanor") {
			return nil, refuse("home_make carries only id, home and athanor")
		}
		if !idPattern.MatchString(req.ID) {
			return nil, refuse("id must match " + idPattern.String())
		}
		if !home.ValidID(req.Home) {
			return nil, refuse("home must be a kept home's id")
		}
		if !athanorPattern.MatchString(req.Athanor) {
			return nil, refuse("athanor must match " + athanorPattern.String())
		}
	case TypeHomeMeasure, TypeHomeReset, TypeHomeRetire:
		if !req.only("id", "home") {
			return nil, refuse(req.Type + " carries only id and home")
		}
		if !idPattern.MatchString(req.ID) {
			return nil, refuse("id must match " + idPattern.String())
		}
		if !home.ValidID(req.Home) {
			return nil, refuse("home must be a kept home's id")
		}
	case TypeHomeList:
		if !req.only("id", "after") {
			return nil, refuse("home_list carries only id and after")
		}
		if !idPattern.MatchString(req.ID) {
			return nil, refuse("id must match " + idPattern.String())
		}
		if req.present["after"] && !home.ValidID(req.After.ID()) {
			return nil, refuse("after must be a kept home's id")
		}
	case TypeReport:
		if !req.only("id", "after") {
			return nil, refuse("report carries only id and after")
		}
		if !idPattern.MatchString(req.ID) {
			return nil, refuse("id must match " + idPattern.String())
		}
		if _, ok := req.After.Rev(); !ok {
			return nil, refuse(fmt.Sprintf("after must be a whole number within 0..%d", uint64(MaxRev)))
		}
	case TypePacksHold:
		if !req.only("id", "athanor", "lifetime", "digest") {
			return nil, refuse("packs_hold carries only id, athanor, lifetime and digest")
		}
		if err := validatePacks(&req); err != nil {
			return nil, refuse(err.Error())
		}
	case TypePacksPut:
		if !req.only("id", "athanor", "lifetime", "digest", "seq", "last", "data") {
			return nil, refuse("packs_put carries only id, athanor, lifetime, digest, seq, last and data")
		}
		if err := validatePacks(&req); err != nil {
			return nil, refuse(err.Error())
		}
		if req.Seq == nil || *req.Seq > MaxPackSeq {
			return nil, refuse(fmt.Sprintf("seq must be within 0..%d", MaxPackSeq))
		}
		if req.Last == nil {
			return nil, refuse("last is required")
		}
		if req.Data == nil {
			return nil, refuse("data is required")
		}
		if base64.StdEncoding.DecodedLen(len(*req.Data)) > MaxPackPartBytes+2 {
			return nil, refuse(fmt.Sprintf("data must be at most %d bytes", MaxPackPartBytes))
		}
		part, err := base64.StdEncoding.Strict().DecodeString(*req.Data)
		if err != nil || len(part) > MaxPackPartBytes {
			return nil, refuse(fmt.Sprintf("data must be the base64 of at most %d bytes", MaxPackPartBytes))
		}
		req.part = part
	default:
		return nil, refuse("unknown type")
	}
	return &req, nil
}

// validatePacks checks a packs request's id, athanor, lifetime and digest.
func validatePacks(req *Request) error {
	if !idPattern.MatchString(req.ID) {
		return errors.New("id must match " + idPattern.String())
	}
	if !athanorPattern.MatchString(req.Athanor) {
		return errors.New("athanor must match " + athanorPattern.String())
	}
	if !lifetimePattern.MatchString(req.Lifetime) {
		return errors.New("lifetime must match " + lifetimePattern.String())
	}
	if !digestPattern.MatchString(req.Digest) {
		return errors.New("digest must match " + digestPattern.String())
	}
	return nil
}

// validateWhose checks whose a place or an assign says it is: one of Kinds,
// and an athanor of the athanor grammar and a subject of the id grammar,
// each optional.
func validateWhose(req *Request) error {
	if !contains(Kinds, req.Kind) {
		return errors.New("kind must be one of " + strings.Join(Kinds, ", "))
	}
	if req.present["athanor"] && !athanorPattern.MatchString(req.Athanor) {
		return errors.New("athanor must match " + athanorPattern.String())
	}
	if req.present["subject"] && !idPattern.MatchString(req.Subject) {
		return errors.New("subject must match " + idPattern.String())
	}
	return nil
}

func validateSpawn(req *Request) error {
	if !req.only("id", "place", "pool", "argv", "env", "rlimits", "control", "attach", "home_mode", "home", "home_max_bytes", "pty", "hosts", "packs") {
		return errors.New("spawn carries only id, place, pool, argv, env, rlimits, control, attach, home_mode, home, home_max_bytes, pty, hosts and packs")
	}
	if p := req.Packs; p != nil && (!athanorPattern.MatchString(p.Athanor) || !digestPattern.MatchString(p.Digest)) {
		return errors.New("packs must name an athanor and a set digest")
	}
	if !idPattern.MatchString(req.ID) {
		return errors.New("id must match " + idPattern.String())
	}
	if !idPattern.MatchString(req.Place) {
		return errors.New("place must match " + idPattern.String())
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
	if err := ValidateAttach(*req.Attach); err != nil {
		return err
	}
	if err := validateHosts(req); err != nil {
		return err
	}
	if req.Pty != nil {
		if err := validatePtySize("pty.", req.Pty.Rows, req.Pty.Cols); err != nil {
			return err
		}
	}
	return validateHome(req)
}

// validateHosts checks a spawn's hosts: when present, 1..MaxHosts distinct
// exact hostnames.
func validateHosts(req *Request) error {
	if !req.present["hosts"] {
		return nil
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
		if req.present["home"] || req.present["home_max_bytes"] {
			return errors.New("home and home_max_bytes need home_mode " + HomeKept)
		}
		return nil
	case HomeKept:
	default:
		return errors.New("home_mode must be " + HomeScratch + " or " + HomeKept)
	}
	if !home.ValidID(req.Home) {
		return errors.New("home must be a kept home's id with home_mode " + HomeKept)
	}
	if b := req.HomeMaxBytes; b != nil && (*b < 1 || *b > MaxHomeBytes) {
		return fmt.Errorf("home_max_bytes must be within 1..%d", uint64(MaxHomeBytes))
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

// ErrorReply refuses the request named by ID (place, assign, spawn, pool,
// home, measure) or SpawnID (signal, resize, release). A spawn refused once
// the keeper made it carries both: SpawnID is then the id its `released`
// carries.
type ErrorReply struct {
	V       int    `json:"v"`
	Type    string `json:"type"`
	ID      string `json:"id,omitempty"`
	SpawnID string `json:"spawn_id,omitempty"`
	Code    string `json:"code"`
	// Held is a CodeNoMemory refusal's account of the pool, and only its.
	Held *Held `json:"held,omitempty"`
}

// Held says what holds a pool that refused a place: what the place needs,
// what was free, the charges of its own athanor's places and the sum of
// every other's.
type Held struct {
	Need   uint64    `json:"need"`
	Free   uint64    `json:"free"`
	Mine   []Holding `json:"mine"`
	Others uint64    `json:"others_bytes"`
}

// Holding is one place of the asking place's athanor in a Held: its kind,
// its subject only where the place is the asking role's, and its charge.
type Holding struct {
	Kind    string `json:"kind"`
	Subject string `json:"subject,omitempty"`
	Bytes   uint64 `json:"bytes"`
}

// NewError builds an `error` reply.
func NewError(id, spawnID, code string) ErrorReply {
	return ErrorReply{V: Version, Type: TypeError, ID: id, SpawnID: spawnID, Code: code}
}

// NewNoMemory builds the CodeNoMemory refusal of the place id.
func NewNoMemory(id string, held Held) ErrorReply {
	if held.Mine == nil {
		held.Mine = []Holding{}
	}
	return ErrorReply{V: Version, Type: TypeError, ID: id, Code: CodeNoMemory, Held: &held}
}

// GiveWay asks the floor's role to release the idle runner of its place.
type GiveWay struct {
	V     int    `json:"v"`
	Type  string `json:"type"`
	Place string `json:"place"`
}

// NewGiveWay builds a `give_way` message.
func NewGiveWay(place string) GiveWay {
	return GiveWay{V: Version, Type: TypeGiveWay, Place: place}
}

// Exited reports a leader's end: its exit code, or the signal that ended it,
// and what memory limit the kernel killed processes of the spawn for.
type Exited struct {
	V       int     `json:"v"`
	Type    string  `json:"type"`
	SpawnID string  `json:"spawn_id"`
	Code    *int    `json:"code"`
	Signal  *string `json:"signal"`
	// Memory is MemoryCap, MemoryMachine, MemoryEither or nil.
	Memory *string `json:"memory"`
}

// NewExited builds an `exited` reply; exactly one of code and signal is set.
func NewExited(spawnID string, code *int, signal, memory *string) Exited {
	return Exited{V: Version, Type: TypeExited, SpawnID: spawnID, Code: code, Signal: signal, Memory: memory}
}

// Placed admits a `place`, with the memory bound its spawn will have.
type Placed struct {
	V           int    `json:"v"`
	Type        string `json:"type"`
	ID          string `json:"id"`
	MemoryBytes uint64 `json:"memory_bytes"`
}

// NewPlaced builds a `placed` reply.
func NewPlaced(id string, memoryBytes uint64) Placed {
	return Placed{V: Version, Type: TypePlaced, ID: id, MemoryBytes: memoryBytes}
}

// Assigned acknowledges an `assign` once the keeper applied it.
type Assigned struct {
	V    int    `json:"v"`
	Type string `json:"type"`
	ID   string `json:"id"`
}

// NewAssigned builds an `assigned` reply.
func NewAssigned(id string) Assigned {
	return Assigned{V: Version, Type: TypeAssigned, ID: id}
}

// Whose is whose a place is: its kind, and its athanor and subject where it
// has them.
type Whose struct {
	Kind    string `json:"kind"`
	Athanor string `json:"athanor,omitempty"`
	Subject string `json:"subject,omitempty"`
}

// Reading is one reading of a group: the bytes it uses that cannot be
// given back, and whether they are the lesser sum of a kernel with no
// `kernel` count.
type Reading struct {
	Bytes  uint64 `json:"bytes"`
	Lesser bool   `json:"lesser"`
}

// Measured answers the `measure` named by ID: whose the place is, its last
// reading and that reading's age in milliseconds.
type Measured struct {
	V    int    `json:"v"`
	Type string `json:"type"`
	ID   string `json:"id"`
	Whose
	Reading
	AgeMs uint64 `json:"age_ms"`
}

// NewMeasured builds a `measured` reply.
func NewMeasured(id string, whose Whose, reading Reading, ageMs uint64) Measured {
	return Measured{V: Version, Type: TypeMeasured, ID: id, Whose: whose, Reading: reading, AgeMs: ageMs}
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

// HomeMade answers a `home_make` or a `home_reset` with the made home's uid.
type HomeMade struct {
	V    int    `json:"v"`
	Type string `json:"type"`
	ID   string `json:"id"`
	UID  int    `json:"uid"`
}

// NewHomeMade builds a `home_made` reply.
func NewHomeMade(id string, uid int) HomeMade {
	return HomeMade{V: Version, Type: TypeHomeMade, ID: id, UID: uid}
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

// HomeRetired acknowledges a `home_retire`, or a `home_reset` of a home not
// made.
type HomeRetired struct {
	V    int    `json:"v"`
	Type string `json:"type"`
	ID   string `json:"id"`
}

// NewHomeRetired builds a `home_retired` reply.
func NewHomeRetired(id string) HomeRetired {
	return HomeRetired{V: Version, Type: TypeHomeRetired, ID: id}
}

// Homes answers a `home_list` with one page of kept home ids, and Next, the
// last of them, when more follow.
type Homes struct {
	V    int      `json:"v"`
	Type string   `json:"type"`
	ID   string   `json:"id"`
	IDs  []string `json:"ids"`
	Next string   `json:"next,omitempty"`
}

// NewHomes builds a `homes` reply; no ids are an empty list.
func NewHomes(id string, ids []string, next string) Homes {
	if ids == nil {
		ids = []string{}
	}
	return Homes{V: Version, Type: TypeHomes, ID: id, IDs: ids, Next: next}
}

// Reported answers a `report` with the asking role's page of counters.
type Reported struct {
	V      int    `json:"v"`
	Type   string `json:"type"`
	ID     string `json:"id"`
	Report Report `json:"report"`
}

// Report is a page of one role's counters, past a rev, beside the keeper's
// boot, the machine's numbers and its wall. Next, the last counter's rev,
// is set only when more follow; every rev is at least 1.
type Report struct {
	Boot     string    `json:"boot"`
	Budget   uint64    `json:"budget"`
	Work     uint64    `json:"work"`
	Floor    uint64    `json:"floor"`
	Used     uint64    `json:"used"`
	Wall     string    `json:"wall"`
	Counters []Counter `json:"counters"`
	Next     uint64    `json:"next,omitempty"`
}

// Counter is what the keeper counted of one role's places of one kind,
// athanor and subject on one UTC day ("YYYY-MM-DD"), as of its last change,
// Rev.
type Counter struct {
	Rev        uint64 `json:"rev"`
	Day        string `json:"day"`
	Athanor    string `json:"athanor,omitempty"`
	Kind       string `json:"kind"`
	Subject    string `json:"subject,omitempty"`
	Bytes      uint64 `json:"bytes"`
	MiBMs      uint64 `json:"mib_ms"`
	MeasuredMs uint64 `json:"measured_ms"`
	PeakBytes  uint64 `json:"peak_bytes"`
	Cap        uint64 `json:"cap"`
	Machine    uint64 `json:"machine"`
	Either     uint64 `json:"either"`
}

// NewReported builds a `reported` reply; no counters are an empty list.
func NewReported(id string, report Report) Reported {
	if report.Counters == nil {
		report.Counters = []Counter{}
	}
	return Reported{V: Version, Type: TypeReported, ID: id, Report: report}
}

// PacksReply answers a packs_hold or a packs_put.
type PacksReply struct {
	V     int    `json:"v"`
	Type  string `json:"type"`
	ID    string `json:"id"`
	State string `json:"state"`
}

// NewPacksReply builds a `packs` reply.
func NewPacksReply(id, state string) PacksReply {
	return PacksReply{V: Version, Type: TypePacks, ID: id, State: state}
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

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/pool"
	"github.com/cyfr/locus/keeper/internal/procfs"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/relay"
	"github.com/cyfr/locus/keeper/internal/residue"
	"github.com/cyfr/locus/keeper/internal/retire"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// Exit statuses of `cyfr-locus serve`.
const (
	// ExitStopped follows a termination signal forwarded to the client.
	ExitStopped = 0
	// ExitUsage reports a malformed command line.
	ExitUsage = 64
	// ExitLost reports that the client or its channel went away unasked.
	ExitLost = 70
	// ExitStart reports that the client could not be started.
	ExitStart = 71
	// ExitConfig reports a privilege or environment the keeper refuses.
	ExitConfig = 78
)

const (
	// leaderExitGrace is the grace given to the rest of a spawn's processes
	// once its leader has exited.
	leaderExitGrace = 2 * time.Second
	// lostGrace is the grace given to every spawn when the channel is lost.
	lostGrace = time.Second
	// stageTimeout bounds a stage from start to exec.
	stageTimeout = 10 * time.Second
	// clearTimeout bounds the wait for a retired uid's last zombies.
	clearTimeout = 2 * time.Second
	// sweepInterval is how often quarantined uids are retried.
	sweepInterval = 5 * time.Second
	// scrubPasses bounds the retirements of one uid before it is quarantined.
	scrubPasses = 3
	// writeTimeout bounds one reply; a client that stops reading for this
	// long is treated as lost.
	writeTimeout = 30 * time.Second
)

// Main runs `cyfr-locus serve` with the arguments after the subcommand.
func Main(args []string) int {
	log := logx.New("cyfr-locus")
	cfg, err := ParseArgs(args)
	if err != nil {
		log.Error("%v; usage: %s", err, Usage)
		return ExitUsage
	}
	if err := CheckEnviron(os.Environ()); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}

	raw, err := os.ReadFile("/proc/self/status")
	if err != nil {
		log.Error("reading /proc/self/status: %v", err)
		return ExitConfig
	}
	st, err := procfs.ParseStatus(raw)
	if err != nil {
		log.Error("%v", err)
		return ExitConfig
	}
	if err := procfs.CheckKeeperCaps(st); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	// no_new_privs is per thread; setting it on every thread makes every
	// process this one starts inherit it.
	if _, _, errno := syscall.AllThreadsSyscall(unix.SYS_PRCTL, unix.PR_SET_NO_NEW_PRIVS, 1, 0); errno != 0 {
		log.Error("refusing to start: PR_SET_NO_NEW_PRIVS: %v", errno)
		return ExitConfig
	}
	if err := unix.Prctl(unix.PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0); err != nil {
		log.Error("refusing to start: PR_SET_CHILD_SUBREAPER: %v", err)
		return ExitConfig
	}
	if err := home.CheckRoot(cfg.HomeRoot); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	client, accounts, err := ResolveAccounts(cfg, SystemLookup)
	if err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	mounts, roots, err := residue.ReadRoots()
	if err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	keptRoot := ""
	if cfg.Kept != nil {
		if err := home.CheckKeptRoot(cfg.Kept.Root, client.GID); err != nil {
			log.Error("refusing to start: %v", err)
			return ExitConfig
		}
		keptRoot = cfg.Kept.Root
	}
	if err := residue.CheckMounts(mounts, cfg.HomeRoot, keptRoot, PoolAccounts(accounts)); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	self, err := os.Executable()
	if err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	// A stage keeps the keeper's supplementary groups, since its namespace
	// denies setgroups: they are cleared here first.
	if err := syscall.Setgroups([]int{}); err != nil {
		log.Error("refusing to start: clearing the supplementary groups: %v", err)
		return ExitConfig
	}
	if err := probeSpaces(self, cfg, accounts); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}

	s := &server{
		cfg:       cfg,
		log:       log,
		self:      self,
		client:    client,
		accounts:  accounts,
		roots:     roots,
		pools:     map[string]*pool.Pool{},
		spawns:    map[string]*spawn{},
		places:    map[string]*place{},
		unremoved: map[*spawn]*removal{},
		waiters:   map[int]*child{},
		keptLive:  map[int]int{},
		keptOps:   map[int]*sync.Mutex{},
	}
	for _, spec := range cfg.Pools {
		s.pools[spec.Name] = pool.New(spec)
	}
	if cfg.Guard != "" {
		netns, err := os.Readlink("/proc/self/ns/net")
		if err != nil {
			log.Error("refusing to start: reading this network namespace: %v", err)
			return ExitConfig
		}
		s.guard = guard.NewClient(cfg.Guard, netns, s.guardLost)
		for _, spec := range cfg.Pools {
			if spec.Routed() {
				if err := s.proveGuard(spec); err != nil {
					log.Error("refusing to start: %v", err)
					return ExitConfig
				}
				break
			}
		}
		log.Info("egress: every routed space's route is made by the guard on %s before it starts", cfg.Guard)
	}
	s.memory = delegateMemory(log)
	return s.run()
}

// spaceAttr is how the keeper starts every spawn's stage: in a session of
// its own, killed if this keeper dies, cloned into a new user, network and
// IPC namespace, which takes no capability of the keeper's own namespace,
// and holding as ambient capabilities, inside that namespace only, what the
// stage needs there to become the pooled ids, bring a routed space's
// loopback up and bind its name sockets, build the space's files in a mount
// namespace it owns, and drop every set. It keeps the keeper's ids until
// the keeper has mapped them. A pty spawn's command takes its terminal as
// its controlling one, in the space's own session (package stage).
func spaceAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{
		Setsid:     true,
		Pdeathsig:  syscall.SIGKILL,
		Cloneflags: unix.CLONE_NEWUSER | unix.CLONE_NEWNET | unix.CLONE_NEWIPC,
		AmbientCaps: []uintptr{unix.CAP_SETUID, unix.CAP_SETGID, unix.CAP_SETPCAP, unix.CAP_SYS_ADMIN,
			unix.CAP_NET_ADMIN, unix.CAP_NET_BIND_SERVICE},
	}
}

// mapIDs maps a cloned stage's uid and gid to themselves from the parent
// side, the one side that may map an id the child could not: setgroups is
// denied first, as a gid map written from outside requires, then gid_map,
// then uid_map. The keeper holds SETUID and SETGID in its own namespace,
// which is what these writes take.
func mapIDs(pid, uid, gid int) error {
	proc := filepath.Join("/proc", strconv.Itoa(pid))
	for _, w := range []struct{ file, content string }{
		{"setgroups", "deny"},
		{"gid_map", strconv.Itoa(gid) + " " + strconv.Itoa(gid) + " 1\n"},
		{"uid_map", strconv.Itoa(uid) + " " + strconv.Itoa(uid) + " 1\n"},
	} {
		// Each map is written whole by one write at offset 0, as the kernel
		// takes it.
		f, err := os.OpenFile(filepath.Join(proc, w.file), os.O_WRONLY, 0)
		if err == nil {
			_, err = f.Write([]byte(w.content))
			if cerr := f.Close(); err == nil {
				err = cerr
			}
		}
		if err != nil {
			return fmt.Errorf("writing %s: %w", w.file, err)
		}
	}
	return nil
}

// probeSpaces proves, before the keeper serves, that this host gives each of
// its pools' spawns its space: for every reach the keeper serves it clones a
// stage as it clones every spawn's, maps the first uid of the first pool of
// that reach, and waits for the stage to become it, bring up a routed
// space's loopback and bind its name sockets, clone the space's first
// process, which builds the space's files and pivots into them, and with it
// drop every capability set, pass the check a spawn's stage makes before it
// executes anything and install the space's filter. A host that refuses any
// step refuses the keeper, naming what to check: there is no weaker space.
func probeSpaces(self string, cfg Config, accounts map[int]Account) error {
	probed := map[string]bool{}
	for _, spec := range cfg.Pools {
		if probed[spec.Reach] {
			continue
		}
		probed[spec.Reach] = true
		if err := probeSpace(self, spec, accounts[spec.First]); err != nil {
			return err
		}
	}
	return nil
}

// probeSpace is probeSpaces's proof for one pool's reach.
func probeSpace(self string, spec pool.Spec, acct Account) error {
	refuse := func(err error) error {
		return fmt.Errorf("pool %s's spawns run in a space of their own, a user, network, IPC, pid, mount and cgroup namespace with files of its own (%s), "+
			"and this host does not let cyfr-locus make one: %w; the host must allow unprivileged user namespaces (check user.max_user_namespaces, above 0, "+
			"and, where AppArmor restricts them, kernel.apparmor_restrict_unprivileged_userns, which the profile below satisfies), "+
			"and the container must run under the seccomp profile apps/locus/keeper/seccomp/keeper.json (/etc/cyfr/keeper.json in the image), which lets "+
			"clone make them and a space mount its files, with its system paths unmasked (security_opt systempaths=unconfined), since a masked /proc "+
			"lets no space mount its own, and, on a host with AppArmor, under the profile apps/locus/keeper/seccomp/cyfr-locus, which `cyfr init` and "+
			"`cyfr update` load (security_opt apparmor=cyfr-locus)", spec.Name, spec.Reach, err)
	}
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		return err
	}
	defer devnull.Close()
	specR, specW, err := os.Pipe()
	if err != nil {
		return err
	}
	defer specW.Close()
	statusR, statusW, err := os.Pipe()
	if err != nil {
		specR.Close()
		return err
	}
	defer statusR.Close()
	pid, err := syscall.ForkExec(self, []string{"cyfr-locus", "stage", stage.ProbeArg}, &syscall.ProcAttr{
		Dir:   "/",
		Env:   []string{},
		Files: []uintptr{devnull.Fd(), devnull.Fd(), devnull.Fd(), specR.Fd(), statusW.Fd()},
		Sys:   spaceAttr(),
	})
	specR.Close()
	statusW.Close()
	if err != nil {
		return refuse(fmt.Errorf("cloning: %w", err))
	}
	reap := func() unix.WaitStatus {
		var ws unix.WaitStatus
		for {
			if _, err := unix.Wait4(pid, &ws, 0, nil); !errors.Is(err, unix.EINTR) {
				return ws
			}
		}
	}
	if err := mapIDs(pid, acct.UID, acct.GID); err != nil {
		_ = unix.Kill(pid, unix.SIGKILL)
		reap()
		return refuse(err)
	}
	probe, err := json.Marshal(stage.Probe{UID: acct.UID, GID: acct.GID, Routed: spec.Routed()})
	if err == nil {
		_, err = specW.Write(probe)
	}
	_ = specW.Close()
	_ = statusR.SetReadDeadline(time.Now().Add(stageTimeout))
	// The status pipe closes when the stage exits; a stage that neither
	// answers nor exits within the bound is killed, so the reap below ends.
	reason, rerr := io.ReadAll(io.LimitReader(statusR, 4096))
	if err == nil {
		err = rerr
	}
	if err != nil || len(reason) > 0 {
		_ = unix.Kill(pid, unix.SIGKILL)
	}
	ws := reap()
	switch {
	case err != nil:
		return refuse(err)
	case len(reason) > 0:
		return refuse(errors.New("the cloned stage: " + string(reason)))
	case !ws.Exited() || ws.ExitStatus() != 0:
		return refuse(fmt.Errorf("the cloned stage ended %v", ws))
	}
	return nil
}

// proveGuard proves, before a routed keeper serves, that its guard makes a
// space's route: a probe stage of pool spec's first uid, in a space of its
// own, hands its namespace and name sockets up; the guard admits a route
// with them, and once the stage has ended, clears it. A guard that does
// either otherwise, or none at all, refuses the keeper by name.
func (s *server) proveGuard(spec pool.Spec) error {
	refuse := func(err error) error {
		return fmt.Errorf("pool %s's spaces are routed, and its guard on %s does not make a route: %w", spec.Name, s.cfg.Guard, err)
	}
	acct := s.accounts[spec.First]
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		return err
	}
	defer devnull.Close()
	specR, specW, err := os.Pipe()
	if err != nil {
		return err
	}
	defer specW.Close()
	statusR, statusW, err := os.Pipe()
	if err != nil {
		specR.Close()
		return err
	}
	defer statusR.Close()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		specR.Close()
		statusW.Close()
		return err
	}
	stageRoute, keeperRoute := os.NewFile(uintptr(fds[0]), "probe-route"), os.NewFile(uintptr(fds[1]), "probe-route-keeper")
	defer keeperRoute.Close()
	pid, err := syscall.ForkExec(s.self, []string{"cyfr-locus", "stage", stage.ProbeArg}, &syscall.ProcAttr{
		Dir:   "/",
		Env:   []string{},
		Files: []uintptr{devnull.Fd(), devnull.Fd(), devnull.Fd(), specR.Fd(), statusW.Fd(), ^uintptr(0), stageRoute.Fd()},
		Sys:   spaceAttr(),
	})
	specR.Close()
	statusW.Close()
	stageRoute.Close()
	if err != nil {
		return refuse(fmt.Errorf("cloning its probe: %w", err))
	}
	reaped := false
	reap := func() unix.WaitStatus {
		var ws unix.WaitStatus
		for !reaped {
			if _, err := unix.Wait4(pid, &ws, 0, nil); !errors.Is(err, unix.EINTR) {
				reaped = true
			}
		}
		return ws
	}
	defer func() {
		if !reaped {
			_ = unix.Kill(pid, unix.SIGKILL)
			reap()
		}
	}()
	if err := mapIDs(pid, acct.UID, acct.GID); err != nil {
		return refuse(err)
	}
	probe, err := json.Marshal(stage.Probe{UID: acct.UID, GID: acct.GID, Routed: true, Route: true})
	if err == nil {
		_, err = specW.Write(probe)
	}
	_ = specW.Close()
	if err != nil {
		return refuse(err)
	}
	_ = keeperRoute.SetReadDeadline(time.Now().Add(stageTimeout))
	files, err := receiveRoute(keeperRoute)
	if err != nil {
		return refuse(fmt.Errorf("its probe's descriptors: %w", err))
	}
	id := randomHex(16)
	r, err := s.guard.Admit(id, guard.ReachIsland, nil, files[0], files[1], files[2])
	for _, f := range files {
		_ = f.Close()
	}
	if err != nil {
		return refuse(err)
	}
	if _, err := keeperRoute.Write([]byte{stage.RouteGo}); err != nil {
		return refuse(err)
	}
	_ = statusR.SetReadDeadline(time.Now().Add(stageTimeout))
	reason, _ := io.ReadAll(io.LimitReader(statusR, 4096))
	ws := reap()
	if len(reason) > 0 || !ws.Exited() || ws.ExitStatus() != 0 {
		return refuse(fmt.Errorf("its probe ended %v: %s", ws, reason))
	}
	if err := s.guard.Clear(id, r); err != nil {
		return refuse(fmt.Errorf("the probe route was not cleared: %w", err))
	}
	return nil
}

// delegateMemory prepares the keeper's cgroup for spawns bounded in memory
// and CPU, or reports why spawns will be refused here.
func delegateMemory(log *logx.Logger) *cgroup.Manager {
	self, err := os.ReadFile(cgroup.SelfPath)
	if err != nil {
		log.Info("memory and CPU bounds are unavailable; spawns are refused: %v", err)
		return nil
	}
	m, err := cgroup.Delegate(cgroup.Root, self)
	if err != nil {
		log.Info("memory and CPU bounds are unavailable; spawns are refused: %v", err)
		return nil
	}
	log.Info("memory and CPU bounds are enforced: a cgroup under %s for each spawn", cgroup.Root)
	return m
}

// child is a process this keeper started and will reap.
type child struct {
	pid    int
	done   chan struct{}
	status unix.WaitStatus
}

func (c *child) reaped() bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

// spawn is one allocation: a uid, its home, its leader and its relay. A
// kept spawn runs under its kept home's uid in that home, and has no pool:
// several kept spawns may share a uid, and the uid is never a pool's.
type spawn struct {
	id      string
	pool    *pool.Pool
	kept    bool
	account Account
	home    string
	leader  *child
	relay   *child
	// group is the spawn's memory-bounded cgroup, nil until it is created.
	group *cgroup.Group
	// place is the id of the place the spawn was made in, set as it is
	// made; its retirement frees the place in the step that follows its
	// group's removal, so no measure answers a place whose spawn's group is
	// gone, and no place goes while its group stays.
	place string
	// reading says a read of the spawn's group is out: no other starts
	// until it returns.
	reading atomic.Bool
	// reach is the spawn's space's, its pool's (package pool).
	reach string
	// route is a routed spawn's route, set once the guard admitted it over
	// a connection that had not ended, and nil again once withdrawn; s.mu
	// guards it.
	route *guard.Route
	// pty is the keeper's own descriptor of the master of the spawn's
	// pseudo-terminal, which a `resize` sets the size through; nil for a
	// spawn without one. s.mu guards it once the spawn is in spawns, and
	// the retirement that removes the spawn from spawns closes it.
	pty *os.File

	// exitOnce settles the leader's one `exited`, sent or never to be:
	// whichever of its watcher and the retirement comes first reads the
	// cause and settles it, and the other waits for that. It is settled
	// before `released`, so no exit follows one, and at the refusal of a
	// spawn refused once made, which was never spawned and is owed none.
	exitOnce sync.Once
	// retired closes when retirement has finished.
	retired    chan struct{}
	retireOnce sync.Once
}

type server struct {
	cfg      Config
	log      *logx.Logger
	self     string
	client   Account
	accounts map[int]Account
	// roots are the writable mounts and the mqueue mount a pooled uid can
	// leave something behind in.
	roots residue.Roots
	// memory makes the cgroups of memory-bounded spawns; nil where the
	// keeper cannot, and a spawn asking for a bound is refused.
	memory *cgroup.Manager
	// guard makes each routed space's route (--guard); nil for a keeper
	// whose pools are all relay pools.
	guard routeGuard

	// mu guards pools, spawns, places, unremoved and waiters, and is held
	// across every fork, reap and signal, so a pid is never signalled after
	// it was reaped.
	mu     sync.Mutex
	pools  map[string]*pool.Pool
	spawns map[string]*spawn
	places map[string]*place
	// unremoved holds every retired spawn whose group could not be removed,
	// out of spawns, with what its retirement leaves to the retry that
	// removes the group: until then its place stays, read as a live
	// spawn's is, and a pooled uid stays out of its pool.
	unremoved map[*spawn]*removal
	// routing holds every routed spawn from before its admit until its
	// retirement ends, so the end of the guard's connection finds every
	// space routed over it (guardLost); lostRoutes names each connection
	// that ended, so an admit answered over one is never recorded.
	routing    map[string]*spawn
	lostRoutes map[uint64]bool
	// uncleared holds every withdrawn spawn's route the guard has not yet
	// said cleared, by spawn id, asked again at each sweep.
	uncleared map[string]guard.Route
	// exit ends the keeper (os.Exit in production) and groupKilled kills a
	// spawn's group and answers whether it is empty (killGroup); tests set
	// either.
	exit        func(code int)
	groupKilled func(sp *spawn) bool
	waiters     map[int]*child
	// keptLive counts the live spawns of each kept home's uid; keptOps
	// holds each such uid's lock, which a spawn's start, the uid's full
	// retirement and a home request take, so none of them interleaves
	// with another of the same uid. A kept uid follows a pooled uid's
	// discipline: keptHomes names the home a live uid runs in; from the
	// release of its last spawn until every process of it is ended and
	// nothing it left remains, it is retiring (keptRetiring, its channel
	// closed at the end); a retirement that cannot finish quarantines it
	// (keptQuarantined, naming its home) until the sweeper's retry does.
	keptLive        map[int]int
	keptEnding      map[int]int // a kept uid's released spawns still ending in order (retireKept)
	keptOps         map[int]*sync.Mutex
	keptHomes       map[int]string
	keptRetiring    map[int]chan struct{}
	keptQuarantined map[int]string

	channel  *os.File
	writeMu  sync.Mutex
	stopping atomic.Bool
	closing  atomic.Bool
}

func (s *server) run() int {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		s.log.Error("socketpair: %v", err)
		return ExitStart
	}
	if err := unix.SetNonblock(fds[0], true); err != nil {
		s.log.Error("socketpair: %v", err)
		return ExitStart
	}
	s.channel = os.NewFile(uintptr(fds[0]), "channel")
	theirs := os.NewFile(uintptr(fds[1]), "client-channel")

	sigchld := make(chan os.Signal, 1)
	signal.Notify(sigchld, unix.SIGCHLD)
	stop := make(chan os.Signal, 4)
	signal.Notify(stop, unix.SIGTERM, unix.SIGINT, unix.SIGHUP)
	go s.reaper(sigchld)

	argv0, err := lookPathIn(s.cfg.ClientArgv[0], os.Getenv("PATH"))
	if err != nil {
		s.log.Error("client command: %v", err)
		return ExitStart
	}
	channelID, err := socketID(theirs)
	if err != nil {
		s.log.Error("socketpair: %v", err)
		return ExitStart
	}
	clientProc, err := s.start(argv0, s.cfg.ClientArgv, ClientEnviron(os.Environ(), s.client, channelID, s.cfg.Kept),
		[]uintptr{0, 1, 2, theirs.Fd()}, s.client.UID, s.client.GID, "")
	theirs.Close()
	if err != nil {
		s.log.Error("starting the client: %v", err)
		return ExitStart
	}
	s.log.Info("client pid %d started as %s; pools %v", clientProc.pid, s.client.Name, s.cfg.Pools)

	lost := make(chan struct{})
	go func() {
		s.serveChannel()
		close(lost)
	}()
	go s.sweeper()
	reading := make(chan struct{})
	defer close(reading)
	go s.reader(reading)

loop:
	for {
		select {
		case sig := <-stop:
			if sig != unix.SIGHUP {
				s.stopping.Store(true)
			}
			s.signalChild(clientProc, sig.(syscall.Signal))
		case <-lost:
			break loop
		case <-clientProc.done:
			break loop
		}
	}

	s.closing.Store(true)
	_ = s.channel.Close()
	s.signalChild(clientProc, unix.SIGKILL)
	s.mu.Lock()
	live := make([]*spawn, 0, len(s.spawns))
	for _, sp := range s.spawns {
		live = append(live, sp)
	}
	s.mu.Unlock()
	for _, sp := range live {
		s.retire(sp, lostGrace, false)
	}
	deadline := time.After(30 * time.Second)
	for _, sp := range live {
		select {
		case <-sp.retired:
		case <-deadline:
			s.log.Error("retirement did not finish within 30s")
			return ExitLost
		}
	}

	if s.stopping.Load() {
		s.log.Info("stopped")
		return ExitStopped
	}
	s.log.Error("client channel lost; every spawn retired")
	return ExitLost
}

// reaper collects every exited child, including orphans reparented to this
// subreaper, and wakes whoever waits on a known pid.
func (s *server) reaper(sigchld <-chan os.Signal) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-sigchld:
		case <-tick.C:
		}
		s.reap()
	}
}

func (s *server) reap() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for {
		var ws unix.WaitStatus
		pid, err := unix.Wait4(-1, &ws, unix.WNOHANG, nil)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil || pid <= 0 {
			return
		}
		if c := s.waiters[pid]; c != nil {
			c.status = ws
			close(c.done)
			delete(s.waiters, pid)
		}
	}
}

// start forks and executes a process in a session of its own as uid and
// gid with no supplementary groups, killed if this keeper dies.
func (s *server) start(argv0 string, argv, env []string, files []uintptr, uid, gid int, dir string) (*child, error) {
	return s.startWith(argv0, argv, env, files, dir, &syscall.SysProcAttr{
		Setsid:     true,
		Credential: &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid), Groups: []uint32{}},
		Pdeathsig:  syscall.SIGKILL,
	})
}

// startWith forks and executes a process as sys says.
func (s *server) startWith(argv0 string, argv, env []string, files []uintptr, dir string, sys *syscall.SysProcAttr) (*child, error) {
	attr := &syscall.ProcAttr{Dir: dir, Env: env, Files: files, Sys: sys}
	s.mu.Lock()
	defer s.mu.Unlock()
	pid, err := syscall.ForkExec(argv0, argv, attr)
	if err != nil {
		return nil, err
	}
	c := &child{pid: pid, done: make(chan struct{})}
	s.waiters[pid] = c
	return c, nil
}

// signalChild signals one child unless it has been reaped.
func (s *server) signalChild(c *child, sig syscall.Signal) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !c.reaped() {
		_ = unix.Kill(c.pid, sig)
	}
}

func (s *server) serveChannel() {
	lr := protocol.NewLineReader(s.channel)
	for {
		line, tooLong, err := lr.Next()
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, os.ErrClosed) {
				s.log.Error("reading the channel: %v", err)
			}
			return
		}
		if tooLong {
			s.log.Warn("refused a request longer than %d bytes", protocol.MaxLineBytes)
			s.send(protocol.NewError("", "", protocol.CodeBadRequest))
			continue
		}
		req, rerr := protocol.ParseRequest(line)
		if rerr != nil {
			s.log.Warn("refused a request: %s", rerr.Detail)
			s.send(rerr.Reply())
			continue
		}
		// A place, a drop and an assign are applied here, before the next
		// line is read, in the order the client sent them: a spawn finds the
		// place sent before it, and a drop or an assign what came before it.
		// Every other request runs on a goroutine of its own.
		switch req.Type {
		case protocol.TypePlace, protocol.TypeDrop, protocol.TypeAssign:
			s.handle(req)
		default:
			go s.handle(req)
		}
	}
}

func (s *server) send(reply any) {
	line, err := protocol.Encode(reply)
	if err != nil {
		s.log.Error("encoding a reply: %v", err)
		return
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.channel.SetWriteDeadline(time.Now().Add(writeTimeout))
	if _, err := s.channel.Write(line); err != nil && !errors.Is(err, os.ErrClosed) {
		s.log.Error("writing the channel: %v", err)
		_ = s.channel.Close()
	}
}

func (s *server) handle(req *protocol.Request) {
	switch req.Type {
	case protocol.TypePlace:
		s.handlePlace(req)
	case protocol.TypeDrop:
		s.handleDrop(req)
	case protocol.TypeAssign:
		s.handleAssign(req)
	case protocol.TypeSpawn:
		s.handleSpawn(req)
	case protocol.TypeSignal:
		s.handleSignal(req)
	case protocol.TypeResize:
		s.handleResize(req)
	case protocol.TypeRelease:
		s.handleRelease(req)
	case protocol.TypePool:
		s.handlePool(req)
	case protocol.TypeMeasure:
		s.handleMeasure(req)
	case protocol.TypeHomeMake, protocol.TypeHomeMeasure, protocol.TypeHomeRetire:
		s.handleHome(req)
	}
}

func (s *server) handlePool(req *protocol.Request) {
	s.mu.Lock()
	p := s.pools[req.Pool]
	var st pool.Stats
	if p != nil {
		st = p.Stats()
	}
	s.mu.Unlock()
	if p == nil {
		s.send(protocol.NewError(req.ID, "", protocol.CodeUnknownPool))
		return
	}
	s.send(protocol.NewPoolReply(req.ID, req.Pool, st.Size, st.Free, st.Quarantined))
}

func (s *server) handleSignal(req *protocol.Request) {
	sig := signalNumbers[req.Sig]
	s.mu.Lock()
	sp := s.spawns[req.SpawnID]
	running := sp != nil && sp.leader != nil && !sp.leader.reaped()
	if running {
		_ = unix.Kill(-sp.leader.pid, sig)
	}
	s.mu.Unlock()
	switch {
	case sp == nil:
		s.send(protocol.NewError("", req.SpawnID, protocol.CodeUnknownSpawn))
	case !running:
		s.send(protocol.NewError("", req.SpawnID, protocol.CodeNotRunning))
	}
}

// handleResize sets the size of a spawn's pseudo-terminal; the kernel
// signals SIGWINCH to the terminal's foreground process group.
func (s *server) handleResize(req *protocol.Request) {
	s.mu.Lock()
	sp := s.spawns[req.SpawnID]
	hasPty := sp != nil && sp.pty != nil
	var err error
	if hasPty {
		err = unix.IoctlSetWinsize(int(sp.pty.Fd()), unix.TIOCSWINSZ, &unix.Winsize{Row: uint16(*req.Rows), Col: uint16(*req.Cols)})
	}
	s.mu.Unlock()
	switch {
	case sp == nil:
		s.send(protocol.NewError("", req.SpawnID, protocol.CodeUnknownSpawn))
	case !hasPty:
		s.send(protocol.NewError("", req.SpawnID, protocol.CodeBadRequest))
	case err != nil:
		s.log.Error("spawn %s: resizing its terminal: %v", sp.id, err)
		s.send(protocol.NewError("", req.SpawnID, protocol.CodeInternal))
	}
}

// closePty closes the keeper's descriptor of the spawn's terminal; s.mu is
// held.
func (sp *spawn) closePty() {
	if sp.pty != nil {
		_ = sp.pty.Close()
		sp.pty = nil
	}
}

func (s *server) handleRelease(req *protocol.Request) {
	s.mu.Lock()
	sp := s.spawns[req.SpawnID]
	s.mu.Unlock()
	if sp == nil {
		s.send(protocol.NewError("", req.SpawnID, protocol.CodeUnknownSpawn))
		return
	}
	s.retire(sp, time.Duration(*req.GraceMs)*time.Millisecond, true)
}

var signalNumbers = map[string]syscall.Signal{
	"SIGTERM": unix.SIGTERM,
	"SIGKILL": unix.SIGKILL,
	"SIGINT":  unix.SIGINT,
	"SIGHUP":  unix.SIGHUP,
	"SIGQUIT": unix.SIGQUIT,
	"SIGUSR1": unix.SIGUSR1,
	"SIGUSR2": unix.SIGUSR2,
}

// poolSpec is the declared spec of the pool name, which never changes.
func (s *server) poolSpec(name string) (pool.Spec, bool) {
	for _, spec := range s.cfg.Pools {
		if spec.Name == name {
			return spec, true
		}
	}
	return pool.Spec{}, false
}

// handleSpawn claims the place a spawn names before anything else is done,
// and starts the spawn in it. One naming a place the keeper does not hold,
// or one another spawn named, is refused. A spawn refused before the keeper
// made it is refused under its request's id alone, its place freed before
// the refusal is sent, so the client may place that id again. One refused
// once made is refused under the spawn id the keeper gave it too, and is
// retired after the refusal is sent, its exit settled first as none, since
// it was never spawned: its retirement frees the place once the spawn's
// group is removed, and then sends its `released`.
func (s *server) handleSpawn(req *protocol.Request) {
	if s.closing.Load() {
		return
	}
	if s.claimPlace(req.Place) == nil {
		s.log.Warn("spawn %s refused: the keeper holds no place %s, or another spawn named it", req.ID, req.Place)
		s.send(protocol.NewError(req.ID, "", protocol.CodeBadRequest))
		return
	}
	made, code := s.startSpawn(req)
	switch {
	case code == "":
	case made == nil:
		s.mu.Lock()
		delete(s.places, req.Place)
		s.mu.Unlock()
		s.send(protocol.NewError(req.ID, "", code))
	default:
		s.send(protocol.NewError(req.ID, made.id, code))
		made.exitOnce.Do(func() {})
		s.retire(made, 0, true)
	}
}

// startSpawn starts the spawn req asks for in the place it claimed. It
// answers the code it is refused with, or "" once it is spawned, and the
// spawn it made in the place, nil when it is refused before it made one.
func (s *server) startSpawn(req *protocol.Request) (*spawn, string) {
	// A relay pool's space reaches nothing: it takes no hosts, and no kept
	// home or terminal, which are a program's, whose pool is routed. A pool
	// the keeper does not serve is refused below, as it always was.
	spec, known := s.poolSpec(req.Pool)
	if known && !spec.Routed() && (req.Hosts != nil || req.HomeMode == protocol.HomeKept || req.Pty != nil) {
		s.log.Warn("spawn %s refused: pool %s's spaces reach nothing, and it names hosts, a kept home or a pty", req.ID, req.Pool)
		return nil, protocol.CodeBadRequest
	}
	if s.memory == nil {
		s.log.Warn("spawn %s refused: its memory and CPU bounds are unavailable here", req.ID)
		return nil, protocol.CodeMemoryUnavailable
	}
	reach, code, err := s.spawnEgress(req)
	if err != nil {
		s.log.Warn("spawn %s refused: %v", req.ID, err)
		return nil, code
	}
	if req.HomeMode == protocol.HomeKept {
		return s.startKeptSpawn(req, spec.Reach, reach)
	}
	s.mu.Lock()
	p := s.pools[req.Pool]
	var uid int
	var ok bool
	if p != nil {
		uid, ok = p.Allocate(func(uid int) bool {
			c, err := procfs.ScanUID("/proc", uid, 0)
			if err != nil || c.Total() > 0 {
				return true
			}
			found, err := residue.Find(s.roots, uid)
			return err != nil || !found.Empty()
		})
	}
	s.mu.Unlock()
	switch {
	case p == nil:
		return nil, protocol.CodeUnknownPool
	case !ok:
		return nil, protocol.CodeCapacity
	}

	sp := &spawn{id: randomHex(16), pool: p, account: s.accounts[uid], reach: spec.Reach, retired: make(chan struct{})}
	s.madeIn(req.Place, sp)
	name, err := home.NewName(uid)
	if err != nil {
		s.log.Error("spawn %s: %v", req.ID, err)
		return sp, protocol.CodeInternal
	}
	sp.home = filepath.Join(s.cfg.HomeRoot, name)

	if code, err := s.launch(sp, req, reach); err != nil {
		s.log.Error("spawn %s on uid %d: %v", req.ID, uid, err)
		return sp, code
	}

	s.mu.Lock()
	s.spawns[sp.id] = sp
	s.mu.Unlock()
	s.log.Info("spawn %s: uid %d, leader pid %d", sp.id, uid, sp.leader.pid)
	s.send(protocol.NewSpawned(req.ID, sp.id, uid, sp.leader.pid))
	go s.watchLeader(sp)
	return sp, ""
}

// launch starts the spawn's stage, cloned into its space (spaceAttr), maps
// its ids and places it in its cgroup, in that order, before its spec
// releases it; a routed space's stage then hands up its namespace and name
// sockets, and only once the guard has admitted its route (admitRoute) is
// it told to go on. launch waits until the stage has executed the command,
// and starts the relay as the client user holding the other ends of the
// command's pipes and, when the request asks for a control channel, the
// relay's end of its socketpair; the command's end goes to the stage, which
// makes it the command's fd 3. A failure kills the stage, which has
// executed nothing. It returns the error code to reply with.
func (s *server) launch(sp *spawn, req *protocol.Request, e egress) (string, error) {
	var opened []*os.File
	closeAll := func() {
		for _, f := range opened {
			_ = f.Close()
		}
	}
	defer closeAll()
	pipe := func() (*os.File, *os.File, error) {
		r, w, err := os.Pipe()
		if err == nil {
			opened = append(opened, r, w)
		}
		return r, w, err
	}

	stdinR, stdinW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	stdoutR, stdoutW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	stderrR, stderrW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	specR, specW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	statusR, statusW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	socketpair := func(name string) (*os.File, *os.File, error) {
		fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
		if err != nil {
			return nil, nil, err
		}
		command, helper := os.NewFile(uintptr(fds[0]), name+"-command"), os.NewFile(uintptr(fds[1]), name+"-relay")
		opened = append(opened, command, helper)
		return command, helper, nil
	}
	// The control channel is one socketpair: commandCtl becomes the
	// command's fd 3 (stage.ControlFD to the stage), relayCtl the relay's
	// relay.ControlFD. A relay space's relay is another: commandRelay
	// becomes the command's fd 4 (stage.RelayFD), helperRelay the relay's
	// relay.RelayFD, so control lines and relay frames never share a
	// socket. The keeper keeps no end of either. A routed space's route
	// socket is a third, at the stage's stage.RouteFD, whose other end,
	// keeperRoute, the keeper holds until the command executes.
	relayed := sp.reach == pool.ReachRelay
	var commandCtl, relayCtl, commandRelay, helperRelay, stageRoute, keeperRoute *os.File
	if req.Control {
		if commandCtl, relayCtl, err = socketpair("control"); err != nil {
			return protocol.CodeInternal, err
		}
	}
	if relayed {
		if commandRelay, helperRelay, err = socketpair("relay"); err != nil {
			return protocol.CodeInternal, err
		}
	} else if stageRoute, keeperRoute, err = socketpair("route"); err != nil {
		return protocol.CodeInternal, err
	}

	// The spawn's group exists before its stage does, and the stage
	// is moved into it while it still waits for its spec, so nothing of the
	// spawn runs outside the bound; the stage checks where it is for itself.
	groupName := cgroup.Name(sp.account.UID)
	homeRoot := s.cfg.HomeRoot
	if sp.kept {
		groupName = cgroup.SpawnName(sp.id)
		homeRoot = s.cfg.Kept.Root
	}
	group, err := s.memory.Create(groupName, *req.MemoryBytes, *req.CPUQuota)
	if err != nil {
		return protocol.CodeInternal, err
	}
	sp.group = group

	spec, err := json.Marshal(stage.Spec{
		UID:      sp.account.UID,
		GID:      sp.account.GID,
		User:     sp.account.Name,
		HomeRoot: homeRoot,
		Home:     sp.home,
		Kept:     sp.kept,
		Argv:     req.Argv,
		Env:      req.Env,
		Limits:   limits(sp.kept, req.Rlimits),
		Control:  req.Control,
		Terminal: req.Pty != nil,
		Reach:    sp.reach,
		Cgroup:   group.Path(),
	})
	if err != nil {
		return protocol.CodeInternal, err
	}
	stageFiles := []uintptr{stdinR.Fd(), stdoutW.Fd(), stderrW.Fd(), specR.Fd(), statusW.Fd()}
	stageOwned := []*os.File{stdinR, stdoutW, stderrW, specR, statusW}
	// A pty spawn's stdin, stdout and stderr are a terminal of its space's
	// own, which the space's first process opens and whose master it hands
	// up over the terminal socket (stage.TerminalFD); the stage itself has
	// none. The relay holds the master as its stdin and its stdout, and its
	// stderr is a pipe no one writes, which ends at once. The keeper keeps
	// a descriptor of the master as sp.pty, which a `resize` sets the size
	// through; the spawn's retirement closes it, after a failure here too.
	pty := req.Pty != nil
	var stageTerminal, keeperTerminal *os.File
	if pty {
		devnull, err := os.Open(os.DevNull)
		if err != nil {
			return protocol.CodeInternal, err
		}
		opened = append(opened, devnull)
		if stageTerminal, keeperTerminal, err = socketpair("terminal"); err != nil {
			return protocol.CodeInternal, err
		}
		stageFiles = []uintptr{devnull.Fd(), devnull.Fd(), devnull.Fd(), specR.Fd(), statusW.Fd()}
		stageOwned = []*os.File{specR, statusW}
		_ = stderrW.Close()
	}
	// A descriptor of ^0 is closed in the child: a spawn without a control
	// channel has no stage.ControlFD before its stage.RelayFD or
	// stage.RouteFD.
	if commandCtl != nil {
		stageFiles = append(stageFiles, commandCtl.Fd())
		stageOwned = append(stageOwned, commandCtl)
	} else {
		stageFiles = append(stageFiles, ^uintptr(0))
	}
	if relayed {
		stageFiles = append(stageFiles, commandRelay.Fd())
		stageOwned = append(stageOwned, commandRelay)
	} else {
		stageFiles = append(stageFiles, stageRoute.Fd())
		stageOwned = append(stageOwned, stageRoute)
	}
	if pty {
		stageFiles = append(stageFiles, stageTerminal.Fd())
		stageOwned = append(stageOwned, stageTerminal)
	}
	if !relayed {
		// From here the end of the guard's connection finds this spawn
		// (guardLost); its retirement removes it.
		s.mu.Lock()
		if s.routing == nil {
			s.routing = map[string]*spawn{}
		}
		s.routing[sp.id] = sp
		s.mu.Unlock()
	}
	leader, err := s.startWith(s.self, []string{"cyfr-locus", "stage"}, nil, stageFiles, "/", spaceAttr())
	if err != nil {
		return protocol.CodeInternal, err
	}
	sp.leader = leader
	for _, f := range stageOwned {
		_ = f.Close()
	}
	// The stage waits for its spec still holding the keeper's ids, which
	// retirement under the pooled uid cannot end, and, routed, for its
	// route's word: it is killed here on every failure before the command
	// executes.
	started := false
	defer func() {
		if !started {
			s.signalChild(leader, unix.SIGKILL)
		}
	}()
	if err := mapIDs(leader.pid, sp.account.UID, sp.account.GID); err != nil {
		return protocol.CodeInternal, err
	}
	if sp.group != nil {
		if err := sp.group.Add(leader.pid); err != nil {
			return protocol.CodeInternal, err
		}
	}

	_ = specW.SetWriteDeadline(time.Now().Add(stageTimeout))
	if _, err := specW.Write(spec); err != nil {
		return protocol.CodeExecFailed, err
	}
	_ = specW.Close()
	if !relayed {
		if code, err := s.admitRoute(sp, keeperRoute, e); err != nil {
			return code, err
		}
	}
	if pty {
		master, err := receiveTerminal(keeperTerminal, uint16(*req.Pty.Rows), uint16(*req.Pty.Cols))
		if err != nil {
			reason, _ := readStatus(statusR)
			return protocol.CodeExecFailed, fmt.Errorf("the space's terminal: %w%s", err, reason)
		}
		opened = append(opened, master)
		masterIn, err := dupFile(master, "pty-stdin")
		if err != nil {
			return protocol.CodeInternal, err
		}
		opened = append(opened, masterIn)
		if sp.pty, err = dupFile(master, "pty-master"); err != nil {
			return protocol.CodeInternal, err
		}
		stdinW, stdoutR = masterIn, master
	}
	reason, err := readStatus(statusR)
	if err != nil {
		return protocol.CodeExecFailed, err
	}
	if len(reason) > 0 {
		return protocol.CodeExecFailed, errors.New("stage: " + string(reason))
	}
	started = true

	relaySpecR, relaySpecW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		return protocol.CodeInternal, err
	}
	opened = append(opened, devnull)
	relaySpec, err := json.Marshal(relay.Spec{Path: req.Attach.Path, Token: req.Attach.Token, Control: req.Control, Relay: relayed})
	if err != nil {
		return protocol.CodeInternal, err
	}
	relayFiles := []uintptr{devnull.Fd(), devnull.Fd(), 2, relaySpecR.Fd(), stdinW.Fd(), stdoutR.Fd(), stderrR.Fd()}
	switch {
	case relayCtl != nil:
		relayFiles = append(relayFiles, relayCtl.Fd())
	case relayed:
		relayFiles = append(relayFiles, ^uintptr(0))
	}
	if relayed {
		relayFiles = append(relayFiles, helperRelay.Fd())
	}
	relayProc, err := s.start(s.self, []string{"cyfr-locus", "relay"}, helperEnviron(), relayFiles,
		s.client.UID, s.client.GID, "/")
	if err != nil {
		return protocol.CodeInternal, err
	}
	sp.relay = relayProc
	_ = relaySpecW.SetWriteDeadline(time.Now().Add(stageTimeout))
	if _, err := relaySpecW.Write(relaySpec); err != nil {
		return protocol.CodeInternal, err
	}
	return "", nil
}

// readStatus reads a stage's status pipe to its end, within stageTimeout:
// empty once the command has executed, the stage's reason otherwise.
func readStatus(statusR *os.File) (string, error) {
	_ = statusR.SetReadDeadline(time.Now().Add(stageTimeout))
	reason, err := io.ReadAll(io.LimitReader(statusR, 4096))
	return string(reason), err
}

// watchLeader reports the leader's exit and retires the spawn.
func (s *server) watchLeader(sp *spawn) {
	<-sp.leader.done
	s.reportExit(sp)
	s.retire(sp, leaderExitGrace, true)
}

// reportExit settles the spawn's one `exited`, with what the counters say
// killed it, once its leader is reaped or clearTimeout has passed: a
// retirement settles it before it removes the group, while the counters
// stand, however late the watcher runs, and waits for the reaping only that
// long, since a leader stuck in the kernel may never be reaped. A leader not
// reaped by then has SIGKILL's where the counters count a kill for memory,
// which takes every process of the group, and none now or later where they
// count none.
func (s *server) reportExit(sp *spawn) {
	sp.exitOnce.Do(func() {
		select {
		case <-sp.leader.done:
		case <-time.After(clearTimeout):
		}
		reaped := sp.leader.reaped()
		memory := s.memoryEnd(sp)
		if !reaped && memory == nil {
			return
		}
		var code *int
		var sig *string
		switch {
		case !reaped:
			name := unix.SignalName(unix.SIGKILL)
			sig = &name
		case sp.leader.status.Signaled():
			signal := sp.leader.status.Signal()
			name := unix.SignalName(signal)
			if name == "" {
				name = signal.String()
			}
			sig = &name
		default:
			c := sp.leader.status.ExitStatus()
			code = &c
		}
		s.send(protocol.NewExited(sp.id, code, sig, memory))
	})
}

// memoryEnd says what the kernel killed processes of the spawn for, as its
// group's counters say (cgroup.KilledFor): its own bound (MemoryCap), a
// limit above it (MemoryMachine), or one of the two that they cannot tell
// apart (MemoryEither), which is never reported as the cap; nil for no kill,
// or for counters that do not read. The kernel counts a kill before it
// delivers it, so a leader reaped after one finds it counted.
func (s *server) memoryEnd(sp *spawn) *string {
	if sp.group == nil {
		return nil
	}
	var memory string
	cause, err := sp.group.KilledFor()
	switch {
	case err != nil:
		s.log.Error("spawn %s: reading its memory counters: %v", sp.id, err)
		return nil
	case cause == cgroup.AtBound:
		memory = protocol.MemoryCap
		s.log.Warn("spawn %s: uid %d reached its memory bound and the kernel killed its processes", sp.id, sp.account.UID)
	case cause == cgroup.Above:
		memory = protocol.MemoryMachine
		s.log.Warn("spawn %s: processes of uid %d were killed for a memory limit above the spawn's own, the container's or the machine's", sp.id, sp.account.UID)
	case cause == cgroup.Either:
		memory = protocol.MemoryEither
		s.log.Warn("spawn %s: processes of uid %d were killed for memory, and the counters do not say whether at the spawn's own bound or above it", sp.id, sp.account.UID)
	default:
		return nil
	}
	return &memory
}

// retire ends a spawn once: every process of its uid is terminated, what
// the uid left behind is removed and the uid returned to its pool, or
// quarantined if a process or anything it left survives. With notify,
// `released` follows, once the spawn's relay has ended and its group is
// removed.
func (s *server) retire(sp *spawn, grace time.Duration, notify bool) {
	if sp.kept {
		s.retireKept(sp, grace, notify)
		return
	}
	sp.retireOnce.Do(func() {
		go func() {
			defer close(sp.retired)
			uid := sp.account.UID
			var paths []string
			if sp.home != "" {
				paths = []string{sp.home}
			}
			clean := s.scrub(sp.account, grace, paths, "")
			// Its processes are gone, or past every kill: its route carries
			// nothing more.
			s.withdrawRoute(sp)
			// The relay's end is its own and its reader's: it has handed the
			// reader the end of every stream, which closes once the spawn's
			// processes are gone, or the reader has closed its connection.
			// Nothing here cuts it, so `released` follows the last byte the
			// reader took.
			if sp.relay != nil {
				<-sp.relay.done
			}
			if notify {
				s.reportExit(sp)
			}
			// A group is removable once it holds no process, which a clean
			// scrub has established. A clean uid whose group stays goes back
			// to its pool only once the group is removed: the next spawn
			// under the uid takes the group's name.
			removed := s.removeSpawnGroup(sp)

			s.mu.Lock()
			switch {
			case !clean:
				_ = sp.pool.Quarantine(uid)
			case removed:
				_ = sp.pool.Release(uid)
			}
			s.leave(sp, removed, removal{notify: notify, clean: clean})
			s.mu.Unlock()

			if !clean {
				s.log.Warn("spawn %s: uid %d quarantined: a process or something it left outlived retirement", sp.id, uid)
			}
			if !removed {
				return
			}
			if clean {
				s.log.Info("spawn %s: uid %d retired", sp.id, uid)
			}
			if notify {
				s.send(protocol.NewReleased(sp.id))
			}
		}()
	})
}

// removeSpawnGroup removes a retired spawn's group, where it has one, and
// says whether none is left.
func (s *server) removeSpawnGroup(sp *spawn) bool {
	if sp.group == nil {
		return true
	}
	if err := removeGroup(sp.group); err != nil {
		s.log.Warn("spawn %s: its memory group of uid %d stays, its place and its release held until a retry removes it: %v", sp.id, sp.account.UID, err)
		return false
	}
	return true
}

// leave is a retirement's last step, with s.mu held. A spawn whose group
// was removed leaves spawns, its place with it, in this one step. One whose
// group stays keeps its place, still read and measured, a started one stays
// in spawns, and it waits in unremoved for the reader's retry of the
// removal, which finishes what left says: until then a release of a started
// one waits as its retirement's `released` does, and no `unknown_spawn`
// answers it.
func (s *server) leave(sp *spawn, removed bool, left removal) {
	sp.closePty()
	if !removed {
		s.unremoved[sp] = &left
		return
	}
	delete(s.spawns, sp.id)
	delete(s.places, sp.place)
	delete(s.routing, sp.id)
}

// scrub retires a uid until nothing of it remains: `cyfr-locus retire` ends
// its processes and removes its message queues and the given paths; then the keeper looks for anything else the uid owns on the
// writable mounts and retires it again with what it found. It reports
// whether the uid is clean.
func (s *server) scrub(acct Account, grace time.Duration, paths []string, except string) bool {
	for pass := 1; ; pass++ {
		if exit := s.runRetire(acct, paths, grace); exit != retire.ExitClean && exit != retire.ExitResidue {
			return false
		}
		if !s.waitClear(acct.UID) {
			return false
		}
		found, err := residue.FindExcept(s.roots, acct.UID, except)
		if err != nil {
			s.log.Error("uid %d: looking for what it left: %v", acct.UID, err)
			return false
		}
		if found.Empty() {
			return true
		}
		if pass == scrubPasses {
			s.log.Warn("uid %d: %d entries (truncated: %t) and %d message queues outlived retirement",
				acct.UID, len(found.Paths), found.Truncated, len(found.Queues))
			return false
		}
		paths, grace = found.Paths, 0
	}
}

// runRetire runs `cyfr-locus retire` as the account and returns its exit
// status, or -1 when it could not be run or did not exit.
func (s *server) runRetire(acct Account, paths []string, grace time.Duration) int {
	spec, err := json.Marshal(retire.Spec{UID: acct.UID, GraceMs: grace.Milliseconds(), Paths: paths})
	if err != nil {
		return -1
	}
	specR, specW, err := os.Pipe()
	if err != nil {
		s.log.Error("retire uid %d: %v", acct.UID, err)
		return -1
	}
	defer specW.Close()
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		specR.Close()
		return -1
	}
	c, err := s.start(s.self, []string{"cyfr-locus", "retire"}, helperEnviron(),
		[]uintptr{devnull.Fd(), devnull.Fd(), 2, specR.Fd()}, acct.UID, acct.GID, "/")
	specR.Close()
	devnull.Close()
	if err != nil {
		s.log.Error("retire uid %d: %v", acct.UID, err)
		return -1
	}
	_ = specW.SetWriteDeadline(time.Now().Add(stageTimeout))
	_, _ = specW.Write(spec)
	_ = specW.Close()

	select {
	case <-c.done:
	case <-time.After(grace + 15*time.Second):
		s.log.Error("retire uid %d did not finish; killing it", acct.UID)
		s.signalChild(c, unix.SIGKILL)
		<-c.done
	}
	if !c.status.Exited() {
		return -1
	}
	return c.status.ExitStatus()
}

// waitClear waits for every process of uid, zombies included, to be gone.
func (s *server) waitClear(uid int) bool {
	deadline := time.Now().Add(clearTimeout)
	for {
		s.reap()
		c, err := procfs.ScanUID("/proc", uid, 0)
		if err == nil && c.Total() == 0 {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// sweeper retries retirement of quarantined uids every sweepInterval.
func (s *server) sweeper() {
	tick := time.NewTicker(sweepInterval)
	defer tick.Stop()
	for range tick.C {
		s.sweep()
	}
}

// sweep retries retirement of every quarantined uid, kept or pooled, and
// returns each pooled one to its pool once nothing of it remains, its group
// included.
func (s *server) sweep() {
	type entry struct {
		pool *pool.Pool
		uid  int
	}
	var todo []entry
	s.mu.Lock()
	for _, p := range s.pools {
		for _, uid := range p.Quarantined() {
			todo = append(todo, entry{p, uid})
		}
	}
	s.mu.Unlock()
	s.sweepKept()
	if s.guard != nil {
		s.retryClears()
	}
	for _, e := range todo {
		if !s.scrub(s.accounts[e.uid], 0, nil, "") {
			continue
		}
		// A uid whose group stays goes back to its pool only once the
		// reader's retry removed the group, whose name the next spawn
		// under the uid would take.
		s.mu.Lock()
		stays := false
		for sp := range s.unremoved {
			if sp.pool == e.pool && sp.account.UID == e.uid {
				stays = true
				break
			}
		}
		s.mu.Unlock()
		if stays {
			continue
		}
		s.mu.Lock()
		_ = e.pool.Release(e.uid)
		s.mu.Unlock()
		s.log.Info("uid %d returned to pool %s", e.uid, e.pool.Spec().Name)
	}
}

// helperEnviron is the environment of relay and retire processes.
func helperEnviron() []string {
	if v := os.Getenv("CYFR_LOG_FORMAT"); v != "" {
		return []string{"CYFR_LOG_FORMAT=" + v}
	}
	return []string{}
}

// socketID is the name /proc/<pid>/fd gives the socket f: `socket:[inode]`.
func socketID(f *os.File) (string, error) {
	var st unix.Stat_t
	if err := unix.Fstat(int(f.Fd()), &st); err != nil {
		return "", err
	}
	return "socket:[" + strconv.FormatUint(st.Ino, 10) + "]", nil
}

// randomHex is n random bytes in hex. crypto/rand.Read never returns an
// error: it ends the process first.
func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func lookPathIn(file, path string) (string, error) {
	if filepath.IsAbs(file) || filepath.Base(file) != file {
		return file, nil
	}
	for _, dir := range filepath.SplitList(path) {
		if dir == "" {
			continue
		}
		candidate := filepath.Join(dir, file)
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode()&0o111 != 0 {
			return candidate, nil
		}
	}
	return "", errors.New(file + ": not found in PATH")
}

// limits are a spawn's resource limits: the ceilings lowered by its
// request, with no file-size limit of its own for a kept spawn, whose disk
// its home's bound and the kept homes' volume hold.
func limits(kept bool, r *protocol.Rlimits) protocol.Limits {
	if kept {
		return r.ResolveKept()
	}
	return r.Resolve()
}

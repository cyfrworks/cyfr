// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
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

	"github.com/cyfr/spawn/internal/home"
	"github.com/cyfr/spawn/internal/logx"
	"github.com/cyfr/spawn/internal/pool"
	"github.com/cyfr/spawn/internal/procfs"
	"github.com/cyfr/spawn/internal/protocol"
	"github.com/cyfr/spawn/internal/relay"
	"github.com/cyfr/spawn/internal/residue"
	"github.com/cyfr/spawn/internal/retire"
	"github.com/cyfr/spawn/internal/stage"
)

// Exit statuses of `cyfr-spawn serve`.
const (
	// ExitStopped follows a termination signal forwarded to the client.
	ExitStopped = 0
	// ExitUsage reports a malformed command line.
	ExitUsage = 64
	// ExitLost reports that the client or its channel went away unasked.
	ExitLost = 70
	// ExitStart reports that the client could not be started.
	ExitStart = 71
	// ExitConfig reports a privilege or environment the spawner refuses.
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

// Main runs `cyfr-spawn serve` with the arguments after the subcommand.
func Main(args []string) int {
	log := logx.New("cyfr-spawn")
	cfg, err := ParseArgs(args)
	if err != nil {
		log.Error("%v; usage: %s", err, Usage)
		return ExitUsage
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
	if err := procfs.CheckSpawnerCaps(st); err != nil {
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
	if err := residue.CheckMounts(mounts, cfg.HomeRoot, PoolAccounts(accounts)); err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}
	self, err := os.Executable()
	if err != nil {
		log.Error("refusing to start: %v", err)
		return ExitConfig
	}

	s := &server{
		cfg:      cfg,
		log:      log,
		self:     self,
		client:   client,
		accounts: accounts,
		roots:    roots,
		pools:    map[string]*pool.Pool{},
		spawns:   map[string]*spawn{},
		waiters:  map[int]*child{},
	}
	for _, spec := range cfg.Pools {
		s.pools[spec.Name] = pool.New(spec)
	}
	return s.run()
}

// child is a process this spawner started and will reap.
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

// spawn is one allocation: a uid, its home, its leader and its relay.
type spawn struct {
	id      string
	pool    *pool.Pool
	account Account
	home    string
	leader  *child
	relay   *child

	// exitReported closes once `exited` has been sent for the leader.
	exitReported chan struct{}
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

	// mu guards pools, spawns and waiters, and is held across every fork,
	// reap and signal, so a pid is never signalled after it was reaped.
	mu      sync.Mutex
	pools   map[string]*pool.Pool
	spawns  map[string]*spawn
	waiters map[int]*child

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
	clientProc, err := s.start(argv0, s.cfg.ClientArgv, ClientEnviron(os.Environ(), s.client, channelID),
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
// gid with no supplementary groups, killed if this spawner dies.
func (s *server) start(argv0 string, argv, env []string, files []uintptr, uid, gid int, dir string) (*child, error) {
	attr := &syscall.ProcAttr{
		Dir:   dir,
		Env:   env,
		Files: files,
		Sys: &syscall.SysProcAttr{
			Setsid:     true,
			Credential: &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid), Groups: []uint32{}},
			Pdeathsig:  syscall.SIGKILL,
		},
	}
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
		go s.handle(req)
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
	case protocol.TypeSpawn:
		s.handleSpawn(req)
	case protocol.TypeSignal:
		s.handleSignal(req)
	case protocol.TypeRelease:
		s.handleRelease(req)
	case protocol.TypePool:
		s.handlePool(req)
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

func (s *server) handleSpawn(req *protocol.Request) {
	if s.closing.Load() {
		return
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
			found, err := residue.Find(s.roots, residue.SysvipcDir, uid)
			return err != nil || !found.Empty()
		})
	}
	s.mu.Unlock()
	switch {
	case p == nil:
		s.send(protocol.NewError(req.ID, "", protocol.CodeUnknownPool))
		return
	case !ok:
		s.send(protocol.NewError(req.ID, "", protocol.CodeCapacity))
		return
	}

	sp := &spawn{pool: p, account: s.accounts[uid], exitReported: make(chan struct{}), retired: make(chan struct{})}
	var err error
	if sp.id, err = randomHex(16); err == nil {
		var name string
		if name, err = home.NewName(uid); err == nil {
			sp.home = filepath.Join(s.cfg.HomeRoot, name)
		}
	}
	if err != nil {
		s.log.Error("spawn %s: %v", req.ID, err)
		s.retire(sp, 0, false)
		s.send(protocol.NewError(req.ID, "", protocol.CodeInternal))
		return
	}

	if code, err := s.launch(sp, req); err != nil {
		s.log.Error("spawn %s on uid %d: %v", req.ID, uid, err)
		s.retire(sp, 0, false)
		s.send(protocol.NewError(req.ID, "", code))
		return
	}

	s.mu.Lock()
	s.spawns[sp.id] = sp
	s.mu.Unlock()
	s.log.Info("spawn %s: uid %d, leader pid %d", sp.id, uid, sp.leader.pid)
	s.send(protocol.NewSpawned(req.ID, sp.id, uid, sp.leader.pid))
	go s.watchLeader(sp)
}

// launch starts the stage as the spawn's uid, waits until it has executed
// the command, and starts the relay as the client user holding the other
// ends of the command's pipes. It returns the error code to reply with.
func (s *server) launch(sp *spawn, req *protocol.Request) (string, error) {
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

	spec, err := json.Marshal(stage.Spec{
		UID:      sp.account.UID,
		GID:      sp.account.GID,
		User:     sp.account.Name,
		HomeRoot: s.cfg.HomeRoot,
		Home:     sp.home,
		Argv:     req.Argv,
		Env:      req.Env,
		Limits:   req.Rlimits.Resolve(),
	})
	if err != nil {
		return protocol.CodeInternal, err
	}
	leader, err := s.start(s.self, []string{"cyfr-spawn", "stage"}, nil,
		[]uintptr{stdinR.Fd(), stdoutW.Fd(), stderrW.Fd(), specR.Fd(), statusW.Fd()},
		sp.account.UID, sp.account.GID, "/")
	if err != nil {
		return protocol.CodeInternal, err
	}
	sp.leader = leader
	for _, f := range []*os.File{stdinR, stdoutW, stderrW, specR, statusW} {
		_ = f.Close()
	}

	_ = specW.SetWriteDeadline(time.Now().Add(stageTimeout))
	if _, err := specW.Write(spec); err != nil {
		return protocol.CodeExecFailed, err
	}
	_ = specW.Close()
	_ = statusR.SetReadDeadline(time.Now().Add(stageTimeout))
	reason, err := io.ReadAll(io.LimitReader(statusR, 4096))
	if err != nil {
		return protocol.CodeExecFailed, err
	}
	if len(reason) > 0 {
		return protocol.CodeExecFailed, errors.New("stage: " + string(reason))
	}

	relaySpecR, relaySpecW, err := pipe()
	if err != nil {
		return protocol.CodeInternal, err
	}
	devnull, err := os.Open(os.DevNull)
	if err != nil {
		return protocol.CodeInternal, err
	}
	opened = append(opened, devnull)
	relaySpec, err := json.Marshal(relay.Spec{Path: req.Attach.Path, Token: req.Attach.Token})
	if err != nil {
		return protocol.CodeInternal, err
	}
	relayProc, err := s.start(s.self, []string{"cyfr-spawn", "relay"}, helperEnviron(),
		[]uintptr{devnull.Fd(), devnull.Fd(), 2, relaySpecR.Fd(), stdinW.Fd(), stdoutR.Fd(), stderrR.Fd()},
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

// watchLeader reports the leader's exit and retires the spawn.
func (s *server) watchLeader(sp *spawn) {
	<-sp.leader.done
	var code *int
	var sig *string
	if ws := sp.leader.status; ws.Signaled() {
		name := unix.SignalName(ws.Signal())
		if name == "" {
			name = ws.Signal().String()
		}
		sig = &name
	} else {
		c := ws.ExitStatus()
		code = &c
	}
	s.send(protocol.NewExited(sp.id, code, sig))
	close(sp.exitReported)
	s.retire(sp, leaderExitGrace, true)
}

// retire ends a spawn once: every process of its uid is terminated, what
// the uid left behind is removed and the uid returned to its pool, or
// quarantined if a process or anything it left survives. With notify,
// `released` follows.
func (s *server) retire(sp *spawn, grace time.Duration, notify bool) {
	sp.retireOnce.Do(func() {
		go func() {
			defer close(sp.retired)
			uid := sp.account.UID
			var paths []string
			if sp.home != "" {
				paths = []string{sp.home}
			}
			clean := s.scrub(sp.account, grace, paths)
			if sp.relay != nil {
				select {
				case <-sp.relay.done:
				case <-time.After(time.Second):
					s.signalChild(sp.relay, unix.SIGKILL)
				}
			}

			s.mu.Lock()
			if clean {
				_ = sp.pool.Release(uid)
			} else {
				_ = sp.pool.Quarantine(uid)
			}
			delete(s.spawns, sp.id)
			s.mu.Unlock()

			if clean {
				s.log.Info("spawn %s: uid %d retired", sp.id, uid)
			} else {
				s.log.Warn("spawn %s: uid %d quarantined: a process or something it left outlived retirement", sp.id, uid)
			}
			if notify {
				// `released` follows `exited`; a leader that survived
				// retirement is not waited for.
				select {
				case <-sp.exitReported:
				case <-time.After(clearTimeout):
				}
				s.send(protocol.NewReleased(sp.id))
			}
		}()
	})
}

// scrub retires a uid until nothing of it remains: `cyfr-spawn retire` ends
// its processes and removes its IPC objects, its message queues and the
// given paths; then the spawner looks for anything else the uid owns on the
// writable mounts and retires it again with what it found. It reports
// whether the uid is clean.
func (s *server) scrub(acct Account, grace time.Duration, paths []string) bool {
	for pass := 1; ; pass++ {
		if exit := s.runRetire(acct, paths, grace); exit != retire.ExitClean && exit != retire.ExitResidue {
			return false
		}
		if !s.waitClear(acct.UID) {
			return false
		}
		found, err := residue.Find(s.roots, residue.SysvipcDir, acct.UID)
		if err != nil {
			s.log.Error("uid %d: looking for what it left: %v", acct.UID, err)
			return false
		}
		if found.Empty() {
			return true
		}
		if pass == scrubPasses {
			s.log.Warn("uid %d: %d entries (truncated: %t), %d IPC objects and %d message queues outlived retirement",
				acct.UID, len(found.Paths), found.Truncated, len(found.IPC), len(found.Queues))
			return false
		}
		paths, grace = found.Paths, 0
	}
}

// runRetire runs `cyfr-spawn retire` as the account and returns its exit
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
	c, err := s.start(s.self, []string{"cyfr-spawn", "retire"}, helperEnviron(),
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

// sweeper retries retirement of quarantined uids and returns each to its
// pool once nothing of it remains.
func (s *server) sweeper() {
	tick := time.NewTicker(sweepInterval)
	defer tick.Stop()
	for range tick.C {
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
		for _, e := range todo {
			if !s.scrub(s.accounts[e.uid], 0, nil) {
				continue
			}
			s.mu.Lock()
			_ = e.pool.Release(e.uid)
			s.mu.Unlock()
			s.log.Info("uid %d returned to pool %s", e.uid, e.pool.Spec().Name)
		}
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

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
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

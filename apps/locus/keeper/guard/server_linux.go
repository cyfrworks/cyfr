// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/cyfr/locus/keeper/internal/logx"
)

// Exit statuses of `cyfr-locus guard-control`.
const (
	ExitUsage  = 64
	ExitConfig = 78
	ExitServe  = 70
)

// Script is the guard that installs and removes a route's rules, run once
// per change (cyfr-guard.sh, installed under this name on PATH).
const Script = "cyfr-guard"

const (
	// applyTimeout bounds one run of the guard script.
	applyTimeout = 30 * time.Second
	// withdrawBound bounds how long a route the guard could not withdraw is
	// tried again: past it the guard ends, and its namespace goes with every
	// pair, rule and connection of every route, the one state from which all
	// of them are known gone.
	withdrawBound = 30 * time.Second
	// retryInterval is how often a route not yet withdrawn is tried again.
	retryInterval = time.Second
)

// Main runs `cyfr-locus guard-control <socket> <range>`, which the guard
// execs once its rules are installed: it serves the control on socket
// until it is stopped, making each route in the IPv4 /16 range the
// guard's rules chose for routes.
func Main(args []string) int {
	log := logx.New("cyfr-guard")
	if len(args) != 2 || !filepath.IsAbs(args[0]) || filepath.Clean(args[0]) != args[0] {
		log.Error("usage: cyfr-locus guard-control <socket> <range>, the socket a clean absolute path")
		return ExitUsage
	}
	rng, err := ParseRange(args[1])
	if err != nil {
		log.Error("refusing to serve: the route range: %v", err)
		return ExitConfig
	}
	netns, err := os.Readlink("/proc/self/ns/net")
	if err != nil {
		log.Error("refusing to serve: reading this network namespace: %v", err)
		return ExitConfig
	}
	// A route's withdrawal removes its connections from the kernel's
	// table: a guard that cannot read the table makes no route.
	if _, err := conntrackOf(netip.IPv4Unspecified()); err != nil {
		log.Error("refusing to serve: the kernel's connection table cannot be read through ctnetlink: %v", err)
		return ExitConfig
	}
	listener, err := listen(args[0])
	if err != nil {
		log.Error("refusing to serve: %v", err)
		return ExitConfig
	}
	log.Info("control: serving %s in %s, routes in %s", args[0], netns, rng)
	s := newServer(log, netns, rng, kernelRoutes{apply: runScript})
	go s.retryLoop(nil)
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			log.Error("control: accepting: %v", err)
			return ExitServe
		}
		go s.serve(conn)
	}
}

// listen makes the control's socket: its directory is root's own and is
// made 0700, a socket left by an earlier guard is removed, and the socket
// is made 0600 as it is bound, so no other user ever reaches it.
func listen(path string) (*net.UnixListener, error) {
	dir := filepath.Dir(path)
	info, err := os.Lstat(dir)
	if err != nil {
		return nil, err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || st.Uid != 0 {
		return nil, fmt.Errorf("%s must be a directory root owns", dir)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	if old, err := os.Lstat(path); err == nil {
		if old.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("%s exists and is not a socket", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	}
	// A socket takes 0777 less the mask: 0600, root's to read and write.
	mask := syscall.Umask(0o177)
	defer syscall.Umask(mask)
	return net.ListenUnix("unixpacket", &net.UnixAddr{Name: path, Net: "unixpacket"})
}

func runScript(args ...string) error {
	cmd := exec.Command(Script, args...)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-time.After(applyTimeout):
		_ = cmd.Process.Kill()
		<-done
		return errors.New("the guard did not finish")
	}
}

// route is one space's route.
type route struct {
	spawnID string
	slot    int
	gateway netip.Addr
	inner   netip.Addr
	// mark is the route's own number, which every connection its space
	// opens carries (CONNMARK) and every reply into it must: a number is
	// never given twice in a guard's life, so a connection of a withdrawn
	// route whose address a later route took passes nothing into it.
	mark      uint32
	reach     string
	addresses []string
	netns     *os.File
	udp       *os.File
	tcp       *os.File
	names     *names
	// sockets are the inodes of its two name sockets, which no other
	// route may hold.
	sockets [2]uint64
	// conn is the connection that made it; answered the names its names
	// answered, read as they stopped; failedAt when its withdrawal first
	// failed, zero while none has; gone once its withdrawal is complete,
	// after which no step acts on it again. A route is its own: its mark
	// is its identity, never given twice, and a step names the route,
	// never its slot or address, which a later route may hold once this
	// one is gone.
	conn     uint64
	answered uint64
	failedAt time.Time
	gone     bool
}

// routeMaker makes and removes the parts of a route: kernelRoutes in
// production.
type routeMaker interface {
	// pair makes the veth pair, both ends' addresses and links and the
	// space's default route.
	pair(r *route) error
	// rules installs the route's rules.
	rules(r *route) error
	// unpair removes the pair, which ends every connection through it.
	unpair(r *route) error
	// unrules removes the route's rules.
	unrules(r *route) error
}

// kernelRoutes makes routes in the kernel, the rules through the guard
// script.
type kernelRoutes struct{ apply func(args ...string) error }

func (k kernelRoutes) pair(r *route) error {
	if err := checkDescriptors(r.netns, r.udp, r.tcp); err != nil {
		return err
	}
	if err := makePair(r.slot, r.netns); err != nil {
		return err
	}
	own, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(own)
	if err := setLink(own, outerName(r.slot), r.gateway); err != nil {
		return err
	}
	space := int(r.udp.Fd())
	if err := setLink(space, innerName, r.inner); err != nil {
		return err
	}
	return defaultRoute(space, r.gateway)
}

func (k kernelRoutes) rules(r *route) error {
	args := []string{"route", outerName(r.slot), r.inner.String(), strconv.FormatUint(uint64(r.mark), 10), r.reach}
	return k.apply(append(args, r.addresses...)...)
}

// unpair removes the pair, then every entry the kernel's connection table
// holds of the route's address: a later route that takes the address takes
// no connection of this one's.
func (k kernelRoutes) unpair(r *route) error {
	if err := removePair(r.slot); err != nil {
		return err
	}
	return forgetConnections(r.inner)
}

func (k kernelRoutes) unrules(r *route) error { return k.apply("unroute", outerName(r.slot)) }

// server answers every connection's requests one at a time: mu is held
// across each request's changes, whichever connection asked.
type server struct {
	log   *logx.Logger
	netns string
	rng   netip.Prefix
	maker routeMaker
	// upstream is the island's resolver the routes' names are asked of.
	upstream string

	mu sync.Mutex
	// taken holds the slots of routes made and not yet wholly withdrawn: a
	// slot whose withdrawal failed stays taken for the guard's life.
	taken [slots]bool
	marks uint32
	// sockets holds the name sockets of every route standing, by inode:
	// a socket is one route's, and is refused to another.
	sockets map[uint64]bool
	// pending holds every route whose withdrawal failed: it keeps its slot
	// and is tried again until it is gone, or the guard ends.
	pending map[*route]bool
	// routes holds each open connection's routes by spawn id, standing,
	// being tried again, or withdrawn by a retry and not yet asked for: a
	// clear of one the retry withdrew answers cleared once and touches
	// nothing. A connection's entry goes at its end.
	routes map[uint64]map[string]*route
	// bound is withdrawBound and interval retryInterval; tests shorten
	// them.
	bound    time.Duration
	interval time.Duration
	conns    atomic.Uint64
	// onEnd, when set, is called once a connection's withdrawals are done.
	onEnd func()
	// exit ends the guard; os.Exit in production.
	exit func(code int)
	// now is the clock the withdrawal's bound is read on.
	now func() time.Time
}

func newServer(log *logx.Logger, netns string, rng netip.Prefix, maker routeMaker) *server {
	return &server{log: log, netns: netns, rng: rng, maker: maker, upstream: islandResolver,
		pending: map[*route]bool{}, routes: map[uint64]map[string]*route{}, exit: os.Exit, now: time.Now,
		bound: withdrawBound, interval: retryInterval}
}

// serve answers one connection until it ends, then withdraws every route
// made over it and not cleared since.
func (s *server) serve(conn *net.UnixConn) {
	defer conn.Close()
	id := s.conns.Add(1)
	s.mu.Lock()
	s.routes[id] = map[string]*route{}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		made := s.routes[id]
		delete(s.routes, id)
		standing, withdrawn := 0, 0
		for _, r := range made {
			if r.gone {
				continue
			}
			standing++
			if err := s.withdrawLocked(r); err == nil {
				withdrawn++
			}
		}
		s.mu.Unlock()
		switch {
		case standing == 0:
		case withdrawn == standing:
			s.log.Warn("control: connection %d ended; its %d routes are withdrawn", id, standing)
		default:
			s.log.Error("control: connection %d ended; %d of its %d routes are withdrawn, and the guard tries the rest again", id, withdrawn, standing)
		}
		if s.onEnd != nil {
			s.onEnd()
		}
	}()
	hello, err := Encode(Message{Type: TypeHello, Netns: s.netns})
	if err == nil {
		_, err = conn.Write(hello)
	}
	if err != nil {
		return
	}
	for {
		var fds []int
		packet, err := readPacket(conn, &fds)
		if err != nil {
			return
		}
		files := make([]*os.File, len(fds))
		for i, fd := range fds {
			files[i] = os.NewFile(uintptr(fd), "descriptor")
		}
		reply := s.answer(id, packet, files)
		out, err := Encode(reply)
		if err == nil {
			_, err = conn.Write(out)
		}
		if err != nil {
			return
		}
	}
}

// answer applies one request and names its outcome. The descriptors it
// came with are the route's from an admit that is admitted, and are closed
// otherwise.
func (s *server) answer(id uint64, packet []byte, files []*os.File) Message {
	keep := false
	defer func() {
		if !keep {
			for _, f := range files {
				_ = f.Close()
			}
		}
	}()
	req, err := ParseRequest(packet, len(files))
	if err != nil {
		s.log.Warn("control: connection %d: refused a request: %v", id, err)
		return Message{Type: TypeRefused, SpawnID: spawnIDOf(packet), Reason: err.Error()}
	}
	refuse := func(reason string) Message {
		return Message{Type: TypeRefused, SpawnID: req.SpawnID, Reason: reason}
	}
	switch req.Type {
	case TypeAdmit:
		s.mu.Lock()
		held := s.routes[id][req.SpawnID] != nil
		s.mu.Unlock()
		if held {
			return refuse("this connection already holds a route for the spawn")
		}
		_, err := s.admit(id, req, files)
		if err != nil {
			s.log.Error("control: connection %d: refused the route of spawn %s: %v", id, req.SpawnID, err)
			return refuse("the guard could not make the route: " + err.Error())
		}
		keep = true
		return Message{Type: TypeAdmitted, SpawnID: req.SpawnID}
	default:
		// The lookup and every step of the withdrawal are taken under the
		// one lock: no retry runs between them, and a route the retry
		// withdrew before is answered cleared and touched no more.
		s.mu.Lock()
		defer s.mu.Unlock()
		r := s.routes[id][req.SpawnID]
		if r == nil {
			return refuse("this connection holds no route for the spawn")
		}
		if err := s.withdrawLocked(r); err != nil {
			return refuse("the guard could not remove the whole route, and tries again: " + err.Error())
		}
		delete(s.routes[id], req.SpawnID)
		return Message{Type: TypeCleared, SpawnID: req.SpawnID}
	}
}

// admit makes a route: a free slot, its pair, its rules and its names, or
// nothing that stays.
func (s *server) admit(id uint64, req Message, files []*os.File) (*route, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	slot := -1
	for i := range s.taken {
		if !s.taken[i] {
			slot = i
			break
		}
	}
	if slot < 0 {
		return nil, fmt.Errorf("every one of the %d routes of %s is taken", slots, s.rng)
	}
	var sockets [2]uint64
	for i, f := range files[1:] {
		ino, err := nsInode(int(f.Fd()))
		if err != nil {
			return nil, err
		}
		if s.sockets[ino] || (i == 1 && ino == sockets[0]) {
			return nil, errors.New("a name socket is another route's")
		}
		sockets[i] = ino
	}
	s.marks++
	gateway, inner := slotAddresses(s.rng, slot)
	r := &route{spawnID: req.SpawnID, slot: slot, gateway: gateway, inner: inner, mark: s.marks, conn: id,
		reach: req.Reach, addresses: req.Addresses, netns: files[0], udp: files[1], tcp: files[2], sockets: sockets}
	s.taken[slot] = true
	if s.sockets == nil {
		s.sockets = map[uint64]bool{}
	}
	s.sockets[sockets[0]], s.sockets[sockets[1]] = true, true
	fail := func(err error) (*route, error) {
		if uerr := s.withdrawLocked(r); uerr != nil {
			s.log.Error("control: the parts of spawn %s's refused route could not all be removed, and slot %d stays taken while the guard tries again: %v", r.spawnID, slot, uerr)
		}
		return nil, err
	}
	if err := s.maker.pair(r); err != nil {
		return fail(err)
	}
	if err := s.maker.rules(r); err != nil {
		return fail(fmt.Errorf("its rules: %w", err))
	}
	n, err := serveNames(r.udp, r.tcp, s.upstream)
	if err != nil {
		return fail(fmt.Errorf("its names: %w", err))
	}
	r.names = n
	s.routes[id][req.SpawnID] = r
	s.log.Info("control: route %s of spawn %s made, %s to %s, reach %s", outerName(r.slot), r.spawnID, r.gateway, r.inner, r.reach)
	// The namespace is the pair's to hold now; the sockets are the names'.
	_ = r.netns.Close()
	r.netns = nil
	return r, nil
}

// withdraw takes a route down, the pair first so nothing passes, then its
// names and its rules, and frees its slot only once all of it is gone. A
// route not wholly withdrawn keeps its slot, and so its address, and is
// tried again (retryLoop) until it is gone or withdrawBound has passed.
func (s *server) withdraw(r *route) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.withdrawLocked(r)
}

// withdrawLocked is withdraw with s.mu held. A route already gone is not
// touched: its slot and address may be a later route's.
func (s *server) withdrawLocked(r *route) error {
	if r.gone {
		return nil
	}
	if r.names != nil {
		r.answered = r.names.answered.Load()
	}
	if err := s.undo(r); err != nil {
		if r.failedAt.IsZero() {
			r.failedAt = s.now()
		}
		s.pending[r] = true
		s.log.Error("control: route %s of spawn %s could not all be removed, and keeps its slot while the guard tries again: %v", outerName(r.slot), r.spawnID, err)
		return err
	}
	// Complete and recorded before its slot, and so its address, is given
	// again.
	r.gone = true
	delete(s.pending, r)
	delete(s.sockets, r.sockets[0])
	delete(s.sockets, r.sockets[1])
	s.taken[r.slot] = false
	s.log.Info("control: route %s of spawn %s withdrawn; it answered %d names", outerName(r.slot), r.spawnID, r.answered)
	return nil
}

// retryLoop tries every route not yet withdrawn again, each retryInterval.
func (s *server) retryLoop(stop <-chan struct{}) {
	tick := time.NewTicker(s.interval)
	defer tick.Stop()
	for {
		select {
		case <-stop:
			return
		case <-tick.C:
			s.retryPending()
		}
	}
}

// retryPending tries each route not yet withdrawn once. One that still
// fails past withdrawBound ends the guard.
func (s *server) retryPending() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for r := range s.pending {
		if err := s.withdrawLocked(r); err == nil {
			continue
		}
		if s.now().Sub(r.failedAt) > s.bound {
			s.log.Error("control: route %s of spawn %s could not be withdrawn within %s; the guard ends, and its namespace with every route", outerName(r.slot), r.spawnID, s.bound)
			s.exit(ExitServe)
			return
		}
	}
}

// undo removes every part of r that stands; s.mu is held. Each part is
// removed once: a route tried again removes only what is left of it.
func (s *server) undo(r *route) error {
	err := s.maker.unpair(r)
	if r.names != nil {
		r.names.stop()
		r.names = nil
	}
	for _, f := range []*os.File{r.netns, r.udp, r.tcp} {
		if f != nil {
			_ = f.Close()
		}
	}
	r.netns, r.udp, r.tcp = nil, nil, nil
	if rerr := s.maker.unrules(r); err == nil {
		err = rerr
	}
	return err
}

// spawnIDOf is the spawn id a refused packet names, when it names one the
// grammar takes, so its refusal still names it.
func spawnIDOf(packet []byte) string {
	m, err := Decode(packet)
	if err != nil || !spawnIDPattern.MatchString(m.SpawnID) {
		return ""
	}
	return m.SpawnID
}

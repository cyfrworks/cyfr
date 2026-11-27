// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/admission"
	"github.com/cyfr/locus/keeper/internal/cgroup"
	"github.com/cyfr/locus/keeper/internal/frame"
	"github.com/cyfr/locus/keeper/internal/home"
	"github.com/cyfr/locus/keeper/internal/packview"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/vm"
)

// A person's machine (plan V2). Where the keeper gives the VM wall (wall),
// every disk is an image and each person's kept sessions run in a VM of
// their own, which boots at their first session the keeper admits: the
// person's disk is its one writable drive, the guard's machine route its
// one card, and the guest's keeper, under the guest's own guard, makes each
// session's space and route inside it as this keeper makes a space on the
// host. This keeper is the guest's keeper's one client: over the VM's
// control connection it places each session, makes its home, puts its
// packs and spawns it, by the keeper protocol's own lines, and joins its
// standard streams to the role's attach socket through the VM's attach
// port. The host binds the VM's traffic to the person: the guard allows the
// VM what the person's live sessions together may reach, changed at each
// admission and each release, and never trusts the guest to tell one
// session from another. The host is charged once for the VM, by its
// reading (admission.NewMachine).
//
// Every loss has its path, and the VM's place is released on one
// condition: the VMM's group is empty, its route withdrawn on the guard's
// word, and its device's lock free.
//   - The guard's connection ends (guardLost): the VMM is killed, and every
//     session in it ends as the VM's end.
//   - A change the guard refuses while the old reach stands refuses the
//     session that needed it; one that leaves the route withdrawn, or a
//     narrowing still refused past narrowWait, ends the VM.
//   - The VMM ends, the guest's first process with it: every session in it
//     ends with SIGKILL, said as the machine's memory where the VMM's group's
//     own counters say so.
//   - The control connection ends, the guest's relay with it: the guest's
//     keeper ends the relay's sessions, and here each ends with SIGKILL; the
//     VM stays, and its next session connects again.
//   - A guest that does not answer within its bound, or answers from
//     another boot: the VM is in no known state, and ends.
//   - The keeper ends: its VMMs end with it, and its successor ends any it
//     left in their groups before it admits anything (cgroup.Tree.Role).

// guestWait bounds one answer of the guest's keeper: a place's past its
// own wait for room (admission.RoomWait), every other's alone. A variable
// its tests shorten.
var guestWait = 30 * time.Second

const (
	// attachDrain bounds the wait of a session's release for the last
	// bytes of its standard streams once its guest has released it.
	attachDrain = 5 * time.Second
	// narrowWait bounds how long a person's VM's route may allow more than
	// their live sessions together, a narrowing the guard refuses while
	// the old reach stands and which each sweep asks again: past it, the
	// VM ends as at the guard's loss.
	narrowWait = 30 * time.Second
	// machineBootWait bounds a session's wait for its person's VM's boot
	// to end: the device's making within its own bound (vm.MakeWait), the
	// VMM's stage and its relay's Hello (vm.ReadyWait).
	machineBootWait = vm.MakeWait + time.Minute
)

// vmEndWait bounds the wait of a control connection's end for its VMM's,
// so a session lost with its VM is said lost for the VM's memory where its
// counters say so: a variable its tests shorten.
var vmEndWait = 2 * time.Second

// guestVM is a person's VM as the keeper drives it: a *vm.Machine in
// production (startVM), a stand-in in tests.
type guestVM interface {
	ConnectWithin(left time.Duration) (guestControl, error)
	Dial(port uint32, within time.Duration) (net.Conn, error)
	// End asks the guest's first process to end the VM, and kills the VMM
	// past within (vm.Machine.End).
	End(within time.Duration) vm.Ended
	Kill()
	Done() <-chan struct{}
	HowEnded() vm.Ended
	KilledFor() (cgroup.Cause, error)
	// Group is the VMM's group while it runs, which the guard's loss kills;
	// Used is its reading, the host's one charge for the VM.
	Group() *cgroup.Group
	Used() (cgroup.Use, error)
	PID() int
}

// guestControl is a VM's control connection: the relay's Hello, then the
// guest keeper's channel, line by line.
type guestControl interface {
	BootID() string
	Send(v any) error
	Next(deadline time.Time) ([]byte, error)
	Close() error
}

// vmBoot is what a person's VM is started with (startVM).
type vmBoot struct {
	Disk, KeptRoot string
	UID            int
	MemoryMiB      int
	VCPUs          int
	Groups         *cgroup.Manager
	// Route makes the VM's route, as the VMM's uid's, from its space's
	// four descriptors (vm.Config.Route).
	Route func(uid int, netns, udp, tcp, nl *os.File) (vm.Network, error)
}

// machineOf is the production *vm.Machine as a guestVM.
type machineOf struct{ *vm.Machine }

func (m machineOf) ConnectWithin(left time.Duration) (guestControl, error) {
	c, err := m.Machine.ConnectWithin(left)
	if err != nil {
		return nil, err
	}
	return controlOf{c}, nil
}

// Used reads the VMM's group, by the reader's seam.
func (m machineOf) Used() (cgroup.Use, error) { return readUse(m.Group()) }

type controlOf struct{ *vm.Control }

func (c controlOf) BootID() string { return c.Hello.BootID }

// startVM starts a person's VM (vm.Start), with the image's programs'
// device, which it holds from here to its end.
func startVM(b vmBoot) (guestVM, error) {
	device, _, err := vm.Programs(io.Discard).Device()
	if err != nil {
		return nil, err
	}
	m, err := vm.Start(vm.Config{Device: device, VCPUs: b.VCPUs, MemoryMiB: b.MemoryMiB, Groups: b.Groups,
		Disk: b.Disk, KeptRoot: b.KeptRoot, UID: b.UID, Route: b.Route})
	if err != nil {
		return nil, err
	}
	return machineOf{m}, nil
}

// machineRef is a VM's own place's Ref in the ledger.
type machineRef struct{ m *machine }

// machine is one person's VM, from the first place of theirs on a keeper
// that gives the wall to its release. s.mu guards every field but those
// its own locks guard.
type machine struct {
	athanor string
	// id names its route at the guard, its spawn id there.
	id string
	// entry is its own place in the ledger (admission.NewMachine), admitted
	// with the first of its sessions' places to be.
	entry *admission.Entry
	// places counts the session places that name it, admitted or waiting:
	// a VM never booted goes with the last of them.
	places int
	// prev is the VM of the person this one follows while that one ends:
	// this one boots only once it is released.
	prev *machine
	// bootMu holds one boot at a time; booted closes once vm is set, or
	// bootErr says why none is.
	bootMu  sync.Mutex
	vm      guestVM
	bootID  string
	booting bool
	// route is its route at the guard, held until withdrawn; reach and
	// addrs are what it allows now, the union of its live sessions'.
	route *guard.Route
	reach string
	addrs []netip.Addr
	// reachMu orders the changes of its route.
	reachMu sync.Mutex
	// narrowing is since when a narrowing of its route has been refused,
	// zero for none: while it stands no session joins.
	narrowing time.Time
	// link is its control connection standing, nil for none.
	link *guestLink
	// linkMu holds one connection's making at a time.
	linkMu sync.Mutex
	// sessions are the spawns in it, by spawn id, from their start to their
	// release.
	sessions map[string]*spawn
	// idleSince is when it last held no session.
	idleSince time.Time
	// reading says a read of its VMM's group is out.
	reading atomic.Bool
	// ending says its end has begun: no session joins it; done closes at
	// its release.
	ending bool
	done   chan struct{}
}

// machineFor is the VM a session place of athanor's names, made for it
// where the person has none standing, or only one that ends; s.mu is held.
func (s *server) machineFor(r *role, athanor string) *machine {
	if s.vms == nil {
		s.vms = map[string]*machine{}
	}
	if m := s.vms[athanor]; m != nil && !m.ending {
		return m
	}
	m := &machine{athanor: athanor, id: randomHex(16), sessions: map[string]*spawn{}, reach: guard.ReachNone,
		done: make(chan struct{}), prev: s.vms[athanor]}
	m.entry = admission.NewMachine(r.spec.Name, athanor, machineRef{m: m})
	s.vms[athanor] = m
	return m
}

// unplaced is a session place of m's that went, with s.mu held: a VM no
// place names any more and never booted goes with it.
func (s *server) unplaced(m *machine) {
	m.places--
	if m.places > 0 || m.vm != nil || m.booting {
		return
	}
	if s.vms[m.athanor] == m {
		delete(s.vms, m.athanor)
	}
	if m.entry.Admitted() {
		s.admit(s.ledger.Drop(m.entry, now()))
	}
	select {
	case <-m.done:
	default:
		close(m.done)
	}
}

// bootMachine boots m unless it runs, within machineBootWait, and answers
// the code its session is refused with: the device not made, the VMM not
// started, its route not made or its relay unheard (CodeUnavailable, or
// CodeGuardUnavailable for the route).
func (s *server) bootMachine(m *machine, at keptAt, r *role) string {
	m.bootMu.Lock()
	defer m.bootMu.Unlock()
	s.mu.Lock()
	running, ending := m.vm != nil, m.ending
	if !running && !ending {
		m.booting = true
	}
	prev := m.prev
	s.mu.Unlock()
	switch {
	case ending:
		return protocol.CodeUnavailable
	case running:
		return ""
	}
	defer func() {
		s.mu.Lock()
		m.booting = false
		s.mu.Unlock()
	}()
	if prev != nil {
		select {
		case <-prev.done:
		case <-time.After(machineBootWait):
			s.log.Warn("the VM of a person's disk of uid %d did not boot: their last VM was not yet released", at.uid)
			return protocol.CodeUnavailable
		}
	}
	// The image is given its VM only as its uid's alone: the stage's bind
	// of a file follows a link at its source.
	image := s.cfg.Kept.ImagePath(at.athanor)
	if err := home.CheckImage(image, at.uid); err != nil {
		s.log.Error("the VM of a person's disk of uid %d is not started: %v", at.uid, err)
		return protocol.CodeUnavailable
	}
	boot := s.bootVM
	if boot == nil {
		boot = startVM
	}
	routeCode := ""
	g, err := boot(vmBoot{Disk: image, KeptRoot: s.keptRoot(), UID: at.uid, MemoryMiB: s.machineMiB(), VCPUs: s.machineVCPUs(r),
		Groups: r.groups, Route: func(uid int, netns, udp, tcp, nl *os.File) (vm.Network, error) {
			mr, err := s.guard.AdmitMachine(m.id, uid, guard.ReachNone, nil, netns, udp, tcp, nl)
			if err != nil {
				routeCode = protocol.CodeGuardUnavailable
				return vm.Network{}, err
			}
			// Admitted, the route is the VM's to withdraw, whatever follows;
			// it counts only while its connection is the live one, decided
			// under s.mu, which the guard's loss takes too.
			s.mu.Lock()
			defer s.mu.Unlock()
			route := mr.Route
			m.route = &route
			if s.lostRoutes[mr.Conn] || !s.guard.Live(mr.Route) {
				routeCode = protocol.CodeGuardUnavailable
				return vm.Network{}, errors.New("the guard's connection ended as the VM's route was admitted")
			}
			return vm.Network{Inner: mr.Inner, Gateway: mr.Gateway}, nil
		}})
	if err != nil {
		// A start that failed after its route was made holds it here: it
		// is withdrawn now, as at the VM's end.
		s.withdrawRoute(m.id, &m.route)
		s.log.Error("the VM of a person's disk of uid %d did not start: %v", at.uid, err)
		if routeCode != "" {
			return routeCode
		}
		return protocol.CodeUnavailable
	}
	s.mu.Lock()
	m.vm, m.idleSince = g, now()
	s.ledger.Spawned(m.entry, now())
	s.mu.Unlock()
	go s.watchMachine(m)
	if _, code := s.machineLink(m); code != "" {
		s.loseMachine(m, "its relay did not greet it")
		return code
	}
	s.log.Info("the VM of a person's disk of uid %d booted, its VMM pid %d", at.uid, g.PID())
	return ""
}

// machineMiB is a person's VM's memory: rest, all a person's work may use;
// the host's group over every VMM holds them to it together, and each
// gives back what it frees by free-page reporting.
func (s *server) machineMiB() int {
	return int(max(s.rest>>20, 128))
}

// machineVCPUs is a person's VM's processors: as many as its role's work
// is given, at least a session's.
func (s *server) machineVCPUs(r *role) int {
	n := int(admission.Processors[admission.Session])
	if r.workCPU > 0 {
		n = max(n, int((r.workCPU+cgroup.CPUPeriod-1)/cgroup.CPUPeriod))
	}
	return n
}

// machineLink is m's control connection, made where none stands: within
// guestWait, its Hello from the boot m first heard, or m is lost.
func (s *server) machineLink(m *machine) (*guestLink, string) {
	m.linkMu.Lock()
	defer m.linkMu.Unlock()
	s.mu.Lock()
	l, g, bootID, ending := m.link, m.vm, m.bootID, m.ending
	s.mu.Unlock()
	if ending || g == nil {
		return nil, protocol.CodeUnavailable
	}
	if l != nil {
		return l, ""
	}
	c, err := g.ConnectWithin(vm.ReadyWait)
	if err != nil {
		s.log.Warn("a person's VM's control connection: %v", err)
		return nil, protocol.CodeUnavailable
	}
	if bootID != "" && c.BootID() != bootID {
		// A guest that answers from another boot is no VM this keeper
		// started: what it says settles nothing.
		_ = c.Close()
		s.loseMachine(m, "its guest answered from another boot")
		return nil, protocol.CodeUnavailable
	}
	l = &guestLink{s: s, m: m, ctl: c, waiters: map[string]chan []byte{}, spawns: map[string]*spawn{},
		pending: map[string]*spawn{}, ended: make(chan struct{}), guestWait: guestWait, endWait: vmEndWait}
	s.mu.Lock()
	if m.ending {
		s.mu.Unlock()
		_ = c.Close()
		return nil, protocol.CodeUnavailable
	}
	m.bootID, m.link = c.BootID(), l
	s.mu.Unlock()
	go l.read()
	return l, ""
}

// watchMachine waits for m's VMM to end, by any cause, and ends m.
func (s *server) watchMachine(m *machine) {
	<-m.vm.Done()
	s.machineEnded(m)
}

// loseMachine ends m at once: its VMM is killed, and its end follows
// (watchMachine).
func (s *server) loseMachine(m *machine, why string) {
	s.mu.Lock()
	g := m.vm
	s.mu.Unlock()
	s.log.Warn("a person's VM ends: %s", why)
	if g != nil {
		go g.Kill()
	}
}

// machineEnded ends every session of m's ended VMM, as the VM's end, then
// withdraws its route and releases it (finishMachine).
// A session whose start is still under way is refused by its start, which
// finds its guest gone; every other is retired by its follower
// (followGuest), each in its own time, and the last to go releases m.
func (s *server) machineEnded(m *machine) {
	s.mu.Lock()
	m.ending = true
	if s.vmsEnding == nil {
		s.vmsEnding = map[*machine]bool{}
	}
	s.vmsEnding[m] = true
	s.ledger.Ending(m.entry, now())
	l := m.link
	m.link = nil
	sessions := make([]*spawn, 0, len(m.sessions))
	for _, sp := range m.sessions {
		sessions = append(sessions, sp)
	}
	s.mu.Unlock()
	memory := memoryOf(m.vm.KilledFor())
	s.log.Warn("a person's VM ended (%s): its %d sessions end with it", m.vm.HowEnded(), len(sessions))
	if l != nil {
		l.end(memory)
	}
	for _, sp := range sessions {
		sp.gone(memory)
	}
	s.withdrawRoute(m.id, &m.route)
	s.finishMachine(m)
}

// memoryOf is what an ended VMM's group's counters say the kernel killed
// for: the VM's own bound or a limit above it, both the machine's to its
// sessions, or one of the two that they cannot tell apart; nil for none.
func memoryOf(cause cgroup.Cause, err error) *string {
	var memory string
	switch {
	case err != nil:
		return nil
	case cause == cgroup.AtBound, cause == cgroup.Above:
		memory = protocol.MemoryMachine
	case cause == cgroup.Either:
		memory = protocol.MemoryEither
	default:
		return nil
	}
	return &memory
}

// finishMachine releases an ended m once its route is withdrawn on the
// guard's word and every session of it has gone: its place leaves the
// ledger, and the person's next session boots a VM again. One whose route
// is not yet withdrawn is released by the sweep that withdraws it.
func (s *server) finishMachine(m *machine) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !m.ending || m.route != nil || len(m.sessions) > 0 {
		return
	}
	select {
	case <-m.done:
		return
	default:
	}
	if s.vms[m.athanor] == m {
		delete(s.vms, m.athanor)
	}
	delete(s.vmsEnding, m)
	s.admit(s.ledger.Drop(m.entry, now()))
	close(m.done)
	s.log.Info("a person's VM is released: its group is empty, its route withdrawn and its device let go")
}

// finishMachines releases every ended VM whose route a sweep withdrew.
func (s *server) finishMachines() {
	s.mu.Lock()
	ended := make([]*machine, 0, len(s.vmsEnding))
	for m := range s.vmsEnding {
		ended = append(ended, m)
	}
	s.mu.Unlock()
	for _, m := range ended {
		s.finishMachine(m)
	}
}

// machineRoutes holds the VMs routed over conn, for the guard's loss.
func (s *server) machineRoutes(conn uint64) []*machine {
	var lost []*machine
	for _, m := range s.vms {
		if m.route != nil && m.route.Conn == conn && m.vm != nil && !m.ending {
			lost = append(lost, m)
		}
	}
	return lost
}

// killMachineGroup kills every process of m's VMM's group at once and
// answers whether the group is empty, or gone with the VMM's end.
func killMachineGroup(m *machine) bool {
	g := m.vm.Group()
	if g == nil || g.KillBy(time.Now()) {
		return true
	}
	_, err := g.Procs()
	return errors.Is(err, os.ErrNotExist)
}

// A route's reach: what one session may reach, and what a VM's sessions
// together may.

// unionOf is the reach of sessions together: none for none, the island's
// where any has it, otherwise every host address any of them names, each
// once and in order.
func unionOf(sessions []*spawn) (string, []netip.Addr) {
	if len(sessions) == 0 {
		return guard.ReachNone, nil
	}
	var addrs []netip.Addr
	for _, sp := range sessions {
		if !sp.egress.listed {
			return guard.ReachIsland, nil
		}
		addrs = append(addrs, sp.egress.addrs...)
	}
	for i := range addrs {
		addrs[i] = addrs[i].Unmap().WithZone("")
	}
	slices.SortFunc(addrs, func(a, b netip.Addr) int { return a.Compare(b) })
	return guard.ReachHosts, slices.Compact(addrs)
}

// errTooManyHosts refuses a session whose hosts would carry its person's
// VM's route past the guard's bound.
var errTooManyHosts = fmt.Errorf("the person's live sessions together would name more than %d host addresses", guard.MaxAddresses)

// errNarrowing refuses a session while its person's VM's route still
// allows more than their live sessions.
var errNarrowing = errors.New("the person's VM's route still allows a released session's hosts")

// errRouteLost is a change after which the VM has no route.
var errRouteLost = errors.New("the person's VM's route is lost")

// reroute changes m's route to its live sessions' union, with without
// left out, and answers whether the guard holds it: a change refused while
// the old reach stands is errRefused's (the old reach stands); a route
// withdrawn or gone ends the VM (errRouteLost).
func (s *server) reroute(m *machine, without *spawn) error {
	m.reachMu.Lock()
	defer m.reachMu.Unlock()
	s.mu.Lock()
	var live []*spawn
	for _, sp := range m.sessions {
		if sp != without {
			live = append(live, sp)
		}
	}
	reach, addrs := unionOf(live)
	same := reach == m.reach && slices.Equal(addrs, m.addrs)
	r, ending := m.route, m.ending
	s.mu.Unlock()
	if same {
		return nil
	}
	if ending {
		return errRouteLost
	}
	if reach == guard.ReachHosts && len(addrs) > guard.MaxAddresses {
		return errTooManyHosts
	}
	if r == nil {
		return errRouteLost
	}
	err := s.guard.Change(m.id, *r, reach, addrs)
	switch {
	case err == nil:
		s.mu.Lock()
		m.reach, m.addrs = reach, addrs
		s.mu.Unlock()
		return nil
	case errors.Is(err, guard.ErrRouteWithdrawn), errors.Is(err, guard.ErrConnectionGone):
		s.mu.Lock()
		m.route = nil
		s.mu.Unlock()
		s.loseMachine(m, fmt.Sprintf("its route is lost: %v", err))
		return errRouteLost
	default:
		return err
	}
}

// joinMachine makes sp one of m's sessions and widens m's route to hold it,
// answering the code sp is refused with: m's route still narrowing, its
// hosts past the guard's bound, or the guard refusing the change.
func (s *server) joinMachine(m *machine, sp *spawn) string {
	s.mu.Lock()
	switch {
	case m.ending:
		s.mu.Unlock()
		return protocol.CodeUnavailable
	case !m.narrowing.IsZero():
		s.mu.Unlock()
		s.log.Warn("spawn %s refused: %v", sp.id, errNarrowing)
		return protocol.CodeGuardUnavailable
	}
	m.sessions[sp.id] = sp
	s.mu.Unlock()
	if err := s.reroute(m, nil); err != nil {
		s.mu.Lock()
		delete(m.sessions, sp.id)
		s.mu.Unlock()
		s.log.Warn("spawn %s refused: its person's VM's route: %v", sp.id, err)
		if errors.Is(err, errTooManyHosts) {
			return protocol.CodeUnavailable
		}
		return protocol.CodeGuardUnavailable
	}
	return ""
}

// leaveMachine takes sp out of its VM at its release, and narrows the VM's
// route to the sessions left: a narrowing the guard refuses while the old
// reach stands is asked again at each sweep (retryNarrowing).
func (s *server) leaveMachine(sp *spawn) {
	m := sp.machine
	err := s.reroute(m, sp)
	s.mu.Lock()
	delete(m.sessions, sp.id)
	if len(m.sessions) == 0 {
		m.idleSince = now()
	}
	if err != nil && !errors.Is(err, errRouteLost) && !m.ending && m.narrowing.IsZero() {
		m.narrowing = now()
	}
	s.mu.Unlock()
	if err != nil && !errors.Is(err, errRouteLost) {
		s.log.Warn("a person's VM's route still allows a released session's hosts, and is narrowed again at each sweep: %v", err)
	}
	s.finishMachine(m)
}

// retryNarrowing asks the guard again for every VM whose route still
// allows a released session's hosts; one past narrowWait ends as at the
// guard's loss.
func (s *server) retryNarrowing() {
	s.mu.Lock()
	var due []*machine
	for _, m := range s.vms {
		if !m.narrowing.IsZero() && !m.ending {
			due = append(due, m)
		}
	}
	s.mu.Unlock()
	for _, m := range due {
		err := s.reroute(m, nil)
		s.mu.Lock()
		since := m.narrowing
		if err == nil {
			m.narrowing = time.Time{}
		}
		s.mu.Unlock()
		switch {
		case err == nil:
			s.log.Info("a person's VM's route is narrowed to its live sessions again")
		case errors.Is(err, errRouteLost):
		case now().Sub(since) >= narrowWait:
			s.loseMachine(m, fmt.Sprintf("its route allowed a released session's hosts past %s: %v", narrowWait, err))
		}
	}
}

// startMachineSpawn starts a kept spawn of an image disk in its person's
// VM, booting it where none runs: the VM's route widened to hold it, its
// place and home made in the guest, its packs put there where the guest
// holds none, its spawn there, and its standard streams joined to its
// role's attach socket. It answers as startSpawn does.
func (s *server) startMachineSpawn(c *client, req *protocol.Request, at keptAt, reach string, e egress, limits admission.Limits) (*spawn, string) {
	sp, code := s.startInMachine(c, req, at, reach, e, limits)
	if sp != nil && code != "" {
		// Refused once made: it is owed no exit, and its follower sends
		// none.
		sp.exitOnce.Do(func() {})
		close(sp.announced)
	}
	return sp, code
}

func (s *server) startInMachine(c *client, req *protocol.Request, at keptAt, reach string, e egress, limits admission.Limits) (*spawn, string) {
	s.mu.Lock()
	p := c.places[req.Place]
	var m *machine
	if p != nil {
		m = p.machine
	}
	s.mu.Unlock()
	if m == nil || m.athanor != at.athanor {
		s.log.Warn("spawn %s refused: its place is no place in its person's VM", req.ID)
		return nil, protocol.CodeBadRequest
	}
	if code := s.bootMachine(m, at, c.role); code != "" {
		return nil, code
	}
	sp := &spawn{id: randomHex(16), client: c, kept: true, machine: m, account: KeptAccount(at.uid), keptHome: req.Home,
		home: at.path, work: at.work, disk: at.disk, reach: reach, egress: e, limits: limits,
		retired: make(chan struct{}), guestEnded: make(chan struct{}), announced: make(chan struct{}),
		guestEvents: make(chan []byte, 4)}
	s.madeIn(req.Place, sp)
	if code := s.joinMachine(m, sp); code != "" {
		return sp, code
	}
	l, code := s.machineLink(m)
	if code != "" {
		return sp, code
	}
	s.mu.Lock()
	sp.link = l
	s.mu.Unlock()
	if code := s.guestStart(l, sp, req, at); code != "" {
		return sp, code
	}
	// The VM's route is lost meanwhile only by the guard's end, which ends
	// the VM; a session whose VM ended is refused here and retired.
	s.mu.Lock()
	ending := m.ending
	s.mu.Unlock()
	if ending {
		return sp, protocol.CodeGuardUnavailable
	}
	if !s.hold(sp) {
		return sp, protocol.CodeInternal
	}
	s.log.Info("spawn %s: in the VM of kept uid %d, its spawn %s there", sp.id, at.uid, sp.guest)
	s.send(c, protocol.NewSpawned(req.ID, sp.id, at.uid, sp.guestPID))
	close(sp.announced)
	return sp, ""
}

// reachName is the guard's name of an egress.
func (e egress) reachName() string {
	if e.listed {
		return guard.ReachHosts
	}
	return guard.ReachIsland
}

// guestStart makes sp in the guest over l: its place, its home, its packs
// and its spawn, then its standard streams joined. A refusal of the guest
// is answered as its code; an answer that does not come, or a line the
// guest should not send, ends the VM.
func (s *server) guestStart(l *guestLink, sp *spawn, req *protocol.Request, at keptAt) string {
	s.mu.Lock()
	p := sp.client.places[req.Place]
	whose := p.whose
	s.mu.Unlock()
	place := randomHex(16)
	answer, err := l.ask(protocol.Request{V: protocol.Version, Type: protocol.TypePlace, ID: place, Kind: whose.Kind,
		Athanor: whose.Athanor, Subject: whose.Subject}, admission.RoomWait+l.guestWait)
	if err != nil {
		return s.guestLost(l, sp, "placing", err)
	}
	if answer.Type != "placed" {
		s.log.Warn("spawn %s refused: its VM's keeper refused its place: %s", sp.id, answer.Code)
		return protocol.CodeUnavailable
	}
	s.mu.Lock()
	sp.guestPlace = place
	s.mu.Unlock()
	drop := func() { _ = l.ctl.Send(protocol.Request{V: protocol.Version, Type: protocol.TypeDrop, Place: place}) }
	answer, err = l.ask(protocol.Request{V: protocol.Version, Type: protocol.TypeHomeMake, ID: randomHex(16), Home: req.Home,
		Athanor: at.athanor}, l.guestWait)
	if err != nil {
		return s.guestLost(l, sp, "making its home", err)
	}
	if answer.Type != "home_made" {
		drop()
		s.log.Warn("spawn %s refused: its VM's keeper refused its home: %s", sp.id, answer.Code)
		return guestCode(answer.Code)
	}
	var packs *protocol.SpawnPacks
	if req.Packs != nil {
		path, empty, release, err := s.packs.Acquire(req.Packs.Athanor, req.Packs.Digest)
		if err != nil {
			drop()
			s.log.Warn("spawn %s refused: its packs: %v", sp.id, err)
			return protocol.CodeBadRequest
		}
		s.mu.Lock()
		sp.packs = release
		s.mu.Unlock()
		if !empty {
			if code := s.guestPacks(l, sp, req.Packs, path); code != "" {
				drop()
				return code
			}
			packs = req.Packs
		}
	}
	token := randomHex(32)
	spawnReq := protocol.Request{V: protocol.Version, Type: protocol.TypeSpawn, ID: randomHex(16), Place: place,
		Pool: vm.GuestPool, Argv: req.Argv, Env: req.Env, Rlimits: req.Rlimits, Control: req.Control,
		Attach: &protocol.Attach{Path: vm.GuestAttachPath, Token: token}, HomeMode: protocol.HomeKept, Home: req.Home,
		HomeMaxBytes: req.HomeMaxBytes, Pty: req.Pty, Hosts: req.Hosts, Packs: packs}
	wait := l.expectSpawn(spawnReq.ID, sp)
	if err := l.ctl.Send(spawnReq); err != nil {
		l.unexpect(spawnReq.ID)
		return s.guestLost(l, sp, "sending its spawn", err)
	}
	go s.followGuest(sp)
	// The host's half of the space's streams, by the guest's token: the
	// guest's relay holds either half until the other comes.
	guestEnd, err := l.m.vm.Dial(vm.AttachPort, l.guestWait)
	if err == nil {
		err = frame.Write(guestEnd, frame.StreamAttach, []byte(token))
	}
	answer, aerr := l.wait(wait, spawnReq.ID, l.guestWait)
	if aerr != nil {
		if guestEnd != nil {
			_ = guestEnd.Close()
		}
		return s.guestLost(l, sp, "spawning it", aerr)
	}
	if answer.Type != "spawned" {
		if guestEnd != nil {
			_ = guestEnd.Close()
		}
		s.log.Warn("spawn %s refused: its VM's keeper refused its spawn: %s", sp.id, answer.Code)
		return guestCode(answer.Code)
	}
	s.mu.Lock()
	sp.guestPID = answer.PID
	s.mu.Unlock()
	if err != nil {
		if guestEnd != nil {
			_ = guestEnd.Close()
		}
		s.log.Error("spawn %s: its VM's attach port: %v", sp.id, err)
		return protocol.CodeInternal
	}
	role := sp.client.role
	var roleEnd net.Conn
	err = home.AsFileIDs(role.account.UID, role.account.GID, func() error {
		var err error
		roleEnd, err = net.DialTimeout("unix", req.Attach.Path, stageTimeout)
		return err
	})
	if err == nil {
		err = frame.Write(roleEnd, frame.StreamAttach, []byte(req.Attach.Token))
	}
	if err != nil {
		_ = guestEnd.Close()
		if roleEnd != nil {
			_ = roleEnd.Close()
		}
		s.log.Error("spawn %s: its role's attach socket: %v", sp.id, err)
		return protocol.CodeInternal
	}
	sp.splice(roleEnd, guestEnd)
	return ""
}

// guestCode is the code a refusal of the guest's keeper refuses its
// session with here: its own where a role reads it as this keeper's, the
// rest unavailable.
func guestCode(code string) string {
	switch code {
	case protocol.CodeHomeOverCap, protocol.CodeCapacity, protocol.CodeHostsUnresolved, protocol.CodeExecFailed,
		protocol.CodeUIDBusy, protocol.CodeGuardUnavailable:
		return code
	}
	return protocol.CodeUnavailable
}

// guestLost answers a session's start whose guest did not answer: the VM
// is in no known state for it, and ends.
func (s *server) guestLost(l *guestLink, sp *spawn, what string, err error) string {
	s.loseMachine(l.m, fmt.Sprintf("its guest did not answer spawn %s's %s: %v", sp.id, what, err))
	return protocol.CodeUnavailable
}

// guestPacks has the guest hold the generation sp's start names, putting
// the host's own copy, at path, over the control connection where it holds
// none: the host never reads the guest's copy back nor trusts it beyond
// "held".
func (s *server) guestPacks(l *guestLink, sp *spawn, packs *protocol.SpawnPacks, path string) string {
	lifetime := "vm-" + sp.id
	deadline := time.Now().Add(packview.HoldFor)
	for {
		answer, err := l.ask(protocol.Request{V: protocol.Version, Type: protocol.TypePacksHold, ID: randomHex(16),
			Athanor: packs.Athanor, Lifetime: lifetime, Digest: packs.Digest}, l.guestWait)
		if err != nil {
			return s.guestLost(l, sp, "holding its packs", err)
		}
		if answer.Type != "packs" {
			s.log.Warn("spawn %s refused: its VM's keeper refused its packs' hold: %s", sp.id, answer.Code)
			return protocol.CodeUnavailable
		}
		if answer.State == protocol.PacksHeld {
			return ""
		}
		code, busy := s.putGuestPacks(l, sp, packs, lifetime, path)
		if !busy || time.Now().After(deadline) {
			return code
		}
		// Another start of the person's puts the same generation: it is
		// held again once that put has ended.
		time.Sleep(500 * time.Millisecond)
	}
}

// putGuestPacks streams the generation at path to the guest as packs_put
// parts, and answers the code its start is refused with, and busy where
// the guest refused its first part for another put of the person's.
func (s *server) putGuestPacks(l *guestLink, sp *spawn, packs *protocol.SpawnPacks, lifetime, path string) (string, bool) {
	pr, pw := io.Pipe()
	go func() { _ = pw.CloseWithError(packview.Stream(path, pw)) }()
	defer pr.Close()
	buf := make([]byte, protocol.MaxPackPartBytes)
	next := make([]byte, 0, protocol.MaxPackPartBytes)
	n, err := io.ReadFull(pr, buf)
	for seq := uint64(0); ; seq++ {
		if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
			s.log.Error("spawn %s: streaming its packs: %v", sp.id, err)
			return protocol.CodeInternal, false
		}
		last := err != nil
		part := buf[:n]
		var nn int
		var nerr error
		if !last {
			// One part ahead, so the last is told apart before it is sent.
			next = next[:cap(next)]
			nn, nerr = io.ReadFull(pr, next)
			last = nn == 0 && nerr != nil
		}
		data := base64.StdEncoding.EncodeToString(part)
		answer, aerr := l.ask(protocol.Request{V: protocol.Version, Type: protocol.TypePacksPut, ID: randomHex(16),
			Athanor: packs.Athanor, Lifetime: lifetime, Digest: packs.Digest, Seq: &seq, Last: &last, Data: &data}, l.guestWait)
		if aerr != nil {
			return s.guestLost(l, sp, "putting its packs", aerr), false
		}
		if answer.Type != "packs" {
			s.log.Warn("spawn %s refused: its VM's keeper refused its packs at part %d: %s", sp.id, seq, answer.Code)
			return protocol.CodeUnavailable, seq == 0 && answer.Code == protocol.CodePacksBusy
		}
		if last {
			if answer.State != protocol.PacksHeld {
				return protocol.CodeUnavailable, false
			}
			return "", false
		}
		buf, next = next[:cap(next)], buf[:0]
		n, err = nn, nerr
	}
}

// splice joins a session's two halves of its standard streams, the role's
// and the guest's, byte for byte both ways, each written as it was read:
// the frames are the relay's on either side. As a relay on the host ends
// once the space's streams have, the join ends once the guest's half does,
// its last byte handed to the role, or once the role closes its own; then
// both close, and spliced closes.
func (sp *spawn) splice(roleEnd, guestEnd net.Conn) {
	sp.spliceMu.Lock()
	sp.ends = []net.Conn{roleEnd, guestEnd}
	sp.spliced = make(chan struct{})
	done := sp.spliced
	sp.spliceMu.Unlock()
	ended := make(chan struct{}, 2)
	copyOne := func(to, from net.Conn) {
		_, _ = io.Copy(to, from)
		ended <- struct{}{}
	}
	go copyOne(roleEnd, guestEnd)
	go copyOne(guestEnd, roleEnd)
	go func() {
		<-ended
		_ = roleEnd.Close()
		_ = guestEnd.Close()
		<-ended
		close(done)
	}()
}

// drainSplice waits up to attachDrain for sp's streams' last bytes, and
// cuts them past it.
func (sp *spawn) drainSplice() {
	sp.spliceMu.Lock()
	done, ends := sp.spliced, sp.ends
	sp.spliceMu.Unlock()
	if done == nil {
		return
	}
	select {
	case <-done:
	case <-time.After(attachDrain):
		for _, c := range ends {
			_ = c.Close()
		}
		<-done
	}
}

// gone settles a session whose guest is lost to it, its VM or its
// connection ended: no released will come from the guest, and its exit is
// SIGKILL's, memory saying why where the VM's counters do.
func (sp *spawn) gone(memory *string) {
	sp.goneOnce.Do(func() {
		sp.lostMemory = memory
		sp.lost = true
		close(sp.guestEnded)
	})
}

// guestReleased settles a session its guest released.
func (sp *spawn) guestReleased() {
	sp.goneOnce.Do(func() { close(sp.guestEnded) })
}

// followGuest follows a session's guest from its spawn's sending: its
// exit, sent once its spawned has been, and its release, or its guest's
// loss, either of which retires it here.
func (s *server) followGuest(sp *spawn) {
	for {
		select {
		case line := <-sp.guestEvents:
			var ev struct {
				Type   string  `json:"type"`
				Code   *int    `json:"code"`
				Signal *string `json:"signal"`
				Memory *string `json:"memory"`
			}
			if json.Unmarshal(line, &ev) != nil {
				continue
			}
			switch ev.Type {
			case "exited":
				s.guestExit(sp, ev.Code, ev.Signal, ev.Memory)
			case "released":
				sp.guestReleased()
				s.retire(sp, 0, true)
				return
			}
		case <-sp.guestEnded:
			s.mu.Lock()
			lost, memory := sp.lost, sp.lostMemory
			s.mu.Unlock()
			if lost {
				name := "SIGKILL"
				s.guestExit(sp, nil, &name, memory)
			}
			s.retire(sp, 0, true)
			return
		}
	}
}

// guestExit sends sp's one `exited`, once its `spawned` has gone: a spawn
// refused once made has its exit settled as none before.
func (s *server) guestExit(sp *spawn, code *int, signal, memory *string) {
	select {
	case <-sp.announced:
	case <-sp.retired:
	}
	sp.exitOnce.Do(func() {
		if memory != nil {
			s.mu.Lock()
			sp.killedFor = *memory
			s.mu.Unlock()
		}
		s.send(sp.client, protocol.NewExited(sp.id, code, signal, memory))
	})
}

// retireGuest ends a session in a VM once: its guest asked to release it,
// within its grace and guestWait, past which the VM is in no known state
// for it and ends; its streams' last bytes; its place, its packs and its
// part of the VM's route let go. With notify, `released` follows.
func (s *server) retireGuest(sp *spawn, grace time.Duration, notify bool) {
	sp.retireOnce.Do(func() {
		s.mu.Lock()
		s.ending(sp)
		guest, l := sp.guest, sp.link
		s.mu.Unlock()
		go func() {
			defer close(sp.retired)
			select {
			case <-sp.guestEnded:
			default:
				if guest == "" || l == nil {
					break
				}
				ms := grace.Milliseconds()
				if err := l.ctl.Send(protocol.Request{V: protocol.Version, Type: protocol.TypeRelease, SpawnID: guest, GraceMs: &ms}); err != nil {
					s.loseMachine(sp.machine, fmt.Sprintf("spawn %s's release could not be sent: %v", sp.id, err))
				}
				select {
				case <-sp.guestEnded:
				case <-time.After(grace + l.guestWait):
					s.loseMachine(sp.machine, fmt.Sprintf("its guest did not release spawn %s within %s", sp.id, grace+l.guestWait))
					<-sp.guestEnded
				}
			}
			sp.drainSplice()
			if notify {
				// A spawn its guest never made is owed no exit.
				sp.exitOnce.Do(func() {})
			}
			s.mu.Lock()
			s.leave(sp, true, removal{notify: notify})
			s.mu.Unlock()
			s.leaveMachine(sp)
			s.log.Info("spawn %s: released in its person's VM", sp.id)
			if notify {
				s.send(sp.client, protocol.NewReleased(sp.id))
			}
		}()
	})
}

// guestSignal passes a signal to a session in a VM; the guest answers only
// a refusal, which comes back as this keeper's own.
func (s *server) guestSignal(sp *spawn, req *protocol.Request) {
	s.mu.Lock()
	l, guest := sp.link, sp.guest
	s.mu.Unlock()
	if err := l.ctl.Send(protocol.Request{V: protocol.Version, Type: protocol.TypeSignal, SpawnID: guest, Sig: req.Sig}); err != nil {
		s.send(sp.client, protocol.NewError("", req.SpawnID, protocol.CodeNotRunning))
	}
}

// guestResize passes a resize to a session in a VM.
func (s *server) guestResize(sp *spawn, req *protocol.Request) {
	s.mu.Lock()
	l, guest := sp.link, sp.guest
	s.mu.Unlock()
	if err := l.ctl.Send(protocol.Request{V: protocol.Version, Type: protocol.TypeResize, SpawnID: guest, Rows: req.Rows, Cols: req.Cols}); err != nil {
		s.send(sp.client, protocol.NewError("", req.SpawnID, protocol.CodeInternal))
	}
}

// readGuest reads a session in a VM as its guest measures it, outside
// s.mu: its reading is the guest's, a subject under its VM's charge.
func (s *server) readGuest(sp *spawn, clock func() time.Time) {
	s.mu.Lock()
	l, place := sp.link, sp.guestPlace
	s.mu.Unlock()
	if l == nil || place == "" {
		return
	}
	answer, err := l.ask(protocol.Request{V: protocol.Version, Type: protocol.TypeMeasure, ID: randomHex(16), Place: place}, readEvery*3)
	if err != nil || answer.Type != "measured" {
		return
	}
	at := clock()
	s.mu.Lock()
	defer s.mu.Unlock()
	if p := sp.client.places[sp.place]; p != nil && p.spawn == sp {
		p.reading, p.readAt = protocol.Reading{Bytes: answer.Bytes, Lesser: answer.Lesser}, at
		s.ledger.Read(p.entry, answer.Bytes, answer.Lesser, at)
	}
}

// guestLink is one control connection to a VM's guest keeper: its lines
// read on one reader (read), each answer handed to the request that waits
// for it by its id, and each session's exit and release to that session.
type guestLink struct {
	s   *server
	m   *machine
	ctl guestControl
	mu  sync.Mutex
	// waiters wait for the answer naming their id; pending are spawns sent
	// whose answer will name the guest's spawn id; spawns are the
	// sessions by their spawn id in the guest.
	waiters map[string]chan []byte
	pending map[string]*spawn
	spawns  map[string]*spawn
	ended   chan struct{}
	endOnce sync.Once
	memory  *string
	// guestWait and endWait are the bounds the link was made under
	// (guestWait, vmEndWait).
	guestWait, endWait time.Duration
}

// guestAnswer is what the keeper reads of a guest's answer. Its code is a
// refusal's word or an exit's number, each the other's line's.
type guestAnswer struct {
	Type    string          `json:"type"`
	ID      string          `json:"id"`
	SpawnID string          `json:"spawn_id"`
	Raw     json.RawMessage `json:"code"`
	PID     int             `json:"pid"`
	State   string          `json:"state"`
	Bytes   uint64          `json:"bytes"`
	Lesser  bool            `json:"lesser"`
	// Code is a refusal's word, read from Raw.
	Code string `json:"-"`
}

// parseAnswer reads a guest's line.
func parseAnswer(line []byte) (guestAnswer, error) {
	var a guestAnswer
	if err := json.Unmarshal(line, &a); err != nil {
		return guestAnswer{}, err
	}
	if a.Type == "error" {
		_ = json.Unmarshal(a.Raw, &a.Code)
	}
	return a, nil
}

// ask sends req and waits within d for the answer naming its id.
func (l *guestLink) ask(req protocol.Request, d time.Duration) (guestAnswer, error) {
	ch := make(chan []byte, 1)
	l.mu.Lock()
	l.waiters[req.ID] = ch
	l.mu.Unlock()
	if err := l.ctl.Send(req); err != nil {
		l.unexpect(req.ID)
		return guestAnswer{}, err
	}
	return l.wait(ch, req.ID, d)
}

// expectSpawn waits for the answer to the spawn of id, sp's: whatever spawn
// id it names is sp's in the guest from the line's reading on.
func (l *guestLink) expectSpawn(id string, sp *spawn) chan []byte {
	ch := make(chan []byte, 1)
	l.mu.Lock()
	l.waiters[id] = ch
	l.pending[id] = sp
	l.mu.Unlock()
	return ch
}

func (l *guestLink) unexpect(id string) {
	l.mu.Lock()
	delete(l.waiters, id)
	delete(l.pending, id)
	l.mu.Unlock()
}

// wait waits within d for the answer on ch.
func (l *guestLink) wait(ch chan []byte, id string, d time.Duration) (guestAnswer, error) {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case line := <-ch:
		return parseAnswer(line)
	case <-l.ended:
		l.unexpect(id)
		return guestAnswer{}, errors.New("its control connection ended")
	case <-timer.C:
		l.unexpect(id)
		return guestAnswer{}, fmt.Errorf("no answer within %s", d)
	}
}

// read reads the guest keeper's lines until the connection ends, then ends
// the link: its sessions end with it.
func (l *guestLink) read() {
	for {
		line, err := l.ctl.Next(time.Time{})
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
				l.s.log.Warn("a person's VM's control connection: %v", err)
			}
			break
		}
		l.dispatch(line)
	}
	l.s.mu.Lock()
	if l.m.link == l {
		l.m.link = nil
	}
	l.s.mu.Unlock()
	// A connection that ends with its VMM is the VM's end, said by the
	// VMM's group's counters: the end is waited for briefly.
	var memory *string
	select {
	case <-l.m.vm.Done():
		memory = memoryOf(l.m.vm.KilledFor())
	case <-time.After(l.endWait):
	}
	l.end(memory)
}

// dispatch hands one guest line to the request or the session it names.
func (l *guestLink) dispatch(line []byte) {
	a, err := parseAnswer(line)
	if err != nil {
		return
	}
	l.mu.Lock()
	if sp := l.pending[a.ID]; sp != nil && a.ID != "" && a.SpawnID != "" {
		delete(l.pending, a.ID)
		l.spawns[a.SpawnID] = sp
		l.s.mu.Lock()
		sp.guest = a.SpawnID
		l.s.mu.Unlock()
	}
	ch := l.waiters[a.ID]
	if ch != nil && a.ID != "" {
		delete(l.waiters, a.ID)
		delete(l.pending, a.ID)
	}
	var sp *spawn
	if a.ID == "" && a.SpawnID != "" {
		sp = l.spawns[a.SpawnID]
		if a.Type == "released" {
			delete(l.spawns, a.SpawnID)
		}
	}
	l.mu.Unlock()
	switch {
	case ch != nil:
		ch <- line
	case sp != nil && (a.Type == "exited" || a.Type == "released"):
		select {
		case sp.guestEvents <- bytes.Clone(line):
		default:
		}
	}
}

// end ends the link once: every session on it is lost to its guest.
func (l *guestLink) end(memory *string) {
	l.endOnce.Do(func() {
		_ = l.ctl.Close()
		l.mu.Lock()
		sessions := make([]*spawn, 0, len(l.spawns)+len(l.pending))
		for _, sp := range l.spawns {
			sessions = append(sessions, sp)
		}
		for _, sp := range l.pending {
			sessions = append(sessions, sp)
		}
		l.mu.Unlock()
		close(l.ended)
		for _, sp := range sessions {
			sp.gone(memory)
		}
	})
}

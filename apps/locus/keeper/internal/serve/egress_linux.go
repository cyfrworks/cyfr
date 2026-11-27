// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/protocol"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// resolveTimeout bounds the resolution of one spawn's hosts.
const resolveTimeout = 10 * time.Second

// lookupHost answers a host's addresses; the resolver of the keeper's own
// namespace in production.
var lookupHost = func(ctx context.Context, host string) ([]netip.Addr, error) {
	return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
}

// resolveHosts answers the addresses a spawn's hosts name, at this moment
// and only now: every host must resolve to an address, and an address is
// taken unmapped and without a zone, once. It answers the code a spawn is
// refused with when it cannot.
func resolveHosts(hosts []string) ([]netip.Addr, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), resolveTimeout)
	defer cancel()
	var out []netip.Addr
	for _, host := range hosts {
		addrs, err := lookupHost(ctx, host)
		if err == nil && len(addrs) == 0 {
			err = errors.New("no address")
		}
		if err != nil {
			return nil, protocol.CodeHostsUnresolved, fmt.Errorf("host %s resolves to no address: %w", host, err)
		}
		for _, a := range addrs {
			out = append(out, a.Unmap().WithZone(""))
		}
	}
	slices.SortFunc(out, func(a, b netip.Addr) int { return a.Compare(b) })
	out = slices.Compact(out)
	if len(out) > guard.MaxAddresses {
		return nil, protocol.CodeBadRequest, fmt.Errorf("the hosts resolve to %d addresses, more than the guard admits (%d)", len(out), guard.MaxAddresses)
	}
	return out, "", nil
}

// routeGuard is the island's guard as the keeper speaks to it:
// *guard.Client in production.
type routeGuard interface {
	Admit(spawnID, reach string, addrs []netip.Addr, netns, udp, tcp *os.File) (guard.Route, error)
	AdmitRole(spawnID string, port uint16, private bool, netns, udp, tcp *os.File) (guard.Route, error)
	Clear(spawnID string, r guard.Route) error
	// Live reports whether r's connection is the live one at this instant,
	// with no end waiting unread on it.
	Live(r guard.Route) bool
}

// egress is what a routed spawn may reach, read from its request before it
// starts: the island's rule, or exactly its hosts' addresses.
type egress struct {
	listed bool
	addrs  []netip.Addr
}

// spawnEgress resolves a routed spawn's hosts, or answers the code it is
// refused with.
func (s *server) spawnEgress(req *protocol.Request) (egress, string, error) {
	if req.Hosts == nil {
		return egress{}, "", nil
	}
	addrs, code, err := resolveHosts(req.Hosts)
	if err != nil {
		return egress{}, code, err
	}
	return egress{listed: true, addrs: addrs}, "", nil
}

// admitSpawn has the guard make a routed spawn's route (admitRoute): the
// island's rule, or exactly its hosts' addresses.
func (s *server) admitSpawn(sp *spawn, route *os.File, e egress) (string, error) {
	reach := guard.ReachIsland
	if e.listed {
		reach = guard.ReachHosts
	}
	return s.admitRoute(route, &sp.route, sp.client, func(netns, udp, tcp *os.File) (guard.Route, error) {
		return s.guard.Admit(sp.id, reach, e.addrs, netns, udp, tcp)
	})
}

// admitRoute takes the descriptors a routed stage handed up on route (its
// network namespace and two name sockets) and has the guard make the
// space's route with them (admit). Only once the guard has said admitted,
// and its connection has not ended since, is the route the space's, held
// in held, and the stage told to go on: anything else refuses the space,
// and the stage, which waits for that word before it executes anything, is
// killed by its starter's failure path. A spawn's stage is told only while
// owner, its role's client, owns it (owns); a role's own start (owner nil)
// only while the keeper's end has not begun. Such a refusal holds the
// route admitted in held, for the failure path to withdraw.
func (s *server) admitRoute(route *os.File, held **guard.Route, owner *client, admit func(netns, udp, tcp *os.File) (guard.Route, error)) (string, error) {
	if err := route.SetReadDeadline(time.Now().Add(stageTimeout)); err != nil {
		return protocol.CodeInternal, fmt.Errorf("the stage's route socket: %w", err)
	}
	files, err := receiveRoute(route)
	if err != nil {
		return protocol.CodeExecFailed, fmt.Errorf("the stage's route descriptors: %w", err)
	}
	defer func() {
		for _, f := range files {
			_ = f.Close()
		}
	}()
	r, err := admit(files[0], files[1], files[2])
	if err != nil {
		return protocol.CodeGuardUnavailable, fmt.Errorf("its route was not made: %w", err)
	}
	// The admitted counts only while its connection is the live one at the
	// instant the command is released: both are decided under s.mu, which
	// the connection's end (guardLost) takes too, so either the end comes
	// first and the space is refused, or the route is recorded first and
	// the end kills the space.
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lostRoutes[r.Conn] || !s.guard.Live(r) {
		return protocol.CodeGuardUnavailable, errors.New("the guard's connection ended as its route was admitted")
	}
	*held = &r
	if owner != nil && !s.owns(owner) || owner == nil && s.closing.Load() {
		return protocol.CodeInternal, errNotOwned
	}
	if err := route.SetWriteDeadline(time.Now().Add(stageTimeout)); err != nil {
		return protocol.CodeInternal, fmt.Errorf("the stage's route socket: %w", err)
	}
	if _, err := route.Write([]byte{stage.RouteGo}); err != nil {
		return protocol.CodeExecFailed, fmt.Errorf("telling the stage its route is made: %w", err)
	}
	return "", nil
}

// receiveRoute reads the one message of a routed stage: its network
// namespace, its UDP and its TCP name socket.
func receiveRoute(route *os.File) ([]*os.File, error) {
	fds, err := stage.ReceiveDescriptors(route, guard.AdmitDescriptors)
	if err != nil {
		return nil, err
	}
	return []*os.File{os.NewFile(uintptr(fds[0]), "netns"), os.NewFile(uintptr(fds[1]), "names-udp"), os.NewFile(uintptr(fds[2]), "names-tcp")}, nil
}

// withdrawRoute has the guard withdraw a space's route, held in held under
// its id, once its processes are gone: a retiring spawn's, or an ended
// role process's. The route stays the keeper's until the guard says
// cleared, or its connection has ended (the guard's own rule withdraws
// every route made over it): one the guard refuses is asked again at each
// sweep (retryClears), and nothing counts it cleared before.
func (s *server) withdrawRoute(id string, held **guard.Route) {
	s.mu.Lock()
	r := *held
	gone := r != nil && s.lostRoutes[r.Conn]
	s.mu.Unlock()
	if r == nil {
		return
	}
	if !gone {
		if err := s.guard.Clear(id, *r); err != nil && !errors.Is(err, guard.ErrConnectionGone) {
			s.log.Warn("space %s: its route is not yet withdrawn, and is asked again: %v", id, err)
			s.mu.Lock()
			if s.uncleared == nil {
				s.uncleared = map[string]guard.Route{}
			}
			s.uncleared[id] = *r
			s.mu.Unlock()
			return
		}
	}
	s.mu.Lock()
	*held = nil
	s.mu.Unlock()
}

// retryClears asks the guard again for every route it has not yet said
// cleared, and forgets one only once it has, or once its connection ended.
func (s *server) retryClears() {
	s.mu.Lock()
	todo := make(map[string]guard.Route, len(s.uncleared))
	for id, r := range s.uncleared {
		todo[id] = r
	}
	s.mu.Unlock()
	for id, r := range todo {
		s.mu.Lock()
		gone := s.lostRoutes[r.Conn]
		s.mu.Unlock()
		if !gone {
			if err := s.guard.Clear(id, r); err != nil && !errors.Is(err, guard.ErrConnectionGone) {
				s.log.Warn("spawn %s: its route is still not withdrawn: %v", id, err)
				continue
			}
		}
		s.mu.Lock()
		delete(s.uncleared, id)
		s.mu.Unlock()
	}
}

// guardLost is the guard client's word that connection conn has ended: the
// guard withdraws every route made over it, or has lost them with its
// namespace, and every space routed over it is killed here, before the
// client may dial again, so none outlives the guard that held its route. A
// space whose admit was answered over conn and not yet recorded is refused
// at its recording (admitRoute). The spawns end as every killed spawn does:
// their leaders' exits retire them. A role process routed over conn ends
// the keeper, every role and spawn with it: the container starts again
// behind a guard, and no role runs while another guard is dialled.
func (s *server) guardLost(conn uint64) {
	s.mu.Lock()
	if s.lostRoutes == nil {
		s.lostRoutes = map[uint64]bool{}
	}
	s.lostRoutes[conn] = true
	var routed []*spawn
	for _, sp := range s.routing {
		if sp.route != nil && sp.route.Conn == conn {
			routed = append(routed, sp)
		}
	}
	// A role's start whose route is admitted counts as the role, from
	// before its command is released until it stands (publishRole).
	var roles []*role
	for _, r := range s.roles {
		for _, c := range []*client{r.client, r.starting} {
			if c != nil && c.route != nil && c.route.Conn == conn {
				roles = append(roles, r)
				break
			}
		}
	}
	// No role starts again from here, nor any spawn: the end is marked in
	// the critical section every start's last check takes (owns).
	if len(roles) > 0 {
		s.closing.Store(true)
	}
	s.mu.Unlock()
	if len(roles) > 0 {
		for _, r := range roles {
			if !r.leaf.KillBy(time.Now()) {
				s.log.Error("role %s: processes outlived its group's kill after the guard's connection ended", r.spec.Name)
				r.leaf.KillBy(time.Now())
				s.exitKeeper(ExitLost)
				return
			}
		}
		defer func() {
			s.log.Error("egress: the guard's connection %d ended under the routes of roles %s; the keeper ends", conn, roleNames(roles))
			s.end(ExitLost)
		}()
	}
	if len(routed) == 0 {
		return
	}
	// The group's kill (cgroup.kill, the deadline already passed) takes
	// every process of each space at once and answers, from the group's own
	// listing, whether the group is empty within its bound. Only when every
	// group is: the client dials again once this returns. A space that
	// outlives it ends the keeper, and the container starts again behind a
	// guard, so no routed space of a lost guard runs while another is
	// dialled.
	var wg sync.WaitGroup
	var survived atomic.Bool
	for _, sp := range routed {
		wg.Add(1)
		go func(sp *spawn) {
			defer wg.Done()
			s.signalChild(sp.leader, syscall.SIGKILL)
			if !s.killGroup(sp) {
				survived.Store(true)
				s.log.Error("spawn %s: processes outlived its group's kill after the guard's connection ended", sp.id)
			}
		}(sp)
	}
	wg.Wait()
	if survived.Load() {
		// What ends a space the keeper leaves behind is the kernel's own
		// group kill, written here as the keeper's last act: cgroup.kill
		// sends SIGKILL to every process of the group at once, and one the
		// kernel holds in an uninterruptible wait dies as it leaves it.
		// Inside a container the container's end then takes every process
		// too; on bare Linux nothing else would, so this kill is the end.
		for _, sp := range routed {
			if sp.group != nil {
				sp.group.KillBy(time.Now())
			}
		}
		s.log.Error("egress: a routed space of the guard's lost connection %d still ran; its group is killed and the keeper ends, so none runs while another guard is dialled", conn)
		s.exitKeeper(ExitLost)
		return
	}
	s.log.Warn("egress: the guard's connection %d ended; its %d routed spaces are killed", conn, len(routed))
}

// killGroup kills every process of sp's group at once and answers whether
// the group is empty, as its own listing says, within the kill's bound.
func (s *server) killGroup(sp *spawn) bool {
	if s.groupKilled != nil {
		return s.groupKilled(sp)
	}
	if sp.group == nil {
		return true
	}
	if sp.group.KillBy(time.Now()) {
		return true
	}
	// A group its retirement removed meanwhile holds nothing: its removal
	// waited for its last process.
	_, err := sp.group.Procs()
	return errors.Is(err, os.ErrNotExist)
}

// exitKeeper ends the keeper with code.
func (s *server) exitKeeper(code int) {
	if s.exit != nil {
		s.exit(code)
		return
	}
	os.Exit(code)
}

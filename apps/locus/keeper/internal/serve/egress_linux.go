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
	"syscall"
	"time"

	"golang.org/x/sys/unix"

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
	Clear(spawnID string, r guard.Route) error
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

// admitRoute takes the descriptors a routed stage handed up on route (its
// network namespace and two name sockets) and has the guard make the
// space's route with them. Only once the guard has said admitted, and its
// connection has not ended since, is the route the spawn's and the stage
// told to go on: anything else refuses the spawn, and the stage, which
// waits for that word before it executes anything, is killed by the
// launch's failure path.
func (s *server) admitRoute(sp *spawn, route *os.File, e egress) (string, error) {
	_ = route.SetReadDeadline(time.Now().Add(stageTimeout))
	files, err := receiveRoute(route)
	if err != nil {
		return protocol.CodeExecFailed, fmt.Errorf("the stage's route descriptors: %w", err)
	}
	defer func() {
		for _, f := range files {
			_ = f.Close()
		}
	}()
	reach := guard.ReachIsland
	if e.listed {
		reach = guard.ReachHosts
	}
	r, err := s.guard.Admit(sp.id, reach, e.addrs, files[0], files[1], files[2])
	if err != nil {
		return protocol.CodeGuardUnavailable, fmt.Errorf("its route was not made: %w", err)
	}
	s.mu.Lock()
	lost := s.lostRoutes[r.Conn]
	if !lost {
		sp.route = &r
	}
	s.mu.Unlock()
	if lost {
		return protocol.CodeGuardUnavailable, errors.New("the guard's connection ended as its route was admitted")
	}
	_ = route.SetWriteDeadline(time.Now().Add(stageTimeout))
	if _, err := route.Write([]byte{stage.RouteGo}); err != nil {
		return protocol.CodeExecFailed, fmt.Errorf("telling the stage its route is made: %w", err)
	}
	return "", nil
}

// receiveRoute reads the one message of a routed stage: its network
// namespace, its UDP and its TCP name socket.
func receiveRoute(route *os.File) ([]*os.File, error) {
	conn, err := route.SyscallConn()
	if err != nil {
		return nil, err
	}
	buf := make([]byte, 1)
	oob := make([]byte, unix.CmsgSpace(4*guard.AdmitDescriptors))
	var n, oobn int
	var rerr error
	err = conn.Read(func(fd uintptr) bool {
		n, oobn, _, _, rerr = unix.Recvmsg(int(fd), buf, oob, unix.MSG_CMSG_CLOEXEC)
		return !errors.Is(rerr, unix.EAGAIN)
	})
	if err == nil {
		err = rerr
	}
	if err != nil {
		return nil, err
	}
	var fds []int
	if oobn > 0 {
		msgs, perr := unix.ParseSocketControlMessage(oob[:oobn])
		if perr != nil {
			return nil, perr
		}
		for i := range msgs {
			if got, perr := unix.ParseUnixRights(&msgs[i]); perr == nil {
				fds = append(fds, got...)
			}
		}
	}
	if n != 1 || len(fds) != guard.AdmitDescriptors {
		for _, fd := range fds {
			_ = unix.Close(fd)
		}
		return nil, fmt.Errorf("a message of %d bytes and %d descriptors, not 1 and %d", n, len(fds), guard.AdmitDescriptors)
	}
	return []*os.File{os.NewFile(uintptr(fds[0]), "netns"), os.NewFile(uintptr(fds[1]), "names-udp"), os.NewFile(uintptr(fds[2]), "names-tcp")}, nil
}

// withdrawRoute has the guard withdraw a retiring spawn's route once its
// processes are gone, and answers once the guard has said cleared, the
// route's connection has ended (and with it the route, by the guard's own
// rule), or the clear failed, which is logged: a route of a space with no
// process left carries nothing, and the guard withdraws it at the
// connection's end.
func (s *server) withdrawRoute(sp *spawn) {
	s.mu.Lock()
	r := sp.route
	sp.route = nil
	gone := r != nil && s.lostRoutes[r.Conn]
	s.mu.Unlock()
	// A route of a connection that ended went with it: nothing is asked.
	if r == nil || gone {
		return
	}
	switch err := s.guard.Clear(sp.id, *r); {
	case err == nil, errors.Is(err, guard.ErrConnectionGone):
	default:
		s.log.Warn("spawn %s: withdrawing its route: %v", sp.id, err)
	}
}

// guardLost is the guard client's word that connection conn has ended: the
// guard withdraws every route made over it, or has lost them with its
// namespace, and every space routed over it is killed here, before the
// client may dial again, so none outlives the guard that held its route. A
// spawn whose admit was answered over conn and not yet recorded is refused
// at its recording (admitRoute). The spawns end as every killed spawn does:
// their leaders' exits retire them.
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
	s.mu.Unlock()
	if len(routed) == 0 {
		return
	}
	// The group's kill (cgroup.kill, the deadline already passed) takes
	// every process of each space at once and waits until its group is
	// empty; the leader's own kill covers a space whose group could not be
	// made, which never started anything.
	var wg sync.WaitGroup
	for _, sp := range routed {
		wg.Add(1)
		go func(sp *spawn) {
			defer wg.Done()
			s.signalChild(sp.leader, syscall.SIGKILL)
			if sp.group != nil && !sp.group.KillBy(time.Now()) {
				s.log.Error("spawn %s: processes outlived its group's kill after the guard's connection ended", sp.id)
			}
		}(sp)
	}
	wg.Wait()
	s.log.Warn("egress: the guard's connection %d ended; its %d routed spaces are killed", conn, len(routed))
}

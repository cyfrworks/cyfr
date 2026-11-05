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
	"slices"
	"time"

	"github.com/cyfr/locus/keeper/guard"
	"github.com/cyfr/locus/keeper/internal/protocol"
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

// egressGuard is the island's egress guard as the keeper speaks to it:
// *guard.Client in production.
type egressGuard interface {
	Admit(uid int, addrs []netip.Addr) error
	Clear(uid int) error
}

// egress is what a spawn may reach, read from its request before it
// starts: whether it names hosts, and their addresses.
type egress struct {
	listed bool
	addrs  []netip.Addr
}

// spawnEgress resolves a spawn's hosts, or answers the code it is refused
// with: a spawn naming hosts needs the island's guard.
func (s *server) spawnEgress(req *protocol.Request) (egress, string, error) {
	if req.Hosts == nil {
		return egress{}, "", nil
	}
	if s.guard == nil {
		return egress{}, protocol.CodeGuardUnavailable, errors.New("it names hosts, and this keeper has no --guard")
	}
	addrs, code, err := resolveHosts(req.Hosts)
	if err != nil {
		return egress{}, code, err
	}
	return egress{listed: true, addrs: addrs}, "", nil
}

// setEgress has the guard hold uid to what the spawn may reach before its
// command starts: exactly the addresses its hosts resolved to, or the
// island's rule. A keeper without a guard sets nothing; its spawns name no
// hosts (spawnEgress).
func (s *server) setEgress(uid int, e egress) error {
	if s.guard == nil {
		return nil
	}
	if e.listed {
		return s.guard.Admit(uid, e.addrs)
	}
	return s.guard.Clear(uid)
}

// clearEgress returns a retired uid to the island's rule, once no process
// of it remains and before another spawn may take it. A clear that fails is
// logged: the uid's next spawn sets its rules again before it starts.
func (s *server) clearEgress(uid int) {
	if s.guard == nil {
		return
	}
	if err := s.guard.Clear(uid); err != nil {
		s.log.Warn("uid %d: clearing its egress at the guard: %v", uid, err)
	}
}

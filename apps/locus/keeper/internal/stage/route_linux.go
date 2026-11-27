// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"encoding/binary"
	"errors"
	"fmt"
	"syscall"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/pool"
)

// A routed space's part of its route. The stage brings the space's loopback
// up and binds the two name sockets at 127.0.0.11:53 there, while it still
// holds NET_ADMIN and NET_BIND_SERVICE in its own namespace; the guard,
// which is handed them, answers the space's names on them and sets the
// route's inner end through the UDP one (package guard). The command never
// holds either, nor the namespace's descriptor: only the guard does.

// RouteGo is the one byte the keeper writes on RouteFD once the guard has
// admitted the space's route.
const RouteGo = 'g'

// addrGenModeNone is IN6_ADDR_GEN_MODE_NONE: the kernel makes no IPv6
// address on the link.
const addrGenModeNone = 1

// spaceNames is where a space's name sockets are bound: its own 127.0.0.11.
var spaceNames = [4]byte{127, 0, 0, 11}

// nameSockets brings the namespace's loopback up and binds a UDP and a
// listening TCP socket at names:53: a space's at its own 127.0.0.11, a
// person's machine's at pool.MachineNames, which no link of the space
// holds until the guard's bridge does, so bound free of it.
func nameSockets(names [4]byte) (udp, tcp int, err error) {
	ctl, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, -1, err
	}
	defer unix.Close(ctl)
	ifr, err := unix.NewIfreq("lo")
	if err != nil {
		return -1, -1, err
	}
	if err := unix.IoctlIfreq(ctl, unix.SIOCGIFFLAGS, ifr); err != nil {
		return -1, -1, fmt.Errorf("the loopback's flags: %w", err)
	}
	ifr.SetUint16(ifr.Uint16() | unix.IFF_UP)
	if err := unix.IoctlIfreq(ctl, unix.SIOCSIFFLAGS, ifr); err != nil {
		return -1, -1, fmt.Errorf("bringing the loopback up: %w", err)
	}
	at := &unix.SockaddrInet4{Port: 53, Addr: names}
	free := func(fd int) error {
		if names == spaceNames {
			return nil
		}
		return unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_FREEBIND, 1)
	}
	udp, err = unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err == nil {
		err = free(udp)
	}
	if err == nil {
		err = unix.Bind(udp, at)
	}
	if err != nil {
		if udp >= 0 {
			_ = unix.Close(udp)
		}
		return -1, -1, fmt.Errorf("the UDP name socket: %w", err)
	}
	tcp, err = unix.Socket(unix.AF_INET, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err == nil {
		err = free(tcp)
	}
	if err == nil {
		err = unix.Bind(tcp, at)
	}
	if err == nil {
		err = unix.Listen(tcp, 16)
	}
	if err != nil {
		_ = unix.Close(udp)
		if tcp >= 0 {
			_ = unix.Close(tcp)
		}
		return -1, -1, fmt.Errorf("the TCP name socket: %w", err)
	}
	return udp, tcp, nil
}

// handRouteUp makes the name sockets and hands them, after the space's
// network namespace, to the keeper over fd, closing its own copies, then
// waits for the keeper's RouteGo; anything else, or the socket's end,
// refuses the spawn.
func handRouteUp(fd int, names [4]byte) error {
	if err := checkSocket(fd); err != nil {
		return err
	}
	netns, err := unix.Open("/proc/thread-self/ns/net", unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("the space's network namespace: %w", err)
	}
	udp, tcp, err := nameSockets(names)
	if err != nil {
		_ = unix.Close(netns)
		return err
	}
	err = unix.Sendmsg(fd, []byte{'r'}, unix.UnixRights(netns, udp, tcp), nil, 0)
	_ = unix.Close(netns)
	_ = unix.Close(udp)
	_ = unix.Close(tcp)
	if err != nil {
		return fmt.Errorf("handing the route's descriptors up: %w", err)
	}
	var word [1]byte
	for {
		n, err := unix.Read(fd, word[:])
		if errors.Is(err, unix.EINTR) {
			continue
		}
		_ = unix.Close(fd)
		switch {
		case err != nil:
			return err
		case n != 1 || word[0] != RouteGo:
			return errors.New("the keeper did not confirm the route")
		}
		return stillLinks()
	}
}

// stillLinks makes the space's network still before its command starts.
// The guard's inner end, the one link that comes up in the space
// (pool.RouteLink), comes up with an IPv6 link-local address whose
// duplicate address detection ends a second or two later, and the address
// changing then is a change of the namespace's network under a command
// already running: Chrome, for one, fails its requests in flight with
// net::ERR_NETWORK_CHANGED. A space has no IPv6 route out, so that link is
// given no IPv6 address at all: the kernel generates none on it, and the
// one it made is removed now, while the stage still holds NET_ADMIN,
// before the command runs. A space whose guard made no pair, as the
// keeper's tests' stand-in guard makes none, has no such link to still.
func stillLinks() error {
	index, err := linkIndex(pool.RouteLink)
	if errors.Is(err, unix.ENODEV) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("the route's link: %w", err)
	}
	body := make([]byte, unix.SizeofIfInfomsg)
	binary.NativeEndian.PutUint32(body[4:8], index)
	mode := attr(unix.IFLA_INET6_ADDR_GEN_MODE, []byte{addrGenModeNone})
	body = append(body, attr(unix.IFLA_AF_SPEC, attr(unix.AF_INET6, mode))...)
	if err := request(unix.RTM_SETLINK, body); err != nil {
		return fmt.Errorf("the route's link's IPv6 addresses: %w", err)
	}
	addrs, err := syscall.NetlinkRIB(unix.RTM_GETADDR, unix.AF_INET6)
	if err != nil {
		return fmt.Errorf("the route's link's addresses: %w", err)
	}
	msgs, err := syscall.ParseNetlinkMessage(addrs)
	if err != nil {
		return fmt.Errorf("the route's link's addresses: %w", err)
	}
	for _, m := range msgs {
		if m.Header.Type != unix.RTM_NEWADDR || len(m.Data) < unix.SizeofIfAddrmsg || m.Data[0] != unix.AF_INET6 ||
			binary.NativeEndian.Uint32(m.Data[4:8]) != index {
			continue
		}
		attrs, err := syscall.ParseNetlinkRouteAttr(&m)
		if err != nil {
			return fmt.Errorf("the route's link's addresses: %w", err)
		}
		body := append([]byte(nil), m.Data[:unix.SizeofIfAddrmsg]...)
		for _, a := range attrs {
			if a.Attr.Type == unix.IFA_ADDRESS {
				body = append(body, attr(unix.IFA_ADDRESS, a.Value)...)
			}
		}
		if err := request(unix.RTM_DELADDR, body); err != nil && !errors.Is(err, unix.EADDRNOTAVAIL) {
			return fmt.Errorf("an IPv6 address of the route's link: %w", err)
		}
	}
	return nil
}

// linkIndex is the index of the link named name in the space.
func linkIndex(name string) (uint32, error) {
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return 0, err
	}
	defer unix.Close(fd)
	ifr, err := unix.NewIfreq(name)
	if err != nil {
		return 0, err
	}
	if err := unix.IoctlIfreq(fd, unix.SIOCGIFINDEX, ifr); err != nil {
		return 0, err
	}
	return ifr.Uint32(), nil
}

// attr is one netlink attribute of kind holding data, padded to its
// alignment.
func attr(kind uint16, data []byte) []byte {
	size := unix.SizeofRtAttr + len(data)
	b := make([]byte, (size+unix.RTA_ALIGNTO-1) & ^(unix.RTA_ALIGNTO-1))
	binary.NativeEndian.PutUint16(b[0:2], uint16(size))
	binary.NativeEndian.PutUint16(b[2:4], kind)
	copy(b[unix.SizeofRtAttr:], data)
	return b
}

// request sends one route netlink request in the space's namespace and
// reads its acknowledgement.
func request(kind uint16, body []byte) error {
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_ROUTE)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	msg := make([]byte, unix.SizeofNlMsghdr, unix.SizeofNlMsghdr+len(body))
	msg = append(msg, body...)
	binary.NativeEndian.PutUint32(msg[0:4], uint32(len(msg)))
	binary.NativeEndian.PutUint16(msg[4:6], kind)
	binary.NativeEndian.PutUint16(msg[6:8], unix.NLM_F_REQUEST|unix.NLM_F_ACK)
	binary.NativeEndian.PutUint32(msg[8:12], 1)
	if err := unix.Sendto(fd, msg, 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return err
	}
	buf := make([]byte, 8192)
	for {
		n, _, err := unix.Recvfrom(fd, buf, 0)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			return err
		}
		replies, err := syscall.ParseNetlinkMessage(buf[:n])
		if err != nil {
			return err
		}
		for _, r := range replies {
			if r.Header.Type == unix.NLMSG_ERROR && len(r.Data) >= 4 {
				if code := int32(binary.NativeEndian.Uint32(r.Data[0:4])); code != 0 {
					return unix.Errno(-code)
				}
				return nil
			}
		}
	}
}

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package stage

import (
	"errors"
	"fmt"

	"golang.org/x/sys/unix"
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

// nameSockets brings the namespace's loopback up and binds a UDP and a
// listening TCP socket at 127.0.0.11:53.
func nameSockets() (udp, tcp int, err error) {
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
	at := &unix.SockaddrInet4{Port: 53, Addr: [4]byte{127, 0, 0, 11}}
	udp, err = unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
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
func handRouteUp(fd int) error {
	if err := checkSocket(fd); err != nil {
		return err
	}
	netns, err := unix.Open("/proc/thread-self/ns/net", unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("the space's network namespace: %w", err)
	}
	udp, tcp, err := nameSockets()
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
		return nil
	}
}

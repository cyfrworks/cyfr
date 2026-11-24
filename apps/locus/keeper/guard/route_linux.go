// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"strconv"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

// What a route is made of, with the capability the guard holds, NET_ADMIN
// in its own namespace and nothing else. It cannot enter a space's
// namespace (that asks SYS_ADMIN) and needs not: the pair is made by
// netlink with its inner end placed by the namespace's descriptor, and
// that end's address, link and default route are set by ioctl on the
// space's own UDP name socket, which belongs to the space's namespace.
// NET_ADMIN of the guard's namespace reaches a space's, whose user
// namespace descends from the guard's own.

const (
	// innerName is the inner end's name, in a namespace that holds only
	// its loopback (and, on Docker Desktop, fallback tunnel devices, down
	// and without an address) when the pair is made.
	innerName = "eth0"
	// vethInfoPeer is VETH_INFO_PEER, the veth peer's attributes.
	vethInfoPeer = 1
	// nsGetNstype is NS_GET_NSTYPE, which answers a namespace
	// descriptor's kind.
	nsGetNstype = 0xb703
)

// outerName is the guard's end of the route in slot.
func outerName(slot int) string { return "sp" + strconv.Itoa(slot) }

// slotAddresses are the guard's end and the space's end of slot's /30 in
// the range rng.
func slotAddresses(rng netip.Prefix, slot int) (gateway, inner netip.Addr) {
	base := binary.BigEndian.Uint32(rng.Addr().AsSlice()) + uint32(slot)*4
	var g, i [4]byte
	binary.BigEndian.PutUint32(g[:], base+1)
	binary.BigEndian.PutUint32(i[:], base+2)
	return netip.AddrFrom4(g), netip.AddrFrom4(i)
}

// slots is how many /30 routes a /16 holds.
const slots = 1 << 14

// rtattr appends one netlink attribute.
func rtattr(b []byte, kind uint16, data []byte) []byte {
	n := unix.SizeofRtAttr + len(data)
	var h [unix.SizeofRtAttr]byte
	binary.NativeEndian.PutUint16(h[0:2], uint16(n))
	binary.NativeEndian.PutUint16(h[2:4], kind)
	b = append(b, h[:]...)
	b = append(b, data...)
	for len(b)%unix.NLMSG_ALIGNTO != 0 {
		b = append(b, 0)
	}
	return b
}

func cstring(s string) []byte { return append([]byte(s), 0) }

func ifinfomsg() []byte { return make([]byte, unix.SizeofIfInfomsg) }

// netlinkDo sends one request on a route netlink socket of the guard's
// namespace and reads its acknowledgement.
func netlinkDo(kind uint16, flags uint16, body []byte) error {
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_ROUTE)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	if err := unix.Bind(fd, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return err
	}
	msg := make([]byte, unix.SizeofNlMsghdr, unix.SizeofNlMsghdr+len(body))
	msg = append(msg, body...)
	binary.NativeEndian.PutUint32(msg[0:4], uint32(len(msg)))
	binary.NativeEndian.PutUint16(msg[4:6], kind)
	binary.NativeEndian.PutUint16(msg[6:8], unix.NLM_F_REQUEST|unix.NLM_F_ACK|flags)
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
		msgs, err := syscall.ParseNetlinkMessage(buf[:n])
		if err != nil {
			return err
		}
		for _, m := range msgs {
			if m.Header.Type != syscall.NLMSG_ERROR || len(m.Data) < 4 {
				continue
			}
			if code := int32(binary.NativeEndian.Uint32(m.Data[0:4])); code != 0 {
				return unix.Errno(-code)
			}
			return nil
		}
	}
}

// makePair makes the veth pair of slot: its guard's end in this namespace,
// its inner end in the namespace netns names.
func makePair(slot int, netns *os.File) error {
	var nsfd [4]byte
	binary.NativeEndian.PutUint32(nsfd[:], uint32(netns.Fd()))
	peer := ifinfomsg()
	peer = rtattr(peer, unix.IFLA_IFNAME, cstring(innerName))
	peer = rtattr(peer, unix.IFLA_NET_NS_FD, nsfd[:])
	data := rtattr(nil, vethInfoPeer, peer)
	info := rtattr(nil, unix.IFLA_INFO_KIND, cstring("veth"))
	info = rtattr(info, unix.IFLA_INFO_DATA, data)
	body := ifinfomsg()
	body = rtattr(body, unix.IFLA_IFNAME, cstring(outerName(slot)))
	body = rtattr(body, unix.IFLA_LINKINFO, info)
	if err := netlinkDo(unix.RTM_NEWLINK, unix.NLM_F_CREATE|unix.NLM_F_EXCL, body); err != nil {
		return fmt.Errorf("making the pair %s: %w", outerName(slot), err)
	}
	return nil
}

// removePair removes slot's pair, both ends at once. A pair already gone,
// as when the space's namespace ended, is removed.
func removePair(slot int) error {
	body := rtattr(ifinfomsg(), unix.IFLA_IFNAME, cstring(outerName(slot)))
	err := netlinkDo(unix.RTM_DELLINK, 0, body)
	if errors.Is(err, unix.ENODEV) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("removing the pair %s: %w", outerName(slot), err)
	}
	return nil
}

// setLink gives the link name, in the namespace fd's socket belongs to,
// address a in a /30, and brings it up.
func setLink(fd int, name string, a netip.Addr) error {
	for _, set := range []struct {
		req  uint
		addr netip.Addr
	}{{unix.SIOCSIFADDR, a}, {unix.SIOCSIFNETMASK, netip.AddrFrom4([4]byte{255, 255, 255, 252})}} {
		ifr, err := unix.NewIfreq(name)
		if err != nil {
			return err
		}
		v4 := set.addr.As4()
		if err := ifr.SetInet4Addr(v4[:]); err != nil {
			return err
		}
		if err := unix.IoctlIfreq(fd, set.req, ifr); err != nil {
			return fmt.Errorf("%s of %s: %w", map[uint]string{unix.SIOCSIFADDR: "the address", unix.SIOCSIFNETMASK: "the mask"}[set.req], name, err)
		}
	}
	ifr, err := unix.NewIfreq(name)
	if err != nil {
		return err
	}
	if err := unix.IoctlIfreq(fd, unix.SIOCGIFFLAGS, ifr); err != nil {
		return fmt.Errorf("the flags of %s: %w", name, err)
	}
	ifr.SetUint16(ifr.Uint16() | unix.IFF_UP)
	if err := unix.IoctlIfreq(fd, unix.SIOCSIFFLAGS, ifr); err != nil {
		return fmt.Errorf("bringing %s up: %w", name, err)
	}
	return nil
}

// rtentry is struct rtentry of a 64-bit kernel, as SIOCADDRT takes it.
type rtentry struct {
	pad1    uint64
	dst     unix.RawSockaddrInet4
	gateway unix.RawSockaddrInet4
	genmask unix.RawSockaddrInet4
	flags   uint16
	pad2    int16
	pad3    uint64
	tos     uint8
	class   uint8
	pad4    [3]int16
	metric  int16
	dev     uintptr
	mtu     uint64
	window  uint64
	irtt    uint16
}

// defaultRoute sets the default route, through gateway, of the namespace
// fd's socket belongs to.
func defaultRoute(fd int, gateway netip.Addr) error {
	if unsafe.Sizeof(uintptr(0)) != 8 {
		return errors.New("a route is set by ioctl on a 64-bit kernel only")
	}
	var rt rtentry
	rt.dst.Family = unix.AF_INET
	rt.genmask.Family = unix.AF_INET
	rt.gateway.Family = unix.AF_INET
	rt.gateway.Addr = gateway.As4()
	rt.flags = unix.RTF_UP | unix.RTF_GATEWAY
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), unix.SIOCADDRT, uintptr(unsafe.Pointer(&rt))); errno != 0 {
		return fmt.Errorf("the default route: %w", errno)
	}
	return nil
}

// nsInode is the inode of the namespace descriptor fd names.
func nsInode(fd int) (uint64, error) {
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		return 0, err
	}
	return st.Ino, nil
}

// checkDescriptors holds an admit's three descriptors to what they must
// be: a network namespace other than the guard's own, and a UDP and a
// listening TCP socket of that namespace, each bound to 127.0.0.11:53.
func checkDescriptors(netns, udp, tcp *os.File) error {
	kind, err := unix.IoctlRetInt(int(netns.Fd()), nsGetNstype)
	if err != nil || kind != unix.CLONE_NEWNET {
		return errors.New("the first descriptor is not a network namespace")
	}
	space, err := nsInode(int(netns.Fd()))
	if err != nil {
		return err
	}
	var own unix.Stat_t
	if err := unix.Stat("/proc/self/ns/net", &own); err != nil {
		return err
	}
	if own.Ino == space {
		return errors.New("the namespace is the guard's own")
	}
	for _, s := range []struct {
		name string
		f    *os.File
		kind int
	}{{"the UDP name socket", udp, unix.SOCK_DGRAM}, {"the TCP name socket", tcp, unix.SOCK_STREAM}} {
		fd := int(s.f.Fd())
		domain, derr := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_DOMAIN)
		typ, terr := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_TYPE)
		if derr != nil || terr != nil || domain != unix.AF_INET || typ != s.kind {
			return fmt.Errorf("%s is not one", s.name)
		}
		if s.kind == unix.SOCK_STREAM {
			if on, err := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_ACCEPTCONN); err != nil || on != 1 {
				return fmt.Errorf("%s is not listening", s.name)
			}
		}
		sa, err := unix.Getsockname(fd)
		in, ok := sa.(*unix.SockaddrInet4)
		if err != nil || !ok || in.Port != 53 || in.Addr != [4]byte{127, 0, 0, 11} {
			return fmt.Errorf("%s is not bound to 127.0.0.11:53", s.name)
		}
		nsfd, err := unix.IoctlRetInt(fd, unix.SIOCGSKNS)
		if err != nil {
			return fmt.Errorf("%s's namespace: %w", s.name, err)
		}
		ino, err := nsInode(nsfd)
		_ = unix.Close(nsfd)
		if err != nil || ino != space {
			return fmt.Errorf("%s is not of the space's namespace", s.name)
		}
	}
	return nil
}

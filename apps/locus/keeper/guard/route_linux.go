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
	"runtime"
	"strconv"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/pool"
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
	// innerName is the inner end's name (pool.RouteLink).
	innerName = pool.RouteLink
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
	fd, err := nlSocket(unix.NETLINK_ROUTE)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
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
	return setAddress(fd, name, a, netip.AddrFrom4([4]byte{255, 255, 255, 252}))
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

// spaceNames is where a space's two name sockets are bound: its own
// 127.0.0.11, port 53.
var spaceNames = netip.AddrFrom4([4]byte{127, 0, 0, 11})

// checkDescriptors holds an admit's three descriptors to what they must
// be: a network namespace other than the guard's own, and a UDP and a
// listening TCP socket of that namespace, each bound to names port 53:
// spaceNames for a space's, MachineNames for a machine's.
func checkDescriptors(netns, udp, tcp *os.File, names netip.Addr) error {
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
		if err != nil || !ok || in.Port != 53 || in.Addr != names.As4() {
			return fmt.Errorf("%s is not bound to %s:53", s.name, names)
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

// The kernel's connection table (conntrack, through ctnetlink): a withdrawn
// route leaves no entry of its space's address behind, one its space opened
// or one forwarded into it, so no later route that takes the address finds
// a connection of the earlier one's.
const (
	nfnlSubsysCtnetlink = 1
	ctnlMsgGet          = 1
	ctnlMsgDelete       = 2
	ctaTupleOrig        = 1
	ctaTupleReply       = 2
	ctaTupleIP          = 1
	ctaIPv4Src          = 1
	ctaZone             = 18
	nlaTypeMask         = 0x3fff
)

// attrs splits a run of netlink attributes into (type, whole attribute,
// payload) triples.
func attrs(b []byte) [][3][]byte {
	var out [][3][]byte
	for len(b) >= unix.SizeofRtAttr {
		n := int(binary.NativeEndian.Uint16(b[0:2]))
		if n < unix.SizeofRtAttr || n > len(b) {
			break
		}
		kind := make([]byte, 2)
		binary.NativeEndian.PutUint16(kind, binary.NativeEndian.Uint16(b[2:4])&nlaTypeMask)
		out = append(out, [3][]byte{kind, b[:n], b[unix.SizeofRtAttr:n]})
		aligned := (n + unix.NLMSG_ALIGNTO - 1) &^ (unix.NLMSG_ALIGNTO - 1)
		if aligned > len(b) {
			break
		}
		b = b[aligned:]
	}
	return out
}

func attrType(a [3][]byte) uint16 { return binary.NativeEndian.Uint16(a[0]) }

// netlinkTimeout bounds every read of a netlink answer: a step the guard
// takes under its lock never waits longer for the kernel.
var netlinkTimeout = 5 * time.Second

// nlSocket opens a netlink socket of protocol proto in the guard's
// namespace, bound, its every read bounded by netlinkTimeout.
func nlSocket(proto int) (int, error) {
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, proto)
	if err != nil {
		return -1, err
	}
	tv := unix.NsecToTimeval(netlinkTimeout.Nanoseconds())
	if err := unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &tv); err != nil {
		unix.Close(fd)
		return -1, err
	}
	if err := unix.Bind(fd, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		unix.Close(fd)
		return -1, err
	}
	return fd, nil
}

// ctnetlink opens a netfilter netlink socket of the guard's namespace.
func ctnetlink() (int, error) { return nlSocket(unix.NETLINK_NETFILTER) }

// errDumpInterrupted is a dump the kernel says changed while it was read
// (NLM_F_DUMP_INTR): it proves nothing and is read again.
var errDumpInterrupted = errors.New("the connection table changed while it was read")

// ctMessage is one ctnetlink request of the given message type.
func ctMessage(msg uint16, flags uint16, seq uint32, body []byte) []byte {
	out := make([]byte, unix.SizeofNlMsghdr+4, unix.SizeofNlMsghdr+4+len(body))
	out = append(out, body...)
	binary.NativeEndian.PutUint32(out[0:4], uint32(len(out)))
	binary.NativeEndian.PutUint16(out[4:6], nfnlSubsysCtnetlink<<8|msg)
	binary.NativeEndian.PutUint16(out[6:8], unix.NLM_F_REQUEST|flags)
	binary.NativeEndian.PutUint32(out[8:12], seq)
	out[16] = unix.AF_INET
	return out
}

// conntrackOf answers the entries of the IPv4 connection table addr is a
// party to, as the source of the original tuple or of the reply's, each as the attributes a delete names it by:
// its original tuple and, where it has one, its zone.
func conntrackOf(addr netip.Addr) ([][]byte, error) {
	fd, err := ctnetlink()
	if err != nil {
		return nil, err
	}
	defer unix.Close(fd)
	if err := unix.Sendto(fd, ctMessage(ctnlMsgGet, unix.NLM_F_DUMP, 1, nil), 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return nil, err
	}
	buf := make([]byte, 1<<16)
	var found [][]byte
	interrupted := false
	for {
		n, _, err := unix.Recvfrom(fd, buf, 0)
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if err != nil {
			// A read that times out or fails before the dump's end is a
			// short dump, no answer.
			return nil, fmt.Errorf("the dump ended short: %w", err)
		}
		msgs, err := syscall.ParseNetlinkMessage(buf[:n])
		if err != nil {
			return nil, err
		}
		entries, done, intr, err := parseDump(msgs, addr)
		if err != nil {
			return nil, err
		}
		found = append(found, entries...)
		interrupted = interrupted || intr
		if done {
			if interrupted {
				return nil, errDumpInterrupted
			}
			return found, nil
		}
	}
}

// parseDump reads one batch of a connection-table dump: the entries whose
// original source or reply source is addr (a connection forwarded into a
// space has the space's address as the reply's source alone), whether the batch ends the dump, and whether any
// of its messages says the dump was interrupted.
func parseDump(msgs []syscall.NetlinkMessage, addr netip.Addr) (found [][]byte, done, interrupted bool, err error) {
	want := addr.As4()
	for _, m := range msgs {
		if m.Header.Flags&unix.NLM_F_DUMP_INTR != 0 {
			interrupted = true
		}
		switch m.Header.Type {
		case syscall.NLMSG_DONE:
			return found, true, interrupted, nil
		case syscall.NLMSG_ERROR:
			if len(m.Data) >= 4 {
				if code := int32(binary.NativeEndian.Uint32(m.Data[0:4])); code != 0 {
					return nil, false, interrupted, unix.Errno(-code)
				}
			}
			return found, true, interrupted, nil
		}
		if len(m.Data) < 4 {
			continue
		}
		var orig, zone []byte
		party := false
		for _, a := range attrs(m.Data[4:]) {
			switch attrType(a) {
			case ctaTupleOrig, ctaTupleReply:
				if attrType(a) == ctaTupleOrig {
					orig = a[1]
				}
				for _, t := range attrs(a[2]) {
					if attrType(t) != ctaTupleIP {
						continue
					}
					for _, ip := range attrs(t[2]) {
						if attrType(ip) == ctaIPv4Src && len(ip[2]) == 4 && [4]byte(ip[2]) == want {
							party = true
						}
					}
				}
			case ctaZone:
				zone = a[1]
			}
		}
		if orig != nil && party {
			entry := append(append([]byte(nil), orig...), make([]byte, (4-len(orig)%4)%4)...)
			if zone != nil {
				entry = append(entry, zone...)
				entry = append(entry, make([]byte, (4-len(zone)%4)%4)...)
			}
			found = append(found, entry)
		}
	}
	return found, false, interrupted, nil
}

// forgetConnections removes from the connection table every entry addr is
// a party to (conntrackOf), addr the address of a route being withdrawn. An entry
// already gone is removed.
func forgetConnections(addr netip.Addr) error {
	// The address is free only once one whole, uninterrupted pass of the
	// table finds no entry of it: each pass deletes what it found, and the
	// next proves the deletion.
	for pass := 0; pass < forgetPasses; pass++ {
		entries, err := conntrackOf(addr)
		if errors.Is(err, errDumpInterrupted) {
			continue
		}
		if err != nil {
			return fmt.Errorf("reading the connection table: %w", err)
		}
		if len(entries) == 0 {
			return nil
		}
		if err := deleteConnections(addr, entries); err != nil {
			return err
		}
	}
	return fmt.Errorf("no whole pass of the connection table found it free of %s in %d passes", addr, forgetPasses)
}

// forgetPasses bounds the passes forgetConnections makes.
const forgetPasses = 8

// deleteConnections deletes each entry of addr a pass found; one already
// gone is deleted.
func deleteConnections(addr netip.Addr, entries [][]byte) error {
	fd, err := ctnetlink()
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	for i, entry := range entries {
		seq := uint32(i + 2)
		if err := unix.Sendto(fd, ctMessage(ctnlMsgDelete, unix.NLM_F_ACK, seq, entry), 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
			return err
		}
		buf := make([]byte, 4096)
		n, _, err := unix.Recvfrom(fd, buf, 0)
		if err != nil {
			return fmt.Errorf("the deletion's answer: %w", err)
		}
		msgs, err := syscall.ParseNetlinkMessage(buf[:n])
		if err != nil {
			return err
		}
		for _, m := range msgs {
			if m.Header.Type == syscall.NLMSG_ERROR && len(m.Data) >= 4 {
				if code := int32(binary.NativeEndian.Uint32(m.Data[0:4])); code != 0 && unix.Errno(-code) != unix.ENOENT {
					return fmt.Errorf("removing a connection of %s: %w", addr, unix.Errno(-code))
				}
			}
		}
	}
	return nil
}

// tunFlags are a machine's tap's: a tap with no packet information and
// with the virtio-net header, as Firecracker attaches to one.
const tunFlags = unix.IFF_TAP | unix.IFF_NO_PI | unix.IFF_VNET_HDR

// tapName is slot's tap while it is in the guard's namespace, before it is
// moved into its VMM's as MachineTap.
func tapName(slot int) string { return "tp" + strconv.Itoa(slot) }

// machineLinks makes what a machine's route holds in its VMM's namespace
// beside the pair: a tap made here, persistent and owned by the VMM's uid,
// moved in as MachineTap; a bridge joining it and the pair's inner end,
// which holds MachineNames and a host route to the guest's address; all
// of it up. space is the namespace's UDP name socket, by which every
// change in it is made. A tap not yet moved is removed on a failure; what
// stands in the VMM's namespace ends with it.
func machineLinks(r *route) error {
	if err := makeTap(tapName(r.slot), r.uid); err != nil {
		return err
	}
	moved := false
	defer func() {
		if !moved {
			_ = removeLink(tapName(r.slot))
		}
	}()
	tap, err := linkIndex(tapName(r.slot))
	if err != nil {
		return err
	}
	if err := moveLink(tap, MachineTap, r.netns); err != nil {
		return err
	}
	moved = true
	space := int(r.udp.Fd())
	if err := bridgeOf(space, MachineBridge, innerName, MachineTap); err != nil {
		return err
	}
	if err := setAddress(space, MachineBridge, MachineNames, netip.AddrFrom4([4]byte{255, 255, 255, 255})); err != nil {
		return err
	}
	return hostRoute(space, r.inner, MachineBridge)
}

// makeTap makes a persistent tap named name in the guard's namespace,
// owned by uid, so that uid attaches to it with no capability.
func makeTap(name string, uid int) error {
	fd, err := unix.Open("/dev/net/tun", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("the machine's tap: %w", err)
	}
	defer unix.Close(fd)
	ifr, err := unix.NewIfreq(name)
	if err != nil {
		return err
	}
	ifr.SetUint16(tunFlags)
	if err := unix.IoctlIfreq(fd, unix.TUNSETIFF, ifr); err != nil {
		return fmt.Errorf("making the tap %s: %w", name, err)
	}
	if err := unix.IoctlSetInt(fd, unix.TUNSETOWNER, uid); err != nil {
		return fmt.Errorf("the tap %s's owner: %w", name, err)
	}
	if err := unix.IoctlSetInt(fd, unix.TUNSETPERSIST, 1); err != nil {
		return fmt.Errorf("keeping the tap %s: %w", name, err)
	}
	return nil
}

// linkIndex is the index of the link name in the guard's namespace.
func linkIndex(name string) (int32, error) {
	s, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return 0, err
	}
	defer unix.Close(s)
	ifr, err := unix.NewIfreq(name)
	if err != nil {
		return 0, err
	}
	if err := unix.IoctlIfreq(s, unix.SIOCGIFINDEX, ifr); err != nil {
		return 0, fmt.Errorf("the index of %s: %w", name, err)
	}
	return int32(ifr.Uint32()), nil
}

// moveLink moves the guard's link of index into the namespace netns names,
// renamed to name there.
func moveLink(index int32, name string, netns *os.File) error {
	body := ifinfomsg()
	binary.NativeEndian.PutUint32(body[4:8], uint32(index))
	var nsfd [4]byte
	binary.NativeEndian.PutUint32(nsfd[:], uint32(netns.Fd()))
	body = rtattr(body, unix.IFLA_IFNAME, cstring(name))
	body = rtattr(body, unix.IFLA_NET_NS_FD, nsfd[:])
	if err := netlinkDo(unix.RTM_SETLINK, 0, body); err != nil {
		return fmt.Errorf("moving the tap into the machine's namespace: %w", err)
	}
	return nil
}

// removeLink removes the guard's link name; one already gone is removed.
func removeLink(name string) error {
	err := netlinkDo(unix.RTM_DELLINK, 0, rtattr(ifinfomsg(), unix.IFLA_IFNAME, cstring(name)))
	if errors.Is(err, unix.ENODEV) {
		return nil
	}
	return err
}

// bridgeOf makes the bridge name in the namespace the socket fd belongs
// to, joins ports to it and brings each up.
func bridgeOf(fd int, name string, ports ...string) error {
	br := cstring(name)
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), unix.SIOCBRADDBR, uintptr(unsafe.Pointer(&br[0]))); errno != 0 {
		return fmt.Errorf("making the bridge %s: %w", name, errno)
	}
	for _, p := range ports {
		idx, err := unix.NewIfreq(p)
		if err != nil {
			return err
		}
		if err := unix.IoctlIfreq(fd, unix.SIOCGIFINDEX, idx); err != nil {
			return fmt.Errorf("the index of %s: %w", p, err)
		}
		join, err := unix.NewIfreq(name)
		if err != nil {
			return err
		}
		join.SetUint32(idx.Uint32())
		if err := unix.IoctlIfreq(fd, unix.SIOCBRADDIF, join); err != nil {
			return fmt.Errorf("joining %s to %s: %w", p, name, err)
		}
		if err := linkUp(fd, p); err != nil {
			return err
		}
	}
	return nil
}

// setAddress gives the link name, in the namespace fd's socket belongs to,
// address a under mask, and brings it up.
func setAddress(fd int, name string, a, mask netip.Addr) error {
	for _, set := range []struct {
		req  uint
		addr netip.Addr
	}{{unix.SIOCSIFADDR, a}, {unix.SIOCSIFNETMASK, mask}} {
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
	return linkUp(fd, name)
}

// linkUp brings the link name up, in the namespace fd's socket belongs to.
func linkUp(fd int, name string) error {
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

// hostRoute sets a route to the one address a on dev, in the namespace
// fd's socket belongs to.
func hostRoute(fd int, a netip.Addr, dev string) error {
	if unsafe.Sizeof(uintptr(0)) != 8 {
		return errors.New("a route is set by ioctl on a 64-bit kernel only")
	}
	var rt rtentry
	rt.dst.Family = unix.AF_INET
	rt.dst.Addr = a.As4()
	rt.genmask.Family = unix.AF_INET
	rt.genmask.Addr = [4]byte{255, 255, 255, 255}
	rt.gateway.Family = unix.AF_INET
	rt.flags = unix.RTF_UP | unix.RTF_HOST
	name := cstring(dev)
	rt.dev = uintptr(unsafe.Pointer(&name[0]))
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), unix.SIOCADDRT, uintptr(unsafe.Pointer(&rt)))
	runtime.KeepAlive(name)
	if errno != 0 {
		return fmt.Errorf("the route to %s on %s: %w", a, dev, errno)
	}
	return nil
}

// GuestLink sets a person's VM's own link up, in the guest, as the host's
// guard made the machine's route for it (machineLinks): the guest's one
// card, pool.RouteLink, at inner in a /30 and up, a host route to
// MachineNames on it, where the host's guard answers its names, and the
// default route through gateway, the guard's end; the loopback up too.
func GuestLink(inner, gateway netip.Addr) error {
	s, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer unix.Close(s)
	if err := linkUp(s, "lo"); err != nil {
		return err
	}
	if err := setLink(s, innerName, inner); err != nil {
		return err
	}
	if err := hostRoute(s, MachineNames, innerName); err != nil {
		return err
	}
	return defaultRoute(s, gateway)
}

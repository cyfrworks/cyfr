// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/stage"
)

// The real-kernel proof of a route: the test binary re-runs itself as a
// stand-in guard in a user and network namespace of its own (so NET_ADMIN
// there is all it holds), which serves the control with kernelRoutes (its
// rules script a no-op: iptables is the image suites') and starts a
// stand-in space in a namespace that descends from its own. A keeper's
// client admits the space's route with the namespace and name sockets the
// space handed up; the space then reaches the guard's end of the route,
// has a name answered on its own 127.0.0.11:53 and holds a stream from
// the guard open. When the keeper's connection ends, the guard withdraws
// the route: the open stream passes nothing more, and both ends are gone.

const (
	routeGuardMode   = "CYFR_GUARD_TEST_ROUTE"
	routeSpaceMode   = "CYFR_GUARD_TEST_SPACE"
	machineGuardMode = "CYFR_GUARD_TEST_MACHINE"
	machineMode      = "CYFR_GUARD_TEST_VMM"
	guestLinkMode    = "CYFR_GUARD_TEST_GUEST_LINK"
	forgedGuardMode  = "CYFR_GUARD_TEST_FORGED"
	forgerMode       = "CYFR_GUARD_TEST_FORGER"
	timersMode       = "CYFR_GUARD_TEST_TIMERS"
)

func TestMain(m *testing.M) {
	switch {
	case os.Getenv(routeGuardMode) != "":
		os.Exit(standInGuard())
	case os.Getenv(routeSpaceMode) != "":
		os.Exit(standInSpace())
	case os.Getenv(machineGuardMode) != "":
		os.Exit(standInMachineGuard())
	case os.Getenv(machineMode) != "":
		os.Exit(standInVMM())
	case os.Getenv(guestLinkMode) != "":
		os.Exit(standInGuest())
	case os.Getenv(forgedGuardMode) != "":
		os.Exit(standInForgedGuard(os.Getenv(forgedGuardMode)))
	case os.Getenv(forgerMode) != "":
		os.Exit(standInForger())
	case os.Getenv(timersMode) != "":
		os.Exit(shortTimers())
	}
	os.Exit(m.Run())
}

// userNetAttr clones into a new user and network namespace mapping uid and
// gid 0 to the caller's own.
func userNetAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{
		Cloneflags:  syscall.CLONE_NEWUSER | syscall.CLONE_NEWNET,
		UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: os.Getuid(), Size: 1}},
		GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: os.Getgid(), Size: 1}},
		Pdeathsig:   syscall.SIGKILL,
	}
}

func TestARouteIsMadeIntoASpaceAndAnswersItsNames(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), routeGuardMode+"=1")
	cmd.SysProcAttr = userNetAttr()
	out, err := cmd.CombinedOutput()
	if err != nil && (bytes.Contains(out, []byte("skip:")) || errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EINVAL)) {
		t.Skipf("this host gives the test no namespaces of its own: %v %s", err, out)
	}
	if err != nil {
		t.Fatalf("the stand-in guard: %v\n%s", err, out)
	}
	for _, want := range []string{"space: reached the guard: guard", "space: name: answer",
		"space: the stream passes nothing after the withdrawal", "space: a new connection has no route", "guard: both ends gone"} {
		if !strings.Contains(string(out), want) {
			t.Errorf("lacks %q:\n%s", want, out)
		}
	}
}

func standInGuard() int {
	fail := func(format string, args ...any) int {
		fmt.Printf("guard: "+format+"\n", args...)
		return 1
	}
	lo, err := net.InterfaceByName("lo")
	if err != nil {
		return fail("%v", err)
	}
	ctl, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	ifr, _ := unix.NewIfreq(lo.Name)
	_ = unix.IoctlIfreq(ctl, unix.SIOCGIFFLAGS, ifr)
	ifr.SetUint16(ifr.Uint16() | unix.IFF_UP)
	if err := unix.IoctlIfreq(ctl, unix.SIOCSIFFLAGS, ifr); err != nil {
		// A host that restricts unprivileged user namespaces gives this
		// one no capability in it.
		fmt.Printf("skip: the loopback: %v\n", err)
		return 1
	}
	// The island's resolver stands in as a UDP server answering "answer".
	upstream, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		return fail("%v", err)
	}
	go func() {
		buf := make([]byte, 512)
		for {
			_, from, err := upstream.ReadFrom(buf)
			if err != nil {
				return
			}
			_, _ = upstream.WriteTo([]byte("answer"), from)
		}
	}()
	listener, err := net.Listen("tcp", "0.0.0.0:7777")
	if err != nil {
		return fail("%v", err)
	}
	go func() {
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			_, _ = c.Write([]byte("guard"))
			c.Close()
		}
	}()

	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	mine, theirs := os.NewFile(uintptr(pair[0]), "guard"), os.NewFile(uintptr(pair[1]), "space")
	space := exec.Command(os.Args[0], "-test.run=^$")
	space.Env = []string{routeSpaceMode + "=1"}
	space.ExtraFiles = []*os.File{theirs}
	space.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:  syscall.CLONE_NEWUSER | syscall.CLONE_NEWNET,
		UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
		GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
		Pdeathsig:   syscall.SIGKILL,
	}
	var spaceOut bytes.Buffer
	space.Stdout, space.Stderr = &spaceOut, &spaceOut
	if err := space.Start(); err != nil {
		return fail("the space: %v", err)
	}
	theirs.Close()
	buf, oob := make([]byte, 1), make([]byte, unix.CmsgSpace(12))
	_, oobn, _, _, err := unix.Recvmsg(int(mine.Fd()), buf, oob, 0)
	if err != nil {
		return fail("the space's descriptors: %v", err)
	}
	msgs, _ := unix.ParseSocketControlMessage(oob[:oobn])
	fds, err := unix.ParseUnixRights(&msgs[0])
	if err != nil || len(fds) != 3 {
		return fail("descriptors %v %v", fds, err)
	}
	rng, _ := ParseRange("10.213.0.0/16")
	gateway, inner := slotAddresses(rng, 0)
	r := &route{spawnID: testSpawn, slot: 0, gateway: gateway, inner: inner, mark: 1, reach: ReachIsland,
		netns: os.NewFile(uintptr(fds[0]), "netns"), udp: os.NewFile(uintptr(fds[1]), "udp"), tcp: os.NewFile(uintptr(fds[2]), "tcp")}
	_ = r
	rng16, _ := ParseRange("10.213.0.0/16")
	srv := newServer(logx.New("cyfr-guard-test"), "net:[test]", rng16, kernelRoutes{set: noRules{}})
	srv.upstream = upstream.LocalAddr().String()
	ended := make(chan struct{}, 1)
	srv.onEnd = func() { ended <- struct{}{} }
	dir, err := os.MkdirTemp("", "cyfr-guard-route-")
	if err != nil {
		return fail("%v", err)
	}
	defer os.RemoveAll(dir)
	sock := dir + "/guard.sock"
	l, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: sock, Net: "unixpacket"})
	if err != nil {
		return fail("%v", err)
	}
	go func() {
		for {
			conn, err := l.AcceptUnix()
			if err != nil {
				return
			}
			go srv.serve(conn)
		}
	}()
	client := NewClient(sock, "net:[test]", nil)
	if _, err := client.Admit(testSpawn, ReachIsland, nil, r.netns, r.udp, r.tcp); err != nil {
		return fail("the admit: %v", err)
	}
	r.netns.Close()
	r.udp.Close()
	r.tcp.Close()
	// The guard's stream: a line every 5 ms to whoever connects to 7778.
	stream, err := net.Listen("tcp", "0.0.0.0:7778")
	if err != nil {
		return fail("%v", err)
	}
	go func() {
		for {
			c, err := stream.Accept()
			if err != nil {
				return
			}
			go func() {
				for {
					if _, err := c.Write([]byte("line\n")); err != nil {
						return
					}
					time.Sleep(5 * time.Millisecond) // sleep-ok: the stream's pace
				}
			}()
		}
	}()
	if _, err := mine.Write([]byte{'g'}); err != nil {
		return fail("%v", err)
	}
	// The space reports it streams; the keeper's connection then ends.
	streaming := make([]byte, 1)
	if _, err := mine.Read(streaming); err != nil {
		return fail("the space's stream: %v", err)
	}
	client.mu.Lock()
	if client.link != nil {
		client.end(client.link)
	}
	client.mu.Unlock()
	select {
	case <-ended:
	case <-time.After(10 * time.Second):
		return fail("the connection's withdrawal did not finish")
	}
	if _, err := mine.Write([]byte{'w'}); err != nil {
		return fail("%v", err)
	}
	waited := make(chan error, 1)
	go func() { waited <- space.Wait() }()
	select {
	case err := <-waited:
		fmt.Print(spaceOut.String())
		if err != nil {
			return fail("the space ended %v", err)
		}
	case <-time.After(20 * time.Second):
		return fail("the space did not finish: %s", spaceOut.String())
	}
	if _, err := net.InterfaceByName(outerName(0)); err == nil {
		return fail("the guard's end stays")
	}
	fmt.Println("guard: both ends gone")
	return 0
}

func standInSpace() int {
	fail := func(format string, args ...any) int {
		fmt.Printf("space: "+format+"\n", args...)
		return 1
	}
	keeper := os.NewFile(3, "guard")
	netns, err := unix.Open("/proc/thread-self/ns/net", unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	ctl, _ := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	ifr, _ := unix.NewIfreq("lo")
	_ = unix.IoctlIfreq(ctl, unix.SIOCGIFFLAGS, ifr)
	ifr.SetUint16(ifr.Uint16() | unix.IFF_UP)
	if err := unix.IoctlIfreq(ctl, unix.SIOCSIFFLAGS, ifr); err != nil {
		return fail("the loopback: %v", err)
	}
	at := &unix.SockaddrInet4{Port: 53, Addr: [4]byte{127, 0, 0, 11}}
	udp, _ := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	tcp, _ := unix.Socket(unix.AF_INET, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err := unix.Bind(udp, at); err != nil {
		return fail("binding: %v", err)
	}
	if err := unix.Bind(tcp, at); err != nil {
		return fail("binding: %v", err)
	}
	_ = unix.Listen(tcp, 4)
	if err := unix.Sendmsg(int(keeper.Fd()), []byte{'r'}, unix.UnixRights(netns, udp, tcp), nil, 0); err != nil {
		return fail("%v", err)
	}
	unix.Close(udp)
	unix.Close(tcp)
	unix.Close(netns)
	word := make([]byte, 1)
	if _, err := keeper.Read(word); err != nil || word[0] != 'g' {
		return fail("no word: %v", err)
	}
	rng, _ := ParseRange("10.213.0.0/16")
	gateway, _ := slotAddresses(rng, 0)
	c, err := net.DialTimeout("tcp", netip.AddrPortFrom(gateway, 7777).String(), 3*time.Second)
	if err != nil {
		return fail("reaching the guard: %v", err)
	}
	got := make([]byte, 16)
	k, _ := c.Read(got)
	c.Close()
	fmt.Printf("space: reached the guard: %s\n", got[:k])
	q, err := net.Dial("udp", "127.0.0.11:53")
	if err != nil {
		return fail("%v", err)
	}
	_ = q.SetDeadline(time.Now().Add(3 * time.Second))
	_, _ = q.Write([]byte("q"))
	k, err = q.Read(got)
	if err != nil {
		return fail("the name: %v", err)
	}
	fmt.Printf("space: name: %s\n", got[:k])
	s, err := net.DialTimeout("tcp", netip.AddrPortFrom(gateway, 7778).String(), 3*time.Second)
	if err != nil {
		return fail("the stream: %v", err)
	}
	r := bufio.NewReader(s)
	if _, err := r.ReadString('\n'); err != nil {
		return fail("the stream: %v", err)
	}
	if _, err := keeper.Write([]byte{'s'}); err != nil {
		return fail("%v", err)
	}
	if _, err := keeper.Read(word); err != nil || word[0] != 'w' {
		return fail("no word of the withdrawal: %v", err)
	}
	// The route is withdrawn: what was in flight drains, then nothing more.
	_ = s.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
	for {
		if _, err := r.ReadString('\n'); err != nil {
			break
		}
	}
	_ = s.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if line, err := r.ReadString('\n'); err == nil {
		return fail("the stream passed %q after its route was withdrawn", line)
	}
	fmt.Println("space: the stream passes nothing after the withdrawal")
	if _, err := net.DialTimeout("tcp", netip.AddrPortFrom(gateway, 7777).String(), time.Second); err == nil {
		return fail("a new connection passed after the withdrawal")
	}
	fmt.Println("space: a new connection has no route")
	return 0
}

// noRules stands for the guard's rules where a test makes a route's pair
// alone.
type noRules struct{}

func (noRules) install(*route) error  { return nil }
func (noRules) withdraw(*route) error { return nil }
func (noRules) change(_, _ *route) error {
	return nil
}

// vmmUID is the stand-in VMM's uid, the tap's owner.
const vmmUID = 30201

// The real-kernel proof of a machine's route: as the space's, with a
// stand-in VMM in place of the space, which hands up its namespace, its two
// name sockets and a route netlink socket. The guard makes the pair, the
// tap it moves into the VMM's namespace and the bridge there. The stand-in
// VMM, the tap's owner, attaches to it by name with no capability and, as a
// guest would, with no ARP: its echo to the gateway is answered through the
// bridge and the pair, and its name question to MachineNames:53 through
// the tap by the guard. A guest that writes what frames it likes grows no
// table of the host's: 20,000 source addresses leave the bridge learning
// none, and 64 spoofed ARP senders, for the gateway and for the names,
// leave the guard's end and the bridge knowing the guest's address alone.
// No end of the route holds an IPv6 address, and the guard's end filters
// by its reverse path strictly. When the keeper's connection ends, the
// pair and the tap's name in the guard's namespace are gone.
func TestAMachinesRouteJoinsItsTapToTheGuardsEnd(t *testing.T) {
	if _, err := os.Stat("/dev/net/tun"); err != nil {
		t.Skipf("this host has no /dev/net/tun: %v", err)
	}
	if os.Getuid() != 0 {
		t.Skip("the VMM's own uid is mapped beside the guard's by root alone")
	}
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), machineGuardMode+"=1")
	cmd.SysProcAttr = userNetAttr()
	cmd.SysProcAttr.UidMappings = append(cmd.SysProcAttr.UidMappings, syscall.SysProcIDMap{ContainerID: vmmUID, HostID: vmmUID, Size: 1})
	out, err := cmd.CombinedOutput()
	if err != nil && (bytes.Contains(out, []byte("skip:")) || errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EINVAL)) {
		t.Skipf("this host gives the test no namespaces of its own: %v %s", err, out)
	}
	if err != nil {
		t.Fatalf("the stand-in guard: %v\n%s", err, out)
	}
	for _, want := range []string{"guard: admitted 10.213.0.2 behind 10.213.0.1",
		"guard: sp0 is 06:00:0a:00:00:01, answers no ARP, holds no IPv6 address, filters its reverse path strictly",
		"guard: sp0 knows the guest alone", "vmm: attached to tap0 as its owner",
		"vmm: the gateway answered the guest's echo through the bridge, with no ARP",
		"vmm: name: answer, through the tap", "vmm: the bridge learned none of 20000 addresses",
		"vmm: br0 knows the guest alone", "vmm: br0 is " + NamesMAC.String() + " and answers no ARP", "vmm: no end of the route holds an IPv6 address",
		"vmm: 64 router advertisements left no IPv6 address, route or neighbour",
		"guard: sp0 still knows the guest alone after 64 spoofed senders", "guard: the pair and the tap are gone"} {
		if !strings.Contains(string(out), want) {
			t.Errorf("lacks %q:\n%s", want, out)
		}
	}
}

// neighbours are the IPv4 unicast neighbours of link index the route
// netlink socket fd's namespace holds, by address, with their state: the
// kernel's own multicast entries (IGMP's 224.0.0.22, of no ARP) apart, a
// fixed few that no frame of a guest's adds to.
func neighbours(fd int, index int32) (map[netip.Addr]uint16, error) {
	got := map[netip.Addr]uint16{}
	b := make([]byte, unix.SizeofNdMsg)
	b[0] = unix.AF_INET
	err := dump(fd, unix.RTM_GETNEIGH, b, func(m syscall.NetlinkMessage) {
		if m.Header.Type != unix.RTM_NEWNEIGH || len(m.Data) < unix.SizeofNdMsg {
			return
		}
		if int32(binary.NativeEndian.Uint32(m.Data[4:8])) != index {
			return
		}
		state := binary.NativeEndian.Uint16(m.Data[8:10])
		for _, a := range attrs(m.Data[unix.SizeofNdMsg:]) {
			if attrType(a) == unix.NDA_DST && len(a[2]) == 4 {
				if addr := netip.AddrFrom4([4]byte(a[2])); !addr.IsMulticast() {
					got[addr] = state
				}
			}
		}
	})
	return got, err
}

// A netlink answer the guard takes is its own request's, whatever else
// the socket holds, and comes within its bound or not at all: on the real
// kernel an earlier request's refusal left unread is passed over for this
// request's acknowledgement, and a socket that answers nothing is given
// up at the deadline. A machine's stage hands the guard such a socket.
func TestANetlinkAnswerIsItsOwnRequestsWithinItsBound(t *testing.T) {
	fd, err := nlSocket(unix.NETLINK_ROUTE)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fd)
	stale := append(make([]byte, unix.SizeofNlMsghdr), ifinfo(unix.AF_UNSPEC, 0x7fffffff)...)
	binary.NativeEndian.PutUint32(stale[0:4], uint32(len(stale)))
	binary.NativeEndian.PutUint16(stale[4:6], unix.RTM_GETLINK)
	binary.NativeEndian.PutUint16(stale[6:8], unix.NLM_F_REQUEST|unix.NLM_F_ACK)
	binary.NativeEndian.PutUint32(stale[8:12], 0xfffffff0)
	if err := unix.Sendto(fd, stale, 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		t.Fatal(err)
	}
	if err := netlinkOn(fd, time.Now().Add(netlinkTimeout), unix.RTM_GETLINK, 0, ifinfo(unix.AF_UNSPEC, 1)); err != nil {
		t.Fatalf("the loopback's request answered %v: an earlier request's refusal was taken for its own", err)
	}
	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(pair[0])
	defer unix.Close(pair[1])
	began := time.Now()
	if err := netlinkAnswer(pair[0], 7, began.Add(200*time.Millisecond)); err == nil || time.Since(began) > 2*time.Second {
		t.Fatalf("a socket that answers nothing answered %v after %s", err, time.Since(began))
	}
}

// spaceProcOf mounts a proc of the calling process's namespaces where a
// stage mounts its space's, the one place the Locus profile lets a proc be
// mounted, over a tmpfs of its own mount namespace, and answers it.
func spaceProcOf() (string, error) {
	if err := unix.Mount("", "/", "", unix.MS_REC|unix.MS_PRIVATE, ""); err != nil {
		return "", err
	}
	if err := os.MkdirAll(stage.Root, 0o755); err != nil {
		return "", err
	}
	if err := unix.Mount("space", stage.Root, "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, "mode=0755,size=64k"); err != nil {
		return "", err
	}
	proc := stage.Root + "/proc"
	if err := os.Mkdir(proc, 0o755); err != nil {
		return "", err
	}
	return proc, unix.Mount("proc", proc, "proc", unix.MS_NOSUID|unix.MS_NODEV|unix.MS_NOEXEC, "")
}

// routerAdvert is a router advertisement to all nodes from fe80::2:<i> at
// mac, with a prefix of 2001:db8:<i>::/64 to take addresses from.
func routerAdvert(mac net.HardwareAddr, i byte) []byte {
	from := []byte{0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0x02, i}
	allNodes := []byte{0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
	ra := []byte{134, 0, 0, 0, 64, 0, 0x07, 0x08, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1}
	ra = append(ra, mac...)
	ra = append(ra, 3, 4, 64, 0xc0, 0, 1, 0x51, 0x80, 0, 0, 0x38, 0x40, 0, 0, 0, 0,
		0x20, 0x01, 0x0d, 0xb8, 0, i, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	pseudo := append(append(append([]byte{}, from...), allNodes...), 0, 0, byte(len(ra)>>8), byte(len(ra)), 0, 0, 0, 58)
	binary.BigEndian.PutUint16(ra[2:], csum(append(pseudo, ra...)))
	ip := []byte{0x60, 0, 0, 0, byte(len(ra) >> 8), byte(len(ra)), 58, 255}
	ip = append(append(ip, from...), allNodes...)
	f := append([]byte{0x33, 0x33, 0, 0, 0, 1}, mac...)
	f = append(f, 0x86, 0xdd)
	return append(append(f, ip...), ra...)
}

// v6Neighbours is how many IPv6 neighbours the route netlink socket fd's
// namespace holds.
func v6Neighbours(fd int) (int, error) {
	n := 0
	b := make([]byte, unix.SizeofNdMsg)
	b[0] = unix.AF_INET6
	err := dump(fd, unix.RTM_GETNEIGH, b, func(m syscall.NetlinkMessage) {
		if m.Header.Type == unix.RTM_NEWNEIGH {
			n++
		}
	})
	return n, err
}

// v6Routes is how many IPv6 routes of the calling process's namespace go
// by the links named.
func v6Routes(names ...string) (int, error) {
	b, err := os.ReadFile("/proc/self/net/ipv6_route")
	if err != nil {
		return 0, err
	}
	n := 0
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) == 10 && slices.Contains(names, f[9]) {
			n++
		}
	}
	return n, nil
}

// fdbCount is how many forwarding entries the bridge ports of the route
// netlink socket fd's namespace hold.
func fdbCount(fd int) (int, error) {
	n := 0
	b := make([]byte, unix.SizeofNdMsg)
	b[0] = unix.AF_BRIDGE
	err := dump(fd, unix.RTM_GETNEIGH, b, func(m syscall.NetlinkMessage) {
		if m.Header.Type == unix.RTM_NEWNEIGH {
			n++
		}
	})
	return n, err
}

// v6Addresses is how many IPv6 addresses links of the namespace hold, of
// the indexes given.
func v6Addresses(fd int, indexes ...int32) (int, error) {
	n := 0
	b := make([]byte, unix.SizeofIfAddrmsg)
	b[0] = unix.AF_INET6
	err := dump(fd, unix.RTM_GETADDR, b, func(m syscall.NetlinkMessage) {
		if m.Header.Type != unix.RTM_NEWADDR || len(m.Data) < unix.SizeofIfAddrmsg {
			return
		}
		for _, i := range indexes {
			if int32(binary.NativeEndian.Uint32(m.Data[4:8])) == i {
				n++
			}
		}
	})
	return n, err
}

// dump sends a dump request of kind on fd and calls each for every message
// of its answer.
func dump(fd int, kind uint16, body []byte, each func(syscall.NetlinkMessage)) error {
	msg := make([]byte, unix.SizeofNlMsghdr)
	msg = append(msg, body...)
	binary.NativeEndian.PutUint32(msg[0:4], uint32(len(msg)))
	binary.NativeEndian.PutUint16(msg[4:6], kind)
	binary.NativeEndian.PutUint16(msg[6:8], unix.NLM_F_REQUEST|unix.NLM_F_DUMP)
	binary.NativeEndian.PutUint32(msg[8:12], 7)
	if err := unix.Sendto(fd, msg, 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return err
	}
	buf := make([]byte, 1<<16)
	for {
		n, _, err := unix.Recvfrom(fd, buf, 0)
		if err != nil {
			return err
		}
		msgs, err := syscall.ParseNetlinkMessage(buf[:n])
		if err != nil {
			return err
		}
		for _, m := range msgs {
			switch m.Header.Type {
			case syscall.NLMSG_DONE:
				return nil
			case syscall.NLMSG_ERROR:
				if code := int32(binary.NativeEndian.Uint32(m.Data[0:4])); code != 0 {
					return unix.Errno(-code)
				}
				return nil
			}
			each(m)
		}
	}
}

func standInMachineGuard() int {
	fail := func(format string, args ...any) int {
		fmt.Printf("guard: "+format+"\n", args...)
		return 1
	}
	ctl, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	if err := linkUp(ctl, "lo"); err != nil {
		fmt.Printf("skip: the loopback: %v\n", err)
		return 1
	}
	upstream, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		return fail("%v", err)
	}
	go func() {
		buf := make([]byte, 512)
		for {
			_, from, err := upstream.ReadFrom(buf)
			if err != nil {
				return
			}
			_, _ = upstream.WriteTo([]byte("answer"), from)
		}
	}()
	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	mine, theirs := os.NewFile(uintptr(pair[0]), "guard"), os.NewFile(uintptr(pair[1]), "vmm")
	vmm := exec.Command(os.Args[0], "-test.run=^$")
	vmm.Env = []string{machineMode + "=1"}
	vmm.ExtraFiles = []*os.File{theirs}
	vmm.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:  syscall.CLONE_NEWUSER | syscall.CLONE_NEWNET | syscall.CLONE_NEWNS | syscall.CLONE_NEWPID,
		UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}, {ContainerID: vmmUID, HostID: vmmUID, Size: 1}},
		GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
		Pdeathsig:   syscall.SIGKILL,
	}
	var vmmOut bytes.Buffer
	vmm.Stdout, vmm.Stderr = &vmmOut, &vmmOut
	if err := vmm.Start(); err != nil {
		return fail("the VMM: %v", err)
	}
	theirs.Close()
	buf, oob := make([]byte, 1), make([]byte, unix.CmsgSpace(16))
	_, oobn, _, _, err := unix.Recvmsg(int(mine.Fd()), buf, oob, 0)
	if err != nil {
		return fail("the VMM's descriptors: %v", err)
	}
	msgs, _ := unix.ParseSocketControlMessage(oob[:oobn])
	fds, err := unix.ParseUnixRights(&msgs[0])
	if err != nil || len(fds) != 4 {
		return fail("descriptors %v %v", fds, err)
	}
	files := []*os.File{os.NewFile(uintptr(fds[0]), "netns"), os.NewFile(uintptr(fds[1]), "udp"), os.NewFile(uintptr(fds[2]), "tcp"), os.NewFile(uintptr(fds[3]), "netlink")}
	rng, _ := ParseRange("10.213.0.0/16")
	srv := newServer(logx.New("cyfr-guard-test"), "net:[test]", rng, kernelRoutes{set: noRules{}})
	srv.upstream = upstream.LocalAddr().String()
	ended := make(chan struct{}, 1)
	srv.onEnd = func() { ended <- struct{}{} }
	dir, err := os.MkdirTemp("", "cyfr-guard-machine-")
	if err != nil {
		return fail("%v", err)
	}
	defer os.RemoveAll(dir)
	sock := dir + "/guard.sock"
	l, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: sock, Net: "unixpacket"})
	if err != nil {
		return fail("%v", err)
	}
	go func() {
		for {
			conn, err := l.AcceptUnix()
			if err != nil {
				return
			}
			go srv.serve(conn)
		}
	}()
	client := NewClient(sock, "net:[test]", nil)
	m, err := client.AdmitMachine(testSpawn, vmmUID, ReachIsland, nil, files[0], files[1], files[2], files[3])
	if err != nil {
		return fail("the admit: %v", err)
	}
	fmt.Printf("guard: admitted %s behind %s\n", m.Inner, m.Gateway)
	for _, f := range files {
		f.Close()
	}
	if _, err := net.InterfaceByName(tapName(0)); err == nil {
		return fail("the tap's name stays in the guard's namespace")
	}
	end, err := net.InterfaceByName(outerName(0))
	if err != nil {
		return fail("%v", err)
	}
	nl, err := nlSocket(unix.NETLINK_ROUTE)
	if err != nil {
		return fail("%v", err)
	}
	v6, _ := v6Addresses(nl, int32(end.Index))
	rp, _ := os.ReadFile("/proc/sys/net/ipv4/conf/" + outerName(0) + "/rp_filter")
	if end.HardwareAddr.String() == GatewayMAC.String() && end.Flags&net.FlagUp != 0 && v6 == 0 && strings.TrimSpace(string(rp)) == "1" {
		ifr, _ := unix.NewIfreq(outerName(0))
		if unix.IoctlIfreq(ctl, unix.SIOCGIFFLAGS, ifr) == nil && ifr.Uint16()&unix.IFF_NOARP != 0 {
			fmt.Printf("guard: sp0 is %s, answers no ARP, holds no IPv6 address, filters its reverse path strictly\n", GatewayMAC)
		}
	}
	alone := func(word string) {
		known, err := neighbours(nl, int32(end.Index))
		if err == nil && len(known) == 1 && known[m.Inner] == unix.NUD_PERMANENT {
			fmt.Printf("guard: sp0 %sknows the guest alone%s\n", map[bool]string{true: "still "}[word != ""], word)
		} else {
			fmt.Printf("guard: sp0 knows %v (%v)\n", known, err)
		}
	}
	alone("")
	if _, err := mine.Write([]byte{'g'}); err != nil {
		return fail("%v", err)
	}
	done := make([]byte, 1)
	if _, err := mine.Read(done); err != nil {
		fmt.Print(vmmOut.String())
		return fail("the VMM's word: %v", err)
	}
	alone(" after 64 spoofed senders")
	client.mu.Lock()
	if client.link != nil {
		client.end(client.link)
	}
	client.mu.Unlock()
	select {
	case <-ended:
	case <-time.After(10 * time.Second):
		return fail("the connection's withdrawal did not finish")
	}
	_ = vmm.Process.Kill()
	_ = vmm.Wait()
	fmt.Print(vmmOut.String())
	_, outer := net.InterfaceByName(outerName(0))
	_, tap := net.InterfaceByName(tapName(0))
	if outer == nil || tap == nil {
		return fail("after the withdrawal the pair stands (%v) or the tap's name (%v)", outer, tap)
	}
	fmt.Println("guard: the pair and the tap are gone")
	return 0
}

// csum is the Internet checksum of b.
func csum(b []byte) uint16 {
	var s uint32
	for i := 0; i+1 < len(b); i += 2 {
		s += uint32(binary.BigEndian.Uint16(b[i:]))
	}
	if len(b)%2 == 1 {
		s += uint32(b[len(b)-1]) << 8
	}
	for s>>16 != 0 {
		s = s&0xffff + s>>16
	}
	return ^uint16(s)
}

// ipv4Frame is an Ethernet frame of one IPv4 packet of proto and payload,
// its header's checksum set.
func ipv4Frame(dst, src net.HardwareAddr, from, to netip.Addr, proto byte, payload []byte) []byte {
	ip := make([]byte, 20)
	ip[0], ip[8], ip[9] = 0x45, 64, proto
	binary.BigEndian.PutUint16(ip[2:], uint16(20+len(payload)))
	f4, t4 := from.As4(), to.As4()
	copy(ip[12:], f4[:])
	copy(ip[16:], t4[:])
	binary.BigEndian.PutUint16(ip[10:], csum(ip))
	f := append(append(append([]byte{}, dst...), src...), 0x08, 0)
	return append(append(f, ip...), payload...)
}

// arpRequest is who-has target, from sender at mac.
func arpRequest(mac net.HardwareAddr, sender, target netip.Addr) []byte {
	s4, t4 := sender.As4(), target.As4()
	f := append([]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, mac...)
	f = append(f, 0x08, 0x06, 0, 1, 0x08, 0, 6, 4, 0, 1)
	f = append(f, mac...)
	f = append(f, s4[:]...)
	f = append(f, 0, 0, 0, 0, 0, 0)
	return append(f, t4[:]...)
}

// standInVMM hands up its namespace, two name sockets bound to
// MachineNames:53 and a route netlink socket, then, once the route is made,
// attaches to the tap as its owner and speaks for a guest at the route's
// inner address, as GuestLink sets one: by permanent neighbours, no ARP.
func standInVMM() int {
	fail := func(format string, args ...any) int {
		fmt.Printf("vmm: "+format+"\n", args...)
		return 1
	}
	guard := os.NewFile(3, "guard")
	netns, err := unix.Open("/proc/thread-self/ns/net", unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	ctl, _ := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err := linkUp(ctl, "lo"); err != nil {
		return fail("the loopback: %v", err)
	}
	at := &unix.SockaddrInet4{Port: 53, Addr: MachineNames.As4()}
	udp, _ := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	tcp, _ := unix.Socket(unix.AF_INET, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	for _, fd := range []int{udp, tcp} {
		if err := unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_FREEBIND, 1); err != nil {
			return fail("%v", err)
		}
		if err := unix.Bind(fd, at); err != nil {
			return fail("binding: %v", err)
		}
	}
	_ = unix.Listen(tcp, 4)
	nl, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_ROUTE)
	if err != nil {
		return fail("%v", err)
	}
	if err := unix.Sendmsg(int(guard.Fd()), []byte{'r'}, unix.UnixRights(netns, udp, tcp, nl), nil, 0); err != nil {
		return fail("%v", err)
	}
	for _, fd := range []int{udp, tcp, netns} {
		unix.Close(fd)
	}
	word := make([]byte, 1)
	if _, err := guard.Read(word); err != nil || word[0] != 'g' {
		return fail("no word: %v", err)
	}
	// The route made, the stage builds the space and its own proc, which
	// turns IPv6 off in the namespace (stage.NoIPv6), before the VMM runs.
	proc, err := spaceProcOf()
	if err != nil {
		return fail("the space's proc: %v", err)
	}
	if err := stage.NoIPv6(proc); err != nil {
		return fail("%v", err)
	}
	// As the VMM does, it attaches as the tap's owner holding no
	// capability: its stage made the sockets, then became the VMM's uid.
	if err := syscall.Setresuid(vmmUID, vmmUID, vmmUID); err != nil {
		return fail("becoming the VMM's uid: %v", err)
	}
	var caps [2]unix.CapUserData
	if err := unix.Capget(&unix.CapUserHeader{Version: unix.LINUX_CAPABILITY_VERSION_3}, &caps[0]); err != nil || caps[0].Effective != 0 || caps[1].Effective != 0 {
		return fail("the VMM holds capabilities %x%x (%v)", caps[1].Effective, caps[0].Effective, err)
	}
	tap, err := unix.Open("/dev/net/tun", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	defer unix.Close(tap)
	attach, _ := unix.NewIfreq(MachineTap)
	attach.SetUint16(unix.IFF_TAP | unix.IFF_NO_PI)
	if err := unix.IoctlIfreq(tap, unix.TUNSETIFF, attach); err != nil {
		return fail("attaching to %s: %v", MachineTap, err)
	}
	fmt.Printf("vmm: attached to %s as its owner\n", MachineTap)
	if err := unix.SetNonblock(tap, true); err != nil {
		return fail("%v", err)
	}
	rng, _ := ParseRange("10.213.0.0/16")
	gateway, inner := slotAddresses(rng, 0)
	frame := make([]byte, 2048)
	// await writes f until a frame comes back that match says is its answer.
	await := func(f []byte, match func([]byte) bool) bool {
		for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
			if _, err := unix.Write(tap, f); err != nil {
				return false
			}
			for end := time.Now().Add(200 * time.Millisecond); time.Now().Before(end); {
				n, err := unix.Read(tap, frame)
				if err != nil {
					time.Sleep(5 * time.Millisecond) // sleep-ok: a nonblocking tap's next frame
					continue
				}
				if n > 34 && bytes.Equal(frame[0:6], GuestMAC) && frame[12] == 0x08 && frame[13] == 0 && match(frame[14:n]) {
					return true
				}
			}
		}
		return false
	}
	echo := []byte{8, 0, 0, 0, 0x12, 0x34, 0, 1, 'g', 'u', 'e', 's', 't'}
	binary.BigEndian.PutUint16(echo[2:], csum(echo))
	g4 := gateway.As4()
	if await(ipv4Frame(GatewayMAC, GuestMAC, inner, gateway, 1, echo), func(p []byte) bool {
		return p[9] == 1 && bytes.Equal(p[12:16], g4[:]) && p[20] == 0 && binary.BigEndian.Uint16(p[24:26]) == 0x1234
	}) {
		fmt.Println("vmm: the gateway answered the guest's echo through the bridge, with no ARP")
	}
	question := []byte{0x9c, 0x41, 0, 53, 0, 9, 0, 0, 'q'}
	n4 := MachineNames.As4()
	answered := ""
	if await(ipv4Frame(NamesMAC, GuestMAC, inner, MachineNames, 17, question), func(p []byte) bool {
		if p[9] == 17 && bytes.Equal(p[12:16], n4[:]) && binary.BigEndian.Uint16(p[20:22]) == 53 {
			answered = string(p[28:])
			return true
		}
		return false
	}) {
		fmt.Printf("vmm: name: %s, through the tap\n", answered)
	}
	before, err := fdbCount(nl)
	if err != nil {
		return fail("the bridge's entries: %v", err)
	}
	for i := 0; i < 20000; i++ {
		src := net.HardwareAddr{0x02, 0x11, byte(i >> 16), byte(i >> 8), byte(i), 0x01}
		f := append(append([]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, src...), 0x88, 0xb5, 'x')
		_, _ = unix.Write(tap, f)
	}
	after, err := fdbCount(nl)
	if err == nil && after == before {
		fmt.Println("vmm: the bridge learned none of 20000 addresses")
	} else {
		fmt.Printf("vmm: the bridge holds %d entries after the flood, %d before (%v)\n", after, before, err)
	}
	for i := 0; i < 64; i++ {
		mac := net.HardwareAddr{0x02, 0x22, 0, 0, 0, byte(i)}
		sender := netip.AddrFrom4([4]byte{10, 99, 0, byte(i)})
		_, _ = unix.Write(tap, arpRequest(mac, sender, gateway))
		_, _ = unix.Write(tap, arpRequest(mac, sender, MachineNames))
	}
	time.Sleep(200 * time.Millisecond) // sleep-ok: the spoofed requests reach both ends before their tables are read
	ifr, _ := unix.NewIfreq(MachineBridge)
	if err := unix.IoctlIfreq(ctl, unix.SIOCGIFINDEX, ifr); err != nil {
		return fail("%v", err)
	}
	known, err := neighbours(nl, int32(ifr.Uint32()))
	if err == nil && len(known) == 1 && known[inner] == unix.NUD_PERMANENT {
		fmt.Println("vmm: br0 knows the guest alone")
	} else {
		fmt.Printf("vmm: br0 knows %v (%v)\n", known, err)
	}
	// The namespace holds no route back to a spoofed sender, which keeps
	// it from br0's table here; where the host filters no reverse path,
	// only br0's own NOARP does.
	br, err := net.InterfaceByName(MachineBridge)
	flags, _ := unix.NewIfreq(MachineBridge)
	if err == nil && br.HardwareAddr.String() == NamesMAC.String() && unix.IoctlIfreq(ctl, unix.SIOCGIFFLAGS, flags) == nil && flags.Uint16()&unix.IFF_NOARP != 0 {
		fmt.Printf("vmm: br0 is %s and answers no ARP\n", NamesMAC)
	}
	var indexes []int32
	for _, name := range []string{innerName, MachineTap, MachineBridge} {
		ifr, _ := unix.NewIfreq(name)
		if err := unix.IoctlIfreq(ctl, unix.SIOCGIFINDEX, ifr); err == nil {
			indexes = append(indexes, int32(ifr.Uint32()))
		}
	}
	if v6, err := v6Addresses(nl, indexes...); err == nil && v6 == 0 && len(indexes) == 3 {
		fmt.Println("vmm: no end of the route holds an IPv6 address")
	}
	// A guest's router advertisements, from senders of its choosing, each
	// with a prefix to take addresses and a route from.
	for i := 0; i < 64; i++ {
		_, _ = unix.Write(tap, routerAdvert(net.HardwareAddr{0x02, 0x33, 0, 0, 0, byte(i)}, byte(i)))
	}
	time.Sleep(300 * time.Millisecond) // sleep-ok: the advertisements reach the bridge's stack before its tables are read
	v6, aerr := v6Addresses(nl, indexes...)
	n6, nerr := v6Neighbours(nl)
	r6, rerr := v6Routes(innerName, MachineTap, MachineBridge)
	if aerr == nil && nerr == nil && rerr == nil && v6 == 0 && n6 == 0 && r6 == 0 {
		fmt.Println("vmm: 64 router advertisements left no IPv6 address, route or neighbour")
	} else {
		fmt.Printf("vmm: after 64 router advertisements: %d IPv6 addresses (%v), %d neighbours (%v), %d routes (%v)\n", v6, aerr, n6, nerr, r6, rerr)
	}
	if _, err := guard.Write([]byte{'d'}); err != nil {
		return fail("%v", err)
	}
	select {}
}

// A person's VM sets its one card as its host's machine route expects it:
// the inner address in a /30 and up, no IPv6 address, the gateway and
// MachineNames known by permanent neighbours at their fixed addresses,
// since neither answers ARP, a host route to MachineNames on it, and the
// default route through the gateway. Here the card is one end of a pair
// in a namespace of the test's own.
func TestAGuestsCardIsSetAsItsMachineRouteExpects(t *testing.T) {
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), guestLinkMode+"=1")
	cmd.SysProcAttr = userNetAttr()
	out, err := cmd.CombinedOutput()
	if err != nil && (bytes.Contains(out, []byte("skip:")) || errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EINVAL)) {
		t.Skipf("this host gives the test no namespaces of its own: %v %s", err, out)
	}
	if err != nil {
		t.Fatalf("the stand-in guest: %v\n%s", err, out)
	}
	for _, want := range []string{"guest: eth0 10.213.0.6/30 up", "guest: route 169.254.0.53/32 dev eth0", "guest: default via 10.213.0.5 dev eth0",
		"guest: eth0 holds no IPv6 address", "guest: eth0 knows 10.213.0.5 at " + GatewayMAC.String() + " and 169.254.0.53 at " + NamesMAC.String() + ", for good"} {
		if !strings.Contains(string(out), want) {
			t.Errorf("lacks %q:\n%s", want, out)
		}
	}
}

func standInGuest() int {
	fail := func(format string, args ...any) int {
		fmt.Printf("guest: "+format+"\n", args...)
		return 1
	}
	peer := ifinfomsg()
	peer = rtattr(peer, unix.IFLA_IFNAME, cstring("peer0"))
	info := rtattr(nil, unix.IFLA_INFO_KIND, cstring("veth"))
	info = rtattr(info, unix.IFLA_INFO_DATA, rtattr(nil, vethInfoPeer, peer))
	body := rtattr(ifinfomsg(), unix.IFLA_IFNAME, cstring(innerName))
	body = rtattr(body, unix.IFLA_LINKINFO, info)
	if err := netlinkDo(unix.RTM_NEWLINK, unix.NLM_F_CREATE|unix.NLM_F_EXCL, body); err != nil {
		fmt.Printf("skip: the card: %v\n", err)
		return 1
	}
	// The pair's other end up, so the card has its carrier once up, as a
	// guest's has, and the kernel would give it a link-local address.
	ctl, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	if err := linkUp(ctl, "peer0"); err != nil {
		return fail("%v", err)
	}
	inner, gateway := netip.MustParseAddr("10.213.0.6"), netip.MustParseAddr("10.213.0.5")
	if err := GuestLink(inner, gateway); err != nil {
		return fail("%v", err)
	}
	card, err := net.InterfaceByName(innerName)
	if err != nil {
		return fail("%v", err)
	}
	addrs, _ := card.Addrs()
	if len(addrs) == 1 && addrs[0].String() == "10.213.0.6/30" && card.Flags&net.FlagUp != 0 {
		fmt.Println("guest: eth0 10.213.0.6/30 up")
	}
	routes, err := os.ReadFile("/proc/net/route")
	if err != nil {
		return fail("%v", err)
	}
	for _, line := range strings.Split(string(routes), "\n")[1:] {
		f := strings.Fields(line)
		if len(f) < 8 {
			continue
		}
		dst, gw, mask := hexIPv4(f[1]), hexIPv4(f[2]), hexIPv4(f[7])
		switch {
		case f[0] == innerName && dst == "169.254.0.53" && mask == "255.255.255.255":
			fmt.Println("guest: route 169.254.0.53/32 dev eth0")
		case f[0] == innerName && dst == "0.0.0.0" && gw == "10.213.0.5":
			fmt.Println("guest: default via 10.213.0.5 dev eth0")
		}
	}
	nl, err := nlSocket(unix.NETLINK_ROUTE)
	if err != nil {
		return fail("%v", err)
	}
	if v6, err := v6Addresses(nl, int32(card.Index)); err == nil && v6 == 0 {
		fmt.Println("guest: eth0 holds no IPv6 address")
	}
	// /proc/net/arp's flags 0x6 are a complete, permanent entry.
	arp, err := os.ReadFile("/proc/net/arp")
	if err != nil {
		return fail("%v", err)
	}
	known := map[string]string{}
	for _, line := range strings.Split(string(arp), "\n")[1:] {
		if f := strings.Fields(line); len(f) >= 6 && f[5] == innerName && f[2] == "0x6" {
			known[f[0]] = f[3]
		}
	}
	if len(known) == 2 && known["10.213.0.5"] == GatewayMAC.String() && known["169.254.0.53"] == NamesMAC.String() {
		fmt.Printf("guest: eth0 knows 10.213.0.5 at %s and 169.254.0.53 at %s, for good\n", GatewayMAC, NamesMAC)
	} else {
		fmt.Printf("guest: eth0 knows %v\n", known)
	}
	return 0
}

// hexIPv4 is /proc/net/route's little-endian hex IPv4 address, dotted.
func hexIPv4(h string) string {
	v, err := strconv.ParseUint(h, 16, 32)
	if err != nil {
		return ""
	}
	return netip.AddrFrom4([4]byte{byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24)}).String()
}

// A guest's forged source carries nothing out, on the real rules and the
// real kernel: a stand-in guest writes frames from four addresses not its
// own (an outside host, the control plane, an island host, the metadata
// address) and from a second address on its card, another route's guest's,
// to the guard itself, to an outside host with a TTL of 1, so the kernel
// would answer it, and to an outside host plainly; and IPv6 from an
// outside and an island address, to the guard's own IPv6 address on the
// island and past it, which no route carries; and a first fragment of
// each family from a forged source, to the guard and past it, never
// completed, which the kernel holds before the raw table sees it and
// whose reassembly ends, its timers shortened here to a second, in the
// kernel's own error to that source. Under reach none and under a reach
// of that host, nothing leaves by the island's link but, under the reach,
// the guest's own packet from its own address, and nothing comes back to
// the guest. The namespace's own rp_filter is as the host's: loose on
// this host, so the raw table's lines alone are what drop them.
func TestAGuestsForgedSourcesCarryNothingOut(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("the VMM's own uid is mapped beside the guard's by root alone")
	}
	for _, tool := range []string{"iptables-restore", "ip6tables", "/dev/net/tun"} {
		if _, err := exec.LookPath(tool); err != nil && !strings.HasPrefix(tool, "/") {
			t.Skipf("this host has no %s: %v", tool, err)
		}
		if _, err := os.Stat(tool); err != nil && strings.HasPrefix(tool, "/") {
			t.Skipf("this host has no %s: %v", tool, err)
		}
	}
	for _, reach := range []string{ReachNone, ReachHosts} {
		cmd := exec.Command(os.Args[0], "-test.run=^$")
		cmd.Env = append(os.Environ(), forgedGuardMode+"="+reach)
		cmd.SysProcAttr = userNetAttr()
		cmd.SysProcAttr.UidMappings = append(cmd.SysProcAttr.UidMappings, syscall.SysProcIDMap{ContainerID: vmmUID, HostID: vmmUID, Size: 1})
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("reach %s: the stand-in guard: %v\n%s", reach, err, out)
		}
		left := "guard: nothing left the island's link"
		if reach == ReachHosts {
			left = "guard: the guest's own packet alone left the island's link"
		}
		for _, want := range []string{"guard: the real rules stand", left, "forger: nothing came back to the guest"} {
			if !strings.Contains(string(out), want) {
				t.Errorf("reach %s lacks %q:\n%s", reach, want, out)
			}
		}
	}
}

// forgedTarget is the outside host the forger writes to, which a reach of
// hosts allows.
var forgedTarget = netip.AddrFrom4([4]byte{203, 0, 113, 50})

func standInForgedGuard(reach string) int {
	fail := func(format string, args ...any) int {
		fmt.Printf("guard: "+format+"\n", args...)
		return 1
	}
	ctl, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	if err := linkUp(ctl, "lo"); err != nil {
		return fail("the loopback: %v", err)
	}
	// The reassembly timers, shortened to a second by a child in this
	// network namespace with a mount and process namespace of its own, for
	// the proc it writes them through.
	timers := exec.Command(os.Args[0], "-test.run=^$")
	timers.Env = []string{timersMode + "=1"}
	timers.SysProcAttr = &syscall.SysProcAttr{Cloneflags: syscall.CLONE_NEWNS | syscall.CLONE_NEWPID, Pdeathsig: syscall.SIGKILL}
	if out, err := timers.CombinedOutput(); err != nil {
		return fail("shortening the reassembly timers: %v %s", err, out)
	}
	// ext0 is the island's way out: an L3 tun the test reads, holding the
	// island's address, the default route through it.
	ext, err := unix.Open("/dev/net/tun", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	ifr, _ := unix.NewIfreq("ext0")
	ifr.SetUint16(unix.IFF_TUN | unix.IFF_NO_PI)
	if err := unix.IoctlIfreq(ext, unix.TUNSETIFF, ifr); err != nil {
		return fail("ext0: %v", err)
	}
	if err := setAddress(ctl, "ext0", netip.MustParseAddr("198.51.100.1"), netip.MustParseAddr("255.255.255.0")); err != nil {
		return fail("%v", err)
	}
	if err := linkUp(ctl, "ext0"); err != nil {
		return fail("%v", err)
	}
	if err := defaultRoute(ctl, netip.MustParseAddr("198.51.100.254")); err != nil {
		return fail("%v", err)
	}
	// The island holds IPv6 too, so a refusal of the guard's own would have
	// a way back to a forged IPv6 source.
	if err := v6Island("ext0", forgedGuardV6); err != nil {
		return fail("%v", err)
	}
	log := logx.New("cyfr-guard-test")
	isl := island{controlPlane: "192.0.2.1", routes: []string{"198.51.100.0/24"}, subnets: []string{"198.51.100.0/24"}, local: []string{"198.51.100.1"}}
	st, err := staticRules(log, isl)
	if err != nil {
		return fail("%v", err)
	}
	for _, r := range st.rules {
		ctx, cancel := bounded()
		_, err := tool(ctx, "", false, r.tool(), append([]string{"-w", "5"}, r.args...)...)
		cancel()
		if err != nil {
			return fail("%s: %v", r, err)
		}
	}
	dir, err := os.MkdirTemp("", "cyfr-guard-forged-")
	if err != nil {
		return fail("%v", err)
	}
	defer os.RemoveAll(dir)
	at := place{dir: dir, proc: "/proc"}
	if err := os.MkdirAll(at.routes(), 0o755); err != nil {
		return fail("%v", err)
	}
	lock, err := os.OpenFile(at.lock(), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return fail("%v", err)
	}
	rng, _ := ParseRange(st.rng)
	srv := newServer(log, "net:[test]", rng, kernelRoutes{set: &rulesOf{log: log, at: at, st: st, lock: lock, bound: applyTimeout}})
	fmt.Println("guard: the real rules stand")
	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	mine, theirs := os.NewFile(uintptr(pair[0]), "guard"), os.NewFile(uintptr(pair[1]), "forger")
	forger := exec.Command(os.Args[0], "-test.run=^$")
	forger.Env = []string{forgerMode + "=1"}
	forger.ExtraFiles = []*os.File{theirs}
	forger.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:  syscall.CLONE_NEWUSER | syscall.CLONE_NEWNET,
		UidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}, {ContainerID: vmmUID, HostID: vmmUID, Size: 1}},
		GidMappings: []syscall.SysProcIDMap{{ContainerID: 0, HostID: 0, Size: 1}},
		Pdeathsig:   syscall.SIGKILL,
	}
	var forgerOut bytes.Buffer
	forger.Stdout, forger.Stderr = &forgerOut, &forgerOut
	if err := forger.Start(); err != nil {
		return fail("%v", err)
	}
	defer func() { _ = forger.Process.Kill(); _ = forger.Wait(); fmt.Print(forgerOut.String()) }()
	theirs.Close()
	buf, oob := make([]byte, 1), make([]byte, unix.CmsgSpace(16))
	_, oobn, _, _, err := unix.Recvmsg(int(mine.Fd()), buf, oob, 0)
	if err != nil {
		return fail("%v", err)
	}
	msgs, _ := unix.ParseSocketControlMessage(oob[:oobn])
	fds, err := unix.ParseUnixRights(&msgs[0])
	if err != nil || len(fds) != 4 {
		return fail("descriptors %v %v", fds, err)
	}
	// Held until the admit is answered: a file no one holds may be closed
	// by its finalizer before the admit sends it.
	files := []*os.File{os.NewFile(uintptr(fds[0]), "netns"), os.NewFile(uintptr(fds[1]), "udp"), os.NewFile(uintptr(fds[2]), "tcp"), os.NewFile(uintptr(fds[3]), "netlink")}
	sock := filepath.Join(dir, "guard.sock")
	l, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: sock, Net: "unixpacket"})
	if err != nil {
		return fail("%v", err)
	}
	go func() {
		for {
			conn, err := l.AcceptUnix()
			if err != nil {
				return
			}
			go srv.serve(conn)
		}
	}()
	var addrs []netip.Addr
	if reach == ReachHosts {
		addrs = []netip.Addr{forgedTarget}
	}
	client := NewClient(sock, "net:[test]", nil)
	if _, err := client.AdmitMachine(testSpawn, vmmUID, reach, addrs, files[0], files[1], files[2], files[3]); err != nil {
		return fail("the admit: %v", err)
	}
	for _, f := range files {
		f.Close()
	}
	// The route forwards, as the guard's island does: by its own link's
	// forwarding, which the namespace's ip_forward would otherwise set.
	for _, name := range []string{outerName(0), "ext0"} {
		index, err := linkIndex(name)
		if err == nil {
			err = netlinkDo(unix.RTM_SETLINK, 0, inetConf(index, 1, 1))
		}
		if err != nil {
			return fail("forwarding on %s: %v", name, err)
		}
	}
	if err := unix.SetNonblock(ext, true); err != nil {
		return fail("%v", err)
	}
	if _, err := mine.Write([]byte{'g'}); err != nil {
		return fail("%v", err)
	}
	var leaving []string
	p := make([]byte, 4096)
	// Past the fragments' shortened reassembly, a second, and what follows.
	for end := time.Now().Add(4 * time.Second); time.Now().Before(end); {
		n, err := unix.Read(ext, p)
		if err != nil {
			time.Sleep(5 * time.Millisecond) // sleep-ok: a nonblocking tun's next packet
			continue
		}
		switch {
		case n >= 20 && p[0]>>4 == 4:
			leaving = append(leaving, fmt.Sprintf("proto %d %s -> %s %q", p[9], netip.AddrFrom4([4]byte(p[12:16])), netip.AddrFrom4([4]byte(p[16:20])), tagOf(p[:n])))
		case n >= 40 && p[0]>>4 == 6:
			from, to := netip.AddrFrom16([16]byte(p[8:24])), netip.AddrFrom16([16]byte(p[24:40]))
			// The kernel's own on the island's link (its solicitations
			// and reports) name no address of the guest's.
			if !from.IsLinkLocalUnicast() && !from.IsUnspecified() {
				leaving = append(leaving, fmt.Sprintf("next %d %s -> %s %q", p[6], from, to, tagOf(p[:n])))
			}
		}
	}
	switch {
	case len(leaving) == 0:
		fmt.Println("guard: nothing left the island's link")
	case len(leaving) == 1 && strings.Contains(leaving[0], "own-to-outside"):
		fmt.Println("guard: the guest's own packet alone left the island's link")
	default:
		fmt.Printf("guard: left the island's link: %v\n", leaving)
	}
	return 0
}

// forgedGuardV6 is the guard's IPv6 address on the island, and
// forgedTargetV6 an outside IPv6 host.
var (
	forgedGuardV6  = netip.MustParseAddr("2001:db8:100::1")
	forgedTargetV6 = netip.MustParseAddr("2001:db8:200::50")
)

// v6Island gives link name address a in a /64, at once (no duplicate
// detection), and the IPv6 default route through it.
func v6Island(name string, a netip.Addr) error {
	index, err := linkIndex(name)
	if err != nil {
		return err
	}
	b := make([]byte, unix.SizeofIfAddrmsg)
	b[0], b[1], b[2] = unix.AF_INET6, 64, unix.IFA_F_NODAD
	binary.NativeEndian.PutUint32(b[4:8], uint32(index))
	a16 := a.As16()
	b = rtattr(b, unix.IFA_LOCAL, a16[:])
	b = rtattr(b, unix.IFA_ADDRESS, a16[:])
	if err := netlinkDo(unix.RTM_NEWADDR, unix.NLM_F_CREATE|unix.NLM_F_EXCL, b); err != nil {
		return fmt.Errorf("%s's IPv6 address: %w", name, err)
	}
	rt := make([]byte, unix.SizeofRtMsg)
	rt[0], rt[4], rt[5], rt[6], rt[7] = unix.AF_INET6, unix.RT_TABLE_MAIN, unix.RTPROT_BOOT, unix.RT_SCOPE_UNIVERSE, unix.RTN_UNICAST
	var oif [4]byte
	binary.NativeEndian.PutUint32(oif[:], uint32(index))
	rt = rtattr(rt, unix.RTA_OIF, oif[:])
	if err := netlinkDo(unix.RTM_NEWROUTE, unix.NLM_F_CREATE|unix.NLM_F_EXCL, rt); err != nil {
		return fmt.Errorf("the IPv6 default route: %w", err)
	}
	return nil
}

// ipv6Frame is an Ethernet frame of one IPv6 UDP datagram of payload,
// from and to, its hop limit hop and its checksum set.
func ipv6Frame(dst, src net.HardwareAddr, from, to netip.Addr, hop byte, payload []byte) []byte {
	u := make([]byte, 8, 8+len(payload))
	binary.BigEndian.PutUint16(u[0:], 4444)
	binary.BigEndian.PutUint16(u[2:], 9)
	binary.BigEndian.PutUint16(u[4:], uint16(8+len(payload)))
	u = append(u, payload...)
	f16, t16 := from.As16(), to.As16()
	pseudo := append(append(append([]byte{}, f16[:]...), t16[:]...), 0, 0, byte(len(u)>>8), byte(len(u)), 0, 0, 0, 17)
	binary.BigEndian.PutUint16(u[6:], csum(append(pseudo, u...)))
	ip := make([]byte, 40)
	ip[0], ip[6], ip[7] = 0x60, 17, hop
	binary.BigEndian.PutUint16(ip[4:], uint16(len(u)))
	copy(ip[8:], f16[:])
	copy(ip[24:], t16[:])
	f := append(append(append([]byte{}, dst...), src...), 0x86, 0xdd)
	return append(append(f, ip...), u...)
}

// shortTimers shortens the reassembly timers of its network namespace,
// IPv4's, IPv6's and connection tracking's, to a second.
func shortTimers() int {
	proc, err := spaceProcOf()
	if err != nil {
		fmt.Println(err)
		return 1
	}
	for _, timer := range []string{"net/ipv4/ipfrag_time", "net/ipv6/ip6frag_time", "net/netfilter/nf_conntrack_frag6_timeout"} {
		if err := os.WriteFile(proc+"/sys/"+timer, []byte("1\n"), 0); err != nil {
			fmt.Println(err)
			return 1
		}
	}
	return 0
}

// fragmentData is a UDP datagram's first 400 bytes, the forger's tag
// first, whose header claims 2,000: what a first fragment carries.
func fragmentData(tag string) []byte {
	d := make([]byte, 400)
	binary.BigEndian.PutUint16(d[0:], 4444)
	binary.BigEndian.PutUint16(d[2:], 9)
	binary.BigEndian.PutUint16(d[4:], 2000)
	copy(d[8:], "forged:"+tag+":")
	return d
}

// firstFragment4 is an Ethernet frame of the first fragment of IPv4
// datagram id, from and to, more fragments to follow.
func firstFragment4(from, to netip.Addr, id uint16, tag string) []byte {
	f := ipv4Frame(GatewayMAC, GuestMAC, from, to, 17, fragmentData(tag))
	ip := f[14:34]
	binary.BigEndian.PutUint16(ip[4:], id)
	binary.BigEndian.PutUint16(ip[6:], 0x2000)
	binary.BigEndian.PutUint16(ip[10:], 0)
	binary.BigEndian.PutUint16(ip[10:], csum(ip))
	return f
}

// firstFragment6 is an Ethernet frame of the first fragment of IPv6
// datagram id, from and to, more fragments to follow.
func firstFragment6(from, to netip.Addr, id uint32, tag string) []byte {
	frag := []byte{17, 0, 0, 1, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(frag[4:], id)
	payload := append(frag, fragmentData(tag)...)
	f16, t16 := from.As16(), to.As16()
	ip := make([]byte, 40)
	ip[0], ip[6], ip[7] = 0x60, 44, 64
	binary.BigEndian.PutUint16(ip[4:], uint16(len(payload)))
	copy(ip[8:], f16[:])
	copy(ip[24:], t16[:])
	f := append(append(append([]byte{}, GatewayMAC...), GuestMAC...), 0x86, 0xdd)
	return append(append(f, ip...), payload...)
}

// tagOf is the forger's tag a packet carries or quotes, "" for none.
func tagOf(p []byte) string {
	if i := bytes.Index(p, []byte("forged:")); i >= 0 {
		rest := p[i+len("forged:"):]
		if j := bytes.IndexByte(rest, ':'); j >= 0 {
			return string(rest[:j])
		}
	}
	return ""
}

// standInForger is a guest with a broken kernel at its tap: it hands up as
// a VMM does and, once routed, writes frames with sources of its choosing.
func standInForger() int {
	fail := func(format string, args ...any) int {
		fmt.Printf("forger: "+format+"\n", args...)
		return 1
	}
	guard := os.NewFile(3, "guard")
	netns, _ := unix.Open("/proc/thread-self/ns/net", unix.O_RDONLY|unix.O_CLOEXEC, 0)
	ctl, _ := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err := linkUp(ctl, "lo"); err != nil {
		return fail("%v", err)
	}
	at := &unix.SockaddrInet4{Port: 53, Addr: MachineNames.As4()}
	udp, _ := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	tcp, _ := unix.Socket(unix.AF_INET, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	for _, fd := range []int{udp, tcp} {
		_ = unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_FREEBIND, 1)
		if err := unix.Bind(fd, at); err != nil {
			return fail("%v", err)
		}
	}
	_ = unix.Listen(tcp, 4)
	nl, _ := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_ROUTE)
	if err := unix.Sendmsg(int(guard.Fd()), []byte{'r'}, unix.UnixRights(netns, udp, tcp, nl), nil, 0); err != nil {
		return fail("%v", err)
	}
	word := make([]byte, 1)
	if _, err := guard.Read(word); err != nil || word[0] != 'g' {
		return fail("no word: %v", err)
	}
	if err := syscall.Setresuid(vmmUID, vmmUID, vmmUID); err != nil {
		return fail("%v", err)
	}
	tap, err := unix.Open("/dev/net/tun", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	attach, _ := unix.NewIfreq(MachineTap)
	attach.SetUint16(unix.IFF_TAP | unix.IFF_NO_PI)
	if err := unix.IoctlIfreq(tap, unix.TUNSETIFF, attach); err != nil {
		return fail("%v", err)
	}
	_ = unix.SetNonblock(tap, true)
	rng, _ := ParseRange("10.213.0.0/16")
	gateway, inner := slotAddresses(rng, 0)
	_, another := slotAddresses(rng, 1)
	udpFrame := func(from, to netip.Addr, ttl byte, tag string) []byte {
		payload := []byte("forged:" + tag + ":")
		payload = append(payload, bytes.Repeat([]byte("x"), 200)...)
		u := make([]byte, 8)
		binary.BigEndian.PutUint16(u[0:], 4444)
		binary.BigEndian.PutUint16(u[2:], 9)
		binary.BigEndian.PutUint16(u[4:], uint16(8+len(payload)))
		f := ipv4Frame(GatewayMAC, GuestMAC, from, to, 17, append(u, payload...))
		f[14+8] = ttl
		binary.BigEndian.PutUint16(f[14+10:], 0)
		binary.BigEndian.PutUint16(f[14+10:], csum(f[14:34]))
		return f
	}
	for _, from := range []netip.Addr{netip.MustParseAddr("203.0.113.9"), netip.MustParseAddr("192.0.2.1"),
		netip.MustParseAddr("198.51.100.77"), netip.MustParseAddr("169.254.169.254"), another} {
		for _, w := range []struct {
			to  netip.Addr
			ttl byte
			how string
		}{{gateway, 64, "to-guard"}, {forgedTarget, 1, "ttl-1"}, {forgedTarget, 64, "forwarded"}} {
			if _, err := unix.Write(tap, udpFrame(from, w.to, w.ttl, from.String()+"-"+w.how)); err != nil {
				return fail("%v", err)
			}
		}
	}
	v6payload := func(tag string) []byte {
		return append([]byte("forged:"+tag+":"), bytes.Repeat([]byte("x"), 200)...)
	}
	for _, from := range []netip.Addr{netip.MustParseAddr("2001:db8:999::9"), netip.MustParseAddr("2001:db8:100::77")} {
		for _, w := range []struct {
			to  netip.Addr
			hop byte
			how string
		}{{forgedGuardV6, 64, "to-guard"}, {forgedTargetV6, 1, "hop-1"}, {forgedTargetV6, 64, "forwarded"}} {
			if _, err := unix.Write(tap, ipv6Frame(GatewayMAC, GuestMAC, from, w.to, w.hop, v6payload(from.String()+"-"+w.how))); err != nil {
				return fail("%v", err)
			}
		}
	}
	// First fragments, never completed, from forged sources of each family.
	fragments := [][]byte{
		firstFragment4(netip.MustParseAddr("203.0.113.9"), gateway, 1, "frag4-to-guard"),
		firstFragment4(netip.MustParseAddr("203.0.113.9"), forgedTarget, 2, "frag4-forwarded"),
		firstFragment6(netip.MustParseAddr("2001:db8:999::9"), forgedGuardV6, 3, "frag6-to-guard"),
		firstFragment6(netip.MustParseAddr("2001:db8:999::9"), forgedTargetV6, 4, "frag6-forwarded"),
	}
	for _, f := range fragments {
		if _, err := unix.Write(tap, f); err != nil {
			return fail("%v", err)
		}
	}
	if _, err := unix.Write(tap, udpFrame(inner, forgedTarget, 64, "own-to-outside")); err != nil {
		return fail("%v", err)
	}
	var back []string
	frame := make([]byte, 4096)
	for end := time.Now().Add(1500 * time.Millisecond); time.Now().Before(end); {
		n, err := unix.Read(tap, frame)
		if err != nil {
			time.Sleep(5 * time.Millisecond) // sleep-ok: a nonblocking tap's next frame
			continue
		}
		if n > 34 && (frame[12] == 0x08 && frame[13] == 0 || frame[12] == 0x86 && frame[13] == 0xdd) {
			// The refusal of the guest's own packet under reach none is its
			// own to have; a forged one's answer is not.
			if tag := tagOf(frame[14:n]); tag != "" && tag != "own-to-outside" {
				back = append(back, tag)
			}
		}
	}
	if len(back) == 0 {
		fmt.Println("forger: nothing came back to the guest")
	} else {
		fmt.Printf("forger: came back to the guest: %v\n", back)
	}
	select {}
}

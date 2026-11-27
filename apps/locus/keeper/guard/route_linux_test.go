// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/logx"
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
// stand-in VMM in place of the space. The guard makes the pair, the tap it
// moves into the VMM's namespace and the bridge there; the stand-in VMM,
// the tap's owner, attaches to it by name and, as a guest would, asks for
// the gateway's hardware address in an ARP request written to the tap,
// which the guard's end answers through the bridge and the pair. A name
// asked on MachineNames:53 is answered by the guard. When the keeper's
// connection ends, the pair and the tap's name in the guard's namespace
// are gone.
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
	for _, want := range []string{"guard: admitted 10.213.0.2 behind 10.213.0.1", "vmm: attached to tap0 as its owner",
		"vmm: the gateway answered the guest's ARP request through the bridge", "vmm: name: answer",
		"guard: the pair and the tap are gone"} {
		if !strings.Contains(string(out), want) {
			t.Errorf("lacks %q:\n%s", want, out)
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
	ifr, _ := unix.NewIfreq("lo")
	_ = unix.IoctlIfreq(ctl, unix.SIOCGIFFLAGS, ifr)
	ifr.SetUint16(ifr.Uint16() | unix.IFF_UP)
	if err := unix.IoctlIfreq(ctl, unix.SIOCSIFFLAGS, ifr); err != nil {
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
		Cloneflags:  syscall.CLONE_NEWUSER | syscall.CLONE_NEWNET,
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
	buf, oob := make([]byte, 1), make([]byte, unix.CmsgSpace(12))
	_, oobn, _, _, err := unix.Recvmsg(int(mine.Fd()), buf, oob, 0)
	if err != nil {
		return fail("the VMM's descriptors: %v", err)
	}
	msgs, _ := unix.ParseSocketControlMessage(oob[:oobn])
	fds, err := unix.ParseUnixRights(&msgs[0])
	if err != nil || len(fds) != 3 {
		return fail("descriptors %v %v", fds, err)
	}
	netns, udp, tcp := os.NewFile(uintptr(fds[0]), "netns"), os.NewFile(uintptr(fds[1]), "udp"), os.NewFile(uintptr(fds[2]), "tcp")
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
	m, err := client.AdmitMachine(testSpawn, vmmUID, ReachIsland, nil, netns, udp, tcp)
	if err != nil {
		return fail("the admit: %v", err)
	}
	fmt.Printf("guard: admitted %s behind %s\n", m.Inner, m.Gateway)
	netns.Close()
	udp.Close()
	tcp.Close()
	if _, err := net.InterfaceByName(tapName(0)); err == nil {
		return fail("the tap's name stays in the guard's namespace")
	}
	if _, err := mine.Write([]byte{'g'}); err != nil {
		return fail("%v", err)
	}
	done := make([]byte, 1)
	if _, err := mine.Read(done); err != nil {
		fmt.Print(vmmOut.String())
		return fail("the VMM's word: %v", err)
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

// standInVMM hands up its namespace and two name sockets bound to
// MachineNames:53, then, once the route is made, attaches to the tap as
// its owner and speaks for a guest at the route's inner address.
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
	ifr, _ := unix.NewIfreq("lo")
	_ = unix.IoctlIfreq(ctl, unix.SIOCGIFFLAGS, ifr)
	ifr.SetUint16(ifr.Uint16() | unix.IFF_UP)
	if err := unix.IoctlIfreq(ctl, unix.SIOCSIFFLAGS, ifr); err != nil {
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
	if err := unix.Sendmsg(int(guard.Fd()), []byte{'r'}, unix.UnixRights(netns, udp, tcp), nil, 0); err != nil {
		return fail("%v", err)
	}
	unix.Close(udp)
	unix.Close(tcp)
	unix.Close(netns)
	word := make([]byte, 1)
	if _, err := guard.Read(word); err != nil || word[0] != 'g' {
		return fail("no word: %v", err)
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
	rng, _ := ParseRange("10.213.0.0/16")
	gateway, inner := slotAddresses(rng, 0)
	guest := []byte{0x02, 0, 0, 0, 0, 0x02}
	g4, i4 := gateway.As4(), inner.As4()
	arp := append([]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, guest...)
	arp = append(arp, 0x08, 0x06, 0, 1, 0x08, 0, 6, 4, 0, 1)
	arp = append(arp, guest...)
	arp = append(arp, i4[:]...)
	arp = append(arp, 0, 0, 0, 0, 0, 0)
	arp = append(arp, g4[:]...)
	if err := unix.SetNonblock(tap, true); err != nil {
		return fail("%v", err)
	}
	frame := make([]byte, 2048)
	answered := false
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline) && !answered; {
		if _, err := unix.Write(tap, arp); err != nil {
			return fail("writing the ARP request: %v", err)
		}
		for end := time.Now().Add(200 * time.Millisecond); time.Now().Before(end); {
			n, err := unix.Read(tap, frame)
			if err != nil {
				time.Sleep(5 * time.Millisecond) // sleep-ok: a nonblocking tap's next frame
				continue
			}
			f := frame[:n]
			if n >= 42 && f[12] == 0x08 && f[13] == 0x06 && f[21] == 2 && bytes.Equal(f[28:32], g4[:]) && bytes.Equal(f[32:38], guest) {
				answered = true
				break
			}
		}
	}
	if !answered {
		return fail("the gateway did not answer the guest's ARP request")
	}
	fmt.Println("vmm: the gateway answered the guest's ARP request through the bridge")
	q, err := net.Dial("udp", netip.AddrPortFrom(MachineNames, 53).String())
	if err != nil {
		return fail("%v", err)
	}
	_ = q.SetDeadline(time.Now().Add(3 * time.Second))
	_, _ = q.Write([]byte("q"))
	got := make([]byte, 16)
	k, err := q.Read(got)
	if err != nil {
		return fail("the name: %v", err)
	}
	fmt.Printf("vmm: name: %s\n", got[:k])
	if _, err := guard.Write([]byte{'d'}); err != nil {
		return fail("%v", err)
	}
	select {}
}

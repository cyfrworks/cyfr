// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// guard-role-space stands in for a keeper starting a role's service
// process behind its island's guard, for the builder image suite
// (isolation.py beside it), which builds it with the residue canary
// (stack.py) and runs it as root in the island's service container:
//
//	guard-role-space <control socket> <spawn id> <port> <private> <other port>
//
// It makes a space as the keeper does (a user and network namespace of its
// own, its loopback up and its two name sockets bound to 127.0.0.11:53),
// asks the guard over its control for the space's route of reach `role` at
// <port>, private or not, and prints the guard's answer, `answer=<type>`
// and the reason of a refusal. Admitted, the space listens on <port> and on
// <other port>, answering each connection with `role <port>` or
// `other <port>`, and prints `ready`. It then reads commands on its input:
//
//	probe <address:port>…   the space connects to each and prints
//	                        `<address:port>=<code>` for each, then `probed`
//	clear                   the route is cleared and the answer printed
//
// and ends at `clear` or at the end of its input, its control connection
// with it. Only the standard library, as it is built outside any module.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	childMode = "GUARD_ROLE_SPACE_CHILD"
	// CAP_NET_BIND_SERVICE and CAP_NET_ADMIN, which package syscall does
	// not name.
	capNetBindService = 10
	capNetAdmin       = 12
)

func main() {
	if os.Getenv(childMode) != "" {
		os.Exit(space())
	}
	os.Exit(keeper())
}

func fail(format string, args ...any) int {
	fmt.Printf("error="+format+"\n", args...)
	return 1
}

// keeper makes the space, admits its route and relays the commands.
func keeper() int {
	if len(os.Args) != 6 {
		return fail("usage: guard-role-space <socket> <spawn id> <port> <private> <other port>")
	}
	socket, spawnID := os.Args[1], os.Args[2]
	port, err := strconv.Atoi(os.Args[3])
	if err != nil {
		return fail("port: %v", err)
	}
	private, err := strconv.ParseBool(os.Args[4])
	if err != nil {
		return fail("private: %v", err)
	}
	pair, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	mine, theirs := os.NewFile(uintptr(pair[0]), "keeper"), os.NewFile(uintptr(pair[1]), "space")
	child := exec.Command(os.Args[0], os.Args[3], os.Args[5])
	child.Env = []string{childMode + "=1"}
	child.Stdout, child.Stderr = os.Stdout, os.Stderr
	child.ExtraFiles = []*os.File{theirs}
	// As the keeper's stage does, the space maps no id (mapping root would
	// take CAP_SETFCAP, which the service lacks) and keeps, inside its own
	// namespace only, what it needs there: its loopback up and its name
	// sockets bound.
	child.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:  syscall.CLONE_NEWUSER | syscall.CLONE_NEWNET,
		AmbientCaps: []uintptr{capNetBindService, capNetAdmin},
		Pdeathsig:   syscall.SIGKILL,
	}
	if err := child.Start(); err != nil {
		return fail("the space: %v", err)
	}
	defer func() { _ = child.Process.Kill(); _ = child.Wait() }()
	theirs.Close()
	buf, oob := make([]byte, 1), make([]byte, syscall.CmsgSpace(12))
	_, oobn, _, _, err := syscall.Recvmsg(int(mine.Fd()), buf, oob, 0)
	if err != nil {
		return fail("the space's descriptors: %v", err)
	}
	msgs, err := syscall.ParseSocketControlMessage(oob[:oobn])
	if err != nil || len(msgs) != 1 {
		return fail("the space's descriptors: %v", err)
	}
	fds, err := syscall.ParseUnixRights(&msgs[0])
	if err != nil || len(fds) != 3 {
		return fail("the space's descriptors: %v %v", fds, err)
	}

	conn, err := net.Dial("unixpacket", socket)
	if err != nil {
		return fail("the guard: %v", err)
	}
	defer conn.Close()
	control := conn.(*net.UnixConn)
	if _, err := read(control); err != nil {
		return fail("the guard's hello: %v", err)
	}
	admit, _ := json.Marshal(map[string]any{"v": 4, "type": "admit", "spawn_id": spawnID, "reach": "role", "port": port, "private": private})
	if _, _, err := control.WriteMsgUnix(admit, syscall.UnixRights(fds...), nil); err != nil {
		return fail("the admit: %v", err)
	}
	for _, fd := range fds {
		syscall.Close(fd)
	}
	answer, err := read(control)
	if err != nil {
		return fail("the admit's answer: %v", err)
	}
	fmt.Println(answered(answer))
	if answer["type"] != "admitted" {
		return 1
	}
	commands := bufio.NewReader(os.Stdin)
	if _, err := mine.Write([]byte("go\n")); err != nil {
		return fail("%v", err)
	}
	for {
		line, err := commands.ReadString('\n')
		if err != nil {
			return 0
		}
		if strings.TrimSpace(line) == "clear" {
			clear, _ := json.Marshal(map[string]any{"v": 4, "type": "clear", "spawn_id": spawnID})
			if _, err := control.Write(clear); err != nil {
				return fail("the clear: %v", err)
			}
			answer, err := read(control)
			if err != nil {
				return fail("the clear's answer: %v", err)
			}
			fmt.Println(answered(answer))
			return 0
		}
		if _, err := mine.Write([]byte(line)); err != nil {
			return fail("%v", err)
		}
	}
}

// answered is the line naming an answer: `answer=<type> <reason>`.
func answered(m map[string]any) string {
	kind, _ := m["type"].(string)
	reason, _ := m["reason"].(string)
	return "answer=" + kind + " " + reason
}

// read reads one packet of the control as an object.
func read(c *net.UnixConn) (map[string]any, error) {
	_ = c.SetReadDeadline(time.Now().Add(40 * time.Second))
	buf := make([]byte, 64<<10)
	n, err := c.Read(buf)
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(buf[:n], &m); err != nil {
		return nil, err
	}
	return m, nil
}

// space runs in the space: it hands its namespace and name sockets up,
// then listens and probes as the keeper relays.
func space() int {
	keeper := os.NewFile(3, "keeper")
	if err := loopbackUp(); err != nil {
		return fail("the loopback: %v", err)
	}
	netns, err := syscall.Open("/proc/thread-self/ns/net", syscall.O_RDONLY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return fail("%v", err)
	}
	at := &syscall.SockaddrInet4{Port: 53, Addr: [4]byte{127, 0, 0, 11}}
	udp, _ := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)
	tcp, _ := syscall.Socket(syscall.AF_INET, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err := syscall.Bind(udp, at); err != nil {
		return fail("binding: %v", err)
	}
	if err := syscall.Bind(tcp, at); err != nil {
		return fail("binding: %v", err)
	}
	if err := syscall.Listen(tcp, 4); err != nil {
		return fail("listening: %v", err)
	}
	if err := syscall.Sendmsg(int(keeper.Fd()), []byte{'r'}, syscall.UnixRights(netns, udp, tcp), nil, 0); err != nil {
		return fail("%v", err)
	}
	commands := bufio.NewReader(keeper)
	if line, err := commands.ReadString('\n'); err != nil || line != "go\n" {
		return 0
	}
	for i, port := range os.Args[1:3] {
		word := []string{"role", "other"}[i] + " " + port
		l, err := net.Listen("tcp4", "0.0.0.0:"+port)
		if err != nil {
			return fail("listening on %s: %v", port, err)
		}
		go func() {
			for {
				c, err := l.Accept()
				if err != nil {
					return
				}
				_, _ = c.Write([]byte(word + "\n"))
				c.Close()
			}
		}()
	}
	fmt.Println("ready")
	for {
		line, err := commands.ReadString('\n')
		if err != nil {
			return 0
		}
		fields := strings.Fields(line)
		if len(fields) == 0 || fields[0] != "probe" {
			return fail("unknown command %q", line)
		}
		for _, target := range fields[1:] {
			fmt.Printf("%s=%s\n", target, dial(target))
		}
		fmt.Println("probed")
	}
}

// dial connects to target and names the outcome as the suites' connect
// probe does: connected, an errno's name or ETIMEDOUT.
func dial(target string) string {
	c, err := net.DialTimeout("tcp4", target, 4*time.Second)
	if err == nil {
		c.Close()
		return "connected"
	}
	for _, e := range []syscall.Errno{syscall.EHOSTUNREACH, syscall.ECONNREFUSED, syscall.ENETUNREACH, syscall.EACCES, syscall.EPERM} {
		if errors.Is(err, e) {
			return map[syscall.Errno]string{syscall.EHOSTUNREACH: "EHOSTUNREACH", syscall.ECONNREFUSED: "ECONNREFUSED",
				syscall.ENETUNREACH: "ENETUNREACH", syscall.EACCES: "EACCES", syscall.EPERM: "EPERM"}[e]
		}
	}
	var timeout net.Error
	if errors.As(err, &timeout) && timeout.Timeout() {
		return "ETIMEDOUT"
	}
	return strings.ReplaceAll(err.Error(), " ", "_")
}

// loopbackUp sets the space's loopback up, which its name sockets' address
// needs.
func loopbackUp() error {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	var ifr struct {
		name  [syscall.IFNAMSIZ]byte
		flags uint16
		_     [22]byte
	}
	copy(ifr.name[:], "lo")
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.SIOCGIFFLAGS, uintptr(unsafe.Pointer(&ifr))); e != 0 {
		return e
	}
	ifr.flags |= syscall.IFF_UP
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.SIOCSIFFLAGS, uintptr(unsafe.Pointer(&ifr))); e != 0 {
		return e
	}
	return nil
}

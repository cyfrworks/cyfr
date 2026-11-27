// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package guard

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

// What the ingress mode's forger writes beside the forged frames: ARP
// requests from this many senders, and this many router advertisements.
const (
	ingressARP     = 64
	ingressAdverts = 16
)

// guestLinkLocal is a link-local IPv6 address of the guest's own, as its
// card would take one if its IPv6 were not off.
var guestLinkLocal = netip.MustParseAddr("fe80::400:aff:fe00:2")

// netCounters are the calling thread's network namespace's counts of what
// reached its IP layers and its reassembly: IPv4's received packets and
// reassembly requests, failures and timeouts, IPv6's received packets and
// reassembly requests, and the memory each family's reassembly holds now.
func netCounters() (map[string]uint64, error) {
	out := map[string]uint64{}
	snmp, err := os.ReadFile("/proc/self/net/snmp")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, line := range strings.Split(string(snmp), "\n") {
		rest, ok := strings.CutPrefix(line, "Ip: ")
		if !ok {
			continue
		}
		fields := strings.Fields(rest)
		if names == nil {
			names = fields
			continue
		}
		for i, v := range fields {
			n, _ := strconv.ParseUint(v, 10, 64)
			out["Ip"+names[i]] = n
		}
	}
	snmp6, err := os.Open("/proc/self/net/snmp6")
	if err != nil {
		return nil, err
	}
	defer snmp6.Close()
	s := bufio.NewScanner(snmp6)
	for s.Scan() {
		f := strings.Fields(s.Text())
		if len(f) == 2 {
			n, _ := strconv.ParseUint(f[1], 10, 64)
			out[f[0]] = n
		}
	}
	for file, tag := range map[string]string{"/proc/self/net/sockstat": "FRAG:", "/proc/self/net/sockstat6": "FRAG6:"} {
		raw, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		for _, line := range strings.Split(string(raw), "\n") {
			if rest, ok := strings.CutPrefix(line, tag+" "); ok {
				f := strings.Fields(rest)
				if len(f) == 4 && f[2] == "memory" {
					n, _ := strconv.ParseUint(f[3], 10, 64)
					out[strings.TrimSuffix(tag, ":")+"memory"] = n
				}
			}
		}
	}
	return out, nil
}

// ingressCounts are the packets each ingress filter of link index matched,
// by its priority, as the kernel's dump of them counts its action.
func ingressCounts(index int32) (map[uint16]uint64, error) {
	fd, err := nlSocket(unix.NETLINK_ROUTE)
	if err != nil {
		return nil, err
	}
	defer unix.Close(fd)
	counts := map[uint16]uint64{}
	err = dump(fd, unix.RTM_GETTFILTER, tcmsg(index, 0, tcIngressHandle, 0), func(m syscall.NetlinkMessage) {
		if len(m.Data) < sizeofTcMsg {
			return
		}
		prio := uint16(binary.NativeEndian.Uint32(m.Data[16:20]) >> 16)
		for _, a := range attrs(m.Data[sizeofTcMsg:]) {
			if attrType(a) != tcaOptions {
				continue
			}
			for _, o := range attrs(a[2]) {
				if attrType(o) != flowerAct {
					continue
				}
				for _, act := range attrs(o[2]) {
					for _, part := range attrs(act[2]) {
						if attrType(part) != 4 { // TCA_ACT_STATS
							continue
						}
						for _, st := range attrs(part[2]) {
							if attrType(st) == 1 && len(st[2]) >= 12 { // TCA_STATS_BASIC
								counts[prio] += uint64(binary.NativeEndian.Uint32(st[2][8:12]))
							}
						}
					}
				}
			}
		}
	})
	return counts, err
}

// reportIngress says, after the forger's frames, what reached the guard's
// namespace's IP layers and reassembly since before (netCounters), and
// what the ingress filters of the machine's route's end counted.
func reportIngress(before map[string]uint64) int {
	after, err := netCounters()
	if err != nil {
		fmt.Printf("guard: %v\n", err)
		return 1
	}
	moved := []string{}
	for _, k := range []string{"IpReasmReqds", "IpReasmFails", "IpReasmTimeout", "Ip6InReceives", "Ip6ReasmReqds", "Ip6ReasmFails", "Ip6ReasmTimeout"} {
		if after[k] != before[k] {
			moved = append(moved, fmt.Sprintf("%s %d->%d", k, before[k], after[k]))
		}
	}
	if len(moved) == 0 {
		fmt.Println("guard: nothing reached the reassembly or IPv6")
	} else {
		fmt.Printf("guard: reached: %v\n", moved)
	}
	if after["FRAGmemory"] == 0 && after["FRAG6memory"] == 0 {
		fmt.Println("guard: the reassembly holds no memory")
	} else {
		fmt.Printf("guard: the reassembly holds %d and %d bytes\n", after["FRAGmemory"], after["FRAG6memory"])
	}
	index, err := linkIndex(outerName(0))
	if err != nil {
		fmt.Printf("guard: %v\n", err)
		return 1
	}
	counts, err := ingressCounts(index)
	if err != nil {
		fmt.Printf("guard: the ingress filters' counts: %v\n", err)
		return 1
	}
	fmt.Printf("guard: ingress fragments %d whole %d other %d\n", counts[1], counts[2], counts[3])
	return 0
}

// From a machine's route only a whole IPv4 packet enters the guard's
// namespace: a guest's unfinished fragments, first, middle, last and with
// options, from its own address and from forged ones, of both families,
// reach neither its reassembly nor its IPv6, which hold nothing of them;
// its tagged frames, in one VLAN tag and two, its ARP flood and its router
// advertisements are dropped at the ingress with every other frame; and
// its own whole datagram still leaves under a reach that allows it. Run as
// the forged-source test runs, on the real rules and kernel.
func TestAMachinesRouteLetsOnlyAWholeIPv4PacketIn(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("the VMM's own uid is mapped beside the guard's by root alone")
	}
	for _, tool := range []string{"iptables-restore", "ip6tables"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("this host has no %s: %v", tool, err)
		}
	}
	if _, err := os.Stat("/dev/net/tun"); err != nil {
		t.Skipf("this host has no /dev/net/tun: %v", err)
	}
	// The forger's frames the ingress counts: IPv4 fragments, forged and
	// its own, first, middle, last and with options; whole IPv4 datagrams,
	// forged and its own; and every other frame, IPv6 whole and in
	// fragments, tagged frames (judged by their tag), ARP and router
	// advertisements.
	const fragments, whole, other = 8, 16, 6 + 4 + 7 + ingressARP + ingressAdverts
	for _, reach := range []string{ReachNone, ReachHosts} {
		cmd := exec.Command(os.Args[0], "-test.run=^$")
		cmd.Env = append(os.Environ(), forgedGuardMode+"="+reach+"+ingress")
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
		for _, want := range []string{left, "guard: nothing reached the reassembly or IPv6", "guard: the reassembly holds no memory"} {
			if !strings.Contains(string(out), want) {
				t.Errorf("reach %s lacks %q:\n%s", reach, want, out)
			}
		}
		var f, w, o int
		line := ""
		for _, l := range strings.Split(string(out), "\n") {
			if strings.HasPrefix(l, "guard: ingress ") {
				line = l
			}
		}
		t.Logf("reach %s: %s", reach, line)
		if _, err := fmt.Sscanf(line, "guard: ingress fragments %d whole %d other %d", &f, &w, &o); err != nil || f < fragments || w < whole || o < other {
			t.Errorf("reach %s: the ingress counted %q, want at least %d fragments dropped, %d whole let in, %d other dropped:\n%s",
				reach, line, fragments, whole, other, out)
		}
	}
}

// standInProbe tries the start's check in a namespace of its own, as the
// guard does, with the kernel's own names and then with a classifier no
// kernel has, and says what each answered and whether its pair was left
// after each.
func standInProbe() int {
	ctl, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM|unix.SOCK_CLOEXEC, 0)
	if err == nil {
		err = linkUp(ctl, "lo")
	}
	if err != nil {
		fmt.Printf("probe: %v\n", err)
		return 1
	}
	left := func(after string) {
		if _, err := linkIndex(probeName); err == nil {
			fmt.Printf("probe: its pair is left after %s\n", after)
		}
	}
	fmt.Printf("probe: the kernel's own: %q\n", probeMachines())
	left("the kernel's own try")
	flowerKind = "cyfr-no-such-classifier"
	fmt.Printf("probe: no such classifier: %q\n", probeMachines())
	left("a try that fails")
	return 0
}

// The guard's start tries what a machine's route's end is given on a pair
// of its own: this kernel gives all of it, and where a call fails (here a
// classifier the kernel does not have) the guard says why it routes no
// machine, and leaves nothing of its try.
func TestTheGuardsStartTriesAMachinesIngressFilter(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("a pair of the guard's own is made by root alone")
	}
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), probeMode+"=1")
	cmd.SysProcAttr = userNetAttr()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("the probe: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), `probe: the kernel's own: ""`) {
		t.Errorf("this kernel does not hold a machine's route to whole IPv4 packets:\n%s", out)
	}
	if !strings.Contains(string(out), "probe: no such classifier: \"the guard routes no machine: this kernel cannot hold a machine's route to whole IPv4 packets at its ingress (it needs the kernel's modules sch_ingress, cls_flower and act_gact)") {
		t.Errorf("a classifier the kernel lacks did not refuse machines:\n%s", out)
	}
	if strings.Contains(string(out), "its pair is left") {
		t.Errorf("the try left its pair:\n%s", out)
	}
}

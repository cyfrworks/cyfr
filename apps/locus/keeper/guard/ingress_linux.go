// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package guard

import (
	"encoding/binary"
	"errors"
	"fmt"

	"golang.org/x/sys/unix"
)

// What enters from a machine's route. A guest writes any frame it likes to
// its tap, and in the guard's namespace, where connection tracking is on,
// every IPv4 and IPv6 fragment is held for reassembly before any iptables
// line sees it: in memory the island and every route share, 4 MiB a
// family, for 30 and 60 seconds. So on a machine's route's guard end only a
// whole IPv4 packet enters, judged at ingress, before the kernel's IP
// layer, its defragmentation and netfilter: an IPv4 fragment, first or
// later, from any source, is dropped, and so is every other frame, IPv6,
// ARP and every other type alike. A machine's route has fixed neighbours
// on both its ends and needs nothing else. It is the traffic control
// layer's ingress qdisc with three flower filters, each with the generic
// action:
//
//	prio 1  protocol ip   flower ip_flags frag  action drop
//	prio 2  protocol ip   flower                action ok
//	prio 3  protocol all  flower                action drop
//
// The guard makes them over the route netlink it already speaks, before the
// end comes up, so nothing of the guest's passes unfiltered; they go with
// the end. It needs the host kernel's ingress qdisc, flower classifier and
// generic action, which it tries at its start on a pair of its own
// (probeMachines): a guard whose kernel lacks one routes no machine, says
// so in its hello, and refuses each machine's admit.

// The traffic control layer's names and numbers (linux/pkt_sched.h,
// linux/pkt_cls.h, linux/tc_act/tc_gact.h), which golang.org/x/sys does
// not carry.
const (
	tcIngressParent = 0xfffffff1 // TC_H_INGRESS
	tcIngressHandle = 0xffff0000 // ffff:, the ingress qdisc's
	sizeofTcMsg     = 20
	tcaKind         = 1 // TCA_KIND
	tcaOptions      = 2 // TCA_OPTIONS
	flowerAct       = 3 // TCA_FLOWER_ACT
	flowerKeyFlags  = 47
	flowerFlagsMask = 48
	flowerFragment  = 1 // TCA_FLOWER_KEY_FLAGS_IS_FRAGMENT
	actKind         = 1 // TCA_ACT_KIND
	actOptions      = 2 // TCA_ACT_OPTIONS
	gactParms       = 2 // TCA_GACT_PARMS
	actOK           = 0 // TC_ACT_OK
	actShot         = 2 // TC_ACT_SHOT
	ethPIP          = 0x0800
	ethPAll         = 0x0003
)

// Seams of the filter's making: the kinds the kernel is asked for, which a
// test names wrongly to make the start's check fail.
var (
	ingressKind = "ingress"
	flowerKind  = "flower"
	gactKind    = "gact"
)

// tcmsg is a struct tcmsg for link index, of handle and parent, info its
// last word (a filter's priority and protocol).
func tcmsg(index int32, handle, parent, info uint32) []byte {
	b := make([]byte, sizeofTcMsg)
	binary.NativeEndian.PutUint32(b[4:8], uint32(index))
	binary.NativeEndian.PutUint32(b[8:12], handle)
	binary.NativeEndian.PutUint32(b[12:16], parent)
	binary.NativeEndian.PutUint32(b[16:20], info)
	return b
}

// filterInfo is a filter's tcm_info: its priority above, its protocol in
// network order below.
func filterInfo(prio uint16, protocol uint16) uint32 {
	var p [2]byte
	binary.BigEndian.PutUint16(p[:], protocol)
	return uint32(prio)<<16 | uint32(binary.NativeEndian.Uint16(p[:]))
}

// gact is the generic action of verdict, the one action of a filter.
func gact(verdict int32) []byte {
	parms := make([]byte, 20) // struct tc_gact: index, capab, action, refcnt, bindcnt
	binary.NativeEndian.PutUint32(parms[8:12], uint32(verdict))
	one := rtattr(nil, actKind, cstring(gactKind))
	one = nested(one, actOptions, rtattr(nil, gactParms, parms))
	return nested(nil, flowerAct, nested(nil, 1, one))
}

// flowerFilter is the RTM_NEWTFILTER of a flower filter on link index's
// ingress, of prio and protocol, matching IPv4 fragments where fragments,
// everything of its protocol otherwise, with the generic action of verdict.
func flowerFilter(index int32, prio, protocol uint16, fragments bool, verdict int32) []byte {
	options := gact(verdict)
	if fragments {
		var flag [4]byte
		binary.BigEndian.PutUint32(flag[:], flowerFragment)
		options = rtattr(options, flowerKeyFlags, flag[:])
		options = rtattr(options, flowerFlagsMask, flag[:])
	}
	b := tcmsg(index, 0, tcIngressHandle, filterInfo(prio, protocol))
	b = rtattr(b, tcaKind, cstring(flowerKind))
	return nested(b, tcaOptions, options)
}

// wholeIPv4Only makes link index's ingress let only a whole IPv4 packet
// in, as the package doc says. A link that already holds an ingress qdisc
// is refused, as one the guard did not make.
func wholeIPv4Only(index int32) error {
	qdisc := rtattr(tcmsg(index, tcIngressHandle, tcIngressParent, 0), tcaKind, cstring(ingressKind))
	if err := netlinkDo(unix.RTM_NEWQDISC, unix.NLM_F_CREATE|unix.NLM_F_EXCL, qdisc); err != nil {
		return fmt.Errorf("its ingress qdisc: %w", err)
	}
	for _, f := range []struct {
		prio, protocol uint16
		fragments      bool
		verdict        int32
		what           string
	}{
		{1, ethPIP, true, actShot, "dropping every IPv4 fragment"},
		{2, ethPIP, false, actOK, "letting a whole IPv4 packet in"},
		{3, ethPAll, false, actShot, "dropping every other frame"},
	} {
		if err := netlinkDo(unix.RTM_NEWTFILTER, unix.NLM_F_CREATE|unix.NLM_F_EXCL, flowerFilter(index, f.prio, f.protocol, f.fragments, f.verdict)); err != nil {
			return fmt.Errorf("its ingress filter %s: %w", f.what, err)
		}
	}
	return nil
}

// probeName is the end of the pair the guard tries the filter on at its
// start, the other end probePeer: no route's name (outerName, tapName).
const (
	probeName = "cyfr-probe0"
	probePeer = "cyfr-probe1"
)

// probeMachines tries, on a veth pair of the guard's own that it removes
// after, what a machine's route's end is given (wholeIPv4Only), and answers
// "" where the kernel gives all of it, or why the guard routes no machine.
// A pair an earlier guard left is removed first.
func probeMachines() string {
	_ = removeLink(probeName)
	peer := rtattr(ifinfomsg(), unix.IFLA_IFNAME, cstring(probePeer))
	info := rtattr(nil, unix.IFLA_INFO_KIND, cstring("veth"))
	info = rtattr(info, unix.IFLA_INFO_DATA, rtattr(nil, vethInfoPeer, peer))
	body := rtattr(ifinfomsg(), unix.IFLA_IFNAME, cstring(probeName))
	body = rtattr(body, unix.IFLA_LINKINFO, info)
	if err := netlinkDo(unix.RTM_NEWLINK, unix.NLM_F_CREATE|unix.NLM_F_EXCL, body); err != nil {
		return "the guard could not make a pair to try a machine's ingress filter on: " + err.Error()
	}
	defer func() { _ = removeLink(probeName) }()
	index, err := linkIndex(probeName)
	if err != nil {
		return "the guard could not find its pair to try a machine's ingress filter on: " + err.Error()
	}
	if err := wholeIPv4Only(index); err != nil {
		why := err.Error()
		if errors.Is(err, unix.ENOENT) || errors.Is(err, unix.EOPNOTSUPP) {
			why += " (the kernel lacks the ingress qdisc, the flower classifier or the generic action)"
		}
		return "this host's kernel cannot hold a machine's route to whole IPv4 packets at its ingress: " + why
	}
	return ""
}

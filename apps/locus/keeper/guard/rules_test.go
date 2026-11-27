// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package guard

import (
	"bytes"
	"net/netip"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/cyfr/locus/keeper/internal/logx"
)

const controlPlane = "172.16.230.2"

// anIsland is a namespace on two island subnets, with a local address on
// each, the loopback's and one outside both, and an IPv6 subnet.
func anIsland() island {
	return island{
		controlPlane: controlPlane,
		targets:      []string{"10.9.8.0/24", "fd12:3456::/64"},
		routes:       []string{"172.18.0.0/16", "192.168.5.0/24", "203.0.113.0/24"},
		subnets:      []string{"172.18.0.0/16", "192.168.5.0/24"},
		v6Subnets:    []string{"fd00:0000:0000:0000:0000:0000:0000:0000/64"},
		local:        []string{"10.1.1.1", "127.0.0.1", "172.18.0.3", "192.168.5.7"},
	}
}

// lockedBuffer is a log the guard's goroutines write and a test reads,
// each under its lock.
type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

func logged() (*logx.Logger, *lockedBuffer) {
	b := &lockedBuffer{}
	return logx.NewWriter(b, "cyfr-guard", false), b
}

func commands(rules []rule) []string {
	out := make([]string, len(rules))
	for i, r := range rules {
		out[i] = r.String()
	}
	return out
}

func rejects(chain string, ranges []string) []string {
	var out []string
	for _, r := range ranges {
		if strings.Contains(r, ":") {
			out = append(out, "ip6tables -A "+chain+" -d "+r+" -j REJECT --reject-with icmp6-adm-prohibited")
		} else {
			out = append(out, "iptables -A "+chain+" -d "+r+" -j REJECT --reject-with icmp-admin-prohibited")
		}
	}
	return out
}

func cat(lists ...[]string) []string {
	var out []string
	for _, l := range lists {
		out = append(out, l...)
	}
	return out
}

// The guard installs every metadata and private row of its table and the
// island's own rows, in this order: for the namespace's own processes, the
// control plane, the island's subnets, the service's own loopback and the
// deployment's private hosts; and for the spaces, what every route is held
// to (the metadata, the control plane and the island's subnets; then the
// private rows), the jumps to each route's chain and to its replies, the
// refusal of all else from or into a space, of both families, the jumps of
// the connections to the island's own addresses to the roles' forwarding,
// and the masquerade of the route range it chose.
func TestTheStaticRulesAreTheTableAndTheIslandsRowsInOrder(t *testing.T) {
	log, out := logged()
	st, err := staticRules(log, anIsland())
	if err != nil {
		t.Fatal(err)
	}
	want := cat(
		[]string{
			"iptables -N CYFR_GUARD",
			"ip6tables -N CYFR_GUARD",
			"iptables -N CYFR_GUARD_REFUSE",
			"iptables -N CYFR_GUARD_PRIVATE",
			"iptables -N CYFR_GUARD_ROUTES",
			"iptables -N CYFR_GUARD_REPLIES",
			"iptables -A OUTPUT -j CYFR_GUARD",
			"ip6tables -A OUTPUT -j CYFR_GUARD",
			"iptables -A CYFR_GUARD -o sp+ -p icmp -m conntrack --ctstate RELATED -j ACCEPT",
			"iptables -A CYFR_GUARD -o sp+ -j REJECT --reject-with icmp-admin-prohibited",
			"ip6tables -A CYFR_GUARD -o sp+ -j REJECT --reject-with icmp6-adm-prohibited",
			"iptables -A CYFR_GUARD -m conntrack ! --ctstate NEW -j ACCEPT",
			"ip6tables -A CYFR_GUARD -m conntrack ! --ctstate NEW -j ACCEPT",
		},
		rejects("CYFR_GUARD", metadataV4),
		rejects("CYFR_GUARD", metadataV6),
		[]string{"iptables -A CYFR_GUARD -d " + controlPlane + "/32 -j REJECT --reject-with icmp-admin-prohibited"},
		rejects("CYFR_GUARD", []string{"172.18.0.0/16", "192.168.5.0/24", "fd00:0000:0000:0000:0000:0000:0000:0000/64"}),
		[]string{
			"iptables -A CYFR_GUARD -o lo -j RETURN",
			"ip6tables -A CYFR_GUARD -o lo -j RETURN",
			"iptables -A CYFR_GUARD -d 10.9.8.0/24 -j RETURN",
			"ip6tables -A CYFR_GUARD -d fd12:3456::/64 -j RETURN",
		},
		rejects("CYFR_GUARD", privateV4),
		rejects("CYFR_GUARD", privateV6),
		rejects("CYFR_GUARD_REFUSE", metadataV4),
		[]string{"iptables -A CYFR_GUARD_REFUSE -d " + controlPlane + "/32 -j REJECT --reject-with icmp-admin-prohibited"},
		rejects("CYFR_GUARD_REFUSE", []string{"172.18.0.0/16", "192.168.5.0/24"}),
		rejects("CYFR_GUARD_PRIVATE", privateV4),
		[]string{
			"iptables -A FORWARD -i sp+ -j CYFR_GUARD_ROUTES",
			"iptables -A FORWARD -i sp+ -j REJECT --reject-with icmp-admin-prohibited",
			"iptables -A FORWARD -o sp+ -j CYFR_GUARD_REPLIES",
			"iptables -A FORWARD -o sp+ -j REJECT --reject-with icmp-admin-prohibited",
			"iptables -A INPUT -i sp+ -p tcp -m conntrack --ctstate DNAT --ctdir REPLY -j CYFR_GUARD_ROUTES",
			"iptables -A INPUT -i sp+ -j REJECT --reject-with icmp-admin-prohibited",
			"ip6tables -A FORWARD -i sp+ -j REJECT --reject-with icmp6-adm-prohibited",
			"ip6tables -A FORWARD -o sp+ -j REJECT --reject-with icmp6-adm-prohibited",
			"ip6tables -A INPUT -i sp+ -j REJECT --reject-with icmp6-adm-prohibited",
			"iptables -t nat -N CYFR_GUARD_ROLES",
			// The island's own addresses are its local addresses on its
			// subnets: neither the loopback's nor one outside them.
			"iptables -t nat -A PREROUTING -d 172.18.0.3/32 ! -i sp+ -p tcp -j CYFR_GUARD_ROLES",
			"iptables -t nat -A OUTPUT -d 172.18.0.3/32 -p tcp -j CYFR_GUARD_ROLES",
			"iptables -t nat -A PREROUTING -d 192.168.5.7/32 ! -i sp+ -p tcp -j CYFR_GUARD_ROLES",
			"iptables -t nat -A OUTPUT -d 192.168.5.7/32 -p tcp -j CYFR_GUARD_ROLES",
			"iptables -t nat -A POSTROUTING -s 10.213.0.0/16 ! -o sp+ -j MASQUERADE",
		},
	)
	if got := commands(st.rules); !reflect.DeepEqual(got, want) {
		t.Fatalf("the static rules:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if st.rng != "10.213.0.0/16" || !reflect.DeepEqual(st.targets, anIsland().targets) || st.hostAddress != "" {
		t.Fatalf("the static rules' range %q, targets %q, host API %q", st.rng, st.targets, st.hostAddress)
	}
	for _, line := range []string{
		"[cyfr-guard] info: routes take 10.213.0.0/16\n",
		"[cyfr-guard] info: island subnet 172.18.0.0/16\n",
		"[cyfr-guard] info: island subnet fd00:0000:0000:0000:0000:0000:0000:0000/64\n",
		"[cyfr-guard] info: island address 192.168.5.7\n",
	} {
		if !strings.Contains(out.String(), line) {
			t.Errorf("the log lacks %q:\n%s", line, out)
		}
	}
	if strings.Contains(out.String(), "host API") {
		t.Errorf("a guard with no host API names one:\n%s", out)
	}
}

// The table holds every range the island must refuse.
func TestTheTableHoldsEveryRangeTheIslandMustRefuse(t *testing.T) {
	has := func(list []string, r string) bool {
		for _, x := range list {
			if x == r {
				return true
			}
		}
		return false
	}
	for _, r := range strings.Fields("169.254.0.0/16 100.100.100.200/32 192.0.0.192/32 fe80::/10 fd00:ec2::254/128") {
		if !has(metadataV4, r) && !has(metadataV6, r) {
			t.Errorf("the metadata rows lack %s", r)
		}
	}
	for _, r := range strings.Fields(`127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 0.0.0.0/8 100.64.0.0/10
		192.0.0.0/24 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4 fc00::/7 64:ff9b:1::/48 ff00::/8`) {
		if !has(privateV4, r) && !has(privateV6, r) {
			t.Errorf("the private rows lack %s", r)
		}
	}
}

// Core's host API is one address and port on the island's subnets: the
// guard starts on one it reads so, logging it, and refuses to start on any
// other value, naming it, with no rule.
func TestTheGuardRefusesAHostAPIThatIsNotAnAddressAndPortOfTheIslandsSubnets(t *testing.T) {
	isl := anIsland()
	isl.hostAPI = "172.18.0.3:4300"
	log, out := logged()
	st, err := staticRules(log, isl)
	if err != nil || st.hostAddress != "172.18.0.3" || st.hostPort != "4300" {
		t.Fatalf("the host API %q %q: %v", st.hostAddress, st.hostPort, err)
	}
	if !strings.Contains(out.String(), "[cyfr-guard] info: host API 172.18.0.3:4300 passes private roles\n") {
		t.Fatalf("the guard does not log its host API:\n%s", out)
	}
	for _, bad := range []string{
		"172.18.0.3", "172.18.0.3:0", "172.18.0.3:065", "172.18.0.3:65536", "172.18.0.3:4300:1",
		"172.18.0.3:http", "192.0.2.1:4300", "172.18.0.3.1:4300", "[::1]:4300",
	} {
		isl.hostAPI = bad
		log, out := logged()
		st, err := staticRules(log, isl)
		if err == nil || st.rules != nil {
			t.Errorf("a host API of %q was taken: %d rules", bad, len(st.rules))
			continue
		}
		want := "[cyfr-guard] error: CYFR_GUARD_HOST_API is '" + bad +
			"', not <IPv4 address>:<port> with the address on one of the island's subnets (172.18.0.0/16 192.168.5.0/24)\n"
		if !strings.Contains(out.String(), want) {
			t.Errorf("the refusal of %q is not named:\n%s", bad, out)
		}
	}
}

// The control plane is the one value the guard requires, and an IPv4 one.
func TestTheGuardRefusesAControlPlaneItCannotHold(t *testing.T) {
	for value, want := range map[string]string{
		"":        "[cyfr-guard] error: CYFR_GUARD_CONTROL_PLANE is unset: it names the fixed address of cyfr on the default network\n",
		"fd00::2": "[cyfr-guard] error: CYFR_GUARD_CONTROL_PLANE is 'fd00::2', not an IPv4 address\n",
	} {
		isl := anIsland()
		isl.controlPlane = value
		log, out := logged()
		if st, err := staticRules(log, isl); err == nil || st.rules != nil || !strings.Contains(out.String(), want) {
			t.Errorf("a control plane of %q: %v\n%s", value, err, out)
		}
	}
}

// The route range is the first /16 of 10.0.0.0/8 from 10.213.0.0/16 on
// that no route of the namespace and no private host overlaps: one that
// does is passed over and logged naming what it overlaps.
func TestTheRouteRangePassesOverASlash16APrivateHostOverlapsNamingIt(t *testing.T) {
	isl := anIsland()
	isl.targets = []string{"10.213.4.0/24", "10.214.0.9", "fd00::1"}
	log, out := logged()
	st, err := staticRules(log, isl)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{
		"[cyfr-guard] info: 10.213.0.0/16 overlaps 10.213.4.0/24: the routes take another range\n",
		"[cyfr-guard] info: 10.214.0.0/16 overlaps 10.214.0.9: the routes take another range\n",
		"[cyfr-guard] info: routes take 10.215.0.0/16\n",
	} {
		if !strings.Contains(out.String(), line) {
			t.Errorf("the log lacks %q:\n%s", line, out)
		}
	}
	if st.rng != "10.215.0.0/16" {
		t.Fatalf("the range %s", st.rng)
	}
	// A route of the namespace's own counts as a private host does, and
	// the search goes round past 10.255.0.0/16 to 10.0.0.0/16.
	if got, err := routeRange(log, []string{"10.213.0.0/16", "10.214.0.0/15", "10.216.0.0/13", "10.224.0.0/11"}); err != nil || got != "10.0.0.0/16" {
		t.Fatalf("the range past 10.255.0.0/16: %q %v", got, err)
	}
}

func TestTheGuardRefusesToStartWithNoFreeSlash16(t *testing.T) {
	isl := anIsland()
	isl.targets = []string{"10.0.0.0/8"}
	log, out := logged()
	st, err := staticRules(log, isl)
	if err == nil || st.rules != nil {
		t.Fatalf("a guard with no free /16 started: %d rules", len(st.rules))
	}
	for _, want := range []string{
		"[cyfr-guard] error: no /16 of 10.0.0.0/8 is free for the routes of the spaces: the routes of this namespace and the private hosts overlap every one (10.213.0.0/16: 10.0.0.0/8; ",
		"; 10.212.0.0/16: 10.0.0.0/8)\n",
	} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("the refusal lacks %q:\n%s", want, out)
		}
	}
}

// The guard reads its routes, subnets and addresses from the kernel's own
// tables, the loopback and the routes' pairs apart.
func TestTheGuardReadsItsIslandFromTheKernelsTables(t *testing.T) {
	route := "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n" +
		"eth0\t00000000\t010012AC\t0003\t0\t0\t0\t00000000\t0\t0\t0\n" +
		"eth0\t000012AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n" +
		"eth1\t0005A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n" +
		"eth1\t007100CB\t0105A8C0\t0003\t0\t0\t0\t00FFFFFF\t0\t0\t0\n" +
		"sp3\t0C00D50A\t00000000\t0001\t0\t0\t0\tFCFFFFFF\t0\t0\t0\n" +
		"lo\t0000007F\t00000000\t0001\t0\t0\t0\t000000FF\t0\t0\t0\n"
	if got, want := v4Routes(route, false), []string{"172.18.0.0/16", "192.168.5.0/24", "203.0.113.0/24"}; !reflect.DeepEqual(got, want) {
		t.Errorf("the routes %q, want %q", got, want)
	}
	if got, want := v4Routes(route, true), []string{"172.18.0.0/16", "192.168.5.0/24"}; !reflect.DeepEqual(got, want) {
		t.Errorf("the subnets %q, want %q", got, want)
	}
	v6 := "fd000000000000000000000000000000 40 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000001 00000000 00000001     eth0\n" +
		"fe800000000000000000000000000000 40 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000001 00000000 00000001     eth0\n" +
		"fe800000000000000000000000000000 40 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000001 00000000 00000001     eth1\n" +
		"00000000000000000000000000000000 00 00000000000000000000000000000000 00 fd000000000000000000000000000001 00000400 00000001 00000000 00000003     eth0\n" +
		"20010db8000000000000000000000000 30 00000000000000000000000000000000 00 fd000000000000000000000000000001 00000400 00000001 00000000 00000003     eth0\n" +
		"ff000000000000000000000000000000 08 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000001 00000000 00000001     eth0\n" +
		"fe800000000000000000000000000000 40 00000000000000000000000000000000 00 00000000000000000000000000000000 00000100 00000001 00000000 00000001      sp3\n" +
		"00000000000000000000000000000001 80 00000000000000000000000000000000 00 00000000000000000000000000000000 00000000 00000001 00000000 00000001       lo\n"
	if got, want := v6Subnets(v6), []string{"fd00:0000:0000:0000:0000:0000:0000:0000/64", "fe80:0000:0000:0000:0000:0000:0000:0000/64"}; !reflect.DeepEqual(got, want) {
		t.Errorf("the IPv6 subnets %q, want %q", got, want)
	}
	trie := "Main:\n  +-- 0.0.0.0/0 3 0 5\n     |-- 0.0.0.0\n        /0 universe UNICAST\n" +
		"     +-- 172.18.0.0/16 2 0 2\n        +-- 172.18.0.0/30 2 0 2\n           |-- 172.18.0.0\n              /16 link UNICAST\n" +
		"           |-- 172.18.0.3\n              /32 host LOCAL\n        |-- 172.18.255.255\n           /32 link BROADCAST\n" +
		"Local:\n  +-- 0.0.0.0/0 3 0 5\n     |-- 127.0.0.1\n        /32 host LOCAL\n     |-- 172.18.0.3\n        /32 host LOCAL\n"
	if got, want := localAddresses(trie), []string{"127.0.0.1", "172.18.0.3"}; !reflect.DeepEqual(got, want) {
		t.Errorf("the local addresses %q, want %q", got, want)
	}
	if got, want := splitTargets("locus, 10.9.8.0/24,,fd00::1\tdb"), []string{"locus", "10.9.8.0/24", "fd00::1", "db"}; !reflect.DeepEqual(got, want) {
		t.Errorf("the targets %q, want %q", got, want)
	}
}

func aRoute(reach string) *route {
	gateway, inner := slotAddresses(netip.MustParsePrefix("10.213.0.0/16"), 3)
	return &route{slot: 3, gateway: gateway, inner: inner, mark: 7, reach: reach}
}

// Each reach's route is installed as one restore of its chains and jumps:
// a route of the island's reach passes the public Internet, one of reach
// hosts its addresses alone (an IPv6 one has no route), a role's its port
// forwarded in, and a private role core's host API and every private
// address but the route range.
func TestEachReachsRouteIsItsChainsAndJumps(t *testing.T) {
	st := static{rng: "10.213.0.0/16", targets: []string{"10.9.8.0/24", "fd12:3456::/64", "172.18.0.9"}, hostAddress: "172.18.0.2", hostPort: "4300"}
	head := "*filter\n:CYFR_GUARD_R3 - [0:0]\n:CYFR_GUARD_P3 - [0:0]\n" +
		"-A CYFR_GUARD_P3 -m connmark --mark 0 -j CONNMARK --set-mark 7\n-A CYFR_GUARD_P3 -j ACCEPT\n" +
		"-A CYFR_GUARD_R3 ! -s 10.213.0.14/32 -j DROP\n"
	other := "-A CYFR_GUARD_R3 -o sp+ -j REJECT --reject-with icmp-admin-prohibited\n"
	held := "-A CYFR_GUARD_R3 -j CYFR_GUARD_REFUSE\n-A CYFR_GUARD_R3 -d 10.9.8.0/24 -j CYFR_GUARD_P3\n" +
		"-A CYFR_GUARD_R3 -d 172.18.0.9 -j CYFR_GUARD_P3\n-A CYFR_GUARD_R3 -j CYFR_GUARD_PRIVATE\n"
	jumps := "-A CYFR_GUARD_ROUTES -i sp3 -j CYFR_GUARD_R3\n" +
		"-A CYFR_GUARD_REPLIES -o sp3 -m connmark --mark 7 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n"
	roleIn := "-A CYFR_GUARD_REPLIES -o sp3 -p tcp --dport 4101 -m conntrack --ctstate DNAT --ctdir ORIGINAL -m connmark --mark 7 -j ACCEPT\n"
	roleReply := "-A CYFR_GUARD_R3 -p tcp --sport 4101 -m conntrack --ctstate DNAT --ctdir REPLY -m connmark --mark 7 -j ACCEPT\n"
	forward := "*nat\n-A CYFR_GUARD_ROLES -p tcp --dport 4101 -m comment --comment sp3 -j CONNMARK --set-mark 7\n" +
		"-A CYFR_GUARD_ROLES -p tcp --dport 4101 -m comment --comment sp3 -j DNAT --to-destination 10.213.0.14:4101\nCOMMIT\n"

	hosts := aRoute(ReachHosts)
	hosts.addresses = []string{"1.2.3.4", "2606:4700::1111", "5.6.7.8"}
	role := aRoute(ReachRole)
	role.port = 4101
	private := aRoute(ReachRole)
	private.port, private.private = 4101, true
	for _, c := range []struct {
		name string
		r    *route
		st   static
		want string
	}{
		{"island", aRoute(ReachIsland), st, head + other + held + "-A CYFR_GUARD_R3 -j CYFR_GUARD_P3\n" + jumps + "COMMIT\n"},
		{"hosts", hosts, st, head + other + held + "-A CYFR_GUARD_R3 -d 1.2.3.4/32 -j CYFR_GUARD_P3\n-A CYFR_GUARD_R3 -d 5.6.7.8/32 -j CYFR_GUARD_P3\n" +
			"-A CYFR_GUARD_R3 -j REJECT --reject-with icmp-admin-prohibited\n" + jumps + "COMMIT\n"},
		{"role", role, st, head + roleReply + other + held + "-A CYFR_GUARD_R3 -j CYFR_GUARD_P3\n" + jumps + roleIn + "COMMIT\n" + forward},
		{"private role", private, st, head + roleReply + other + "-A CYFR_GUARD_R3 -d 172.18.0.2/32 -p tcp --dport 4300 -j CYFR_GUARD_P3\n" +
			"-A CYFR_GUARD_R3 -j CYFR_GUARD_REFUSE\n-A CYFR_GUARD_R3 -d 10.213.0.0/16 -j REJECT --reject-with icmp-admin-prohibited\n" +
			"-A CYFR_GUARD_R3 -j CYFR_GUARD_P3\n" + jumps + roleIn + "COMMIT\n" + forward},
		{"private role with no host API", private, static{rng: "10.213.0.0/16"}, head + roleReply + other +
			"-A CYFR_GUARD_R3 -j CYFR_GUARD_REFUSE\n-A CYFR_GUARD_R3 -d 10.213.0.0/16 -j REJECT --reject-with icmp-admin-prohibited\n" +
			"-A CYFR_GUARD_R3 -j CYFR_GUARD_P3\n" + jumps + roleIn + "COMMIT\n" + forward},
	} {
		if got := routeRules(c.r, c.st); got != c.want {
			t.Errorf("%s's route:\n%s\nwant:\n%s", c.name, got, c.want)
		}
	}
}

// A route's record is what the kernel lists of its chains and of its jumps,
// and its removal deletes each of those jumps, the forwarding first, then
// empties and deletes its chains; a chain the kernel does not hold is not
// named, so a route already gone is removed.
func TestARoutesRecordAndRemovalAreItsOwnLinesAlone(t *testing.T) {
	k := installed{
		r:   "-N CYFR_GUARD_R3\n-A CYFR_GUARD_R3 ! -s 10.213.0.14/32 -j DROP\n",
		p:   "-N CYFR_GUARD_P3\n-A CYFR_GUARD_P3 -j ACCEPT\n",
		out: "-N CYFR_GUARD_ROUTES\n-A CYFR_GUARD_ROUTES -i sp3 -j CYFR_GUARD_R3\n-A CYFR_GUARD_ROUTES -i sp31 -j CYFR_GUARD_R31\n",
		in: "-N CYFR_GUARD_REPLIES\n-A CYFR_GUARD_REPLIES -o sp31 -m connmark --mark 9 -j ACCEPT\n" +
			"-A CYFR_GUARD_REPLIES -o sp3 -m connmark --mark 7 -j ACCEPT\n",
		roles: "-N CYFR_GUARD_ROLES\n-A CYFR_GUARD_ROLES -p tcp -m tcp --dport 4101 -m comment --comment sp3 -j DNAT --to-destination 10.213.0.14:4101\n" +
			"-A CYFR_GUARD_ROLES -p tcp -m tcp --dport 4100 -m comment --comment sp31 -j DNAT --to-destination 10.213.0.126:4100\n",
	}
	wantText := k.r + k.p + "-A CYFR_GUARD_ROUTES -i sp3 -j CYFR_GUARD_R3\n-A CYFR_GUARD_REPLIES -o sp3 -m connmark --mark 7 -j ACCEPT\n" +
		"-A CYFR_GUARD_ROLES -p tcp -m tcp --dport 4101 -m comment --comment sp3 -j DNAT --to-destination 10.213.0.14:4101\n"
	if got := routeText("sp3", k); got != wantText {
		t.Errorf("the record:\n%s\nwant:\n%s", got, wantText)
	}
	wantRemoval := "*nat\n-D CYFR_GUARD_ROLES -p tcp -m tcp --dport 4101 -m comment --comment sp3 -j DNAT --to-destination 10.213.0.14:4101\nCOMMIT\n" +
		"*filter\n-D CYFR_GUARD_ROUTES -i sp3 -j CYFR_GUARD_R3\n-D CYFR_GUARD_REPLIES -o sp3 -m connmark --mark 7 -j ACCEPT\n" +
		"-F CYFR_GUARD_R3\n-F CYFR_GUARD_P3\n-X CYFR_GUARD_R3\n-X CYFR_GUARD_P3\nCOMMIT\n"
	if got := removal("sp3", k); got != wantRemoval {
		t.Errorf("the removal:\n%s\nwant:\n%s", got, wantRemoval)
	}
	gone := installed{out: k.out, in: k.in, roles: k.roles}
	if got, want := removal("sp4", gone), "*nat\nCOMMIT\n*filter\nCOMMIT\n"; got != want {
		t.Errorf("the removal of a route gone:\n%s", got)
	}
	k.p = ""
	if got := removal("sp3", k); strings.Contains(got, "CYFR_GUARD_P3") {
		t.Errorf("the removal names a chain the kernel does not hold:\n%s", got)
	}
	chains, jumps := routesListed(k.r+k.out+k.in, k.roles)
	if !reflect.DeepEqual(chains, []string{"sp3"}) || !reflect.DeepEqual(jumps, []string{"sp3", "sp31"}) {
		t.Errorf("the routes listed %q, jumped to %q", chains, jumps)
	}
}

// The digest is of the static rules: comments, the policies' counters,
// other nat rules than the guard's own and every route's lines leave it as
// it is, and any other change moves it.
func TestTheDigestIsOfTheStaticRulesAlone(t *testing.T) {
	v4 := "# Generated by iptables-save v1.8.11 on Fri Nov 27 10:00:00 2026\n*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n" +
		":CYFR_GUARD - [0:0]\n:CYFR_GUARD_ROUTES - [0:0]\n-A FORWARD -i sp+ -j CYFR_GUARD_ROUTES\nCOMMIT\n# Completed on Fri Nov 27 10:00:00 2026\n"
	v6 := "*filter\n:OUTPUT ACCEPT [0:0]\n-A OUTPUT -j CYFR_GUARD\nCOMMIT\n"
	nat := "*nat\n:DOCKER_OUTPUT - [0:0]\n:CYFR_GUARD_ROLES - [0:0]\n-A OUTPUT -d 127.0.0.11/32 -j DOCKER_OUTPUT\n-A OUTPUT -d 172.18.0.3/32 -p tcp -j CYFR_GUARD_ROLES\nCOMMIT\n"
	base := digest(v4, v6, nat)
	if len(base) != 64 {
		t.Fatalf("the digest %q", base)
	}
	same := map[string][3]string{
		"other timestamps and counters": {strings.ReplaceAll(strings.ReplaceAll(v4, "10:00:00", "11:11:11"), "INPUT ACCEPT [0:0]", "INPUT ACCEPT [12:3400]"), v6, nat},
		"a route's chain and jumps": {strings.Replace(v4, "COMMIT", ":CYFR_GUARD_R3 - [0:0]\n:CYFR_GUARD_P3 - [0:0]\n-A CYFR_GUARD_R3 -j CYFR_GUARD_P3\n"+
			"-A CYFR_GUARD_ROUTES -i sp3 -j CYFR_GUARD_R3\n-A CYFR_GUARD_REPLIES -o sp3 -j ACCEPT\nCOMMIT", 1), v6,
			strings.Replace(nat, "COMMIT", "-A CYFR_GUARD_ROLES -p tcp -m tcp --dport 4101 -m comment --comment sp3 -j DNAT --to-destination 10.213.0.14:4101\nCOMMIT", 1)},
		"Docker's own nat rules": {v4, v6, strings.Replace(nat, "COMMIT", "-A DOCKER_OUTPUT -p udp -j DNAT --to-destination 127.0.0.11:53\nCOMMIT", 1)},
	}
	for name, s := range same {
		if digest(s[0], s[1], s[2]) != base {
			t.Errorf("%s move the digest", name)
		}
	}
	moved := map[string][3]string{
		"a static rule removed": {strings.Replace(v4, "-A FORWARD -i sp+ -j CYFR_GUARD_ROUTES\n", "", 1), v6, nat},
		"an IPv6 rule removed":  {v4, strings.Replace(v6, "-A OUTPUT -j CYFR_GUARD\n", "", 1), nat},
		"a nat jump removed":    {v4, v6, strings.Replace(nat, "-A OUTPUT -d 172.18.0.3/32 -p tcp -j CYFR_GUARD_ROLES\n", "", 1)},
		"a policy changed":      {strings.Replace(v4, ":FORWARD ACCEPT", ":FORWARD DROP", 1), v6, nat},
	}
	for name, s := range moved {
		if digest(s[0], s[1], s[2]) == base {
			t.Errorf("%s leaves the digest", name)
		}
	}
}

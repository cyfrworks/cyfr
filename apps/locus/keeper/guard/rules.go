// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package guard

// The guard's rules. docker-compose.yml runs one guard, locus-guard, from
// the Locus image as `cyfr-locus guard-control`, holding NET_ADMIN and no
// other capability, in a namespace whose net.ipv4.ip_forward is 1 and
// net.ipv4.icmp_ratelimit 0 (compose's sysctls; the guard refuses to start
// otherwise). The island's service shares this container's network
// namespace (`network_mode: service:`), and starts only once this container
// is healthy: healthy means the ready file is present, the static rules it
// records are still installed and every route the guard holds is too, and
// the ready file is written only once every rule is in and the control
// listens. A rule that cannot be installed ends the guard with an error
// naming it, before the ready file exists, so the island never starts
// behind a guard that holds fewer rules than these.
//
// Every build, every program's session and every role's service process
// runs in a space of its own, with its own network namespace, which the
// keeper makes; nothing of a space reaches this namespace's loopback, the
// island's service or another space. A routed space's one way out is its
// route: a veth pair whose guard's end is sp<slot> here, a /30 of the route
// range, and the route's own chains, installed as it is admitted and
// removed as it is withdrawn. The route range is the first IPv4 /16 of
// 10.0.0.0/8, from 10.213.0.0/16 on, that overlaps none of this
// namespace's routes and none of the private hosts' addresses; with none
// free the guard ends naming every overlap.
//
// A space's packet leaving through its route is judged, every packet of it,
// by its route's chain (CYFR_GUARD_R<slot>), in this order:
//  1. its source must be the route's inner address, else it is dropped;
//  2. another space, through another sp interface, is refused;
//  3. every metadata address (metadataV4: link-local, the clouds' metadata
//     endpoints), the control plane (cyfr's fixed address on the default
//     network, CYFR_GUARD_CONTROL_PLANE) and every subnet of this
//     namespace's own interfaces (cyfr's island address, the island's
//     gateway and the island itself) are refused (CYFR_GUARD_REFUSE);
//  4. the addresses the private hosts CYFR_PRIVATE_EGRESS_TARGETS names
//     resolve to, the deployment's own registries and MCP servers, pass; a
//     name that does not resolve when the guard starts is logged and opens
//     nothing, and the guard resolves again when it restarts;
//  5. every other private address (privateV4: loopback, RFC 1918, CGNAT,
//     the reserved and multicast ranges) is refused (CYFR_GUARD_PRIVATE);
//  6. a route of reach `island` or `role` passes everything else, the
//     public Internet; a route of reach `hosts` passes the addresses its
//     keeper admitted for it and refuses every other.
//
// A route of reach `role` that is `private` (the role whose container sat
// on a network of its own) is judged instead, after rules 1 and 2:
//  3. core's host API, the one address and TCP port on the island's
//     subnets CYFR_GUARD_HOST_API names, passes;
//  4. what rule 3 above refuses stays refused, and so does the route range
//     (every other space);
//  5. everything else passes: every other private address and the public
//     Internet.
//
// No other route reaches the host API: the island's subnets refuse it.
// What passes leaves masqueraded as this namespace's own address, and a
// connection it opens takes the route's mark as it is made, and never
// after: CONNMARK sets it only on a connection that carries no mark yet
// (through CYFR_GUARD_P<slot>; a route's mark is its own identity, a number
// the guard never gives twice in its life), so no route overwrites
// another's, an unreplied entry's included. A packet into a space passes
// only as a reply of a connection carrying its own route's mark, and a
// withdrawn route leaves no connection in the kernel's table (the control
// removes them as it removes the pair), so a later route that took its
// address inherits nothing of it. IPv6 has no route: a space's IPv6
// packet, and any packet a space sends to this namespace itself, is
// refused. A refusal answers the sender at once with an
// administratively-prohibited ICMP, which it sees as EHOSTUNREACH, never a
// timeout: the namespace's ICMP rate limit is off, so every refusal is
// answered.
//
// A route of reach `role` is a role's service process, listening on its
// port in its space, and is the one route anything enters by: a new TCP
// connection to one of this namespace's own island addresses (the
// addresses of its interfaces on the island's subnets, logged as the guard
// starts) at the role's port, arriving from the island's network or made
// by this namespace's own processes (a health probe), is forwarded to the
// space's address at that port (DNAT, by CYFR_GUARD_ROLES in the nat
// table). It enters as the route's own: it takes the route's mark as it is
// forwarded, its packets into the space pass only to that port of the
// route's address, and the space's replies pass as replies of a forwarded
// connection carrying the route's mark. The filter judges a connection
// this namespace's own processes make by the device it was routed to
// before it was forwarded, the loopback: for those, the forwarding is the
// one way in. One route holds a port at a time (the control refuses a
// second), and the forwarding goes with the route.
//
// The namespace's own processes (the island's service, its keeper, this
// guard) are held as before (CYFR_GUARD, in OUTPUT): a packet of a tracked
// connection passes, and a new one is refused the metadata, the control
// plane and the island's subnets, and every private address but the
// namespace's loopback and the private hosts. What it sends into a space
// is refused, the ICMP that answers a space's refused packet and a
// connection forwarded to a role apart.
//
// The rules reach the kernel through iptables, as one command for each
// static rule and one iptables-restore --noflush for each route's change;
// iptables-save reads them back for the health check (guard_linux.go).

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/cyfr/locus/keeper/internal/logx"
)

// The guard's chains.
const (
	chainOwn     = "CYFR_GUARD"
	chainRefuse  = "CYFR_GUARD_REFUSE"
	chainPrivate = "CYFR_GUARD_PRIVATE"
	chainOut     = "CYFR_GUARD_ROUTES"
	chainIn      = "CYFR_GUARD_REPLIES"
	chainRoute   = "CYFR_GUARD_R"
	chainPass    = "CYFR_GUARD_P"
	chainRoles   = "CYFR_GUARD_ROLES"
)

const (
	reject4 = "icmp-admin-prohibited"
	reject6 = "icmp6-adm-prohibited"
)

// rule is one static rule: the family's tool and its arguments.
type rule struct {
	family int
	args   []string
}

// tool is the family's iptables command.
func (r rule) tool() string {
	if r.family == 6 {
		return "ip6tables"
	}
	return "iptables"
}

// String is the rule as one command, as an error names it.
func (r rule) String() string { return r.tool() + " " + strings.Join(r.args, " ") }

// island is what the guard reads of its namespace as it starts.
type island struct {
	// controlPlane is CYFR_GUARD_CONTROL_PLANE's value.
	controlPlane string
	// targets are the private hosts' addresses and CIDRs, in the order
	// CYFR_PRIVATE_EGRESS_TARGETS names them, each name's addresses as it
	// resolved.
	targets []string
	// routes are the IPv4 destinations of the namespace's routes, the
	// default route and the routes' own pairs apart; subnets the on-link
	// ones of them, of interfaces other than the loopback (v4Routes).
	routes  []string
	subnets []string
	// v6Subnets are the IPv6 subnets of the namespace's interfaces
	// (v6Subnets).
	v6Subnets []string
	// local are the namespace's local IPv4 addresses (localAddresses).
	local []string
	// hostAPI is CYFR_GUARD_HOST_API's value.
	hostAPI string
}

// static is what the guard installs as it starts, and what each route's
// rules take of it.
type static struct {
	rules []rule
	// rng is the route range; targets every private host's address and
	// CIDR, both families.
	rng     string
	targets []string
	// hostAddress and hostPort are core's host API, empty when unset.
	hostAddress string
	hostPort    string
}

// staticRules are the rules the guard installs on isl, in their order, or
// the refusal of the guard's start, logged. It logs what it reads of the
// island as it goes.
func staticRules(log *logx.Logger, isl island) (static, error) {
	refuse := func(format string, args ...any) (static, error) {
		err := fmt.Errorf(format, args...)
		log.Error("%v", err)
		return static{}, err
	}
	cp := isl.controlPlane
	if err := controlPlaneRefusal(cp); err != nil {
		return refuse("%v", err)
	}
	var v4targets []string
	for _, t := range isl.targets {
		if family(t) == 4 {
			v4targets = append(v4targets, t)
		}
	}
	rng, err := routeRange(log, append(append([]string(nil), isl.routes...), v4targets...))
	if err != nil {
		return static{}, err
	}
	log.Info("routes take %s", rng)
	hostAddress, hostPort, err := parseHostAPI(isl.hostAPI, isl.subnets)
	if err != nil {
		log.Error("%v", err)
		return static{}, err
	}
	if hostAddress != "" {
		log.Info("host API %s:%s passes private roles", hostAddress, hostPort)
	}
	addresses := within(isl.local, isl.subnets)

	var rules []rule
	v4 := func(args ...string) { rules = append(rules, rule{4, args}) }
	v6 := func(args ...string) { rules = append(rules, rule{6, args}) }
	reject := func(chain, cidr string) {
		if family(cidr) == 6 {
			v6("-A", chain, "-d", cidr, "-j", "REJECT", "--reject-with", reject6)
		} else {
			v4("-A", chain, "-d", cidr, "-j", "REJECT", "--reject-with", reject4)
		}
	}

	// The chains of the namespace's own processes and of the spaces.
	v4("-N", chainOwn)
	v6("-N", chainOwn)
	v4("-N", chainRefuse)
	v4("-N", chainPrivate)
	v4("-N", chainOut)
	v4("-N", chainIn)

	// The namespace's own processes: OUTPUT.
	v4("-A", "OUTPUT", "-j", chainOwn)
	v6("-A", "OUTPUT", "-j", chainOwn)
	// Into a space, nothing but the ICMP that answers its refused packets
	// (a connection forwarded to a role is seen here on the loopback).
	v4("-A", chainOwn, "-o", "sp+", "-p", "icmp", "-m", "conntrack", "--ctstate", "RELATED", "-j", "ACCEPT")
	v4("-A", chainOwn, "-o", "sp+", "-j", "REJECT", "--reject-with", reject4)
	v6("-A", chainOwn, "-o", "sp+", "-j", "REJECT", "--reject-with", reject6)
	v4("-A", chainOwn, "-m", "conntrack", "!", "--ctstate", "NEW", "-j", "ACCEPT")
	v6("-A", chainOwn, "-m", "conntrack", "!", "--ctstate", "NEW", "-j", "ACCEPT")
	for _, cidr := range metadataV4 {
		reject(chainOwn, cidr)
	}
	for _, cidr := range metadataV6 {
		reject(chainOwn, cidr)
	}
	reject(chainOwn, cp+"/32")
	for _, subnet := range isl.subnets {
		log.Info("island subnet %s", subnet)
		reject(chainOwn, subnet)
	}
	for _, subnet := range isl.v6Subnets {
		log.Info("island subnet %s", subnet)
		reject(chainOwn, subnet)
	}
	v4("-A", chainOwn, "-o", "lo", "-j", "RETURN")
	v6("-A", chainOwn, "-o", "lo", "-j", "RETURN")
	for _, address := range isl.targets {
		if family(address) == 6 {
			v6("-A", chainOwn, "-d", address, "-j", "RETURN")
		} else {
			v4("-A", chainOwn, "-d", address, "-j", "RETURN")
		}
	}
	for _, cidr := range privateV4 {
		reject(chainOwn, cidr)
	}
	for _, cidr := range privateV6 {
		reject(chainOwn, cidr)
	}

	// The spaces: FORWARD, INPUT, the roles' forwarding and the masquerade.
	// A route's chain jumps to the first two for what every space is
	// refused.
	for _, cidr := range metadataV4 {
		reject(chainRefuse, cidr)
	}
	reject(chainRefuse, cp+"/32")
	for _, subnet := range isl.subnets {
		reject(chainRefuse, subnet)
	}
	for _, cidr := range privateV4 {
		reject(chainPrivate, cidr)
	}
	v4("-A", "FORWARD", "-i", "sp+", "-j", chainOut)
	v4("-A", "FORWARD", "-i", "sp+", "-j", "REJECT", "--reject-with", reject4)
	v4("-A", "FORWARD", "-o", "sp+", "-j", chainIn)
	v4("-A", "FORWARD", "-o", "sp+", "-j", "REJECT", "--reject-with", reject4)
	// A role's reply to this namespace's own process: its route's chain
	// judges it.
	v4("-A", "INPUT", "-i", "sp+", "-p", "tcp", "-m", "conntrack", "--ctstate", "DNAT", "--ctdir", "REPLY", "-j", chainOut)
	v4("-A", "INPUT", "-i", "sp+", "-j", "REJECT", "--reject-with", reject4)
	v6("-A", "FORWARD", "-i", "sp+", "-j", "REJECT", "--reject-with", reject6)
	v6("-A", "FORWARD", "-o", "sp+", "-j", "REJECT", "--reject-with", reject6)
	v6("-A", "INPUT", "-i", "sp+", "-j", "REJECT", "--reject-with", reject6)
	v4("-t", "nat", "-N", chainRoles)
	for _, address := range addresses {
		log.Info("island address %s", address)
		v4("-t", "nat", "-A", "PREROUTING", "-d", address+"/32", "!", "-i", "sp+", "-p", "tcp", "-j", chainRoles)
		v4("-t", "nat", "-A", "OUTPUT", "-d", address+"/32", "-p", "tcp", "-j", chainRoles)
	}
	v4("-t", "nat", "-A", "POSTROUTING", "-s", rng, "!", "-o", "sp+", "-j", "MASQUERADE")
	return static{rules: rules, rng: rng, targets: isl.targets, hostAddress: hostAddress, hostPort: hostPort}, nil
}

// controlPlaneRefusal is the refusal of CYFR_GUARD_CONTROL_PLANE's value,
// or nil where the guard takes it: checked before any private host's name
// is resolved, as the script checked it first.
func controlPlaneRefusal(cp string) error {
	if cp == "" {
		return errors.New("CYFR_GUARD_CONTROL_PLANE is unset: it names the fixed address of cyfr on the default network")
	}
	if strings.Contains(cp, ":") {
		return fmt.Errorf("CYFR_GUARD_CONTROL_PLANE is '%s', not an IPv4 address", cp)
	}
	return nil
}

// masquerade is the routes' masquerade rule of the nat table, as the
// health check asks the kernel whether it stands.
func masquerade(rng string) []string {
	return []string{"-t", "nat", "-C", "POSTROUTING", "-s", rng, "!", "-o", "sp+", "-j", "MASQUERADE"}
}

// family is an address or CIDR's family: 6 where it holds a colon, else 4.
func family(address string) int {
	if strings.Contains(address, ":") {
		return 6
	}
	return 4
}

// span is an IPv4 address or CIDR's first and last address, or false
// where text is neither.
func span(text string) (lo, hi uint64, ok bool) {
	addr, bits, found := strings.Cut(text, "/")
	n := 32
	if found {
		b, err := strconv.Atoi(bits)
		if err != nil || b < 0 || b > 32 {
			return 0, 0, false
		}
		n = b
	}
	// Each octet is read as decimal digits, leading zeros and all, as the
	// rules' text is taken.
	octets := strings.Split(addr, ".")
	if len(octets) != 4 {
		return 0, 0, false
	}
	var v uint64
	for _, o := range octets {
		d, err := strconv.ParseUint(o, 10, 32)
		if err != nil || o == "" || strings.ContainsAny(o, "+-") {
			return 0, 0, false
		}
		v = v*256 + d
	}
	size := uint64(1) << (32 - n)
	lo = v - v%size
	return lo, lo + size - 1, true
}

// within is each of addresses, in order, that lies in one of cidrs.
func within(addresses, cidrs []string) []string {
	var out []string
	for _, a := range addresses {
		v, _, ok := span(a)
		if !ok {
			continue
		}
		for _, c := range cidrs {
			if lo, hi, ok := span(c); ok && lo <= v && v <= hi {
				out = append(out, a)
				break
			}
		}
	}
	return out
}

// routeRange is the first /16 of 10.0.0.0/8, from 10.213.0.0/16 on and
// round to 10.212.0.0/16, that overlaps none of the IPv4 routes and
// private hosts taken (an address is its /32). It logs each /16 passed
// over and what it overlaps, and with none free refuses naming them all.
func routeRange(log *logx.Logger, taken []string) (string, error) {
	type taking struct {
		lo, hi uint64
		name   string
	}
	var spans []taking
	for _, t := range taken {
		if lo, hi, ok := span(t); ok {
			spans = append(spans, taking{lo, hi, t})
		}
	}
	var all []string
	for k := 0; k < 256; k++ {
		b := (213 + k) % 256
		start := uint64(10<<24 | b<<16)
		end := start + 65535
		var hit []string
		for _, s := range spans {
			if s.lo <= end && start <= s.hi {
				hit = append(hit, s.name)
			}
		}
		name := fmt.Sprintf("10.%d.0.0/16", b)
		if hit == nil {
			return name, nil
		}
		log.Info("%s overlaps %s: the routes take another range", name, strings.Join(hit, ", "))
		all = append(all, name+": "+strings.Join(hit, ", "))
	}
	err := fmt.Errorf("no /16 of 10.0.0.0/8 is free for the routes of the spaces: the routes of this namespace and the private hosts overlap every one (%s)", strings.Join(all, "; "))
	log.Error("%v", err)
	return "", err
}

var (
	canonicalOctet = regexp.MustCompile(`^(0|[1-9][0-9]?[0-9]?)$`)
	canonicalPort  = regexp.MustCompile(`^[1-9][0-9]{0,4}$`)
)

// canonicalV4 is whether text is a dotted IPv4 address in its canonical
// form: no octet past 255, none with a leading zero.
func canonicalV4(text string) bool {
	octets := strings.Split(text, ".")
	if len(octets) != 4 {
		return false
	}
	for _, o := range octets {
		if !canonicalOctet.MatchString(o) {
			return false
		}
		if n, _ := strconv.Atoi(o); n > 255 {
			return false
		}
	}
	return true
}

// isPort is whether text is a port, 1..65535 in its canonical form.
func isPort(text string) bool {
	if !canonicalPort.MatchString(text) {
		return false
	}
	n, _ := strconv.Atoi(text)
	return n <= 65535
}

// parseHostAPI reads CYFR_GUARD_HOST_API's value: core's host API as its
// address and port, both empty where the value is, or the refusal naming
// the value where it is not <IPv4 address>:<port> with the address on one
// of subnets.
func parseHostAPI(value string, subnets []string) (address, port string, err error) {
	if value == "" {
		return "", "", nil
	}
	i := strings.LastIndex(value, ":")
	if i >= 0 && canonicalV4(value[:i]) && isPort(value[i+1:]) && len(within([]string{value[:i]}, subnets)) == 1 {
		return value[:i], value[i+1:], nil
	}
	named := "none"
	if len(subnets) > 0 {
		named = strings.Join(subnets, " ")
	}
	return "", "", fmt.Errorf("CYFR_GUARD_HOST_API is '%s', not <IPv4 address>:<port> with the address on one of the island's subnets (%s)", value, named)
}

// splitTargets is CYFR_PRIVATE_EGRESS_TARGETS's value as its names,
// addresses and CIDRs, split at commas and white space.
func splitTargets(value string) []string {
	return strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ' ' || r == '\t' || r == '\n' })
}

// v4Routes are the IPv4 destinations of /proc/net/route's text, the
// default route, the loopback's and the routes' own pairs apart, as
// `<address>/<prefix length>`, sorted, each once; with onLink, those of
// on-link routes alone: the namespace's own subnets.
func v4Routes(text string, onLink bool) []string {
	var out []string
	for i, line := range strings.Split(text, "\n") {
		f := strings.Fields(line)
		if i == 0 || len(f) < 8 || f[0] == "lo" || routeLink.MatchString(f[0]) || f[7] == "00000000" || (onLink && f[2] != "00000000") {
			continue
		}
		dest, err1 := strconv.ParseUint(f[1], 16, 32)
		mask, err2 := strconv.ParseUint(f[7], 16, 32)
		if err1 != nil || err2 != nil {
			continue
		}
		// The kernel writes both in its own byte order, little-endian.
		ones := 0
		for m := mask; m != 0; m &= m - 1 {
			ones++
		}
		out = append(out, fmt.Sprintf("%d.%d.%d.%d/%d", dest&0xff, dest>>8&0xff, dest>>16&0xff, dest>>24, ones))
	}
	return sortedOnce(out)
}

// v6Subnets are the IPv6 subnets of /proc/net/ipv6_route's text, of
// interfaces other than the loopback and the routes' pairs: each on-link
// unicast route's prefix, written as eight groups of four digits, sorted,
// each once.
func v6Subnets(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		f := strings.Fields(line)
		if len(f) < 10 || len(f[0]) != 32 || f[9] == "lo" || routeLink.MatchString(f[9]) || f[1] == "00" ||
			f[4] != "00000000000000000000000000000000" || strings.HasPrefix(f[0], "ff") {
			continue
		}
		bits, err := strconv.ParseUint(f[1], 16, 8)
		if err != nil {
			continue
		}
		groups := make([]string, 8)
		for g := range groups {
			groups[g] = f[0][4*g : 4*g+4]
		}
		out = append(out, strings.Join(groups, ":")+"/"+strconv.FormatUint(bits, 10))
	}
	return sortedOnce(out)
}

// localAddresses are the local IPv4 addresses /proc/net/fib_trie's text
// holds, sorted, each once.
func localAddresses(text string) []string {
	var out []string
	last := ""
	for _, line := range strings.Split(text, "\n") {
		if strings.Contains(line, "|-- ") {
			if f := strings.Fields(line); len(f) >= 2 {
				last = f[1]
			}
		}
		if strings.Contains(line, "/32 host LOCAL") && last != "" {
			out = append(out, last)
		}
	}
	return sortedOnce(out)
}

// resolveNetwork is the families a private host's name is resolved in, as
// Go's resolver names them: those the island has an address of, its local
// IPv4 addresses and /proc/net/if_inet6's text, loopback's apart, as glibc's
// AI_ADDRCONFIG counts them; "" with neither, where nothing opens. On the
// shipped islands, which have IPv4, that is what the script's getent gave.
// It differs on two that no deployment reaches: with IPv6 alone getent
// mapped an IPv4 host into IPv6 (::ffff:), and with loopback alone it
// filtered nothing and passed every host in both families.
func resolveNetwork(local []string, ifInet6 string) string {
	v4 := false
	for _, a := range local {
		if a != "127.0.0.1" {
			v4 = true
		}
	}
	v6 := false
	for _, line := range strings.Split(ifInet6, "\n") {
		if f := strings.Fields(line); len(f) >= 1 && f[0] != "00000000000000000000000000000001" {
			v6 = true
		}
	}
	switch {
	case v4 && v6:
		return "ip"
	case v4:
		return "ip4"
	case v6:
		return "ip6"
	}
	return ""
}

// resolveTarget is a private host's addresses in network's families: an
// address itself where it is of one of them, a name's as resolve answers
// it, and none in a family network lacks. An IPv4 address that is not
// written in full (looseIPv4) is none, and no resolver is asked of it,
// since one built on the C library reads it as inet_aton does, 010.9.9.9
// as 8.9.9.9.
func resolveTarget(target, network string, resolve func(name, network string) []string) []string {
	if network == "" {
		return nil
	}
	if a, err := netip.ParseAddr(target); err == nil {
		if (a.Is4() && network != "ip6") || (!a.Is4() && network != "ip4") {
			return []string{a.String()}
		}
		return nil
	}
	if looseIPv4.MatchString(target) {
		return nil
	}
	return resolve(target, network)
}

// looseIPv4 is what inet_aton reads as an IPv4 address: one to four parts
// split by dots, each decimal, octal or hexadecimal (0x), a trailing dot
// apart; one written in full and canonical netip takes first.
var looseIPv4 = regexp.MustCompile(`^(0[xX][0-9a-fA-F]*|[0-9]+)(\.(0[xX][0-9a-fA-F]*|[0-9]+)){0,3}\.?$`)

// routeLink is a route's guard's end.
var routeLink = regexp.MustCompile(`^sp[0-9]+$`)

func sortedOnce(list []string) []string {
	slices.Sort(list)
	return slices.Compact(list)
}

// routeRules are the iptables-restore lines that install r's route: its
// two chains, the jumps to them and a role's forwarding, with what it
// takes of the static rules st.
func routeRules(r *route, st static) string {
	slot := strconv.Itoa(r.slot)
	iface := outerName(r.slot)
	inner := r.inner.String()
	mark := strconv.FormatUint(uint64(r.mark), 10)
	rc, pc := chainRoute+slot, chainPass+slot
	port := ""
	if r.reach == ReachRole {
		port = strconv.Itoa(r.port)
	}
	var b strings.Builder
	line := func(format string, args ...any) { fmt.Fprintf(&b, format+"\n", args...) }
	line("*filter")
	line(":%s - [0:0]", rc)
	line(":%s - [0:0]", pc)
	line("-A %s -m connmark --mark 0 -j CONNMARK --set-mark %s", pc, mark)
	line("-A %s -j ACCEPT", pc)
	b.WriteString(routeChain(r, st))
	line("-A %s -i %s -j %s", chainOut, iface, rc)
	line("-A %s -o %s -m connmark --mark %s -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT", chainIn, iface, mark)
	// A connection forwarded to the role, which took the route's mark as
	// it was forwarded. Through this route's pair, its destination is the
	// space's address: the rule names none, as iptables lists `-d` before
	// `-o` and every rule of a route in this chain is found by its `-o`.
	if port != "" {
		line("-A %s -o %s -p tcp --dport %s -m conntrack --ctstate DNAT --ctdir ORIGINAL -m connmark --mark %s -j ACCEPT", chainIn, iface, port, mark)
	}
	line("COMMIT")
	if port != "" {
		line("*nat")
		line("-A %s -p tcp --dport %s -m comment --comment %s -j CONNMARK --set-mark %s", chainRoles, port, iface, mark)
		line("-A %s -p tcp --dport %s -m comment --comment %s -j DNAT --to-destination %s:%s", chainRoles, port, iface, inner, port)
		line("COMMIT")
	}
	return b.String()
}

// routeChain is the lines of r's route chain, which judges every packet of
// its space's out through the route: from its own address alone, to no
// other route, then by its reach. A machine's change replaces them alone
// (changeRules).
func routeChain(r *route, st static) string {
	rc, pc := chainRoute+strconv.Itoa(r.slot), chainPass+strconv.Itoa(r.slot)
	var b strings.Builder
	line := func(format string, args ...any) { fmt.Fprintf(&b, format+"\n", args...) }
	line("-A %s ! -s %s/32 -j DROP", rc, r.inner)
	// A role's replies on the connections forwarded to it.
	if r.reach == ReachRole {
		line("-A %s -p tcp --sport %d -m conntrack --ctstate DNAT --ctdir REPLY -m connmark --mark %d -j ACCEPT", rc, r.port, r.mark)
	}
	line("-A %s -o sp+ -j REJECT --reject-with %s", rc, reject4)
	switch {
	case r.reach == ReachRole && r.private:
		if st.hostAddress != "" {
			line("-A %s -d %s/32 -p tcp --dport %s -j %s", rc, st.hostAddress, st.hostPort, pc)
		}
		line("-A %s -j %s", rc, chainRefuse)
		line("-A %s -d %s -j REJECT --reject-with %s", rc, st.rng, reject4)
		line("-A %s -j %s", rc, pc)
	case r.reach == ReachNone:
		// A machine with no live session reaches nothing past the guard.
		line("-A %s -j %s", rc, chainRefuse)
		line("-A %s -j REJECT --reject-with %s", rc, reject4)
	default:
		line("-A %s -j %s", rc, chainRefuse)
		for _, t := range st.targets {
			if family(t) == 4 {
				line("-A %s -d %s -j %s", rc, t, pc)
			}
		}
		line("-A %s -j %s", rc, chainPrivate)
		if r.reach == ReachHosts {
			for _, a := range r.addresses {
				if family(a) == 4 {
					line("-A %s -d %s/32 -j %s", rc, a, pc)
				}
			}
			line("-A %s -j REJECT --reject-with %s", rc, reject4)
		} else {
			line("-A %s -j %s", rc, pc)
		}
	}
	return b.String()
}

// changeRules are the iptables-restore lines that replace r's route chain
// with its reach's in one commit: declaring the chain flushes it, so the
// chain holds the old lines or the new ones and never neither.
func changeRules(r *route, st static) string {
	return "*filter\n:" + chainRoute + strconv.Itoa(r.slot) + " - [0:0]\n" + routeChain(r, st) + "COMMIT\n"
}

// installed is what the kernel lists of the route chains and jumps: each
// table's or chain's `iptables -S` text.
type installed struct {
	// r and p are the route's own chains, each "" where it is absent.
	r, p string
	// out, in and roles are the chains every route's jumps are in.
	out, in, roles string
}

// routeLines are the lines of the jump chains that are iface's: its jump
// out, its replies and a role's forwarding, in that order.
func routeLines(iface string, k installed) []string {
	var lines []string
	pick := func(text, prefix string, match func(string) bool) {
		for _, l := range strings.Split(text, "\n") {
			if strings.HasPrefix(l, prefix) && match(l) {
				lines = append(lines, l)
			}
		}
	}
	all := func(string) bool { return true }
	pick(k.out, "-A "+chainOut+" -i "+iface+" ", all)
	pick(k.in, "-A "+chainIn+" -o "+iface+" ", all)
	pick(k.roles, "-A "+chainRoles+" ", func(l string) bool { return strings.Contains(l, " --comment "+iface+" -j ") })
	return lines
}

// routeText is what the kernel holds of the route whose guard's end is
// iface: its two chains, the jumps to them and a role's forwarding, as
// iptables lists them. It is the route's record.
func routeText(iface string, k installed) string {
	var b strings.Builder
	b.WriteString(strings.TrimRight(k.r, "\n") + "\n")
	b.WriteString(strings.TrimRight(k.p, "\n") + "\n")
	for _, l := range routeLines(iface, k) {
		b.WriteString(l + "\n")
	}
	return b.String()
}

// removal is the iptables-restore lines that remove every chain and jump
// of the route whose guard's end is iface and a role's forwarding, the
// forwarding first; a chain k does not hold is not named.
func removal(iface string, k installed) string {
	slot := strings.TrimPrefix(iface, "sp")
	var b strings.Builder
	b.WriteString("*nat\n")
	lines := routeLines(iface, k)
	for _, l := range lines {
		if strings.HasPrefix(l, "-A "+chainRoles+" ") {
			b.WriteString("-D " + l[3:] + "\n")
		}
	}
	b.WriteString("COMMIT\n*filter\n")
	for _, l := range lines {
		if !strings.HasPrefix(l, "-A "+chainRoles+" ") {
			b.WriteString("-D " + l[3:] + "\n")
		}
	}
	chains := []struct{ name, listed string }{{chainRoute + slot, k.r}, {chainPass + slot, k.p}}
	for _, c := range chains {
		if c.listed != "" {
			b.WriteString("-F " + c.name + "\n")
		}
	}
	for _, c := range chains {
		if c.listed != "" {
			b.WriteString("-X " + c.name + "\n")
		}
	}
	b.WriteString("COMMIT\n")
	return b.String()
}

var (
	// digestDropped are the lines of a save the digest leaves out: its
	// comments, the routes' chains and the rules of the chains every
	// route's jumps are in.
	digestDropped = regexp.MustCompile(`^(#|:(` + chainRoute + `|` + chainPass + `)[0-9]+ |-A (` + chainRoute + `|` + chainPass + `)[0-9]+ |-A (` + chainOut + `|` + chainIn + `|` + chainRoles + `) )`)
	// counters are the packet and byte counters a save prints beside a
	// built-in chain's policy.
	counters = regexp.MustCompile(` \[[0-9]+:[0-9]+\]$`)
)

// digest is the digest of the static rules in the saves of both families'
// filter tables and the IPv4 nat table: the nat table's lines of the
// guard's own chains alone (Docker's resolver keeps rules of its own
// there), the save's comments and timestamps and the counters it prints
// beside each built-in chain's policy left out, since both move while the
// rules stand, and so are the routes (their chains, the jumps to them and
// the roles' forwarding), which the routes' records hold.
func digest(v4, v6, nat string) string {
	var kept []string
	keep := func(l string) {
		if !digestDropped.MatchString(l) {
			kept = append(kept, counters.ReplaceAllString(l, ""))
		}
	}
	for _, text := range []string{v4, v6} {
		for _, l := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
			keep(l)
		}
	}
	for _, l := range strings.Split(strings.TrimRight(nat, "\n"), "\n") {
		if strings.Contains(l, chainOwn) {
			keep(l)
		}
	}
	sum := sha256.Sum256([]byte(strings.Join(kept, "\n") + "\n"))
	return hex.EncodeToString(sum[:])
}

var (
	listedChain = regexp.MustCompile(`^-N (` + chainRoute + `|` + chainPass + `)([0-9]+)$`)
	listedJump  = []*regexp.Regexp{
		regexp.MustCompile(`^-A ` + chainOut + ` -i (sp[0-9]+) `),
		regexp.MustCompile(`^-A ` + chainIn + ` -o (sp[0-9]+) `),
		regexp.MustCompile(`^-A ` + chainRoles + ` .* --comment (sp[0-9]+) -j `),
	}
)

// routesListed are the routes the kernel holds a chain of, by guard's end,
// and those it holds a jump or a role's forwarding of, from the filter
// table's `iptables -S` and the roles' chain's, each sorted, each once.
func routesListed(filter, roles string) (chains, jumps []string) {
	for _, l := range strings.Split(filter, "\n") {
		if m := listedChain.FindStringSubmatch(l); m != nil {
			chains = append(chains, "sp"+m[2])
		}
	}
	for _, l := range strings.Split(filter+"\n"+roles, "\n") {
		for _, re := range listedJump {
			if m := re.FindStringSubmatch(l); m != nil {
				jumps = append(jumps, m[1])
			}
		}
	}
	return sortedOnce(chains), sortedOnce(jumps)
}

// errNotReady is a health check's refusal, already logged.
var errNotReady = errors.New("not ready")

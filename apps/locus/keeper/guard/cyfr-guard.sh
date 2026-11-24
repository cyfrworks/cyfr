#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# cyfr-guard: the egress guard of a Locus island. docker-compose.yml runs
# one for the builds island (locus-builds-guard) and one for the backends
# island (locus-backends-guard), each from the Locus image, holding
# NET_ADMIN and no other capability, in a namespace whose net.ipv4.ip_forward
# is 1 and net.ipv4.icmp_ratelimit 0 (compose's sysctls; the guard refuses
# to start otherwise). The island's service shares this container's network
# namespace (`network_mode: service:`), and starts only once this container
# is healthy: healthy means the ready file is present, the static rules it
# records are still installed and every route the guard holds is too, and
# the ready file is written only once every rule is in. A rule that cannot
# be installed ends the guard with an error naming it, before the ready
# file exists, so the island never starts behind a guard that holds fewer
# rules than these.
#
# Every build and every program's session runs in a space of its own, with
# its own network namespace, which the keeper makes; nothing of a space
# reaches this namespace's loopback, the island's service or another space.
# A routed space's one way out is its route (apps/locus/keeper/guard): a
# veth pair whose guard's end is sp<slot> here, a /30 of the route range,
# and the route's own chains, which `route` installs and `unroute` removes.
# The route range is the first IPv4 /16 of 10.0.0.0/8, from 10.213.0.0/16
# on, that overlaps none of this namespace's routes and none of the private
# hosts' addresses; with none free the guard ends naming every overlap.
#
# A space's packet leaving through its route is judged, every packet of it,
# by its route's chain (CYFR_GUARD_R<slot>), in this order:
#   1. its source must be the route's inner address, else it is dropped;
#   2. another space, through another sp interface, is refused;
#   3. every metadata address (METADATA_V4: link-local, the clouds' metadata
#      endpoints), the control plane (cyfr's fixed address on the default
#      network, CYFR_GUARD_CONTROL_PLANE) and every subnet of this
#      namespace's own interfaces (cyfr's island address, the island's
#      gateway and the island itself) are refused (CYFR_GUARD_REFUSE);
#   4. the addresses the private hosts CYFR_PRIVATE_EGRESS_TARGETS names
#      resolve to, the deployment's own registries and MCP servers, pass;
#      a name that does not resolve when the guard starts is logged and
#      opens nothing, and the guard resolves again when it restarts;
#   5. every other private address (PRIVATE_V4: loopback, RFC 1918, CGNAT,
#      the reserved and multicast ranges) is refused (CYFR_GUARD_PRIVATE);
#   6. a route of reach `island` passes everything else, the public
#      Internet; a route of reach `hosts` passes the addresses its keeper
#      admitted for it and refuses every other.
# What passes leaves masqueraded as this namespace's own address, and a
# connection it opens takes the route's mark as it is made, and never
# after: CONNMARK sets it only on a connection that carries no mark yet
# (through CYFR_GUARD_P<slot>; a route's mark is its own identity, a
# number the guard never gives twice in its life), so no route overwrites
# another's, an unreplied entry's included. A packet into a space
# passes only as a reply of a connection carrying its own route's mark,
# and a withdrawn route leaves no connection in the kernel's table (the
# control removes them as it removes the pair), so a later route that took
# its address inherits nothing of it. IPv6 has no route: a space's IPv6
# packet, and any packet a space sends to this namespace itself, is refused.
# A refusal answers the sender at once with an administratively-prohibited
# ICMP, which it sees as EHOSTUNREACH, never a timeout: the namespace's
# ICMP rate limit is off, so every refusal is answered.
#
# The namespace's own processes (the island's service, its keeper, this
# guard) are held as before (CYFR_GUARD, in OUTPUT): a packet of a tracked
# connection passes, and a new one is refused the metadata, the control
# plane and the island's subnets, and every private address but the
# namespace's loopback and the private hosts. What it sends into a space is
# refused, the ICMP that answers a space's refused packet apart.
#
#   cyfr-guard         install the rules, write the ready file, then serve
#                      the island's keeper its control on the socket
#                      CYFR_GUARD_CONTROL names (`cyfr-locus guard-control
#                      <socket> <range>`, apps/locus/keeper/guard). The
#                      control greets each connection naming the network
#                      namespace these rules judge, and a keeper in another
#                      namespace takes no answer from it.
#   cyfr-guard route <iface> <inner> <mark> island
#   cyfr-guard route <iface> <inner> <mark> hosts <address…>
#                      the control's: install the chains of the route whose
#                      guard's end is <iface> and space's address <inner>,
#                      with the connection mark <mark>, and record them
#                      (ROUTES/<iface>) as installed; only IPv4 addresses
#                      are installed, IPv6 having no route. A route that
#                      fails at any step is removed whole and exits 1
#   cyfr-guard unroute <iface>
#                      the control's: remove the route's chains and record;
#                      a route already gone is removed; exits 1 where a
#                      part could not be removed
#   cyfr-guard check   the health probe: the ready file is present, every
#                      rule table can be read, the static rules are the
#                      ones the file recorded when they were installed, and
#                      every route the guard recorded is installed as it was
#                      recorded, with no chain or jump of a route it holds
#                      no record of
#   cyfr-guard rules   print the static rules it would install, one command
#                      a line, and install none
#
# Environment:
#   CYFR_GUARD_CONTROL_PLANE     cyfr's fixed address on the default network
#   CYFR_PRIVATE_EGRESS_TARGETS  the private hosts, addresses or CIDRs the
#                                deployment's own outbound calls may reach,
#                                comma-separated (configuration-guide.md)
#   CYFR_GUARD_CONTROL           the control's socket, on a volume the
#                                island's service mounts read-only
#
# The routes change only under the lock on LOCK, which `route` and
# `unroute` take whole and `check` takes shared, and each change writes its
# record before it answers, so the probe compares the chains installed
# with what the guard recorded, never with a snapshot a later change took.
set -eu

READY_DIR=/run/cyfr-guard
READY="$READY_DIR/ready"
LOCK="$READY_DIR/lock"
ROUTES="$READY_DIR/routes"
TARGETS="$READY_DIR/targets"
RANGE="$READY_DIR/range"
CHAIN=CYFR_GUARD
KNOWN=CYFR_GUARD_KNOWN
REFUSE=CYFR_GUARD_REFUSE
PRIVATE=CYFR_GUARD_PRIVATE
OUT=CYFR_GUARD_ROUTES
IN=CYFR_GUARD_REPLIES
ROUTE_CHAIN=CYFR_GUARD_R
PASS_CHAIN=CYFR_GUARD_P
# Set by `cyfr-guard rules` alone, never from the environment.
PRINT_ONLY=

# BEGIN address table: written by `mix cyfr.gen.guard_table` from
# Prima.Cidr.address_table/0. Edit the table there and run the task; the
# suite fails on a copy that differs.
METADATA_V4='
169.254.0.0/16
100.100.100.200/32
192.0.0.192/32
'
METADATA_V6='
fe80::/10
fd00:ec2::254/128
::169.254.0.0/112
::100.100.100.200/128
::192.0.0.192/128
::ffff:169.254.0.0/112
::ffff:100.100.100.200/128
::ffff:192.0.0.192/128
::ffff:0:a9fe:0/112
::ffff:0:6464:64c8/128
::ffff:0:c000:c0/128
64:ff9b::a9fe:0/112
64:ff9b::6464:64c8/128
64:ff9b::c000:c0/128
64:ff9b:1:a9fe::/64
64:ff9b:1:6464:64:c800::/ffff:ffff:ffff:ffff:ff:ff00::
64:ff9b:1:c000:0:c000::/ffff:ffff:ffff:ffff:ff:ff00::
64:ff9b:1:a9:fe::/ffff:ffff:ffff:ff:ff::
64:ff9b:1:64:64:64c8::/ffff:ffff:ffff:ff:ff:ffff::
64:ff9b:1:c0:0:c0::/ffff:ffff:ffff:ff:ff:ffff::
64:ff9b:1:0:a9:fe00::/ffff:ffff:ffff:0:ff:ff00::
64:ff9b:1:0:64:6464:c800:0/ffff:ffff:ffff:0:ff:ffff:ff00:0
64:ff9b:1:0:c0:0:c000:0/ffff:ffff:ffff:0:ff:ffff:ff00:0
64:ff9b:1::a9fe:0/ffff:ffff:ffff::ffff:0
64:ff9b:1::6464:64c8/ffff:ffff:ffff::ffff:ffff
64:ff9b:1::c000:c0/ffff:ffff:ffff::ffff:ffff
2002:a9fe::/32
2002:6464:64c8::/48
2002:c000:c0::/48
2001:0:a9fe::/48
2001:0:6464:64c8::/64
2001:0:c000:c0::/64
2001::5601:0/ffff:ffff::ffff:0
2001::9b9b:9b37/ffff:ffff::ffff:ffff
2001::3fff:ff3f/ffff:ffff::ffff:ffff
::5efe:a9fe:0/::ffff:ffff:ffff:0
::5efe:6464:64c8/::ffff:ffff:ffff:ffff
::5efe:c000:c0/::ffff:ffff:ffff:ffff
::200:5efe:a9fe:0/::ffff:ffff:ffff:0
::200:5efe:6464:64c8/::ffff:ffff:ffff:ffff
::200:5efe:c000:c0/::ffff:ffff:ffff:ffff
'
PRIVATE_V4='
127.0.0.0/8
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
0.0.0.0/8
100.64.0.0/10
192.0.0.0/24
198.18.0.0/15
224.0.0.0/4
240.0.0.0/4
'
PRIVATE_V6='
fc00::/7
64:ff9b:1::/48
ff00::/8
::127.0.0.0/104
::10.0.0.0/104
::172.16.0.0/108
::192.168.0.0/112
::/104
::100.64.0.0/106
::192.0.0.0/120
::198.18.0.0/111
::224.0.0.0/100
::240.0.0.0/100
::ffff:127.0.0.0/104
::ffff:10.0.0.0/104
::ffff:172.16.0.0/108
::ffff:192.168.0.0/112
::ffff:0.0.0.0/104
::ffff:100.64.0.0/106
::ffff:192.0.0.0/120
::ffff:198.18.0.0/111
::ffff:224.0.0.0/100
::ffff:240.0.0.0/100
::ffff:0:7f00:0/104
::ffff:0:a00:0/104
::ffff:0:ac10:0/108
::ffff:0:c0a8:0/112
::ffff:0:0:0/104
::ffff:0:6440:0/106
::ffff:0:c000:0/120
::ffff:0:c612:0/111
::ffff:0:e000:0/100
::ffff:0:f000:0/100
64:ff9b::7f00:0/104
64:ff9b::a00:0/104
64:ff9b::ac10:0/108
64:ff9b::c0a8:0/112
64:ff9b::/104
64:ff9b::6440:0/106
64:ff9b::c000:0/120
64:ff9b::c612:0/111
64:ff9b::e000:0/100
64:ff9b::f000:0/100
2002:7f00::/24
2002:a00::/24
2002:ac10::/28
2002:c0a8::/32
2002::/24
2002:6440::/26
2002:c000::/40
2002:c612::/31
2002:e000::/20
2002:f000::/20
2001:0:7f00::/40
2001:0:a00::/40
2001:0:ac10::/44
2001:0:c0a8::/48
2001::/40
2001:0:6440::/42
2001:0:c000::/56
2001:0:c612::/47
2001:0:e000::/36
2001:0:f000::/36
2001::8000:0/ffff:ffff::ff00:0
2001::f500:0/ffff:ffff::ff00:0
2001::53e0:0/ffff:ffff::fff0:0
2001::3f57:0/ffff:ffff::ffff:0
2001::ff00:0/ffff:ffff::ff00:0
2001::9b80:0/ffff:ffff::ffc0:0
2001::3fff:ff00/ffff:ffff::ffff:ff00
2001::39ec:0/ffff:ffff::fffe:0
2001::1000:0/ffff:ffff::f000:0
2001::/ffff:ffff::f000:0
::5efe:7f00:0/::ffff:ffff:ff00:0
::5efe:a00:0/::ffff:ffff:ff00:0
::5efe:ac10:0/::ffff:ffff:fff0:0
::5efe:c0a8:0/::ffff:ffff:ffff:0
::5efe:0:0/::ffff:ffff:ff00:0
::5efe:6440:0/::ffff:ffff:ffc0:0
::5efe:c000:0/::ffff:ffff:ffff:ff00
::5efe:c612:0/::ffff:ffff:fffe:0
::5efe:e000:0/::ffff:ffff:f000:0
::5efe:f000:0/::ffff:ffff:f000:0
::200:5efe:7f00:0/::ffff:ffff:ff00:0
::200:5efe:a00:0/::ffff:ffff:ff00:0
::200:5efe:ac10:0/::ffff:ffff:fff0:0
::200:5efe:c0a8:0/::ffff:ffff:ffff:0
::200:5efe:0:0/::ffff:ffff:ff00:0
::200:5efe:6440:0/::ffff:ffff:ffc0:0
::200:5efe:c000:0/::ffff:ffff:ffff:ff00
::200:5efe:c612:0/::ffff:ffff:fffe:0
::200:5efe:e000:0/::ffff:ffff:f000:0
::200:5efe:f000:0/::ffff:ffff:f000:0
'
# END address table

log() { echo "[cyfr-guard] $*" >&2; }

# The static rules of both families' filter tables, digested: what the
# ready file records and the health probe compares. Each table is read on
# its own and a read that fails answers nothing, with status 1, so neither
# the ready file nor the probe ever holds a digest of a table that could
# not be read. The dump's timestamps and the packet counters it prints
# beside each built-in chain's policy are left out, since both move while
# the rules stand, and so are the routes (their chains and the jumps to
# them), which `routes_installed` holds to the guard's record.
digest() {
  v4="$(iptables-save -t filter)" || { log "error: iptables-save failed"; return 1; }
  v6="$(ip6tables-save -t filter)" || { log "error: ip6tables-save failed"; return 1; }
  sum="$(printf '%s\n%s\n' "$v4" "$v6" | sed -E -e '/^#/d' -e 's/ \[[0-9]+:[0-9]+\]$//' \
    -e "/^:(${ROUTE_CHAIN}|${PASS_CHAIN})[0-9]+ /d" -e "/^-A (${ROUTE_CHAIN}|${PASS_CHAIN})[0-9]+ /d" \
    -e "/^-A (${OUT}|${IN}) /d" | sha256sum | cut -d' ' -f1)"
  case "$sum" in
    ????????????????????????????????????????????????????????????????) printf '%s\n' "$sum" ;;
    *) log "error: no digest of the rules"; return 1 ;;
  esac
}

# The namespace's forwarding and ICMP rate limit, as a route needs them.
check_sysctls() {
  forward="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" || forward=""
  ratelimit="$(cat /proc/sys/net/ipv4/icmp_ratelimit 2>/dev/null)" || ratelimit=""
  [ "$forward" = 1 ] || { log "error: net.ipv4.ip_forward is '$forward' in this namespace, not 1: the guard's compose service sets it (sysctls)"; return 1; }
  [ "$ratelimit" = 0 ] || { log "error: net.ipv4.icmp_ratelimit is '$ratelimit' in this namespace, not 0: the guard's compose service sets it (sysctls)"; return 1; }
}

check() {
  [ -f "$READY" ] || { log "not ready: $READY is absent"; exit 1; }
  exec 9>"$LOCK"
  flock -s -w 2 9 || { log "not ready: the rules are changing"; exit 1; }
  check_sysctls || exit 1
  recorded="$(cat "$READY")"
  installed="$(digest)" || { log "not ready: a rule table could not be read"; exit 1; }
  [ "$recorded" = "$installed" ] || { log "not ready: the rules installed are not the ones recorded"; exit 1; }
  range="$(cat "$RANGE")"
  iptables -w 5 -t nat -C POSTROUTING -s "$range" ! -o sp+ -j MASQUERADE 2>/dev/null \
    || { log "not ready: the routes' masquerade for $range is not installed"; exit 1; }
  routes_installed || exit 1
}

# What the kernel holds of the route whose guard's end is $1: its two
# chains and the jumps to them, as iptables lists them.
route_text() {
  slot="${1#sp}"
  r4="$(iptables -w 5 -S "$ROUTE_CHAIN$slot" 2>/dev/null)" || return 1
  p4="$(iptables -w 5 -S "$PASS_CHAIN$slot" 2>/dev/null)" || return 1
  out="$(iptables -w 5 -S "$OUT")" || return 1
  in="$(iptables -w 5 -S "$IN")" || return 1
  printf '%s\n%s\n' "$r4" "$p4"
  printf '%s\n' "$out" | grep -e "^-A $OUT -i $1 " || true
  printf '%s\n' "$in" | grep -e "^-A $IN -o $1 " || true
}

# Whether every route the guard recorded is installed exactly as recorded,
# and no route it holds no record of has a chain or a jump: answers 1,
# naming what differs, otherwise.
routes_installed() {
  recorded=""
  if [ -d "$ROUTES" ]; then
    recorded="$(for record in "$ROUTES"/sp*; do [ -f "$record" ] && basename "$record"; done | grep -E '^sp[0-9]+$' | sort || true)"
  fi
  listed="$(iptables -w 5 -S)" || { log "not ready: the IPv4 rules could not be read"; return 1; }
  chains="$(printf '%s\n' "$listed" | sed -n -E "s/^-N (${ROUTE_CHAIN}|${PASS_CHAIN})([0-9]+)$/sp\2/p" | sort -u)"
  jumps="$(printf '%s\n' "$listed" | sed -n -E -e "s/^-A ${OUT} -i (sp[0-9]+) .*/\1/p" -e "s/^-A ${IN} -o (sp[0-9]+) .*/\1/p" | sort -u)"
  [ "$chains" = "$recorded" ] || { log "not ready: the routes' chains are not the routes the guard recorded"; return 1; }
  [ "$jumps" = "$recorded" ] || { log "not ready: the jumps to routes are not the routes the guard recorded"; return 1; }
  for iface in $recorded; do
    have="$(route_text "$iface")" || { log "not ready: route $iface could not be read"; return 1; }
    [ "$have" = "$(cat "$ROUTES/$iface")" ] || { log "not ready: route $iface is not installed as the guard recorded it"; return 1; }
  done
}

# A rule of one family, or the guard ends naming it; under `rules`, the
# rule printed.
v4() {
  if [ -n "$PRINT_ONLY" ]; then echo "iptables $*"; return; fi
  iptables -w 5 "$@" || { log "error: iptables $* failed"; exit 1; }
}
v6() {
  if [ -n "$PRINT_ONLY" ]; then echo "ip6tables $*"; return; fi
  ip6tables -w 5 "$@" || { log "error: ip6tables $* failed"; exit 1; }
}

# An address or CIDR's family: 6 where it holds a colon, else 4.
family() { case "$1" in *:*) echo 6 ;; *) echo 4 ;; esac; }

# The IPv4 destinations of this namespace's routes, the default route and
# the routes' own pairs apart, from the kernel's routing table, as
# `<address>/<prefix length>`; with `on-link`, the on-link routes of
# interfaces other than the loopback alone: the namespace's own subnets.
v4_routes() {
  awk -v onlink="${1:-}" '
    function octets(h) {
      return sprintf("%d.%d.%d.%d", hex(substr(h, 7, 2)), hex(substr(h, 5, 2)), hex(substr(h, 3, 2)), hex(substr(h, 1, 2)))
    }
    function hex(s,    i, n, c) {
      n = 0
      for (i = 1; i <= length(s); i++) { c = index("0123456789ABCDEF", toupper(substr(s, i, 1))) - 1; n = n * 16 + c }
      return n
    }
    function ones(h,    i, n, c, b) {
      n = 0
      for (i = 1; i <= length(h); i++) {
        c = hex(substr(h, i, 1))
        for (b = 8; b >= 1; b /= 2) if (c >= b) { n++; c -= b }
      }
      return n
    }
    NR > 1 && $1 != "lo" && $8 != "00000000" && (onlink == "" || $3 == "00000000") && $1 !~ /^sp[0-9]+$/ { print octets($2) "/" ones($8) }
  ' /proc/net/route | sort -u
}

# The IPv6 subnets of this namespace's interfaces other than the loopback,
# from the kernel's routing table: each on-link unicast route's prefix.
own_v6_subnets() {
  [ -r /proc/net/ipv6_route ] || return 0
  awk '
    function hex(s,    i, n) {
      n = 0
      for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", tolower(substr(s, i, 1))) - 1
      return n
    }
    $10 != "lo" && $10 !~ /^sp[0-9]+$/ && $2 != "00" && $5 == "00000000000000000000000000000000" && substr($1, 1, 2) != "ff" {
      p = ""
      for (i = 1; i <= 32; i += 4) p = p (i > 1 ? ":" : "") substr($1, i, 4)
      print p "/" hex($2)
    }
  ' /proc/net/ipv6_route | sort -u
}

# The addresses and CIDRs CYFR_PRIVATE_EGRESS_TARGETS names, one a line,
# each name resolved now and logged.
private_targets() {
  for target in $(printf '%s' "${CYFR_PRIVATE_EGRESS_TARGETS:-}" | tr ',' ' '); do
    case "$target" in
      */*) addresses="$target" ;;
      *) addresses="$(getent ahosts "$target" 2>/dev/null | awk '{print $1}' | sort -u)" ;;
    esac
    if [ -z "$addresses" ]; then
      log "private target $target resolves to nothing here: it opens nothing"
      continue
    fi
    for address in $addresses; do
      log "private target $target: $address passes"
      echo "$address"
    done
  done
}

# The route range: the first /16 of 10.0.0.0/8, from 10.213.0.0/16 on and
# round to 10.212.0.0/16, that overlaps none of the IPv4 routes and private
# hosts given, one an argument (an address is its /32). It logs each /16
# passed over and what it overlaps, and with none free ends naming them all.
route_range() {
  printf '%s\n' "$@" | awk '
    function num(a,    p) { split(a, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ {
      split($0, c, "/"); bits = (c[2] == "" ? 32 : c[2]) + 0
      size = 2 ^ (32 - bits); first = num(c[1]); first -= first % size
      n++; lo[n] = first; hi[n] = first + size - 1; name[n] = $0
    }
    END {
      for (k = 0; k < 256; k++) {
        b = (213 + k) % 256; start = (10 * 256 + b) * 65536; end = start + 65535; hit = ""
        for (i = 1; i <= n; i++) if (lo[i] <= end && start <= hi[i]) hit = hit (hit == "" ? "" : ", ") name[i]
        if (hit == "") { print "10." b ".0.0/16"; exit 0 }
        printf "[cyfr-guard] 10.%d.0.0/16 overlaps %s: the routes take another range\n", b, hit > "/dev/stderr"
        all = all (all == "" ? "" : "; ") "10." b ".0.0/16: " hit
      }
      printf "[cyfr-guard] error: no /16 of 10.0.0.0/8 is free for the routes of the spaces: the routes of this namespace and the private hosts overlap every one (%s)\n", all > "/dev/stderr"
      exit 1
    }
  '
}

add_rules() {
  control_plane="${CYFR_GUARD_CONTROL_PLANE:?names the fixed address of cyfr on the default network}"
  [ "$(family "$control_plane")" = 4 ] || { log "error: CYFR_GUARD_CONTROL_PLANE is '$control_plane', not an IPv4 address"; exit 1; }
  [ -n "$PRINT_ONLY" ] || check_sysctls || exit 1
  targets="$(private_targets)"
  v4targets="$(for t in $targets; do [ "$(family "$t")" = 4 ] && echo "$t"; done || true)"
  subnets="$(v4_routes on-link)"
  # shellcheck disable=SC2046,SC2086 # one argument per route and target
  range="$(route_range $(v4_routes) $v4targets)" || exit 1
  log "routes take $range"

  # The namespace's own processes: OUTPUT.
  v4 -N "$CHAIN"
  v6 -N "$CHAIN"
  v4 -A OUTPUT -j "$CHAIN"
  v6 -A OUTPUT -j "$CHAIN"
  # Into a space, nothing but the ICMP that answers its refused packets.
  v4 -A "$CHAIN" -o sp+ -p icmp -m conntrack --ctstate RELATED -j ACCEPT
  v4 -A "$CHAIN" -o sp+ -j REJECT --reject-with icmp-admin-prohibited
  v6 -A "$CHAIN" -o sp+ -j REJECT --reject-with icmp6-adm-prohibited
  v4 -A "$CHAIN" -m conntrack ! --ctstate NEW -j ACCEPT
  v6 -A "$CHAIN" -m conntrack ! --ctstate NEW -j ACCEPT
  for cidr in $METADATA_V4; do v4 -A "$CHAIN" -d "$cidr" -j REJECT --reject-with icmp-admin-prohibited; done
  for cidr in $METADATA_V6; do v6 -A "$CHAIN" -d "$cidr" -j REJECT --reject-with icmp6-adm-prohibited; done
  v4 -A "$CHAIN" -d "$control_plane/32" -j REJECT --reject-with icmp-admin-prohibited
  for subnet in $subnets; do
    log "island subnet $subnet"
    v4 -A "$CHAIN" -d "$subnet" -j REJECT --reject-with icmp-admin-prohibited
  done
  for subnet in $(own_v6_subnets); do
    log "island subnet $subnet"
    v6 -A "$CHAIN" -d "$subnet" -j REJECT --reject-with icmp6-adm-prohibited
  done
  v4 -A "$CHAIN" -o lo -j RETURN
  v6 -A "$CHAIN" -o lo -j RETURN
  for address in $targets; do
    if [ "$(family "$address")" = 6 ]; then v6 -A "$CHAIN" -d "$address" -j RETURN
    else v4 -A "$CHAIN" -d "$address" -j RETURN; fi
  done
  for cidr in $PRIVATE_V4; do v4 -A "$CHAIN" -d "$cidr" -j REJECT --reject-with icmp-admin-prohibited; done
  for cidr in $PRIVATE_V6; do v6 -A "$CHAIN" -d "$cidr" -j REJECT --reject-with icmp6-adm-prohibited; done

  # The spaces: FORWARD, INPUT and the masquerade. A route's chain jumps to
  # the first two for what every space is refused.
  v4 -N "$REFUSE"
  v4 -N "$PRIVATE"
  v4 -N "$OUT"
  v4 -N "$IN"
  for cidr in $METADATA_V4; do v4 -A "$REFUSE" -d "$cidr" -j REJECT --reject-with icmp-admin-prohibited; done
  v4 -A "$REFUSE" -d "$control_plane/32" -j REJECT --reject-with icmp-admin-prohibited
  for subnet in $subnets; do v4 -A "$REFUSE" -d "$subnet" -j REJECT --reject-with icmp-admin-prohibited; done
  for cidr in $PRIVATE_V4; do v4 -A "$PRIVATE" -d "$cidr" -j REJECT --reject-with icmp-admin-prohibited; done
  v4 -A FORWARD -i sp+ -j "$OUT"
  v4 -A FORWARD -i sp+ -j REJECT --reject-with icmp-admin-prohibited
  v4 -A FORWARD -o sp+ -j "$IN"
  v4 -A FORWARD -o sp+ -j REJECT --reject-with icmp-admin-prohibited
  v4 -A INPUT -i sp+ -j REJECT --reject-with icmp-admin-prohibited
  v6 -A FORWARD -i sp+ -j REJECT --reject-with icmp6-adm-prohibited
  v6 -A FORWARD -o sp+ -j REJECT --reject-with icmp6-adm-prohibited
  v6 -A INPUT -i sp+ -j REJECT --reject-with icmp6-adm-prohibited
  v4 -t nat -A POSTROUTING -s "$range" ! -o sp+ -j MASQUERADE
}

# Records the static rules now installed in the ready file, once, as the
# rules are installed.
record() {
  recorded="$(digest)" || { log "error: a rule table could not be read, so the guard is not ready"; return 1; }
  printf '%s\n' "$recorded" > "$READY.tmp"
  mv "$READY.tmp" "$READY"
}

# A route's guard's end, sp<slot>, or 1.
route_iface() {
  case "$1" in
    sp[0-9] | sp[1-9][0-9] | sp[1-9][0-9][0-9] | sp[1-9][0-9][0-9][0-9] | sp[1-9][0-9][0-9][0-9][0-9]) return 0 ;;
  esac
  log "error: '$1' is no route's interface"
  return 1
}

# A dotted IPv4 address, or 1.
dotted() {
  case "$1" in
    *[!0-9.]* | *..* | .* | *.) ;;
    *.*.*.*.*) ;;
    *.*.*.*) return 0 ;;
  esac
  log "error: '$1' is not an IPv4 address"
  return 1
}

# Removes every chain and jump of the route whose guard's end is $1, and
# its record, in one transaction; a route already gone is removed.
remove_route() {
  iface="$1"
  slot="${iface#sp}"
  out="$(iptables -w 5 -S "$OUT")" && in="$(iptables -w 5 -S "$IN")" \
    || { log "error: the routes' jumps could not be read"; return 1; }
  {
    echo "*filter"
    printf '%s\n' "$out" | grep -e "^-A $OUT -i $iface " | sed 's/^-A /-D /' || true
    printf '%s\n' "$in" | grep -e "^-A $IN -o $iface " | sed 's/^-A /-D /' || true
    for chain in "$ROUTE_CHAIN$slot" "$PASS_CHAIN$slot"; do
      iptables -w 5 -S "$chain" >/dev/null 2>&1 && echo "-F $chain"
    done
    for chain in "$ROUTE_CHAIN$slot" "$PASS_CHAIN$slot"; do
      iptables -w 5 -S "$chain" >/dev/null 2>&1 && echo "-X $chain"
    done
    echo "COMMIT"
  } | iptables-restore -w 5 --noflush || { log "error: route $iface's rules could not be removed"; return 1; }
  rm -f "${ROUTES:?}/${iface:?}" || { log "error: route $iface's record could not be dropped"; return 1; }
}

route() {
  iface="$1" inner="$2" mark="$3" reach="$4"
  shift 4
  route_iface "$iface" || exit 1
  dotted "$inner" || exit 1
  case "$mark" in
    "" | *[!0-9]* | 0*) log "error: '$mark' is not a mark"; exit 1 ;;
  esac
  [ "$mark" -le 4294967295 ] || { log "error: '$mark' is not a mark"; exit 1; }
  case "$reach" in
    island) [ $# -eq 0 ] || { log "error: a route of the island's reach names no addresses"; exit 1; } ;;
    hosts) [ $# -ge 1 ] || { log "error: a route of reach hosts names its addresses"; exit 1; } ;;
    *) log "error: '$reach' is no reach"; exit 1 ;;
  esac
  v4list=""
  for address in "$@"; do
    case "$address" in
      *:*) ;;
      *) dotted "$address" || exit 1; v4list="$v4list $address" ;;
    esac
  done
  exec 9>"$LOCK"
  flock 9
  r="$ROUTE_CHAIN${iface#sp}" p="$PASS_CHAIN${iface#sp}"
  remove_route "$iface" || exit 1
  if {
    echo "*filter"
    echo ":$r - [0:0]"
    echo ":$p - [0:0]"
    echo "-A $p -m connmark --mark 0 -j CONNMARK --set-mark $mark"
    echo "-A $p -j ACCEPT"
    echo "-A $r ! -s $inner/32 -j DROP"
    echo "-A $r -o sp+ -j REJECT --reject-with icmp-admin-prohibited"
    echo "-A $r -j $REFUSE"
    while IFS= read -r target; do
      if [ -n "$target" ] && [ "$(family "$target")" = 4 ]; then echo "-A $r -d $target -j $p"; fi
    done < "$TARGETS"
    echo "-A $r -j $PRIVATE"
    if [ "$reach" = island ]; then
      echo "-A $r -j $p"
    else
      for address in $v4list; do echo "-A $r -d $address/32 -j $p"; done
      echo "-A $r -j REJECT --reject-with icmp-admin-prohibited"
    fi
    echo "-A $OUT -i $iface -j $r"
    echo "-A $IN -o $iface -m connmark --mark $mark -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    echo "COMMIT"
  } | iptables-restore -w 5 --noflush; then :; else
    log "error: route $iface's rules failed"
    remove_route "$iface" || true
    exit 1
  fi
  mkdir -p "$ROUTES" && route_text "$iface" > "$ROUTES/$iface.tmp" && mv "$ROUTES/$iface.tmp" "$ROUTES/$iface" \
    || { log "error: route $iface could not be recorded"; remove_route "$iface" || true; exit 1; }
  log "route $iface for $inner ($reach$v4list) installed, mark $mark"
}

unroute() {
  route_iface "$1" || exit 1
  exec 9>"$LOCK"
  flock 9
  remove_route "$1" || exit 1
  log "route $1 removed"
}

install_rules() {
  rm -f "${READY:?}"
  rm -rf "${ROUTES:?}"
  mkdir -p "$READY_DIR" "$ROUTES"
  add_rules
  printf '%s\n' "$targets" | sed '/^$/d' > "$TARGETS"
  printf '%s\n' "$range" > "$RANGE"
  record || exit 1
  log "ready: every rule installed, routes in $range"
}

case "${1:-}" in
  "")
    install_rules
    exec cyfr-locus guard-control "${CYFR_GUARD_CONTROL:?names the control socket the island's keeper reaches the guard on}" "$range"
    ;;
  route)
    [ $# -ge 5 ] || { log "usage: cyfr-guard route <iface> <inner> <mark> island | hosts <address…>"; exit 2; }
    shift
    route "$@"
    ;;
  unroute)
    [ $# -eq 2 ] || { log "usage: cyfr-guard unroute <iface>"; exit 2; }
    unroute "$2"
    ;;
  check)
    check
    ;;
  rules)
    PRINT_ONLY=1
    add_rules
    ;;
  *)
    log "usage: cyfr-guard [route <iface> <inner> <mark> island | hosts <address…> | unroute <iface> | check | rules]"
    exit 2
    ;;
esac

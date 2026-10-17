#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# cyfr-guard: the egress guard of a Locus island. docker-compose.yml runs
# one for the builds island (locus-builds-guard) and one for the backends
# island (locus-backends-guard), each from the Locus image, holding
# NET_ADMIN and no other capability. The island's service shares this
# container's network namespace (`network_mode: service:`), so every packet
# a build or a backend sends is judged by the rules installed here, in the
# OUTPUT chain of both address families, and the island starts only once
# this container is healthy: healthy means the ready file is present and
# the rules it records are still installed, and the ready file is written
# only once every rule is in. A rule that cannot be installed ends the
# guard with an error naming it, before the ready file exists, so the
# island never starts behind a guard that holds fewer rules than these.
#
# What the rules refuse, for a new connection, in this order (a reply to a
# connection cyfr opened to the island is never new). The metadata and
# private rows are Prima.Cidr's address table (`Prima.Cidr.address_table/0`),
# the one the control plane's own outbound calls are held to, written into
# this script between its BEGIN and END lines by `mix cyfr.gen.guard_table`;
# the rest are the island's own:
#   1. every metadata address: link-local, the clouds' metadata endpoints
#      and every IPv6 form embedding one (METADATA_V4, METADATA_V6);
#   2. the control plane: cyfr's fixed address on the default network
#      (CYFR_GUARD_CONTROL_PLANE) and every subnet of this namespace's own
#      interfaces, which hold cyfr's address on the island's network, the
#      island's gateway and the island itself;
#   3. from the island's spawn uids (CYFR_GUARD_POOL), every address of this
#      namespace, so a spawn reaches no listener of another spawn on the
#      shared loopback, nor the island's service, except Docker's resolver
#      at 127.0.0.11:53;
#   4. every private address (PRIVATE_V4, PRIVATE_V6: loopback, RFC 1918,
#      CGNAT, the reserved and multicast ranges, unique-local and every
#      IPv6 form embedding a private IPv4 address), except the island's
#      service's own loopback, which rule 3 already holds the spawns off,
#      and the addresses the private hosts CYFR_PRIVATE_EGRESS_TARGETS
#      names resolve to, which are the deployment's own registries and MCP
#      servers. A name that does not resolve when the guard starts is logged
#      and opens nothing; the guard resolves again when it restarts.
# Everything else, the public Internet, passes. A refusal answers the
# sender at once with an administratively-prohibited ICMP, which the
# sender sees as EHOSTUNREACH (EACCES over IPv6), never a timeout.
#
# Docker's resolver takes a spawn's query at 127.0.0.11:53 through a NAT
# rule of its own, so the packet the filter sees carries the rewritten
# port: the exception matches the connection's original destination.
#
#   cyfr-guard         install the rules, write the ready file and sleep
#   cyfr-guard check   the health probe: the ready file is present, both
#                      rule tables can be read, and the rules they hold are
#                      the ones the file records
#   cyfr-guard rules   print the rules it would install, one command a line,
#                      and install none
#
# Environment:
#   CYFR_GUARD_POOL              the island's spawn uids, `<first>-<last>`
#   CYFR_GUARD_CONTROL_PLANE     cyfr's fixed address on the default network
#   CYFR_PRIVATE_EGRESS_TARGETS  the private hosts, addresses or CIDRs the
#                                deployment's own outbound calls may reach,
#                                comma-separated (configuration-guide.md)
set -eu

READY_DIR=/run/cyfr-guard
READY="$READY_DIR/ready"
CHAIN=CYFR_GUARD
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

# The filter tables of both families, digested: what the ready file
# records and the health probe compares. Each table is read on its own and
# a read that fails answers nothing, with status 1, so neither the ready
# file nor the probe ever holds a digest of a table that could not be
# read. The dump's timestamps and the packet counters it prints beside each
# built-in chain's policy are left out, since both move while the rules
# stand.
digest() {
  v4="$(iptables-save -t filter)" || { log "error: iptables-save failed"; return 1; }
  v6="$(ip6tables-save -t filter)" || { log "error: ip6tables-save failed"; return 1; }
  sum="$(printf '%s\n%s\n' "$v4" "$v6" | sed -E -e '/^#/d' -e 's/ \[[0-9]+:[0-9]+\]$//' | sha256sum | cut -d' ' -f1)"
  case "$sum" in
    ????????????????????????????????????????????????????????????????) printf '%s\n' "$sum" ;;
    *) log "error: no digest of the rules"; return 1 ;;
  esac
}

check() {
  [ -f "$READY" ] || { log "not ready: $READY is absent"; exit 1; }
  recorded="$(cat "$READY")"
  installed="$(digest)" || { log "not ready: a rule table could not be read"; exit 1; }
  [ "$recorded" = "$installed" ] || { log "not ready: the rules installed are not the ones recorded"; exit 1; }
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

# The IPv4 subnets of this namespace's interfaces other than the
# loopback, from the kernel's routing table: each on-link route's
# destination and mask, hexadecimal and little-endian there, as
# `<address>/<prefix length>`.
own_v4_subnets() {
  awk '
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
    NR > 1 && $1 != "lo" && $2 != "00000000" && $3 == "00000000" { print octets($2) "/" ones($8) }
  ' /proc/net/route
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
    $10 != "lo" && $2 != "00" && $5 == "00000000000000000000000000000000" && substr($1, 1, 2) != "ff" {
      p = ""
      for (i = 1; i <= 32; i += 4) p = p (i > 1 ? ":" : "") substr($1, i, 4)
      print p "/" hex($2)
    }
  ' /proc/net/ipv6_route | sort -u
}

add_rules() {
  pool="${CYFR_GUARD_POOL:?names the island spawn uids as <first>-<last>}"
  control_plane="${CYFR_GUARD_CONTROL_PLANE:?names the fixed address of cyfr on the default network}"
  case "$pool" in
    [0-9]*-[0-9]*) ;;
    *) log "error: CYFR_GUARD_POOL is '$pool', not <first>-<last>"; exit 1 ;;
  esac
  [ "$(family "$control_plane")" = 4 ] || { log "error: CYFR_GUARD_CONTROL_PLANE is '$control_plane', not an IPv4 address"; exit 1; }

  v4 -N "$CHAIN"
  v6 -N "$CHAIN"
  v4 -A OUTPUT -j "$CHAIN"
  v6 -A OUTPUT -j "$CHAIN"
  v4 -A "$CHAIN" -m conntrack ! --ctstate NEW -j RETURN
  v6 -A "$CHAIN" -m conntrack ! --ctstate NEW -j RETURN

  # 1. metadata
  for range in $METADATA_V4; do v4 -A "$CHAIN" -d "$range" -j REJECT --reject-with icmp-admin-prohibited; done
  for range in $METADATA_V6; do v6 -A "$CHAIN" -d "$range" -j REJECT --reject-with icmp6-adm-prohibited; done

  # 2. the control plane: cyfr's fixed address, and every subnet this
  # namespace sits on, cyfr's island address among them
  v4 -A "$CHAIN" -d "$control_plane/32" -j REJECT --reject-with icmp-admin-prohibited
  for subnet in $(own_v4_subnets); do
    log "island subnet $subnet"
    v4 -A "$CHAIN" -d "$subnet" -j REJECT --reject-with icmp-admin-prohibited
  done
  for subnet in $(own_v6_subnets); do
    log "island subnet $subnet"
    v6 -A "$CHAIN" -d "$subnet" -j REJECT --reject-with icmp6-adm-prohibited
  done

  # 3. the spawns' reach into this namespace: the resolver alone
  v4 -A "$CHAIN" -m owner --uid-owner "$pool" -m conntrack --ctorigdst 127.0.0.11 --ctorigdstport 53 -j RETURN
  v4 -A "$CHAIN" -m owner --uid-owner "$pool" -m addrtype --dst-type LOCAL -j REJECT --reject-with icmp-admin-prohibited
  v6 -A "$CHAIN" -m owner --uid-owner "$pool" -m addrtype --dst-type LOCAL -j REJECT --reject-with icmp6-adm-prohibited

  # 4. the service's own loopback (rule 3 has refused the spawns theirs)
  # and the deployment's private hosts, then every other private address
  v4 -A "$CHAIN" -o lo -m owner ! --uid-owner "$pool" -j RETURN
  v6 -A "$CHAIN" -o lo -m owner ! --uid-owner "$pool" -j RETURN
  targets="$(printf '%s' "${CYFR_PRIVATE_EGRESS_TARGETS:-}" | tr ',' ' ')"
  for target in $targets; do
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
      if [ "$(family "$address")" = 6 ]; then
        v6 -A "$CHAIN" -d "$address" -j RETURN
      else
        v4 -A "$CHAIN" -d "$address" -j RETURN
      fi
    done
  done
  for range in $PRIVATE_V4; do v4 -A "$CHAIN" -d "$range" -j REJECT --reject-with icmp-admin-prohibited; done
  for range in $PRIVATE_V6; do v6 -A "$CHAIN" -d "$range" -j REJECT --reject-with icmp6-adm-prohibited; done
}

install_rules() {
  rm -f "$READY"
  add_rules
  mkdir -p "$READY_DIR"
  recorded="$(digest)" || { log "error: a rule table could not be read, so the guard is not ready"; exit 1; }
  printf '%s\n' "$recorded" > "$READY.tmp"
  mv "$READY.tmp" "$READY"
  log "ready: every rule installed for spawns $pool"
}

case "${1:-}" in
  "")
    install_rules
    exec sleep infinity
    ;;
  check)
    check
    ;;
  rules)
    PRINT_ONLY=1
    add_rules
    ;;
  *)
    log "usage: cyfr-guard [check | rules]"
    exit 2
    ;;
esac

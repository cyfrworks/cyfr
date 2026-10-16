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
# connection cyfr opened to the island is never new):
#   1. every link-local and metadata address: 169.254.0.0/16, fe80::/10,
#      fd00:ec2::254 and 100.100.100.200;
#   2. the control plane: cyfr's fixed address on the default network
#      (CYFR_GUARD_CONTROL_PLANE) and every subnet of this namespace's own
#      interfaces, which hold cyfr's address on the island's network, the
#      island's gateway and the island itself;
#   3. from the island's spawn uids (CYFR_GUARD_POOL), every address of this
#      namespace, so a spawn reaches no listener of another spawn on the
#      shared loopback, nor the island's service, except Docker's resolver
#      at 127.0.0.11:53;
#   4. every other private address, 10.0.0.0/8, 172.16.0.0/12,
#      192.168.0.0/16 and fc00::/7, except the addresses the private hosts
#      CYFR_PRIVATE_EGRESS_TARGETS names resolve to, which are the
#      deployment's own registries and MCP servers. A name that does not
#      resolve when the guard starts is logged and opens nothing; the guard
#      resolves again when it restarts.
# Everything else, the public Internet, passes. A refusal answers the
# sender at once with an administratively-prohibited ICMP, which the
# sender sees as EHOSTUNREACH (EACCES over IPv6), never a timeout.
#
# Docker's resolver takes a spawn's query at 127.0.0.11:53 through a NAT
# rule of its own, so the packet the filter sees carries the rewritten
# port: the exception matches the connection's original destination.
#
#   cyfr-guard         install the rules, write the ready file and sleep
#   cyfr-guard check   the health probe: the ready file is present and the
#                      rules it records are the ones installed
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

log() { echo "[cyfr-guard] $*" >&2; }

# The filter tables of both families, digested: what the ready file
# records and the health probe compares. The dump's timestamps and the
# packet counters it prints beside each built-in chain's policy are left
# out, since both move while the rules stand.
digest() {
  { iptables-save -t filter; ip6tables-save -t filter; } |
    sed -E -e '/^#/d' -e 's/ \[[0-9]+:[0-9]+\]$//' | sha256sum | cut -d' ' -f1
}

check() {
  [ -f "$READY" ] || { log "not ready: $READY is absent"; exit 1; }
  recorded="$(cat "$READY")"
  installed="$(digest)"
  [ "$recorded" = "$installed" ] || { log "not ready: the rules installed are not the ones recorded"; exit 1; }
}

# A rule of one family, or the guard ends naming it.
v4() { iptables -w 5 "$@" || { log "error: iptables $* failed"; exit 1; }; }
v6() { ip6tables -w 5 "$@" || { log "error: ip6tables $* failed"; exit 1; }; }

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

install_rules() {
  pool="${CYFR_GUARD_POOL:?names the island spawn uids as <first>-<last>}"
  control_plane="${CYFR_GUARD_CONTROL_PLANE:?names the fixed address of cyfr on the default network}"
  case "$pool" in
    [0-9]*-[0-9]*) ;;
    *) log "error: CYFR_GUARD_POOL is '$pool', not <first>-<last>"; exit 1 ;;
  esac
  [ "$(family "$control_plane")" = 4 ] || { log "error: CYFR_GUARD_CONTROL_PLANE is '$control_plane', not an IPv4 address"; exit 1; }

  rm -f "$READY"
  v4 -N "$CHAIN"
  v6 -N "$CHAIN"
  v4 -A OUTPUT -j "$CHAIN"
  v6 -A OUTPUT -j "$CHAIN"
  v4 -A "$CHAIN" -m conntrack ! --ctstate NEW -j RETURN
  v6 -A "$CHAIN" -m conntrack ! --ctstate NEW -j RETURN

  # 1. link-local and metadata
  v4 -A "$CHAIN" -d 169.254.0.0/16 -j REJECT --reject-with icmp-admin-prohibited
  v4 -A "$CHAIN" -d 100.100.100.200/32 -j REJECT --reject-with icmp-admin-prohibited
  v6 -A "$CHAIN" -d fe80::/10 -j REJECT --reject-with icmp6-adm-prohibited
  v6 -A "$CHAIN" -d fd00:ec2::254/128 -j REJECT --reject-with icmp6-adm-prohibited

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

  # 4. the deployment's private hosts, then every other private address
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
  v4 -A "$CHAIN" -d 10.0.0.0/8 -j REJECT --reject-with icmp-admin-prohibited
  v4 -A "$CHAIN" -d 172.16.0.0/12 -j REJECT --reject-with icmp-admin-prohibited
  v4 -A "$CHAIN" -d 192.168.0.0/16 -j REJECT --reject-with icmp-admin-prohibited
  v6 -A "$CHAIN" -d fc00::/7 -j REJECT --reject-with icmp6-adm-prohibited

  mkdir -p "$READY_DIR"
  digest > "$READY.tmp"
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
  *)
    log "usage: cyfr-guard [check]"
    exit 2
    ;;
esac

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
# this container is healthy: healthy means the ready file is present, the
# static rules it records are still installed and every admission the
# guard holds is too, and the ready file is written only once every rule
# is in. A rule that cannot be installed ends the
# guard with an error naming it, before the ready file exists, so the
# island never starts behind a guard that holds fewer rules than these.
#
# A packet of a connection the kernel already tracks, such as a reply to a
# connection cyfr opened to the island or the rest of one a rule below let
# through, passes (CYFR_GUARD_KNOWN), but for a uid whose row names its
# hosts: rule 5's chain judges every packet of such a uid again, with the
# resolver and the private hosts passing for it there too, since the
# kernel tracks a connection by its addresses and ports alone and state
# one uid left would otherwise serve another that reuses them.
#
# What the rules refuse, for a new connection, in this order. The metadata and
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
#   3. from the island's spawn uids (CYFR_GUARD_POOL: every range its
#      keeper runs a spawn under, its pool and, on the backends island, the
#      kept folders' uids, one rule per range), every address of this
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
#   5. from a spawn uid whose program's row names its hosts, every address
#      but the ones its keeper admitted for it (CYFR_GUARD_HOSTS jumps to
#      the uid's own chain, CYFR_GUARD_U<uid>, which returns each admitted
#      address and refuses the rest). The rules before this one stand for
#      it as for every spawn: an admitted address that is metadata, the
#      control plane or private is still refused, and the resolver and the
#      private hosts still pass, so a row's list narrows the public rule
#      and never widens it.
# Everything else, the public Internet, passes. A refusal answers the
# sender at once with an administratively-prohibited ICMP, which the
# sender sees as EHOSTUNREACH (EACCES over IPv6), never a timeout.
#
# Docker's resolver takes a spawn's query at 127.0.0.11:53 through a NAT
# rule of its own, so the packet the filter sees carries the rewritten
# port: the exception matches the connection's original destination.
#
#   cyfr-guard         install the rules, write the ready file, then serve
#                      the island's keeper its control on the socket
#                      CYFR_GUARD_CONTROL names (`cyfr-locus guard-control`,
#                      apps/locus/keeper/guard), or sleep where it names none.
#                      The control greets each connection naming the
#                      network namespace these rules judge (as
#                      /proc/self/ns/net links to it), and a keeper in
#                      another namespace takes no answer from it and refuses
#                      every spawn: a guard that restarted took a new
#                      namespace while the service still runs in the old
#                      one, where no admission of its would hold.
#   cyfr-guard admit <uid> [address…]
#                      the control's: give the spawn uid exactly these
#                      addresses under rule 5, replacing what it held (no
#                      address refuses it every public one), and record the
#                      admission (ADMITTED/<uid>, its addresses one a line);
#                      a change that fails leaves the uid refused every
#                      public address, recorded so, and exits 1
#   cyfr-guard clear <uid>
#                      the control's: return the uid to the island's rule
#                      and drop its record
#   cyfr-guard check   the health probe: the ready file is present, both
#                      rule tables can be read, their static rules are the
#                      ones the file recorded when they were installed (no
#                      admission records them again), every spawn range has
#                      its rules among them, and every admission the guard
#                      recorded is installed exactly, its uid's chain and
#                      the jump to it in both families, with no chain or
#                      jump of a uid it did not admit
#   cyfr-guard rules   print the rules it would install, one command a line,
#                      and install none
#
# Environment:
#   CYFR_GUARD_POOL              the island's spawn uids: every range its
#                                keeper runs a spawn under, `<first>-<last>`,
#                                comma-separated
#   CYFR_GUARD_CONTROL_PLANE     cyfr's fixed address on the default network
#   CYFR_PRIVATE_EGRESS_TARGETS  the private hosts, addresses or CIDRs the
#                                deployment's own outbound calls may reach,
#                                comma-separated (configuration-guide.md)
#   CYFR_GUARD_CONTROL           the control's socket, on a volume the
#                                island's service mounts read-only; unset,
#                                the island takes no list and no uid is
#                                ever admitted
#
# The admissions change only under the lock on LOCK, which `admit` and
# `clear` take whole and `check` takes shared, and each change writes its
# record before it answers, so the probe compares the chains installed
# with what the guard admitted, never with a snapshot a later change took.
set -eu

READY_DIR=/run/cyfr-guard
READY="$READY_DIR/ready"
LOCK="$READY_DIR/lock"
ADMITTED="$READY_DIR/admitted"
CHAIN=CYFR_GUARD
HOSTS=CYFR_GUARD_HOSTS
KNOWN=CYFR_GUARD_KNOWN
UID_CHAIN=CYFR_GUARD_U
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
# the rules stand, and so are the admissions (the uids' chains and the
# jumps to them), which `admissions_installed` holds to the guard's record.
digest() {
  v4="$(iptables-save -t filter)" || { log "error: iptables-save failed"; return 1; }
  v6="$(ip6tables-save -t filter)" || { log "error: ip6tables-save failed"; return 1; }
  sum="$(printf '%s\n%s\n' "$v4" "$v6" | sed -E -e '/^#/d' -e 's/ \[[0-9]+:[0-9]+\]$//' \
    -e "/^:${UID_CHAIN}[0-9]+ /d" -e "/^-A ${UID_CHAIN}[0-9]+ /d" -e "/^-A ${HOSTS} /d" | sha256sum | cut -d' ' -f1)"
  case "$sum" in
    ????????????????????????????????????????????????????????????????) printf '%s\n' "$sum" ;;
    *) log "error: no digest of the rules"; return 1 ;;
  esac
}

check() {
  [ -f "$READY" ] || { log "not ready: $READY is absent"; exit 1; }
  exec 9>"$LOCK"
  flock -s -w 2 9 || { log "not ready: the rules are changing"; exit 1; }
  recorded="$(cat "$READY")"
  installed="$(digest)" || { log "not ready: a rule table could not be read"; exit 1; }
  [ "$recorded" = "$installed" ] || { log "not ready: the rules installed are not the ones recorded"; exit 1; }
  # The digest proves the rules unchanged since they were recorded; this
  # proves they are the ones for every range the island spawns under.
  ranges="$(spawn_ranges)" || exit 1
  v4rules="$(iptables -w 5 -S "$CHAIN")" || { log "not ready: the IPv4 rules could not be read"; exit 1; }
  for range in $ranges; do
    case "$v4rules" in
      *"--uid-owner $range -m addrtype --dst-type LOCAL -j REJECT"*) ;;
      *) log "not ready: no rule holds spawns $range off this namespace"; exit 1 ;;
    esac
  done
  admissions_installed || exit 1
}

# The uids the guard admitted, one a line, from their records.
admitted_uids() {
  [ -d "$ADMITTED" ] || return 0
  for record in "$ADMITTED"/*; do
    [ -f "$record" ] && basename "$record"
  done | sort -n
}

# Whether every admission the guard recorded is installed exactly, in both
# families, and no uid it did not admit has a chain or a jump: answers 1,
# naming what differs, otherwise.
admissions_installed() {
  uids="$(admitted_uids)"
  for family in 4 6; do
    if [ "$family" = 4 ]; then tool=iptables reject=icmp-admin-prohibited bits=32
    else tool=ip6tables reject=icmp6-adm-prohibited bits=128; fi
    listed="$("$tool" -w 5 -S)" || { log "not ready: the $tool rules could not be read"; return 1; }
    chains="$(printf '%s\n' "$listed" | sed -n "s/^-N \(${UID_CHAIN}[0-9][0-9]*\)$/\1/p" | sort)"
    want_chains="$(for uid in $uids; do echo "$UID_CHAIN$uid"; done | sort)"
    [ "$chains" = "$want_chains" ] || { log "not ready: the $tool chains of uids are not the ones the guard admitted"; return 1; }
    jumps="$(printf '%s\n' "$listed" | grep "^-A $HOSTS " | sort)"
    want_jumps="$(for uid in $uids; do echo "-A $HOSTS -m owner --uid-owner $uid -j $UID_CHAIN$uid"; done | sort)"
    [ "$jumps" = "$want_jumps" ] || { log "not ready: the $tool jumps to uids' chains are not the ones the guard admitted"; return 1; }
    for uid in $uids; do
      chain="$UID_CHAIN$uid"
      want="$(echo "-N $chain"
        while IFS= read -r address; do
          case "$address" in
            *:*) [ "$family" = 6 ] && echo "-A $chain -d $address/$bits -j RETURN" ;;
            ?*) [ "$family" = 4 ] && echo "-A $chain -d $address/$bits -j RETURN" ;;
          esac
        done < "$ADMITTED/$uid"
        echo "-A $chain -j REJECT --reject-with $reject")"
      have="$(printf '%s\n' "$listed" | grep -e "^-N $chain\$" -e "^-A $chain ")"
      [ "$have" = "$want" ] || { log "not ready: uid $uid's admission is not installed as the guard admitted it ($tool)"; return 1; }
    done
  done
}

# The island's spawn uid ranges, CYFR_GUARD_POOL's comma-separated
# `<first>-<last>` entries, one a line; a malformed or empty list ends the
# guard naming it.
spawn_ranges() {
  list="${CYFR_GUARD_POOL:?names the island spawn uids as <first>-<last>, comma-separated}"
  ranges="$(printf '%s' "$list" | tr ',' ' ')"
  [ -n "$ranges" ] || { log "error: CYFR_GUARD_POOL names no range"; return 1; }
  for range in $ranges; do
    case "$range" in
      *[!0-9-]* | -* | *- | *-*-* | [!0-9]*) log "error: CYFR_GUARD_POOL holds '$range', not <first>-<last>"; return 1 ;;
      *-*) ;;
      *) log "error: CYFR_GUARD_POOL holds '$range', not <first>-<last>"; return 1 ;;
    esac
    echo "$range"
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

add_rules() {
  ranges="$(spawn_ranges)" || exit 1
  control_plane="${CYFR_GUARD_CONTROL_PLANE:?names the fixed address of cyfr on the default network}"
  [ "$(family "$control_plane")" = 4 ] || { log "error: CYFR_GUARD_CONTROL_PLANE is '$control_plane', not an IPv4 address"; exit 1; }

  v4 -N "$CHAIN"
  v6 -N "$CHAIN"
  v4 -N "$HOSTS"
  v6 -N "$HOSTS"
  v4 -N "$KNOWN"
  v6 -N "$KNOWN"
  v4 -A OUTPUT -j "$CHAIN"
  v6 -A OUTPUT -j "$CHAIN"
  v4 -A "$CHAIN" -m conntrack ! --ctstate NEW -j "$KNOWN"
  v6 -A "$CHAIN" -m conntrack ! --ctstate NEW -j "$KNOWN"

  # A tracked connection's packet: the resolver and the private hosts
  # pass, a listed uid's goes through its own chain (rule 5), and every
  # other passes.
  targets="$(private_targets)"
  v4 -A "$KNOWN" -m conntrack --ctorigdst 127.0.0.11 --ctorigdstport 53 -j ACCEPT
  for address in $targets; do
    if [ "$(family "$address")" = 6 ]; then v6 -A "$KNOWN" -d "$address" -j ACCEPT
    else v4 -A "$KNOWN" -d "$address" -j ACCEPT; fi
  done
  v4 -A "$KNOWN" -j "$HOSTS"
  v6 -A "$KNOWN" -j "$HOSTS"
  v4 -A "$KNOWN" -j ACCEPT
  v6 -A "$KNOWN" -j ACCEPT

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

  # 3. the spawns' reach into this namespace: the resolver alone, for
  # every range
  for range in $ranges; do
    v4 -A "$CHAIN" -m owner --uid-owner "$range" -m conntrack --ctorigdst 127.0.0.11 --ctorigdstport 53 -j RETURN
    v4 -A "$CHAIN" -m owner --uid-owner "$range" -m addrtype --dst-type LOCAL -j REJECT --reject-with icmp-admin-prohibited
    v6 -A "$CHAIN" -m owner --uid-owner "$range" -m addrtype --dst-type LOCAL -j REJECT --reject-with icmp6-adm-prohibited
  done

  # 4. the service's own loopback, for a uid of no spawn range (rule 3 has
  # refused the spawns theirs), and the deployment's private hosts, then
  # every other private address
  outside=""
  for range in $ranges; do outside="$outside -m owner ! --uid-owner $range"; done
  # shellcheck disable=SC2086 # one match per range, word-split on purpose
  v4 -A "$CHAIN" -o lo $outside -j RETURN
  # shellcheck disable=SC2086
  v6 -A "$CHAIN" -o lo $outside -j RETURN
  for address in $targets; do
    if [ "$(family "$address")" = 6 ]; then v6 -A "$CHAIN" -d "$address" -j RETURN
    else v4 -A "$CHAIN" -d "$address" -j RETURN; fi
  done
  for range in $PRIVATE_V4; do v4 -A "$CHAIN" -d "$range" -j REJECT --reject-with icmp-admin-prohibited; done
  for range in $PRIVATE_V6; do v6 -A "$CHAIN" -d "$range" -j REJECT --reject-with icmp6-adm-prohibited; done

  # 5. the spawns whose rows name their hosts: each admitted uid's chain
  v4 -A "$CHAIN" -j "$HOSTS"
  v6 -A "$CHAIN" -j "$HOSTS"
}

# Records the static rules now installed in the ready file, once, as the
# rules are installed.
record() {
  recorded="$(digest)" || { log "error: a rule table could not be read, so the guard is not ready"; return 1; }
  printf '%s\n' "$recorded" > "$READY.tmp"
  mv "$READY.tmp" "$READY"
}

# A uid of one of the spawn ranges, or 1.
spawn_uid() {
  case "$1" in
    "" | *[!0-9]* | 0*) log "error: '$1' is not a uid"; return 1 ;;
  esac
  for range in $(spawn_ranges); do
    [ "$1" -ge "${range%-*}" ] && [ "$1" -le "${range#*-}" ] && return 0
  done
  log "error: uid $1 is no spawn's of this island"
  return 1
}

# Installs one family's chain for uid in one transaction: each address
# returned, every other refused, and the jump to it once.
uid_chain() {
  family="$1" uid="$2"
  shift 2
  chain="CYFR_GUARD_U$uid"
  if [ "$family" = 4 ]; then tool=iptables reject=icmp-admin-prohibited bits=32
  else tool=ip6tables reject=icmp6-adm-prohibited bits=128; fi
  {
    echo "*filter"
    echo ":$chain - [0:0]"
    for address in "$@"; do echo "-A $chain -d $address/$bits -j RETURN"; done
    echo "-A $chain -j REJECT --reject-with $reject"
    "$tool" -w 5 -C "$HOSTS" -m owner --uid-owner "$uid" -j "$chain" 2>/dev/null \
      || echo "-A $HOSTS -m owner --uid-owner $uid -j $chain"
    echo "COMMIT"
  } | "${tool}-restore" -w 5 --noflush || { log "error: $tool: the rules of uid $uid failed"; return 1; }
}

# Removes one family's chain of uid, and the jump to it, in one transaction.
uid_unchain() {
  family="$1" uid="$2"
  chain="CYFR_GUARD_U$uid"
  if [ "$family" = 4 ]; then tool=iptables; else tool=ip6tables; fi
  "$tool" -w 5 -S "$chain" >/dev/null 2>&1 || return 0
  {
    echo "*filter"
    "$tool" -w 5 -C "$HOSTS" -m owner --uid-owner "$uid" -j "$chain" 2>/dev/null \
      && echo "-D $HOSTS -m owner --uid-owner $uid -j $chain"
    echo "-F $chain"
    echo "-X $chain"
    echo "COMMIT"
  } | "${tool}-restore" -w 5 --noflush || { log "error: $tool: clearing uid $uid failed"; return 1; }
}

admit() {
  uid="$1"
  shift
  spawn_uid "$uid" || exit 1
  v4list="" v6list=""
  for address in "$@"; do
    case "$address" in
      "" | *[!0-9a-f.:]*) log "error: '$address' is not an address"; exit 1 ;;
      *:*) v6list="$v6list $address" ;;
      *[!0-9.]*) log "error: '$address' is not an address"; exit 1 ;;
      *.*.*.*) v4list="$v4list $address" ;;
      *) log "error: '$address' is not an address"; exit 1 ;;
    esac
  done
  exec 9>"$LOCK"
  flock 9
  # shellcheck disable=SC2086 # one argument per address
  if uid_chain 4 "$uid" $v4list && uid_chain 6 "$uid" $v6list; then
    remember "$uid" "$@" || exit 1
    log "uid $uid admitted to$v4list$v6list"
    return 0
  fi
  refuse_all "$uid"
  exit 1
}

# Leaves uid refused every public address, recorded so.
refuse_all() {
  uid_chain 4 "$1" || log "error: uid $1 could not be refused every IPv4 address"
  uid_chain 6 "$1" || log "error: uid $1 could not be refused every IPv6 address"
  remember "$1" || true
}

# Records uid's admission: the addresses it may reach, one a line, none
# for a uid refused every public address.
remember() {
  uid="$1"
  shift
  mkdir -p "$ADMITTED" || { log "error: the admissions' record could not be made"; return 1; }
  printf '%s\n' "$@" | sed '/^$/d' > "$ADMITTED/$uid.tmp" && mv "$ADMITTED/$uid.tmp" "$ADMITTED/$uid" \
    || { log "error: uid $uid's admission could not be recorded"; return 1; }
}

clear_uid() {
  uid="$1"
  spawn_uid "$uid" || exit 1
  exec 9>"$LOCK"
  flock 9
  failed=""
  uid_unchain 4 "$uid" || failed=1
  uid_unchain 6 "$uid" || failed=1
  if [ -n "$failed" ]; then
    refuse_all "$uid"
    exit 1
  fi
  rm -f "$ADMITTED/$uid" || { log "error: uid $uid's record could not be dropped"; exit 1; }
  log "uid $uid cleared"
}

install_rules() {
  rm -f "$READY"
  rm -rf "$ADMITTED"
  add_rules
  mkdir -p "$READY_DIR" "$ADMITTED"
  record || exit 1
  log "ready: every rule installed for spawns $(printf '%s' "$ranges" | tr '\n' ' ' | sed 's/ $//')"
}

case "${1:-}" in
  "")
    install_rules
    if [ -n "${CYFR_GUARD_CONTROL:-}" ]; then
      exec cyfr-locus guard-control "$CYFR_GUARD_CONTROL" "$CYFR_GUARD_POOL"
    fi
    exec sleep infinity
    ;;
  admit)
    [ $# -ge 2 ] || { log "usage: cyfr-guard admit <uid> [address…]"; exit 2; }
    shift
    admit "$@"
    ;;
  clear)
    [ $# -eq 2 ] || { log "usage: cyfr-guard clear <uid>"; exit 2; }
    clear_uid "$2"
    ;;
  check)
    check
    ;;
  rules)
    PRINT_ONLY=1
    add_rules
    ;;
  *)
    log "usage: cyfr-guard [admit <uid> [address…] | clear <uid> | check | rules]"
    exit 2
    ;;
esac

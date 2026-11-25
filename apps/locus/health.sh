#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Locus container's health (Dockerfile.locus HEALTHCHECK): healthy when
# every role whose key this environment holds answers at its port, and
# with no key held, never. A role process listens in a space of its own,
# which its guard forwards the role's port to from the guard's island
# addresses alone (cyfr-guard, reach `role`), so each probe asks the first
# of those addresses, the way cyfr reaches the role:
#
#   runtime   LOCUS_RUNTIME_KEY   the worker listener refuses an unsigned
#                                 status request with 401, which it answers
#                                 only once the worker service holds its
#                                 credentials (Prima.WorkerWire)
#   builds    LOCUS_BUILDS_KEY    the builds wire's health operation, answered
#                                 without a key (Prima.BuilderProtocol)
#   backends  LOCUS_BACKENDS_KEY  the backends wire's health operation,
#                                 answered without a key (Prima.LocusBackends)
#
# Each wire refuses a health body at another version, so a step of a
# wire's version moves its body here (Cyfr.StackShapeTest holds each to its
# wire). It names the first role that does not answer, and exits 1.
set -eu

# The first IPv4 address of this namespace's own on an island subnet: a
# local address, from the kernel's routing tables, inside the on-link
# subnet of an interface other than the loopback and the spaces' pairs.
island_address() {
  awk '
    function hex(s,    i, n) {
      n = 0
      for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789ABCDEF", toupper(substr(s, i, 1))) - 1
      return n
    }
    function le(h) { return ((hex(substr(h, 7, 2)) * 256 + hex(substr(h, 5, 2))) * 256 + hex(substr(h, 3, 2))) * 256 + hex(substr(h, 1, 2)) }
    function num(a,    p) { split(a, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
    FILENAME == "/proc/net/route" {
      if (FNR > 1 && $1 != "lo" && $1 !~ /^sp[0-9]+$/ && $3 == "00000000" && $8 != "00000000") {
        n++; lo[n] = le($2); hi[n] = lo[n] + 4294967296 - le($8) - 1
      }
      next
    }
    /\|-- / { a = $2 }
    /\/32 host LOCAL/ {
      v = num(a)
      for (i = 1; i <= n; i++) if (lo[i] <= v && v <= hi[i]) { print a; exit }
    }
  ' /proc/net/route /proc/net/fib_trie
}

address="$(island_address)"
if [ -z "$address" ]; then
  echo "locus: no island address in this network namespace" >&2
  exit 1
fi

probed=0

if [ -n "${LOCUS_RUNTIME_KEY:-}" ]; then
  probed=1
  status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$address:4200/worker/v1/status" || true)"
  [ "$status" = "401" ] || { echo "locus: the runtime answers $status at $address:4200" >&2; exit 1; }
fi

if [ -n "${LOCUS_BUILDS_KEY:-}" ]; then
  probed=1
  curl -fsS -o /dev/null -X POST -H 'content-type: application/json' -d '{"version":2}' \
    "http://$address:4100/locus/v1/builds/health" \
    || { echo "locus: builds does not answer at $address:4100" >&2; exit 1; }
fi

if [ -n "${LOCUS_BACKENDS_KEY:-}" ]; then
  probed=1
  curl -fsS -o /dev/null -X POST -H 'content-type: application/json' -d '{"version":5}' \
    "http://$address:4101/locus/v1/backends/health" \
    || { echo "locus: backends does not answer at $address:4101" >&2; exit 1; }
fi

if [ "$probed" = 0 ]; then
  echo "locus: no role's key is set (LOCUS_RUNTIME_KEY, LOCUS_BUILDS_KEY, LOCUS_BACKENDS_KEY)" >&2
  exit 1
fi

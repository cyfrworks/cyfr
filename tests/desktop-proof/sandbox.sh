# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# The CYFR app's renderer sandbox on Linux, the one assertion of it, sourced
# by the home-free smoke (tests/desktop-proof/native/smoke.sh) and sent to
# the install-and-screen proof's guest (tests/install-screen-proof/run.sh).
#
# renderers_sandboxed APP RENDERER...: 0 when there is at least one
# renderer, the app's own user namespace (APP, its process id) reads, and
# every RENDERER runs under seccomp mode 2 in a user namespace other than
# the app's; it prints what holds, or why not.
renderers_sandboxed() {
  local app_ns r seccomp ns bad="" n=0
  app_ns=$(readlink "/proc/$1/ns/user") || app_ns=
  shift
  for r in "$@"; do
    n=$((n + 1))
    seccomp=$(awk '$1 == "Seccomp:" { print $2 }' "/proc/$r/status" 2>/dev/null) || seccomp=
    ns=$(readlink "/proc/$r/ns/user" 2>/dev/null) || ns=
    [ "$seccomp" = 2 ] || bad+="renderer $r has seccomp mode '${seccomp:-unreadable}'; "
    [ -n "$ns" ] && [ "$ns" != "$app_ns" ] || bad+="renderer $r is in user namespace '${ns:-unreadable}', the app's is '${app_ns:-unreadable}'; "
  done
  if [ "$n" = 0 ]; then
    echo "no live renderer of the app could be listed"
    return 1
  elif [ -z "$app_ns" ]; then
    echo "the app's own user namespace is unreadable"
    return 1
  elif [ -n "$bad" ]; then
    echo "$bad"
    return 1
  fi
  echo "$n renderer(s), each under seccomp mode 2 in a user namespace other than the app's $app_ns"
}

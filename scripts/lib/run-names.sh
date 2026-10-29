#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The names a run gives what it holds on the host, derived in one place.
# Source it (Bash 3.2 or later); it defines functions and variables only.
#
#   run_names_seed [DIR]
#       Prints ten lowercase hex digits: the start of the SHA-256 of the
#       physical path (`pwd -P`, no trailing newline) of the worktree that
#       holds DIR (default: the working directory), as
#       `git rev-parse --show-toplevel` names it. Every spelling of one
#       worktree, through a symlink or from a subdirectory, gives one seed.
#       Returns 69 when DIR is in no worktree, or when git or a SHA-256
#       tool (sha256sum, or shasum on macOS) is missing.
#   run_names_prefix [DIR]
#       Prints `cyfr-<seed>-<pid>-`, where the seed is DIR's and the pid is
#       the calling shell's `$$`, which a command substitution keeps.
#       Returns what run_names_seed returns.
#   RUN_NAMES_PATTERN
#       The extended regular expression a name made from a prefix matches,
#       capturing the seed and the pid. It is the one definition a cleanup
#       matches: the gate's own names (cyfr-gate-<pid>-...) do not match it.
#   run_names_free_port
#       Prints a port between RUN_NAMES_PORT_FIRST and RUN_NAMES_PORT_LAST
#       (20000 and 29999, set when this file is sourced; a test narrows
#       them after) that a bind on 127.0.0.1 finds free, so nothing listens
#       on it there or on the wildcard address. It tries consecutive ports
#       from a random one, wrapping within the range, at most 50 of them.
#       The range lies
#       below the kernel's ephemeral ports (32768 and up on Linux), so a
#       listener on port 0 never lands on a port it picked; a port picked
#       here can still be taken before the caller binds it, which the
#       caller's own bind then reports. Returns 1, naming the range, when
#       every port it tried is held; 69 when python3 is missing.

RUN_NAMES_PATTERN='^cyfr-([0-9a-f]{10})-([0-9]+)-'
RUN_NAMES_PORT_FIRST=20000
RUN_NAMES_PORT_LAST=29999

# The SHA-256 of $1's bytes, as 64 lowercase hex digits.
_run_names_sha256() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | sha256sum) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$1" | shasum -a 256) || return 1
  else
    return 1
  fi
  out=${out%% *}
  case $out in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#out}" = 64 ] || return 1
  printf '%s\n' "$out"
}

run_names_seed() {
  local dir=${1:-.} top physical digest
  if ! command -v git >/dev/null 2>&1; then
    echo 'run_names_seed: git is required' >&2
    return 69
  fi
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || top=
  if [ -z "$top" ] || ! physical=$(cd "$top" 2>/dev/null && pwd -P); then
    echo "run_names_seed: $dir is not inside a git worktree" >&2
    return 69
  fi
  if ! digest=$(_run_names_sha256 "$physical"); then
    echo 'run_names_seed: sha256sum or shasum is required' >&2
    return 69
  fi
  printf '%s\n' "${digest:0:10}"
}

run_names_prefix() {
  local seed
  seed=$(run_names_seed "${1:-.}") || return
  printf 'cyfr-%s-%s-\n' "$seed" "$$"
}

run_names_free_port() {
  local status=0 tries=$((RUN_NAMES_PORT_LAST - RUN_NAMES_PORT_FIRST + 1))
  [ "$tries" -le 50 ] || tries=50
  if ! command -v python3 >/dev/null 2>&1; then
    echo 'run_names_free_port: python3 is required' >&2
    return 69
  fi
  # Exit 3 means every port tried was held; any other failure is the
  # check's own.
  python3 -I -c '
import random, socket, sys
first, last, tries = (int(a) for a in sys.argv[1:4])
size = last - first + 1
start = random.randrange(size)
for i in range(tries):
    port = first + (start + i) % size
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.bind(("127.0.0.1", port))
    except OSError:
        continue
    finally:
        probe.close()
    print(port)
    sys.exit(0)
sys.exit(3)
' "$RUN_NAMES_PORT_FIRST" "$RUN_NAMES_PORT_LAST" "$tries" || status=$?
  case $status in
    0) return 0 ;;
    3) echo "run_names_free_port: no free port in $RUN_NAMES_PORT_FIRST-$RUN_NAMES_PORT_LAST after $tries tries" >&2 ;;
    *) echo "run_names_free_port: the port check failed ($status)" >&2 ;;
  esac
  return 1
}

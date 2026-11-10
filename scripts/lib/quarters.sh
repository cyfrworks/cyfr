# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The host's four quarters, sourced by scripts/heavy-check.sh, which places
# each check on them, and by tests/load-check/run.sh, which measures checks
# on them, so both cut the same ones.
#
# quarters_cut ROOT reads ROOT, a sysfs processor directory such as
# /sys/devices/system/cpu: the online processors group into whole cores,
# one per thread_siblings_list whose processors are all online, ordered by
# their lowest processor; the first 4k of them, k the whole cores divided
# by four, make four quarters of k cores in that order. It sets QUARTER[1]
# to QUARTER[4] to their processors, QUARTERS_CORES to each whole core's,
# QUARTERS_PER to k, QUARTERS_LEFT to the processors of the cores past the
# 4k (empty when the cores divide by four) and QUARTERS_ALL to every online
# processor, and returns 0. When ROOT cannot be read or gives fewer than
# four whole cores it sets QUARTERS_WHY to the reason and returns 1.
#
# A list of processors here is comma-separated and sorted, the form
# `taskset -c` and docker's --cpuset-cpus take.

# The processors a list such as 0-3,8 names, sorted and once each, one
# space apart; 1 for a list that is not one.
quarters_cpus_of() {
  local part a b out=() IFS=,
  for part in $1; do
    case $part in
      ''|*[!0-9-]*|-*|*-|*-*-*) return 1 ;;
      *-*)
        a=$((10#${part%-*})) b=$((10#${part#*-}))
        [ "$a" -le "$b" ] || return 1
        while [ "$a" -le "$b" ]; do out+=("$a"); a=$((a + 1)); done ;;
      *) out+=("$((10#$part))") ;;
    esac
  done
  [ "${#out[@]}" -gt 0 ] || return 1
  printf '%s\n' "${out[@]}" | sort -nu | paste -sd' ' -
}
# The list of the processors in lists $@, sorted.
quarters_list() { printf '%s\n' "$@" | tr ', ' '\n\n' | sed '/^$/d' | sort -nu | paste -sd, -; }
# How many processors list $1 holds.
quarters_count() { local IFS=,; set -- $1; echo "$#"; }

quarters_cut() {
  local root=$1 online= cpu sib key seen=' ' whole c q
  QUARTER=() QUARTERS_CORES=() QUARTERS_PER=0 QUARTERS_LEFT= QUARTERS_ALL= QUARTERS_WHY=
  if ! read -r online 2>/dev/null <"$root/online" || ! online=$(quarters_cpus_of "$online"); then
    QUARTERS_WHY="cannot read the online processors in $root/online"
    return 1
  fi
  for cpu in $online; do
    sib=
    if ! read -r sib 2>/dev/null <"$root/cpu$cpu/topology/thread_siblings_list" || ! sib=$(quarters_cpus_of "$sib"); then
      QUARTERS_WHY="cannot read processor $cpu's thread siblings in $root/cpu$cpu/topology"
      return 1
    fi
    key=${sib// /,}
    case $seen in *" $key "*) continue ;; esac
    seen="$seen$key "
    whole=true
    for c in $sib; do case " $online " in *" $c "*) ;; *) whole=false ;; esac; done
    if $whole; then QUARTERS_CORES+=("$key"); fi
  done
  QUARTERS_PER=$(( ${#QUARTERS_CORES[@]} / 4 ))
  if [ "$QUARTERS_PER" -lt 1 ]; then
    QUARTERS_WHY="this host has ${#QUARTERS_CORES[@]} whole cores, and four quarters need four"
    return 1
  fi
  for q in 1 2 3 4; do
    QUARTER[$q]=$(quarters_list "${QUARTERS_CORES[@]:$(( (q - 1) * QUARTERS_PER )):$QUARTERS_PER}")
  done
  QUARTERS_LEFT=$(quarters_list "${QUARTERS_CORES[@]:$(( 4 * QUARTERS_PER ))}")
  QUARTERS_ALL=$(quarters_list ${online// /,})
}

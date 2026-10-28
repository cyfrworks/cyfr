#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Removes what runs left on this host and what no checkout uses any more:
#   scripts/janitor.sh [--dry-run] [--keep-build-cache]
#
# Its rules, in the order it applies them. This header is their one
# statement.
#   1. What a killed run left. Docker containers, networks, volumes and
#      image tags whose names match RUN_NAMES_PATTERN
#      (scripts/lib/run-names.sh) go once the run their pid names is
#      finished. Each of these keeps the run on its own: a live process
#      holds the pid, even another program and whatever a record says; the
#      heavy-check holder record naming the pid shows a live process in
#      its group (group=), or a live watchdog (watchdog=), or no group, as
#      heavy-check wrote before it recorded one. Containers go with
#      `docker rm -f -v`, then networks, volumes and tags.
#   2. Old images. An image tagged cyfr-locus:in-<h> or cyfr:in-<h> whose
#      works.cyfr.image-inputs label is <h> (scripts/image.sh) goes,
#      holding the image's lock, only when no worktree of this repository
#      produces its tag today, dated or undated (each worktree's own
#      scripts/image.sh --tag-only; a worktree whose call fails, or that
#      has no such script, produces nothing and keeps nothing), no live
#      pid in <h>.uses names it, no container in any state uses it, and
#      it was created more than 24 hours ago. `docker image rm` runs
#      without force, still under the lock. Then dangling images carrying
#      the label are pruned.
#   3. Old build cache. `docker builder prune -f --filter until=168h`
#      removes BuildKit cache unused for seven days, for every project on
#      this Docker daemon, since the cache cannot be attributed to one.
#      --keep-build-cache strikes this rule.
#   4. Old run directories. A $JANITOR_TMP/cyfr-t.* run directory of the
#      partition runner that is this user's, more than three days old, and
#      whose runner-pid names no live process: the PostgreSQL database
#      each partition's receipt names is dropped (the runner's own receipt
#      check, valid_receipt in scripts/test-partitioned.sh: database-created
#      equals database-name and no database-create-pending is left), then
#      the directory goes. Every receipt of a directory is read before its
#      first drop: one it cannot read keeps the directory and every
#      database it names. A drop that fails keeps the directory, names what
#      was dropped and what is left, and fails the run.
#   5. Old logs. $JANITOR_TMP/cyfr-stage.* and $JANITOR_TMP/cyfr-gate.* log
#      directories of this user more than seven days old.
#   6. Old records. Under each image's lock, the dead pids in <h>.uses go.
#      No lock file is ever removed.
#
# It prints `removed <kind> <name>`, or `would remove <kind> <name>` with
# --dry-run, which removes nothing, and `kept <kind> <name>: <reason>` for
# every candidate it keeps, and `worktree <path>: no tag (<exit>)` for a
# worktree whose tag it could not read. It never names or touches anything
# else: not the gate's own cyfr-gate-<pid>-... names, which the gate
# sweeps at its next start, not a tag scripts/image.sh did not make, not
# another project's objects. The per-image lock and the run-finished test,
# not a queue lane, protect an image between its choice and its
# container's start and a run until its end, so it runs in any lane.
#
# HEAVY_CHECK_LOCK (default /tmp/cyfr-heavy-check.lock) names heavy-check's
# lock, beside which the holder records lie; JANITOR_TMP (default /tmp)
# the directory the runner, the stages and the gate make theirs in; the
# image lock directory is the one `scripts/image.sh --lock-dir` prints.
#
# It runs on Linux: it reads Docker's image dates with GNU `date -d`.
#
# Exits 0; 1 naming each removal that failed; 64 on usage; 69 without
# docker, a Docker daemon, git, flock or pgrep.
set -uo pipefail

usage() { echo "usage: $0 [--dry-run] [--keep-build-cache]"; }
dry=false keep_cache=false
while [ "$#" -gt 0 ]; do
  case $1 in
    --dry-run) dry=true ;;
    --keep-build-cache) keep_cache=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/run-names.sh
. "$root/scripts/lib/run-names.sh" || exit 69
for tool in docker git flock pgrep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "janitor: $tool is required" >&2; exit 69; }
done
docker version -f '{{.Server.Os}}' >/dev/null 2>&1 || { echo 'janitor: no Docker daemon answers (docker version)' >&2; exit 69; }

LOCK=${HEAVY_CHECK_LOCK:-/tmp/cyfr-heavy-check.lock}
TMP_ROOT=${JANITOR_TMP:-/tmp}
STATE=$("$root/scripts/image.sh" --lock-dir) || exit 69
failed=0

removed() { if $dry; then echo "would remove $1 $2"; else echo "removed $1 $2"; fi; }
kept() { echo "kept $1 $2: $3"; }
failure() { echo "failed $1 $2: $3"; failed=1; }

# Whether pid $1 is a process that has not exited; a zombie has.
alive() {
  local stat
  [ -n "$1" ] || return 1
  stat=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  case $stat in ''|*Z*) return 1 ;; esac
}

# The holder record that names pid $1, as its group= and watchdog= values
# ("-" for one it lacks); nothing when no record names the pid.
record_of() {
  local file line
  for file in "$LOCK".holder "$LOCK".*.holder; do
    [ -s "$file" ] || continue
    IFS= read -r line <"$file" || [ -n "$line" ] || continue
    line=" ${line%% command=*} "
    case $line in *" pid=$1 "*) ;; *) continue ;; esac
    awk '{ g = "-"; w = "-"
           for (i = 1; i <= NF; i++) {
             if ($i ~ /^group=/) g = substr($i, 7)
             if ($i ~ /^watchdog=/) w = substr($i, 10)
           }
           print g, w }' <<<"$line"
    return 0
  done
  return 1
}

# Why the run pid $1 names is not finished, or nothing when it is.
# Each keeps the run on its own: a live pid, then what its holder record
# says, so a stale record never speaks for a pid that still lives.
unfinished() {
  local fields group watchdog
  if alive "$1"; then echo "its pid $1 is alive"; return; fi
  fields=$(record_of "$1") || return 0
  read -r group watchdog <<<"$fields"
  case $group in ''|*[!0-9]*) echo 'its holder record names no group'; return ;; esac
  if pgrep -g "$group" >/dev/null 2>&1; then echo "a process of its group $group is alive"; return; fi
  case $watchdog in ''|*[!0-9]*) echo 'its holder record names no watchdog'; return ;; esac
  if alive "$watchdog"; then echo "its watchdog $watchdog is alive"; fi
}

# Rule 1.
declare -A why_kept=()
sweep_run_objects() {
  local kind=$1 list=$2 remove=$3 name pid reason
  while IFS= read -r name; do
    [[ $name =~ $RUN_NAMES_PATTERN ]] || continue
    pid=${BASH_REMATCH[2]}
    if [ -z "${why_kept[$pid]+set}" ]; then why_kept[$pid]=$(unfinished "$pid"); fi
    reason=${why_kept[$pid]}
    if [ -n "$reason" ]; then kept "$kind" "$name" "$reason"; continue; fi
    if $dry; then removed "$kind" "$name"; continue; fi
    # shellcheck disable=SC2086
    if out=$(docker $remove "$name" 2>&1); then removed "$kind" "$name"; else failure "$kind" "$name" "$out"; fi
  done < <(docker $list 2>/dev/null)
}
sweep_run_objects container "ps -a --format {{.Names}}" "rm -f -v"
sweep_run_objects network "network ls --format {{.Name}}" "network rm"
sweep_run_objects volume "volume ls --format {{.Name}}" "volume rm"
sweep_run_objects image "image ls --format {{.Repository}}:{{.Tag}}" "image rm"

# Rule 2. The tags the repository's worktrees produce today.
declare -A produced=()
while IFS= read -r worktree; do
  status=0
  for undated in '' --undated; do
    for kind in locus app; do
      if [ -x "$worktree/scripts/image.sh" ]; then
        # shellcheck disable=SC2086
        tag=$("$worktree/scripts/image.sh" --tag-only $undated "$kind" 2>/dev/null) || status=$?
      else
        status=127
      fi
      [ "$status" = 0 ] || break 2
      produced[$tag]=1
    done
  done
  [ "$status" = 0 ] || echo "worktree $worktree: no tag ($status)"
done < <(git -C "$root" worktree list --porcelain | sed -n 's/^worktree //p')

# Holds image <h>'s lock on descriptor 8, waiting up to two hours. A dry
# run makes no lock file: it holds one only where one exists.
take_lock() {
  if $dry && [ ! -e "$STATE/$1.lock" ]; then return 0; fi
  mkdir -p -m 700 "$STATE" && exec 8>>"$STATE/$1.lock" || return 1
  flock -w 7200 8 || { exec 8>&-; return 1; }
}
release_lock() { exec 8>&- 2>/dev/null || :; }

# The live pids among <h>.uses, each once, under the image's lock.
live_uses() {
  local pid
  [ -f "$STATE/$1.uses" ] || return 0
  while IFS= read -r pid; do
    case $pid in ''|*[!0-9]*) continue ;; esac
    if alive "$pid"; then echo "$pid"; fi
  done <"$STATE/$1.uses" | sort -u
}

now=$(date +%s)
while IFS= read -r tag; do
  [[ $tag =~ ^(cyfr-locus|cyfr):in-([0-9a-f]{20})$ ]] || continue
  h=${BASH_REMATCH[2]}
  label=$(docker image inspect -f '{{index .Config.Labels "works.cyfr.image-inputs"}}' "$tag" 2>/dev/null) || continue
  [ "$label" = "$h" ] || continue
  if [ -n "${produced[$tag]+set}" ]; then kept image "$tag" 'a worktree produces it'; continue; fi
  if ! take_lock "$h"; then kept image "$tag" 'its lock stayed held for two hours'; continue; fi
  uses=$(live_uses "$h" | tr '\n' ' ')
  created=$(docker image inspect -f '{{.Created}}' "$tag" 2>/dev/null) || created=
  created=$(date -d "$created" +%s 2>/dev/null) || created=
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    :
  elif [ -n "$uses" ]; then
    kept image "$tag" "a live use names it (pid ${uses% })"
  elif [ -n "$(docker ps -a --filter "ancestor=$tag" --format '{{.ID}}' 2>/dev/null)" ]; then
    kept image "$tag" 'a container uses it'
  elif [ -z "$created" ] || [ $((now - created)) -le 86400 ]; then
    kept image "$tag" 'it is younger than 24 hours'
  elif $dry; then
    removed image "$tag"
  elif out=$(docker image rm "$tag" 2>&1); then
    removed image "$tag"
  else
    failure image "$tag" "$out"
  fi
  release_lock
done < <(docker image ls --filter label=works.cyfr.image-inputs --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
if $dry; then
  echo 'would prune dangling images labelled works.cyfr.image-inputs'
elif out=$(docker image prune -f --filter label=works.cyfr.image-inputs 2>&1); then
  echo 'pruned dangling images labelled works.cyfr.image-inputs'
else
  failure images dangling "$out"
fi

# Rule 3.
if $keep_cache; then
  kept build-cache 'unused for 168h' '--keep-build-cache strikes the rule'
elif $dry; then
  removed build-cache 'unused for 168h'
elif out=$(docker builder prune -f --filter until=168h 2>&1); then
  removed build-cache 'unused for 168h'
else
  failure build-cache 'unused for 168h' "$out"
fi

# Rule 4. A partition's receipt, read as the runner reads it, and the
# server its env file names; prints `<server URL> <database>` when both
# hold, nothing otherwise.
receipt_of() {
  local part=$1 env=$2 name url
  [ ! -e "$part/database-create-pending" ] || return 1
  [ -s "$part/database-created" ] && cmp -s "$part/database-created" "$part/database-name" || return 1
  name=$(cat "$part/database-created")
  [[ $name =~ ^[a-zA-Z0-9_]+_[a-f0-9]{32}_p[0-9]+$ ]] || return 1
  [ -f "$env" ] || return 1
  url=$(env -i bash -c '. "$1" >/dev/null 2>&1 && printf %s "${CYFR_DATABASE_URL:-}"' receipt "$env") || return 1
  [ "${url##*/}" = "$name" ] || return 1
  printf '%s %s\n' "${url%/*}" "$name"
}
drop_database() {
  # shellcheck disable=SC2086
  docker run --rm ${PROOF_RUN_PREFIX:+--name "${PROOF_RUN_PREFIX}janitor-psql-$3"} --network host postgres:18.6 \
    psql -v ON_ERROR_STOP=1 -q "$1/postgres" -c "DROP DATABASE IF EXISTS \"$2\" WITH (FORCE)"
}
while IFS= read -r -d '' dir; do
  [ -O "$dir" ] || continue
  pid=$(cat "$dir/runner-pid" 2>/dev/null) || pid=
  if alive "$pid"; then kept directory "$dir" "its runner $pid is alive"; continue; fi
  # Every partition's receipt is read before the first drop: one that
  # cannot be read keeps the directory and every database it names.
  unreadable= drops=()
  for part in "$dir"/p*/; do
    part=${part%/}
    n=${part##*/p}
    case $n in ''|*[!0-9]*) continue ;; esac
    if [ ! -e "$part/database-created" ] && [ ! -e "$part/database-create-pending" ]; then continue; fi
    if found=$(receipt_of "$part" "$dir/p$n.env"); then
      drops+=("$n ${found}")
    else
      unreadable="$unreadable $n"
    fi
  done
  if [ -n "$unreadable" ]; then
    for n in $unreadable; do kept directory "$dir" "partition $n's database receipt cannot be read"; done
    continue
  fi
  dropped= left=
  for drop in ${drops[@]+"${drops[@]}"}; do
    read -r n server database <<<"$drop"
    if $dry; then removed database "$database"; continue; fi
    if out=$(drop_database "$server" "$database" "$n" 2>&1) && rm -f "$dir/p$n/database-created"; then
      removed database "$database"
      dropped="$dropped${dropped:+, }$database"
    else
      failure database "$database" "${out:-its receipt could not be removed}"
      left="$left${left:+, }$database"
    fi
  done
  if [ -n "$left" ]; then
    failure directory "$dir" "kept; it dropped ${dropped:-no database} and left $left"
    continue
  fi
  if $dry; then removed directory "$dir"
  elif rm -rf "$dir"; then removed directory "$dir"
  else failure directory "$dir" 'rm -rf failed'
  fi
done < <(find "$TMP_ROOT" -maxdepth 1 -name 'cyfr-t.*' -type d -mmin +4320 -print0 2>/dev/null)

# Rule 5.
while IFS= read -r -d '' dir; do
  [ -O "$dir" ] || continue
  if $dry; then removed directory "$dir"
  elif rm -rf "$dir"; then removed directory "$dir"
  else failure directory "$dir" 'rm -rf failed'
  fi
done < <(find "$TMP_ROOT" -maxdepth 1 \( -name 'cyfr-stage.*' -o -name 'cyfr-gate.*' \) -type d -mmin +10080 -print0 2>/dev/null)

# Rule 6.
for uses in "$STATE"/*.uses; do
  [ -f "$uses" ] || continue
  h=${uses##*/}; h=${h%.uses}
  if ! take_lock "$h"; then kept uses "$h" 'its lock stayed held for two hours'; continue; fi
  live=$(live_uses "$h")
  dead=$(grep -cvxF -f <(printf '%s\n' "$live") "$uses" 2>/dev/null) || dead=0
  if [ "$dead" -gt 0 ]; then
    if $dry; then
      echo "would remove $dead dead uses of $h"
    elif printf '%s' "${live:+$live$'\n'}" >"$uses.new" && mv -f "$uses.new" "$uses"; then
      echo "removed $dead dead uses of $h"
    else
      failure uses "$h" 'could not rewrite its records'
    fi
  fi
  release_lock
done

exit "$failed"

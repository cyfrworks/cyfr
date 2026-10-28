#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# What tests/image-test.sh and tests/janitor-test.sh share: a stand-in
# docker and a toy repository. Source it after setting S, the test's
# scratch directory, and ROOT, the checkout under test.
#
# The stand-in docker keeps its state under $DOCKER_STUB and appends every
# call to $DOCKER_STUB/calls, one line each:
#   images/<tag, with / and : as %>   tag=, label= and created= lines
#   containers/<name>                 image=<tag> of the image it uses
#   networks/<name>, volumes/<name>   empty files
#   context.<n>.tar                   the context each build was given
# and reads these switches:
#   daemon-down                       `docker version` fails, as with no daemon
#   build-fail                        holds the status a build exits with
#   build-sleep                       holds the seconds a build takes
#   rm-fail                           `docker image rm` fails
#   run-fail                          `docker run` fails, every run when it is
#                                     empty, else each run whose arguments
#                                     hold its content
# STUB_PLATFORM (default linux/amd64) is the daemon's os/arch.

stub_docker() {
  export DOCKER_STUB="$S/docker"
  mkdir -p "$DOCKER_STUB/images" "$DOCKER_STUB/containers" "$DOCKER_STUB/networks" "$DOCKER_STUB/volumes" "$S/bin"
  : >"$DOCKER_STUB/calls"
  cat >"$S/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -u
D=${DOCKER_STUB:?}
printf '%s\n' "$*" >>"$D/calls"
key() { printf '%s' "$1" | tr '/:' '%%'; }
field() { sed -n "s/^$2=//p" "$1"; }
platform=${STUB_PLATFORM:-linux/amd64}
case ${1:-} in
  version)
    [ ! -e "$D/daemon-down" ] || { echo 'Cannot connect to the Docker daemon' >&2; exit 1; }
    case "$*" in *Arch*) echo "$platform" ;; *) echo "${platform%%/*}" ;; esac ;;
  build)
    shift
    tag= label=
    while [ "$#" -gt 0 ]; do
      case $1 in
        --tag) tag=$2; shift ;;
        --label) label=${2#works.cyfr.image-inputs=}; shift ;;
        --platform|-f|--build-arg) shift ;;
      esac
      shift
    done
    n=1; while [ -e "$D/context.$n.tar" ]; do n=$((n + 1)); done
    cat >"$D/context.$n.tar"
    [ ! -s "$D/build-sleep" ] || sleep "$(cat "$D/build-sleep")"
    if [ -s "$D/build-fail" ]; then echo 'stub: the build failed' >&2; exit "$(cat "$D/build-fail")"; fi
    printf 'tag=%s\nlabel=%s\ncreated=%s\n' "$tag" "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$D/images/$(key "$tag")"
    echo "stub: built $tag" ;;
  image)
    case ${2:-} in
      inspect)
        shift 2
        format=
        if [ "${1:-}" = -f ]; then format=$2; shift 2; fi
        f="$D/images/$(key "$1")"
        [ -f "$f" ] || { echo "Error: No such image: $1" >&2; exit 1; }
        case $format in
          *Labels*) field "$f" label ;;
          *Created*) field "$f" created ;;
          *) echo '[]' ;;
        esac ;;
      ls)
        labelled=false
        case "$*" in *label=works.cyfr.image-inputs*) labelled=true ;; esac
        for f in "$D"/images/*; do
          [ -f "$f" ] || continue
          if $labelled && [ -z "$(field "$f" label)" ]; then continue; fi
          field "$f" tag
        done ;;
      rm)
        tag=$3 f="$D/images/$(key "$3")"
        [ ! -e "$D/rm-fail" ] || { echo "Error response from daemon: stub refuses $tag" >&2; exit 1; }
        [ -f "$f" ] || { echo "Error: No such image: $tag" >&2; exit 1; }
        if grep -lxF "image=$tag" "$D"/containers/* >/dev/null 2>&1; then
          echo "Error response from daemon: conflict: unable to remove $tag: image is being used" >&2
          exit 1
        fi
        rm -f "$f"; echo "Untagged: $tag" ;;
      prune) echo 'Total reclaimed space: 0B' ;;
      *) echo "stub docker: unknown $*" >&2; exit 2 ;;
    esac ;;
  ps)
    ancestor=
    all="$*"
    case $all in *ancestor=*) ancestor=${all##*ancestor=}; ancestor=${ancestor%% *} ;; esac
    for f in "$D"/containers/*; do
      [ -f "$f" ] || continue
      if [ -n "$ancestor" ] && [ "$(field "$f" image)" != "$ancestor" ]; then continue; fi
      basename "$f"
    done ;;
  rm)
    name=${*: -1}
    [ -f "$D/containers/$name" ] || { echo "Error: No such container: $name" >&2; exit 1; }
    rm -f "$D/containers/$name"; echo "$name" ;;
  network|volume)
    dir="$D/${1}s"
    case ${2:-} in
      ls) for f in "$dir"/*; do [ -f "$f" ] && basename "$f"; done; exit 0 ;;
      rm) [ -f "$dir/$3" ] || { echo "Error: No such $1: $3" >&2; exit 1; }; rm -f "$dir/$3"; echo "$3" ;;
      *) echo "stub docker: unknown $*" >&2; exit 2 ;;
    esac ;;
  builder) echo 'Total: 0B' ;;
  run)
    if [ -e "$D/run-fail" ]; then
      all="$*" pattern=$(cat "$D/run-fail")
      case $all in *"$pattern"*) echo 'stub: the run failed' >&2; exit 1 ;; esac
    fi ;;
  *) echo "stub docker: unknown $*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$S/bin/docker"
  export PATH="$S/bin:$PATH"
}

# The file under $DOCKER_STUB/images for a tag.
image_file() { printf '%s/images/%s' "$DOCKER_STUB" "$(printf '%s' "$1" | tr '/:' '%%')"; }

# A file with the given content, its directories made.
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }

# A toy repository at $1 shaped like this one where the scripts read it:
# the scripts under test, both Dockerfiles' forms, sources inside and
# outside their COPY lines, and an ignored file pattern. One commit.
toy_repo() {
  local repo=$1
  git init -q -b main "$repo"
  mkdir -p "$repo/scripts/lib"
  cp "$ROOT/scripts/image.sh" "$ROOT/scripts/janitor.sh" "$repo/scripts/"
  cp "$ROOT/scripts/lib/run-names.sh" "$repo/scripts/lib/"
  put "$repo/Dockerfile.locus" '# syntax=docker/dockerfile:1.7-labs
# The toy Locus image.
FROM scratch AS keeper
COPY apps/locus/keeper/go.mod ./
COPY apps/locus/keeper/ ./
FROM scratch
COPY --from=keeper /out /out
COPY --chmod=0755 apps/locus/keeper/guard/cyfr-guard.sh /usr/local/bin/cyfr-guard
COPY config/ config/
COPY mix.exs mix.lock ./'
  put "$repo/Dockerfile" '# syntax=docker/dockerfile:1.7-labs
# (parser directive above must be the first line; needed for COPY --parents)

FROM scratch
COPY --parents apps/*/mix.exs ./
COPY seed/ /app/seed/
COPY --link LICENSE \
     README.md /app/'
  put "$repo/.dockerignore" '**/_build/'
  put "$repo/.gitignore" '*.log'
  put "$repo/apps/locus/keeper/go.mod" 'module keeper'
  put "$repo/apps/locus/keeper/main.go" 'package main'
  put "$repo/apps/locus/keeper/guard/cyfr-guard.sh" '#!/bin/sh'
  chmod 755 "$repo/apps/locus/keeper/guard/cyfr-guard.sh"
  put "$repo/apps/locus/mix.exs" 'locus'
  put "$repo/apps/locus/lib/locus.ex" 'defmodule Locus do end'
  put "$repo/apps/locus/test/fixture/mix.exs" 'fixture'
  put "$repo/apps/prima/mix.exs" 'prima'
  put "$repo/apps/prima/lib/prima.ex" 'defmodule Prima do end'
  put "$repo/config/config.exs" 'import Config'
  put "$repo/mix.exs" 'umbrella'
  put "$repo/mix.lock" '%{}'
  put "$repo/seed/a.txt" 'seed'
  put "$repo/LICENSE" 'license'
  put "$repo/README.md" 'readme'
  put "$repo/notes/readme.txt" 'notes'
  git -C "$repo" add -A
  git -C "$repo" -c user.name=test -c user.email=test@invalid commit -q -m init
}

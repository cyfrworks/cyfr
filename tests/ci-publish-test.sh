#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Regression cases for the tag pipeline's image publication against a local
# registry: release.yml's one build per platform, loaded for the scan and
# pushed by digest; scripts/ci/scanned-is-pushed.sh, which proves the
# scanned image is the pushed one; and scripts/ci/merge-image.sh, which
# merges exactly the digests a run pushed and prints the manifest its
# version tag names, and moves :latest to it only for a release that is
# not a pre-release.
#
# Two runs, A and B, push between each other's steps, and B's merge lands
# inside A's. Each run's manifest must list its own images only, and each
# printed digest must be its own version's manifest. The same interleaving
# through mutable :amd64/:arm64 tags and a read of :latest is the negative
# control: it must show the mix.
#
# The images are FROM scratch, so both platforms build on any host without
# emulation. The registry with its anonymous volume, the builder and the
# loaded images are this run's alone and are removed on exit, INT, TERM
# and HUP, and the last case checks the volume is gone; the builder is
# registered in a buildx configuration under the scratch directory, so the
# host's builders and its default builder are untouched. A KILL leaves
# them behind under names carrying the test's pid.
#
# Needs docker with buildx, jq and curl, and pulls registry:3 and BuildKit's
# image when they are missing. The daemon must use the containerd image
# store, which CI switches to with scripts/ci/containerd-image-store.sh, as
# release.yml does: the classic store cannot load an image carrying its
# attestation, and the test refuses to start on it.
#
# Usage: bash tests/ci-publish-test.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
merge="$root/scripts/ci/merge-image.sh"
same="$root/scripts/ci/scanned-is-pushed.sh"
store="$root/scripts/ci/containerd-image-store.sh"
registry_image=registry:3@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8
tmp=${TMPDIR:-/tmp}
scratch=$(mktemp -d "${tmp%/}/cyfr-ci-publish-test.XXXXXX") || {
  echo "FAIL: cannot create a temporary directory"
  exit 1
}
name="cyfr-ci-publish-test-$$"
export BUILDX_CONFIG="$scratch/buildx"
registry_id=
registry_volumes=
builder=
# The images the builds load, listed here because the builds run in
# command substitutions.
scan_images=()
for run in a b; do
  for arch in amd64 arm64; do scan_images+=("cyfr-ci-publish-scan/$run:$arch-$$"); done
done

# -v: the registry image declares a volume, and a container removed
# without it leaves that anonymous volume behind on every run.
remove_registry() {
  [ -n "$registry_id" ] && docker rm -f -v "$registry_id" > /dev/null 2>&1
  registry_id=
}

cleanup() {
  remove_registry
  [ -n "$builder" ] && docker buildx rm -f "$builder" > /dev/null 2>&1
  docker image rm -f "${scan_images[@]}" > /dev/null 2>&1
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

die() {
  echo "FAIL: $1"
  [ -s "$scratch/err" ] && sed 's/^/  stderr: /' "$scratch/err"
  exit 1
}

for tool in docker jq curl; do
  command -v "$tool" > /dev/null || die "$tool is not on PATH"
done
docker buildx version > /dev/null 2>&1 || die "docker buildx is not available"
"$store" --check > /dev/null 2> "$scratch/err" || die "the Docker daemon is not on the containerd image store"

failures=0
cases=0
pass() { cases=$((cases + 1)); echo "PASS: $1"; }
fail() {
  cases=$((cases + 1))
  echo "FAIL: $1"
  shift
  for line in "$@"; do echo "  $line"; done
  failures=$((failures + 1))
}

# --- the registry and a builder that can push by digest ---

docker image inspect "$registry_image" > /dev/null 2>&1 ||
  docker pull -q "$registry_image" > /dev/null 2> "$scratch/err" || die "cannot pull $registry_image"
# An ephemeral host port: nothing else on the host is displaced. Docker
# trusts plain HTTP on 127.0.0.0/8.
registry_id=$(docker run -d --name "$name" -p 127.0.0.1::5000 "$registry_image" 2> "$scratch/err") ||
  die "cannot start $registry_image"
registry_volumes=$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$registry_id")
port=$(docker port "$registry_id" 5000/tcp | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p' | head -n 1)
[ -n "$port" ] || die "the registry published no port"
reg="127.0.0.1:$port"
for _ in $(seq 1 50); do
  curl -fsS "http://$reg/v2/" > /dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS "http://$reg/v2/" > /dev/null 2>&1 || die "the registry did not answer on $reg"

# The docker driver cannot push by digest; on the CI runner
# setup-buildx-action creates a container builder, as here. Host
# networking lets BuildKit reach the registry on the host's loopback, and
# plain HTTP is allowed for this registry alone.
printf '[registry."%s"]\n  http = true\n' "$reg" > "$scratch/buildkitd.toml"
docker buildx create --name "$name" --driver docker-container --driver-opt network=host \
  --buildkitd-config "$scratch/buildkitd.toml" --bootstrap > /dev/null 2> "$scratch/err" ||
  die "cannot create a docker-container builder"
builder=$name

# --- helpers ---

# context RUN: a FROM scratch build context holding one file naming RUN.
context() {
  local dir="$scratch/ctx-$1"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    printf 'FROM scratch\nCOPY run.txt /run.txt\n' > "$dir/Dockerfile"
    printf '%s\n' "$1" > "$dir/run.txt"
  fi
  echo "$dir"
}

# build RUN ARCH OUTPUT...: builds RUN's image for linux/ARCH with the
# given outputs (an argument starting with -- passes to buildx as is) and
# prints containerimage.digest from the build's
# metadata, which build-push-action reports as its digest output. It runs
# in a command substitution, so the caller checks what it printed.
build() {
  local run=$1 arch=$2 meta="$scratch/meta-$1-$2-$RANDOM.json"
  shift 2
  local outputs=()
  for out in "$@"; do
    case "$out" in
      --*) outputs+=("$out") ;;
      *) outputs+=(--output "$out") ;;
    esac
  done
  docker buildx build --builder "$builder" --platform "linux/$arch" "${outputs[@]}" \
    --metadata-file "$meta" "$(context "$run")" > /dev/null 2> "$scratch/err" || {
    echo "build of run $run for $arch failed:" >&2
    cat "$scratch/err" >&2
    return 1
  }
  jq -r '."containerimage.digest"' "$meta"
}

# release.yml's build: one build, loaded for the scan and pushed by digest,
# with the max-mode provenance its `provenance: mode=max` input asks for.
pipeline_build() {
  build "$1" "$2" --attest=type=provenance,mode=max \
    "type=docker,name=cyfr-ci-publish-scan/$1:$2-$$" \
    "type=image,name=$reg/publish,push-by-digest=true,name-canonical=true,push=true"
}

# The control's build: each platform pushed under a mutable tag.
mutable_tag_build() {
  build "$1" "$2" "type=image,name=$reg/mutable:$2,push=true"
}

is_digest() {
  for v in "$@"; do [[ "$v" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1; done
}

# children REPO DIGEST: the manifests a pushed index lists, each as
# "digest os/arch".
children() {
  docker buildx imagetools inspect --raw "$1@$2" |
    jq -r '.manifests[] | "\(.digest) \(.platform.os)/\(.platform.architecture)"'
}
# listed REF: the manifests REF's index lists, each as "digest os/arch".
listed() {
  docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' |
    jq -r '.manifests[]? | "\(.digest) \(.platform.os)/\(.platform.architecture)"' | sort -u
}
digest_of() {
  docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r '.digest'
}
# tags_of REPO: REPO's tags, space-separated; nothing for a repository
# that holds no tag, which the registry answers with 404 NAME_UNKNOWN or
# an empty list; "unreadable" for any other answer.
tags_of() {
  local answer list
  answer=$(curl -sS "http://$reg/v2/$1/tags/list") || { echo unreadable; return; }
  list=$(jq -r 'if (.tags | type) == "array" then .tags[]
                elif .errors[0].code == "NAME_UNKNOWN" or (.name != null and .tags == null) then empty
                else error("unreadable") end' <<< "$answer" 2> /dev/null) || { echo unreadable; return; }
  [ -n "$list" ] && sort <<< "$list" | tr '\n' ' '
}

run_script() {
  "$@" > "$scratch/out" 2> "$scratch/err"
  code=$?
}

real_docker=$(command -v docker)
# shim DIR PATTERN COMMAND...: a docker that runs the real docker with
# COMMAND once, before the first call whose arguments match the extended
# regex PATTERN, then behaves as the real one.
shim() {
  local dir=$1 pattern=$2
  shift 2
  mkdir -p "$dir"
  {
    echo '#!/usr/bin/env bash'
    printf 'pattern=%q\n' "$pattern"
    printf 'if [[ "$*" =~ $pattern ]] && mkdir %q 2> /dev/null; then\n' "$dir/fired"
    printf '  %q' "$real_docker" "$@"
    printf ' > /dev/null 2>&1 || exit 99\nfi\n'
    printf 'exec %q "$@"\n' "$real_docker"
  } > "$dir/docker"
  chmod +x "$dir/docker"
}
# blank_shim DIR PATTERN: a docker that answers a call matching PATTERN
# with nothing and success, and every other call as the real one.
blank_shim() {
  mkdir -p "$1"
  {
    echo '#!/usr/bin/env bash'
    printf 'pattern=%q\n' "$2"
    printf 'if [[ "$*" =~ $pattern ]]; then mkdir -p %q; exit 0; fi\n' "$1/fired"
    printf 'exec %q "$@"\n' "$real_docker"
  } > "$1/docker"
  chmod +x "$1/docker"
}

# --- A and B build and push ---

a_amd64=$(pipeline_build a amd64)
a_arm64=$(pipeline_build a arm64)
b_amd64=$(pipeline_build b amd64)
b_arm64=$(pipeline_build b arm64)
is_digest "$a_amd64" "$a_arm64" "$b_amd64" "$b_arm64" || die "a pipeline build reported no digest"

label="each reported digest is a pushed index of one image and its attestation"
ok=1
for d in "$a_amd64" "$a_arm64" "$b_amd64" "$b_arm64"; do
  raw=$(docker buildx imagetools inspect --raw "$reg/publish@$d") || { ok=0; continue; }
  jq -e '.mediaType == "application/vnd.oci.image.index.v1+json"
         and ([.manifests[] | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest")] | length) == 1
         and ([.manifests[] | select(.platform.os == "linux")] | length) == 1' <<< "$raw" > /dev/null || ok=0
done
if [ "$ok" = 1 ]; then pass "$label"; else fail "$label"; fi

label="each pushed attestation is max-mode provenance, with the build's config and sources"
ok=1
for d in "$a_amd64" "$a_arm64" "$b_amd64" "$b_arm64"; do
  docker buildx imagetools inspect "$reg/publish@$d" --format '{{json .Provenance}}' |
    jq -e '(if has("SLSA") then .SLSA else to_entries[0].value.SLSA end)
           | (.buildDefinition.internalParameters | has("buildConfig"))
             and (.runDetails.metadata.buildkit_metadata | has("source"))' > /dev/null 2>&1 || ok=0
done
if [ "$ok" = 1 ]; then pass "$label"; else
  fail "$label" "$(docker buildx imagetools inspect "$reg/publish@$a_amd64" --format '{{json .Provenance}}' | head -c 400)"
fi

label="pushing by digest leaves no tag in the registry"
tags=$(tags_of publish)
if [ -z "$tags" ]; then pass "$label"; else fail "$label" "tags: $tags"; fi

# --- the scanned image is the pushed one ---

label="scanned-is-pushed accepts each build's loaded image and its pushed digest"
ok=1
for build in "a amd64 $a_amd64" "a arm64 $a_arm64" "b amd64 $b_amd64" "b arm64 $b_arm64"; do
  read -r run arch digest <<< "$build"
  run_script "$same" "cyfr-ci-publish-scan/$run:$arch-$$" "$reg/publish" "$digest"
  [ "$code" = 0 ] || { ok=0; echo "  $run $arch: exit $code: $(cat "$scratch/err")"; }
done
if [ "$ok" = 1 ]; then pass "$label"; else fail "$label"; fi

label="scanned-is-pushed refuses a pushed image that differs by one file"
run_script "$same" "cyfr-ci-publish-scan/a:amd64-$$" "$reg/publish" "$b_amd64"
if [ "$code" = 1 ] && grep -qF 'is not the scanned image' "$scratch/err"; then pass "$label"; else
  fail "$label" "exit $code" "stderr: $(tr '\n' ' ' < "$scratch/err")"
fi

label="scanned-is-pushed refuses a digest the registry does not hold"
run_script "$same" "cyfr-ci-publish-scan/a:amd64-$$" "$reg/publish" "sha256:$(printf '0%.0s' $(seq 64))"
if [ "$code" = 1 ]; then pass "$label"; else fail "$label" "exit $code"; fi

label="scanned-is-pushed refuses an empty registry answer"
blank_shim "$scratch/shim-blank-registry" '^buildx imagetools inspect .* --format \{\{json \.Image\}\}$'
PATH="$scratch/shim-blank-registry:$PATH" run_script "$same" "cyfr-ci-publish-scan/a:amd64-$$" "$reg/publish" "$a_amd64"
if [ "$code" = 1 ] && [ -d "$scratch/shim-blank-registry/fired" ] && grep -qF 'no single image with layers' "$scratch/err"; then
  pass "$label"
else
  fail "$label" "exit $code" "stderr: $(tr '\n' ' ' < "$scratch/err")"
fi

label="scanned-is-pushed refuses an empty local answer"
blank_shim "$scratch/shim-blank-local" '^image inspect '
PATH="$scratch/shim-blank-local:$PATH" run_script "$same" "cyfr-ci-publish-scan/a:amd64-$$" "$reg/publish" "$a_amd64"
if [ "$code" = 1 ] && [ -d "$scratch/shim-blank-local/fired" ] && grep -qF 'has no layers in the local daemon' "$scratch/err"; then
  pass "$label"
else
  fail "$label" "exit $code" "stderr: $(tr '\n' ' ' < "$scratch/err")"
fi

label="scanned-is-pushed refuses an empty answer from both sides"
blank_shim "$scratch/shim-blank-both" '^(image inspect |buildx imagetools inspect .* --format \{\{json \.Image\}\}$)'
PATH="$scratch/shim-blank-both:$PATH" run_script "$same" "cyfr-ci-publish-scan/a:amd64-$$" "$reg/publish" "$a_amd64"
if [ "$code" = 1 ] && [ -d "$scratch/shim-blank-both/fired" ]; then pass "$label"; else
  fail "$label" "exit $code" "stderr: $(tr '\n' ' ' < "$scratch/err")"
fi

label="scanned-is-pushed refuses an image the daemon does not hold"
run_script "$same" "cyfr-ci-publish-scan/none:amd64-$$" "$reg/publish" "$a_amd64"
if [ "$code" = 1 ]; then pass "$label"; else fail "$label" "exit $code"; fi

# --- A merges, with B's merge landing between A's create and A's read ---

# The docker in front of the real one runs B's whole create once, just
# before A's merge first reads a manifest back.
shim "$scratch/shim-interleave" '^buildx imagetools inspect [^ ]+ --format' \
  buildx imagetools create --tag "$reg/publish:latest" --tag "$reg/publish:1.0.1" \
  "$reg/publish@$b_amd64" "$reg/publish@$b_arm64"
PATH="$scratch/shim-interleave:$PATH" run_script "$merge" "$reg/publish" 1.0.0 "$a_amd64" "$a_arm64"
a_code=$code
a_printed=$(cat "$scratch/out")
a_latest=$(digest_of "$reg/publish:latest")
cp "$scratch/err" "$scratch/err-a"
run_script "$merge" "$reg/publish" 1.0.1 "$b_amd64" "$b_arm64"
b_code=$code
b_printed=$(cat "$scratch/out")

label="both runs publish, B's create landing inside A's merge"
if [ "$a_code" = 0 ] && [ "$b_code" = 0 ] && [ -d "$scratch/shim-interleave/fired" ]; then pass "$label"; else
  fail "$label" "A exit $a_code: $(tr '\n' ' ' < "$scratch/err-a")" "B exit $b_code: $(tr '\n' ' ' < "$scratch/err")"
fi

a_expected=$( (children "$reg/publish" "$a_amd64"; children "$reg/publish" "$a_arm64") | sort -u)
b_expected=$( (children "$reg/publish" "$b_amd64"; children "$reg/publish" "$b_arm64") | sort -u)
a_listed=$(listed "$reg/publish:1.0.0")
b_listed=$(listed "$reg/publish:1.0.1")

label="each run's manifest lists exactly its own images, with their platforms"
if [ "$(wc -l <<< "$a_expected")" = 4 ] && [ "$a_listed" = "$a_expected" ] && [ "$b_listed" = "$b_expected" ] &&
  [ -z "$(comm -12 <(echo "$a_listed") <(echo "$b_listed"))" ]; then
  pass "$label"
else
  fail "$label" "A listed: $(echo $a_listed)" "A pushed: $(echo $a_expected)" \
    "B listed: $(echo $b_listed)" "B pushed: $(echo $b_expected)"
fi

label="the merged index puts each platform's image under that platform"
amd64_image=$(children "$reg/publish" "$a_amd64" | awk '$2 == "linux/amd64" { print $1 }')
arm64_image=$(children "$reg/publish" "$a_arm64" | awk '$2 == "linux/arm64" { print $1 }')
if is_digest "$amd64_image" "$arm64_image" && grep -qx "$amd64_image linux/amd64" <<< "$a_listed" &&
  grep -qx "$arm64_image linux/arm64" <<< "$a_listed"; then
  pass "$label"
else
  fail "$label" "A listed: $(echo $a_listed)"
fi

label="each printed digest is the manifest its version tag names"
a_tag=$(digest_of "$reg/publish:1.0.0")
b_tag=$(digest_of "$reg/publish:1.0.1")
if is_digest "$a_printed" "$b_printed" && [ "$a_printed" = "$a_tag" ] && [ "$b_printed" = "$b_tag" ]; then
  pass "$label"
else
  fail "$label" "A printed '$a_printed', 1.0.0 names $a_tag" "B printed '$b_printed', 1.0.1 names $b_tag"
fi

label="A's merge points latest at the index it verified, by that digest"
if is_digest "$a_printed" && [ "$a_latest" = "$a_printed" ]; then pass "$label"; else
  fail "$label" "A printed '$a_printed', latest named $a_latest after A's merge"
fi

label="neither printed digest is the other run's"
if is_digest "$a_printed" "$b_printed" && [ "$a_printed" != "$b_printed" ]; then pass "$label"; else
  fail "$label" "A printed '$a_printed', B printed '$b_printed'"
fi

label="the merges leave exactly the version tags and latest, which names the last merge"
tags=$(tags_of publish)
if [ "$tags" = "1.0.0 1.0.1 latest " ] && is_digest "$b_printed" &&
  [ "$(digest_of "$reg/publish:latest")" = "$b_printed" ]; then
  pass "$label"
else
  fail "$label" "tags: $tags" "latest: $(digest_of "$reg/publish:latest")"
fi

# --- the negative control: a merge through mutable per-platform tags ---

# Each run pushes its platforms under the mutable tags, creates its
# version's manifest from them and reads :latest for its attestation, in
# this order. A step is "push-RUN", "create-RUN" or "read-RUN"; each run's
# version is 1.0.0 for A and 1.0.1 for B.
control_order="push-a push-b create-a create-b read-a read-b"
declare -A control_digest=() control_attested=()
for step in $control_order; do
  run=${step#*-}
  [ "$run" = a ] && version=1.0.0 || version=1.0.1
  case "$step" in
    push-*)
      for arch in amd64 arm64; do
        control_digest[$run-$arch]=$(mutable_tag_build "$run" "$arch")
        is_digest "${control_digest[$run-$arch]}" || die "a mutable-tag build reported no digest"
      done
      ;;
    create-*)
      docker buildx imagetools create \
        --tag "$reg/mutable:latest" \
        --tag "$reg/mutable:$version" \
        "$reg/mutable:amd64" \
        "$reg/mutable:arm64" > /dev/null 2> "$scratch/err" || die "the control's create for $version failed"
      ;;
    read-*)
      control_attested[$run]=$(docker buildx imagetools inspect "$reg/mutable:latest" --format '{{json .Manifest}}' | jq -r '.digest')
      ;;
  esac
done

own_a=$( (children "$reg/mutable" "${control_digest[a-amd64]}"; children "$reg/mutable" "${control_digest[a-arm64]}") | sort -u)
own_b=$( (children "$reg/mutable" "${control_digest[b-amd64]}"; children "$reg/mutable" "${control_digest[b-arm64]}") | sort -u)
control_a_listed=$(listed "$reg/mutable:1.0.0")

label="negative control: a merge through mutable tags gives run A's manifest run B's images"
if [ -n "$control_a_listed" ] && [ "$control_a_listed" = "$own_b" ] &&
  [ -z "$(comm -12 <(echo "$control_a_listed") <(echo "$own_a"))" ]; then
  pass "$label"
else
  fail "$label" "the control showed no mix: A's 1.0.0 lists $(echo $control_a_listed)"
fi

label="negative control: a read of :latest attests B's manifest for A"
if is_digest "${control_attested[a]}" && [ "${control_attested[a]}" = "${control_attested[b]}" ] &&
  [ "${control_attested[a]}" = "$(digest_of "$reg/mutable:1.0.1")" ]; then
  pass "$label"
else
  fail "$label" "the control showed no mix: A attested '${control_attested[a]}', B attested '${control_attested[b]}'"
fi

# --- the version tag moved between merge-image.sh's create and its read ---

# As a second run of the same version would: the tag names B's images, or
# only one of A's own, when the script reads it back. The script must
# refuse, print nothing and leave :latest where it was.
moved_case() {
  local version=$1 description=$2
  shift 2
  shim "$scratch/shim-moved-$version" "^buildx imagetools inspect $reg/publish:${version//./\\.} --format" \
    buildx imagetools create --tag "$reg/publish:$version" "$@"
  label="a version tag moved to $description is refused, no digest is printed and latest stays"
  latest_before=$(digest_of "$reg/publish:latest")
  PATH="$scratch/shim-moved-$version:$PATH" run_script "$merge" "$reg/publish" "$version" "$a_amd64" "$a_arm64"
  latest_after=$(digest_of "$reg/publish:latest")
  if [ "$code" = 1 ] && [ -d "$scratch/shim-moved-$version/fired" ] && [ ! -s "$scratch/out" ] &&
    grep -qF 'is not the manifest of the digests given' "$scratch/err" &&
    is_digest "$latest_before" && [ "$latest_after" = "$latest_before" ]; then
    pass "$label"
  else
    fail "$label" "exit $code" "stdout: $(cat "$scratch/out")" "stderr: $(tr '\n' ' ' < "$scratch/err")" \
      "latest before $latest_before, after $latest_after"
  fi
}
moved_case 1.0.2 "another run's images" "$reg/publish@$b_amd64" "$reg/publish@$b_arm64"
moved_case 1.0.3 "one of the given images alone" "$reg/publish@$a_amd64"
moved_case 1.0.4 "the given images and one more" "$reg/publish@$a_amd64" "$reg/publish@$a_arm64" "$reg/publish@$b_amd64"

# --- a pre-release publishes its version tag alone ---

# From A's images while :latest names B's merge, so a :latest the
# pre-release moved would name another index than before.
label="a pre-release publishes its version tag, prints that manifest's digest and leaves latest where it was"
latest_before=$(digest_of "$reg/publish:latest")
run_script "$merge" "$reg/publish" 1.0.5-rc.1 "$a_amd64" "$a_arm64"
pre_printed=$(cat "$scratch/out")
pre_tag=$(digest_of "$reg/publish:1.0.5-rc.1")
pre_listed=$(listed "$reg/publish:1.0.5-rc.1")
latest_after=$(digest_of "$reg/publish:latest")
if [ "$code" = 0 ] && is_digest "$pre_printed" "$latest_before" && [ "$pre_printed" = "$pre_tag" ] &&
  [ "$pre_listed" = "$a_expected" ] && [ "$pre_printed" != "$latest_before" ] &&
  [ "$latest_after" = "$latest_before" ]; then
  pass "$label"
else
  fail "$label" "exit $code" "printed '$pre_printed', 1.0.5-rc.1 names $pre_tag" \
    "1.0.5-rc.1 lists $(echo $pre_listed)" "latest before $latest_before, after $latest_after" \
    "stderr: $(tr '\n' ' ' < "$scratch/err")"
fi

# --- refusals that publish nothing ---

refused_case() {
  local want=$1 description=$2 version=$3
  shift 3
  label="refused before publishing: $description"
  latest_before=$(digest_of "$reg/publish:latest")
  run_script "$merge" "$reg/publish" "$version" "$@"
  if [ "$code" = "$want" ] && [ ! -s "$scratch/out" ] &&
    ! docker buildx imagetools inspect "$reg/publish:$version" > /dev/null 2>&1 &&
    is_digest "$latest_before" && [ "$(digest_of "$reg/publish:latest")" = "$latest_before" ]; then
    pass "$label"
  else
    fail "$label" "exit $code, want $want" "stdout: $(cat "$scratch/out")"
  fi
}
refused_case 64 "one digest" 2.0.1 "$a_amd64"
refused_case 64 "three digests" 2.0.2 "$a_amd64" "$a_arm64" "$b_amd64"
refused_case 64 "a tag in place of a digest" 2.0.3 "$a_amd64" arm64
refused_case 64 "a short digest" 2.0.4 "$a_amd64" "${a_arm64%?}"
refused_case 1 "two amd64 images" 2.0.5 "$a_amd64" "$b_amd64"
refused_case 1 "one image given twice" 2.0.6 "$a_amd64" "$a_amd64"

label="refused before publishing: the version latest"
latest_before=$(digest_of "$reg/publish:latest")
run_script "$merge" "$reg/publish" latest "$b_amd64" "$b_arm64"
if [ "$code" = 64 ] && is_digest "$latest_before" && [ "$(digest_of "$reg/publish:latest")" = "$latest_before" ]; then pass "$label"; else
  fail "$label" "exit $code"
fi
for bad in "$reg/publish:x" "$reg/publish@$a_amd64"; do
  label="refused before publishing: the image $bad"
  run_script "$merge" "$bad" 2.0.7 "$a_amd64" "$a_arm64"
  if [ "$code" = 64 ] && [ ! -s "$scratch/out" ]; then pass "$label"; else fail "$label" "exit $code"; fi
done

label="the refusals left the registry's tags as they were"
tags=$(tags_of publish)
if [ "$tags" = "1.0.0 1.0.1 1.0.2 1.0.3 1.0.4 1.0.5-rc.1 latest " ]; then pass "$label"; else fail "$label" "tags: $tags"; fi

label="removing the registry removes its anonymous volume"
remove_registry
left=
for volume in $registry_volumes; do
  docker volume inspect "$volume" > /dev/null 2>&1 && left="$left $volume"
done
if [ -n "$registry_volumes" ] && [ -z "$left" ]; then pass "$label"; else
  fail "$label" "the registry mounted: ${registry_volumes:-no volume}" "left:${left:- none}"
fi

echo "$((cases - failures))/$cases passed"
[ "$failures" -eq 0 ]

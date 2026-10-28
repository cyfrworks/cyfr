#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# A local image of this checkout's tree, shared by every worktree at the
# same inputs: scripts/image.sh [--undated] [--tag-only] [--for PID] locus|app
#                  scripts/image.sh --lock-dir
#
# Prints cyfr-locus:in-<h> (Dockerfile.locus) or cyfr:in-<h> (Dockerfile)
# on stdout, where <h> is the first 20 hex digits of a hash of the image's
# inputs, and says `image: built <tag>` or `image: reused <tag>` on stderr.
# CI and the commit gate build under their own tags and never use these.
#
# The inputs are the files the Dockerfile's COPY lines read, as the tree
# this checkout holds now: its index, its modified files and its untracked
# files that are not ignored, recorded in a copy of the index so the real
# one is untouched. Each COPY source resolves to a literal list of the
# tree's files. These forms, the ones this repository's Dockerfiles use,
# are read:
#   - COPY with --chmod=, --chown=, --parents and --link, several sources
#     and one destination; a COPY --from= line reads no context and is
#     skipped;
#   - a source naming a file gives that file, and one naming a directory,
#     with or without a trailing slash, every file under it;
#   - a `*` inside a path segment matches within that segment only
#     (apps/*/mix.exs), and a matched directory gives every file under it.
# Every other form exits 65 naming the Dockerfile's line: ADD, the JSON
# array form, a heredoc, a parser directive other than syntax=, a `$` in
# a source, the glob characters ?, [ and **, a flag not listed above, a
# source that resolves to no file, and one that holds a submodule.
#
# The hash is the SHA-256 of: for each input path in byte order (the
# Dockerfile, .dockerignore when the tree has one, and every resolved
# source) the path and a newline, then its mode, a space, its blob id and
# a newline; then the Docker daemon's platform (os/arch) and a newline;
# then each build argument as NAME=value and a newline, sorted by name.
# The only argument is APT_REFRESH: the UTC date, as CI and the gate pass
# it, or 0 with --undated, as a compose or dev build leaves it.
# .dockerignore's exclusions are not applied to the hash: a spare build is
# the cheaper error than a hash that misses a file the build reads.
#
# The build's context is a tar written from exactly those files' blobs,
# each with its mode, read raw through `git cat-file --batch`: ignored
# files never reach it, no attribute or configuration (export-ignore, a
# filter, an eol rule) changes what one tag holds, and a source the
# reading here missed fails the build at its COPY. It runs `docker build
# --platform <the hashed platform>`, labels the image
# works.cyfr.image-inputs=<h>, and Docker tags only a build that
# succeeded.
#
# Shared state lives in one directory per user, whatever TMPDIR is, which
# --lock-dir prints: ${XDG_RUNTIME_DIR:-/run/user/$UID}/cyfr-image when
# that base directory exists, else /tmp/cyfr-image-$UID. For each <h>:
#   <h>.lock   the image's one lock. This script checks for the tag,
#              builds it when absent and adds its use under flock on it,
#              and only then releases the lock and prints the tag;
#              scripts/janitor.sh makes its checks and removes the image
#              under the same lock. No lock file is ever unlinked.
#   <h>.uses   one consumer pid per line, written and pruned only under
#              <h>.lock. The use is --for PID's, by default the shell whose
#              command substitution called this script: its parent, or,
#              when Bash forked a subshell for the substitution (as it does
#              when the command carries a redirection), the first ancestor
#              whose command line differs from the subshell's, since a
#              forked subshell keeps its shell's. A use is live while its
#              pid is.
# --tag-only prints the tag and does nothing else: no build, no lock, no
# use.
#
# Exits 0; 64 on usage; 65 for a Dockerfile form it does not read; 69
# outside a Git checkout, without a Docker daemon, or without git,
# python3 or flock; the build's own status when the build fails.
set -euo pipefail

usage() {
  echo "usage: $0 [--undated] [--tag-only] [--for PID] locus|app"
  echo "       $0 --lock-dir"
}
die() { echo "image: $2" >&2; exit "$1"; }

lock_dir() {
  local base=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  if [ -d "$base" ]; then
    printf '%s/cyfr-image\n' "$base"
  else
    printf '/tmp/cyfr-image-%s\n' "$(id -u)"
  fi
}

# The shell whose command substitution called this script (the header's
# <h>.uses).
caller_pid() {
  local pid=$PPID parent
  while parent=$(ps -o ppid= -p "$pid" 2>/dev/null) && parent=${parent//[[:space:]]/} &&
    [ -n "$parent" ] && [ "$parent" -gt 1 ] &&
    [ "$(ps -o command= -p "$pid" 2>/dev/null)" = "$(ps -o command= -p "$parent" 2>/dev/null)" ]; do
    pid=$parent
  done
  printf '%s\n' "$pid"
}

dated=true tag_only=false for_pid= kind=
while [ "$#" -gt 0 ]; do
  case $1 in
    --undated) dated=false ;;
    --tag-only) tag_only=true ;;
    --for)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      for_pid=$2; shift ;;
    --lock-dir) [ "$#" = 1 ] || { usage >&2; exit 64; }; lock_dir; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    locus|app) [ -z "$kind" ] || { usage >&2; exit 64; }; kind=$1 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done
[ -n "$kind" ] || { usage >&2; exit 64; }
if [ -n "$for_pid" ]; then
  case $for_pid in 0*|*[!0-9]*) die 64 "--for takes a pid, not $for_pid" ;; esac
elif ! $tag_only; then
  for_pid=$(caller_pid)
fi
case $kind in
  locus) dockerfile=Dockerfile.locus repo=cyfr-locus ;;
  app) dockerfile=Dockerfile repo=cyfr ;;
esac

for tool in git python3 docker; do
  command -v "$tool" >/dev/null 2>&1 || die 69 "$tool is required"
done
$tag_only || command -v flock >/dev/null 2>&1 || die 69 'flock is required (util-linux; on macOS: brew install flock)'

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
root=$(git -C "$here/.." rev-parse --show-toplevel 2>/dev/null) || root=
[ -n "$root" ] || die 69 "$here/.. is not inside a git checkout"

platform=$(docker version -f '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null) || platform=
[[ $platform =~ ^[a-z0-9]+/[a-z0-9_]+$ ]] || die 69 'no Docker daemon answers (docker version)'

if $dated; then apt_refresh=$(date -u +%F); else apt_refresh=0; fi

work=$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-image.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The tree as this checkout holds it now, in a copy of its index.
index=$(git -C "$root" rev-parse --path-format=absolute --git-path index)
if [ -f "$index" ]; then cp "$index" "$work/index"; fi
GIT_INDEX_FILE="$work/index" git -C "$root" add -A
tree=$(GIT_INDEX_FILE="$work/index" git -C "$root" write-tree)

# Reads the Dockerfile from the tree, resolves its sources, writes the
# inputs as `git update-index -z --index-info` lines to $5 and prints the
# hash. Exits 65, naming the line, on a form it does not read.
digest=$(python3 -I - "$root" "$tree" "$dockerfile" "$platform" "$work/inputs" "APT_REFRESH=$apt_refresh" <<'PY'
import fnmatch, hashlib, subprocess, sys

root, tree, dockerfile, platform, inputs_path, *build_args = sys.argv[1:]


def git(*args):
    return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True).stdout


def refuse(line, why):
    print(f"image: {dockerfile}:{line}: {why}", file=sys.stderr)
    sys.exit(65)


def encode(path):
    return path.encode("utf-8", "surrogateescape")


listing = {}
for record in git("ls-tree", "-r", "-z", "--full-tree", tree).split(b"\0"):
    if not record:
        continue
    meta, path = record.split(b"\t", 1)
    mode, _kind, oid = meta.decode().split(" ")
    listing[path.decode("utf-8", "surrogateescape")] = (mode, oid)

if dockerfile not in listing:
    refuse(0, "the tree holds no such file")
text = git("cat-file", "blob", listing[dockerfile][1]).decode("utf-8", "surrogateescape")

# Logical lines: a trailing backslash continues one, and a comment line
# inside a continuation is dropped, as Docker reads them. Parser
# directives come first; only syntax= is read.
logical, buffer, start, in_directives = [], None, 0, True
for number, line in enumerate(text.split("\n"), 1):
    stripped = line.strip()
    if buffer is None:
        if in_directives and stripped.startswith("#"):
            body = stripped[1:].strip()
            if "=" in body and body.split("=", 1)[0].strip().isidentifier():
                if body.split("=", 1)[0].strip().lower() != "syntax":
                    refuse(number, f"the parser directive `{stripped}` is not read here")
                continue
        in_directives = False
        if not stripped or stripped.startswith("#"):
            continue
        buffer, start = "", number
    elif stripped.startswith("#"):
        continue
    if line.rstrip().endswith("\\"):
        buffer += line.rstrip()[:-1] + " "
        continue
    logical.append((start, buffer + line))
    buffer = None
if buffer is not None:
    logical.append((start, buffer))

FLAGS_WITH_VALUE = ("--chmod=", "--chown=")
FLAGS_BARE = ("--parents", "--link")


def resolve(line, source):
    if "$" in source:
        refuse(line, f"`{source}` holds a `$`, which is not read here")
    if "?" in source or "[" in source or "**" in source:
        refuse(line, f"`{source}` holds a glob character other than a `*` within a segment")
    path = source
    while path.startswith("./"):
        path = path[2:]
    path = path.lstrip("/").rstrip("/")
    if path in ("", "."):
        found = list(listing)
    elif "*" in path:
        segments = path.split("/")
        found = [
            name
            for name in listing
            if len(name.split("/")) >= len(segments)
            and all(fnmatch.fnmatchcase(part, pattern) for part, pattern in zip(name.split("/"), segments))
        ]
    elif path in listing:
        found = [path]
    else:
        found = [name for name in listing if name.startswith(path + "/")]
    if not found:
        refuse(line, f"`{source}` resolves to no file of the tree")
    for name in found:
        if listing[name][0] == "160000":
            refuse(line, f"`{source}` holds the submodule `{name}`, which is not read here")
    return found


inputs = {dockerfile}
if ".dockerignore" in listing:
    inputs.add(".dockerignore")
for line, content in logical:
    words = content.split()
    instruction = words[0].upper()
    if instruction == "ADD":
        refuse(line, "ADD is not read here")
    if instruction != "COPY":
        continue
    rest = content.strip()[len(words[0]):].strip()
    if rest.startswith("["):
        refuse(line, "the JSON array form of COPY is not read here")
    if "<<" in rest:
        refuse(line, "a heredoc is not read here")
    tokens = rest.split()
    flags = []
    while tokens and tokens[0].startswith("--"):
        flags.append(tokens.pop(0))
    if any(flag.startswith("--from=") for flag in flags):
        continue
    for flag in flags:
        if not (flag.startswith(FLAGS_WITH_VALUE) or flag in FLAGS_BARE):
            refuse(line, f"the flag `{flag}` is not read here")
    if len(tokens) < 2:
        refuse(line, "a COPY needs a source and a destination")
    for source in tokens[:-1]:
        inputs.update(resolve(line, source))

digest = hashlib.sha256()
with open(inputs_path, "wb") as out:
    for path in sorted(inputs, key=encode):
        mode, oid = listing[path]
        digest.update(encode(path) + b"\n" + f"{mode} {oid}\n".encode())
        out.write(f"{mode} {oid}\t".encode() + encode(path) + b"\0")
digest.update(platform.encode() + b"\n")
for argument in sorted(build_args, key=lambda a: a.split("=", 1)[0]):
    digest.update(argument.encode() + b"\n")
print(digest.hexdigest())
PY
) || exit $?
h=${digest:0:20}
tag="$repo:in-$h"

if $tag_only; then
  printf '%s\n' "$tag"
  exit 0
fi

# Writes the build's context to stdout: a tar of each input's blob, read
# raw (`git cat-file --batch`), with its mode, in the inputs' byte order
# and with every time at the epoch, so one tree always gives the same
# bytes. $2 holds the inputs as `<mode> <blob id>\t<path>\0` records,
# sorted.
context_tar=$(cat <<'PY'
import io, subprocess, sys, tarfile

root, inputs_path = sys.argv[1:3]
records = [r for r in open(inputs_path, "rb").read().split(b"\0") if r]
batch = subprocess.Popen(["git", "-C", root, "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
with tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT) as tar:
    for record in records:
        meta, path = record.split(b"\t", 1)
        mode, oid = meta.decode().split(" ")
        batch.stdin.write(oid.encode() + b"\n")
        batch.stdin.flush()
        header = batch.stdout.readline().split()
        if len(header) != 3 or header[1] != b"blob":
            sys.exit(f"image: {oid} is not a blob")
        content = batch.stdout.read(int(header[2]))
        batch.stdout.read(1)
        info = tarfile.TarInfo(path.decode("utf-8", "surrogateescape"))
        info.mtime = 0
        if mode == "120000":
            info.type = tarfile.SYMTYPE
            info.linkname = content.decode("utf-8", "surrogateescape")
            info.mode = 0o777
            tar.addfile(info)
        else:
            info.size = len(content)
            info.mode = 0o755 if mode == "100755" else 0o644
            tar.addfile(info, io.BytesIO(content))
batch.stdin.close()
sys.exit(batch.wait())
PY
)

state=$(lock_dir)
mkdir -p -m 700 "$state" || die 69 "cannot make $state"
[ -O "$state" ] || die 69 "$state belongs to another user"

exec 9>>"$state/$h.lock"
flock 9
if docker image inspect "$tag" >/dev/null 2>&1; then
  said=reused
else
  set +e
  python3 -I -c "$context_tar" "$root" "$work/inputs" |
    docker build --platform "$platform" -f "$dockerfile" --build-arg "APT_REFRESH=$apt_refresh" \
      --label "works.cyfr.image-inputs=$h" --tag "$tag" - >&2
  statuses=("${PIPESTATUS[@]}")
  set -e
  if [ "${statuses[1]}" != 0 ]; then
    echo "image: the build of $tag failed (${statuses[1]})" >&2
    exit "${statuses[1]}"
  fi
  [ "${statuses[0]}" = 0 ] || die 1 "writing the context from its blobs failed (${statuses[0]})"
  said=built
fi
printf '%s\n' "$for_pid" >>"$state/$h.uses"
exec 9>&-
echo "image: $said $tag" >&2
printf '%s\n' "$tag"

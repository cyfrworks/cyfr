# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The `cyfr` release as the release proofs start it, sourced by
# tests/release-boot/boot.sh and the browser harness's scripts: built as
# `Dockerfile` builds it (MIX_ENV=prod, the adapter chosen at compile time
# by CYFR_DATABASE, `mix release cyfr`), started with the deployment file
# `cyfr init` writes, built from this checkout's apps/codex, and the
# test's own settings beside it, and nothing else of the caller's, and
# stopped by its own `stop`.
#
# The sourcing script sets ADAPTER (sqlite or postgres) and WORK (a scratch
# directory it owns) first. A cell is where one server keeps its state: a
# storage root, a seed tree, a deployment file (`.env`) and, for SQLite, a
# database file. Every function that starts, asks or stops a release names
# the cell it runs; the database of a PostgreSQL cell is the URL its
# deployment file holds, and the listener it answers on is the one its
# deployment file names.
#
# A cell answers on the default listeners under the node name NODE, one at
# a time, reached at its localhost address (CYFR_REACH=local). A cell given
# a hostname of its own (`cell_hostname`) is a public home of that name
# (CYFR_REACH=public), behind a TLS-terminating front that forwards to its
# proxy listener, on listeners and under a node name of its own, so
# several such cells run at once.
#
# Environment: RELEASE_BOOT_PORT and RELEASE_BOOT_HOST_API_PORT choose the
# default listeners (4399 and 4398), RELEASE_BOOT_READY_TIMEOUT the seconds
# a boot has to answer readiness (180), and RELEASE_BOOT_SKIP_BUILD=1
# reuses the release a previous run built from the same tree.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The proofs' one redaction (`redact_log`), named from this checkout.
REDACTION="$ROOT/tests/browser/lib.mjs"
PORT="${RELEASE_BOOT_PORT:-4399}"
HOST_API_PORT="${RELEASE_BOOT_HOST_API_PORT:-4398}"
READY_TIMEOUT="${RELEASE_BOOT_READY_TIMEOUT:-180}"
BUILD_PATH="$ROOT/_build/prod_release_boot_$ADAPTER"
REL="$BUILD_PATH/rel/cyfr"
# Every server running, in the order started: SERVER_PIDS[i] is the
# background `start` of the cell SERVER_CELLS[i].
SERVER_PIDS=()
SERVER_CELLS=()

# A node name of this run's own. The release's default is `cyfr`, which a
# developer's release or the other adapter's leg may still hold on epmd — a
# clash that says nothing about the release.
NODE="cyfr-boot-$ADAPTER-$$"

step() { printf '\n=== %s\n' "$*"; }

fail() {
  echo "::error::$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# The release
# ---------------------------------------------------------------------------

# Building the release runs `mix assets.deploy`, as the image's builder
# stage does, so it leaves digested assets under apps/cyfr/priv/static/ —
# build output of a prod build, not of these proofs.
#
# A built release records the tree it was built from in
# `$BUILD_PATH/release-source` (`release_source`), and a reuse
# (RELEASE_BOOT_SKIP_BUILD=1) is refused unless the tree is still that
# one: a proof never runs a release that is not the source it checks. The
# tree is read before the build and again once it has finished, and the
# release is recorded only when the two readings agree: an edit saved
# mid-build may postdate the compile, so a release built around it names
# no tree and is not kept for reuse. The build's own output (what
# `mix assets.deploy` writes under apps/cyfr/priv/static, and _build) is
# ignored by git, so it changes neither reading.
release_build() {
  local before after
  if [ "${RELEASE_BOOT_SKIP_BUILD:-}" = "1" ] && [ -x "$REL/bin/cyfr" ]; then
    release_source_matches
    step "reusing the $ADAPTER release at $REL"
  else
    step "building the cyfr release for $ADAPTER (MIX_ENV=prod, as Dockerfile builds it)"
    rm -f "$BUILD_PATH/release-source"
    before="$(release_source)" ||
      fail "the checkout's tree could not be read before the $ADAPTER release built"
    (
      cd "$ROOT" || exit 1
      export MIX_ENV=prod MIX_BUILD_PATH="$BUILD_PATH" CYFR_DATABASE="$ADAPTER"
      mix deps.get --only prod &&
        mix compile &&
        mix assets.deploy &&
        mix release cyfr --overwrite
    ) || fail "the $ADAPTER release did not build"
    [ -x "$REL/bin/cyfr" ] || fail "no release at $REL/bin/cyfr"
    after="$(release_source)" ||
      fail "the checkout's tree could not be read after the $ADAPTER release built"
    [ "$before" = "$after" ] ||
      fail "the tree changed while the $ADAPTER release built, so the release is not recorded for reuse; build it again once the tree holds still"
    release_source >"$BUILD_PATH/release-source.part" &&
      mv "$BUILD_PATH/release-source.part" "$BUILD_PATH/release-source" ||
      fail "the release's source could not be recorded"
  fi
}

# The tree the checkout holds, as three lines: `head=` the commit HEAD
# names, `adapter=` the adapter, and `tree=` one SHA-256 over every
# difference from HEAD — `git diff HEAD`, staged and unstaged, deletions
# and renames included — and the path and content of every untracked file
# git does not ignore, so a source file not yet added changes it too. Each
# part is hashed apart and named, so no two trees share a text. A file
# that vanishes between the listing and its read counts as vanished, and a
# symlink as its target, never its target's content.
release_source() {
  local head tree
  head="$(git -C "$ROOT" rev-parse --verify HEAD)" || return 1
  tree="$(
    set -o pipefail
    cd "$ROOT" || exit 1
    diff="$(git diff HEAD --binary --no-ext-diff --no-textconv --no-color | sha256sum)" || exit 1
    untracked="$(mktemp "${TMPDIR:-/tmp}/cyfr-release-source-XXXXXX")" || exit 1
    trap 'rm -f "$untracked"' EXIT
    git ls-files -z --others --exclude-standard >"$untracked" || exit 1
    {
      printf 'diff\0%s\0' "${diff:0:64}"
      while IFS= read -r -d '' path; do
        if [ -L "$path" ]; then
          printf 'link\0%s\0%s\0' "$path" "$(readlink -- "$path")"
        elif [ -f "$path" ] && content="$(sha256sum <"$path" 2>/dev/null)"; then
          printf 'file\0%s\0%s\0' "$path" "${content:0:64}"
        else
          printf 'vanished\0%s\0' "$path"
        fi
      done <"$untracked"
    } | sha256sum | cut -c1-64
  )" || return 1
  [[ "$head" =~ ^[0-9a-f]{40,64}$ && "$tree" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'head=%s\nadapter=%s\ntree=%s\n' "$head" "$ADAPTER" "$tree"
}

# Refuse a reuse whose release was built from another tree, naming each
# part that differs and how to build one from this tree.
release_source_matches() {
  local recorded="$BUILD_PATH/release-source" now part differs=""
  local rebuild="build it again: run without RELEASE_BOOT_SKIP_BUILD=1 (or tests/browser/run.sh, which builds it)"
  [ -f "$recorded" ] ||
    fail "the reused release was built from another tree: $recorded is missing, so the tree it was built from is unknown; $rebuild"
  grep -Eqx 'head=[0-9a-f]{40,64}' "$recorded" && grep -Eqx 'adapter=(sqlite|postgres)' "$recorded" &&
    grep -Eqx 'tree=[0-9a-f]{64}' "$recorded" && [ "$(wc -l <"$recorded")" -eq 3 ] ||
    fail "the reused release was built from another tree: $recorded is malformed; $rebuild"
  now="$(release_source)" || fail "the checkout's tree could not be read, so the reused release cannot be matched to it"
  for part in head adapter tree; do
    if [ "$(sed -n "s/^$part=//p" "$recorded")" != "$(printf '%s\n' "$now" | sed -n "s/^$part=//p")" ]; then
      differs="${differs:+$differs, }$part (built from $(sed -n "s/^$part=//p" "$recorded" | cut -c1-12), now $(printf '%s\n' "$now" | sed -n "s/^$part=//p" | cut -c1-12))"
    fi
  done
  [ -z "$differs" ] ||
    fail "the reused release was built from another tree: $differs differs; $rebuild"
}

# ---------------------------------------------------------------------------
# Cells
# ---------------------------------------------------------------------------

# The `cyfr` command line every cell's deployment file comes from, built
# from this checkout's apps/codex once per run (`cell_cli_build`).
CELL_CLI=""

cell_cli_build() {
  [ -z "$CELL_CLI" ] || return 0
  mkdir -p "$WORK/cli"
  # -mod=readonly: the build reads go.mod and go.sum as they are and never
  # rewrites them.
  (cd "$ROOT/apps/codex" && go build -mod=readonly -o "$WORK/cli/cyfr" .) ||
    fail "the cyfr command line did not build from apps/codex"
  CELL_CLI="$WORK/cli/cyfr"
}

# Run the command line in a directory of its own for cell `$1`, holding the
# cell's deployment file when it has one and the checkout's .env.example
# (a development build downloads no scaffold), as a person runs `cyfr` in
# their project: `$2...` are its arguments. HOME is the cell's own and the
# environment is nothing of the caller's but PATH and how Docker is
# reached, which the reach engine asks for the project's containers. The
# directory's name is the run's own, so the compose project the engine
# derives from it is one no other stack on this host has. The command
# line's output is `$cell/cli.log` (appended); the deployment file it
# leaves becomes the cell's.
cell_cli() {
  local cell="$1" dir log="$1/cli.log" status=0
  shift
  cell_cli_build
  dir="$WORK/cyfr-cell-$(basename "$cell")-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  mkdir -p "$dir" "$cell/home"
  cp "$ROOT/.env.example" "$dir/.env.example"
  [ ! -f "$cell/.env" ] || cp "$cell/.env" "$dir/.env"
  printf '\n$ cyfr %s\n' "$*" >>"$log"
  (
    cd "$dir" || exit 1
    env -i HOME="$cell/home" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" TERM=dumb \
      DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}" \
      ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONTEXT:+DOCKER_CONTEXT="$DOCKER_CONTEXT"} \
      "$CELL_CLI" "$@" </dev/null
  ) >>"$log" 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    echo "----- the command line's output for cell $cell -----" >&2
    redact_log "$dir" <"$log" >&2 || echo "(the output could not be redacted, so it is not printed)" >&2
    fail "cyfr $1 exited $status for cell $cell"
  fi
  [ -f "$dir/.env" ] || fail "cyfr $1 left no deployment file for cell $cell"
  cp "$dir/.env" "$cell/.env"
  rm -rf "$dir"
}

# Set NAME `$2` to `$3` in cell `$1`'s deployment file: its first
# assignment rewritten in place and any later one removed, or the line
# added at the end, every other line kept as it was. The file is written
# over, not replaced, so it keeps its mode.
cell_set() {
  NAME="$2" VALUE="$3" awk '
    BEGIN { name = ENVIRON["NAME"]; line = name "=" ENVIRON["VALUE"] }
    index($0, name "=") == 1 { if (!done) print line; done = 1; next }
    { print }
    END { if (!done) print line }
  ' "$1/.env" >"$1/.env.part" && cat "$1/.env.part" >"$1/.env" && rm -f "$1/.env.part" ||
    fail "cell $1's deployment file could not be written"
}

# Remove NAME `$2`'s assignments from cell `$1`'s deployment file.
cell_unset() {
  NAME="$2" awk 'index($0, ENVIRON["NAME"] "=") != 1' "$1/.env" >"$1/.env.part" &&
    cat "$1/.env.part" >"$1/.env" && rm -f "$1/.env.part" || fail "cell $1's deployment file could not be written"
}

# The value cell `$1`'s deployment file assigns NAME `$2`, its last
# assignment.
cell_value() {
  NAME="$2" awk 'index($0, ENVIRON["NAME"] "=") == 1 { value = substr($0, length(ENVIRON["NAME"]) + 2) } END { print value }' "$1/.env"
}

# A new cell at `$1`: an empty storage root, a copy of the repository's
# seed tree, and the deployment file `cyfr init --no-interactive --no-pull`
# writes: the stack's keys minted for this cell alone, the empty CORS
# allowlist, the client ids .env.example ships, builds on with their URL
# and key, and the reach mode with every setting it implies, `local`, or
# `public` at the domain `$3` when it is given (`--reach public --domain`).
# Beside it the cell's own settings, each init writes none of: the
# database adapter the release was COMPILED for (runtime.exs refuses a
# disagreement), auto-migration on, the listener ports, the host API on
# loopback, the runtime's service id, the operators, and the pinned
# validator. With operators named, the setup link's capability init mints
# is deleted, as its refusal says to. `$2` is the PostgreSQL URL of the
# cell's database, ignored for SQLite.
cell_new() {
  local cell="$1" url="${2:-}" host="${3:-}"
  "$ROOT/scripts/wasm-tools.sh" install "$ROOT/_tools" >/dev/null ||
    fail "the pinned wasm-tools could not be installed"
  mkdir -p "$cell/data" "$cell/home"
  cp -R "$ROOT/seed" "$cell/seed"
  rm -f "$cell/.env"

  if [ -n "$host" ]; then
    cell_cli "$cell" init --no-interactive --no-pull --reach public --domain "$host"
  else
    cell_cli "$cell" init --no-interactive --no-pull --reach local
  fi
  cell_unset "$cell" CYFR_SETUP_TOKEN
  cell_set "$cell" CYFR_PORT "$PORT"
  cell_set "$cell" CYFR_DATABASE "$ADAPTER"
  cell_set "$cell" CYFR_AUTO_MIGRATE true
  cell_set "$cell" CYFR_HOST_API_BIND 127.0.0.1
  cell_set "$cell" CYFR_HOST_API_PORT "$HOST_API_PORT"
  cell_set "$cell" LOCUS_RUNTIME_SERVICE_ID wrk_locus
  cell_set "$cell" CYFR_PLATFORM_ADMIN_EMAILS operator@example.com
  # The pinned validator, which the release checks as it starts; outside
  # its image it is the checkout's own (scripts/wasm-tools.sh).
  cell_set "$cell" CYFR_WASM_TOOLS "$ROOT/_tools/wasm-tools"
  if [ "$ADAPTER" = postgres ]; then cell_set "$cell" CYFR_DATABASE_URL "$url"; fi
}

# Cell `$1` is a public home at the hostname `$2`, as `cyfr init --reach
# public --domain` or `cyfr reach public --domain` makes one: what the
# command line writes for the name is its mode, its host and its public
# URL, and nothing here writes those itself. A cell made by `cell_new` for
# that name already is one; any other cell is switched with `cyfr reach`,
# which keeps every other line of its deployment file, its keys among them.
# The cell then answers on three listener ports of its own from `$3`: its
# loopback listener on `$3`, its host API on the next and its proxy
# listener, where the front that terminates TLS for it forwards
# (tests/browser/lib.mjs), on the one after. Its node name is its own
# (`$cell/node`), so it runs beside the other cells of the run.
cell_hostname() {
  local cell="$1" host="$2" port="$3"
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] ||
    fail "not a lowercase dotted hostname: '$host'"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65533 ] ||
    fail "cell $cell needs a listener port from 1024 to 65533, not '$port'"
  if [ "$(cell_value "$cell" CYFR_REACH)" != public ] || [ "$(cell_value "$cell" CYFR_HOST)" != "$host" ]; then
    cell_cli "$cell" reach public --domain "$host" --yes
  fi
  cell_set "$cell" CYFR_PORT "$port"
  cell_set "$cell" CYFR_HOST_API_PORT "$((port + 1))"
  cell_set "$cell" CYFR_PROXY_PORT "$((port + 2))"
  [ "$(cell_value "$cell" CYFR_REACH)" = public ] && [ "$(cell_value "$cell" CYFR_HOST)" = "$host" ] ||
    fail "cell $cell is not a public home at $host"
  printf 'cyfr-%s-%s-%s\n' "${host//./-}" "$ADAPTER" "$$" >"$cell/node"
}

# The port cell `$1`'s loopback listener answers on: the one its
# deployment file names.
cell_port() {
  sed -n 's/^CYFR_PORT=//p' "$1/.env" | tail -1
}

# The port cell `$1`'s proxy listener answers on, which a public cell has
# (`cell_hostname`): the one its deployment file names.
cell_proxy_port() {
  local port
  port="$(sed -n 's/^CYFR_PROXY_PORT=//p' "$1/.env" | tail -1)"
  [ -n "$port" ] || fail "cell $1 names no proxy listener port: make it a public home first (cell_hostname)"
  printf '%s\n' "$port"
}

# The node name cell `$1`'s server runs under: its own when it has a
# hostname (`cell_hostname`), NODE otherwise.
cell_node() {
  if [ -f "$1/node" ]; then cat "$1/node"; else printf '%s\n' "$NODE"; fi
}

# Each NAME=value cell `$1`'s deployment file assigns, one a line, as a
# dotenv reader takes them: blank and comment lines skipped, a value in
# single quotes taken literally, one in double quotes taken without them,
# and any other value as written. A line it cannot take as the release's
# reader would (a double-quoted value holding an escape or `$`, an
# unquoted one holding ` #`, a quote left open, or no NAME=) fails, naming
# it: the cell would otherwise boot on another value than its file says.
cell_assignments() {
  awk -v file="$1/.env" '
    function refuse(why) { printf "%s:%d: %s\n", file, NR, why > "/dev/stderr"; exit 1 }
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      sub(/^export[[:space:]]+/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) refuse("not a NAME=value line")
      at = index(line, "=")
      name = substr(line, 1, at - 1)
      value = substr(line, at + 1)
      first = substr(value, 1, 1)
      if (first == sprintf("%c", 39) || first == "\"") {
        if (length(value) < 2 || substr(value, length(value), 1) != first) refuse("a quoted value is left open")
        value = substr(value, 2, length(value) - 2)
        if (index(value, first)) refuse("a quoted value holds its own quote")
        if (first == "\"" && value ~ /[\\$]/) refuse("a double-quoted value holds an escape or $")
      } else if (value ~ /[[:space:]]#/) {
        refuse("an unquoted value holds an inline comment")
      }
      print name "=" value
    }
  ' "$1/.env" || fail "cell $1's deployment file holds a line the proofs cannot read as the release does"
}

# Run a command with the cell's environment and nothing else of the
# caller's that could steer the release (a CYFR_* left over from a shell, a
# DATABASE_URL): its deployment file, its paths, its keyring file when it
# keeps one apart (`$cell/keyring.json`, exported as CYFR_CRYPTO_KEYRING),
# and `$@`'s leading NAME=value words after that. From the cell, so a crash
# dump or anything else the release writes beside itself lands there, and
# with crash dumps off, so a boot that raises dies at once instead of
# spending its ready window writing one (`ERL_CRASH_DUMP_SECONDS=0`, as the
# workflows set for every Elixir job).
cell_env() {
  local cell="$1"
  shift

  local -a assignments=()
  cell_assignments "$cell" >"$cell/.env.assignments.$BASHPID"
  mapfile -t assignments <"$cell/.env.assignments.$BASHPID"
  rm -f "$cell/.env.assignments.$BASHPID"
  [ "${#assignments[@]}" -gt 0 ] || fail "cell $cell's deployment file assigns nothing"

  assignments+=(
    "CYFR_DATA_PATH=$cell/data"
    "CYFR_SEED_PATH=$cell/seed"
  )
  if [ "$ADAPTER" = sqlite ] && [ -d "$cell/db" ]; then
    assignments+=("CYFR_DATABASE_PATH=$cell/db/cyfr.db")
  fi
  if [ -f "$cell/keyring.json" ]; then
    assignments+=("CYFR_CRYPTO_KEYRING=$(cat "$cell/keyring.json")")
  fi

  while [ $# -gt 0 ] && [[ "$1" == [A-Z]*=* ]]; do
    assignments+=("$1")
    shift
  done

  local node
  node="$(cell_node "$cell")"
  (
    cd "$cell" || exit 1
    env -i \
      HOME="$cell/home" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" TERM="${TERM:-dumb}" \
      ERL_CRASH_DUMP_SECONDS=0 \
      RELEASE_NODE="$node" \
      "${assignments[@]}" \
      "$@"
  )
}

# The release's own command (`bin/cyfr ...`) in the cell's environment,
# after any leading NAME=value words, which override it.
cell_cyfr() {
  local cell="$1"
  shift
  local -a overrides=()
  while [ $# -gt 0 ] && [[ "$1" == [A-Z]*=* ]]; do
    overrides+=("$1")
    shift
  done
  cell_env "$cell" ${overrides[@]+"${overrides[@]}"} "$REL/bin/cyfr" "$@"
}

# How many migrations the cell's database has not run, as the release
# itself reports them (`Cyfr.Release.pending/0`): the one number that says
# whether a schema is there, whoever put it there.
cell_pending() {
  cell_cyfr "$1" eval \
    'IO.puts("PENDING=" <> Integer.to_string(length(Cyfr.Release.pending())))' \
    | sed -n 's/^PENDING=//p' | tail -1
}

# Values a log of this run must not show beside the ones its cells hold,
# such as a session token a proof was given; a sourcing script appends to
# it.
LOG_SECRETS=()

# Standard input on standard output with nothing cell `$1` or the run
# holds secret, through the proofs' one redaction (REDACTION's `redact`):
# it is given every value of the cell's deployment file whose
# name says key, secret, root, password, token or URL, the password such a
# URL carries, the cell's keyring and each of its keys, and LOG_SECRETS,
# and it masks a bearer credential and the values its rules name. The
# values travel in the environment, never on a command line. A log that
# cannot be redacted is not printed: the function fails instead.
redact_log() {
  local cell="$1"
  REDACT_CELL="$cell" REDACT_LIB="$REDACTION" \
    REDACT_SECRETS="$(printf '%s\n' ${LOG_SECRETS[@]+"${LOG_SECRETS[@]}"})" \
    node --input-type=module -e '
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const { redact } = await import(pathToFileURL(process.env.REDACT_LIB).href);
const read = (name) => { try { return readFileSync(join(process.env.REDACT_CELL, name), "utf8"); } catch { return ""; } };
const secrets = process.env.REDACT_SECRETS.split("\n");
for (const line of read(".env").split("\n")) {
  const at = line.indexOf("=");
  if (at < 0 || !/KEY|SECRET|ROOT|PASSWORD|TOKEN|URL/.test(line.slice(0, at))) continue;
  const value = line.slice(at + 1);
  secrets.push(value);
  try {
    const { password } = new URL(value);
    if (password) secrets.push(password, decodeURIComponent(password));
  } catch {}
}
const keyring = read("keyring.json").trim();
if (keyring) {
  secrets.push(keyring);
  try { secrets.push(...Object.values(JSON.parse(keyring).keys ?? {})); } catch {}
}
// Longest first, so a value that holds another goes whole.
const known = [...new Set(secrets)].filter((s) => typeof s === "string" && s.length >= 4).sort((a, b) => b.length - a.length);
process.stdout.write(redact(readFileSync(0, "utf8"), known));
'
}

# ---------------------------------------------------------------------------
# A server
# ---------------------------------------------------------------------------

# Start the release on the cell in the background and wait for it to answer
# /api/health/ready on the cell's own listener, the readiness check the
# image's HEALTHCHECK runs; the log is `$cell/boot.log` (appended). A boot
# that raises, exits or never answers fails here, naming the cell, with its
# whole log redacted (`redact_log`), and leaves no server behind. The window is READY_TIMEOUT
# seconds of wall clock: each probe is bounded (READY_PROBE_SECONDS), and
# none starts once the window has closed, so a listener that accepts and
# never answers costs the window and one probe at most.
READY_PROBE_SECONDS=5
server_start() {
  local cell="$1" port
  port="$(cell_port "$cell")"
  [ -n "$port" ] || fail "cell $cell names no CYFR_PORT"

  # A server left from another run would answer the readiness check below
  # while this boot failed on its ports, and pass for it.
  if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$port/api/health" 2>/dev/null; then
    fail "something already answers on 127.0.0.1:$port — stop it before this proof"
  fi

  local log="$cell/boot.log"
  local mark
  mark="$( [ -f "$log" ] && wc -l <"$log" || echo 0)"
  cell_cyfr "$cell" start >>"$log" 2>&1 &
  SERVER_PIDS+=("$!")
  SERVER_CELLS+=("$cell")

  local ready="" died="" closes=$((SECONDS + READY_TIMEOUT))
  while [ "$SECONDS" -lt "$closes" ]; do
    if curl -fsS -m "$READY_PROBE_SECONDS" -o "$cell/ready.json" "http://127.0.0.1:$port/api/health/ready" 2>/dev/null; then
      ready=yes
      break
    fi
    # A boot that raised says so in its log and never answers. `kill -0` on
    # the background job cannot tell: a child that has exited stays a zombie
    # until it is waited for, and `start` runs the VM below a wrapper of its
    # own, so a raise would otherwise cost the whole ready window and be
    # reported as a boot that was merely slow.
    if tail -n "+$((mark + 1))" "$log" | grep -q "Kernel pid terminated\|Application cyfr exited\|application_start_failure"; then
      died=yes
      break
    fi
    [ "$SECONDS" -lt "$closes" ] && sleep 1
  done

  if [ "$ready" != yes ]; then
    echo "----- boot log of cell $cell -----" >&2
    tail -n "+$((mark + 1))" "$log" | redact_log "$cell" >&2 ||
      echo "(the boot log could not be redacted, so it is not printed)" >&2
    if [ -n "$died" ]; then
      echo "::error::the $ADAPTER release of cell $cell exited while booting, without answering /api/health/ready on 127.0.0.1:$port" >&2
    else
      echo "::error::the $ADAPTER release of cell $cell did not answer /api/health/ready on 127.0.0.1:$port within ${READY_TIMEOUT}s" >&2
    fi
    # A boot that is still going when the window closes is stopped too, so
    # no VM outlives the run that gave up on it.
    server_stop "$cell"
    exit 1
  fi
}

# Stop the server of cell `$1`, or, with no cell, every server running, the
# last started first. `bin/cyfr start` runs the BEAM as a CHILD of the shell
# it starts, so signalling that shell leaves a listening server behind.
# Stopping is the release's own stop; whatever survives it is signalled by
# the cell's node name. Each listener is gone before the next boot asks its
# port; a server whose listener outlives its stop fails the run, named.
server_stop() {
  local only="${1:-}" i outlived=""
  local -a pids=() cells=()
  for ((i = ${#SERVER_CELLS[@]} - 1; i >= 0; i--)); do
    if [ -n "$only" ] && [ "${SERVER_CELLS[i]}" != "$only" ]; then
      pids=("${SERVER_PIDS[i]}" ${pids[@]+"${pids[@]}"})
      cells=("${SERVER_CELLS[i]}" ${cells[@]+"${cells[@]}"})
    elif ! server_halt "${SERVER_PIDS[i]}" "${SERVER_CELLS[i]}"; then
      outlived="${outlived:+$outlived, }cell ${SERVER_CELLS[i]} on 127.0.0.1:$(cell_port "${SERVER_CELLS[i]}")"
    fi
  done
  SERVER_PIDS=(${pids[@]+"${pids[@]}"})
  SERVER_CELLS=(${cells[@]+"${cells[@]}"})
  [ -z "$outlived" ] || fail "the server of $outlived outlived its stop"
}

# Stop the server `start`ed as the background job `$1` on cell `$2`, and
# answer whether its listener is gone.
server_halt() {
  local pid="$1" cell="$2" node port
  node="$(cell_node "$cell")"
  port="$(cell_port "$cell")"
  cell_cyfr "$cell" stop >/dev/null 2>&1 || true
  # A VM that refused the stop, or was still booting and could not take
  # it, would hold the job forever; it gets its window, then the signal.
  # A job that has exited is a zombie until it is waited for.
  for _ in $(seq 1 30); do
    case "$(ps -o stat= -p "$pid" 2>/dev/null)" in '' | Z*) break ;; esac
    sleep 1
  done
  # The node name ends there: another cell's name may begin with this one.
  pkill -f "sname $node( |\$)" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    curl -fsS -m 1 -o /dev/null "http://127.0.0.1:$port/api/health" 2>/dev/null || return 0
    sleep 1
  done
  return 1
}

# Evaluate the fixture file `$2` inside cell `$1`'s running server, as
# `bin/cyfr rpc`: `$4...` are its arguments, each passed as an Elixir
# string with `\`, `"` and `#` escaped, so no argument is interpolated, and
# the answer is the value of its last line that begins `$3=`. A fixture
# that raises prints no such line and answers nothing; its caller decides
# whether that fails the run.
cell_fixture() {
  local cell="$1" file="$2" prefix="$3"
  shift 3
  local args="" arg
  for arg in "$@"; do
    args="$args\"$(printf '%s' "$arg" | sed 's/[\\"#]/\\&/g')\","
  done
  cell_cyfr "$cell" rpc \
    "{answer, _} = Code.eval_file(\"$file\"); IO.puts(answer.([${args%,}]))" |
    sed -n "s/^$prefix=//p" | tail -1
}

# The release-boot fixture (tests/release-boot/fixture.exs) on cell `$1`:
# `$2...` are its arguments, and its one JSON line is the answer.
server_fixture() {
  local cell="$1"
  shift
  cell_fixture "$cell" "$ROOT/tests/release-boot/fixture.exs" FIXTURE "$@"
}

# The value at the path `$2...` of the JSON document `$1`, each step a key,
# or an index into a list (`-1`, the last): a string or a number as itself,
# anything else (an object, a list, a boolean, null) as JSON. A step that
# is not there fails.
field() {
  printf '%s' "$1" | python3 -c '
import json, sys
value = json.load(sys.stdin)
for step in sys.argv[1:]:
    value = value[int(step)] if isinstance(value, list) else value[step]
plain = isinstance(value, (str, int, float)) and not isinstance(value, bool)
print(value if plain else json.dumps(value))' "${@:2}"
}

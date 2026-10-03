# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Homes that reach identity directories, sourced after
# tests/release-boot/release.sh, tests/browser/harness.sh and front.sh (by
# run.sh, and by a proof that reuses them, as tests/join-proof/ does).
#
# A home's directory client speaks HTTPS to the URL an identity names,
# such as https://dir.test, through Sanctum's pinned egress. The harness
# resolves no name and the run's authority is in no system store, so
# each such cell is given, in its own deployment file alone:
#
#   * ERL_INETRC, an inetrc of the run's own that names every directory
#     the run declared at its front's address (front.sh,
#     `identity_directory`), so the release resolves each with no DNS or
#     /etc/hosts change, and a home reaches the directory any identity
#     names, not only its own;
#   * every front's address in CYFR_PRIVATE_EGRESS_TARGETS, as an operator
#     lists a private directory, since each is a loopback address;
#   * CYFR_DIRECTORY_URL, the one directory this deployment enrolls at;
#
# and, once its server answers, the run's authority as the node's trusted
# store (`:public_key.cacerts_load/1` over `bin/cyfr rpc`), as an operator
# adds a certificate authority to a node's store. No test seam is set.

# The run's inetrc, naming every declared directory at its front, written
# again whenever a cell is configured: every directory is declared first.
identity_inetrc() {
  local file="$WORK/inetrc" host a b c d
  : >"$file"
  for host in "${!IDENTITY_FRONTS[@]}"; do
    IFS=. read -r a b c d <<<"${IDENTITY_FRONTS[$host]}"
    printf '{host, {%s,%s,%s,%s}, ["%s"]}.\n' "$a" "$b" "$c" "$d" "$host" >>"$file"
  done
  printf '{lookup, [file, native]}.\n' >>"$file"
  printf '%s' "$file"
}

# Cell `$1` reaches every declared directory, by name through the run's
# inetrc and at an address listed as a private egress target, and
# enrolls its people at the directory `$2` (its hostname). `$3...` are
# further NAME=value lines for its deployment file.
identity_reaches_directory() {
  local cell="$1" directory="$2" line targets="locus-backends" host
  shift 2
  [ -n "${IDENTITY_FRONTS[$directory]:-}" ] || fail "no directory $directory is declared"
  for host in "${!IDENTITY_FRONTS[@]}"; do targets="$targets,${IDENTITY_FRONTS[$host]}"; done
  sed -i \
    -e "s|^CYFR_PRIVATE_EGRESS_TARGETS=.*|CYFR_PRIVATE_EGRESS_TARGETS=$targets|" \
    -e "/^CYFR_DIRECTORY_URL=/d" -e "/^ERL_INETRC=/d" \
    "$cell/.env"
  {
    echo "CYFR_DIRECTORY_URL=https://$directory"
    echo "ERL_INETRC=$(identity_inetrc)"
    for line in "$@"; do echo "$line"; done
  } >>"$cell/.env"
}

# Set NAME=value in cell `$1`'s deployment file, or with no value remove
# NAME: what an operator changes between two boots.
identity_env() {
  local cell="$1" name="$2"
  sed -i "/^$name=/d" "$cell/.env"
  if [ "$#" -ge 3 ]; then echo "$name=$3" >>"$cell/.env"; fi
}

# Start cell `$1` and have its node trust the run's authority.
identity_start() {
  local cell="$1" answer
  server_start "$cell"
  answer="$(cell_cyfr "$cell" rpc \
    ":public_key.cacerts_load(\"$BROWSER_AUTHORITY/authority.pem\"); IO.puts(\"TRUST=ok\")" |
    sed -n 's/^TRUST=//p' | tail -1)"
  [ "$answer" = ok ] || fail "cell $cell did not take the run's authority"
}

# A copy of the stopped cell `$1` at `$2`, answering as the hostname `$3`
# on listener ports of its own: everything the original held, its
# database, its storage and its deployment's keys, as a thief who took
# the machine holds them. It is no home of the browsers' proxy.
identity_preserved() {
  local source="$1" cell="$2" host="$3" port="$4"
  rm -rf "$cell"
  cp -a "$source" "$cell"
  rm -f "$cell/boot.log" "$cell/ready.json"
  cell_hostname "$cell" "$host" "$port" "$((port + 1))"
}

# Kill cell `$1`'s server where it stands, as a machine dies: its node
# signalled at once, with no stop of its own, then its listener awaited.
identity_kill() {
  local cell="$1" node
  node="$(cell_node "$cell")"
  pkill -9 -f "sname $node( |\$)" 2>/dev/null || true
  server_stop "$cell"
}

# Evaluate this proof's fixture (fixture.exs) inside cell `$1`'s running
# server; `$2...` are its arguments, and its one JSON line is the answer.
identity_fixture() {
  local cell="$1"
  shift
  local args="" arg
  for arg in "$@"; do
    args="$args\"$(printf '%s' "$arg" | sed 's/[\\"]/\\&/g')\","
  done
  cell_cyfr "$cell" rpc \
    "{answer, _} = Code.eval_file(\"$ROOT/tests/identity-proof/fixture.exs\"); IO.puts(answer.([${args%,}]))" |
    sed -n 's/^FIXTURE=//p' | tail -1
}

# POST a restore request to cell `$1` as the browser does, on its own
# listener behind the front's headers: path `$2`, the file `$3` holding
# the installation token, sent in the authorization header, and the JSON
# body file `$4`. Writes the answer's body to `$5` and prints its status.
# The token and the kit are read from their files, never put on a command
# line.
identity_restore_post() {
  local cell="$1" path="$2" token_file="$3" body="$4" out="$5" host port headers
  host="$(sed -n 's/^CYFR_HOST=//p' "$cell/.env" | tail -1)"
  port="$(cell_port "$cell")"
  headers="$(mktemp "$WORK/headers.XXXXXX")"
  printf 'authorization: Bearer %s\n' "$(cat "$token_file")" >"$headers"
  curl -sS -m 60 -o "$out" -w '%{http_code}' -X POST "http://127.0.0.1:$port$path" \
    -H "host: $host" -H "x-forwarded-proto: https" -H "x-forwarded-for: 127.0.0.1" \
    -H "x-forwarded-host: $host" -H "origin: https://$host" \
    -H "@$headers" -H "content-type: application/json" \
    -H "accept: application/json" --data-binary "@$body"
  rm -f "$headers"
}

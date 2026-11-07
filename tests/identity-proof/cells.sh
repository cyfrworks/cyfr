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
#   * CYFR_DIRECTORY_URL, the one directory this deployment reads its
#     people's accounts at;
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
# inetrc and at an address listed as a private egress target, and reads
# its people's accounts at the directory `$2` (its hostname). `$3...` are
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

# Evaluate this proof's fixture (fixture.exs) inside cell `$1`'s running
# server; `$2...` are its arguments, and its one JSON line is the answer.
identity_fixture() {
  local cell="$1"
  shift
  cell_fixture "$cell" "$ROOT/tests/identity-proof/fixture.exs" FIXTURE "$@"
}

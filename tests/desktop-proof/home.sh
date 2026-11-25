#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The CYFR app against a real CYFR (README.md): for each tracked
# tests/desktop-proof/*/run.sh, in sorted order, a fresh CYFR and account
# directory, both the release of the loaded app image IMAGE in the pairing
# proof's topology (tests/pairing-proof/README.md), each behind a TLS
# front of its own (tests/identity-proof/front.sh); then the installed app
# from the DEB in a client container of its own, with no Docker in it, the
# run's authority trusted and nothing else configured; then
#
#   bash SCRIPT APP_PATH HOME_ORIGIN FIXTURE_DIR
#
# inside that container as its own user. A script whose folder holds a
# proof.js runs it as the app's entry: the proof bundle (pack.mjs) takes
# the place of the installed app.asar in that container alone.
#
# Usage: tests/desktop-proof/home.sh DEB IMAGE
#   DEB    the candidate cyfr-desktop package
#   IMAGE  the app image, loaded, of the same architecture as DEB
# It needs Docker, Go (the cells' command line), node and npm's install of
# apps/codex/desktop (pack.mjs bundles with its esbuild), python3 and
# openssl. Each script's record lands in its FIXTURE_DIR/out, copied to
# PROOF_OUT (default: the run's scratch directory, kept with
# RELEASE_BOOT_KEEP=1). Every home, front, container and the scratch
# directory with the run's authority key and setup token is removed when
# a script ends, whether it passes or fails; no script found fails the
# run, as does any script that fails.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" != --one ]; then
  [ "$#" -eq 2 ] || { echo "usage: tests/desktop-proof/home.sh DEB IMAGE" >&2; exit 64; }
  deb="$(realpath "$1")"
  image="$2"
  deb_arch="$(dpkg-deb -f "$deb" Architecture)"
  image_arch="$(docker image inspect -f '{{.Architecture}}' "$image")"
  if [ "$deb_arch" != "$image_arch" ]; then
    echo "::error::the package is for $deb_arch and the image $image for $image_arch" >&2
    exit 1
  fi
  mapfile -t scripts < <(git -C "$HERE/../.." ls-files 'tests/desktop-proof/*/run.sh' | LC_ALL=C sort)
  if [ "${#scripts[@]}" -eq 0 ]; then
    echo "::error::no tests/desktop-proof/*/run.sh is tracked" >&2
    exit 1
  fi
  status=0
  for script in "${scripts[@]}"; do
    echo "=== $script"
    bash "$0" --one "$HERE/../../$script" "$deb" "$image" || { echo "::error::$script failed" >&2; status=1; }
  done
  exit "$status"
fi

SCRIPT="$(realpath "$2")"
DEB="$3"
IMAGE="$4"
NAME="$(basename "$(dirname "$SCRIPT")")"
ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-desktop-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$HERE/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
# shellcheck source=../identity-proof/front.sh
source "$ROOT/tests/identity-proof/front.sh"
# shellcheck source=../identity-proof/cells.sh
source "$ROOT/tests/identity-proof/cells.sh"
OUT="${PROOF_OUT:-$WORK/out}"
FIXTURE="$WORK/fixture"
CLIENT="${PROOF_RUN_PREFIX:-}cyfr-desktop-client-$$"
CELLS="${PROOF_RUN_PREFIX:-}cyfr-desktop-cell-$$"
APP_OUTPUT="$FIXTURE/app-output"
APP_LOG="$FIXTURE/out/app-$NAME.log"
SCRUB=""
mkdir -p "$FIXTURE/out" "$OUT"
mkfifo "$APP_OUTPUT"

cleanup() {
  local code=$?
  docker rm -f "$CLIENT" >/dev/null 2>&1 || true
  if [ -n "$SCRUB" ]; then
    # No writer is left. A scrub still waiting for a first one is given an
    # empty one, then read to its end.
    if kill -0 "$SCRUB" 2>/dev/null; then timeout 5 bash -c ': >"$1"' _ "$APP_OUTPUT" 2>/dev/null || true; fi
    wait "$SCRUB" || [ "$code" -ne 0 ] || code=1
    [ "$code" -eq 0 ] || tail -n 30 "$APP_LOG" >&2 2>/dev/null || true
  fi
  identity_front_stop
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  docker ps -aq --filter "name=^$CELLS-" | xargs -r docker rm -f >/dev/null 2>&1 || true
  mkdir -p "$OUT/$NAME" && cp -R "$FIXTURE/out/." "$OUT/$NAME/" 2>/dev/null || true
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

# The release the cells run is the image's (image-release.sh).
# shellcheck source=image-release.sh
source "$HERE/image-release.sh"
image_release "$IMAGE" "$CELLS"

# The CYFR a script runs against (README.md), named by its folder's
# `home` file, `separate` without one:
#   separate  x.test, reading accounts at the directory dir.test
#   self      x.test serving its own account pages: home and account
#             service share one origin
#   company   x.test serving its own account pages and requiring a company
#             sign-in (join) at the OIDC issuer idp.test, a front with
#             nothing behind it that only records what reaches it, at an
#             address the client alone is told: whatever reaches it is the
#             client's, whatever headers it carries
#   pair      separate's two, with dir.test a CYFR of its own too, its own
#             account service, set up with a setup token of its own: two
#             CYFRs of one account
SHAPE=separate
if [ -f "$(dirname "$SCRIPT")/home" ]; then SHAPE="$(tr -d '[:space:]' <"$(dirname "$SCRIPT")/home")"; fi
case "$SHAPE" in separate | self | company | pair) ;; *) fail "$(dirname "$SCRIPT")/home names no shape this driver makes: '$SHAPE'" ;; esac

step "the run's authority and the CYFR ($SHAPE), from $IMAGE"
browser_authority
X="$WORK/x"
SETUP_TOKEN="$(openssl rand -hex 32)"
LOG_SECRETS+=("$SETUP_TOKEN")
browser_home "$X" x.test
identity_directory x.test
case "$SHAPE" in
  separate | pair)
    DIR="$WORK/dir"
    browser_home "$DIR" dir.test
    identity_directory dir.test
    identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
    DIRECTORY_HOST=dir.test
    ;;
  self | company)
    identity_env "$X" CYFR_DIRECTORY_SERVE writer
    DIRECTORY_HOST=x.test
    ;;
esac
identity_reaches_directory "$X" "$DIRECTORY_HOST"
SECOND_SETUP_TOKEN=""
if [ "$SHAPE" = pair ]; then
  # The second CYFR, its people's accounts at itself as self's x.test.
  identity_reaches_directory "$DIR" dir.test
  identity_env "$DIR" CYFR_REGISTRY_URL dir.test
  SECOND_SETUP_TOKEN="$(openssl rand -hex 32)"
  LOG_SECRETS+=("$SECOND_SETUP_TOKEN")
  identity_env "$DIR" CYFR_SETUP_TOKEN "$SECOND_SETUP_TOKEN"
fi
if [ "$SHAPE" = company ]; then
  # The issuer: a certificate of the run's authority and a front at an
  # address of the run's own, forwarding to a port nothing listens on.
  # Declared once x.test is configured, so that its inetrc does not name
  # it: the CYFR's own server cannot reach it.
  IDP="$WORK/idp"
  mkdir -p "$IDP"
  browser_certificate idp.test
  printf 'CYFR_HOST=idp.test\nCYFR_PROXY_PORT=9\n' >"$IDP/.env"
  identity_directory idp.test
  IDP_SECRET="$(openssl rand -hex 32)"
  LOG_SECRETS+=("$IDP_SECRET")
fi
identity_env "$X" CYFR_REGISTRY_URL "$DIRECTORY_HOST"
identity_env "$X" CYFR_SETUP_TOKEN "$SETUP_TOKEN"
# The CYFR's worker service, at a port of the run's own where nothing
# listens unless a proof answers its status (media/).
cell_pick_port WORKER_PORT
identity_env "$X" CYFR_LOCUS_RUNTIME_WORKERS "wrk_proof=http://127.0.0.1:$WORKER_PORT"
if [ "$SHAPE" = company ]; then
  identity_env "$X" CYFR_COMPANY_LOGIN join
  identity_env "$X" CYFR_OIDC_ISSUER https://idp.test
  identity_env "$X" CYFR_OIDC_CLIENT_ID cyfr-desktop-proof
  identity_env "$X" CYFR_OIDC_CLIENT_SECRET "$IDP_SECRET"
fi

step "starting them and their fronts"
case "$SHAPE" in
  separate) server_start "$DIR" ;;
  pair) identity_start "$DIR" ;;
esac
if [ -n "${DIR:-}" ]; then identity_front_start "$DIR"; fi
identity_start "$X"
identity_front_start "$X"
if [ "$SHAPE" = company ]; then identity_front_start "$IDP"; fi

# What the script and its proof get: the CYFR's address, its account
# directory, the run's authority, the setup token, the worker service's
# port and each front's control address, and in pair the second CYFR's
# address and setup token. The app gets the address alone.
cp "$BROWSER_AUTHORITY/authority.pem" "$FIXTURE/authority.pem"
fronts=()
for host in "${!IDENTITY_FRONTS[@]}"; do fronts+=("$host" "$(identity_front_control "$host")"); done
python3 -I -c 'import json, sys; a = sys.argv; json.dump({"home": "https://x.test", "directory": "https://" + a[1], "setup_token": a[2],
  "worker_port": int(a[4]), "fronts": dict(zip(a[6::2], a[7::2])),
  **({"second": "https://dir.test", "second_setup_token": a[5]} if a[5] else {})}, open(a[3], "w"))' \
  "$DIRECTORY_HOST" "$SETUP_TOKEN" "$FIXTURE/inputs.json" "$WORKER_PORT" "$SECOND_SETUP_TOKEN" "${fronts[@]}"
if [ -f "$(dirname "$SCRIPT")/proof.js" ]; then
  node "$HERE/pack.mjs" "$(dirname "$SCRIPT")/proof.js" "$FIXTURE/proof.asar"
fi
chmod -R a+rwX "$FIXTURE"

step "the client: the installed app, with no Docker"
hosts=()
for host in "${!IDENTITY_FRONTS[@]}"; do hosts+=(--add-host "$host:${IDENTITY_FRONTS[$host]}"); done
docker rm -f "$CLIENT" >/dev/null 2>&1 || true
docker run -d --name "$CLIENT" --network host --security-opt seccomp=unconfined \
  "${hosts[@]}" \
  -v "$DEB:/deb/cyfr-desktop.deb:ro" -v "$HERE:/proof:ro" -v "$FIXTURE:/fixture" \
  ubuntu:24.04 sleep infinity >/dev/null
docker exec "$CLIENT" bash /proof/client.sh >"$WORK/client.log" 2>&1 || {
  tail -n 40 "$WORK/client.log" >&2
  fail "the client container could not be prepared"
}

step "$NAME"
node "$HERE/scrub-lines.mjs" <"$APP_OUTPUT" >"$APP_LOG" &
SCRUB=$!
docker exec -u proof -e HOME=/home/proof -w /home/proof "$CLIENT" \
  bash "/proof/$NAME/run.sh" /opt/cyfr/CYFR https://x.test /fixture

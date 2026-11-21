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
mkdir -p "$FIXTURE/out" "$OUT"

cleanup() {
  local code=$?
  docker rm -f "$CLIENT" >/dev/null 2>&1 || true
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

# The release the cells run is the image's: bin/cyfr here runs the
# image's /app/bin/cyfr on this host's network, as this user, with the
# cell's environment (release.sh cell_env) and the run's folders where
# they are here, and the image's own validator. A start runs in a
# container named for its node, which cleanup removes whatever happens.
REL="$WORK/image-release"
mkdir -p "$REL/bin"
cat >"$REL/bin/cyfr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=(run --rm --network host --user "$(id -u):$(id -g)" --entrypoint /app/bin/cyfr
  -v "$WORK:$WORK" -v "$ROOT:$ROOT:ro" -w "\$PWD" -e CYFR_WASM_TOOLS=/usr/local/bin/wasm-tools)
for name in \$(compgen -e); do
  case "\$name" in PATH | PWD | OLDPWD | SHLVL | _ | CYFR_WASM_TOOLS) ;; *) args+=(-e "\$name") ;; esac
done
if [ "\${1:-}" = start ]; then args+=(--name "$CELLS-\$RELEASE_NODE"); fi
exec docker "\${args[@]}" "$IMAGE" "\$@"
EOF
chmod +x "$REL/bin/cyfr"

step "the run's authority, the account directory and the CYFR, from $IMAGE"
browser_authority
DIR="$WORK/dir"
X="$WORK/x"
browser_home "$DIR" dir.test
browser_home "$X" x.test
identity_directory dir.test
identity_directory x.test
identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
SETUP_TOKEN="$(openssl rand -hex 32)"
identity_reaches_directory "$X" dir.test
identity_env "$X" CYFR_REGISTRY_URL dir.test
identity_env "$X" CYFR_SETUP_TOKEN "$SETUP_TOKEN"
LOG_SECRETS+=("$SETUP_TOKEN")

step "starting them and their fronts"
server_start "$DIR"
identity_front_start "$DIR"
identity_start "$X"
identity_front_start "$X"

# What the script and its proof get: the CYFR's address, the run's
# authority, the setup token, and each front's control address. The app
# gets the address alone.
cp "$BROWSER_AUTHORITY/authority.pem" "$FIXTURE/authority.pem"
python3 -I -c 'import json, sys; json.dump({"home": "https://x.test", "directory": "https://dir.test", "setup_token": sys.argv[1],
  "fronts": {"x.test": sys.argv[2], "dir.test": sys.argv[3]}}, open(sys.argv[4], "w"))' \
  "$SETUP_TOKEN" "$(identity_front_control x.test)" "$(identity_front_control dir.test)" "$FIXTURE/inputs.json"
if [ -f "$(dirname "$SCRIPT")/proof.js" ]; then
  node "$HERE/pack.mjs" "$(dirname "$SCRIPT")/proof.js" "$FIXTURE/proof.asar"
fi
chmod -R a+rwX "$FIXTURE"

step "the client: the installed app, with no Docker"
docker rm -f "$CLIENT" >/dev/null 2>&1 || true
docker run -d --name "$CLIENT" --network host --security-opt seccomp=unconfined \
  --add-host "x.test:${IDENTITY_FRONTS[x.test]}" --add-host "dir.test:${IDENTITY_FRONTS[dir.test]}" \
  -v "$DEB:/deb/cyfr-desktop.deb:ro" -v "$HERE:/proof:ro" -v "$FIXTURE:/fixture" \
  ubuntu:24.04 sleep infinity >/dev/null
docker exec "$CLIENT" bash /proof/client.sh >"$WORK/client.log" 2>&1 || {
  tail -n 40 "$WORK/client.log" >&2
  fail "the client container could not be prepared"
}

step "$NAME"
docker exec -u proof -e HOME=/home/proof -w /home/proof "$CLIENT" \
  bash "/proof/$NAME/run.sh" /opt/cyfr/CYFR https://x.test /fixture

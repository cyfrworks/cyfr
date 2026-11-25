# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# The release the cells of a real-CYFR proof run (home.sh, box/box.sh),
# sourced after tests/release-boot/release.sh, whose WORK and ROOT it
# reads: image_release IMAGE CELLS makes REL the image's own, so that
# bin/cyfr there runs the image's /app/bin/cyfr on this host's network, as
# this user, with the cell's environment (release.sh cell_env) and the
# run's folders where they are here, and the image's own validator. A
# start runs in a container named CELLS-<its node>, which the proof's
# cleanup removes whatever happens.
image_release() {
  local image="$1" cells="$2"
  REL="$WORK/image-release"
  mkdir -p "$REL/bin"
  cat >"$REL/bin/cyfr" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
args=(run --rm --network host --user "$(id -u):$(id -g)" --entrypoint /app/bin/cyfr
  -v "$WORK:$WORK" -v "$ROOT:$ROOT:ro" -w "\$PWD" -e CYFR_WASM_TOOLS=/usr/local/bin/wasm-tools)
for name in \$(compgen -e); do
  case "\$name" in PATH | PWD | OLDPWD | SHLVL | _ | CYFR_WASM_TOOLS) ;; *) args+=(-e "\$name") ;; esac
done
if [ "\${1:-}" = start ]; then args+=(--name "$cells-\$RELEASE_NODE"); fi
exec docker "\${args[@]}" "$image" "\$@"
SCRIPT
  chmod +x "$REL/bin/cyfr"
}

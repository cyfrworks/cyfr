# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# shellcheck shell=bash
#
# A CYFR folder as a release's download leaves it, but for the loaded
# image and no Locus (the candidate is a dev build, which downloads
# nothing), sourced by the setup proof in the app (app.sh) and the box's
# proof with two CYFRs (tests/desktop-proof/box/box.sh). The sourcing
# script sets ROOT (this checkout) and IMAGE (the loaded app image).

# A port of this machine's loopback no listener holds now.
free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# seed DIR PORT [NAME=value...]: the folder DIR for a CYFR at PORT. The
# lines after PORT are its account settings, appended to .env.example;
# with none, it serves its own accounts at http://localhost:PORT. Each
# word of SEED_MOUNTS (HOST:CONTAINER:ro) is mounted into its cyfr.
seed() {
  local D=$1 PORT=$2 mount
  shift 2
  [ "$#" -gt 0 ] || set -- CYFR_DIRECTORY_SERVE=writer "CYFR_DIRECTORY_URL=http://localhost:$PORT" "CYFR_REGISTRY_URL=localhost:$PORT" \
    CYFR_PRIVATE_EGRESS_TARGETS=locus-backends,127.0.0.1
  cp "$ROOT/docker-compose.yml" "$ROOT/Caddyfile" "$D/"
  cp "$ROOT/apps/locus/keeper/seccomp/keeper.json" "$D/keeper.seccomp.json"
  {
    printf '%s\n' services: "  cyfr:" "    image: $IMAGE" "    pull_policy: never" "    container_name: !reset null"
    if [ -n "${SEED_MOUNTS:-}" ]; then
      echo "    volumes:"
      for mount in $SEED_MOUNTS; do echo "      - $mount"; done
    fi
    printf '%s\n' "  locus-runtime:" '    profiles: ["proof-never"]' "  locus-backends:" '    profiles: ["proof-never"]' \
      "  locus-backends-guard:" '    profiles: ["proof-never"]'
  } >"$D/docker-compose.override.yml"
  sed -e "s|^CYFR_PORT=.*|CYFR_PORT=$PORT|" -e 's|^CYFR_LOCUS_BUILDS_URL=.*|CYFR_LOCUS_BUILDS_URL=|' \
    -e '/^CYFR_DIRECTORY_SERVE=/d;/^CYFR_DIRECTORY_URL=/d;/^CYFR_REGISTRY_URL=/d;/^CYFR_PRIVATE_EGRESS_TARGETS=/d' "$ROOT/.env.example" >"$D/.env.example"
  printf '%s\n' "" CYFR_AUTO_MIGRATE=on "$@" >>"$D/.env.example"
}

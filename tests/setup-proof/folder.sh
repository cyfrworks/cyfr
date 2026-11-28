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

# The tunnel keys of the private name's vectors (apps/codex/internal/link),
# one for each seeded folder in turn: its .env.example carries it, which
# init keeps, so the folder's private address is known before init writes
# .env. Each key's public half and the private name it gives follow it.
SEED_LINKS=(
  "privkey:b09562be8a0bfee65eaeef5555dad1576019560663ae4616a0cef7b3c5e8c872,psk:6a681bf4064665498645f666e39f9c3917071baecf8685b0923468fd769c47bc 6b6b937aca103230d149eb148efbcfb59e6d1f05bb04dc648ac3e92339eae74a h-xeypbemm44chehc5"
  "privkey:f844138e8c9a51aa225459b275e5697ef85fbb4ba913fac5304410e1d6b2d26c,psk:5299a4d73c45958434f1faa0b9bd021786f2be1c3621beb9d381fc024db167a5 527be3055d91803acc9a4c8cd16521654fc43affa3c89322edbaa20f9e5ced0a h-ookaajj2w5uapqdp"
  "privkey:00218c09adaf3c491494e26318e863771b833e17d98348be7c4f0b62bfb0406c,psk:f2a87f8123b8d8364ffab21d8f733c1c592bad28bbec4f310b3a18487b40d483 285feb8081eb6a3100c78dadd7925e33e956499e1ebe80b85111368ddf63174e h-kmb7nuzlttehja4m"
)
SEEDED=0
# SEED_ADDRESS is the private address of the folder seed made last.
SEED_ADDRESS=""

# seed DIR PORT [NAME=value...]: the folder DIR for a CYFR at PORT, at the
# private address the next of SEED_LINKS names (SEED_ADDRESS). The lines
# after PORT are its account settings, appended to .env.example; with
# none, it serves its own accounts at its private address. Each word of
# SEED_MOUNTS (HOST:CONTAINER:ro) is mounted into its cyfr.
seed() {
  local D=$1 PORT=$2 mount key public name
  shift 2
  [ "$SEEDED" -lt "${#SEED_LINKS[@]}" ] || { echo "seed: every tunnel key of SEED_LINKS is taken" >&2; return 1; }
  read -r key public name <<<"${SEED_LINKS[$SEEDED]}"
  SEEDED=$((SEEDED + 1))
  SEED_ADDRESS="http://$name.localhost:$PORT"
  [ "$#" -gt 0 ] || set -- CYFR_DIRECTORY_SERVE=writer "CYFR_DIRECTORY_URL=$SEED_ADDRESS" "CYFR_REGISTRY_URL=$name.localhost:$PORT" \
    CYFR_PRIVATE_EGRESS_TARGETS=locus,127.0.0.1
  cp "$ROOT/docker-compose.yml" "$ROOT/Caddyfile" "$D/"
  cp "$ROOT/apps/locus/keeper/seccomp/keeper.json" "$D/keeper.seccomp.json"
  cp "$ROOT/apps/locus/keeper/seccomp/container.json" "$D/container.seccomp.json"
  {
    printf '%s\n' services: "  cyfr:" "    image: $IMAGE" "    pull_policy: never" "    container_name: !reset null"
    if [ -n "${SEED_MOUNTS:-}" ]; then
      echo "    volumes:"
      for mount in $SEED_MOUNTS; do echo "      - $mount"; done
    fi
    printf '%s\n' "  locus:" '    profiles: ["proof-never"]' "  locus-guard:" '    profiles: ["proof-never"]'
  } >"$D/docker-compose.override.yml"
  sed -e "s|^CYFR_PORT=.*|CYFR_PORT=$PORT|" -e 's|^CYFR_LOCUS_BUILDS_KEY=.*|CYFR_LOCUS_BUILDS_KEY=|' \
    -e "s|^CYFR_LINK_KEY=.*|CYFR_LINK_KEY=$key|" -e "s|^CYFR_LINK_PUBLIC=.*|CYFR_LINK_PUBLIC=$public|" \
    -e '/^CYFR_DIRECTORY_SERVE=/d;/^CYFR_DIRECTORY_URL=/d;/^CYFR_REGISTRY_URL=/d;/^CYFR_PRIVATE_EGRESS_TARGETS=/d' "$ROOT/.env.example" >"$D/.env.example"
  printf '%s\n' "" CYFR_AUTO_MIGRATE=on "$@" >>"$D/.env.example"
}

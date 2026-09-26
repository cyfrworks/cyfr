# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The browser harness's shell side, sourced after tests/release-boot/
# release.sh by tests/browser/run.sh and the two proofs
# (tests/tincture-proof/run.sh, tests/hostile-frame-proof/run.sh).
#
# A browser cell's server names itself `cyfr.test` (CYFR_HOST), the name
# every browser reaches it under through the harness's proxy
# (tests/browser/lib.mjs), so the origin the policies are derived for is
# the origin the browsers see. The experiments run in the official
# Playwright image, pinned by digest, with Playwright's library installed
# from tests/browser/package-lock.json and nothing fetched at test time but
# that; the container shares this host's network and reaches the server on
# loopback.

# mcr.microsoft.com/playwright:v1.63.0-noble
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27"
BROWSER_HOME="$ROOT/tests/browser"

# A new cell (release.sh's `cell_new`) whose server names itself cyfr.test:
# its host, and the public URL the policies derive the endpoint's origin
# from (`Sanctum.origin/0`), which a deployment that is not
# http://localhost:4000 declares.
browser_cell() {
  cell_new "$@"
  sed -i 's/^CYFR_HOST=.*/CYFR_HOST=cyfr.test/' "$1/.env"
  echo "CYFR_PUBLIC_URL=http://cyfr.test:$PORT" >>"$1/.env"
  grep -qx 'CYFR_HOST=cyfr.test' "$1/.env" || fail "the cell does not name cyfr.test"
}

# The browser session cookie of the session token `$2`, minted by the
# server running on cell `$1` (tests/browser/session.exs).
browser_cookie() {
  local cookie
  cookie="$(cell_cyfr "$1" rpc \
    "{answer, _} = Code.eval_file(\"$BROWSER_HOME/session.exs\"); IO.puts(answer.([\"$2\"]))" \
    | sed -n 's/^COOKIE=//p' | tail -1)"
  [ -n "$cookie" ] || fail "the server minted no session cookie"
  printf '%s' "$cookie"
}

# Run the experiment `$2` of the directory tests/`$1` in the Playwright
# image, with `$3...` as its arguments; OUT is mounted at /out. The
# experiment's directory is copied beside tests/browser, so it imports the
# harness's library as ../browser/lib.mjs, and Playwright through it.
playwright_run() {
  local name="$1" script="$2"
  shift 2
  mkdir -p "$OUT"
  docker run --rm --network host --ipc=host \
    -u "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_update_notifier=false \
    -v "$ROOT/tests:/tests:ro" -v "$OUT:/out" \
    "$PLAYWRIGHT_IMAGE" \
    sh -c 'set -e
           mkdir -p /tmp/tests
           cp -R /tests/browser /tmp/tests/browser
           [ "$0" = browser ] || cp -R "/tests/$0" "/tmp/tests/$0"
           (cd /tmp/tests/browser && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
           cd "/tmp/tests/$0"
           exec node "$@"' \
    "$name" "$script" "$@"
}

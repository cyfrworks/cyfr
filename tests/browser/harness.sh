# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The browser harness's shell side, sourced after tests/release-boot/
# release.sh by tests/browser/run.sh, the proofs (tests/tincture-proof/,
# tests/hostile-frame-proof/, tests/canvas-proof/) and the multi-home smoke
# (tests/multi-home-smoke/run.sh).
#
# A browser cell's server names itself `cyfr.test` (CYFR_HOST), the name
# every browser reaches it under through the harness's proxy
# (tests/browser/lib.mjs), so the origin the policies are derived for is
# the origin the browsers see.
#
# A home is a cell on a `.test` hostname of its own, several at once, each
# reached by every browser at https://HOST through the same proxy, whose
# TLS front presents a certificate the run's own authority issued for that
# name. No name is resolved by DNS or /etc/hosts: the proxy routes each name
# itself. The authority is made for the run under WORK, its private key
# kept apart and never mounted, and every browser of the Playwright
# container trusts it: Chromium's full build through a managed policy,
# Firefox through the policies file Playwright's build reads, and WebKit
# through the system bundle it verifies against.
#
# The experiments run in the official Playwright image, pinned by digest,
# with Playwright's library installed from tests/browser/package-lock.json
# and nothing fetched at test time but that; the container shares this
# host's network and reaches every server on loopback.

# mcr.microsoft.com/playwright:v1.63.0-noble
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27"
BROWSER_HOME="$ROOT/tests/browser"

# The run's authority (`browser_authority`), mounted at /authority, and the
# directory of the keys it and the stranger sign with, which nothing mounts.
BROWSER_AUTHORITY=""
BROWSER_AUTHORITY_KEYS=""
# The first home's listener port; each next home takes the next two.
BROWSER_HOMES_PORT="${BROWSER_HOMES_PORT:-4410}"
# The run's homes and unsigned names, as `name host port certificate`
# rows, which /authority/homes.json lists.
BROWSER_HOMES=()
BROWSER_UNSIGNED=()

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

# Publish, for the person whose session token is `$2` on cell `$1`, the
# layout document `$3` over revision `${4:-0}`, as the console publishes it
# (`layout.edit` through the gate).
browser_layout() {
  local answer
  answer="$(server_fixture "$1" console "$2" layout/edit "{\"document\":$3,\"revision\":${4:-0}}")"
  printf '%s' "$answer" | grep -q '"ok"' || fail "the layout was not published: $answer"
}

# A layout whose desktop no one installed: the shell runs no desktop and
# draws its picker, which the frame experiments launch their tinctures from.
browser_picker_layout() {
  local none='{"desktop":"tincture:local.no-desktop","slots":[],"floating":[]}'
  browser_layout "$1" "$2" "{\"version\":1,\"postures\":{\"desk\":$none,\"hand\":$none}}"
}

# ---------------------------------------------------------------------------
# Homes: several cells on several hostnames at once, over HTTPS
# ---------------------------------------------------------------------------

# The run's certificate authority: its certificate, the trust each browser
# reads and every name's certificate in `$WORK/authority` (mounted at
# /authority), and its private key in `$WORK/authority-keys`, which nothing
# mounts. It lives a day and vouches for `.test` names alone (a critical
# name constraint). A second authority, the stranger, which no browser
# trusts, issues the certificates of names the run's authority did not
# sign.
browser_authority() {
  BROWSER_AUTHORITY="$WORK/authority"
  BROWSER_AUTHORITY_KEYS="$WORK/authority-keys"
  mkdir -p "$BROWSER_AUTHORITY"
  mkdir -p -m 700 "$BROWSER_AUTHORITY_KEYS"
  browser_root run "CYFR harness run authority $$" "$BROWSER_AUTHORITY/authority.pem" \
    -addext "nameConstraints=critical,permitted;DNS:test"
  browser_root stranger "CYFR harness stranger $$" "$BROWSER_AUTHORITY_KEYS/stranger.pem"

  # Chromium: the managed policy its full build reads (CACertificates, the
  # certificate's DER in base64). Firefox: the policies file Playwright's
  # build reads from PLAYWRIGHT_FIREFOX_POLICIES_JSON. WebKit: the
  # certificate itself, as its system bundle (`playwright_run`).
  local der
  der="$(openssl x509 -in "$BROWSER_AUTHORITY/authority.pem" -outform DER | base64 -w0)"
  [ -n "$der" ] || fail "the run's authority has no certificate"
  printf '{"CACertificates":["%s"]}\n' "$der" >"$BROWSER_AUTHORITY/chromium-policy.json"
  printf '{"policies":{"Certificates":{"Install":["/authority/authority.pem"]}}}\n' \
    >"$BROWSER_AUTHORITY/firefox-policies.json"
  browser_homes_file
}

# A self-signed P-256 authority named `$1` (run or stranger), `$2` its
# subject, its certificate written to `$3` and `$4...` further extensions.
browser_root() {
  local name="$1" subject="$2" out="$3"
  shift 3
  (umask 077 && openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -days 1 -subj "/CN=$subject" \
    -keyout "$BROWSER_AUTHORITY_KEYS/$name.key" -out "$out" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" "$@" 2>/dev/null) ||
    fail "the $name authority was not made"
  chmod 644 "$out"
}

# A certificate for the name `$1`, issued by the run's authority, or by the
# stranger when `$2` is `stranger`: `$BROWSER_AUTHORITY/$1.pem`, and its
# key beside it, which the TLS front presents for that name. Issuing again
# replaces both.
browser_certificate() {
  local host="$1" issuer="${2:-run}" ca
  [ -n "$BROWSER_AUTHORITY" ] || fail "no authority: browser_authority comes first"
  case "$issuer" in
    run) ca="$BROWSER_AUTHORITY/authority.pem" ;;
    stranger) ca="$BROWSER_AUTHORITY_KEYS/stranger.pem" ;;
    *) fail "no authority named '$issuer'" ;;
  esac
  local csr="$BROWSER_AUTHORITY_KEYS/$host.csr"
  (umask 077 && openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj "/CN=$host" -keyout "$BROWSER_AUTHORITY/$host.key" -out "$csr" 2>/dev/null) ||
    fail "no key for $host"
  openssl x509 -req -in "$csr" -CA "$ca" -CAkey "$BROWSER_AUTHORITY_KEYS/$issuer.key" \
    -set_serial "0x$(openssl rand -hex 16)" -days 1 -out "$BROWSER_AUTHORITY/$host.pem" \
    -extfile <(printf '%s\n' "subjectAltName=DNS:$host" "basicConstraints=critical,CA:FALSE" \
      "keyUsage=critical,digitalSignature" "extendedKeyUsage=serverAuth") 2>/dev/null ||
    fail "the $issuer authority issued no certificate for $host"
}

# A home: a new cell at `$1` (release.sh's `cell_new`, `$3` the PostgreSQL
# URL of its database) answering as the hostname `$2` (`cell_hostname`) on
# the next two listener ports, with a certificate for `$2` from the run's
# authority. Its name is the cell's directory name.
browser_home() {
  local cell="$1" host="$2" url="${3:-}" name port
  name="$(basename "$cell")"
  [ -n "$BROWSER_AUTHORITY" ] || fail "no authority: browser_authority comes first"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
    fail "a home's cell is named in lowercase letters, digits and dashes, not '$name'"
  [[ "$host" == *.test ]] || fail "a home's hostname is a .test name, not '$host'"
  port=$((BROWSER_HOMES_PORT + 2 * ${#BROWSER_HOMES[@]}))
  cell_new "$cell" "$url"
  cell_hostname "$cell" "$host" "$port" "$((port + 1))"
  browser_certificate "$host"
  BROWSER_HOMES+=("$name $host $port $host")
  browser_homes_file
}

# A name `$1` the run's authority did not sign, routed to the listener of
# the home at `$2`: with `$3` `stranger` the front presents the stranger's
# certificate for it; with `misnamed`, the home's own certificate, which
# names the home and not `$1`. Every browser must refuse it.
browser_unsigned() {
  local host="$1" cell="$2" kind="$3" cert
  [[ "$host" == *.test ]] || fail "an unsigned name is a .test name, not '$host'"
  case "$kind" in
    stranger)
      browser_certificate "$host" stranger
      cert="$host"
      ;;
    misnamed) cert="$(sed -n 's/^CYFR_HOST=//p' "$cell/.env" | tail -1)" ;;
    *) fail "an unsigned name is stranger or misnamed, not '$kind'" ;;
  esac
  [ -f "$BROWSER_AUTHORITY/$cert.pem" ] || fail "$cell is not a home of this run"
  BROWSER_UNSIGNED+=("$host $host $(cell_port "$cell") $cert")
  browser_homes_file
}

# /authority/homes.json: the run's homes and unsigned names, each with the
# listener its requests go to and the certificate and key the front
# presents for it (lib.mjs `readHomes`).
browser_homes_file() {
  printf '{"homes":[%s],"unsigned":[%s]}\n' \
    "$(browser_rows ${BROWSER_HOMES[@]+"${BROWSER_HOMES[@]}"})" \
    "$(browser_rows ${BROWSER_UNSIGNED[@]+"${BROWSER_UNSIGNED[@]}"})" \
    >"$BROWSER_AUTHORITY/homes.json"
}

# The rows `$@` (`name host port certificate`) as JSON objects,
# comma-separated.
browser_rows() {
  local row name host port cert sep=""
  for row in "$@"; do
    read -r name host port cert <<<"$row"
    printf '%s{"name":"%s","host":"%s","port":%s,"cert":"/authority/%s.pem","key":"/authority/%s.key"}' \
      "$sep" "$name" "$host" "$port" "$cert" "$cert"
    sep=","
  done
}

# ---------------------------------------------------------------------------
# The browsers
# ---------------------------------------------------------------------------

# Run the experiment `$2` of the directory tests/`$1` in the Playwright
# image, with `$3...` as its arguments; OUT is mounted at /out. The
# experiment's directory is copied beside tests/browser, so it imports the
# harness's library as ../browser/lib.mjs, and Playwright through it. Once
# the run has an authority, it is mounted at /authority and every browser
# of the container trusts it; WebKit then trusts it alone.
playwright_run() {
  local name="$1" script="$2"
  shift 2
  mkdir -p "$OUT"
  local -a trust=()
  if [ -n "$BROWSER_AUTHORITY" ]; then
    trust=(
      -v "$BROWSER_AUTHORITY:/authority:ro"
      -v "$BROWSER_AUTHORITY/chromium-policy.json:/etc/opt/chrome_for_testing/policies/managed/cyfr-harness.json:ro"
      -v "$BROWSER_AUTHORITY/authority.pem:/etc/ssl/certs/ca-certificates.crt:ro"
      -e PLAYWRIGHT_FIREFOX_POLICIES_JSON=/authority/firefox-policies.json
    )
  fi
  docker run --rm --network host --ipc=host \
    -u "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_update_notifier=false \
    -v "$ROOT/tests:/tests:ro" -v "$OUT:/out" ${trust[@]+"${trust[@]}"} \
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

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The browser harness's shell side, sourced after tests/release-boot/
# release.sh by tests/browser/run.sh, by each browser proof's scripts
# under tests/ and by the tests of the proofs' shared plumbing.
#
# A home is a cell on a `.test` hostname of its own, a public home of that
# name (CYFR_ACCESS=public), one or several at once, each reached by every
# browser at https://HOST through the harness's proxy (tests/browser/
# lib.mjs), whose TLS front presents a certificate the run's own authority
# issued for that name and forwards to the home's proxy listener. A proof
# of one cell runs it as the home `cyfr.test` (`browser_cell`), so the
# origin the policies are derived for is the origin the browsers see, with
# the attacker's name, `attacker.test`, beside it. No name is resolved by
# DNS or /etc/hosts: the proxy routes each name itself. The authority is made for the run under
# WORK, its private key kept apart and never mounted, and every browser of
# the Playwright container trusts it: Chromium's full build through a
# managed policy, Firefox through the policies file Playwright's build
# reads, and WebKit through the system bundle it verifies against.
#
# The experiments run in the official Playwright image, pinned by digest,
# with Playwright's library installed from tests/browser/package-lock.json
# once for each lockfile and nothing fetched at test time but that; the
# container shares this host's network and reaches every server on
# loopback.
#
# A proof that asks the server for its part mid-run does it through its
# output directory (`ask-<id>.json` written by the proof, answered
# `answer-<id>.json` here); this file holds that loop (`answer_asks`,
# `proof_await`), and lib.mjs the proof's side of it (`ask`).

# mcr.microsoft.com/playwright:v1.64.0-noble
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright@sha256:06a9939e57531807f8d5fd76ce44b53165ffb7d7501d87ab10e285c20b1e971f"
BROWSER_HOME="$ROOT/tests/browser"

# The run's authority (`browser_authority`), mounted at /authority, and the
# directory of the keys it and the stranger sign with, which nothing mounts.
BROWSER_AUTHORITY=""
BROWSER_AUTHORITY_KEYS=""
# The first home's listener port; each home takes three (its loopback
# listener, its host API and its proxy listener), the next home the next
# three.
BROWSER_HOMES_PORT="${BROWSER_HOMES_PORT:-4410}"
# The run's homes and unsigned names, as `name host port certificate`
# rows, where port is that of the proxy listener the front forwards to,
# which /authority/homes.json lists, and whether the attacker's name has
# its certificate (`browser_attacker`).
BROWSER_HOMES=()
BROWSER_UNSIGNED=()
BROWSER_ATTACKER=""

# The cell of a proof of one cell: the home `cyfr.test` at `$1` (`$2` the
# PostgreSQL URL of its database), as `browser_home` makes every home, with
# the run's authority made first when the run has none, and the attacker's
# name beside it.
browser_cell() {
  [ -n "$BROWSER_AUTHORITY" ] || browser_authority
  browser_home "$1" cyfr.test "${2:-}"
  browser_attacker
}

# The attacker's name, `attacker.test`, served over HTTPS too: a
# certificate for it from the run's authority, which the front presents
# for it and forwards its requests to the receiver of the experiment that
# starts one (lib.mjs `startProxy`).
browser_attacker() {
  browser_certificate attacker.test
  BROWSER_ATTACKER=attacker.test
  browser_homes_file
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
# layout document `$3` (version 2) over revision `${4:-0}`: `layout.edit`
# under that session, through the gate. No console page publishes a layout.
browser_layout() {
  local answer
  answer="$(server_fixture "$1" console "$2" layout/edit "{\"document\":$3,\"revision\":${4:-0}}")"
  printf '%s' "$answer" | grep -q '"ok"' || fail "the layout was not published: $answer"
}

# A layout with no canvas: the shell runs no canvas and draws its picker,
# which the frame experiments launch their tinctures from.
browser_picker_layout() {
  browser_layout "$1" "$2" '{"version":2,"canvases":[]}'
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
# URL of its database), the public home `cyfr init` makes for the hostname
# `$2` (`cell_hostname`), on the next three listener ports, with a
# certificate for `$2` from the run's authority. Its name is the cell's
# directory name.
browser_home() {
  local cell="$1" host="$2" url="${3:-}" name port
  name="$(basename "$cell")"
  [ -n "$BROWSER_AUTHORITY" ] || fail "no authority: browser_authority comes first"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
    fail "a home's cell is named in lowercase letters, digits and dashes, not '$name'"
  [[ "$host" == *.test ]] || fail "a home's hostname is a .test name, not '$host'"
  port=$((BROWSER_HOMES_PORT + 3 * ${#BROWSER_HOMES[@]}))
  cell_new "$cell" "$url" "$host"
  cell_hostname "$cell" "$host" "$port"
  browser_certificate "$host"
  BROWSER_HOMES+=("$name $host $(cell_proxy_port "$cell") $host")
  browser_homes_file
}

# A name `$1` the run's authority did not sign, routed to the proxy
# listener of the home at `$2`: with `$3` `stranger` the front presents the
# stranger's certificate for it; with `misnamed`, the home's own
# certificate, which names the home and not `$1`. Every browser must refuse
# it.
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
  BROWSER_UNSIGNED+=("$host $host $(cell_proxy_port "$cell") $cert")
  browser_homes_file
}

# /authority/homes.json: the run's homes and unsigned names, each with the
# proxy listener its requests go to and the certificate and key the front
# presents for it, and the attacker's name with its certificate and key, or
# null (lib.mjs `readHomes`).
browser_homes_file() {
  local attacker=null
  [ -z "$BROWSER_ATTACKER" ] ||
    attacker="$(printf '{"name":"attacker","host":"%s","cert":"/authority/%s.pem","key":"/authority/%s.key"}' \
      "$BROWSER_ATTACKER" "$BROWSER_ATTACKER" "$BROWSER_ATTACKER")"
  printf '{"homes":[%s],"unsigned":[%s],"attacker":%s}\n' \
    "$(browser_rows ${BROWSER_HOMES[@]+"${BROWSER_HOMES[@]}"})" \
    "$(browser_rows ${BROWSER_UNSIGNED[@]+"${BROWSER_UNSIGNED[@]}"})" \
    "$attacker" >"$BROWSER_AUTHORITY/homes.json"
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
# A proof's asks
# ---------------------------------------------------------------------------

# The proof's own container, found by the output directory only this run
# mounts: stopping the subshell that started it leaves `docker run` and its
# container behind.
stop_proof_container() {
  local ids
  ids="$(docker ps -q --filter "volume=$OUT" 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker stop -t 5 $ids >/dev/null 2>&1 || true
  fi
}

# Field `$2...` of the ask file `$1`, as release.sh's `field` prints it.
asked() {
  field "$(cat "$1")" "${@:2}"
}

# Each ask the proof has written into OUT, answered once. The proof's
# dispatch `$1` is called in this shell, never a subshell, as `$1 ASK ID`,
# so it may keep state between asks; it leaves its answer in ANSWER, and
# an empty one is answered `$2` (default: the fixture answered nothing).
# The ask is removed once its answer is made, before the answer appears:
# an ask may carry a kit, a cookie, a token or a digest of a typed key, and
# none outlives the read it was for, and an ask whose answer the proof
# deletes once read is never answered again. The answer is written aside
# and renamed, so the proof never reads half of one.
answer_asks() {
  local dispatch="$1" empty='{"error":"the fixture answered nothing"}' ask id
  [ "$#" -lt 2 ] || empty="$2"
  for ask in "$OUT"/ask-*.json; do
    [ -e "$ask" ] || continue
    id="${ask##*/ask-}"
    id="${id%.json}"
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    [ -e "$OUT/answer-$id.json" ] && continue
    ANSWER=""
    "$dispatch" "$ask" "$id"
    [ -n "$ANSWER" ] || ANSWER="$empty"
    rm -f "$ask"
    printf '%s\n' "$ANSWER" >"$OUT/answer-$id.part"
    mv "$OUT/answer-$id.part" "$OUT/answer-$id.json"
  done
}

# Answer the asks of the proof running as the background job PROOF_PID
# (`answer_asks`, with `$@`) until it ends, then wait for it: its exit
# status is left in PROOF_STATUS, and PROOF_PID is cleared, so a cleanup
# signals no process that is gone.
proof_await() {
  local errexit=0
  while kill -0 "$PROOF_PID" 2>/dev/null; do
    answer_asks "$@"
    sleep 0.2
  done
  case $- in *e*) errexit=1 ;; esac
  set +e
  wait "$PROOF_PID"
  PROOF_STATUS=$?
  [ "$errexit" = 0 ] || set -e
  PROOF_PID=""
}

# ---------------------------------------------------------------------------
# The browsers
# ---------------------------------------------------------------------------

# Playwright's library, installed from tests/browser/package-lock.json with
# its scripts off once for each lockfile and image, into the checkout's
# ignored build output, and the directory it is in printed. Two runs that
# start at once install it once: the install holds a lock, goes to a
# directory of its own and is renamed into place complete, and a run uses
# only a directory that is complete. Sourced without release.sh (the
# markdown proof), so it reports on stderr itself.
browser_node_modules() {
  local base="$ROOT/_build/browser-node-modules" key dir
  key="$(printf '%s\0%s' "$(sha256sum <"$BROWSER_HOME/package-lock.json")" "$PLAYWRIGHT_IMAGE" | sha256sum | cut -c1-64)"
  dir="$base/$key"
  if [ ! -f "$dir/complete" ] && ! {
    mkdir -p "$base" &&
      (
        flock 9 || exit 1
        [ -f "$dir/complete" ] && exit 0
        rm -rf "$dir"
        staging="$(mktemp -d "$base/$key.install.XXXXXX")" || exit 1
        trap 'rm -rf "$staging"' EXIT
        cp "$BROWSER_HOME/package.json" "$BROWSER_HOME/package-lock.json" "$staging/" || exit 1
        printf '\n=== %s\n' "installing Playwright's library from tests/browser/package-lock.json (${key:0:12}), once for this lockfile" >&2
        docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_update_notifier=false \
          -v "$staging:/install" -w /install "$PLAYWRIGHT_IMAGE" \
          npm ci --ignore-scripts --no-audit --no-fund --loglevel=error >&2 || exit 1
        [ -d "$staging/node_modules/playwright-core" ] || exit 1
        : >"$staging/complete"
        mv -T "$staging" "$dir"
      ) 9>"$base/$key.lock"
  }; then
    echo "::error::Playwright's library was not installed from tests/browser/package-lock.json into $dir" >&2
    return 1
  fi
  printf '%s' "$dir"
}

# Run the experiment `$2` of the directory tests/`$1` in the Playwright
# image, with `$3...` as its arguments; OUT is mounted at /out, and the
# console's assets (apps/cyfr/assets) read-only at /assets. The
# experiment's directory is copied beside tests/browser, so it imports the
# harness's library as ../browser/lib.mjs, and Playwright through it from
# /node_modules, where Playwright's library is mounted read-only
# (`browser_node_modules`), so no run changes it. Once the run has an
# authority, it is mounted at /authority and every browser of the
# container trusts it; WebKit then trusts it alone.
#
# The container shares no IPC namespace with the host. Chromium and
# Firefox keep their shared memory in /dev/shm, whose 64 MB Docker default
# is too small for them, so the container has 1 GB of its own.
playwright_run() {
  local name="$1" script="$2" modules
  shift 2
  mkdir -p "$OUT"
  modules="$(browser_node_modules)" || return 1
  local -a trust=()
  if [ -n "$BROWSER_AUTHORITY" ]; then
    trust=(
      -v "$BROWSER_AUTHORITY:/authority:ro"
      -v "$BROWSER_AUTHORITY/chromium-policy.json:/etc/opt/chrome_for_testing/policies/managed/cyfr-harness.json:ro"
      -v "$BROWSER_AUTHORITY/authority.pem:/etc/ssl/certs/ca-certificates.crt:ro"
      -e PLAYWRIGHT_FIREFOX_POLICIES_JSON=/authority/firefox-policies.json
    )
  fi
  # Named after the run under PROOF_RUN_PREFIX, so one a killed proof
  # leaves is found by that name.
  local -a named=()
  [ -z "${PROOF_RUN_PREFIX:-}" ] ||
    named=(--name "${PROOF_RUN_PREFIX}cyfr-playwright-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')")
  docker run --rm ${named[@]+"${named[@]}"} --network host --shm-size=1g \
    -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$ROOT/tests:/tests:ro" -v "$ROOT/apps/cyfr/assets:/assets:ro" -v "$OUT:/out" \
    -v "$modules/node_modules:/node_modules:ro" \
    ${trust[@]+"${trust[@]}"} \
    "$PLAYWRIGHT_IMAGE" \
    sh -c 'set -e
           mkdir -p /tmp/tests
           cp -R /tests/browser /tmp/tests/browser
           rm -rf /tmp/tests/browser/node_modules
           [ "$0" = browser ] || cp -R "/tests/$0" "/tmp/tests/$0"
           cd "/tmp/tests/$0"
           exec node "$@"' \
    "$name" "$script" "$@"
}

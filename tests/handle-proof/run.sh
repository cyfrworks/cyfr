#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The handle proof (README.md): a handle at the registry carries a sign-in
# from one CYFR to another, end to end. `cyfr` releases started as the
# browser harness starts homes (tests/browser/harness.sh), each a SQLite
# cell on a `.test` name behind the harness's HTTPS front: the directory
# dir.test, the person's CYFR a.test and the CYFR b.test they sign in at,
# both set up through /setup. The registry is cyfr.run's, built from the
# checkout CYFR_RUN_DIR names (its `git archive HEAD`, as its Dockerfile
# builds it), on a PostgreSQL of the run's own, behind a front of the
# identity proof's kind (tests/identity-proof/front.sh and cells.sh) at
# registry.test, as the directory is at dir.test. proof.mjs drives the
# browsers; this script answers its asks for the servers' part
# (`ask-N.json`, answered `answer-N.json`).
#
# Usage: CYFR_RUN_DIR=<cyfr.run checkout> tests/handle-proof/run.sh
# Without CYFR_RUN_DIR it says so and exits 0: CI cannot read cyfr.run's
# source, so the proof runs where both checkouts are. Writes
# handle-proof.json and handle-proof.md into PROOF_OUT (default: the
# scratch directory, kept with RELEASE_BOOT_KEEP=1) and prints the table.
# RELEASE_BOOT_SKIP_BUILD=1 reuses a release a previous run built.
#
# Everything it starts is removed when it ends, whether it succeeds or
# fails: the cells' servers, the fronts, the registry's and its
# database's containers and image, the Playwright container, and the
# scratch directory with the run's authority key, every token and cookie.
set -euo pipefail

if [ -z "${CYFR_RUN_DIR:-}" ]; then
  echo "handle proof: not run: CYFR_RUN_DIR names no cyfr.run checkout, and the registry is built from one"
  exit 0
fi
if [ ! -f "$CYFR_RUN_DIR/cmd/smokeid/main.go" ] || ! git -C "$CYFR_RUN_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "::error::CYFR_RUN_DIR ($CYFR_RUN_DIR) is no cyfr.run checkout with cmd/smokeid" >&2
  exit 1
fi

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${PROOF_RUN_PREFIX:-}cyfr-handle-proof-XXXXXX")"
# shellcheck source=../release-boot/release.sh
source "$(cd "$(dirname "$0")" && pwd)/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
# shellcheck source=../identity-proof/front.sh
source "$ROOT/tests/identity-proof/front.sh"
# shellcheck source=../identity-proof/cells.sh
source "$ROOT/tests/identity-proof/cells.sh"
OUT="${PROOF_OUT:-$WORK/out}"
PROOF_PID=""
SECRETS="$WORK/secrets"
mkdir -p -m 700 "$SECRETS"
RUN="${PROOF_RUN_PREFIX:-}cyfr-handle-proof-$$"
PG="$RUN-pg"
PG_VOLUME="$RUN-pgdata"
REGISTRY="$RUN-registry"
REGISTRY_IMAGE="$RUN-registry:$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
REGISTRY_HOST=registry.test
DIRECTORY_FRONT=127.77.0.1
REGISTRY_FRONT=127.77.0.3
SMOKEID="$WORK/bin/smokeid"

cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  identity_front_stop
  docker rm -f -v "$REGISTRY" "$PG" >/dev/null 2>&1 || true
  docker volume rm "$PG_VOLUME" >/dev/null 2>&1 || true
  docker image rm -f "$REGISTRY_IMAGE" >/dev/null 2>&1 || true
  jobs -p | xargs -r kill 2>/dev/null || true
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  rm -f "$OUT"/ask-* "$OUT"/answer-* 2>/dev/null || true
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT
# A signal ends the run through its exit, so the cleanup runs on it too.
trap 'exit 130' INT
trap 'exit 143' TERM

free_port() {
  python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# A JSON string of `$1`.
jstr() { python3 -I -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"; }

# This proof's fixture (fixture.exs) inside cell `$1`'s running server.
handle_fixture() {
  local cell="$1"
  shift
  cell_fixture "$cell" "$ROOT/tests/handle-proof/fixture.exs" FIXTURE "$@"
}

# psql in the registry's database, the SQL on stdin, `$@` its -v
# variables; one value a line, unaligned.
registry_sql() {
  local vars=() pair
  for pair in "$@"; do vars+=(-v "$pair"); done
  docker exec -i "$PG" psql -X -q -At -v ON_ERROR_STOP=1 -U cyfrrun -d cyfrrun "${vars[@]}"
}

# A request to the registry at https://registry.test through its front,
# trusting the run's authority: `$1` the method, `$2` the path, `$3...`
# curl's further arguments. Prints `{status, body}`.
registry_http() {
  local method="$1" path="$2" body status
  shift 2
  body="$(mktemp "$WORK/body.XXXXXX")"
  status="$(curl -sS -m 30 -o "$body" -w '%{http_code}' -X "$method" \
    --resolve "$REGISTRY_HOST:443:$REGISTRY_FRONT" --cacert "$BROWSER_AUTHORITY/authority.pem" \
    "$@" "https://$REGISTRY_HOST$path")" || status=0
  python3 -I -c 'import json, sys; print(json.dumps({"status": int(sys.argv[1]), "body": open(sys.argv[2]).read()}))' "$status" "$body"
  rm -f "$body"
}

# The same to the directory at https://dir.test.
directory_http() {
  local method="$1" path="$2" body status
  shift 2
  body="$(mktemp "$WORK/body.XXXXXX")"
  status="$(curl -sS -m 30 -o "$body" -w '%{http_code}' -X "$method" \
    --resolve "dir.test:443:$DIRECTORY_FRONT" --cacert "$BROWSER_AUTHORITY/authority.pem" \
    "$@" "https://dir.test$path")" || status=0
  python3 -I -c 'import json, sys; print(json.dumps({"status": int(sys.argv[1]), "body": open(sys.argv[2]).read()}))' "$status" "$body"
  rm -f "$body"
}

release_build

step "the registry's image from $CYFR_RUN_DIR ($(git -C "$CYFR_RUN_DIR" rev-parse --short HEAD)), and its smoke's person"
mkdir -p "$WORK/registry-src" "$WORK/bin"
git -C "$CYFR_RUN_DIR" archive HEAD | tar -x -C "$WORK/registry-src"
docker build -q -t "$REGISTRY_IMAGE" "$WORK/registry-src" >"$WORK/registry-build.log" 2>&1 || {
  tail -n 40 "$WORK/registry-build.log" >&2
  fail "the registry's image did not build"
}
(cd "$WORK/registry-src" && CGO_ENABLED=0 go build -mod=readonly -o "$SMOKEID" ./cmd/smokeid) || fail "cmd/smokeid did not build"

step "the run's authority and the homes"
browser_authority
DIR="$WORK/dir"
A="$WORK/a"
B="$WORK/b"
browser_home "$DIR" dir.test
browser_home "$A" a.test
browser_home "$B" b.test
browser_certificate "$REGISTRY_HOST"
openssl rand -hex 32 | tr -d '\n' >"$SECRETS/setup-a"
openssl rand -hex 32 | tr -d '\n' >"$SECRETS/setup-b"

identity_directory dir.test "$DIRECTORY_FRONT"
identity_directory "$REGISTRY_HOST" "$REGISTRY_FRONT"
identity_env "$DIR" CYFR_DIRECTORY_SERVE writer
identity_reaches_directory "$A" dir.test
identity_reaches_directory "$B" dir.test
for cell in "$A" "$B"; do identity_env "$cell" CYFR_REGISTRY_URL "$REGISTRY_HOST"; done
identity_env "$A" CYFR_SETUP_TOKEN "$(cat "$SECRETS/setup-a")"
identity_env "$B" CYFR_SETUP_TOKEN "$(cat "$SECRETS/setup-b")"

step "the registry's database, the registry, and its front at $REGISTRY_HOST"
PG_PORT="$(free_port)"
openssl rand -hex 16 | tr -d '\n' >"$SECRETS/pg"
docker volume create "$PG_VOLUME" >/dev/null || fail "the registry's database volume was not made"
docker run -d --name "$PG" -p "127.0.0.1:$PG_PORT:5432" -v "$PG_VOLUME:/var/lib/postgresql/data" \
  -e POSTGRES_USER=cyfrrun -e POSTGRES_DB=cyfrrun -e "POSTGRES_PASSWORD=$(cat "$SECRETS/pg")" \
  postgres:16-alpine >/dev/null || fail "the registry's database did not start"
closes=$((SECONDS + 60))
until docker exec "$PG" pg_isready -U cyfrrun -d cyfrrun >/dev/null 2>&1; do
  [ "$SECONDS" -lt "$closes" ] || fail "the registry's database did not answer within 60 s"
  sleep 1
done
REGISTRY_PORT="$(free_port)"
openssl rand -hex 32 | tr -d '\n' >"$SECRETS/admin-token"
(
  umask 077
  printf '%s\n' \
    "PORT=$REGISTRY_PORT" \
    "DATABASE_URL=postgres://cyfrrun:$(cat "$SECRETS/pg")@127.0.0.1:$PG_PORT/cyfrrun?sslmode=disable" \
    "ZOT_INTERNAL_URL=http://127.0.0.1:9" \
    "DOMAIN=$REGISTRY_HOST" \
    "DIRECTORY_URL=https://dir.test" \
    "DIRECTORY_PRIVATE_TARGETS=$DIRECTORY_FRONT/32" \
    "DIRECTORY_CA_FILE=/authority/authority.pem" \
    "ADMIN_TOKEN=$(cat "$SECRETS/admin-token")" \
    "LOG_LEVEL=info" >"$SECRETS/registry.env"
)

server_start "$DIR"
identity_front_start "$DIR"
docker run -d --name "$REGISTRY" --network host --add-host "dir.test:$DIRECTORY_FRONT" \
  -v "$BROWSER_AUTHORITY:/authority:ro" --env-file "$SECRETS/registry.env" \
  "$REGISTRY_IMAGE" >/dev/null || fail "the registry did not start"
closes=$((SECONDS + 90))
until curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$REGISTRY_PORT/health" 2>/dev/null; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY" 2>/dev/null)" != true ] || [ "$SECONDS" -ge "$closes" ]; then
    docker logs "$REGISTRY" 2>&1 | tail -n 40 >&2
    fail "the registry did not become ready"
  fi
  sleep 1
done

# The registry's front: front.mjs, as front.sh starts a directory's, but
# forwarding to the registry's listener.
REGISTRY_FRONT_NAME="$RUN-front-registry"
front_token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
docker run -d --name "$REGISTRY_FRONT_NAME" --network host -u 0 \
  -v "$BROWSER_AUTHORITY:/authority:ro" -v "$ROOT/tests/identity-proof:/front:ro" \
  "$PLAYWRIGHT_IMAGE" \
  node /front/front.mjs "$REGISTRY_FRONT:443" 9443 "$REGISTRY_HOST" \
  "/authority/$REGISTRY_HOST.pem" "/authority/$REGISTRY_HOST.key" "$REGISTRY_PORT" "$front_token" >/dev/null ||
  fail "the registry's front did not start"
IDENTITY_FRONT_NAMES[$REGISTRY_HOST]="$REGISTRY_FRONT_NAME"
closes=$((SECONDS + 60))
until [ "$(field "$(curl -fsS -m 2 "http://$REGISTRY_FRONT:9443/health" 2>/dev/null || echo '{}')" token 2>/dev/null)" = "$front_token" ]; do
  [ "$SECONDS" -lt "$closes" ] || fail "the registry's front did not answer"
  sleep 1
done
answer="$(registry_http GET /health)"
[ "$(field "$answer" status)" = 200 ] || fail "the registry does not answer through its front: $answer"

step "starting the CYFRs a.test and b.test"
for cell in "$A" "$B"; do identity_start "$cell"; done
RUN_STARTED_MS="$(date +%s%3N)"

# The registry's operator account, made once through its one-shot
# bootstrap, and its signed-in session's cookies (`registry_admin`).
ADMIN_COOKIE=""
ADMIN_CSRF=""
registry_admin() {
  local window status headers="$WORK/admin-headers" password="$SECRETS/admin-password"
  [ -z "$ADMIN_COOKIE" ] || return 0
  export CYFR_SMOKE_ADMIN_TOTP_SECRET
  CYFR_SMOKE_ADMIN_TOTP_SECRET="$(openssl rand 20 | base32)"
  (umask 077 && openssl rand -hex 16 | tr -d '\n' >"$password")
  printf 'authorization: Bearer %s\n' "$(cat "$SECRETS/admin-token")" >"$SECRETS/admin-header"
  status="$(field "$(registry_http POST /admin/bootstrap -H "@$SECRETS/admin-header" \
    --data-urlencode "email=handle-proof@example.com" \
    --data-urlencode "password@$password" --data-urlencode "password_confirm@$password" \
    --data-urlencode "totp_secret=$CYFR_SMOKE_ADMIN_TOTP_SECRET" \
    --data-urlencode "totp_code=$("$SMOKEID" totp)")" status)"
  [ "$status" = 303 ] || fail "the registry's bootstrap answered $status"
  # A TOTP code is spent once: the sign-in waits for the next window.
  window=$(( $(date +%s) / 30 ))
  while [ $(( $(date +%s) / 30 )) = "$window" ]; do sleep 1; done
  status="$(curl -sS -m 30 -o /dev/null -D "$headers" -w '%{http_code}' -X POST \
    --resolve "$REGISTRY_HOST:443:$REGISTRY_FRONT" --cacert "$BROWSER_AUTHORITY/authority.pem" \
    --data-urlencode "email=handle-proof@example.com" --data-urlencode "password@$password" \
    --data-urlencode "totp_code=$("$SMOKEID" totp)" "https://$REGISTRY_HOST/admin/login")"
  [ "$status" = 303 ] || fail "the registry's admin sign-in answered $status"
  ADMIN_COOKIE="$(tr -d '\r' <"$headers" | sed -n 's/^[Ss]et-[Cc]ookie: __Host-cyfr_admin_session=\([^;]*\).*/\1/p' | tail -1)"
  curl -sS -m 30 -o /dev/null -D "$headers" \
    --resolve "$REGISTRY_HOST:443:$REGISTRY_FRONT" --cacert "$BROWSER_AUTHORITY/authority.pem" \
    -H "Cookie: __Host-cyfr_admin_session=$ADMIN_COOKIE" "https://$REGISTRY_HOST/admin/identities" >/dev/null
  ADMIN_CSRF="$(tr -d '\r' <"$headers" | sed -n 's/^[Ss]et-[Cc]ookie: cyfr_admin_csrf=\([^;]*\).*/\1/p' | tail -1)"
  [ -n "$ADMIN_COOKIE" ] && [ -n "$ADMIN_CSRF" ] || fail "the registry's admin sign-in set no session"
}

# The second identity: the smoke's person (cmd/smokeid), enrolled at
# dir.test, which accepts the registry's policy, claims the handle `$1`
# and publishes the address `$2` with it, each a request its live key
# signs. Answers its identifier and each answer.
other_identity() {
  local handle="$1" address="$2" state="$WORK/other.json" identifier steps="[]" request version
  identifier="$("$SMOKEID" -state "$state" new https://dir.test)"
  "$SMOKEID" -state "$state" genesis >"$WORK/other-genesis"
  add() { steps="$(python3 -I -c 'import json, sys; s = json.loads(sys.argv[1]); s.append({"op": sys.argv[2], **json.loads(sys.argv[3])}); print(json.dumps(s))' "$steps" "$1" "$2")"; }
  add genesis "$(directory_http POST /directory/v1/genesis -H 'content-type: application/json' --data-binary "@$WORK/other-genesis")"
  answer="$(registry_http GET /v1/legal/version)"
  add legal_version "$answer"
  version="$(field "$(field "$answer" body)" policy_version)"
  signed() {
    "$SMOKEID" -state "$state" sign "$REGISTRY_HOST" "$2" "$3" >"$WORK/other-request"
    add "$2" "$(registry_http POST "$1" -H 'content-type: application/json' --data-binary "@$WORK/other-request")"
  }
  signed /v1/legal/accept policy.accept "{\"policy_version\":$(jstr "$version")}"
  signed /v1/namespaces/personal/claim handle.claim "{\"handle\":$(jstr "$handle")}"
  signed /v1/handles/address address.set "{\"address\":$(jstr "$address")}"
  ANSWER="$(python3 -I -c 'import base64, json, sys; print(json.dumps({"identifier": sys.argv[1], "steps": json.loads(sys.argv[2]), "genesis": base64.b64encode(open(sys.argv[3], "rb").read()).decode()}))' "$identifier" "$steps" "$WORK/other-genesis")"
}

# Each step the proof asks for (harness.sh `answer_asks`).
answer_ask() {
  local ask="$1" op cell value file
  op="$(asked "$ask" op)"
  case "$op" in
    setup_token)
      ANSWER="$(python3 -I -c 'import json, sys; print(json.dumps({"token": open(sys.argv[1]).read().strip()}))' "$SECRETS/setup-$(asked "$ask" cell)")"
      ;;
    run_started)
      ANSWER="{\"at\":$RUN_STARTED_MS}"
      ;;
    rows)
      cell="$WORK/$(asked "$ask" cell)"
      if [ -z "$(asked "$ask" column)" ]; then
        ANSWER="$(handle_fixture "$cell" rows "$(asked "$ask" table)")" || ANSWER=""
      else
        ANSWER="$(handle_fixture "$cell" rows "$(asked "$ask" table)" "$(asked "$ask" column)" "$(asked "$ask" value)")" || ANSWER=""
      fi
      ;;
    set)
      cell="$WORK/$(asked "$ask" cell)"
      file="$(mktemp "$WORK/value.XXXXXX")"
      python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["value"]))' "$ask" >"$file"
      ANSWER="$(handle_fixture "$cell" set "$(asked "$ask" table)" "$(asked "$ask" id)" "$(asked "$ask" field)" "@$file")" || ANSWER=""
      rm -f "$file"
      ;;
    credential)
      ANSWER="$(handle_fixture "$A" credential "$(asked "$ask" user_id)" "$(asked "$ask" registry)" "$(asked "$ask" slug)")" || ANSWER=""
      ;;
    refusal)
      ANSWER="$(handle_fixture "$WORK/$(asked "$ask" cell)" refusal "$(asked "$ask" reason)")" || ANSWER=""
      ;;
    state)
      ANSWER="$(handle_fixture "$WORK/$(asked "$ask" cell)" state "$(asked "$ask" table)")" || ANSWER=""
      ;;
    opens)
      file="$(mktemp "$WORK/sealed.XXXXXX")"
      python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["sealed"]))' "$ask" >"$file"
      ANSWER="$(handle_fixture "$WORK/$(asked "$ask" cell)" opens "$(asked "$ask" user_id)" "$(asked "$ask" role)" "@$file")" || ANSWER=""
      rm -f "$file"
      ;;
    reseal)
      file="$(mktemp "$WORK/patch.XXXXXX")"
      python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["patch"]))' "$ask" >"$file"
      ANSWER="$(handle_fixture "$A" reseal "$(asked "$ask" user_id)" "$(asked "$ask" registry)" "$(asked "$ask" slug)" "@$file")" || ANSWER=""
      rm -f "$file"
      ;;
    session_digest)
      file="$SECRETS/cookie"
      (umask 077 && python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["cookie"])' "$ask" >"$file")
      ANSWER="$(handle_fixture "$WORK/$(asked "$ask" cell)" session_digest "@$file")" || ANSWER=""
      rm -f "$file"
      ;;
    setting)
      ANSWER="$(handle_fixture "$WORK/$(asked "$ask" cell)" setting "$(asked "$ask" key)")" || ANSWER=""
      ;;
    registry_rows)
      ANSWER="$(registry_sql "t=$(asked "$ask" table)" "c=$(asked "$ask" column)" "v=$(asked "$ask" value)" <<'SQL'
SELECT json_build_object('rows', coalesce(json_agg(row_to_json(x) ORDER BY to_jsonb(x)->>'expires_at', row_to_json(x)::text), '[]'::json))
  FROM (SELECT * FROM :"t" WHERE :'c' = '' OR to_jsonb(:"t")->>:'c' = :'v') x;
SQL
)" || ANSWER=""
      ;;
    registry_state)
      # The whole table, and every constraint on it as PostgreSQL prints
      # it, which a tamper's restore must leave as they were.
      ANSWER="$(registry_sql "t=$(asked "$ask" table)" <<'SQL'
SELECT json_build_object(
  'rows', (SELECT coalesce(json_agg(row_to_json(x) ORDER BY row_to_json(x)::text), '[]'::json) FROM :"t" x),
  'constraints', (SELECT coalesce(json_agg(json_build_array(conname, pg_get_constraintdef(oid)) ORDER BY conname), '[]'::json)
                    FROM pg_constraint WHERE conrelid = CAST(:'t' AS regclass)));
SQL
)" || ANSWER=""
      ;;
    admin_id)
      ANSWER="$(registry_sql <<'SQL'
SELECT json_build_object('id', id) FROM admin_accounts WHERE email = 'handle-proof@example.com';
SQL
)" || ANSWER=""
      ;;
    registry_set)
      value="$(python3 -I -c 'import json, sys; a = json.load(open(sys.argv[1])); print(json.dumps({a["field"]: a["value"]}))' "$ask")"
      # Behind the registry's back and with its checks off for the write:
      # foreign keys off for the transaction, and a tamper saves and drops
      # the table's CHECK constraints, which its restore adds back from
      # their saved definitions once the stored value is the original.
      if ANSWER="$(registry_sql "t=$(asked "$ask" table)" "k=$(asked "$ask" key)" "kv=$(asked "$ask" key_value)" \
        "f=$(asked "$ask" field)" "patch=$value" "phase=$(asked "$ask" phase)" <<'SQL' 2>"$WORK/psql.err" | tail -n 1
BEGIN;
SET LOCAL session_replication_role = replica;
SELECT set_config('handle_proof.t', :'t', true), set_config('handle_proof.phase', :'phase', true) \g /dev/null
CREATE TABLE IF NOT EXISTS handle_proof_checks (tbl text, name text, def text);
DO $$
DECLARE c record;
BEGIN
  IF current_setting('handle_proof.phase') = 'tamper' THEN
    FOR c IN SELECT conname, pg_get_constraintdef(oid) AS def FROM pg_constraint
              WHERE conrelid = current_setting('handle_proof.t')::regclass AND contype = 'c' LOOP
      INSERT INTO handle_proof_checks VALUES (current_setting('handle_proof.t'), c.conname, c.def);
      EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I', current_setting('handle_proof.t'), c.conname);
    END LOOP;
  END IF;
END $$;
WITH changed AS (
  UPDATE :"t" SET :"f" = (json_populate_record(CAST(NULL AS :"t"), :'patch'::json)).:"f"
   WHERE :"k"::text = :'kv' RETURNING 1)
SELECT count(*) AS changed FROM changed \gset
DO $$
DECLARE c record;
BEGIN
  IF current_setting('handle_proof.phase') = 'restore' THEN
    FOR c IN SELECT name, def FROM handle_proof_checks WHERE tbl = current_setting('handle_proof.t') LOOP
      EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I %s', current_setting('handle_proof.t'), c.name, c.def);
    END LOOP;
    DELETE FROM handle_proof_checks WHERE tbl = current_setting('handle_proof.t');
  END IF;
END $$;
COMMIT;
SELECT json_build_object('set', :changed, 'role', current_setting('session_replication_role'));
SQL
)" && [ -n "$ANSWER" ]; then :; else
        ANSWER="$(python3 -I -c 'import json, sys; print(json.dumps({"error": "the registry refused the write: " + open(sys.argv[1]).read().strip()}))' "$WORK/psql.err")"
      fi
      ;;
    user_agents)
      # The registry records each signer's HTTP client: a CYFR's is Req's
      # default, named for the version mix.lock pins; the second
      # identity's is this run's curl.
      ANSWER="$(python3 -I -c 'import json, re, sys; v = re.search(r"\"req\": \{:hex, :req, \"([^\"]+)\"", open(sys.argv[1]).read()).group(1); print(json.dumps({"cyfr": "req/" + v, "curl": "curl/" + sys.argv[2]}))' "$ROOT/mix.lock" "$(curl -V | head -1 | cut -d' ' -f2)")" || ANSWER=""
      ;;
    legal_version)
      ANSWER="$(python3 -I -c 'import json, sys; a = json.loads(sys.argv[1]); print(json.dumps({"status": a["status"], "policy_version": json.loads(a["body"]).get("policy_version")}))' "$(registry_http GET /v1/legal/version)")" || ANSWER=""
      ;;
    handle_answer)
      ANSWER="$(registry_http GET "/v1/handles/$(asked "$ask" handle)")"
      ;;
    other_identity)
      other_identity "$(asked "$ask" handle)" "$(asked "$ask" address)"
      ;;
    ban)
      registry_admin
      ANSWER="$(registry_http POST /admin/identities/ban \
        -H "Cookie: __Host-cyfr_admin_session=$ADMIN_COOKIE; cyfr_admin_csrf=$ADMIN_CSRF" \
        --data-urlencode "x-csrf-token=$ADMIN_CSRF" --data-urlencode "identity=$(asked "$ask" handle)" \
        --data-urlencode "category=spam" --data-urlencode "reason=handle proof")"
      ;;
    token_use)
      file="$SECRETS/push-token"
      handle_fixture "$A" token_to "$(asked "$ask" user_id)" "$(asked "$ask" registry)" "$(asked "$ask" slug)" "$file" >/dev/null
      [ -s "$file" ] || fail "A's push token was not read"
      printf 'authorization: Bearer %s\n' "$(cat "$file")" >"$file.header"
      ANSWER="$(registry_http GET "/v1/namespaces/$(asked "$ask" slug)/tokens" -H "@$file.header")"
      rm -f "$file" "$file.header"
      ;;
    clock)
      ANSWER="{\"at\":$(date +%s%3N)}"
      ;;
    *) fail "the proof asked for '$op', which this script does not do" ;;
  esac
}

step "the handle proof in Chromium, in $PLAYWRIGHT_IMAGE"
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-*
playwright_run handle-proof proof.mjs /authority/homes.json /out &
PROOF_PID=$!
proof_await answer_ask

echo "the record: $OUT/handle-proof.json and $OUT/handle-proof.md"
exit "$PROOF_STATUS"

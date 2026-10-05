#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The file-offer proof (README.md): a `cyfr` release started as the browser
# harness starts a home (tests/browser/harness.sh), home.test behind the
# harness's HTTPS front, three people signed in, two of them seated
# together in one group and the third in no athanor but their own. In
# Chromium (proof.mjs), each person in a browser context of their own, the
# sender offers files from the Files page, the recipient answers them in
# its Inbox, the sender edits an offered original and withdraws an offer,
# and the outsider is offered nothing; the release's own storage copies
# the bytes, and each snapshot and the recipient's accepted copy are read
# back.
#
# The proof asks the server for its part through the output directory
# (`ask-N.json`), and this script answers each (`answer-N.json`) through
# the proof's fixture (tests/file-offer-proof/fixture.exs): writing the
# sender's files, and reading the rows, the storage counts, and the
# digests of the snapshots and the accepted copy the steps left.
#
# The harness runs no execution engine and no model, and nothing here
# needs one: an offer and an acceptance copy bytes in the release itself.
#
# Usage: tests/file-offer-proof/run.sh
# VAULT_PROOF_VIEWPORT is `desktop` (1280×900, the default) or `720x720`,
# the viewport every person's browser context has. Writes
# file-offer-proof.json and file-offer-proof.md into PROOF_OUT (default:
# the scratch directory, kept with RELEASE_BOOT_KEEP=1). The release is
# the one a previous build left (RELEASE_BOOT_SKIP_BUILD=1, which this
# proof requires): build it as release.sh's `release_build` does, without
# fetching dependencies.
set -euo pipefail

VIEWPORT="${VAULT_PROOF_VIEWPORT:-desktop}"
case "$VIEWPORT" in
  desktop | 720x720) ;;
  *)
    echo "::error::VAULT_PROOF_VIEWPORT is desktop or 720x720, not '$VIEWPORT'" >&2
    exit 64
    ;;
esac

ADAPTER=sqlite
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cyfr-file-offer-proof-XXXXXX")"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../release-boot/release.sh
source "$HERE/../release-boot/release.sh"
# shellcheck source=../browser/harness.sh
source "$ROOT/tests/browser/harness.sh"
OUT="${PROOF_OUT:-$WORK/out}"
PROOF_PID=""

stop_proof_container() {
  local ids
  ids="$(docker ps -q --filter "volume=$OUT" 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker stop -t 5 $ids >/dev/null 2>&1 || true
  fi
}

# The scratch directory holds the run's keys, the cell's deployment file
# and its database, so it goes even when a stop fails. `server_stop` ends
# in `fail`, an `exit`, when a listener outlives its stop, and an exit
# inside this trap would end it before the removal, so the stop runs in a
# subshell, whose exit ends only that subshell; the stop's failure still
# fails the run.
cleanup() {
  local code=$?
  [ -n "$PROOF_PID" ] && kill "$PROOF_PID" 2>/dev/null || true
  stop_proof_container
  ( server_stop ) || [ "$code" -ne 0 ] || code=1
  if [ "${RELEASE_BOOT_KEEP:-}" = 1 ]; then
    echo "kept $WORK"
  else
    rm -rf "$WORK"
  fi
  exit "$code"
}
trap cleanup EXIT

field() { printf '%s' "$1" | python3 -c "import json, sys; print(json.load(sys.stdin)['$2'])"; }

# The proof's fixture inside the running server, as `bin/cyfr rpc`.
offer_fixture() {
  local args="" arg
  for arg in "$@"; do
    args="$args\"$(printf '%s' "$arg" | sed 's/[\\"]/\\&/g')\","
  done
  cell_cyfr "$CELL" rpc \
    "{answer, _} = Code.eval_file(\"$HERE/fixture.exs\"); IO.puts(answer.([${args%,}]))" \
    | sed -n 's/^OFFER=//p' | tail -1
}

[ "${RELEASE_BOOT_SKIP_BUILD:-}" = 1 ] ||
  fail "build the release first and run with RELEASE_BOOT_SKIP_BUILD=1 (README.md)"
release_build
mkdir -p "$OUT"
rm -f "$OUT"/ask-* "$OUT"/answer-* "$OUT"/setup.json "$OUT"/file-offer-proof.*

# The cases the README names as shown elsewhere, each found in the tree
# as a test of that name in that file before it is listed in the record.
step "the cases shown elsewhere, found in the tree"
python3 - "$HERE/README.md" "$ROOT" "$OUT/shown-elsewhere.json" <<'PY' ||
import json, re, sys

readme, root, out = sys.argv[1:]
text = open(readme, encoding="utf-8").read()
section = text.split("\n## Shown elsewhere\n", 1)
if len(section) != 2:
    sys.exit("README.md has no 'Shown elsewhere' section")
rows = []
for line in section[1].split("\n## ", 1)[0].splitlines():
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) != 4 or cells[0] in ("Claim", "") or set(cells[0]) <= set("-"):
        continue
    claim, path, name, owner = cells
    path, name = path.strip("`"), name.strip("`")
    try:
        source = open(f"{root}/{path}", encoding="utf-8").read().splitlines()
    except OSError:
        sys.exit(f"{path} is not in the tree")
    found = [n for n, code in enumerate(source, 1) if re.search(r'\btest\s+"' + re.escape(name) + '"', code)]
    if len(found) != 1:
        sys.exit(f"{path} holds {len(found)} tests named {name!r}, not one")
    rows.append({"claim": claim, "file": path, "test": name, "line": found[0], "owner": owner})
if len(rows) != 3:
    sys.exit(f"the Shown elsewhere table lists {len(rows)} cases, not three")
json.dump(rows, open(out, "w"), indent=2)
print("\n".join(f"  {r['file']}:{r['line']} {r['test']}" for r in rows))
PY
  fail "a case the README names as shown elsewhere is not in the tree"

step "the run's authority and the home home.test"
browser_authority
CELL="$WORK/home"
browser_home "$CELL" home.test

step "starting home.test on a fresh SQLite cell"
server_start "$CELL"

step "three people signed in, the sender an operator, who lets the other two in at the door"
sender="$(offer_fixture person operator@example.com file-offer-sender "Sam Sender")"
[ -n "$sender" ] || fail "the fixture signed the sender in nowhere"
sender_token="$(field "$sender" token)"
for email in recipient@example.com outsider@example.com; do
  admitted="$(offer_fixture admit "$sender_token" "$email")"
  printf '%s' "$admitted" | grep -q "\"allowed\":\"$email\"" || fail "$email was not let in: $admitted"
done
recipient="$(offer_fixture person recipient@example.com file-offer-recipient "Rae Recipient")"
outsider="$(offer_fixture person outsider@example.com file-offer-outsider "Oli Outsider")"
[ -n "$recipient" ] && [ -n "$outsider" ] || fail "the fixture signed the recipient or the outsider in nowhere"
sender_id="$(field "$sender" user_id)"
recipient_id="$(field "$recipient" user_id)"
outsider_id="$(field "$outsider" user_id)"

step "the sender's group, with the recipient seated in it"
group="$(offer_fixture group "$sender_token" "$recipient_id" "File offer proof")"
printf '%s' "$group" | grep -q '"added":"added"' || fail "the group was not made with the recipient in it: $group"

step "each person's session as their browser's cookie, and each one's own athanor filled"
declare -A cookie
for role in sender recipient outsider; do
  cookie[$role]="$(browser_cookie "$CELL" "$(field "${!role}" token)")"
done
# The counts are read from each whole tree, which a fill still running, or
# one retried after a failure, would write into while the proof counts.
settled="$(offer_fixture settle "$sender_id" "$recipient_id" "$outsider_id")"
python3 -c "import json, sys; sys.exit(set(json.loads(sys.argv[1])['states'].values()) != {'ready'})" "$settled" ||
  fail "an athanor is not filled: $settled"

# What the proof is told of the run: the people without their session
# tokens, the group, the viewport and the cases shown elsewhere.
python3 - "$OUT/setup.json" "$VIEWPORT" "$sender" "$recipient" "$outsider" "$group" "$settled" \
  "$OUT/shown-elsewhere.json" <<'PY'
import json, sys

out, viewport, sender, recipient, outsider, group, settled, shown = sys.argv[1:]
people = {}
for role, raw in (("sender", sender), ("recipient", recipient), ("outsider", outsider)):
    person = json.loads(raw)
    person.pop("token")
    people[role] = person
setup = {
    "viewport": viewport,
    "people": people,
    "group": json.loads(group),
    "settled": json.loads(settled)["states"],
    "shown_elsewhere": json.load(open(shown)),
}
json.dump(setup, open(out, "w"), indent=2)
PY

# Each step the proof asks for, answered once.
answer_asks() {
  local ask id op answer path content
  for ask in "$OUT"/ask-*.json; do
    [ -e "$ask" ] || continue
    id="${ask##*/ask-}"
    id="${id%.json}"
    [ -e "$OUT/answer-$id.json" ] && continue
    op="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['op'])" "$ask")"
    case "$op" in
      file)
        path="$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['path'])" "$ask")"
        content="$(python3 -c "import base64, json, sys; print(base64.b64encode(json.load(open(sys.argv[1]))['content'].encode()).decode())" "$ask")"
        answer="$(offer_fixture file "$sender_token" "$path" "$content")"
        ;;
      facts) answer="$(offer_fixture facts "$sender_id" "$recipient_id" "$outsider_id")" ;;
      *) fail "the proof asked for '$op', which this script does not do" ;;
    esac
    [ -n "$answer" ] || answer='{"error":"the fixture answered nothing"}'
    printf '%s\n' "$answer" >"$OUT/answer-$id.part"
    mv "$OUT/answer-$id.part" "$OUT/answer-$id.json"
  done
}

step "the file-offer proof in Chromium at the $VIEWPORT viewport, in $PLAYWRIGHT_IMAGE"
playwright_run file-offer-proof proof.mjs /authority/homes.json /out \
  "${cookie[sender]}" "${cookie[recipient]}" "${cookie[outsider]}" &
PROOF_PID=$!
while kill -0 "$PROOF_PID" 2>/dev/null; do
  answer_asks
  sleep 0.2
done
set +e
wait "$PROOF_PID"
status=$?
set -e
PROOF_PID=""

echo "the record: $OUT/file-offer-proof.json and $OUT/file-offer-proof.md"
exit "$status"

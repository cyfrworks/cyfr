#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The Mac distribution's signing, rehearsed with no Apple input: a
# self-made Developer ID-named identity, trusted for code signing on this
# machine, and a profile of its own making, signed by it. Each check prints
# one PASS or FAIL line, and one FAIL fails the run:
#
#   input      a rehearsal missing an input refuses, naming it
#   mixed      a rehearsal with an Apple input in its environment refuses
#   profile    a profile for another app refuses
#   group      a profile that does not authorise the WebAuthn group refuses
#   built      the rehearsed build finishes, its DMG passing the recipe's
#              own check: every signature the identity's, hardened and
#              timestamped, with its kind's entitlements, the profile
#              embedded and the bundled cyfr the one it signed after
#              checking it as the verified one
#   helper     the app with another program as its cyfr, signed again
#              with the same identity, is refused
#   release    the rehearsed DMG is refused by a release's check, which
#              asks for Apple's stapled notarisation and Gatekeeper's
#              acceptance, and passes the rehearsal's
#
# What it cannot show, needing Apple: that the real .p12 imports and its
# password opens it; that the real profile authorises the group when the
# app launches; Apple's notarisation and its ticket; Gatekeeper's first
# launch of a downloaded copy; Touch ID.
#
# Usage: bash tests/desktop-proof/native/mac-rehearsal.sh CYFR ARCH
# CYFR is the cyfr the package carries, ARCH amd64 or arm64. It runs on a
# disposable macOS runner of GitHub's alone (GITHUB_ACTIONS=true and
# RUNNER_ENVIRONMENT=github-hosted, which GitHub sets on its own runners
# and on no person's Mac) and refuses anywhere else first: it trusts its
# identity in the System keychain with sudo and leaves that trust to the
# runner's end, as taking it away asks for a person's authorisation, which
# nobody gives there. Each command that could wait on a person has a bound
# of its own and fails with a sentence; each says when it starts.
# apps/codex/desktop's packages must be installed.
set -uo pipefail

# It trusts a certificate of its own making for code signing and leaves
# that trust behind, so it runs where the machine is thrown away after the
# job: on GitHub's own runners, and of those on macOS.
if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
  echo "rehearsal: refused: it trusts a certificate of its own making and leaves the trust behind, so it runs on a GitHub-hosted runner alone" >&2
  exit 64
fi
[ "$(uname -s)" = Darwin ] || { echo "rehearsal: refused: it rehearses the Mac package, on macOS alone" >&2; exit 64; }
CYFR=${1:-}
ARCH=${2:-}
[ -x "$CYFR" ] && [ -n "$ARCH" ] || { echo "usage: bash $0 CYFR ARCH" >&2; exit 64; }
CYFR=$(cd "$(dirname "$CYFR")" && pwd)/$(basename "$CYFR")
DESKTOP=$(cd "$(dirname "$0")/../../../apps/codex/desktop" && pwd)

RUN=$(mktemp -d "${TMPDIR:-/tmp}/cyfr-mac-rehearsal.XXXXXX") || exit 1
TEAM=RHRSL00001
NAME="Developer ID Application: CYFR Rehearsal ($TEAM)"
PASSWORD=$(openssl rand -hex 16)
KEYCHAIN="$RUN/tamper.keychain"

# bounded SECONDS WHAT COMMAND...: COMMAND, said when it starts, ended
# with a sentence when it has not finished in SECONDS (exit 142).
bounded() {
  local seconds=$1 what=$2 status
  shift 2
  echo "$(date -u +%H:%M:%SZ) $what" >&2
  perl -e 'alarm shift @ARGV; exec @ARGV or die "cannot run $ARGV[0]\n"' "$seconds" "$@"
  status=$?
  [ "$status" != 142 ] || echo "rehearsal: $what did not finish in $seconds seconds" >&2
  return "$status"
}

SEARCH=() # the account's keychain search list before the rehearsal's joined it
cleanup() {
  [ "${#SEARCH[@]}" = 0 ] || bounded 60 "restoring the keychain search list" security list-keychains -d user -s "${SEARCH[@]}"
  [ ! -e "$KEYCHAIN" ] || bounded 60 "deleting the keychain" security delete-keychain "$KEYCHAIN"
  rm -rf "$RUN"
}
trap cleanup EXIT

FAILED=0
pass() { echo "$(date -u +%H:%M:%SZ) PASS $1${2:+: $2}"; }
fail() { FAILED=$((FAILED + 1)); echo "$(date -u +%H:%M:%SZ) FAIL $1: $2"; }

# The identity: a code-signing certificate of its own, named as a
# Developer ID is, trusted on this machine for code signing.
cat >"$RUN/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
OU = $TEAM
O = CYFR Rehearsal
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$RUN/cert.cnf" -keyout "$RUN/key.pem" -out "$RUN/cert.pem" 2>/dev/null &&
  /usr/bin/openssl x509 -in "$RUN/cert.pem" -outform der -out "$RUN/cert.der" &&
  /usr/bin/openssl pkcs12 -export -inkey "$RUN/key.pem" -in "$RUN/cert.pem" -out "$RUN/id.p12" -passout "pass:$PASSWORD" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 || { echo "rehearsal: the identity was not made" >&2; exit 1; }
bounded 60 "trusting the identity" sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$RUN/cert.pem" ||
  { echo "rehearsal: the identity is not trusted" >&2; exit 1; }

# A profile signed by the identity: KIND is good, app (another app's) or
# group (one that does not authorise the WebAuthn group).
profile() {
  node --input-type=module - "$1" "$RUN/cert.der" "$TEAM" "$RUN/$1.plist" "$DESKTOP" <<'EOF' &&
import {readFileSync, writeFileSync} from "node:fs"
import {createRequire} from "node:module"
import path from "node:path"
const [kind, der, team, out, desktop] = process.argv.slice(2)
const plist = createRequire(path.join(desktop, "node_modules", "app-builder-lib", "package.json"))("plist")
const now = Date.now()
writeFileSync(out, plist.build({
  AppIDName: "CYFR", ApplicationIdentifierPrefix: [team], CreationDate: new Date(now), Platform: ["OSX"],
  DeveloperCertificates: [readFileSync(der)], ExpirationDate: new Date(now + 86400000), Name: `CYFR rehearsal (${kind})`,
  ProvisionsAllDevices: true, TeamIdentifier: [team], TeamName: "CYFR Rehearsal", TimeToLive: 1,
  UUID: "00000000-0000-4000-8000-000000000000", Version: 1,
  Entitlements: {
    "com.apple.application-identifier": `${team}.${kind === "app" ? "run.cyfr.other" : "run.cyfr.desktop"}`,
    "com.apple.developer.team-identifier": team,
    "keychain-access-groups": [kind === "group" ? `${team}.run.cyfr.desktop.other` : `${team}.*`]
  }
}))
EOF
  /usr/bin/openssl smime -sign -binary -nodetach -outform der -signer "$RUN/cert.pem" -inkey "$RUN/key.pem" \
    -in "$RUN/$1.plist" -out "$RUN/$1.provisionprofile" && base64 -i "$RUN/$1.provisionprofile"
}
GOOD=$(profile good) && OTHER_APP=$(profile app) && OTHER_GROUP=$(profile group) || { echo "rehearsal: the profiles were not made" >&2; exit 1; }

# Every rehearsal input, as the build reads them; none of Apple's.
for name in APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_PROVISIONING_PROFILE \
  APPLE_API_KEY APPLE_API_KEY_ID APPLE_API_ISSUER; do
  unset "$name"
done
export CYFR_REHEARSAL_CERTIFICATE CYFR_REHEARSAL_CERTIFICATE_PASSWORD="$PASSWORD" CYFR_REHEARSAL_SIGNING_IDENTITY="$NAME" \
  CYFR_REHEARSAL_TEAM_ID="$TEAM" CYFR_REHEARSAL_PROVISIONING_PROFILE="$GOOD"
CYFR_REHEARSAL_CERTIFICATE=$(base64 -i "$RUN/id.p12")

# The rehearsed build, bounded by SECONDS.
build() {
  (cd "$DESKTOP" && bounded "$1" "the rehearsed build" node scripts/build.mjs --cyfr "$CYFR" --version 0.0.0-rehearsal --arch "$ARCH" \
    --out "$RUN/dist" --distribution --rehearse)
}

# A refusal: the build, with CHANGE to its environment (NAME=VALUE, or
# -NAME for NAME unset), exits 1 before it packs, saying WHY.
refused() {
  local check=$1 why=$2 change=$3 out status
  out=$(if [ "${change#-}" != "$change" ]; then unset "${change#-}"; else export "${change?}"; fi; build 300 2>&1)
  status=$?
  if [ "$status" = 1 ] && grep -qF "refused: $why" <<<"$out" && ! grep -q "packaging" <<<"$out"; then pass "$check" "$why"
  else fail "$check" "exit $status, not the refusal '$why': $(tail -3 <<<"$out")"; fi
}
refused input "CYFR_REHEARSAL_PROVISIONING_PROFILE is not set" -CYFR_REHEARSAL_PROVISIONING_PROFILE
refused mixed "a rehearsal takes no Apple input, and APPLE_API_KEY is set" APPLE_API_KEY=
refused profile "the provisioning profile is not for run.cyfr.desktop" CYFR_REHEARSAL_PROVISIONING_PROFILE="$OTHER_APP"
refused group "the provisioning profile does not authorise the app's WebAuthn group" CYFR_REHEARSAL_PROVISIONING_PROFILE="$OTHER_GROUP"

DMG="$RUN/dist/cyfr-desktop_0.0.0-rehearsal_darwin_$ARCH.dmg"
# The build's own lines as they come, for the record of where it is.
build 1800 2>&1 | tee "$RUN/build.log"
if [ "${PIPESTATUS[0]}" = 0 ] && [ -f "$DMG" ]; then
  pass built "$(tail -1 "$RUN/build.log")"
  HELPER=$(sed -n 's/^the bundled cyfr is signed as sha256 \([0-9a-f]\{64\}\)$/\1/p' "$RUN/build.log")
else
  fail built "$(grep '^refused\|did not finish' "$RUN/build.log" || tail -3 "$RUN/build.log")"
  exit 1
fi
# The record of what was signed, and with what.
BUILT=$(echo "$RUN/dist"/mac*/CYFR.app)
for file in "$BUILT" "$BUILT/Contents/Frameworks/CYFR Helper (Renderer).app" "$BUILT/Contents/Resources/cyfr"; do
  echo "-- ${file#"$BUILT/"}"
  bounded 60 "reading ${file##*/}'s signature" codesign -d --verbose=2 --entitlements - --xml "$file" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory)=?|plist' | sed 's/^/   /'
done

check() { (cd "$DESKTOP" && bounded 900 "checking ${1##*/}" node scripts/mac-sign.mjs check "$@" --cyfr-sha256 "$HELPER"); }

# The same app with another program as its cyfr, signed again inside out
# with the same identity, so its signature verifies and only the program
# differs.
# A keychain codesign may use with no prompt: unlocked, never locking
# again, its key open to Apple's tools, and on the account's search list,
# where alone codesign finds an identity (measured: with --keychain alone
# it finds none).
bounded 60 "making the keychain" security create-keychain -p "$PASSWORD" "$KEYCHAIN" &&
  bounded 60 "unlocking the keychain" security unlock-keychain -p "$PASSWORD" "$KEYCHAIN" &&
  bounded 60 "keeping the keychain unlocked" security set-keychain-settings "$KEYCHAIN" &&
  bounded 60 "importing the identity" security import "$RUN/id.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null &&
  bounded 60 "opening the key to codesign" security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null &&
  listed=$(bounded 60 "reading the keychain search list" security list-keychains -d user) ||
  { echo "rehearsal: no keychain" >&2; exit 1; }
while IFS= read -r line; do
  line=${line#"${line%%[![:space:]]*}"}
  line=${line#\"}
  [ -z "$line" ] || SEARCH+=("${line%\"}")
done <<<"$listed"
bounded 60 "putting the keychain on the search list" security list-keychains -d user -s "$KEYCHAIN" "${SEARCH[@]}" ||
  { echo "rehearsal: the keychain is not on the search list" >&2; exit 1; }
MOUNT="$RUN/mount"
mkdir "$MOUNT" && bounded 300 "mounting the DMG" hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null &&
  bounded 300 "copying the app" ditto "$MOUNT/CYFR.app" "$RUN/tampered/CYFR.app"
bounded 120 "unmounting the DMG" hdiutil detach "$MOUNT" >/dev/null
APP="$RUN/tampered/CYFR.app"
if ! { cp /usr/bin/true "$APP/Contents/Resources/cyfr" &&
  bounded 120 "signing the substitute" codesign --force --sign "$NAME" --keychain "$KEYCHAIN" --options runtime --timestamp \
    "$APP/Contents/Resources/cyfr" &&
  bounded 120 "signing the app again" codesign --force --sign "$NAME" --keychain "$KEYCHAIN" --options runtime --timestamp \
    --preserve-metadata=entitlements "$APP"; }; then
  fail helper "the substituted app was not signed again, so it shows nothing"
elif ! bounded 120 "verifying the substituted app" codesign --verify --deep --strict "$APP"; then
  fail helper "the substituted app's signature does not verify, so it shows nothing"
elif out=$(check "$APP" --rehearsed 2>&1); then fail helper "the substituted app passed: $out"
elif grep -qF "refused: CYFR.app/Contents/Resources/cyfr is not the cyfr the build signed" <<<"$out"; then pass helper "$out"
else fail helper "refused for another reason: $out"; fi

# A release's check asks for what only Apple gives.
if out=$(APPLE_TEAM_ID=$TEAM APPLE_PROVISIONING_PROFILE=$GOOD check "$DMG" 2>&1); then fail release "a release's check passed the rehearsed DMG: $out"
elif ! grep -qF "refused: the DMG has no stapled notarisation" <<<"$out"; then fail release "refused for another reason: $out"
elif ! rehearsed=$(check "$DMG" --rehearsed 2>&1); then fail release "the rehearsal's own check refuses it: $rehearsed"
else pass release "$out"; fi

[ "$FAILED" = 0 ] || { echo "rehearsal: $FAILED of 7 checks failed" >&2; exit 1; }
echo "rehearsal: 7 checks passed"

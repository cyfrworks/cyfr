#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
# Unit tests for scripts/install.sh verification behavior (fail-closed
# checksum, the release workflow's cosign signature required unless
# CYFR_ALLOW_UNVERIFIED=1, explicit skip escape hatch), and for what it
# does before and after: its generated policy block, its decisions on the
# shared vectors of tests/fixtures/install_prerequisites.json, its root
# helper, and whole runs against stubbed sudo, apt, dpkg and downloads.
#
# Usage: sh tests/install-verify-test.sh
# INSTALL_SH names another copy of the script to run the checks against.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
INSTALL_SH="${INSTALL_SH:-$REPO_ROOT/scripts/install.sh}"

failures=0

# Run a snippet in a subshell that sources install.sh in test mode.
# $1 = description, $2 = expected exit (0 or nonzero via "fail"), $3 = snippet,
# $4 = optional text the output must contain, which pins the refusal reached
run_case() {
    desc="$1"
    expect="$2"
    snippet="$3"
    message="${4:-}"

    output="$(
        sh -c "
            CYFR_INSTALL_TEST=1
            export CYFR_INSTALL_TEST
            . '$INSTALL_SH'
            $snippet
        " 2>&1
    )"
    code=$?

    if [ "$expect" = "ok" ] && [ "$code" -eq 0 ]; then
        reason=""
    elif [ "$expect" = "fail" ] && [ "$code" -ne 0 ]; then
        reason=""
    else
        reason="exit=$code, expected $expect"
    fi

    if [ -z "$reason" ] && [ -n "$message" ]; then
        case "$output" in
            *"$message"*) ;;
            *) reason="output lacks \"$message\"" ;;
        esac
    fi

    if [ -z "$reason" ]; then
        printf 'PASS: %s\n' "$desc"
    else
        printf 'FAIL: %s (%s)\n' "$desc" "$reason"
        printf '%s\n' "$output" | sed 's/^/    /'
        failures=$((failures + 1))
    fi
}

# Print the first executable named $1 on PATH. `command -v` would name a
# shell builtin such as printf instead of its file.
find_tool() {
    saved_ifs="$IFS"
    IFS=:
    for dir in $PATH; do
        if [ -n "$dir" ] && [ -f "$dir/$1" ] && [ -x "$dir/$1" ]; then
            IFS="$saved_ifs"
            printf '%s\n' "$dir/$1"
            return 0
        fi
    done
    IFS="$saved_ifs"
    return 1
}

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Build a valid fixture: archive + matching checksums.txt
printf 'binary-bytes-v1' > "$fixture/cyfr_test.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum "$fixture/cyfr_test.tar.gz" | awk '{print $1}')"
else
    sum="$(shasum -a 256 "$fixture/cyfr_test.tar.gz" | awk '{print $1}')"
fi
printf '%s  cyfr_test.tar.gz\n' "$sum" > "$fixture/checksums.txt"

run_case "valid checksum passes" ok \
    "verify_checksum '$fixture' 'cyfr_test.tar.gz'"

run_case "tampered archive fails closed" fail \
    "printf 'tampered' >> '$fixture/cyfr_test.tar.gz'
     verify_checksum '$fixture' 'cyfr_test.tar.gz'
     status=\$?
     # restore fixture for later cases regardless
     exit \$status"

# Restore the fixture after the tamper case
printf 'binary-bytes-v1' > "$fixture/cyfr_test.tar.gz"

run_case "missing checksum line fails closed" fail \
    "printf '%s  some-other-file.tar.gz\n' '$sum' > '$fixture/checksums.txt'
     verify_checksum '$fixture' 'cyfr_test.tar.gz'"

# Restore checksums.txt
printf '%s  cyfr_test.tar.gz\n' "$sum" > "$fixture/checksums.txt"

# verify_checksum reads checksums.txt with grep and awk before it looks for a
# sha tool, so this case's PATH keeps those and lacks only sha256sum and
# shasum; an empty PATH would stop at "no checksum found" instead.
no_sha_path="$fixture/no-sha-path"
mkdir "$no_sha_path"
for tool in sh grep awk cat printf; do
    if ! tool_file="$(find_tool "$tool")"; then
        printf 'install-verify-test: %s is not on PATH\n' "$tool" >&2
        exit 1
    fi
    ln -s "$tool_file" "$no_sha_path/$tool"
done

run_case "missing sha tool fails closed" fail \
    "PATH='$no_sha_path'
     verify_checksum '$fixture' 'cyfr_test.tar.gz'" \
    "sha256sum or shasum is required"

run_case "CYFR_INSECURE_SKIP_VERIFY=1 bypasses with a warning" ok \
    "CYFR_INSECURE_SKIP_VERIFY=1
     export CYFR_INSECURE_SKIP_VERIFY
     printf 'garbage' > '$fixture/cyfr_test.tar.gz'
     verify_checksum '$fixture' 'cyfr_test.tar.gz'"

# Restore the fixture
printf 'binary-bytes-v1' > "$fixture/cyfr_test.tar.gz"

bundle_url='https://example.invalid/checksums.txt.sigstore.json'

run_case "cosign absent refuses" fail \
    "PATH='/nonexistent'
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "cosign is required"

run_case "cosign absent with CYFR_ALLOW_UNVERIFIED=1 installs on the checksum, with a warning" ok \
    "CYFR_ALLOW_UNVERIFIED=1
     PATH='/nonexistent'
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "signature is NOT verified"

run_case "CYFR_ALLOW_UNVERIFIED set to anything but 1 still refuses" fail \
    "CYFR_ALLOW_UNVERIFIED=yes
     PATH='/nonexistent'
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "cosign is required"

run_case "CYFR_INSECURE_SKIP_VERIFY=1 skips the signature with a warning" ok \
    "CYFR_INSECURE_SKIP_VERIFY=1
     PATH='/nonexistent'
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "signature verification SKIPPED"

# A cosign on PATH that writes its arguments one per line to cosign.args and
# exits with the status in cosign.exit (0 when absent). The bundle downloads
# through an override of download, so no case reaches the network.
cosign_bin="$fixture/cosign-bin"
mkdir "$cosign_bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/cosign.args"\nexit "$(cat "%s/cosign.exit" 2>/dev/null || echo 0)"\n' \
    "$fixture" "$fixture" > "$cosign_bin/cosign"
chmod +x "$cosign_bin/cosign"
with_cosign="PATH='$cosign_bin:$PATH'"
bundle_ok='download() { printf bundle > "$2"; }'
bundle_missing='download() { return 22; }'

run_case "the release workflow's signature for the version passes" ok \
    "$with_cosign
     $bundle_ok
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "Signature verified (the release workflow of 1.2.3"

# The identity cosign was given is exactly the release workflow's at the
# version's tag, under GitHub Actions' issuer; no regexp admits another.
desc="cosign verifies the exact identity release.yml@refs/tags/<version>"
args="$(cat "$fixture/cosign.args" 2>/dev/null)"
expected_args="verify-blob
--bundle
$fixture/checksums.txt.sigstore.json
--certificate-identity
https://github.com/cyfrworks/cyfr/.github/workflows/release.yml@refs/tags/1.2.3
--certificate-oidc-issuer
https://token.actions.githubusercontent.com
$fixture/checksums.txt"
if [ "$args" = "$expected_args" ]; then
    printf 'PASS: %s\n' "$desc"
else
    printf 'FAIL: %s\n' "$desc"
    printf '%s\n' "$args" | sed 's/^/    /'
    failures=$((failures + 1))
fi

printf '1' > "$fixture/cosign.exit"
run_case "a signature cosign refuses fails closed" fail \
    "$with_cosign
     $bundle_ok
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "verification FAILED"
rm -f "$fixture/cosign.exit"

run_case "a signature bundle that does not download refuses" fail \
    "$with_cosign
     $bundle_missing
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "could not be downloaded"

run_case "a missing bundle with CYFR_ALLOW_UNVERIFIED=1 installs on the checksum, with a warning" ok \
    "CYFR_ALLOW_UNVERIFIED=1
     $with_cosign
     $bundle_missing
     verify_signature '$fixture' '$bundle_url' 1.2.3" \
    "signature is NOT verified"

# resolve_version reads the releases API through a curl on PATH that prints
# a fixture: the newest release is the greatest bare MAJOR.MINOR.PATCH by
# number, whatever the listing's order; drafts, releases flagged as
# pre-releases, tags with a pre-release, tags with a leading zero and tags
# that are no version are skipped, and a release body quoting the keys is
# only text.
api_bin="$fixture/api-bin"
mkdir "$api_bin"
cat > "$fixture/releases.json" <<'JSON'
[
  {
    "url": "https://api.github.com/repos/cyfrworks/cyfr/releases/1",
    "author": {"login": "release-bot", "type": "Bot", "site_admin": false},
    "tag_name": "0.5.12",
    "name": "0.5.12",
    "draft": false,
    "prerelease": false,
    "body": "Backport. Not \"tag_name\": \"9.9.9\", \"draft\": false, \"prerelease\": false."
  },
  {"tag_name": "0.11.0", "draft": true, "prerelease": false, "assets": [{"name": "cyfr_0.11.0_linux_amd64.tar.gz", "state": "uploaded"}]},
  {"tag_name": "0.10.0", "draft": false, "prerelease": true},
  {"tag_name": "porta-v1.2.0", "draft": false, "prerelease": false},
  {"tag_name": "v0.20.0", "draft": false, "prerelease": false},
  {"tag_name": "0.9.1-rc1", "draft": false, "prerelease": false},
  {"tag_name": "1.0.0-rc.1", "draft": false, "prerelease": false},
  {"tag_name": "1.1.0-alpha.1", "draft": false, "prerelease": true},
  {"tag_name": "01.0.0", "draft": false, "prerelease": false},
  {"tag_name": "0.9.1", "draft": false, "prerelease": false},
  {"tag_name": "0.6.3", "draft": false, "prerelease": false}
]
JSON
printf '#!/bin/sh\ncat "%s"\n' "$fixture/releases.json" > "$api_bin/curl"
chmod +x "$api_bin/curl"

run_case "the newest release is the greatest bare version, drafts and pre-releases skipped" ok \
    "PATH='$api_bin:$PATH'
     unset CYFR_VERSION
     version=\$(resolve_version) || exit 1
     printf 'resolved %s\n' \"\$version\"
     [ \"\$version\" = 0.9.1 ]" \
    "resolved 0.9.1"

tr -d '\n ' < "$fixture/releases.json" > "$fixture/releases.min.json"
printf '#!/bin/sh\ncat "%s"\n' "$fixture/releases.min.json" > "$api_bin/curl"
run_case "the API's minified answer resolves the same release" ok \
    "PATH='$api_bin:$PATH'
     unset CYFR_VERSION
     version=\$(resolve_version) || exit 1
     printf 'resolved %s\n' \"\$version\"
     [ \"\$version\" = 0.9.1 ]" \
    "resolved 0.9.1"

# With no release to take as the latest, the refusal names CYFR_VERSION,
# the one way to install a pre-release.
no_release="no CYFR release is published yet apart from pre-releases; set CYFR_VERSION to the version to install (https://github.com/cyfrworks/cyfr/releases lists them)"
no_release_case() {
    printf '%s' "$2" > "$fixture/releases.none.json"
    printf '#!/bin/sh\ncat "%s"\n' "$fixture/releases.none.json" > "$api_bin/curl"
    run_case "$1 refuses, naming CYFR_VERSION" fail \
        "PATH='$api_bin:$PATH'
         unset CYFR_VERSION
         resolve_version" \
        "$no_release"
}
no_release_case "an empty release list" '[]'
no_release_case "only releases flagged as pre-releases" \
    '[{"tag_name": "0.6.0", "draft": false, "prerelease": true}, {"tag_name": "0.6.0-alpha.1", "draft": false, "prerelease": true}]'
no_release_case "only tags with a pre-release" \
    '[{"tag_name": "0.6.0-alpha.1", "draft": false, "prerelease": false}, {"tag_name": "1.0.0-rc.2", "draft": false, "prerelease": false}]'
no_release_case "no released bare version" \
    '[{"tag_name": "1.0.0", "draft": true, "prerelease": false}, {"tag_name": "porta-v2.0.0", "draft": false, "prerelease": false}]'

# CYFR_VERSION names the exact version, a pre-release included, and no
# listing is read: the curl on PATH fails.
printf '#!/bin/sh\nexit 22\n' > "$api_bin/curl"
run_case "CYFR_VERSION names a pre-release exactly" ok \
    "PATH='$api_bin:$PATH'
     CYFR_VERSION=0.6.0-alpha.1
     version=\$(resolve_version) || exit 1
     printf 'resolved %s\n' \"\$version\"
     [ \"\$version\" = 0.6.0-alpha.1 ]" \
    "resolved 0.6.0-alpha.1"

# macOS's closing tip offers the Homebrew cask for a bare version alone:
# the cask installs the latest release that is not a pre-release, so a
# pre-release is told the cask follows the first such release.
run_case "a bare version's tip is the Homebrew cask" ok \
    "homebrew_tip 1.2.3" \
    "brew tap cyfrworks/cyfr && brew install --cask cyfr"
run_case "a pre-release's tip says the cask follows the first release that is not one" ok \
    "out=\$(homebrew_tip 0.6.0-alpha.1)
     printf '%s\n' \"\$out\"
     case \"\$out\" in *'brew tap'*|*--cask*) exit 1 ;; esac" \
    "The Homebrew cask follows the first release that is not a pre-release; v0.6.0-alpha.1 is a pre-release, installed by this script alone."

# ---------------------------------------------------------------------------
# Decisions, the policy block, the root helper and whole runs
# ---------------------------------------------------------------------------

pass() {
    printf 'PASS: %s\n' "$1"
}

# Fails the check $1, printing each later argument indented.
fail_check() {
    printf 'FAIL: %s\n' "$1"
    shift
    for detail in "$@"; do
        printf '%s\n' "$detail" | sed 's/^/    /'
    done
    failures=$((failures + 1))
}

# Runs the snippet $2 with the arguments after $3 in a shell that sourced
# install.sh in test mode; passes when its output is exactly $3.
expect() {
    expect_desc="$1"
    expect_snippet="$2"
    expect_want="$3"
    shift 3
    expect_got="$(sh -c 'CYFR_INSTALL_TEST=1; . "$1"; expect_snippet=$2; shift 2; eval "$expect_snippet"' \
        sh "$INSTALL_SH" "$expect_snippet" "$@" 2>&1 </dev/null)"
    if [ "$expect_got" = "$expect_want" ]; then
        pass "$expect_desc"
    else
        fail_check "$expect_desc" "wanted: $expect_want" "got:    $expect_got"
    fi
}

# The real tools every stub world and root helper below runs with, so no
# case finds the host's own sudo, apt-get, dpkg-query, curl or cosign.
base="$fixture/base"
mkdir "$base"
for tool in awk cat chmod cmp cp cut date dirname env flock grep gzip id ls mkdir mkfifo mktemp mv rm sed sha256sum sleep tar touch tr; do
    if ! tool_file="$(find_tool "$tool")"; then
        printf 'install-verify-test: %s is not on PATH\n' "$tool" >&2
        exit 1
    fi
    ln -s "$tool_file" "$base/$tool"
done

# --- The shared vectors ----------------------------------------------------

vectors="$REPO_ROOT/tests/fixtures/install_prerequisites.json"
vec="$fixture/vectors"
mkdir "$vec"
if ! python3 -I - "$vectors" "$vec" <<'PY'
import json
import os
import sys

source, out = sys.argv[1], sys.argv[2]
with open(source, encoding="utf-8") as f:
    data = json.load(f)


def field(value):
    text = str(value)
    if "|" in text or "\n" in text:
        sys.exit(f"{text!r} cannot be a field")
    return text


def flag(value):
    return "yes" if value else "no"


def write(name, text):
    with open(os.path.join(out, name), "w", encoding="utf-8") as f:
        f.write(text)


def table(name, rows):
    if not rows:
        sys.exit(f"the vectors' {name} array is empty")
    write(name, "".join("|".join(field(v) for v in row) + "\n" for row in rows))


rows = []
for i, case in enumerate(data["systems"]):
    write(f"os-release.{i}", case["os_release"])
    rows.append([i, case["arch"], "supported" if case["supported"] else "unsupported", case["system"], case["name"]])
table("systems", rows)

rows = []
for i, case in enumerate(data["universe"]):
    write(f"indextargets.{i}", case["indextargets"])
    rows.append([i, case["codename"], flag(case["enabled"]), case["name"]])
table("universe", rows)

rows = []
for i, case in enumerate(data["bootstrap"]):
    rows.append([i, flag(case["supported"]), flag(case["universe"]), flag(case["bypass"]),
                 " ".join(case["commands"]), " ".join(case["installed"]), case["outcome"],
                 " ".join(case["packages"]), case["name"]])
table("bootstrap", rows)
PY
then
    printf 'install-verify-test: cannot flatten %s\n' "$vectors" >&2
    exit 1
fi

while IFS='|' read -r n arch supported system name; do
    expect "os-release: $name" '
        OS_RELEASE_PATHS=$1
        read_system linux
        if system_supported "$2"; then printf "supported "; else printf "unsupported "; fi
        system_name' "$supported $system" "$vec/os-release.$n" "$arch"
done <"$vec/systems"

# An apt-get that prints the current case's index targets and keeps its
# arguments.
universe_bin="$vec/universe-bin"
mkdir "$universe_bin"
cat >"$universe_bin/apt-get" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >'$vec/apt-get.args'
exec '$base/cat' '$vec/indextargets.current'
EOF
chmod +x "$universe_bin/apt-get"
while IFS='|' read -r n codename enabled name; do
    cp "$vec/indextargets.$n" "$vec/indextargets.current"
    expect "universe: $name" '
        PATH=$1
        os_codename=$2
        if universe_enabled; then echo yes; else echo no; fi' "$enabled" "$universe_bin" "$codename"
done <"$vec/universe"
desc="universe is read from apt-get indextargets without the release files"
# shellcheck disable=SC2016 # apt's own format fields
want_args='indextargets
--no-release-info
--format
$(RELEASE) $(COMPONENT) $(IDENTIFIER)'
if [ "$(cat "$vec/apt-get.args")" = "$want_args" ]; then
    pass "$desc"
else
    fail_check "$desc" "$(cat "$vec/apt-get.args")"
fi

# Each bootstrap case gets a PATH of its commands and a dpkg-query and an
# apt-get that report its packages and universe; a case with a bypass runs
# once under each bypass, one without under neither.
while IFS='|' read -r n supported universe bypass commands installed outcome packages name; do
    b="$vec/bootstrap.$n"
    mkdir -p "$b/commands" "$b/stubs"
    for command_name in $commands; do
        printf '#!/bin/sh\n' >"$b/commands/$command_name"
        chmod +x "$b/commands/$command_name"
    done
    : >"$b/installed"
    for package in $installed; do
        printf '%s\n' "$package" >>"$b/installed"
    done
    cat >"$b/stubs/dpkg-query" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$b/dpkg.log'
if '$base/grep' -qx -- "\$3" '$b/installed'; then printf installed; exit 0; fi
exit 1
EOF
    if [ "$universe" = yes ]; then
        printf '#!/bin/sh\nprintf "resolute main Packages\\nresolute universe Packages\\n"\n' >"$b/stubs/apt-get"
    else
        printf '#!/bin/sh\nprintf "resolute main Packages\\n"\n' >"$b/stubs/apt-get"
    fi
    chmod +x "$b/stubs/dpkg-query" "$b/stubs/apt-get"
    if [ "$bypass" = yes ]; then
        bypasses="CYFR_ALLOW_UNVERIFIED CYFR_INSECURE_SKIP_VERIFY"
    else
        bypasses="none"
    fi
    for bypass_name in $bypasses; do
        expect "bootstrap: $name (bypass: $bypass_name)" '
            PATH=$1
            unset CYFR_ALLOW_UNVERIFIED CYFR_INSECURE_SKIP_VERIFY
            case "$3" in
                CYFR_ALLOW_UNVERIFIED) CYFR_ALLOW_UNVERIFIED=1 ;;
                CYFR_INSECURE_SKIP_VERIFY) CYFR_INSECURE_SKIP_VERIFY=1 ;;
            esac
            bootstrap_decide "$2"
            printf "%s [%s]\n" "$bootstrap_outcome" "$bootstrap_packages"' \
            "$outcome [$packages]" "$b/commands:$b/stubs" "$supported" "$bypass_name"
    done
    if [ "$supported" = no ]; then
        desc="bootstrap: $name reads no dpkg on another system"
        if [ -s "$b/dpkg.log" ]; then
            fail_check "$desc" "$(cat "$b/dpkg.log")"
        else
            pass "$desc"
        fi
    fi
done <"$vec/bootstrap"

# Facts the vectors leave out: dpkg's other states are not installed, a
# cosign that is not an executable file is missing however it is spelled,
# and a bypass is exactly 1.
extra="$vec/extra"
mkdir -p "$extra/commands/cosign" "$extra/stubs"
printf '#!/bin/sh\n' >"$extra/commands/curl"
chmod +x "$extra/commands/curl"
printf '#!/bin/sh\nprintf "%%s" "$(cat %s/status)"\n' "$extra" >"$extra/stubs/dpkg-query"
printf '#!/bin/sh\nprintf "resolute universe Packages\\n"\n' >"$extra/stubs/apt-get"
chmod +x "$extra/stubs/dpkg-query" "$extra/stubs/apt-get"
mkdir "$extra/plain"
printf 'not executable\n' >"$extra/plain/cosign"
for status in config-files not-installed half-configured; do
    printf '%s' "$status" >"$extra/status"
    expect "bootstrap: dpkg's $status is not installed" '
        PATH=$1
        bootstrap_decide yes
        printf "%s [%s]\n" "$bootstrap_outcome" "$bootstrap_packages"' \
        "install [ca-certificates cosign]" "$extra/commands:$extra/stubs:$base"
done
printf 'installed' >"$extra/status"
expect "bootstrap: a cosign directory, a cosign that is not executable and a cosign function are no cosign" '
    PATH=$1
    cosign() { :; }
    bootstrap_decide yes
    printf "%s [%s]\n" "$bootstrap_outcome" "$bootstrap_packages"' \
    "install [cosign]" "$extra/commands:$extra/plain:$extra/stubs:$base"
expect "bootstrap: CYFR_ALLOW_UNVERIFIED=yes is no bypass" '
    PATH=$1
    CYFR_ALLOW_UNVERIFIED=yes
    bootstrap_decide yes
    printf "%s [%s]\n" "$bootstrap_outcome" "$bootstrap_packages"' \
    "install [cosign]" "$extra/commands:$extra/stubs:$base"

expect "the rerun command carries the CYFR_ settings after the pipe, quoted where the shell needs it" '
    CYFR_VERSION=0.6.0-alpha.5
    CYFR_INSTALL_DIR="/opt/my tools/it'\''s"
    install_command' \
    "curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | CYFR_VERSION=0.6.0-alpha.5 CYFR_INSTALL_DIR='/opt/my tools/it'\\''s' sh"

# --- The generated policy block --------------------------------------------

generator="$REPO_ROOT/scripts/generate-install-policy.py"
policy="$REPO_ROOT/apps/codex/internal/install/policy.json"
gen="$fixture/generator"
mkdir "$gen"

desc="the script's install policy block is the one the policy generates"
if gen_out="$(python3 -I "$generator" --check --policy "$policy" --script "$INSTALL_SH" 2>&1)"; then
    pass "$desc"
else
    fail_check "$desc" "$gen_out"
fi

cp "$policy" "$gen/policy.json"
cp "$INSTALL_SH" "$gen/install.sh"
cp "$INSTALL_SH" "$gen/install.sh.before"
python3 -I - "$gen/policy.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    policy = json.load(f)
policy["lock"]["seconds"] = 61
policy["bootstrap"].append({"package": "jq", "commands": ["jq"], "universe": False})
with open(path, "w", encoding="utf-8") as f:
    json.dump(policy, f)
PY
desc="--check names a policy change the block lacks and changes nothing"
gen_out="$(python3 -I "$generator" --check --policy "$gen/policy.json" --script "$gen/install.sh" 2>&1)"
gen_status=$?
case "$gen_status:$gen_out" in
    1:*"the install policy block differs from"*"+POLICY_LOCK_SECONDS='61'"*)
        if cmp -s "$gen/install.sh" "$gen/install.sh.before"; then
            pass "$desc"
        else
            fail_check "$desc" "--check rewrote the script"
        fi
        ;;
    *) fail_check "$desc" "exit $gen_status" "$gen_out" ;;
esac
desc="the generator writes the changed policy into the block, after which --check passes"
if python3 -I "$generator" --policy "$gen/policy.json" --script "$gen/install.sh" >/dev/null 2>&1 &&
    python3 -I "$generator" --check --policy "$gen/policy.json" --script "$gen/install.sh" >/dev/null 2>&1 &&
    grep -qx "POLICY_LOCK_SECONDS='61'" "$gen/install.sh" &&
    grep -qx "jq commands jq no'" "$gen/install.sh"; then
    pass "$desc"
else
    fail_check "$desc" "$(sed -n '/^# BEGIN install policy/,/^# END install policy/p' "$gen/install.sh")"
fi
cp "$gen/install.sh" "$gen/install.sh.before"
python3 -I - "$gen/policy.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    policy = json.load(f)
policy["bootstrap"][0]["package"] = "co'sign"
with open(path, "w", encoding="utf-8") as f:
    json.dump(policy, f)
PY
desc="a policy value outside its grammar is refused and writes nothing"
gen_out="$(python3 -I "$generator" --policy "$gen/policy.json" --script "$gen/install.sh" 2>&1)"
gen_status=$?
if [ "$gen_status" -eq 2 ] && cmp -s "$gen/install.sh" "$gen/install.sh.before"; then
    pass "$desc"
else
    fail_check "$desc" "exit $gen_status" "$gen_out"
fi

# Prints the lines of the script $2 outside its policy block that restate
# one of the policy $1's values, exiting 1 when there is one.
restated() {
    python3 -I - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    policy = json.load(f)
with open(sys.argv[2], encoding="utf-8") as f:
    lines = f.read().split("\n")
begin = next(i for i, line in enumerate(lines) if line.startswith("# BEGIN install policy"))
end = lines.index("# END install policy")
values = [
    policy["system"]["version_id"],
    policy["system"]["codename"],
    policy["system"]["name"],
    policy["universe"]["command"],
    policy["install_path"],
    policy["lock"]["path"],
] + [row["installed"] for row in policy["bootstrap"] if "installed" in row]
found = [f"{i + 1}: {line}" for i, line in enumerate(lines) if not begin <= i <= end and any(v in line for v in values)]
print("\n".join(found))
sys.exit(1 if found else 0)
PY
}
desc="nothing outside the policy block restates a policy value"
if restate_out="$(restated "$policy" "$INSTALL_SH")"; then
    pass "$desc"
else
    fail_check "$desc" "$restate_out"
fi
cp "$INSTALL_SH" "$gen/planted.sh"
printf '# resolute\n' >>"$gen/planted.sh"
desc="the restatement check finds a planted restatement"
if restated "$policy" "$gen/planted.sh" >/dev/null; then
    fail_check "$desc" "the planted line was not found"
else
    pass "$desc"
fi

# --- The root helper --------------------------------------------------------

helper="$fixture/helper"
mkdir -p "$helper/bin" "$helper/dest"
cat >"$helper/bin/apt-get" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$helper/apt.log'
EOF
chmod +x "$helper/bin/apt-get"
: >"$helper/apt.log"
sh -c 'CYFR_INSTALL_TEST=1; . "$1"; ROOT_PATH=$2; POLICY_LOCK_PATH=$3; POLICY_LOCK_SECONDS=2; root_helper_text' \
    sh "$INSTALL_SH" "$helper/bin:$base" "$helper/install.lock" >"$helper/text" 2>&1

# Runs the helper text as the person's side would: for the private
# directory $1 and destination $2 with the packages after $4, it reads the
# first replies, sends the request $3 (none: none) and prints every reply
# and the helper's status.
cat >"$helper/drive" <<'EOF'
dir=$1
dest=$2
request=$3
text=$4
shift 4
mkfifo "$dir/req" "$dir/rep"
sh -c "$(cat "$text")" cyfr-install-helper "$dir" "$dest" "$@" >"$dir/helper.out" 2>&1 &
pid=$!
exec 4<"$dir/rep" 3>"$dir/req"
IFS= read -r reply <&4
printf '%s\n' "$reply"
if [ "$reply" = ready ] && [ "$#" -gt 0 ]; then
    IFS= read -r reply <&4
    printf '%s\n' "$reply"
fi
if [ "$reply" != "${reply#refused}" ]; then
    request=none
fi
if [ "$request" != none ]; then
    printf '%s\n' "$request" >&3
fi
exec 3>&-
while IFS= read -r reply <&4; do
    printf '%s\n' "$reply"
done
wait "$pid"
printf 'status %s\n' "$?"
EOF

verified_sum="$(printf 'verified-bytes' | sha256sum | awk '{print $1}')"

# Runs one helper conversation in a fresh private directory holding the
# file $2 as cyfr; passes when its replies are exactly $3.
helper_case() {
    helper_desc="$1"
    helper_dir="$(mktemp -d "$helper/dir.XXXXXX")"
    printf '%s' "$2" >"$helper_dir/cyfr"
    helper_want="$3"
    helper_dest="$4"
    helper_request="$(printf '%s' "$5" | sed "s|@DIR@|$helper_dir|g")"
    shift 5
    helper_got="$(timeout 30 sh "$helper/drive" "$helper_dir" "$helper_dest" "$helper_request" "$helper/text" "$@" 2>&1 </dev/null)"
    if [ "$helper_got" = "$helper_want" ]; then
        pass "$helper_desc"
    else
        fail_check "$helper_desc" "wanted: $helper_want" "got:    $helper_got" "$(cat "$helper_dir/helper.out" 2>/dev/null)"
    fi
}

# Whether the helper's destination directory holds nothing but $1.
dest_holds_only() {
    [ "$(ls -A "$helper/dest")" = "$1" ]
}

helper_case "the helper installs the verified bytes by rename, mode 0755" verified-bytes \
    "ready
installed
status 0" "$helper/dest/cyfr" "install @DIR@/cyfr $verified_sum"
desc="the helper's install holds the verified bytes, mode 0755, and leaves no temporary"
if [ "$(cat "$helper/dest/cyfr")" = verified-bytes ] && [ "$(ls -ln "$helper/dest/cyfr" | cut -c1-10)" = -rwxr-xr-x ] && dest_holds_only cyfr; then
    pass "$desc"
else
    fail_check "$desc" "$(ls -lan "$helper/dest")"
fi

helper_case "a file swapped after verification is refused by the hash check" swapped-bytes \
    "ready
refused mismatch
status 1" "$helper/dest/cyfr" "install @DIR@/cyfr $verified_sum"
desc="the refused swap left the installed copy and no temporary"
if [ "$(cat "$helper/dest/cyfr")" = verified-bytes ] && dest_holds_only cyfr; then
    pass "$desc"
else
    fail_check "$desc" "$(ls -lan "$helper/dest")"
fi

helper_case "the helper refuses a file outside its private directory" verified-bytes \
    "ready
refused request
status 1" "$helper/dest/cyfr" "install /etc/hostname $verified_sum"

helper_case "the helper refuses a malformed SHA-256" verified-bytes \
    "ready
refused request
status 1" "$helper/dest/cyfr" "install @DIR@/cyfr $(printf '%s' "$verified_sum" | tr a-f A-F)"

helper_case "the helper refuses a command instead of a request" verified-bytes \
    "ready
refused request
status 1" "$helper/dest/cyfr" "rm -rf /"

helper_case "the end of the requests installs nothing" other-bytes \
    "ready
status 0" "$helper/dest/cyfr" none
desc="the helper's ended conversation left the installed copy"
if [ "$(cat "$helper/dest/cyfr")" = verified-bytes ]; then
    pass "$desc"
else
    fail_check "$desc" "$(cat "$helper/dest/cyfr")"
fi

helper_case "the helper refuses a package outside the policy before running apt" verified-bytes \
    "refused arguments
status 1" "$helper/dest/cyfr" none jq
helper_case "the helper refuses a destination other than the CLI's name" verified-bytes \
    "refused arguments
status 1" "$helper/dest/other" none
desc="no refused argument ran apt"
if [ -s "$helper/apt.log" ]; then
    fail_check "$desc" "$(cat "$helper/apt.log")"
else
    pass "$desc"
fi

linked="$(mktemp -d "$helper/dir.XXXXXX")"
printf 'verified-bytes' >"$helper/elsewhere"
ln -s "$helper/elsewhere" "$linked/cyfr"
desc="the helper refuses a source that is a link"
got="$(timeout 30 sh "$helper/drive" "$linked" "$helper/dest/cyfr" "install $linked/cyfr $verified_sum" "$helper/text" 2>&1 </dev/null)"
if [ "$got" = "ready
refused copy
status 1" ]; then
    pass "$desc"
else
    fail_check "$desc" "$got"
fi

# --- Whole runs ------------------------------------------------------------

# One release, served by every world's curl.
release="$fixture/release"
mkdir -p "$release/stage"
printf '#!/bin/sh\necho cyfr 1.2.3\n' >"$release/stage/cyfr"
chmod 755 "$release/stage/cyfr"
tar -czf "$release/cyfr_1.2.3_linux_amd64.tar.gz" -C "$release/stage" cyfr
printf '%s  cyfr_1.2.3_linux_amd64.tar.gz\n' "$(sha256sum <"$release/cyfr_1.2.3_linux_amd64.tar.gz" | awk '{print $1}')" >"$release/checksums.txt"
printf 'bundle' >"$release/checksums.txt.sigstore.json"
real_id="$(find_tool id)"
cmd_text='curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | CYFR_VERSION=1.2.3 sh'

# Makes the world $1 in $w: a fresh Ubuntu 26.04 cloud image as the stubs
# show it (ca-certificates installed, curl present, cosign absent,
# universe enabled, sudo that works), the release, a terminal answering
# yes, and the assignments that point the sourced script at them. Every
# stub finds its world two directories above itself and appends what it
# was asked to $w/events.
make_world() {
    w="$fixture/world-$1"
    mkdir -p "$w/bin" "$w/rootbin" "$w/sysbin" "$w/home/.local/bin" "$w/usrlocal" "$w/tmp" "$w/release"
    cp "$release"/cyfr_1.2.3_linux_amd64.tar.gz "$release"/checksums.txt "$release"/checksums.txt.sigstore.json "$w/release/"
    : >"$w/events"
    printf 'ca-certificates\n' >"$w/dpkg-installed"
    : >"$w/dpkg-files"
    : >"$w/universe"
    printf 'y\n' >"$w/tty"
    mkdir "$w/real-id"
    ln -s "$real_id" "$w/real-id/id"
    printf 'PRETTY_NAME="Ubuntu 26.04.1 LTS"\nNAME="Ubuntu"\nVERSION_ID="26.04"\nVERSION_CODENAME=resolute\nID=ubuntu\n' >"$w/os-release"

    cat >"$w/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
    -s) echo Linux ;;
    -m) echo x86_64 ;;
esac
EOF
    cat >"$w/bin/id" <<'EOF'
#!/bin/sh
W=${0%/*/*}
if [ "$1" = -u ] && [ -f "$W/uid" ]; then
    cat "$W/uid"
    exit 0
fi
exec "$W/real-id/id" "$@"
EOF
    cat >"$w/bin/curl" <<'EOF'
#!/bin/sh
W=${0%/*/*}
printf 'curl %s\n' "$*" >>"$W/events"
out=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
name=${url##*/}
if [ -e "$W/offline" ]; then
    echo "curl: (6) Could not resolve host: github.com" >&2
    exit 6
fi
if [ -e "$W/hold" ] && [ "$name" = cyfr_1.2.3_linux_amd64.tar.gz ]; then
    : >"$W/at-download"
    sleep 30
fi
if [ ! -f "$W/release/$name" ]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
    exit 22
fi
if [ -n "$out" ]; then
    cp "$W/release/$name" "$out"
else
    cat "$W/release/$name"
fi
EOF
    cat >"$w/bin/sudo" <<'EOF'
#!/bin/sh
W=${0%/*/*}
line=sudo
for arg in "$@"; do
    case "$arg" in
        *'
'*) line="$line <script>" ;;
        *) line="$line $arg" ;;
    esac
done
printf '%s\n' "$line" >>"$W/events"
if [ "$#" -eq 1 ] && [ "$1" = -k ]; then
    exit 0
fi
noninteractive=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n) noninteractive=yes; shift ;;
        -k) shift ;;
        --) shift; break ;;
        *) echo "fake sudo: unexpected $1" >&2; exit 2 ;;
    esac
done
case "$(cat "$W/sudo-mode" 2>/dev/null)" in
    refuse)
        echo "sudo: 3 incorrect authentication attempts" >&2
        exit 1
        ;;
    refuse-n)
        if [ "$noninteractive" = yes ]; then
            echo "sudo: interactive authentication is required" >&2
            exit 1
        fi
        ;;
esac
exec env -i "$@"
EOF
    cat >"$w/bin/apt-get" <<'EOF'
#!/bin/sh
W=${0%/*/*}
if [ "$1" = indextargets ]; then
    if [ -e "$W/universe" ]; then
        printf 'resolute main Packages\nresolute universe Packages\n'
    else
        printf 'resolute main Packages\n'
    fi
    exit 0
fi
if [ -n "${HOME:-}" ]; then
    environment=person-env
else
    environment=clean-env
fi
printf 'apt-get %s [%s]\n' "$*" "$environment" >>"$W/events"
case " $* " in
    *" update "*)
        case "$(cat "$W/apt-update" 2>/dev/null)" in
            list-lock)
                echo 'E: Could not get lock /var/lib/apt/lists/lock. It is held by process 4242 (apt-get)' >&2
                exit 100
                ;;
            fail)
                echo 'E: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/resolute/InRelease  Temporary failure resolving' >&2
                exit 100
                ;;
        esac
        echo 'Reading package lists... Done'
        ;;
    *" install "*)
        case "$(cat "$W/apt-install" 2>/dev/null)" in
            dpkg-lock)
                echo 'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 4243 (unattended-upgr)' >&2
                exit 100
                ;;
            interrupted)
                echo "E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem." >&2
                exit 100
                ;;
        esac
        if [ -e "$W/hold-apt" ]; then
            : >"$W/at-apt"
            sleep 30
        fi
        listed=no
        for arg in "$@"; do
            if [ "$listed" = yes ]; then
                printf '%s\n' "$arg" >>"$W/dpkg-installed"
                if [ "$arg" = cosign ]; then
                    cp "$W/cosign-stub" "$W/sysbin/cosign"
                    chmod 755 "$W/sysbin/cosign"
                fi
                echo "Setting up $arg"
            fi
            if [ "$arg" = --no-install-recommends ]; then
                listed=yes
            fi
        done
        ;;
esac
EOF
    cp "$w/bin/apt-get" "$w/rootbin/apt-get"
    cat >"$w/cosign-stub" <<'EOF'
#!/bin/sh
W=${0%/*/*}
printf 'cosign %s\n' "$1" >>"$W/events"
exit "$(cat "$W/cosign-exit" 2>/dev/null || echo 0)"
EOF
    cat >"$w/bin/dpkg-query" <<'EOF'
#!/bin/sh
W=${0%/*/*}
case "$1" in
    -W)
        if grep -qx -- "$3" "$W/dpkg-installed"; then
            printf installed
            exit 0
        fi
        echo "dpkg-query: no packages found matching $3" >&2
        exit 1
        ;;
    -S)
        while read -r package path; do
            if [ "$path" = "$2" ]; then
                echo "$package: $path"
                exit 0
            fi
        done <"$W/dpkg-files"
        echo "dpkg-query: no path found matching pattern $2" >&2
        exit 1
        ;;
esac
exit 2
EOF
    cat >"$w/bin/add-apt-repository" <<'EOF'
#!/bin/sh
W=${0%/*/*}
printf 'add-apt-repository %s\n' "$*" >>"$W/events"
EOF
    chmod +x "$w/bin/"* "$w/rootbin/apt-get" "$w/cosign-stub"
    cat >"$w/overrides" <<EOF
OS_RELEASE_PATHS='$w/os-release'
TTY_DEVICE='$w/tty'
ROOT_PATH='$w/rootbin:$base'
POLICY_INSTALL_PATH='$w/usrlocal/cyfr'
POLICY_LOCK_PATH='$w/install.lock'
POLICY_LOCK_SECONDS=2
EOF
}

# The world's cosign, as if the archive's package were installed.
with_cosign() {
    cp "$w/cosign-stub" "$w/sysbin/cosign"
    chmod 755 "$w/sysbin/cosign"
    printf 'cosign\n' >>"$w/dpkg-installed"
}

world_env() {
    printf '%s\n' "HOME=$w/home" "PATH=$w/home/.local/bin:$w/bin:$w/sysbin:$base:$w/usrlocal" "TMPDIR=$w/tmp" "CYFR_VERSION=1.2.3"
}

# Runs the installer's main in the world with the extra settings given as
# arguments; the output lands in $w/out, the status in $w/status and the
# seconds it took in $elapsed.
run_world() {
    started="$(date +%s)"
    # shellcheck disable=SC2046 # one assignment a line, no blanks
    timeout 60 env -i $(world_env) "$@" /bin/sh -c 'CYFR_INSTALL_TEST=1; . "$1"; . "$2"; main' \
        sh "$INSTALL_SH" "$w/overrides" >"$w/out" 2>&1 </dev/null
    printf '%s\n' "$?" >"$w/status"
    elapsed=$(($(date +%s) - started))
}

problems=
note() {
    problems="$problems$1
"
}
status_is() {
    if [ "$(cat "$w/status")" != "$1" ]; then
        note "exit $(cat "$w/status"), wanted $1"
    fi
}
out_has() {
    if ! grep -F -q -- "$1" "$w/out"; then
        note "output lacks: $1"
    fi
}
out_lacks() {
    if grep -F -q -- "$1" "$w/out"; then
        note "output has: $1"
    fi
}
event_line() {
    if ! grep -F -x -q -- "$1" "$w/events"; then
        note "no event line: $1"
    fi
}
events_lack() {
    if grep -F -q -- "$1" "$w/events"; then
        note "events have: $1"
    fi
}
# The number of the first event line containing $1, or nothing.
first_event() {
    grep -n -F -m 1 -- "$1" "$w/events" | cut -d: -f1
}
event_before() {
    first="$(first_event "$1")"
    second="$(first_event "$2")"
    if [ -z "$first" ] || [ -z "$second" ] || [ "$first" -ge "$second" ]; then
        note "event '$1' is not before '$2'"
    fi
}
# The elevation $1 ran once, and sudo -k after it as the last sudo.
elevated_once_then_cleaned() {
    if [ "$(grep -c -F -- "$1" "$w/events")" != 1 ]; then
        note "not one elevation: $1"
    fi
    if [ "$(grep '^sudo' "$w/events" | tail -n 1)" != "sudo -k" ]; then
        note "the last sudo is not sudo -k"
    fi
    elevated_at="$(first_event "$1")"
    cleaned_at="$(grep -n -x -F 'sudo -k' "$w/events" | tail -n 1 | cut -d: -f1)"
    if [ -z "$elevated_at" ] || [ -z "$cleaned_at" ] || [ "$elevated_at" -ge "$cleaned_at" ]; then
        note "sudo -k did not run after the elevation"
    fi
}
nothing_as_root() {
    events_lack "sudo"
    events_lack "apt-get"
}
tmp_is_empty() {
    if [ -n "$(ls -A "$w/tmp")" ]; then
        note "the run left $(ls -A "$w/tmp") in its TMPDIR"
    fi
}
installed_release() {
    if ! cmp -s "$release/stage/cyfr" "$1" || [ "$(ls -ln "$1" | cut -c1-10)" != -rwxr-xr-x ]; then
        note "$1 is not the release's cyfr, mode 0755"
    fi
}
not_installed() {
    if [ -e "$1" ]; then
        note "$1 was installed"
    fi
}
verdict() {
    if [ -z "$problems" ]; then
        pass "$1"
    else
        fail_check "$1" "$problems" "output:" "$(cat "$w/out")" "events:" "$(cat "$w/events")"
    fi
    problems=
}

elevation="sudo -k -- /bin/sh -c <script> cyfr-install-helper "

make_world fresh
run_world
status_is 0
out_has "CYFR runs these commands as root:
  apt-get update
  apt-get -o DPkg::Lock::Timeout=2 install -y --no-install-recommends cosign
  install -o root -g root -m 0755 "
out_has " $w/usrlocal/cyfr
The last command runs once the download it installs passes the signature and checksum checks.
Install these requirements? [y/N] "
out_has "cyfr v1.2.3 installed successfully to $w/usrlocal/cyfr"
elevated_once_then_cleaned "$elevation"
event_line "apt-get update [clean-env]"
event_line "apt-get -o DPkg::Lock::Timeout=2 install -y --no-install-recommends cosign [clean-env]"
event_before "$elevation" "apt-get update"
event_before "apt-get update" "apt-get -o DPkg"
event_before "apt-get -o DPkg" "curl"
event_before "apt-get -o DPkg" "cosign verify-blob"
installed_release "$w/usrlocal/cyfr"
tmp_is_empty
verdict "a fresh image lacking cosign: one agreed elevation installs cosign before verification, then the verified cyfr"
grep -F "$elevation" "$w/events" >"$w/elevation"
case "$(cat "$w/elevation")" in
    *" $w/usrlocal/cyfr cosign") pass "the elevation names the destination and the packages as its arguments" ;;
    *) fail_check "the elevation names the destination and the packages as its arguments" "$(cat "$w/elevation")" ;;
esac

make_world declined
printf 'n\n' >"$w/tty"
run_world
status_is 1
out_has "You chose not to install cosign and cyfr in $w/usrlocal. Nothing was installed. Run \`$cmd_text\` again when you want to continue."
nothing_as_root
events_lack "curl"
not_installed "$w/usrlocal/cyfr"
tmp_is_empty
verdict "declining runs nothing as root and downloads nothing"

make_world no-terminal
rm "$w/tty"
run_world
status_is 1
out_has "Installing cosign and cyfr in $w/usrlocal needs your agreement in a terminal. Nothing was installed. Run \`$cmd_text\` in a terminal, or with CYFR_INSTALL_YES=1 after the pipe to agree to the commands it shows."
nothing_as_root
verdict "without a terminal or CYFR_INSTALL_YES=1 nothing runs as root"

make_world yes
rm "$w/tty"
run_world CYFR_INSTALL_YES=1
status_is 0
out_has "CYFR_INSTALL_YES=1 approves these commands."
out_lacks "Install these requirements?"
elevated_once_then_cleaned "sudo -n -k -- /bin/sh -c <script> cyfr-install-helper "
installed_release "$w/usrlocal/cyfr"
verdict "CYFR_INSTALL_YES=1 approves the displayed plan and elevates with sudo -n -k"

make_world yes-needs-password
printf 'refuse-n\n' >"$w/sudo-mode"
run_world CYFR_INSTALL_YES=1
status_is 1
out_has "This account cannot run sudo, so CYFR cannot install cosign and cyfr in $w/usrlocal. Nothing was installed. Run \`curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | CYFR_VERSION=1.2.3 CYFR_INSTALL_YES=1 sh\` from an account that can install software."
events_lack "apt-get"
elevated_once_then_cleaned "sudo -n -k -- /bin/sh -c <script> cyfr-install-helper "
verdict "CYFR_INSTALL_YES=1 still needs sudo that works without a prompt"

make_world sudo-refuses
printf 'refuse\n' >"$w/sudo-mode"
run_world
status_is 1
out_has "This account cannot run sudo, so CYFR cannot install cosign and cyfr in $w/usrlocal. Nothing was installed. Run \`$cmd_text\` from an account that can install software."
events_lack "apt-get"
elevated_once_then_cleaned "$elevation"
tmp_is_empty
verdict "sudo refusing the elevation refuses the install, and sudo -k still runs"

make_world no-sudo
rm "$w/bin/sudo"
run_world
status_is 1
out_has "This account cannot run sudo, so CYFR cannot install cosign and cyfr in $w/usrlocal. Nothing was installed. Run \`$cmd_text\` from an account that can install software."
out_lacks "Install these requirements?"
events_lack "apt-get"
verdict "an account without sudo is refused before any question"

make_world yes-invalid
run_world CYFR_INSTALL_YES=yes
status_is 1
out_has "CYFR_INSTALL_YES is yes; set it to 1"
nothing_as_root
verdict "CYFR_INSTALL_YES other than 1 is refused"

make_world no-universe
rm "$w/universe"
run_world
status_is 1
out_has "Ubuntu's universe archive is not enabled. Run \`sudo add-apt-repository universe\`, then run \`$cmd_text\` again."
nothing_as_root
events_lack "add-apt-repository"
events_lack "curl"
verdict "universe missing refuses with its command and edits nothing"

make_world unsupported
printf 'PRETTY_NAME="Ubuntu 24.04.3 LTS"\nNAME="Ubuntu"\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nID=ubuntu\n' >"$w/os-release"
run_world
status_is 1
out_has "CYFR installs these requirements automatically on Ubuntu 26.04 LTS. This machine runs Ubuntu 24.04.3 LTS and needs cosign. Install them, then run \`$cmd_text\` again."
nothing_as_root
events_lack "curl"
verdict "another system lacking cosign is named, with what it lacks"

make_world satisfied-own-dir
with_cosign
mkdir "$w/opt"
run_world CYFR_INSTALL_DIR="$w/opt"
status_is 0
nothing_as_root
installed_release "$w/opt/cyfr"
verdict "every tool present and a writable CYFR_INSTALL_DIR: no elevation and no apt"

make_world satisfied-installed
with_cosign
cp "$release/stage/cyfr" "$w/usrlocal/cyfr"
chmod 755 "$w/usrlocal/cyfr"
run_world
status_is 0
out_has "cyfr v1.2.3 is already installed at $w/usrlocal/cyfr"
nothing_as_root
verdict "a rerun of the installed version elevates nothing and runs no apt"

make_world satisfied-new-cli
with_cosign
run_world
status_is 0
out_has "  install -o root -g root -m 0755 "
out_lacks "apt-get update"
events_lack "apt-get"
elevated_once_then_cleaned "$elevation"
case "$(grep -F "$elevation" "$w/events")" in
    *" $w/usrlocal/cyfr") ;;
    *) note "the elevation carries packages" ;;
esac
checked="$(grep -n -F 'Checksum verified.' "$w/out" | cut -d: -f1)"
asked="$(grep -n -F 'CYFR runs these commands as root:' "$w/out" | cut -d: -f1)"
if [ -z "$checked" ] || [ -z "$asked" ] || [ "$checked" -ge "$asked" ]; then
    note "the question came before the verification"
fi
installed_release "$w/usrlocal/cyfr"
verdict "every tool present: the verified cyfr alone is shown, agreed and installed by root"

make_world root
with_cosign
printf '0\n' >"$w/uid"
rm "$w/tty"
run_world
status_is 0
events_lack "sudo"
out_lacks "Install these requirements?"
installed_release "$w/usrlocal/cyfr"
verdict "as root the helper installs the CLI without sudo or a question"

make_world root-packages
printf '0\n' >"$w/uid"
run_world
status_is 0
events_lack "sudo"
out_has "Install these requirements? [y/N] "
event_line "apt-get -o DPkg::Lock::Timeout=2 install -y --no-install-recommends cosign [person-env]"
installed_release "$w/usrlocal/cyfr"
verdict "as root packages still need agreement, and run without sudo"

make_world install-lock
: >"$w/install.lock"
sh -c 'exec 9<"$1"; flock 9; : >"$2"; exec sleep 30' sh "$w/install.lock" "$w/held" &
holder=$!
waited=0
while [ ! -e "$w/held" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
run_world
status_is 1
out_has "Another CYFR installation is still running after 2 seconds. Nothing was installed. Let it finish, then run \`$cmd_text\` again."
events_lack "apt-get"
elevated_once_then_cleaned "$elevation"
if [ "$elapsed" -gt 7 ]; then
    note "the refusal took $elapsed seconds"
fi
if ! kill -0 "$holder" 2>/dev/null || [ ! -e "$w/install.lock" ]; then
    note "the other installation's lock or its holder is gone"
fi
verdict "a held install lock refuses after its deadline, leaving the holder and its lock"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

make_world list-lock
printf 'list-lock\n' >"$w/apt-update"
run_world
status_is 1
out_has "A package-list update is still running after 2 seconds. Nothing was installed. Let it finish, then run \`$cmd_text\` again."
if [ "$(grep -c -F 'apt-get update' "$w/events")" -lt 2 ]; then
    note "the list lock was not retried"
fi
events_lack "install -y"
if [ "$elapsed" -lt 2 ] || [ "$elapsed" -gt 7 ]; then
    note "the refusal took $elapsed seconds"
fi
elevated_once_then_cleaned "$elevation"
verdict "the package-list lock is retried until its deadline, then refused"

make_world dpkg-lock
printf 'dpkg-lock\n' >"$w/apt-install"
run_world
status_is 1
out_has "A package installation is still running after 2 seconds. Nothing was installed. Let it finish, then run \`$cmd_text\` again."
event_line "apt-get -o DPkg::Lock::Timeout=2 install -y --no-install-recommends cosign [clean-env]"
elevated_once_then_cleaned "$elevation"
verdict "the dpkg lock waits through apt's DPkg::Lock::Timeout, then is refused"

make_world update-fails
printf 'fail\n' >"$w/apt-update"
run_world
status_is 1
out_has "CYFR could not download Ubuntu's package lists. Nothing was installed. Check the connection, then run \`$cmd_text\` again."
events_lack "install -y"
elevated_once_then_cleaned "$elevation"
verdict "a failed package-list update is refused, naming the connection"

make_world interrupted
printf 'interrupted\n' >"$w/apt-install"
run_world
status_is 1
out_has "CYFR could not finish installing cosign because an earlier package installation was interrupted. Nothing was installed. Finish it with \`sudo dpkg --configure -a\`, then run \`$cmd_text\` again."
elevated_once_then_cleaned "$elevation"
verdict "interrupted package work names its repair"

make_world offline
: >"$w/offline"
run_world
status_is 1
out_has "CYFR could not download cyfr_1.2.3_linux_amd64.tar.gz from github.com. CYFR installed cosign. Check the connection, then run \`$cmd_text\` again."
elevated_once_then_cleaned "$elevation"
not_installed "$w/usrlocal/cyfr"
tmp_is_empty
verdict "a download that fails after the packages names what was installed"

make_world bad-signature
printf '1\n' >"$w/cosign-exit"
run_world
status_is 1
out_has "cosign signature verification FAILED"
elevated_once_then_cleaned "$elevation"
not_installed "$w/usrlocal/cyfr"
tmp_is_empty
verdict "a signature that fails after elevation installs nothing, and sudo -k runs"

# Runs the installer as a terminal's foreground job would, with SIGINT at
# its default in a process group of its own; once the file $1 appears the
# whole group gets the interrupt the terminal sends.
interrupt_world_at() {
    # shellcheck disable=SC2046 # one assignment a line, no blanks
    python3 -I -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.setpgid(0, 0)
os.execvp(sys.argv[1], sys.argv[1:])' env -i $(world_env) /bin/sh -c 'CYFR_INSTALL_TEST=1; . "$1"; . "$2"; main' \
        sh "$INSTALL_SH" "$w/overrides" >"$w/out" 2>&1 </dev/null &
    group=$!
    waited=0
    while [ ! -e "$1" ] && [ "$waited" -lt 200 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    kill -INT "-$group" 2>/dev/null
    waited=0
    while kill -0 "$group" 2>/dev/null && [ "$waited" -lt 200 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if kill -0 "$group" 2>/dev/null; then
        kill -KILL "-$group" 2>/dev/null
        note "the interrupted run did not end"
    fi
    wait "$group"
    printf '%s\n' "$?" >"$w/status"
    sleep 0.2
    if kill -0 "-$group" 2>/dev/null; then
        note "processes of the run outlived it"
        kill -KILL "-$group" 2>/dev/null
    fi
}

make_world interrupt-download
: >"$w/hold"
interrupt_world_at "$w/at-download"
status_is 130
elevated_once_then_cleaned "$elevation"
not_installed "$w/usrlocal/cyfr"
tmp_is_empty
verdict "an interrupt during the download stops the waiting helper, runs sudo -k and removes the run's files"

make_world interrupt-apt
: >"$w/hold-apt"
interrupt_world_at "$w/at-apt"
status_is 130
elevated_once_then_cleaned "$elevation"
events_lack "curl"
not_installed "$w/usrlocal/cyfr"
tmp_is_empty
verdict "an interrupt reaches root's apt too, and the run ends only after root's side has"

# --- PATH migration ----------------------------------------------------------

# A world where the CLI goes to a writable CYFR_INSTALL_DIR, so the only
# question is the migration's, and an earlier copy sits in ~/.local/bin.
migration_world() {
    make_world "$1"
    with_cosign
    old="$w/home/.local/bin/cyfr"
    new="$w/usrlocal/cyfr"
    printf '#!/bin/sh\necho old cyfr\n' >"$old"
    chmod 755 "$old"
}

make_world migrate-accept
old="$w/home/.local/bin/cyfr"
new="$w/usrlocal/cyfr"
printf '#!/bin/sh\necho old cyfr\n' >"$old"
chmod 755 "$old"
printf 'y\ny\n' >"$w/tty"
run_world
status_is 0
out_has "Typing \`cyfr\` runs $old; the new version is at $new. Remove the earlier copy? [y/N] "
out_has "Removed $old."
out_has "Run \`hash -r\`, or open a new terminal, so that typing \`cyfr\` runs $new."
if [ -e "$old" ]; then
    note "the earlier copy is still there"
fi
installed_release "$new"
verdict "an earlier copy the person owns is removed on yes, after the verified install"

migration_world migrate-decline
printf 'n\n' >"$w/tty"
run_world CYFR_INSTALL_DIR="$w/usrlocal"
status_is 0
out_has "Typing \`cyfr\` runs $old; the new version is at $new. Remove the earlier copy? [y/N] "
out_has "Typing \`cyfr\` still runs $old. Run the new version as $new, for example \`$new init\`."
out_lacks "Removed"
if [ ! -f "$old" ]; then
    note "the declined copy is gone"
fi
verdict "a declined removal keeps the copy and gives the new path"

migration_world migrate-symlink
rm "$old"
printf '#!/bin/sh\n' >"$w/elsewhere"
chmod 755 "$w/elsewhere"
ln -s "$w/elsewhere" "$old"
run_world CYFR_INSTALL_DIR="$w/usrlocal"
status_is 0
out_lacks "Remove the earlier copy?"
out_has "Typing \`cyfr\` still runs $old, which is a symbolic link, so CYFR left it in place. Run the new version as $new, for example \`$new init\`."
if [ ! -h "$old" ]; then
    note "the link is gone"
fi
verdict "a symlinked copy is never removed, and the reason is named"

migration_world migrate-package
printf 'cyfr-legacy %s\n' "$old" >"$w/dpkg-files"
run_world CYFR_INSTALL_DIR="$w/usrlocal"
status_is 0
out_lacks "Remove the earlier copy?"
out_has "Typing \`cyfr\` still runs $old, which came from the cyfr-legacy package, so CYFR left it in place."
if [ ! -f "$old" ]; then
    note "the package's copy is gone"
fi
verdict "a package's copy is never removed, and the package is named"

migration_world migrate-foreign
printf '4242\n' >"$w/uid"
run_world CYFR_INSTALL_DIR="$w/usrlocal"
status_is 0
out_lacks "Remove the earlier copy?"
out_has "Typing \`cyfr\` still runs $old, which belongs to another account, so CYFR left it in place."
if [ ! -f "$old" ]; then
    note "another account's copy is gone"
fi
verdict "another account's copy is never removed"

migration_world migrate-changed
rm "$w/tty"
mkfifo "$w/tty"
(
    exec 9<>"$w/tty"
    waited=0
    while ! grep -F -q 'Remove the earlier copy?' "$w/out" 2>/dev/null && [ "$waited" -lt 200 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    printf '#!/bin/sh\necho replaced\n' >"$old.new"
    chmod 755 "$old.new"
    mv -f "$old.new" "$old"
    printf 'y\n' >&9
) &
answerer=$!
run_world CYFR_INSTALL_DIR="$w/usrlocal"
wait "$answerer"
status_is 0
out_has "Typing \`cyfr\` still runs $old, which changed after you were asked, so CYFR left it in place."
out_lacks "Removed"
if ! grep -q replaced "$old" 2>/dev/null; then
    note "the changed copy is gone"
fi
verdict "a copy that changed after the question is left"

migration_world migrate-yes
run_world CYFR_INSTALL_DIR="$w/usrlocal" CYFR_INSTALL_YES=1
status_is 0
out_lacks "Remove the earlier copy?"
out_has "Typing \`cyfr\` still runs $old. Run the new version as $new, for example \`$new init\`."
if [ ! -f "$old" ]; then
    note "CYFR_INSTALL_YES=1 removed the copy"
fi
verdict "CYFR_INSTALL_YES=1 approves the plan, not removing an earlier copy"

migration_world migrate-no-terminal
rm "$w/tty"
run_world CYFR_INSTALL_DIR="$w/usrlocal"
status_is 0
out_has "Typing \`cyfr\` still runs $old. Run the new version as $new, for example \`$new init\`."
if [ ! -f "$old" ]; then
    note "the copy was removed without a terminal"
fi
verdict "without a terminal the copy stays and the new path is given"


if [ "$failures" -gt 0 ]; then
    printf '\n%s test(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nAll install.sh verification tests passed\n'

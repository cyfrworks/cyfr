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
for tool in awk cat chmod cmp cp cut date dirname env flock grep gzip id ls mkdir mkfifo mktemp mv readlink rm sed sha256sum sleep tar tee touch tr; do
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

# A policy name assigned outside the block would override it however the
# block reads, so --check and a write refuse it, naming the line, and a
# write changes nothing; a line that only reads a policy name passes.
# shellcheck disable=SC2016 # planted shell text, not expanded here
for planted in "POLICY_LOCK_SECONDS=1" ': "${POLICY_INSTALL_PATH:=/tmp/cyfr}"' "export POLICY_LOCK_PATH=/tmp/lock" \
    "read -r POLICY_SYSTEM_ID <&8" "x=1; POLICY_SYSTEM_NAME=Other"; do
    cp "$INSTALL_SH" "$gen/assigned.sh"
    printf '%s\n' "$planted" >>"$gen/assigned.sh"
    cp "$gen/assigned.sh" "$gen/assigned.sh.before"
    desc="--check refuses '$planted' after the policy block, naming it"
    gen_out="$(python3 -I "$generator" --check --policy "$policy" --script "$gen/assigned.sh" 2>&1)"
    gen_status=$?
    case "$gen_status:$gen_out" in
        1:*"assign a policy name"*": $planted"*) pass "$desc" ;;
        *) fail_check "$desc" "exit $gen_status" "$gen_out" ;;
    esac
    desc="the generator refuses to write past '$planted', changing nothing"
    python3 -I "$generator" --policy "$policy" --script "$gen/assigned.sh" >/dev/null 2>&1
    gen_status=$?
    if [ "$gen_status" -eq 1 ] && cmp -s "$gen/assigned.sh" "$gen/assigned.sh.before"; then
        pass "$desc"
    else
        fail_check "$desc" "exit $gen_status"
    fi
done
cp "$INSTALL_SH" "$gen/reads.sh"
# shellcheck disable=SC2016 # planted shell text, not expanded here
printf '%s\n' 'printf "%s %s\n" "$POLICY_LOCK_SECONDS" "${POLICY_INSTALL_PATH%/*}"' '# POLICY_LOCK_SECONDS=1' >>"$gen/reads.sh"
desc="a line reading policy names and a comment naming one pass --check"
if gen_out="$(python3 -I "$generator" --check --policy "$policy" --script "$gen/reads.sh" 2>&1)"; then
    pass "$desc"
else
    fail_check "$desc" "$gen_out"
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
sh -c "$(cat "$text")" cyfr-install-helper run "$dir" "$dest" "$@" >"$dir/helper.out" 2>&1 &
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

# The show mode is the same program, run by the person for the preview:
# each command's words, one a line, an empty line after each, and nothing
# run, so no apt, no lock file and no installed copy.
shown_dir="$(mktemp -d "$helper/dir.XXXXXX")"
desc="the helper's show mode prints root's commands and runs none of them"
shown="$(sh -c "$(cat "$helper/text")" cyfr-install-helper show "$shown_dir" "$helper/dest/cyfr" cosign 2>&1 </dev/null)"
shown_status=$?
shown_want="flock
-E
75
-w
2
9

apt-get
update

apt-get
-o
DPkg::Lock::Timeout=2
install
-y
--no-install-recommends
cosign

flock
-E
75
-w
2
9

mktemp
$helper/dest/.cyfr.XXXXXX

cp
--
$shown_dir/cyfr
$helper/dest/.cyfr.XXXXXX

sha256sum
--
$helper/dest/.cyfr.XXXXXX

chmod
0755
$helper/dest/.cyfr.XXXXXX

mv
-f
-T
--
$helper/dest/.cyfr.XXXXXX
$helper/dest/cyfr"
if [ "$shown_status" -eq 0 ] && [ "$shown" = "$shown_want" ] && [ ! -s "$helper/apt.log" ] &&
    [ ! -e "$helper/install.lock" ] && [ -z "$(ls -A "$helper/dest")" ]; then
    pass "$desc"
else
    fail_check "$desc" "status $shown_status" "wanted: $shown_want" "got:    $shown" "apt: $(cat "$helper/apt.log")" "$(ls -A "$helper")"
fi
desc="the helper refuses a mode other than run and show"
sh -c "$(cat "$helper/text")" cyfr-install-helper root "$shown_dir" "$helper/dest/cyfr" cosign >"$helper/mode.out" 2>&1 </dev/null
mode_status=$?
if [ "$mode_status" -eq 64 ] && [ ! -s "$helper/mode.out" ] && [ ! -s "$helper/apt.log" ]; then
    pass "$desc"
else
    fail_check "$desc" "status $mode_status" "$(cat "$helper/mode.out")"
fi

# Runs one helper exchange in a fresh private directory holding the
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
desc="the helper's ended exchange left the installed copy"
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
# was asked to $w/events; the commands root runs also append their argv
# to $w/root-argv.
make_world() {
    w="$fixture/world-$1"
    mkdir -p "$w/bin" "$w/rootbin" "$w/sysbin" "$w/home/.local/bin" "$w/usrlocal" "$w/tmp" "$w/release"
    cp "$release"/cyfr_1.2.3_linux_amd64.tar.gz "$release"/checksums.txt "$release"/checksums.txt.sigstore.json "$w/release/"
    : >"$w/events"
    : >"$w/root-argv"
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
    # sudo keeps CYFR's root step, its one multi-line argument, in
    # root-step. Its modes print what sudo-rs 0.2.13 prints for each
    # refusal; a command other than /bin/sh, as install_binary's sudo cp,
    # is recorded and not run, since the test cannot be root.
    cat >"$w/bin/sudo" <<'EOF'
#!/bin/sh
W=${0%/*/*}
line=sudo
for arg in "$@"; do
    case "$arg" in
        *'
'*)
            line="$line <CYFR's root step>"
            printf '%s' "$arg" >"$W/root-step"
            ;;
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
        -*) echo "fake sudo: unexpected $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
case "$(cat "$W/sudo-mode" 2>/dev/null)" in
    wrong-password)
        echo "sudo: Authentication failed, try again." >&2
        echo "sudo: Authentication failed, try again." >&2
        echo "sudo: maximum 3 incorrect authentication attempts" >&2
        exit 1
        ;;
    not-allowed)
        echo "sudo: I'm sorry person. I'm afraid I can't do that" >&2
        exit 1
        ;;
    unknown)
        echo "sudo: account validation failure, is your account locked?" >&2
        exit 1
        ;;
    refuse-n)
        if [ "$noninteractive" = yes ]; then
            echo "sudo: interactive authentication is required" >&2
            exit 1
        fi
        ;;
esac
case "$1" in
    /bin/sh) exec env -i "$@" ;;
esac
exit 0
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
case "$0" in
    */rootbin/*) printf 'apt-get %s\n' "$*" >>"$W/root-argv" ;;
esac
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
            "${W%/*}/base/sleep" 30
        fi
        listed=no
        for arg in "$@"; do
            if [ "$listed" = yes ]; then
                printf '%s\n' "$arg" >>"$W/dpkg-installed"
                if [ "$arg" = cosign ]; then
                    "${W%/*}/base/cp" "$W/cosign-stub" "$W/sysbin/cosign"
                    "${W%/*}/base/chmod" 755 "$W/sysbin/cosign"
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
    # The rest of root's commands keep their argv and run the real tool;
    # flock also keeps the file its descriptor 9 is open on, and mktemp
    # the name it made.
    # shellcheck disable=SC2016 # the stub's own expansions
    for tool in flock mktemp cp sha256sum chmod mv; do
        {
            printf '#!/bin/sh\nW=${0%%/*/*}\n'
            printf 'printf "%%s\\n" "%s $*" >>"$W/root-argv"\n' "$tool"
            case "$tool" in
                flock) printf '"%s/readlink" "/proc/$$/fd/9" >>"$W/flock-fd9"\n' "$base" ;;
                mktemp) printf 'made=$("%s/mktemp" "$@") || exit\nprintf "%%s\\n" "$made" >"$W/mktemp-made"\nprintf "%%s\\n" "$made"\nexit 0\n' "$base" ;;
            esac
            printf 'exec "%s/%s" "$@"\n' "$base" "$tool"
        } >"$w/rootbin/$tool"
    done
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
    chmod +x "$w/bin/"* "$w/rootbin/"* "$w/cosign-stub"
    cat >"$w/overrides" <<EOF
OS_RELEASE_PATHS='$w/os-release'
TTY_DEVICE='$w/tty'
ROOT_PATH='$w/rootbin:$base'
PLAIN_INSTALL_DIRS='$w/homebrew $w/usrlocal'
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

# A clock for root's date and sleep: date prints the seconds in
# $w/clock and sleep adds its argument to them, at once.
# shellcheck disable=SC2016 # the stubs' own expansions
with_clock() {
    printf '1000\n' >"$w/clock"
    printf '#!/bin/sh\ncat "${0%%/*/*}/clock"\n' >"$w/rootbin/date"
    printf '#!/bin/sh\nW=${0%%/*/*}\nprintf "sleep %%s\\n" "$1" >>"$W/events"\necho $(($(cat "$W/clock") + $1)) >"$W/clock"\n' >"$w/rootbin/sleep"
    chmod +x "$w/rootbin/date" "$w/rootbin/sleep"
}

world_env() {
    printf '%s\n' "HOME=$w/home" "PATH=$w/home/.local/bin:$w/bin:$w/sysbin:$base:$w/usrlocal" "TMPDIR=$w/tmp" "CYFR_VERSION=1.2.3"
}

# Runs the installer's main in the world with the extra settings given as
# arguments; the output lands in $w/out and the status in $w/status. The
# timeout only ends a run that hangs.
run_world() {
    # shellcheck disable=SC2046 # one assignment a line, no blanks
    timeout 60 env -i $(world_env) "$@" /bin/sh -c 'CYFR_INSTALL_TEST=1; . "$1"; . "$2"; main' \
        sh "$INSTALL_SH" "$w/overrides" >"$w/out" 2>&1 </dev/null
    printf '%s\n' "$?" >"$w/status"
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
# Whether the output holds the text $1 whole: a text of several lines
# matches only as those lines, consecutive and in order, its first line
# the end of an output line and its last the start of one.
out_has() {
    case "$(cat "$w/out")" in
        *"$1"*) ;;
        *) note "output lacks: $1" ;;
    esac
}
out_lacks() {
    case "$(cat "$w/out")" in
        *"$1"*) note "output has: $1" ;;
    esac
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
    if [ -s "$w/root-argv" ]; then
        note "root ran $(cat "$w/root-argv")"
    fi
}
tmp_is_empty() {
    if [ -n "$(ls -A "$w/tmp")" ]; then
        note "the run left $(ls -A "$w/tmp") in its TMPDIR"
    fi
}
# Root's install: the release's cyfr, mode 0755 whatever the umask.
installed_release() {
    if ! cmp -s "$release/stage/cyfr" "$1" || [ "$(ls -ln "$1" | cut -c1-10)" != -rwxr-xr-x ]; then
        note "$1 is not the release's cyfr, mode 0755"
    fi
}
# install_binary's: the release's cyfr, executable by its owner, the rest
# of its mode the umask's.
installed_plain() {
    # shellcheck disable=SC2012 # one file the test made, its mode alone
    if ! cmp -s "$release/stage/cyfr" "$1" || [ "$(ls -ln "$1" | cut -c4)" != x ]; then
        note "$1 is not the release's cyfr, executable by its owner"
    fi
}
not_installed() {
    if [ -e "$1" ]; then
        note "$1 was installed"
    fi
}
# The private directory the run gave root's step, from sudo's arguments.
run_dir() {
    sed -n 's/^sudo .* cyfr-install-helper run \([^ ]*\) .*/\1/p' "$w/events" | head -n 1
}
# The commands the preview showed are the commands root ran, in order:
# the indented lines under its heading against root's argv as the world's
# stubs kept it, mktemp's name put back as its template; the step the
# preview names against sudo's arguments; and each flock's descriptor 9
# on the world's install lock.
shown_is_run() {
    awk '/^CYFR runs these commands as root:$/ { on = 1; next }
        on && /^  / { print substr($0, 3); next }
        on { exit }' "$w/out" >"$w/shown"
    made="$(cat "$w/mktemp-made" 2>/dev/null)"
    template="$(sed -n 's/^mktemp //p' "$w/root-argv" | head -n 1)"
    awk -v made="$made" -v template="$template" '{
        line = $0; out = ""
        while (made != "" && (i = index(line, made)) > 0) {
            out = out substr(line, 1, i - 1) template
            line = substr(line, i + length(made))
        }
        print out line
    }' "$w/root-argv" >"$w/ran"
    if [ ! -s "$w/shown" ] || ! cmp -s "$w/shown" "$w/ran"; then
        note "the preview's commands are not root's: shown
$(cat "$w/shown")
ran
$(cat "$w/ran")"
    fi
    shown_step="$(sed -n 's/^They run as one root step: //p' "$w/out")"
    ran_step="$(grep '^sudo .* /bin/sh -c ' "$w/events")"
    if [ -z "$shown_step" ] || [ "$shown_step" != "$ran_step" ]; then
        note "the preview names the step '$shown_step', and sudo ran '$ran_step'"
    fi
    if [ "$(sort -u "$w/flock-fd9" 2>/dev/null)" != "$w/install.lock" ]; then
        note "flock's descriptor 9 was $(cat "$w/flock-fd9" 2>/dev/null), not $w/install.lock"
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

# out_has matches a text of several lines whole: consecutive, in order.
w="$fixture/out-check"
mkdir "$w"
printf 'first line\nsecond line\nthird line\n' >"$w/out"
out_has "line
second line
thi"
verdict "out_has finds consecutive lines, the first and last partly"
out_has "first line
third line"
if [ -n "$problems" ]; then
    problems=
    pass "out_has refuses lines that are not consecutive"
else
    fail_check "out_has refuses lines that are not consecutive"
fi
out_has "second line
first line"
if [ -n "$problems" ]; then
    problems=
    pass "out_has refuses lines out of order"
else
    fail_check "out_has refuses lines out of order"
fi

elevation="sudo -k -- /bin/sh -c <CYFR's root step> cyfr-install-helper run "
lock_note="flock takes CYFR's install lock, $fixture/world-@/install.lock, open as file descriptor 9, waiting up to 2 seconds for another installation to finish."
retry_note="apt-get update is tried again each second, for up to 2 seconds, while another package-list update holds its lock."
binary_note="mktemp's name takes the place of XXXXXX, and mv runs only when sha256sum gives the verified download's SHA-256."
verify_note="The second flock and the commands after it run once the download passes the signature and checksum checks."
# The lock note for the current world.
world_lock_note() {
    printf '%s\n' "$lock_note" | sed "s|$fixture/world-@/|$w/|"
}

make_world fresh
run_world
status_is 0
d="$(run_dir)"
out_has "CYFR runs these commands as root:
  flock -E 75 -w 2 9
  apt-get update
  apt-get -o DPkg::Lock::Timeout=2 install -y --no-install-recommends cosign
  flock -E 75 -w 2 9
  mktemp $w/usrlocal/.cyfr.XXXXXX
  cp -- $d/cyfr $w/usrlocal/.cyfr.XXXXXX
  sha256sum -- $w/usrlocal/.cyfr.XXXXXX
  chmod 0755 $w/usrlocal/.cyfr.XXXXXX
  mv -f -T -- $w/usrlocal/.cyfr.XXXXXX $w/usrlocal/cyfr
$(world_lock_note)
$retry_note
$binary_note
$verify_note
They run as one root step: ${elevation}$d $w/usrlocal/cyfr cosign
Install these requirements? [y/N] "
out_has "cyfr v1.2.3 installed successfully to $w/usrlocal/cyfr"
shown_is_run
elevated_once_then_cleaned "$elevation"
event_line "apt-get update [clean-env]"
event_line "apt-get -o DPkg::Lock::Timeout=2 install -y --no-install-recommends cosign [clean-env]"
event_before "$elevation" "apt-get update"
event_before "apt-get update" "apt-get -o DPkg"
event_before "apt-get -o DPkg" "curl"
event_before "apt-get -o DPkg" "cosign verify-blob"
installed_release "$w/usrlocal/cyfr"
tmp_is_empty
verdict "a fresh image lacking cosign: one agreed elevation installs cosign before verification, then the verified cyfr, as the preview shows"
case "$(grep -F "$elevation" "$w/events")" in
    *" $w/usrlocal/cyfr cosign") pass "the elevation names the destination and the packages as its arguments" ;;
    *) fail_check "the elevation names the destination and the packages as its arguments" "$(grep -F "$elevation" "$w/events")" ;;
esac
desc="sudo's root step is the helper program, as the script writes it"
# shellcheck disable=SC2016 # expanded by the inner shell
if helper_text="$(sh -c 'CYFR_INSTALL_TEST=1; . "$1"; . "$2"; root_helper_text' sh "$INSTALL_SH" "$w/overrides" 2>&1)" &&
    printf '%s' "$helper_text" >"$w/helper-text" && cmp -s "$w/root-step" "$w/helper-text"; then
    pass "$desc"
else
    fail_check "$desc" "$(diff "$w/helper-text" "$w/root-step" 2>&1 | head -n 20)"
fi

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
shown_is_run
elevated_once_then_cleaned "sudo -n -k -- /bin/sh -c <CYFR's root step> cyfr-install-helper run "
installed_release "$w/usrlocal/cyfr"
verdict "CYFR_INSTALL_YES=1 without a terminal approves the displayed plan and elevates with sudo -n -k"

make_world yes-terminal
run_world CYFR_INSTALL_YES=1
status_is 0
out_has "CYFR_INSTALL_YES=1 approves these commands."
out_lacks "Install these requirements?"
shown_is_run
elevated_once_then_cleaned "$elevation"
installed_release "$w/usrlocal/cyfr"
verdict "CYFR_INSTALL_YES=1 in a terminal asks nothing, and sudo may ask for the password there"

make_world yes-needs-password
rm "$w/tty"
printf 'refuse-n\n' >"$w/sudo-mode"
run_world CYFR_INSTALL_YES=1
status_is 1
out_has "sudo: interactive authentication is required
sudo needs this account's password, and without a terminal there is nowhere to type it, so CYFR cannot install cosign and cyfr in $w/usrlocal. Nothing was installed. Run \`curl -fsSL https://raw.githubusercontent.com/cyfrworks/cyfr/main/scripts/install.sh | CYFR_VERSION=1.2.3 CYFR_INSTALL_YES=1 sh\` in a terminal, or give this account sudo without a password prompt."
out_lacks "cannot run sudo"
events_lack "apt-get"
elevated_once_then_cleaned "sudo -n -k -- /bin/sh -c <CYFR's root step> cyfr-install-helper run "
tmp_is_empty
verdict "sudo -n needing a password names the missing terminal, not a missing sudo"

make_world wrong-password
printf 'wrong-password\n' >"$w/sudo-mode"
run_world
status_is 1
out_has "sudo: maximum 3 incorrect authentication attempts
sudo did not accept the password, so CYFR cannot install cosign and cyfr in $w/usrlocal. Nothing was installed. Run \`$cmd_text\` again and type this account's password."
out_lacks "cannot run sudo"
events_lack "apt-get"
elevated_once_then_cleaned "$elevation"
tmp_is_empty
verdict "a password sudo refused three times is named as such, and sudo -k still runs"

make_world not-allowed
printf 'not-allowed\n' >"$w/sudo-mode"
run_world
status_is 1
out_has "sudo: I'm sorry person. I'm afraid I can't do that
This account cannot run sudo, so CYFR cannot install cosign and cyfr in $w/usrlocal. Nothing was installed. Run \`$cmd_text\` from an account that can install software."
events_lack "apt-get"
elevated_once_then_cleaned "$elevation"
verdict "an account sudo does not allow is told it cannot run sudo"

make_world sudo-unknown
printf 'unknown\n' >"$w/sudo-mode"
run_world
status_is 1
out_has "sudo: account validation failure, is your account locked?
sudo did not run CYFR's installer, so CYFR cannot install cosign and cyfr in $w/usrlocal. Nothing was installed. Run \`$cmd_text\` again once sudo works for this account."
out_lacks "cannot run sudo"
verdict "a sudo refusal of other words, in a terminal, claims no cause"

make_world sudo-unknown-no-terminal
rm "$w/tty"
printf 'unknown\n' >"$w/sudo-mode"
run_world CYFR_INSTALL_YES=1
status_is 1
out_has "sudo needs this account's password, and without a terminal there is nowhere to type it, so CYFR cannot install cosign and cyfr in $w/usrlocal."
verdict "a sudo -n refusal of other words is the password it could not ask for"

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
installed_plain "$w/opt/cyfr"
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
d="$(run_dir)"
out_has "CYFR runs these commands as root:
  flock -E 75 -w 2 9
  mktemp $w/usrlocal/.cyfr.XXXXXX
  cp -- $d/cyfr $w/usrlocal/.cyfr.XXXXXX
  sha256sum -- $w/usrlocal/.cyfr.XXXXXX
  chmod 0755 $w/usrlocal/.cyfr.XXXXXX
  mv -f -T -- $w/usrlocal/.cyfr.XXXXXX $w/usrlocal/cyfr
$(world_lock_note)
$binary_note
They run as one root step: ${elevation}$d $w/usrlocal/cyfr
Install these requirements? [y/N] "
out_lacks "apt-get update"
shown_is_run
events_lack "apt-get"
elevated_once_then_cleaned "$elevation"
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
out_has "
They run as one root step: /bin/sh -c <CYFR's root step> cyfr-install-helper run "
event_line "apt-get -o DPkg::Lock::Timeout=2 install -y --no-install-recommends cosign [person-env]"
installed_release "$w/usrlocal/cyfr"
verdict "as root packages still need agreement, and run without sudo"

# --- A verification bypass: the plain install, never root's -----------------

# Under a bypass on the supported system with every tool it needs, the CLI
# goes where resolve_install_dir puts it: the world's /usr/local/bin only
# when the person can write it, else ~/.local/bin.
if [ "$("$real_id" -u)" = 0 ]; then
    printf 'SKIP: a bypass with /usr/local/bin unwritable (the test runs as root, which writes every directory)\n'
else
    make_world bypass-home
    chmod 555 "$w/usrlocal"
    run_world CYFR_ALLOW_UNVERIFIED=1
    chmod 755 "$w/usrlocal"
    status_is 0
    out_has "Installing cyfr v1.2.3 (linux/amd64) to $w/home/.local/bin"
    out_has "cyfr v1.2.3 installed successfully to $w/home/.local/bin/cyfr"
    out_lacks "as root"
    out_lacks "signature and checksum checks"
    nothing_as_root
    not_installed "$w/usrlocal/cyfr"
    installed_plain "$w/home/.local/bin/cyfr"
    tmp_is_empty
    verdict "CYFR_ALLOW_UNVERIFIED=1 on Ubuntu 26.04 installs in ~/.local/bin as the person when /usr/local/bin is not theirs"
fi

make_world bypass-usrlocal
run_world CYFR_INSECURE_SKIP_VERIFY=1
status_is 0
out_has "Installing cyfr v1.2.3 (linux/amd64) to $w/usrlocal"
out_lacks "as root"
out_lacks "signature and checksum checks"
nothing_as_root
installed_plain "$w/usrlocal/cyfr"
verdict "CYFR_INSECURE_SKIP_VERIFY=1 on Ubuntu 26.04 copies into a /usr/local/bin the person can write, without root"

# Missing bootstrap packages under a bypass are still root's, and the CLI
# is not: the elevation carries no destination.
if [ "$("$real_id" -u)" != 0 ]; then
    make_world bypass-packages
    : >"$w/dpkg-installed"
    chmod 555 "$w/usrlocal"
    run_world CYFR_ALLOW_UNVERIFIED=1
    chmod 755 "$w/usrlocal"
    status_is 0
    d="$(run_dir)"
    out_has "CYFR runs these commands as root:
  flock -E 75 -w 2 9
  apt-get update
  apt-get -o DPkg::Lock::Timeout=2 install -y --no-install-recommends ca-certificates
$(world_lock_note)
$retry_note
They run as one root step: ${elevation}$d - ca-certificates
Install these requirements? [y/N] "
    out_lacks "signature and checksum checks"
    out_lacks "mktemp"
    shown_is_run
    elevated_once_then_cleaned "$elevation"
    not_installed "$w/usrlocal/cyfr"
    installed_plain "$w/home/.local/bin/cyfr"
    verdict "a bypass missing ca-certificates: root installs the package alone, and the CLI goes the plain way"
fi

# An explicit CYFR_INSTALL_DIR the person cannot write keeps install_binary's
# own sudo cp under a bypass, and no root step.
if [ "$("$real_id" -u)" != 0 ]; then
    make_world bypass-explicit
    mkdir "$w/locked"
    chmod 555 "$w/locked"
    run_world CYFR_ALLOW_UNVERIFIED=1 CYFR_INSTALL_DIR="$w/locked"
    chmod 755 "$w/locked"
    status_is 0
    out_has "Elevated permissions required to install to $w/locked"
    out_lacks "as root"
    if ! grep -q "^sudo cp $w/tmp/[^ ]*/cyfr $w/locked/cyfr\$" "$w/events" || ! grep -q -x -F "sudo chmod +x $w/locked/cyfr" "$w/events"; then
        note "install_binary's sudo cp and chmod did not run"
    fi
    events_lack "/bin/sh -c"
    events_lack "apt-get"
    verdict "a bypass with an unwritable CYFR_INSTALL_DIR keeps install_binary's sudo cp"
fi

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
if [ "$(cat "$w/root-argv")" != "flock -E 75 -w 2 9" ] || [ "$(cat "$w/flock-fd9" 2>/dev/null)" != "$w/install.lock" ]; then
    note "root did not wait on the install lock with flock -w 2 alone: $(cat "$w/root-argv")"
fi
elevated_once_then_cleaned "$elevation"
if ! kill -0 "$holder" 2>/dev/null || [ ! -e "$w/install.lock" ]; then
    note "the other installation's lock or its holder is gone"
fi
verdict "a held install lock refuses after flock's deadline, leaving the holder and its lock"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# The list lock's deadline runs on root's clock: refused when date reads
# the deadline, after one try at each second up to it.
make_world list-lock
with_clock
printf 'list-lock\n' >"$w/apt-update"
run_world
status_is 1
out_has "A package-list update is still running after 2 seconds. Nothing was installed. Let it finish, then run \`$cmd_text\` again."
if [ "$(grep -c -x -F 'apt-get update' "$w/root-argv")" != 3 ] || [ "$(grep -c -x -F 'sleep 1' "$w/events")" != 2 ]; then
    note "not three tries a second apart: $(cat "$w/root-argv") $(grep sleep "$w/events")"
fi
events_lack "install -y"
elevated_once_then_cleaned "$elevation"
verdict "the package-list lock is retried each second until its deadline, then refused"

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

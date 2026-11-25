#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The tag pipeline's graph: .github/workflows/release.yml publishes nothing
# unless all six verification workflows passed and the tag names the
# version apps/prima/mix.exs declares, can neither be cancelled nor let a
# failure pass, builds both images for both platforms with the scan reading
# the loaded image and each image's upgrade layer keyed on the archive's
# key (scripts/apt-key.sh, APT_REFRESH in both Dockerfiles), boots each loaded image on its
# platform's runner before its digest is uploaded, merges each image's two digests
# by exact name, attests the merge's printed digest and hands it to the
# CLI release, which pins the scaffold's compose to the merged digests,
# writes release.json with the schema fingerprint its merged cyfr image
# answers, checks it and signs it before GoReleaser attaches both, has every
# command line binary checked before it is archived
# (scripts/ci/release-binary-check.sh), builds, installs and smokes the
# CYFR app's five installers on each system's and architecture's own
# runner (the Linux DEBs and the Windows MSIs with nothing to publish
# with, the Apple silicon DMG signed and notarised by desktop-mac.yml,
# which alone receives the Apple inputs, each by its name), hands all five
# to the CLI release by exact name, which checks them and the Homebrew
# cask it writes from the DMG's bytes before GoReleaser sums and attaches
# them, lets no job that publishes (the images' merge, the release and its
# tap, the provenance) go without the installers job's check of the five
# and the cask, reads
# each installed executable's architecture, keeps the tap moving forward
# only and its token out of git's arguments, and grants each job only what
# it needs and each secret only where it is read. The build, and the
# publication test in test.yml's static job, first switch the runner's
# Docker daemon to the containerd image store, which alone can load an
# image carrying its attestation.
#
# A release version is one rule, SEMVER, which tests/fixtures/
# release_manifest.json's versions hold: MAJOR.MINOR.PATCH, or the same with
# a SemVer pre-release (0.6.0-alpha.1). A pre-release publishes as a GitHub
# pre-release (.goreleaser.yml's prerelease: auto) and never reaches the
# Homebrew tap.
#
# The checks run on the real files, then on fixtures and on mutants of the
# real files, each of which must be refused, so a check that stops checking
# fails here. Beside reading files, they execute the tag check's step under
# bash against the real tree and planted ones declaring each of the
# vectors' versions, the Homebrew step against a stub git for each accepted
# version, scripts/scaffold-tarball.sh into temporary directories for each
# version and scripts/release.sh in disposable repositories for each
# version, and check the manifest rules and SEMVER against the vectors. The scripts that match a version run under a locale whose ranges
# admit letters outside ASCII where the host has one, so only their own
# LC_ALL=C keeps their match to ASCII. Needs PyYAML for this mode.
#
# The release job's installers mode checks, without PyYAML, that the
# folder GoReleaser sums and attaches holds exactly the five installers at
# the tag's version and that the cask names the DMG by its own digest,
# installing CYFR.app and linking its cyfr and nothing else.
#
# The release job's own mode checks the manifest it wrote, without PyYAML:
# its shape by the vector file's rules (the schema fingerprint among them), its version against the tag, its
# scaffold digest against the tarball's, its Caddy and Tailscale digests
# against the ones docker-compose.yml pins (third-party images the release
# does not build), and the tarball's compose against its image digests.
#
# Usage: python3 -I tests/ci-release-graph.py
#        python3 -I tests/ci-release-graph.py --manifest FILE --version VERSION --scaffold TARBALL
#        python3 -I tests/ci-release-graph.py --installers FOLDER --version VERSION --cask FILE
import copy
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASE = os.path.join(ROOT, ".github", "workflows", "release.yml")
TEST = os.path.join(ROOT, ".github", "workflows", "test.yml")
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
ACTIONS = os.path.join(ROOT, ".github", "actions")
IMAGE_BUILD = "./.github/actions/image-build"
GORELEASER = os.path.join(ROOT, "apps", "codex", ".goreleaser.yml")
COMPOSE = os.path.join(ROOT, "docker-compose.yml")
MIX_EXS = os.path.join("apps", "prima", "mix.exs")
VECTORS = os.path.join(ROOT, "tests", "fixtures", "release_manifest.json")

VERIFY = {
    "./.github/workflows/%s.yml" % n
    for n in ["test", "dialyzer", "codex-ci", "keeper-ci", "license-lint", "security"]
}
TERM_OK = re.compile(r"^github\.(repository|ref)\s*==\s*'[^']*'$")


# --- the graph: no publication without the six checks ---


def if_allowed(expr):
    """No condition, or a conjunction of repository/ref equalities with at
    most one bare success(); never ||, !, always(), failure() or cancelled()."""
    if expr is None:
        return True
    e = str(expr).strip()
    if e.startswith("${{") and e.endswith("}}"):
        e = e[3:-2].strip()
    if "||" in e or "!" in e.replace("!=", "") or "!=" in e:
        return False
    terms = [t.strip() for t in e.split("&&")]
    successes = [t for t in terms if t == "success()"]
    return len(successes) <= 1 and all(t == "success()" or TERM_OK.match(t) for t in terms)


def needs_of(job):
    n = job.get("needs", [])
    return [n] if isinstance(n, str) else list(n)


def check_graph(wf):
    jobs = wf["jobs"]
    verify = {j for j, job in jobs.items() if job.get("uses") in VERIFY}
    if {jobs[j]["uses"] for j in verify} != VERIFY:
        return "the six checks are not all called"

    def ancestors(j, seen=None):
        seen = set() if seen is None else seen
        for n in needs_of(jobs[j]):
            if n not in seen:
                seen.add(n)
                ancestors(n, seen)
        return seen

    for j, job in jobs.items():
        missing = [n for n in needs_of(job) if n not in jobs]
        if missing:
            return f"{j} needs {missing}, which are not jobs"
    # A cycle of needs is a workflow GitHub never runs.
    for j in jobs:
        if j in ancestors(j):
            return f"{j} needs itself through its needs, so the workflow never runs"
    for j in jobs:
        if j in verify:
            continue
        # The tag check publishes nothing and runs beside the checks;
        # check_tag holds it to its one comparison.
        if not verify <= ancestors(j) and j != TAG_JOB:
            return f"{j} does not depend on every check"
        for k in {j} | (ancestors(j) - verify):
            if not if_allowed(jobs[k].get("if")):
                return f"{k} has a condition outside the allowed forms: {jobs[k].get('if')!r}"
    if wf.get("concurrency", {}).get("cancel-in-progress") not in (False, "false"):
        return "tag runs can be cancelled"
    for j, job in jobs.items():
        if j not in verify and "uses" not in job and "timeout-minutes" not in job:
            return f"{j} has no timeout"
    return None


# --- the run's shape: what the graph does not read ---

# The one step allowed to fail on: the Homebrew tap push, after the release.
HOMEBREW = "Publish Homebrew cask to tap"
# A failure turned into success: `|| true` or `|| :`.
IGNORED = re.compile(r"\|\|\s*(true|:)(?=\s|;|\)|$)", re.MULTILINE)
# The CLI release's permissions, which it may narrow and never widen.
RELEASE_PERMISSIONS = {"contents": "write", "id-token": "write", "attestations": "write"}
IMAGES = {"cyfr": "Dockerfile", "cyfr-locus": "Dockerfile.locus"}
PUSH_BY_DIGEST = (
    "type=image,name=${{ env.REGISTRY }}/${{ matrix.image }},"
    "push-by-digest=true,name-canonical=true,push=true"
)
LOAD = "type=docker,name="
# The boot of each loaded image on its platform's runner
# (scripts/ci/image-boots.sh), before its digest is uploaded.
BOOT_RUN = 'scripts/ci/image-boots.sh "$IMAGE" "$LOADED"'
# The upgrade layer's cache key: one build argument, the output of a step
# that writes the archive's key (scripts/apt-key.sh) on every run, so each
# image's upgrade is built on what Debian's archive holds (Dockerfile and
# Dockerfile.locus read it as ARG APT_REFRESH).
APT_KEY_READ = "apt_key=$(scripts/apt-key.sh)"
APT_ARG = re.compile(r"^APT_REFRESH=\$\{\{ steps\.([\w-]+)\.outputs\.([\w-]+) \}\}$")
OUTPUT_LINE = re.compile(r'^echo "[\w-]+=[^"]*" >> "\$GITHUB_OUTPUT"$')
# The layer's RUN, continued lines and all, runs the key's guard on
# APT_REFRESH before it upgrades.
APT_UPGRADE = re.compile(
    r"^RUN --mount=type=bind,source=scripts/apt-key\.sh,target=(\S+) \\\n"
    r"\s+bash \1 --update \"\$\{APT_REFRESH\}\" && apt-get upgrade",
    re.MULTILINE,
)
# The switch to the containerd image store. It restarts the daemon, so it
# precedes buildx's builder and every build.
STORE_SWITCH = "sudo scripts/ci/containerd-image-store.sh"
PUBLISH_TEST = "bash tests/ci-publish-test.sh"
# The tags that start the workflow, as GitHub's filter patterns: a release
# version, and one with a pre-release. They admit more than SEMVER does;
# the tag check is the exact one.
TAG_FILTERS = ["[0-9]+.[0-9]+.[0-9]+", "[0-9]+.[0-9]+.[0-9]+-*"]
# The tag check: a job of its own, its checkout and the one comparison of
# $GITHUB_REF_NAME with the version apps/prima/mix.exs declares, which
# matches SEMVER under LC_ALL=C.
TAG_JOB = "version"
TAG_COMPARISON = '"$GITHUB_REF_NAME" != "${declared[0]}"'
C_LOCALE = "export LC_ALL=C"
# The merge job hands its printed digest to the CLI release.
RECORD_RUN = 'mkdir -p merged\necho "$DIGEST" > merged/digest'
MERGED_UPLOAD = {
    "name": "merged-${{ matrix.image }}",
    "path": "merged/digest",
    "if-no-files-found": "error",
    "retention-days": 1,
}
MERGED_DOWNLOADS = {
    "merged-cyfr": "${{ runner.temp }}/merged/cyfr",
    "merged-cyfr-locus": "${{ runner.temp }}/merged/cyfr-locus",
}
# The CLI release's manifest steps, in this order: the scaffold pinned to
# the merged digests, release.json written once, checked, then signed.
# release.json and its bundle live outside the checkout, in
# $RUNNER_TEMP/release, which GoReleaser's step names to .goreleaser.yml.
# Both signatures run through scripts/ci/retry.sh: a keyless signing is
# safe to repeat, and a transparency log too slow to answer fails one run.
SCAFFOLD_RUN = """set -euo pipefail
cyfr=$(cat "$RUNNER_TEMP/merged/cyfr/digest")
locus=$(cat "$RUNNER_TEMP/merged/cyfr-locus/digest")
bash scripts/scaffold-tarball.sh apps/codex/cyfr-scaffold.tar.gz "$GITHUB_REF_NAME" "$cyfr" "$locus"
"""
MANIFEST_OUT = '> "$RUNNER_TEMP/release/release.json"\n'
# The manifest step reads the schema fingerprint from the release's own
# cyfr image, by the merged digest, and writes it as schema_fingerprint.
SCHEMA_READ = (
    """schema=$(docker run --rm -e CYFR_ACCESS=local -e "CYFR_SECRET_KEY_BASE=$(openssl rand -hex 48)" """
    """"ghcr.io/cyfrworks/cyfr@$cyfr" bin/cyfr eval 'IO.puts("CYFR_SCHEMA=" <> Arca.SchemaFingerprint.current())' """
    """| sed -n 's/^CYFR_SCHEMA=//p')"""
)
SCHEMA_ARG = '--arg schema "$schema" \\'
SCHEMA_KEY = "schema_fingerprint: $schema}"
VALIDATE_RUN = (
    'python3 -I tests/ci-release-graph.py --manifest "$RUNNER_TEMP/release/release.json" '
    '--version "$GITHUB_REF_NAME" --scaffold apps/codex/cyfr-scaffold.tar.gz'
)
SIGN_RUN = (
    'scripts/ci/retry.sh cosign sign-blob --yes --new-bundle-format '
    '--bundle "$RUNNER_TEMP/release/release.json.sigstore.json" '
    '"$RUNNER_TEMP/release/release.json"'
)
MANIFEST_DIR_ENV = {"RELEASE_MANIFEST_DIR": "${{ runner.temp }}/release"}
# The Homebrew cask, written from the downloaded DMG's bytes outside the
# checkout, then checked with the folder of installers before GoReleaser
# sums and attaches them: nothing is published unless both pass.
CASK_SCRIPT = os.path.join(ROOT, "scripts", "ci", "homebrew-cask.sh")
CASK_URL_BASE = "https://github.com/cyfrworks/cyfr/releases/download/#{version}"
CASK_RUN = """set -euo pipefail
mkdir -p "$RUNNER_TEMP/checked/cask"
bash scripts/ci/homebrew-cask.sh "$GITHUB_REF_NAME" "$RUNNER_TEMP/checked/packages" '%s' > "$RUNNER_TEMP/checked/cask/cyfr.rb"
""" % CASK_URL_BASE
INSTALLERS_RUN = (
    'python3 -I tests/ci-release-graph.py --installers "$RUNNER_TEMP/checked/packages" '
    '--version "$GITHUB_REF_NAME" --cask "$RUNNER_TEMP/checked/cask/cyfr.rb"'
)
# The CYFR app's Linux package: a job of its own, held to exactly these
# steps in this order, so that what is published is what was installed and
# smoked, built as the release builds cyfr and from no cache.
PACKAGE_JOB = "linux-package"
PACKAGE_ARCHES = ("amd64", "arm64")
PACKAGE_MATRIX = [
    {"arch": "amd64", "runner": "ubuntu-24.04"},
    {"arch": "arm64", "runner": "ubuntu-24.04-arm"},
]
PACKAGE_STEPS = [
    ("actions/checkout", {"fetch-depth": 0, "persist-credentials": False}),
    ("actions/setup-go", {"go-version-file": "apps/codex/go.mod", "cache": False}),
    ("actions/setup-node", {"node-version": 24, "package-manager-cache": False}),
    ("run", 'mkdir -p "$RUNNER_TEMP/cyfr"'),
    ("goreleaser/goreleaser-action", None),
    ("run", """set -euo pipefail
cd apps/codex/desktop
npm ci --ignore-scripts --no-audit --no-fund
node scripts/build.mjs --cyfr "$RUNNER_TEMP/cyfr/cyfr" --version "$GITHUB_REF_NAME" --arch "$ARCH" --out "$RUNNER_TEMP/package"
"""),
    ("run", 'bash tests/desktop-proof/native/linux.sh "$RUNNER_TEMP/package/cyfr-desktop_${GITHUB_REF_NAME}_linux_${ARCH}.deb"'),
    ("run", 'bash tests/desktop-proof/native/installed-version.sh /usr/bin/cyfr "$GITHUB_REF_NAME"'),
    ("run", 'bash tests/desktop-proof/native/installed-machine.sh "$ARCH" /opt/cyfr/CYFR /usr/bin/cyfr'),
    ("actions/upload-artifact", {
        "name": "cyfr-desktop-linux-${{ matrix.arch }}",
        "path": "${{ runner.temp }}/package/cyfr-desktop_${{ github.ref_name }}_linux_${{ matrix.arch }}.deb",
        "if-no-files-found": "error",
        "retention-days": 1,
    }),
]
PACKAGE_BUILD_ARGS = "build --single-target --clean --output ${{ runner.temp }}/cyfr/cyfr"
# The CYFR app's five installers, Linux's and Windows' packages for amd64
# and arm64 and the Mac's for Apple silicon alone, which the release
# downloads by exact name into one folder and GoReleaser sums and attaches
# from it.
INSTALLER_KINDS = {"linux": "deb", "darwin": "dmg", "windows": "msi"}
INSTALLER_ARCHES = {"linux": PACKAGE_ARCHES, "darwin": ("arm64",), "windows": PACKAGE_ARCHES}
INSTALLERS = [(system, arch) for system in INSTALLER_KINDS for arch in INSTALLER_ARCHES[system]]


def installer_name(version, system, arch):
    return f"cyfr-desktop_{version}_{system}_{arch}.{INSTALLER_KINDS[system]}"


PACKAGE_DOWNLOADS = {f"cyfr-desktop-{s}-{a}": "${{ runner.temp }}/checked/packages" for s, a in INSTALLERS}
# The one check before anything is published: the installers job, which
# downloads the five, writes the cask from the DMG, checks both and hands
# them on as one artifact, which the CLI release downloads alone.
INSTALLERS_JOB = "installers"
CHECKED = "checked-installers"
CHECKED_DOWNLOAD = {CHECKED: "${{ runner.temp }}/checked"}
PACKAGES_DIR_ENV = {"RELEASE_PACKAGES_DIR": "${{ runner.temp }}/checked/packages"}
PACKAGE_GLOBS = ["{{ .Env.RELEASE_PACKAGES_DIR }}/" + installer_name("{{ .Version }}", s, a) for s, a in INSTALLERS]
# The release's written note, the annotated tag's message beneath its
# subject (scripts/release.sh writes it from --notes): the version job
# refuses a tag that carries none, and the release job writes it beside
# release.json for GoReleaser to publish as the release's notes.
RELEASE_NOTE_SH = os.path.join(ROOT, "scripts", "ci", "release-note.sh")
NOTE_CHECK_RUN = 'scripts/ci/release-note.sh "$GITHUB_REF_NAME" "$GITHUB_SHA" "$RUNNER_TEMP/release-note.md"'
NOTE_WRITE_RUN = 'scripts/ci/release-note.sh "$GITHUB_REF_NAME" "$GITHUB_SHA" "$RUNNER_TEMP/release/notes.md"'
GORELEASER_ARGS = "release --clean --release-notes ${{ runner.temp }}/release/notes.md"
# .goreleaser.yml's release attaches the scaffold from its workdir,
# apps/codex, and the manifest and its bundle from RELEASE_MANIFEST_DIR
# alone: an unset variable or a missing file fails the release.
SCAFFOLD_GLOB = "cyfr-scaffold.tar.gz"
# GoReleaser's signature over checksums.txt, as the protobuf bundle, with
# retry.sh's path from GoReleaser's workdir, apps/codex.
CHECKSUM_SIGN_CMD = "../../scripts/ci/retry.sh"
CHECKSUM_SIGN_ARGS = ["cosign", "sign-blob", "--new-bundle-format", "--bundle=${signature}", "${artifact}", "--yes"]
MANIFEST_GLOBS = [
    "{{ .Env.RELEASE_MANIFEST_DIR }}/release.json",
    "{{ .Env.RELEASE_MANIFEST_DIR }}/release.json.sigstore.json",
]
# GoReleaser refuses a dirty tree, so what the job writes into the
# checkout before it runs is ignored by git.
CHECKOUT_WRITES = ["apps/codex/" + SCAFFOLD_GLOB]

DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
FINGERPRINT = re.compile(r"[0-9a-f]{64}")
# The one rule for a release version: MAJOR.MINOR.PATCH without leading
# zeros, optionally a SemVer pre-release, no build metadata, ASCII only.
# Always used with fullmatch, since $ also matches before a final newline,
# and spelled with [0-9], since \d admits digits outside ASCII.
SEMVER = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?"
)
RELEASE_VERSION = "release version (MAJOR.MINOR.PATCH, or with a pre-release)"
IMAGE_LINE = re.compile(r"^(\s*image:\s*)(\S+)\s*$")
CYFR_REPO = "ghcr.io/cyfrworks/cyfr"
LOCUS_REPO = "ghcr.io/cyfrworks/cyfr-locus"
# The third-party images the compose pins and the manifest names by the
# compose's digest: each manifest key and the repository its image line
# names.
PINNED_REPOS = {"caddy": "caddy", "tailscale": "tailscale/tailscale"}


def steps_using(job, action):
    return [s for s in job.get("steps", []) if str(s.get("uses", "")).split("@")[0] == action]


def steps_running(job, script):
    return [s for s in job.get("steps", []) if script in str(s.get("run", ""))]


def step_index(job, predicate):
    return next((i for i, s in enumerate(job.get("steps", [])) if predicate(s)), None)


def check_failures_pass_nothing(wf):
    if wf.get("concurrency", {}).get("group") != "publish-${{ github.ref }}":
        return "the concurrency group is not publish-${{ github.ref }}"
    for j, job in wf["jobs"].items():
        if "concurrency" in job:
            return f"{j} has a concurrency of its own"
        if "continue-on-error" in job:
            return f"{j} has a job-level continue-on-error"
        if job.get("secrets") == "inherit":
            return f"{j} passes every secret on"
        for s in job.get("steps", []):
            if s.get("name") == HOMEBREW:
                continue
            if "continue-on-error" in s:
                return f"{j}'s step {s.get('name') or s.get('uses')!r} has continue-on-error"
            if IGNORED.search(str(s.get("run", ""))):
                return f"{j}'s step {s.get('name')!r} ignores a failure"
    return None


def check_store_switch(job, before, what):
    steps = job.get("steps", [])
    at = [i for i, s in enumerate(steps) if "containerd-image-store.sh" in str(s.get("run", ""))]
    if len(at) != 1:
        return f"not one step switches to the containerd image store before {what}"
    step = steps[at[0]]
    if str(step.get("run", "")).strip() != STORE_SWITCH:
        return f"the store switch runs {step.get('run')!r}, not {STORE_SWITCH!r}"
    if "if" in step:
        return f"the store switch runs only if {step['if']}"
    if "continue-on-error" in step:
        return "the store switch has continue-on-error"
    first = step_index(job, before)
    if first is None or at[0] > first:
        return f"the store switch does not come before {what}"
    return None


def check_build(wf):
    jobs = wf["jobs"]
    builds = [j for j, job in jobs.items() if steps_using(job, "docker/build-push-action")]
    if len(builds) != 1:
        return f"not one image build job: {builds}", None
    name = builds[0]
    job = jobs[name]
    strategy = job.get("strategy", {})
    matrix = strategy.get("matrix", {})
    if sorted(matrix.get("image", [])) != sorted(IMAGES):
        return f"the build matrix images are {matrix.get('image')}", name
    if sorted(matrix.get("platform", [])) != ["linux/amd64", "linux/arm64"]:
        return f"the build matrix platforms are {matrix.get('platform')}", name
    rows = {r["image"]: r.get("file") for r in matrix.get("include", []) if "image" in r}
    if rows != IMAGES:
        return f"the build matrix files are {rows}", name
    if strategy.get("fail-fast") is False:
        return "one failed build does not stop the others", name

    steps = steps_using(job, "docker/build-push-action")
    if len(steps) != 1:
        return "the build job does not build once", name
    inputs = steps[0].get("with", {})
    if any(k in inputs for k in ("push", "load", "tags")):
        return "the build step sets push, load or tags beside outputs", name
    if inputs.get("provenance") != "mode=max":
        return f"the build's provenance is {inputs.get('provenance')!r}, not mode=max", name
    reason = check_store_switch(
        job,
        lambda s: str(s.get("uses", "")).split("@")[0] in ("docker/setup-buildx-action", "docker/build-push-action"),
        "buildx's builder and the build",
    )
    if reason:
        return reason, name
    reason = check_apt_refresh(job, inputs)
    if reason:
        return reason, name
    outputs = [o.strip() for o in str(inputs.get("outputs", "")).splitlines() if o.strip()]
    if (
        len(outputs) != 2
        or not outputs[0].startswith(LOAD)
        or "," in outputs[0][len(LOAD):]
        or outputs[1] != PUSH_BY_DIGEST
    ):
        return f"the build outputs are {outputs}", name
    loaded = outputs[0][len(LOAD):]
    host = loaded.split("/")[0]
    if "/" not in loaded or "." in host or ":" in host or host == "localhost":
        return f"the loaded image {loaded} names a registry", name

    scans = steps_using(job, "aquasecurity/trivy-action")
    if len(scans) != 1 or scans[0].get("env", {}).get("TRIVY_IMAGE_SRC") != "docker":
        return "the scan can read an image the build did not load", name
    if str(scans[0].get("with", {}).get("exit-code")) != "1":
        return f"the scan's exit-code is {scans[0].get('with', {}).get('exit-code')!r}, not '1'", name
    if scans[0].get("with", {}).get("image-ref") != loaded:
        return "the scan reads another image than the loaded one", name
    if not steps_running(job, "scripts/ci/scanned-is-pushed.sh"):
        return "the build does not prove the scanned image is the pushed one", name
    order = [
        step_index(job, lambda s: "aquasecurity/trivy-action" in str(s.get("uses"))),
        step_index(job, lambda s: "scripts/ci/scanned-is-pushed.sh" in str(s.get("run"))),
        step_index(job, lambda s: "actions/upload-artifact" in str(s.get("uses"))),
    ]
    if None in order or order != sorted(order):
        return "the digest is not uploaded after the scan and the comparison", name
    boots = steps_running(job, "scripts/ci/image-boots.sh")
    if len(boots) != 1 or str(boots[0].get("run", "")).strip() != BOOT_RUN:
        return f"the loaded image is not booted once by {BOOT_RUN!r}", name
    if "if" in boots[0]:
        return f"the boot runs only if {boots[0]['if']}", name
    if boots[0].get("env") != {"IMAGE": "${{ matrix.image }}", "LOADED": loaded}:
        return f"the boot starts {boots[0].get('env')}, not {loaded} as its matrix image", name
    boot = step_index(job, lambda s: "scripts/ci/image-boots.sh" in str(s.get("run")))
    if boot > order[2]:
        return "the digest is uploaded before the image booted", name
    return None, name


def check_apt_refresh(job, inputs):
    args = str(inputs.get("build-args", "")).strip()
    match = APT_ARG.match(args)
    if not match:
        return f"the build's build-args are {args!r}, not APT_REFRESH from a step's output"
    step_id, output = match.groups()
    written = f'echo "{output}=$apt_key" >> "$GITHUB_OUTPUT"'
    steps = job.get("steps", [])
    at = step_index(job, lambda s: s.get("id") == step_id)
    build = step_index(job, lambda s: "docker/build-push-action" in str(s.get("uses")))
    if at is None:
        return f"no step {step_id} writes the build's APT_REFRESH"
    step = steps[at]
    if "if" in step:
        return f"the step {step_id} that writes APT_REFRESH runs only if {step['if']}"
    if at > build:
        return f"the step {step_id} that writes APT_REFRESH runs after the build"
    # The key is read and written on two lines together, and every line
    # before them writes an output and nothing else, so nothing in the step
    # can end it before the key is written.
    lines = [line.strip() for line in str(step.get("run", "")).splitlines() if line.strip()]
    if APT_KEY_READ not in lines or lines[lines.index(APT_KEY_READ) + 1 :][:1] != [written]:
        return f"the step {step_id} does not write {output} as the archive's key"
    at_key = lines.index(APT_KEY_READ)
    for line in lines[:at_key]:
        if not OUTPUT_LINE.match(line):
            return f"the step {step_id} runs {line!r} before it writes the key"
    # A later write of the same output would replace the key.
    for line in lines[at_key + 2 :]:
        if re.search(rf"(?<![\w-]){re.escape(output)}=", line):
            return f"the step {step_id} writes {output} again after the key: {line!r}"
    return None


# The ARG must be declared in the upgrade layer's own stage, between its
# FROM and the RUN: an ARG above the FROM, or in another stage, leaves
# ${APT_REFRESH} empty there, and the layer is served from cache forever.
def check_apt_layers(dockerfiles):
    for path, text in dockerfiles.items():
        layer = APT_UPGRADE.search(text)
        if layer is None:
            return f"{path} has no apt-get upgrade layer that guards ${{APT_REFRESH}} with scripts/apt-key.sh"
        stage = [m.end() for m in re.finditer(r"^FROM\b.*$", text[: layer.start()], re.MULTILINE)]
        if not stage or not re.search(r"^ARG APT_REFRESH\b", text[stage[-1] : layer.start()], re.MULTILINE):
            return f"{path}'s apt-get upgrade layer does not read an ARG APT_REFRESH of its own stage"
    return None


# Every image build in CI but release.yml's (check_build holds that one) is
# made through the one action, .github/actions/image-build, whose build
# reads APT_REFRESH from the archive's key as release.yml's does: no step
# of another workflow or composite action uses build-push-action or
# bake-action or runs a build of its own.
BUILD_ACTIONS = ("docker/build-push-action", "docker/bake-action")
BUILD_RUN = re.compile(r"\b(docker\s+(buildx\s+)?build|docker\s+image\s+build|buildx\s+bake)\b")


def check_ci_builds(workflows, actions):
    for name, doc in sorted(workflows.items()):
        if name == "release.yml":
            continue
        for job_name, job in (doc.get("jobs") or {}).items():
            for step in job.get("steps") or []:
                where = f"{name} {job_name}: '{step.get('name', step.get('uses', 'a step'))}'"
                if any(a in str(step.get("uses", "")) for a in BUILD_ACTIONS) or BUILD_RUN.search(str(step.get("run", ""))):
                    return f"{where} builds an image other than through {IMAGE_BUILD}"
    for name, doc in sorted(actions.items()):
        steps = (doc.get("runs") or {}).get("steps") or []
        for step in steps:
            builds = any(a in str(step.get("uses", "")) for a in BUILD_ACTIONS) or BUILD_RUN.search(str(step.get("run", "")))
            if name != "image-build" and builds:
                return f"the {name} action's '{step.get('name', 'a step')}' builds an image other than through {IMAGE_BUILD}"
    image_build = actions.get("image-build")
    if image_build is None:
        return f"there is no {IMAGE_BUILD} action"
    job = {"steps": (image_build.get("runs") or {}).get("steps") or []}
    builds = steps_using(job, "docker/build-push-action")
    if len(builds) != 1 or any(BUILD_RUN.search(str(s.get("run", ""))) for s in job["steps"]):
        return f"{IMAGE_BUILD} does not build once, through build-push-action"
    reason = check_apt_refresh(job, builds[0].get("with") or {})
    return f"{IMAGE_BUILD}: {reason}" if reason else None


def ci_build_sources():
    import yaml

    workflows, actions = {}, {}
    for entry in sorted(os.listdir(WORKFLOWS)):
        if entry.endswith((".yml", ".yaml")):
            with open(os.path.join(WORKFLOWS, entry)) as f:
                workflows[entry] = yaml.safe_load(f) or {}
    for entry in sorted(os.listdir(ACTIONS)):
        for file in ("action.yml", "action.yaml"):
            path = os.path.join(ACTIONS, entry, file)
            if os.path.exists(path):
                with open(path) as f:
                    actions[entry] = yaml.safe_load(f) or {}
    return workflows, actions


def arg_above_stage(text):
    layer = APT_UPGRADE.search(text)
    stage = list(re.finditer(r"^FROM\b.*$", text[: layer.start()], re.MULTILINE))[-1]
    without = text.replace("\nARG APT_REFRESH=0\n", "\n", 1)
    return without.replace(stage.group(0), "ARG APT_REFRESH=0\n" + stage.group(0), 1)


def dockerfiles():
    texts = {}
    for path in sorted(set(IMAGES.values())):
        with open(os.path.join(ROOT, path)) as f:
            texts[path] = f.read()
    return texts


def check_merge(wf, build):
    jobs = wf["jobs"]
    merges = [j for j, job in jobs.items() if steps_running(job, "scripts/ci/merge-image.sh")]
    if len(merges) != 1:
        return f"not one merge job: {merges}", None
    name = merges[0]
    job = jobs[name]
    if build not in needs_of(job):
        return "the merge does not need the build", name
    if sorted(job.get("strategy", {}).get("matrix", {}).get("image", [])) != sorted(IMAGES):
        return "the merge matrix is not both images", name
    downloads = steps_using(job, "actions/download-artifact")
    names = sorted(d.get("with", {}).get("name", "") for d in downloads)
    if names != ["digest-${{ matrix.image }}-amd64", "digest-${{ matrix.image }}-arm64"] or any(
        "pattern" in d.get("with", {}) for d in downloads
    ):
        return "the merge does not download its image's two digests by exact name", name
    merge_steps = steps_running(job, "scripts/ci/merge-image.sh")
    attest = steps_using(job, "actions/attest-build-provenance")
    if (
        len(merge_steps) != 1
        or len(attest) != 1
        or attest[0].get("with", {}).get("subject-digest") != "${{ steps.%s.outputs.digest }}" % merge_steps[0].get("id")
    ):
        return "the attestation does not name the merge's printed digest", name
    return None, name


def release_jobs(wf):
    """The CLI release: GoReleaser's job that builds no package."""
    return [
        k for k, job in wf["jobs"].items()
        if k not in PACKAGE_JOBS and steps_using(job, "goreleaser/goreleaser-action")
    ]


def check_permissions(wf, build, merge):
    jobs = wf["jobs"]
    if wf.get("permissions") != {"contents": "read"}:
        return f"the workflow's default permissions are {wf.get('permissions')}"
    if jobs[build].get("permissions") != {"contents": "read", "packages": "write"}:
        return f"the build's permissions are {jobs[build].get('permissions')}"
    want = {"contents": "read", "packages": "write", "id-token": "write", "attestations": "write"}
    if jobs[merge].get("permissions") != want:
        return f"the merge's permissions are {jobs[merge].get('permissions')}"
    release = release_jobs(wf)
    if len(release) != 1:
        return f"not one CLI release job: {release}"
    granted = jobs[release[0]].get("permissions") or {}
    if not isinstance(granted, dict) or any(
        k not in RELEASE_PERMISSIONS or (v == "write" and RELEASE_PERMISSIONS[k] != "write") for k, v in granted.items()
    ):
        return f"the CLI release's permissions {granted} go beyond {RELEASE_PERMISSIONS}"
    return None


# --- the tag check: nothing builds or publishes under a tag mix.exs does not declare ---


def run_lines(step):
    return [line.strip() for line in str(step.get("run", "")).splitlines() if line.strip()]


def declared_versions(text):
    return re.findall(r'^\s*version:\s*"([^"]*)"', text, re.MULTILINE)


def other_version(version):
    """The version with the next PATCH, its pre-release kept."""
    core, sep, pre = version.partition("-")
    major, minor, patch = core.split(".")
    return f"{major}.{minor}.{int(patch) + 1}{sep}{pre}"


def other_prerelease(version):
    """The version's MAJOR.MINOR.PATCH with a pre-release it does not carry."""
    core, _, pre = version.partition("-")
    return core + "-" + ("rc.9" if pre != "rc.9" else "rc.8")


def version_vectors():
    """The vector file's accepted and refused versions; check_vectors holds
    their shape."""
    with open(VECTORS, "rb") as f:
        versions = strict_json(f.read()).get("versions")
    if not isinstance(versions, dict):
        return [], []
    return [list(v) if isinstance(v, list) else [] for v in (versions.get("accepted"), versions.get("refused"))]


# Executions of one step's script, by (script, tree, tag): mutants that
# leave the step alone reuse the real step's results.
_TAG_RUNS = {}
_SCRATCH = []
_LOCALE = []


def scratch():
    if not _SCRATCH:
        _SCRATCH.append(tempfile.mkdtemp(prefix="ci-release-graph."))
    return _SCRATCH[0]


def range_locale():
    """A locale under which bash's [A-Za-z] admits a letter outside ASCII,
    as some UTF-8 locales' collation does, so a script that matches a
    version without LC_ALL=C of its own is refused; else C.UTF-8, the
    runner's own."""
    if not _LOCALE:
        found = "C.UTF-8"
        for candidate in ("en_US.UTF-8", "en_US.utf8", "en_GB.UTF-8", "de_DE.UTF-8"):
            probe = subprocess.run(
                ["bash", "--noprofile", "--norc", "-c", '[[ "$1" =~ ^[A-Za-z]$ ]]', "bash", "\u00e5"],
                env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": candidate},
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=60,
            )
            if probe.returncode == 0:
                found = candidate
                break
        _LOCALE.append(found)
    return _LOCALE[0]


def matches_in_c_locale(lines):
    """Whether `export LC_ALL=C` comes before the first =~ match."""
    first = next((i for i, line in enumerate(lines) if "=~" in line), len(lines))
    return C_LOCALE in [line.strip() for line in lines[:first]]


def run_tag_step(script, tree, tag):
    key = (script, tree, tag)
    if key not in _TAG_RUNS:
        path = os.path.join(scratch(), "tag-step-%d.sh" % len(_TAG_RUNS))
        with open(path, "w") as f:
            f.write(script)
        # As the runner runs a step: bash -e with pipefail, its script a
        # file, the working directory the checkout, and nothing in the
        # environment but PATH, the tag and range_locale().
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": range_locale(), "GITHUB_REF_NAME": tag}
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", path],
            cwd=tree,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
        _TAG_RUNS[key] = (result.returncode, result.stdout.decode(errors="replace"))
    return _TAG_RUNS[key]


def planted_mix(name, text):
    """A tree holding only apps/prima/mix.exs, with the given text."""
    tree = os.path.join(scratch(), "mix-" + name)
    if not os.path.isdir(tree):
        os.makedirs(os.path.join(tree, os.path.dirname(MIX_EXS)))
        with open(os.path.join(tree, MIX_EXS), "w") as f:
            f.write(text)
    return tree


def tag_cases():
    """(description, tree, tag, expected) cases the comparison is run on:
    the real tree, trees planted around it, and a tree declaring each of
    the vector file's versions."""
    with open(os.path.join(ROOT, MIX_EXS)) as f:
        text = f.read()
    found = declared_versions(text)
    if len(found) != 1 or not SEMVER.fullmatch(found[0]):
        raise SystemExit(f"FAIL: {MIX_EXS} declares {found}, not one {RELEASE_VERSION}")
    real = found[0]
    other = other_version(real)
    line = re.search(r'^\s*version:\s*"[^"]*",?\s*$', text, re.MULTILINE).group(0)

    def declaring(version):
        return text.replace(line, line.replace(f'"{real}"', f'"{version}"', 1), 1)

    moved = planted_mix("other", declaring(other))
    twice = planted_mix("twice", text.replace(line, line + "\n" + line.replace(real, other), 1))
    none = planted_mix("none", text.replace(line + "\n", "", 1))
    core = real.partition("-")[0]
    cases = [
        ("the declared version", ROOT, real, True),
        ("another version", ROOT, other, False),
        ("the declared version with a v", ROOT, "v" + real, False),
        ("the declared version with a suffix", ROOT, real + "-rc.1", False),
        ("the declared version with build metadata", ROOT, real + "+build.5", False),
        ("another pre-release of the declared version", ROOT, other_prerelease(real), False),
        ("an empty tag", ROOT, "", False),
        ("the real tag on a tree that declares another version", moved, real, False),
        ("the tag a tree that declares another version names", moved, other, True),
        ("a tree that declares two versions", twice, real, False),
        ("a tree that declares none", none, real, False),
    ]
    if core != real:
        cases.append(("the declared version without its pre-release", ROOT, core, False))
    accepted, refused = version_vectors()
    for i, version in enumerate(accepted):
        tree = planted_mix("accepted-%d" % i, declaring(version))
        version_core, pre = version.partition("-")[::2]
        cases.append((f"a tree declaring {version} under its tag", tree, version, True))
        cases.append((f"a tree declaring {version} under another pre-release", tree, other_prerelease(version), False))
        if pre:
            cases.append((f"a tree declaring {version} under {version_core}", tree, version_core, False))
    # A version mix.exs can declare on its one line, in its quotes.
    for i, version in enumerate(refused):
        if "\n" in version or '"' in version:
            continue
        tree = planted_mix("refused-%d" % i, declaring(version))
        cases.append((f"a tree declaring {version!r}, no release version, under that tag", tree, version, False))
    return cases


def check_tag(wf, build, release):
    jobs = wf["jobs"]
    job = jobs.get(TAG_JOB)
    if job is None:
        return f"no {TAG_JOB} job checks the tag against {MIX_EXS}"
    for name in (build, release):
        if TAG_JOB not in needs_of(jobs[name]):
            return f"{name} does not need the tag check"
    if job.get("permissions") != {"contents": "read"}:
        return f"the tag check's permissions are {job.get('permissions')}"
    if "env" in job or "GITHUB_REF_NAME" in (wf.get("env") or {}):
        return "the workflow or the tag check's job sets an environment of its own"
    steps = job.get("steps", [])
    if (
        len(steps) != 3
        or str(steps[0].get("uses", "")).split("@")[0] != "actions/checkout"
        or set(steps[0]) != {"uses"}
    ):
        return "the tag check's steps are not the checkout of the tag, the comparison and the note's check"
    note = steps[2]
    if set(note) - {"name", "run"} or run_lines(note) != run_lines({"run": NOTE_CHECK_RUN}):
        return f"the tag check's third step is {note!r}, not the note's check {NOTE_CHECK_RUN!r}"
    step = steps[1]
    if set(step) - {"name", "run"} or "run" not in step:
        return f"the tag check's comparison carries {sorted(set(step) - {'name', 'run'})}"
    script = str(step["run"])
    if "$GITHUB_REF_NAME" not in script or MIX_EXS not in script:
        return f"the tag check does not compare $GITHUB_REF_NAME with {MIX_EXS}"
    # On a host with no locale whose ranges admit letters outside ASCII,
    # the cases below cannot tell a match byte by byte from another.
    if not matches_in_c_locale(run_lines(step)):
        return f"the tag check matches the version before {C_LOCALE!r}"
    cases = tag_cases()
    for what, tree, tag, passes in cases:
        status, output = run_tag_step(script, tree, tag)
        if passes and status != 0:
            return f"the tag check refuses {what} ({tag!r}): exit {status}: {output.strip()[-300:]}"
        if not passes:
            if status == 0:
                return f"the tag check accepts {what} ({tag!r})"
            if "::error::" not in output:
                return f"the tag check refuses {what} ({tag!r}) without an ::error:: line: {output.strip()[-300:]}"
    # A mismatch names both the tag and the declared version.
    real, other = cases[0][2], cases[1][2]
    _, output = run_tag_step(script, ROOT, other)
    error = next((line for line in output.splitlines() if line.startswith("::error::")), "")
    if other not in error or real not in error:
        return f"the tag check's refusal of {other!r} does not name it and {real!r}: {error!r}"
    return None


# --- the merged digests and the signed release manifest ---


def check_merged_digest(wf, merge):
    job = wf["jobs"][merge]
    steps = job.get("steps", [])
    merge_at = step_index(job, lambda s: "scripts/ci/merge-image.sh" in str(s.get("run", "")))
    records = [i for i, s in enumerate(steps) if run_lines(s) == run_lines({"run": RECORD_RUN})]
    if len(records) != 1:
        return "the merge does not record its printed digest once"
    record = steps[records[0]]
    if set(record) - {"name", "env", "run"} or record.get("env") != {
        "DIGEST": "${{ steps.%s.outputs.digest }}" % steps[merge_at].get("id")
    }:
        return "the recorded digest is not the one merge-image.sh printed"
    uploads = [i for i, s in enumerate(steps) if str(s.get("uses", "")).split("@")[0] == "actions/upload-artifact"]
    if len(uploads) != 1:
        return "the merge does not upload its digest once"
    upload = steps[uploads[0]]
    if set(upload) - {"name", "uses", "with"} or upload.get("with") != MERGED_UPLOAD:
        return f"the merged digest is uploaded as {upload.get('with')}, not {MERGED_UPLOAD}"
    if not merge_at < records[0] < uploads[0]:
        return "the merged digest is not recorded after the merge and uploaded after that"
    return None


def check_release_manifest(wf, merge, release):
    job = wf["jobs"][release]
    steps = job.get("steps", [])
    if merge not in needs_of(job):
        return "the CLI release does not need the merge"
    downloads = [i for i, s in enumerate(steps) if str(s.get("uses", "")).split("@")[0] == "actions/download-artifact"]
    got = {steps[i].get("with", {}).get("name"): steps[i].get("with", {}).get("path") for i in downloads}
    if (
        len(downloads) != len(MERGED_DOWNLOADS) + len(CHECKED_DOWNLOAD)
        or got != {**MERGED_DOWNLOADS, **CHECKED_DOWNLOAD}
        or any(
            set(steps[i]) - {"name", "uses", "with"} or set(steps[i].get("with", {})) != {"name", "path"}
            for i in downloads
        )
    ):
        return "the CLI release does not download the two merged digests and the checked installers by exact name"

    def only(predicate, what):
        at = [i for i, s in enumerate(steps) if predicate(s)]
        return (at[0], None) if len(at) == 1 else (None, f"the CLI release does not {what} once")

    order = []
    for predicate, what in [
        (lambda s: "scaffold-tarball.sh" in str(s.get("run", "")), "build the scaffold"),
        (lambda s: MANIFEST_OUT in str(s.get("run", "")), "write release.json"),
        (lambda s: "--manifest" in str(s.get("run", "")), "validate release.json"),
        (lambda s: "sign-blob" in str(s.get("run", "")), "sign release.json"),
        (lambda s: "release-note.sh" in str(s.get("run", "")), "write the release note"),
        (lambda s: str(s.get("uses", "")).split("@")[0] == "goreleaser/goreleaser-action", "run GoReleaser"),
    ]:
        at, reason = only(predicate, what)
        if reason:
            return reason
        order.append(at)
    scaffold, manifest, validate, sign, note, goreleaser = order
    lines = run_lines(steps[manifest])
    if SCHEMA_READ not in lines or SCHEMA_ARG not in lines or not any(SCHEMA_KEY in line for line in lines):
        return "the CLI release's manifest does not carry the schema fingerprint its merged cyfr image answers"
    for at, want in [
        (scaffold, SCAFFOLD_RUN), (validate, VALIDATE_RUN), (sign, SIGN_RUN), (note, NOTE_WRITE_RUN),
    ]:
        if run_lines(steps[at]) != run_lines({"run": want}):
            return f"the CLI release runs {steps[at].get('run')!r}, not {want!r}"
    for at in (scaffold, manifest, validate, sign, note):
        if set(steps[at]) - {"name", "run"}:
            extra = sorted(set(steps[at]) - {"name", "run"})
            return f"the CLI release's step {steps[at].get('name')!r} carries {extra}"
    installer = step_index(job, lambda s: str(s.get("uses", "")).split("@")[0] == "sigstore/cosign-installer")
    if installer is None or installer > sign:
        return "cosign is not installed before the manifest is signed"
    if [max(downloads)] + order != sorted([max(downloads)] + order):
        return (
            "the CLI release does not download the digests and the checked installers, build the scaffold, "
            "write, validate and sign release.json, write the release note, then run GoReleaser, in that order"
        )
    if steps[goreleaser].get("with", {}).get("workdir") != "apps/codex":
        return "GoReleaser does not run in apps/codex"
    if steps[goreleaser].get("with", {}).get("args") != GORELEASER_ARGS:
        return f"GoReleaser runs {steps[goreleaser].get('with', {}).get('args')!r}, not {GORELEASER_ARGS!r}"
    env = steps[goreleaser].get("env") or {}
    if {k: env.get(k) for k in MANIFEST_DIR_ENV} != MANIFEST_DIR_ENV:
        return f"GoReleaser's RELEASE_MANIFEST_DIR is {env.get('RELEASE_MANIFEST_DIR')!r}, not {MANIFEST_DIR_ENV}"
    if {k: env.get(k) for k in PACKAGES_DIR_ENV} != PACKAGES_DIR_ENV:
        return f"GoReleaser's RELEASE_PACKAGES_DIR is {env.get('RELEASE_PACKAGES_DIR')!r}, not {PACKAGES_DIR_ENV}"
    return None


def check_linux_package(wf, merge, release):
    jobs = wf["jobs"]
    job = jobs.get(PACKAGE_JOB)
    if job is None:
        return f"no {PACKAGE_JOB} job builds the CYFR app's Linux package"
    if TAG_JOB not in needs_of(job):
        return "the Linux package does not need the tag check"
    if PACKAGE_JOB not in needs_of(jobs.get(INSTALLERS_JOB, {})):
        return "the installers' check does not need the Linux package"
    if job.get("permissions") != {"contents": "read"}:
        return f"the Linux package's permissions are {job.get('permissions')}, not contents read alone"
    if "secrets." in json.dumps(job) or "github.token" in json.dumps(job):
        return "the Linux package's job reads a secret"
    if job.get("env") != {"ARCH": "${{ matrix.arch }}"}:
        return f"the Linux package's environment is {job.get('env')}"
    if job.get("strategy", {}).get("matrix") != {"include": PACKAGE_MATRIX} or job.get("runs-on") != "${{ matrix.runner }}":
        return "the Linux package is not built on each architecture's own runner"
    steps = job.get("steps", [])
    if len(steps) != len(PACKAGE_STEPS):
        return f"the Linux package's job has {len(steps)} steps, not {len(PACKAGE_STEPS)}"
    for step, (kind, want) in zip(steps, PACKAGE_STEPS):
        if kind == "run":
            if set(step) - {"name", "run"} or run_lines(step) != run_lines({"run": want}):
                return f"the Linux package's job runs {step!r}, not {want!r}"
            continue
        if set(step) - {"name", "uses", "with"} or str(step.get("uses", "")).split("@")[0] != kind:
            return f"the Linux package's job has {step!r}, not {kind}"
        if want is None:
            # The release's own GoReleaser, at its version, in its workdir.
            theirs = next(s for s in jobs[release]["steps"] if str(s.get("uses", "")).startswith(kind))
            if step["uses"] != theirs["uses"]:
                return "the Linux package's cyfr is built by another GoReleaser action than the release's"
            want = {**theirs.get("with", {}), "args": PACKAGE_BUILD_ARGS}
        if step.get("with") != want:
            return f"the Linux package's {kind} takes {step.get('with')}, not {want}"
    return None


# The CYFR app's Mac package: release.yml calls desktop-mac.yml at the
# tag, from this repository, and hands it the Apple inputs by name alone;
# desktop-mac.yml builds, signs, notarises, checks, installs and smokes the
# Apple silicon DMG on an Apple silicon runner, checks the installed cyfr
# is the tag's and uploads the DMG, its steps exactly these, and the Apple
# inputs reach its one signing step and nothing else.
MAC_JOB = "mac-package"
DESKTOP_MAC = os.path.join(WORKFLOWS, "desktop-mac.yml")
MAC_WORKFLOW = "./.github/workflows/desktop-mac.yml"
APPLE_SECRETS = [
    "APPLE_CERTIFICATE", "APPLE_CERTIFICATE_PASSWORD", "APPLE_SIGNING_IDENTITY", "APPLE_TEAM_ID",
    "APPLE_API_KEY", "APPLE_API_KEY_ID", "APPLE_API_ISSUER", "APPLE_PROVISIONING_PROFILE",
]
APPLE_PASSED = {name: "${{ secrets.%s }}" % name for name in APPLE_SECRETS}
MAC_CALL = {
    "needs": [TAG_JOB, "test", "dialyzer", "codex-ci", "keeper-ci", "license-lint", "security"],
    "if": "github.repository == 'cyfrworks/cyfr'",
    "permissions": {"contents": "read"},
    "uses": MAC_WORKFLOW,
    "with": {"version": "${{ github.ref_name }}"},
    "secrets": APPLE_PASSED,
}
MAC_RUNNER = "macos-latest"
MAC_ENV = {
    "ARCH": "arm64",
    "VERSION": "${{ inputs.version || '0.0.0-candidate' }}",
    "DMG": "apps/codex/desktop/dist/cyfr-desktop_${{ inputs.version || '0.0.0-candidate' }}_darwin_arm64.dmg",
}
MAC_BUILD_ARGS = (
    "build --single-target --clean ${{ inputs.version == '' && '--snapshot ' || '' }}"
    "--output ${{ runner.temp }}/cyfr/cyfr"
)
# Each step as it must be, without its name: an action by its name before
# the @, a script by its lines. The GoReleaser action is the release's own.
MAC_STEPS = [
    {"uses": "actions/checkout", "with": {"fetch-depth": 0, "persist-credentials": False}},
    {"uses": "actions/setup-go", "with": {"go-version-file": "apps/codex/go.mod", "cache": False}},
    {"uses": "actions/setup-node", "with": {"node-version": 24, "package-manager-cache": False}},
    {"run": 'mkdir -p "$RUNNER_TEMP/cyfr"'},
    {"uses": "goreleaser/goreleaser-action", "with": None},
    {"working-directory": "apps/codex/desktop", "run": "npm ci --ignore-scripts --no-audit --no-fund"},
    {"working-directory": "apps/codex/desktop", "env": APPLE_PASSED,
     "run": 'node scripts/build.mjs --cyfr "$RUNNER_TEMP/cyfr/cyfr" --version "$VERSION" --arch "$ARCH" --distribution'},
    {"run": 'bash tests/desktop-proof/native/mac.sh "$DMG"'},
    {"run": 'bash tests/desktop-proof/native/installed-machine.sh "$ARCH" /Applications/CYFR.app/Contents/MacOS/CYFR /Applications/CYFR.app/Contents/Resources/cyfr'},
    {"if": "inputs.version != ''",
     "run": 'bash tests/desktop-proof/native/installed-version.sh /Applications/CYFR.app/Contents/Resources/cyfr "$VERSION"'},
    {"if": "inputs.version != '' || inputs.upload == true", "uses": "actions/upload-artifact", "with": {
        "name": "cyfr-desktop-darwin-arm64",
        "path": "${{ env.DMG }}",
        "if-no-files-found": "error",
        "retention-days": 1,
    }},
]


def step_differs(step, want, goreleaser):
    """Why `step` is not `want` (a MAC_STEPS entry), or None."""
    if set(step) - {"name"} != set(want):
        return f"{step.get('name')!r} has {sorted(set(step) - {'name'})}, not {sorted(want)}"
    for key, value in want.items():
        if key == "uses":
            if str(step["uses"]).split("@")[0] != value:
                return f"{step.get('name')!r} uses {step['uses']}, not {value}"
            if value == "goreleaser/goreleaser-action" and step["uses"] != goreleaser["uses"]:
                return f"{step.get('name')!r} is another GoReleaser action than the release's"
        elif key == "run":
            if run_lines(step) != run_lines({"run": value}):
                return f"{step.get('name')!r} runs {step['run']!r}, not {value!r}"
        elif key == "with" and value is None:
            if step["with"] != {**goreleaser.get("with", {}), "args": MAC_BUILD_ARGS}:
                return f"{step.get('name')!r} takes {step['with']}, not the release's GoReleaser with {MAC_BUILD_ARGS!r}"
        elif step[key] != value:
            return f"{step.get('name')!r} has {key} {step[key]!r}, not {value!r}"
    return None


def check_mac_package(wf, mac, merge, release):
    jobs = wf["jobs"]
    job = jobs.get(MAC_JOB)
    if job is None:
        return f"no {MAC_JOB} job builds the CYFR app's Mac package"
    for key, want in MAC_CALL.items():
        got = sorted(needs_of(job)) if key == "needs" else job.get(key)
        if got != (sorted(want) if key == "needs" else want):
            return f"the Mac package's {key} is {got!r}, not {want!r}"
    if set(job) != set(MAC_CALL):
        return f"the Mac package's job carries {sorted(set(job) - set(MAC_CALL))}"
    if MAC_JOB not in needs_of(jobs.get(INSTALLERS_JOB, {})):
        return "the installers' check does not need the Mac package"
    on = mac.get("on", mac.get(True))
    if not isinstance(on, dict) or sorted(on) != ["workflow_call", "workflow_dispatch"]:
        return f"desktop-mac.yml starts on {sorted(on) if isinstance(on, dict) else on!r}, not a dispatch and a call alone"
    call = on["workflow_call"] or {}
    if call.get("secrets") != {name: {"required": True} for name in APPLE_SECRETS}:
        return f"desktop-mac.yml's call takes the secrets {call.get('secrets')}, not the eight Apple inputs, each required"
    version = (call.get("inputs") or {}).get("version") or {}
    if sorted(call.get("inputs") or {}) != ["version"] or version.get("type") != "string" or version.get("required") is not True:
        return f"desktop-mac.yml's call takes the inputs {call.get('inputs')}, not a required version alone"
    # PyYAML reads the key `on` as YAML 1.1's true.
    if {"on" if k is True else k for k in mac} != {"name", "on", "permissions", "jobs"}:
        return f"desktop-mac.yml carries {sorted(str(k) for k in mac)}"
    if mac.get("permissions") != {"contents": "read"}:
        return f"desktop-mac.yml's permissions are {mac.get('permissions')}, not contents read alone"
    if sorted(mac.get("jobs") or {}) != ["mac"]:
        return f"desktop-mac.yml's jobs are {sorted(mac.get('jobs') or {})}, not the one mac"
    build = mac["jobs"]["mac"]
    extra = set(build) - {"name", "runs-on", "timeout-minutes", "defaults", "env", "steps"}
    if extra:
        return f"desktop-mac.yml's job carries {sorted(extra)}"
    if build.get("runs-on") != MAC_RUNNER:
        return f"the Mac package is built on {build.get('runs-on')!r}, not Apple silicon's {MAC_RUNNER}"
    if build.get("env") != MAC_ENV:
        return f"desktop-mac.yml's environment is {build.get('env')}, not {MAC_ENV}"
    if not isinstance(build.get("timeout-minutes"), int):
        return "desktop-mac.yml's job has no timeout"
    steps = build.get("steps", [])
    if len(steps) != len(MAC_STEPS):
        return f"desktop-mac.yml's job has {len(steps)} steps, not {len(MAC_STEPS)}"
    goreleaser = next(s for s in jobs[release]["steps"] if str(s.get("uses", "")).startswith("goreleaser/goreleaser-action"))
    for step, want in zip(steps, MAC_STEPS):
        reason = step_differs(step, want, goreleaser)
        if reason:
            return f"desktop-mac.yml's step {reason}"
    return None


# The CYFR app's Windows packages: cyfr.exe built by the release's
# GoReleaser on Linux for each architecture (Windows cannot start the
# build's bash post hook), then the MSI built, installed, smoked, its cyfr
# checked and removed on each architecture's own Windows runner, and
# uploaded; each job's steps exactly these, neither reading a secret.
WINDOWS_CYFR_JOB = "windows-cyfr"
WINDOWS_JOB = "windows-package"
CHECKS = ["test", "dialyzer", "codex-ci", "keeper-ci", "license-lint", "security"]
WINDOWS_CYFR_BUILD_ARGS = "build --single-target --clean --output ${{ runner.temp }}/cyfr/cyfr.exe"
WINDOWS_CYFR = {
    "needs": [TAG_JOB] + CHECKS,
    "if": "github.repository == 'cyfrworks/cyfr'",
    "permissions": {"contents": "read"},
    "strategy": {"matrix": {"arch": list(PACKAGE_ARCHES)}},
    "env": {"GOOS": "windows", "GOARCH": "${{ matrix.arch }}"},
    "runs-on": "ubuntu-latest",
}
WINDOWS_CYFR_STEPS = [
    {"uses": "actions/checkout", "with": {"fetch-depth": 0, "persist-credentials": False}},
    {"uses": "actions/setup-go", "with": {"go-version-file": "apps/codex/go.mod", "cache": False}},
    {"run": 'mkdir -p "$RUNNER_TEMP/cyfr"'},
    {"uses": "goreleaser/goreleaser-action", "with": WINDOWS_CYFR_BUILD_ARGS},
    {"uses": "actions/upload-artifact", "with": {
        "name": "cyfr-windows-${{ matrix.arch }}",
        "path": "${{ runner.temp }}/cyfr/cyfr.exe",
        "if-no-files-found": "error",
        "retention-days": 1,
    }},
]
WINDOWS_MSI = 'tests/desktop-proof/native/windows.ps1 %s "$env:RUNNER_TEMP/package/cyfr-desktop_$($env:GITHUB_REF_NAME)_windows_$($env:ARCH).msi"'
WINDOWS = {
    "needs": [WINDOWS_CYFR_JOB, TAG_JOB] + CHECKS,
    "if": "github.repository == 'cyfrworks/cyfr'",
    "permissions": {"contents": "read"},
    "strategy": {"matrix": {"include": [
        {"arch": "amd64", "runner": "windows-latest"},
        {"arch": "arm64", "runner": "windows-11-arm"},
    ]}},
    "env": {"ARCH": "${{ matrix.arch }}"},
    "runs-on": "${{ matrix.runner }}",
    "defaults": {"run": {"shell": "bash"}},
}
WINDOWS_STEPS = [
    {"run": "git config --global core.autocrlf false"},
    {"uses": "actions/checkout", "with": {"persist-credentials": False}},
    {"uses": "actions/setup-node", "with": {"node-version": 24, "package-manager-cache": False}},
    {"uses": "actions/download-artifact", "with": {"name": "cyfr-windows-${{ matrix.arch }}", "path": "${{ runner.temp }}/cyfr"}},
    {"run": """set -euo pipefail
cd apps/codex/desktop
npm ci --ignore-scripts --no-audit --no-fund
node scripts/build.mjs --cyfr "$RUNNER_TEMP/cyfr/cyfr.exe" --version "$GITHUB_REF_NAME" --arch "$ARCH" --out "$RUNNER_TEMP/package"
"""},
    {"shell": "pwsh", "run": "pwsh -NoProfile -File " + WINDOWS_MSI % "install"},
    {"run": 'bash tests/desktop-proof/native/smoke.sh "$APP"'},
    {"run": 'bash tests/desktop-proof/native/installed-version.sh "$CYFR" "$GITHUB_REF_NAME"'},
    {"run": 'bash tests/desktop-proof/native/installed-machine.sh "$ARCH" "$APP" "$CYFR"'},
    {"shell": "pwsh", "run": "pwsh -NoProfile -File " + WINDOWS_MSI % "remove"},
    {"uses": "actions/upload-artifact", "with": {
        "name": "cyfr-desktop-windows-${{ matrix.arch }}",
        "path": "${{ runner.temp }}/package/cyfr-desktop_${{ github.ref_name }}_windows_${{ matrix.arch }}.msi",
        "if-no-files-found": "error",
        "retention-days": 1,
    }},
]
PACKAGE_JOBS = {PACKAGE_JOB, MAC_JOB, WINDOWS_CYFR_JOB, WINDOWS_JOB, "installers"}


def check_job(jobs, name, want, steps_want, goreleaser, what):
    job = jobs.get(name)
    if job is None:
        return f"no {name} job builds {what}"
    for key, value in want.items():
        got = sorted(needs_of(job)) if key == "needs" else job.get(key)
        if got != (sorted(value) if key == "needs" else value):
            return f"{what}'s {key} is {got!r}, not {value!r}"
    extra = set(job) - set(want) - {"timeout-minutes", "steps"}
    if extra:
        return f"{what}'s job carries {sorted(extra)}"
    if not isinstance(job.get("timeout-minutes"), int):
        return f"{what}'s job has no timeout"
    steps = job.get("steps", [])
    if len(steps) != len(steps_want):
        return f"{what}'s job has {len(steps)} steps, not {len(steps_want)}"
    for step, step_want in zip(steps, steps_want):
        if isinstance(step_want.get("with"), str):
            step_want = {**step_want, "with": {**goreleaser.get("with", {}), "args": step_want["with"]}}
        reason = step_differs(step, step_want, goreleaser)
        if reason:
            return f"{what}'s step {reason}"
    return None


def check_windows_package(wf, merge, release):
    jobs = wf["jobs"]
    goreleaser = next(s for s in jobs[release]["steps"] if str(s.get("uses", "")).startswith("goreleaser/goreleaser-action"))
    reason = check_job(jobs, WINDOWS_CYFR_JOB, WINDOWS_CYFR, WINDOWS_CYFR_STEPS, goreleaser, "the Windows packages' cyfr") or check_job(
        jobs, WINDOWS_JOB, WINDOWS, WINDOWS_STEPS, goreleaser, "the Windows package"
    )
    if reason:
        return reason
    if WINDOWS_JOB not in needs_of(jobs.get(INSTALLERS_JOB, {})):
        return "the installers' check does not need the Windows package"
    return None


INSTALLERS_CHECK = {
    "needs": [TAG_JOB, PACKAGE_JOB, MAC_JOB, WINDOWS_JOB] + CHECKS,
    "if": "github.repository == 'cyfrworks/cyfr'",
    "permissions": {"contents": "read"},
    "runs-on": "ubuntu-latest",
}
INSTALLERS_STEPS = (
    [{"uses": "actions/checkout", "with": {"persist-credentials": False}}]
    + [{"uses": "actions/download-artifact", "with": {"name": n, "path": p}} for n, p in PACKAGE_DOWNLOADS.items()]
    + [
        {"run": CASK_RUN},
        {"run": INSTALLERS_RUN},
        {"uses": "actions/upload-artifact", "with": {
            "name": CHECKED,
            "path": "${{ runner.temp }}/checked",
            "if-no-files-found": "error",
            "retention-days": 1,
        }},
    ]
)
# A job publishes when it may write to the repository, the registry or an
# attestation, or calls a workflow that may; the image builds alone push,
# by digest only, what no tag names before the merge.
PUBLISHING = {"contents", "packages", "id-token", "attestations"}


def check_installers_job(wf):
    jobs = wf["jobs"]
    goreleaser = next(s for s in jobs[release_jobs(wf)[0]]["steps"] if str(s.get("uses", "")).startswith("goreleaser/goreleaser-action"))
    reason = check_job(jobs, INSTALLERS_JOB, INSTALLERS_CHECK, INSTALLERS_STEPS, goreleaser, "the installers' check")
    if reason:
        return reason

    def ancestors(j, seen=None):
        seen = set() if seen is None else seen
        for n in needs_of(jobs[j]):
            if n not in seen:
                seen.add(n)
                ancestors(n, seen)
        return seen

    build = next(j for j, job in jobs.items() if steps_using(job, "docker/build-push-action"))
    for j, job in jobs.items():
        granted = job.get("permissions") or {}
        writes = isinstance(granted, dict) and any(granted.get(k) == "write" for k in PUBLISHING)
        if writes and j != build:
            if INSTALLERS_JOB not in ancestors(j):
                return f"{j} publishes without the installers' check"
    return None


# Where a secret may be read in release.yml: the token GitHub makes for the
# run where a step needs it, the Apple inputs in the Mac package's call
# alone, each by its own name, and the tap's token in the tap's step alone.
SECRET_REF = re.compile(r"secrets\.([A-Za-z_][A-Za-z0-9_]*)")


def secret_reads(node, path=()):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from secret_reads(value, path + (key,))
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from secret_reads(value, path + (i,))
    elif isinstance(node, str):
        for name in SECRET_REF.findall(node):
            yield name, path, node


def check_secrets(wf, release):
    steps = wf["jobs"][release].get("steps", [])
    tap = next((i for i, s in enumerate(steps) if s.get("name") == HOMEBREW), None)
    for name, path, text in secret_reads(wf):
        where = "/".join(str(p) for p in path)
        if name == "GITHUB_TOKEN":
            continue
        if name in APPLE_SECRETS:
            if path != ("jobs", MAC_JOB, "secrets", name) or text != "${{ secrets.%s }}" % name:
                return f"the Apple input {name} is read at {where}, not passed by its name to the Mac package alone"
        elif name == "HOMEBREW_TAP_TOKEN":
            if path != ("jobs", release, "steps", tap, "env", "HOMEBREW_TAP_TOKEN"):
                return f"the tap's token is read at {where}, not in the tap's step alone"
        else:
            return f"release.yml reads the secret {name} at {where}"
    return None


def check_trigger(wf):
    # PyYAML reads the key `on` as YAML 1.1's true.
    on = wf.get("on", wf.get(True))
    if on != {"push": {"tags": TAG_FILTERS}}:
        return f"the workflow starts on {on!r}, not on a push of the tags {TAG_FILTERS}"
    return None


# --- the Homebrew tap: a pre-release never reaches it ---

# Executions of the Homebrew step's script, by (script, tag).
_HOMEBREW_RUNS = {}
# The tap's token in the stubbed runs: no git call's arguments may hold it.
TAP_TOKEN = "tap-secret-0451"
# A git that records each call and plays a tap: its clone holds a cask at
# TAP_AT (none when empty), or the text TAP_TEXT, a fetch brings one at TAP_AFTER, the first
# PUSH_FAILS pushes fail, and the staged cask always differs.
GIT_STUB = r"""#!/bin/sh
printf '%s\n' "$*" >> "$GIT_CALLS"
while [ "$1" = -c ]; do shift 2; done
dir=.
if [ "$1" = -C ]; then dir=$2; shift 2; fi
cask() { mkdir -p "$1/Casks"; printf 'cask "cyfr" do\n  version "%s"\nend\n' "$2" > "$1/Casks/cyfr.rb"; }
case "$1" in
  clone)
    eval "dest=\${$#}"; mkdir -p "$dest"
    if [ -n "$TAP_TEXT" ]; then mkdir -p "$dest/Casks"; printf '%s' "$TAP_TEXT" > "$dest/Casks/cyfr.rb"
    elif [ -n "$TAP_AT" ]; then cask "$dest" "$TAP_AT"; fi ;;
  fetch) [ -z "$TAP_AFTER" ] || cask "$dir" "$TAP_AFTER" ;;
  push)
    n=$(( $(cat "$GIT_CALLS.pushes" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GIT_CALLS.pushes"
    [ "$n" -gt "${PUSH_FAILS:-0}" ] || exit 1 ;;
  diff) exit 1 ;;
esac
exit 0
"""


def run_homebrew_step(script, tag, tap_at="", tap_after="", push_fails=0, tap_text=""):
    """The step's script run as the runner runs it, with the cask the release
    checked in $RUNNER_TEMP/checked/cask and GIT_STUB on PATH. Returns
    (status, git calls, output)."""
    key = (script, tag, tap_at, tap_after, push_fails, tap_text)
    if key not in _HOMEBREW_RUNS:
        work = tempfile.mkdtemp(prefix="homebrew-", dir=scratch())
        casks = os.path.join(work, "runner", "checked", "cask")
        os.makedirs(casks)
        with open(os.path.join(casks, "cyfr.rb"), "w") as f:
            f.write('cask "cyfr" do\n  version "%s"\nend\n' % tag)
        stubs = os.path.join(work, "bin")
        os.makedirs(stubs)
        calls = os.path.join(work, "git.calls")
        with open(os.path.join(stubs, "git"), "w") as f:
            f.write(GIT_STUB)
        os.chmod(os.path.join(stubs, "git"), 0o755)
        # The retries' pauses, which the stubbed runs do not wait out.
        with open(os.path.join(stubs, "sleep"), "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(os.path.join(stubs, "sleep"), 0o755)
        os.makedirs(os.path.join(work, "tmp"))
        path = os.path.join(work, "step.sh")
        with open(path, "w") as f:
            f.write(script)
        env = {
            "PATH": stubs + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
            "LC_ALL": range_locale(),
            "TAG": tag,
            "RUNNER_TEMP": os.path.join(work, "runner"),
            "HOMEBREW_TAP_TOKEN": TAP_TOKEN,
            "GITHUB_STEP_SUMMARY": os.path.join(work, "summary"),
            "TMPDIR": os.path.join(work, "tmp"),
            "GIT_CALLS": calls,
            "TAP_AT": tap_at,
            "TAP_AFTER": tap_after,
            "PUSH_FAILS": str(push_fails),
            "TAP_TEXT": tap_text,
        }
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", path],
            cwd=work,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
        made = []
        if os.path.exists(calls):
            with open(calls) as f:
                made = f.read().splitlines()
        _HOMEBREW_RUNS[key] = (result.returncode, made, result.stdout.decode(errors="replace"))
    return _HOMEBREW_RUNS[key]


# The tap only moves forward: (the tap's version at the clone, its version
# after a fetch, pushes that fail, this release) and whether it pushes.
TAP_CASES = [
    ("", "", 0, "1.2.3", 1),
    ("1.2.2", "", 0, "1.2.3", 1),
    ("1.2.4", "", 0, "1.2.3", 0),
    ("1.9.9", "", 0, "1.10.0", 1),
    ("1.10.0", "", 0, "1.9.9", 0),
    ("1.2.2", "1.2.4", 1, "1.2.3", 1),
    ("1.2.2", "", 1, "1.2.3", 2),
]
# A cask that is there and whose version the step cannot read: the step
# fails naming the file and pushes nothing.
TAP_UNREADABLE = [
    ("one space more before the version", 'cask "cyfr" do\n  version  "1.2.4"\nend\n'),
    ("no version", 'cask "cyfr" do\nend\n'),
    ("an empty file", ""),
]


def check_homebrew(wf, release):
    """The Homebrew step, run on each accepted version: a pre-release exits
    0 with a notice before any git call, and a release reaches git clone;
    then on TAP_CASES: a tap that names a newer release is left as it is,
    with a notice and exit 0, at the clone and after a retry's fetch, and
    no git call carries the token."""
    steps = [s for s in wf["jobs"][release].get("steps", []) if s.get("name") == HOMEBREW]
    if len(steps) != 1:
        return f"the CLI release does not run {HOMEBREW!r} once"
    step = steps[0]
    if (step.get("env") or {}).get("TAG") != "${{ github.ref_name }}":
        return f"the Homebrew step's TAG is {(step.get('env') or {}).get('TAG')!r}, not the tag"
    script = str(step.get("run", ""))
    accepted, _ = version_vectors()
    if not accepted:
        return "the vector file accepts no version to run the Homebrew step on"
    for tag in accepted:
        status, calls, output = run_homebrew_step(script, tag)
        if "-" in tag:
            if status != 0 or calls:
                return f"the Homebrew step on the pre-release {tag} exits {status} after the git calls {calls[:2]}, not 0 before any"
            if "::notice::" not in output:
                return f"the Homebrew step skips the pre-release {tag} without a notice: {output.strip()[-300:]}"
        elif not calls or " clone " not in f" {calls[0]} ":
            return f"the Homebrew step on the release {tag} does not reach git clone: exit {status}, git {calls[:2]}: {output.strip()[-300:]}"
    for tap_at, tap_after, push_fails, tag, pushes in TAP_CASES:
        status, calls, output = run_homebrew_step(script, tag, tap_at, tap_after, push_fails)
        what = f"the Homebrew step for {tag} on a tap at {tap_at or 'nothing'}" + (
            f", {push_fails} push failing and a fetch bringing {tap_after}" if push_fails else "")
        made = sum(1 for c in calls if " push " in f" {c} ")
        if status != 0 or made != pushes:
            return f"{what} exits {status} after {made} pushes, not 0 after {pushes}: {output.strip()[-300:]}"
        if pushes == 0 and "::notice::" not in output:
            return f"{what} leaves the tap without a notice"
        if any(TAP_TOKEN in c for c in calls):
            return f"{what} hands git the token in its arguments"
    for name, text in TAP_UNREADABLE:
        status, calls, output = run_homebrew_step(script, "1.2.3", tap_text=text or "\n")
        made = sum(1 for c in calls if " push " in f" {c} ")
        if status == 0 or made or "Casks/cyfr.rb" not in output or "::error::" not in output:
            return f"the Homebrew step for 1.2.3 on a tap whose cask has {name} exits {status} after {made} pushes: {output.strip()[-300:]}"
    return None


# Each build's one hook: scripts/ci/release-binary-check.sh on the binary
# it built, which refuses one built with a build tag or holding the
# release proof (apps/codex/cmd/release_proof.go), so the release fails
# before any archive or upload. Held exactly on every build: a build's
# hooks are its own, and GoReleaser refuses hooks in a per-target override.
RELEASE_BINARY_HOOKS = {"post": [{"cmd": '../../scripts/ci/release-binary-check.sh "{{ .Path }}"', "output": True}]}


def check_goreleaser(config):
    builds = config.get("builds") or []
    if not builds:
        return ".goreleaser.yml has no builds"
    for build in builds:
        if build.get("hooks") != RELEASE_BINARY_HOOKS:
            return (
                f".goreleaser.yml's build {build.get('binary')!r} has hooks {build.get('hooks')!r}, "
                f"not exactly {RELEASE_BINARY_HOOKS!r}"
            )
    # The changelog step is what reads --release-notes (GoReleaser's
    # changelog pipe): disabled, it publishes an empty body.
    if "disable" in (config.get("changelog") or {}):
        return f".goreleaser.yml's changelog sets disable ({config.get('changelog')!r}), so the release note is never read"
    release = config.get("release") or {}
    # A tag with a pre-release publishes a GitHub pre-release, and
    # GoReleaser marks no release the repository's latest.
    if release.get("prerelease") != "auto":
        return f".goreleaser.yml's release has prerelease {release.get('prerelease')!r}, not auto"
    if release.get("make_latest") is not False:
        return f".goreleaser.yml's release has make_latest {release.get('make_latest')!r}, not false"
    globs = [str(e.get("glob")) for e in release.get("extra_files") or []]
    if SCAFFOLD_GLOB not in globs:
        return f".goreleaser.yml's release does not attach {SCAFFOLD_GLOB}"
    manifest = sorted(g for g in globs if "release.json" in g)
    if manifest != sorted(MANIFEST_GLOBS):
        return f".goreleaser.yml's release attaches {manifest} for the manifest, not exactly {MANIFEST_GLOBS}"
    packages = sorted(g for g in globs if "cyfr-desktop" in g or "RELEASE_PACKAGES_DIR" in g)
    if packages != sorted(PACKAGE_GLOBS):
        return f".goreleaser.yml's release attaches {packages} for the app, not exactly {PACKAGE_GLOBS}"
    # What is attached and fetched by its checksum is in the signed manifest.
    summed = sorted(str(e.get("glob")) for e in (config.get("checksum") or {}).get("extra_files") or [])
    if summed != sorted([SCAFFOLD_GLOB] + PACKAGE_GLOBS):
        return f".goreleaser.yml's checksums sum {summed}, not exactly the scaffold and {PACKAGE_GLOBS}"
    # The cask is the release workflow's, written from the DMG's bytes
    # (scripts/ci/homebrew-cask.sh): GoReleaser writes none, so none
    # installs a bare cyfr or strips the quarantine Homebrew sets.
    for key in ("homebrew_casks", "brews"):
        if key in config:
            return f".goreleaser.yml writes a Homebrew {key}, which the release workflow writes from the DMG alone"
    # checksums.txt is signed into the protobuf bundle sigstore-go reads:
    # cosign 2 writes its legacy bundle without --new-bundle-format, which
    # `cyfr init` and `cyfr update` refuse.
    signs = config.get("signs") or []
    if [(s.get("cmd"), s.get("artifacts"), s.get("signature"), s.get("args")) for s in signs] != [
        (CHECKSUM_SIGN_CMD, "checksum", "${artifact}.sigstore.json", CHECKSUM_SIGN_ARGS)
    ]:
        return (
            f".goreleaser.yml's signs are {signs}, not {CHECKSUM_SIGN_CMD} over checksums.txt "
            f"with {CHECKSUM_SIGN_ARGS}"
        )
    return None


def check_ignored(paths):
    for path in paths:
        result = subprocess.run(
            ["git", "-C", ROOT, "check-ignore", "-q", "--no-index", "--", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=60,
        )
        if result.returncode == 1:
            return f"{path} is not ignored by git, so GoReleaser finds the tree dirty"
        if result.returncode != 0:
            return f"git check-ignore {path} failed: {result.stderr.decode(errors='replace').strip()}"
    return None


# --- the manifest's rules, shared with tests/fixtures/release_manifest.json ---


def strict_json(data):
    def pairs(items):
        keys = [k for k, _ in items]
        if len(keys) != len(set(keys)):
            raise ValueError(f"duplicate keys in {keys}")
        return dict(items)

    def constant(name):
        raise ValueError(f"{name} is not JSON")

    return json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)


def validate_manifest(obj, rule=SEMVER):
    """None when obj is a release manifest, else the reason it is not:
    exactly version, images, scaffold and schema_fingerprint; images exactly
    cyfr, cyfr_locus, caddy and tailscale; every digest sha256:<64 lowercase
    hex>; the schema fingerprint 64 lowercase hex; the version a release
    version by rule."""
    if not isinstance(obj, dict):
        return f"the manifest is {type(obj).__name__}, not an object"
    if set(obj) != {"version", "images", "scaffold", "schema_fingerprint"}:
        return f"the manifest's keys are {sorted(obj)}, not images, scaffold, schema_fingerprint and version"
    fingerprint = obj["schema_fingerprint"]
    if not isinstance(fingerprint, str) or not FINGERPRINT.fullmatch(fingerprint):
        return f"the schema fingerprint {fingerprint!r} is not 64 lowercase hex"
    version = obj["version"]
    if not isinstance(version, str) or not rule.fullmatch(version):
        return f"the version {version!r} is not a {RELEASE_VERSION}"
    images = obj["images"]
    if not isinstance(images, dict) or set(images) != {"cyfr", "cyfr_locus", *PINNED_REPOS}:
        return f"the images are {images!r}, not exactly caddy, cyfr, cyfr_locus and tailscale"
    for name, digest in [*sorted(images.items()), ("scaffold", obj["scaffold"])]:
        if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
            return f"{name}'s digest {digest!r} is not sha256:<64 lowercase hex>"
    return None


def vector_failures(vectors, rule=SEMVER):
    """The vector file's valid release and pre-release manifests accepted,
    every refused one refused, every accepted version matched by rule and
    every refused one not. Returns (failures, manifests, versions)."""
    failures = []
    for key, manifest, prerelease in (
        ("valid", vectors.get("valid"), False),
        ("valid_prerelease", vectors.get("valid_prerelease"), True),
    ):
        reason = validate_manifest(manifest, rule)
        if reason:
            failures.append(f"the vector file's {key} manifest is refused: {reason}")
        elif ("-" in manifest["version"]) != prerelease:
            failures.append(f"the vector file's {key} manifest names {manifest['version']!r}")
    refused = vectors.get("refused")
    if not isinstance(refused, list) or not refused:
        failures.append("the vector file has no refused manifests")
        refused = []
    for case in refused:
        if not isinstance(case, dict) or set(case) != {"name", "manifest"}:
            failures.append(f"a refused vector is not {{name, manifest}}: {case!r}")
        elif validate_manifest(case["manifest"], rule) is None:
            failures.append(f"a refused manifest vector was accepted: {case['name']}")
    versions = vectors.get("versions")
    counted = 0
    for key, accepted in (("accepted", True), ("refused", False)):
        values = versions.get(key) if isinstance(versions, dict) else None
        if not isinstance(values, list) or not values or not all(isinstance(v, str) for v in values):
            failures.append(f"the vector file's versions.{key} is not a list of versions")
            continue
        counted += len(values)
        for version in values:
            if bool(rule.fullmatch(version)) != accepted:
                failures.append(
                    f"the rule {'refuses' if accepted else 'accepts'} {version!r}, which versions.{key} holds"
                )
    return failures, len(refused), counted


def check_vectors(path=VECTORS):
    with open(path, "rb") as f:
        return vector_failures(strict_json(f.read()))


# Rules that are not SEMVER: the vectors must tell each from it.
RULE_MUTANTS = [
    ("MAJOR.MINOR.PATCH alone", r"[0-9]+\.[0-9]+\.[0-9]+"),
    ("leading zeros", SEMVER.pattern.replace("(0|[1-9][0-9]*)", "[0-9]+")),
    ("build metadata", SEMVER.pattern + r"(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?"),
    (
        "word characters for letters",
        SEMVER.pattern.replace("[0-9A-Za-z-]", r"[\w-]").replace("[A-Za-z-]", r"(?:[^\W\d]|-)"),
    ),
    ("empty pre-release identifiers", SEMVER.pattern.replace("[0-9A-Za-z-]*)", "[0-9A-Za-z-]*|)")),
    ("a v prefix", "v?" + SEMVER.pattern),
    ("digits outside ASCII", SEMVER.pattern.replace("[1-9][0-9]*", r"[1-9]\d*").replace("(0|", r"(\d|")),
]


def vector_mutants(vectors):
    """Vector files a check of the vectors must refuse, each with its name."""

    def changed(name, mutate):
        v = copy.deepcopy(vectors)
        mutate(v)
        return name, v

    def move(source, target):
        def mutate(v):
            v["versions"][target].append(v["versions"][source].pop(0))

        return mutate

    return [
        changed("valid_prerelease dropped", lambda v: v.pop("valid_prerelease")),
        changed("valid_prerelease naming a release", lambda v: v["valid_prerelease"].update(version="1.2.3")),
        changed("versions dropped", lambda v: v.pop("versions")),
        changed("versions.accepted emptied", lambda v: v["versions"].update(accepted=[])),
        changed("a refused version among the accepted", move("refused", "accepted")),
        changed("an accepted version among the refused", move("accepted", "refused")),
    ]


def image_ref(line):
    match = IMAGE_LINE.match(line)
    return (match.group(1), match.group(2)) if match else (None, None)


def repository(ref):
    name = ref.split("@", 1)[0]
    head, sep, tail = name.rpartition(":")
    return head if sep and "/" not in tail else name


def compose_pinned(text, key):
    """The one digest docker-compose.yml's image lines pin PINNED_REPOS[key] at."""
    digests = []
    for line in text.splitlines():
        _, ref = image_ref(line)
        if ref is not None and repository(ref) == PINNED_REPOS[key]:
            digests.append(ref.split("@", 1)[1] if "@" in ref else None)
    if len(digests) < 1 or len(set(digests)) != 1 or not DIGEST.fullmatch(digests[0] or ""):
        return None, f"docker-compose.yml's {key} images name {digests}, not one digest"
    return digests[0], None


def check_scaffold_compose(text, manifest):
    """The scaffold's compose names exactly the manifest's images: every
    cyfr and cyfr-locus image at the release's version and digest, Caddy
    and Tailscale each at its digest, and no other image."""
    version, images = manifest["version"], manifest["images"]
    want = {
        CYFR_REPO: f"{CYFR_REPO}:{version}@{images['cyfr']}",
        LOCUS_REPO: f"{LOCUS_REPO}:{version}@{images['cyfr_locus']}",
    }
    pinned = {repo: key for key, repo in PINNED_REPOS.items()}
    seen = {CYFR_REPO: 0, LOCUS_REPO: 0, **{repo: 0 for repo in pinned}}
    for line in text.splitlines():
        if not re.match(r"^\s*image:", line):
            continue
        _, ref = image_ref(line)
        repo = repository(ref) if ref else None
        if repo in want and ref != want[repo]:
            return f"the scaffold's compose names {ref}, not {want[repo]}"
        if repo in pinned and not ref.endswith("@" + images[pinned[repo]]):
            return f"the scaffold's compose names {ref}, not {repo} at {images[pinned[repo]]}"
        if repo not in seen:
            return f"the scaffold's compose names {line.strip()!r}, which the manifest does not cover"
        seen[repo] += 1
    if 0 in seen.values():
        return f"the scaffold's compose names images {seen}, not each of cyfr, cyfr-locus, caddy and tailscale"
    return None


def tar_member(tarball, name):
    with tarfile.open(tarball, "r:gz") as tar:
        found = [m for m in tar.getmembers() if m.name == name]
        if len(found) != 1 or not found[0].isfile():
            return None
        return tar.extractfile(found[0]).read()


def check_manifest(data, version, scaffold, compose_text):
    try:
        manifest = strict_json(data)
    except ValueError as e:
        return f"release.json is not one strict JSON value: {e}"
    reason = validate_manifest(manifest)
    if reason:
        return reason
    if not SEMVER.fullmatch(version):
        return f"the tag {version!r} is not a {RELEASE_VERSION}"
    if manifest["version"] != version:
        return f"release.json is release {manifest['version']}, the tag {version}"
    with open(scaffold, "rb") as f:
        digest = "sha256:" + hashlib.sha256(f.read()).hexdigest()
    if manifest["scaffold"] != digest:
        return f"release.json's scaffold is {manifest['scaffold']}, the tarball's digest {digest}"
    for key in PINNED_REPOS:
        digest, reason = compose_pinned(compose_text, key)
        if reason:
            return reason
        if manifest["images"][key] != digest:
            return f"release.json's {key} is {manifest['images'][key]}, docker-compose.yml's {digest}"
    try:
        staged = tar_member(scaffold, "docker-compose.yml")
    except (tarfile.TarError, OSError) as e:
        return f"the scaffold is not a readable tarball: {e}"
    if staged is None:
        return "the scaffold holds no one docker-compose.yml at its root"
    return check_scaffold_compose(staged.decode("utf-8"), manifest)


def manifest_mode(argv):
    """--manifest FILE --version VERSION --scaffold TARBALL, each once."""
    args = {}
    rest = list(argv)
    while rest:
        flag = rest.pop(0)
        if flag not in ("--manifest", "--version", "--scaffold") or flag in args or not rest:
            print("usage: ci-release-graph.py [--manifest FILE --version VERSION --scaffold TARBALL]", file=sys.stderr)
            return 64
        args[flag] = rest.pop(0)
    if len(args) != 3:
        print("usage: ci-release-graph.py [--manifest FILE --version VERSION --scaffold TARBALL]", file=sys.stderr)
        return 64
    with open(args["--manifest"], "rb") as f:
        data = f.read()
    with open(COMPOSE) as f:
        compose = f.read()
    reason = check_manifest(data, args["--version"], args["--scaffold"], compose)
    if reason:
        print(f"FAIL: {reason}")
        return 1
    print(f"release manifest ok: {args['--manifest']} is release {args['--version']} and names its scaffold and images")
    return 0


# --- the installers and the cask, before anything is published ---

# The cask this release must publish, whole: what Homebrew has been shown
# to read (Codex CI's local tap installs, upgrades and removes the cask
# scripts/ci/homebrew-cask.sh writes, through brew itself), at this
# release's version and download folder, naming its Apple silicon DMG by
# its digest, for Apple silicon alone. The release's check compares the cask with it byte for byte;
# the graph test compares the script's output with it, so neither can
# change without the other.
CASK_TEMPLATE = """cask "cyfr" do
  version "{version}"
  sha256 "{sum}"

  url "{base}/cyfr-desktop_#{{version}}_darwin_arm64.dmg"
  name "CYFR"
  desc "App and CLI for the CYFR sandboxed runtime"
  homepage "https://cyfr.run/"

  depends_on arch: :arm64
  depends_on :macos

  app "CYFR.app"
  binary "#{{appdir}}/CYFR.app/Contents/Resources/cyfr"
end
"""


def release_cask(folder, version):
    """The cask this release must publish, from the DMG in FOLDER."""
    dmg = file_sha256(os.path.join(folder, installer_name(version, "darwin", "arm64")))
    return CASK_TEMPLATE.format(version=version, sum=dmg, base=CASK_URL_BASE)


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_installers(folder, version, cask):
    """The folder GoReleaser sums and attaches holds exactly the five
    installers at VERSION, each a non-empty file of its own bytes, and the
    cask is exactly release_cask's text for them."""
    if not SEMVER.fullmatch(version):
        return f"{version!r} is not a {RELEASE_VERSION}"
    want = sorted(installer_name(version, s, a) for s, a in INSTALLERS)
    try:
        got = sorted(os.listdir(folder))
    except OSError as e:
        return f"the installers' folder cannot be read: {e}"
    if got != want:
        return f"the installers' folder holds {got}, not exactly {want}"
    for name in want:
        path = os.path.join(folder, name)
        if os.path.islink(path) or not os.path.isfile(path) or os.path.getsize(path) == 0:
            return f"{name} is not a non-empty file"
    # Each installer is its own build: two of the same bytes are one
    # architecture's or one system's package under two names.
    by_digest = {}
    for name in want:
        by_digest.setdefault(file_sha256(os.path.join(folder, name)), []).append(name)
    for names in by_digest.values():
        if len(names) > 1:
            return f"{' and '.join(names)} are the same bytes"
    want_cask = release_cask(folder, version)
    if cask != want_cask:
        got_lines, want_lines = cask.split("\n"), want_cask.split("\n")
        at = next((i for i, (g, w) in enumerate(zip(got_lines, want_lines)) if g != w), min(len(got_lines), len(want_lines)))
        got_line = got_lines[at] if at < len(got_lines) else "(its end)"
        want_line = want_lines[at] if at < len(want_lines) else "(its end)"
        return f"the cask is not the one this release must publish: line {at + 1} is {got_line!r}, not {want_line!r}"
    return None


# The cask script run for real on a folder of the five installers (and the
# CLI's Mac archive beside them, which a cask must never name), its cask
# checked as the release checks it; then mutants of the script, of its
# cask and of the folder, each refused.
CASK_SCRIPT_MUTANTS = [
    ("the CLI archive's digest", lambda s: s.replace('dmg="$dir/cyfr-desktop_${version}_darwin_arm64.dmg"', 'dmg="$dir/cyfr_${version}_darwin_arm64.tar.gz"')),
    ("an Intel Mac let install it", lambda s: s.replace("  depends_on arch: :arm64\n", "")),
    ("a fixed version", lambda s: s.replace('  version "$version"', '  version "0.0.0"')),
    ("the quarantine stripped", lambda s: s.replace('  binary "#{appdir}', '  postflight do\n    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/CYFR.app"]\n  end\n  binary "#{appdir}')),
    ("the raw binary", lambda s: s.replace('  binary "#{appdir}/CYFR.app/Contents/Resources/cyfr"', '  binary "cyfr"')),
    ("no app", lambda s: s.replace('  app "CYFR.app"\n', "")),
    ("a missing DMG passed over", lambda s: s.replace('[ -f "$dmg" ] || { echo "$0: no $dmg" >&2; exit 1; }', '[ -f "$dmg" ] || dmg=/dev/null')),
    # The script and the checker cannot drift apart: the generator's text
    # changed alone is refused by the comparison with the checker's.
    ("its text changed alone", lambda s: s.replace('  desc "App and CLI for the CYFR sandboxed runtime"', '  desc "The CYFR app and its CLI"')),
]
CASK_TEXT_MUTANTS = [
    ("a second url", lambda c: c.replace('  name "CYFR"', '  url "https://example.com/cyfr.dmg"\n  name "CYFR"')),
    ("the latest release's url", lambda c: c.replace("releases/download/", "releases/latest/download/")),
    ("a preflight", lambda c: c.replace('  app "CYFR.app"', '  preflight do\n  end\n  app "CYFR.app"')),
    ("an installer of its own", lambda c: c.replace('  app "CYFR.app"', '  pkg "CYFR.pkg"\n  app "CYFR.app"')),
    ("a second app", lambda c: c.replace('  app "CYFR.app"', '  app "CYFR.app"\n  app "Other.app"')),
    ("another sha256", lambda c: re.sub(r'sha256 "[0-9a-f]{64}"', 'sha256 "%s"' % ("0" * 64), c, count=1)),
    ("no architecture it needs", lambda c: c.replace("  depends_on arch: :arm64\n", "")),
    ("Intel's architecture beside it", lambda c: c.replace("depends_on arch: :arm64", "depends_on arch: [:arm64, :x86_64]")),
    ("the Intel DMG's url", lambda c: c.replace("_darwin_arm64.dmg", "_darwin_amd64.dmg")),
    ("no end", lambda c: c[: c.rindex("end")]),
    ("an unterminated string", lambda c: c.replace('desc "App and CLI for the CYFR sandboxed runtime"', 'desc "unfinished')),
    ("a string closed by another quote", lambda c: c.replace('name "CYFR"', "name \"CYFR'")),
    ("an unmatched parenthesis", lambda c: c.replace('  depends_on :macos', '  depends_on(:macos')),
    ("the url before the version it reads", lambda c: c.replace('  version "', '  url "%s/cyfr-desktop_#{version}_darwin_arm64.dmg"\n  version "' % CASK_URL_BASE, 1).replace('\n\n  url "%s/cyfr-desktop_#{version}_darwin_arm64.dmg"\n' % CASK_URL_BASE, '\n\n', 1)),
    ("one space more before the version", lambda c: c.replace('  version "', '  version  "', 1)),
    ("no newline at its end", lambda c: c.rstrip("\n")),
]


def cask_failures(version):
    """Returns (failures, cases)."""
    failures = []
    work = tempfile.mkdtemp(prefix="cask-", dir=scratch())
    folder = os.path.join(work, "packages")
    os.makedirs(folder)
    for system, arch in INSTALLERS:
        with open(os.path.join(folder, installer_name(version, system, arch)), "w") as f:
            f.write(f"the {system} {arch} installer\n")
    beside = os.path.join(work, "beside")
    shutil.copytree(folder, beside)
    with open(os.path.join(beside, f"cyfr_{version}_darwin_arm64.tar.gz"), "w") as f:
        f.write("the CLI's arm64 archive\n")
    with open(CASK_SCRIPT) as f:
        script = f.read()

    def run(text, at):
        path = os.path.join(work, "cask.sh")
        with open(path, "w") as f:
            f.write(text)
        result = subprocess.run(["bash", path, version, at, CASK_URL_BASE], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        return result.returncode, result.stdout.decode(errors="replace")

    cases = 0
    status, cask = run(script, folder)
    cases += 1
    if status != 0:
        failures.append(f"homebrew-cask.sh exits {status} on the five installers")
        return failures, cases
    # The generator's cask is the checker's text, byte for byte.
    reason = check_installers(folder, version, cask)
    if reason:
        failures.append(f"homebrew-cask.sh's cask is not the checker's: {reason}")
        return failures, cases
    missing = os.path.join(work, "missing")
    shutil.copytree(folder, missing)
    os.remove(os.path.join(missing, installer_name(version, "darwin", "arm64")))
    status, out = run(script, missing)
    cases += 1
    if status != 1 or out:
        failures.append(f"homebrew-cask.sh without the DMG exits {status} writing {len(out)} bytes, not 1 and none")
    for name, mutate in CASK_SCRIPT_MUTANTS:
        mutant = mutate(script)
        cases += 1
        if mutant == script:
            failures.append(f"a mutant changed nothing: homebrew-cask.sh, {name}")
            continue
        at = missing if name == "a missing DMG passed over" else beside if name == "the CLI archive's digest" else folder
        status, out = run(mutant, at)
        if status == 0 and check_installers(folder, version, out) is None:
            failures.append(f"a mutant of homebrew-cask.sh was accepted: {name}")
    for name, mutate in CASK_TEXT_MUTANTS:
        mutant = mutate(cask)
        cases += 1
        if mutant == cask:
            failures.append(f"a mutant changed nothing: the cask, {name}")
        elif check_installers(folder, version, mutant) is None:
            failures.append(f"a mutant of the cask was accepted: {name}")
    for name, change in [
        ("a sixth file", lambda d: open(os.path.join(d, "cyfr_%s_darwin_arm64.tar.gz" % version), "w").close()),
        ("an MSI missing", lambda d: os.remove(os.path.join(d, installer_name(version, "windows", "arm64")))),
        ("an empty DEB", lambda d: open(os.path.join(d, installer_name(version, "linux", "amd64")), "w").close()),
        ("two installers of the same bytes",
         lambda d: shutil.copyfile(os.path.join(d, installer_name(version, "windows", "amd64")),
                                   os.path.join(d, installer_name(version, "windows", "arm64")))),
        ("a DMG changed after the cask was written",
         lambda d: open(os.path.join(d, installer_name(version, "darwin", "arm64")), "a").write("x")),
    ]:
        planted = tempfile.mkdtemp(prefix="installers-", dir=work)
        os.rmdir(planted)
        shutil.copytree(folder, planted)
        change(planted)
        cases += 1
        if check_installers(planted, version, cask) is None:
            failures.append(f"the installers' check accepted a folder with {name}")
    cases += 1
    if check_installers(folder, other_version(version), cask) is None:
        failures.append("the installers' check accepted the five of another version")
    cases += 1
    usage = subprocess.run([sys.executable, "-I", os.path.abspath(__file__), "--installers", folder, "--version", version],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    if usage.returncode != 64:
        failures.append(f"the installers mode exits {usage.returncode} without --cask, not 64")
    return failures, cases


# tests/desktop-proof/native/installed-machine.sh against headers of each
# system's executables for each architecture: an amd64 app or cyfr in an
# arm64 package, which emulation runs, is refused, as is any file it cannot
# read as one architecture's.
INSTALLED_MACHINE = os.path.join(ROOT, "tests", "desktop-proof", "native", "installed-machine.sh")
MACHINES = {"amd64": {"elf": 0x3E, "macho": 0x01000007, "pe": 0x8664}, "arm64": {"elf": 0xB7, "macho": 0x0100000C, "pe": 0xAA64}}


def executable_header(kind, arch):
    machine = MACHINES[arch][kind]
    if kind == "elf":
        return b"\x7fELF\x02\x01\x01" + bytes(11) + machine.to_bytes(2, "little") + bytes(44)
    if kind == "macho":
        return b"\xcf\xfa\xed\xfe" + machine.to_bytes(4, "little") + bytes(24)
    return b"MZ" + bytes(0x3A) + (0x40).to_bytes(4, "little") + b"PE\x00\x00" + machine.to_bytes(2, "little") + bytes(18)


def installed_machine_failures():
    failures = []
    work = tempfile.mkdtemp(prefix="machine-", dir=scratch())

    def made(name, data):
        path = os.path.join(work, name)
        with open(path, "wb") as f:
            f.write(data)
        return path

    files = {(kind, arch): made(f"{kind}-{arch}", executable_header(kind, arch)) for kind in ("elf", "macho", "pe") for arch in MACHINES}
    universal = made("universal", b"\xca\xfe\xba\xbe" + bytes(28))
    script = made("script", b"#!/bin/sh\necho cyfr version 1.2.3\n")
    no_pe = made("mz-alone", b"MZ" + bytes(0x3A) + (0x40).to_bytes(4, "little") + b"XX\x00\x00" + bytes(20))
    cases = []
    for kind in ("elf", "macho", "pe"):
        cases.append((f"the {kind} app and cyfr of arm64", "arm64", [files[(kind, "arm64")], files[(kind, "arm64")]], 0))
        cases.append((f"the {kind} app and cyfr of amd64", "amd64", [files[(kind, "amd64")], files[(kind, "amd64")]], 0))
        cases.append((f"an amd64 {kind} app in the arm64 package", "arm64", [files[(kind, "amd64")], files[(kind, "arm64")]], 1))
        cases.append((f"an amd64 {kind} cyfr in the arm64 package", "arm64", [files[(kind, "arm64")], files[(kind, "amd64")]], 1))
        cases.append((f"an arm64 {kind} app in the amd64 package", "amd64", [files[(kind, "arm64")]], 1))
    cases += [
        ("a universal Mach-O", "arm64", [universal], 1),
        ("a script", "arm64", [script], 1),
        ("an MZ file with no PE header", "amd64", [no_pe], 1),
        ("a file that is not there", "arm64", [os.path.join(work, "missing")], 1),
        ("no file", "arm64", [], 64),
        ("another architecture's name", "x86_64", [files[("elf", "amd64")]], 64),
    ]
    for name, arch, paths, want in cases:
        result = subprocess.run(["bash", INSTALLED_MACHINE, arch, *paths], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if result.returncode != want:
            failures.append(f"installed-machine.sh exits {result.returncode} for {name}, not {want}")
    return failures, len(cases)


# tests/desktop-proof/native/installed-version.sh against a cyfr that
# answers each version line.
INSTALLED_VERSION = os.path.join(ROOT, "tests", "desktop-proof", "native", "installed-version.sh")


def installed_version_failures():
    failures = []
    work = tempfile.mkdtemp(prefix="installed-", dir=scratch())
    cases = [
        ("cyfr version 1.2.3\ncommit abc", 0, 0),
        ("cyfr version 1.2.3", 0, 0),
        ("cyfr version 1.2.4\ncommit abc", 0, 1),
        ("cyfr version 1.2.3-rc.1", 0, 1),
        ("cyfr version 1.2", 0, 1),
        ("cyfr version 1.2.3", 3, 1),
    ]
    for i, (said, exit_status, want) in enumerate(cases):
        stub = os.path.join(work, f"cyfr-{i}")
        with open(stub, "w") as f:
            f.write("#!/bin/sh\nprintf '%%s\\n' '%s'\nexit %d\n" % (said.replace("\n", "' '"), exit_status))
        os.chmod(stub, 0o755)
        result = subprocess.run(["bash", INSTALLED_VERSION, stub, "1.2.3"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if (result.returncode == 0) != (want == 0):
            failures.append(f"installed-version.sh exits {result.returncode} for a cyfr saying {said!r} with exit {exit_status}")
    return failures, len(cases)


def installers_mode(argv):
    """--installers FOLDER --version VERSION --cask FILE, each once."""
    usage = "usage: ci-release-graph.py --installers FOLDER --version VERSION --cask FILE"
    args = {}
    rest = list(argv)
    while rest:
        flag = rest.pop(0)
        if flag not in ("--installers", "--version", "--cask") or flag in args or not rest:
            print(usage, file=sys.stderr)
            return 64
        args[flag] = rest.pop(0)
    if len(args) != 3:
        print(usage, file=sys.stderr)
        return 64
    try:
        with open(args["--cask"], encoding="utf-8") as f:
            cask = f.read()
    except (OSError, UnicodeDecodeError) as e:
        print(f"FAIL: the cask cannot be read: {e}")
        return 1
    reason = check_installers(args["--installers"], args["--version"], cask)
    if reason:
        print(f"FAIL: {reason}")
        return 1
    print(f"installers ok: {args['--installers']} holds the five installers of {args['--version']}, and the cask names its DMG")
    return 0


# --- the scaffold pinned to the release's images, run for real ---

FAKE_CYFR = "sha256:" + hashlib.sha256(b"cyfr").hexdigest()
FAKE_LOCUS = "sha256:" + hashlib.sha256(b"cyfr-locus").hexdigest()


def run_scaffold(root, args):
    result = subprocess.run(
        ["bash", os.path.join(root, "scripts", "scaffold-tarball.sh"), *args],
        env={**os.environ, "LC_ALL": range_locale()},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=300,
    )
    return result.returncode, result.stdout.decode(errors="replace")


def tar_names(tarball):
    with tarfile.open(tarball, "r:gz") as tar:
        return tar.getnames()


def compare_pinned(repo_text, staged_text, version, cyfr, locus):
    """The staged compose is the repository's with each cyfr and cyfr-locus
    image line naming VERSION@its digest, and every image line pinned."""
    repo_lines, staged_lines = repo_text.split("\n"), staged_text.split("\n")
    if len(repo_lines) != len(staged_lines):
        return f"the scaffold's compose has {len(staged_lines)} lines, the repository's {len(repo_lines)}"
    count = {CYFR_REPO: 0, LOCUS_REPO: 0}
    for number, (old, new) in enumerate(zip(repo_lines, staged_lines), 1):
        lead, ref = image_ref(old)
        repo = repository(ref) if ref else None
        if repo == CYFR_REPO:
            want = f"{lead}{CYFR_REPO}:{version}@{cyfr}"
        elif repo == LOCUS_REPO:
            want = f"{lead}{LOCUS_REPO}:{version}@{locus}"
        else:
            want = old
        if repo in count:
            count[repo] += 1
        if new != want:
            return f"the scaffold's compose line {number} is {new!r}, not {want!r}"
        if re.match(r"^\s*image:", new) and not re.search(r"@sha256:[0-9a-f]{64}\s*$", new):
            return f"the scaffold's compose line {number} names no digest: {new.strip()!r}"
    if 0 in count.values():
        return f"the scaffold's compose pins {count}, not at least one cyfr and one cyfr-locus image"
    return None


def check_scaffold(root, out, version, cyfr=FAKE_CYFR, locus=FAKE_LOCUS):
    """Runs root's scripts/scaffold-tarball.sh plain and pinned into out."""
    with open(os.path.join(root, "docker-compose.yml"), "rb") as f:
        before = f.read()
    plain = os.path.join(out, "plain.tar.gz")
    pinned = os.path.join(out, "pinned.tar.gz")
    status, output = run_scaffold(root, [plain])
    if status != 0:
        return f"scaffold-tarball.sh OUTPUT exits {status}: {output.strip()[-300:]}"
    status, output = run_scaffold(root, [pinned, version, cyfr, locus])
    if status != 0:
        return f"scaffold-tarball.sh OUTPUT VERSION CYFR LOCUS exits {status}: {output.strip()[-300:]}"
    with open(os.path.join(root, "docker-compose.yml"), "rb") as f:
        if f.read() != before:
            return "scaffold-tarball.sh changed the repository's docker-compose.yml"
    if tar_member(plain, "docker-compose.yml") != before:
        return "the plain scaffold's docker-compose.yml is not the repository's"
    if tar_names(plain) != tar_names(pinned):
        return "the pinned scaffold's entries are not the plain scaffold's, in the same order"
    staged = tar_member(pinned, "docker-compose.yml")
    if staged is None:
        return "the pinned scaffold holds no one docker-compose.yml at its root"
    return compare_pinned(before.decode("utf-8"), staged.decode("utf-8"), version, cyfr, locus)


def refused_scaffold_args(out, version):
    a, b = FAKE_CYFR, FAKE_LOCUS
    o = os.path.join(out, "refused.tar.gz")
    return o, [
        ("no output", []),
        ("an empty output alone", [""]),
        ("a version without digests", [o, version]),
        ("one digest", [o, version, a]),
        ("five arguments", [o, version, a, b, b]),
        ("a v-prefixed version", [o, "v" + version, a, b]),
        ("a version with build metadata", [o, version + "+build.5", a, b]),
        ("an upper-case digest", [o, version, "sha256:" + a[7:].upper(), b]),
        ("a short digest", [o, version, a, b[:-1]]),
        ("a sha512 digest", [o, version, a, "sha512:" + "0" * 128]),
        ("a tag for a digest", [o, version, "latest", b]),
        ("an empty output", ["", version, a, b]),
    ]


def planted_tree(name, compose_text, script_text=None):
    """A tree whose docker-compose.yml and scaffold script are the given
    ones, every other top-level entry a link to the repository's."""
    tree = os.path.join(scratch(), "tree-" + name)
    os.makedirs(os.path.join(tree, "scripts"))
    for entry in os.listdir(ROOT):
        if entry not in ("scripts", "docker-compose.yml"):
            os.symlink(os.path.join(ROOT, entry), os.path.join(tree, entry))
    if script_text is None:
        with open(os.path.join(ROOT, "scripts", "scaffold-tarball.sh")) as f:
            script_text = f.read()
    with open(os.path.join(tree, "scripts", "scaffold-tarball.sh"), "w") as f:
        f.write(script_text)
    with open(os.path.join(tree, "docker-compose.yml"), "w") as f:
        f.write(compose_text)
    return tree


def planted_composes(text):
    """Composes the pinned scaffold must refuse."""
    caddy = re.search(r"^(\s*image:\s*caddy:[^@\s]*)@sha256:[0-9a-f]{64}\s*$", text, re.MULTILINE)
    tailscale = re.search(r"^(\s*image:\s*tailscale/tailscale:[^@\s]*)@sha256:[0-9a-f]{64}\s*$", text, re.MULTILINE)
    extra = "\n  extra:\n    image: %s\n"
    return [
        ("an unpinned caddy", text.replace(caddy.group(0), caddy.group(1)) if caddy else text),
        ("an unpinned tailscale", text.replace(tailscale.group(0), tailscale.group(1)) if tailscale else text),
        ("another unpinned image", text + extra % "postgres:18"),
        ("a repository cyfr-locus is a prefix of", text + extra % (LOCUS_REPO + "-extra:latest")),
        ("no cyfr image", re.sub(r"ghcr\.io/cyfrworks/cyfr:\S+", LOCUS_REPO + ":latest", text)),
        ("no cyfr-locus image", re.sub(r"ghcr\.io/cyfrworks/cyfr-locus:\S+", CYFR_REPO + ":latest", text)),
    ]


def scaffold_version_failure(root, accepted, refused):
    """root's scaffold-tarball.sh pins each accepted version and refuses
    each refused one with 64 before writing anything: the first failure, or
    None."""
    with open(os.path.join(root, "scripts", "scaffold-tarball.sh")) as f:
        if not matches_in_c_locale(f.read().splitlines()):
            return f"scaffold-tarball.sh matches the version before {C_LOCALE!r}"
    with open(os.path.join(root, "docker-compose.yml")) as f:
        compose = f.read()
    out = tempfile.mkdtemp(prefix="versions-", dir=scratch())
    for i, version in enumerate(accepted):
        tarball = os.path.join(out, "accepted-%d.tar.gz" % i)
        status, output = run_scaffold(root, [tarball, version, FAKE_CYFR, FAKE_LOCUS])
        if status != 0 or not os.path.isfile(tarball):
            return f"scaffold-tarball.sh exits {status} on the release version {version!r}: {output.strip()[-300:]}"
        staged = tar_member(tarball, "docker-compose.yml")
        if staged is None:
            return f"the scaffold pinned at {version!r} holds no one docker-compose.yml at its root"
        reason = compare_pinned(compose, staged.decode("utf-8"), version, FAKE_CYFR, FAKE_LOCUS)
        if reason:
            return f"the scaffold pinned at {version!r}: {reason}"
    target = os.path.join(out, "refused.tar.gz")
    for version in refused:
        status, _ = run_scaffold(root, [target, version, FAKE_CYFR, FAKE_LOCUS])
        if status != 64 or os.path.exists(target):
            return f"scaffold-tarball.sh exits {status} on {version!r}, no release version, not 64 with nothing written"
    return None


# SEMVER as the bash scripts spell it, anchored: the mutants replace it.
BASH_RULE = "'^" + SEMVER.pattern + "$'"
BARE_RULE = r"'^[0-9]+\.[0-9]+\.[0-9]+$'"
SCAFFOLD_RULE = "RELEASE=" + BASH_RULE
SCAFFOLD_MUTANTS = [
    ("the rule without pre-releases", lambda t: t.replace(SCAFFOLD_RULE, "RELEASE=" + BARE_RULE, 1)),
    ("the rule unanchored at its end", lambda t: t.replace(SCAFFOLD_RULE, SCAFFOLD_RULE.replace("?$'", "?'"), 1)),
    ("no LC_ALL=C", lambda t: t.replace("\n" + C_LOCALE + "\n", "\n", 1)),
    ("the version unchecked", lambda t: t.replace('    [[ "$VERSION" =~ $RELEASE ]] || usage\n', "", 1)),
]


def scaffold_failures(version):
    """The scaffold pinned on the real tree at its version and at each of
    the vector file's, its refused argument forms and versions, its refusal
    of planted composes, and mutants of the script each refused. Returns
    (failures, pinned tarball, counts)."""
    failures = []
    out = os.path.join(scratch(), "scaffold")
    os.makedirs(out)
    reason = check_scaffold(ROOT, out, version)
    if reason:
        failures.append(reason)
    accepted, refused = version_vectors()
    reason = scaffold_version_failure(ROOT, accepted, refused)
    if reason:
        failures.append(reason)
    with open(COMPOSE) as f:
        text = f.read()
    with open(os.path.join(ROOT, "scripts", "scaffold-tarball.sh")) as f:
        script = f.read()
    for i, (name, mutate) in enumerate(SCAFFOLD_MUTANTS):
        mutant = mutate(script)
        if mutant == script:
            failures.append(f"a mutant changed nothing: scaffold-tarball.sh, {name}")
        elif scaffold_version_failure(planted_tree("script-%d" % i, text, mutant), accepted, refused) is None:
            failures.append(f"a mutant of scaffold-tarball.sh was accepted: {name}")
    target, cases = refused_scaffold_args(out, version)
    for name, args in cases:
        status, output = run_scaffold(ROOT, args)
        if status != 64 or os.path.exists(target):
            failures.append(f"scaffold-tarball.sh exits {status} on {name}, not 64 with nothing written")
    planted = planted_composes(text)
    for i, (name, compose) in enumerate(planted):
        if compose == text:
            failures.append(f"a planted compose changed nothing: {name}")
            continue
        tree = planted_tree("refused-%d" % i, compose)
        tarball = os.path.join(tree, "out.tar.gz")
        status, _ = run_scaffold(tree, [tarball, version, FAKE_CYFR, FAKE_LOCUS])
        if status == 0 or os.path.exists(tarball):
            failures.append(f"scaffold-tarball.sh pinned a compose with {name}")
    counts = (len(cases), len(planted), len(accepted), len(refused))
    return failures, os.path.join(out, "pinned.tar.gz"), counts


# --- scripts/release.sh: the release helper, in disposable repositories ---

RELEASE_SH = os.path.join(ROOT, "scripts", "release.sh")
HELPER_APPS = ["arca", "cyfr", "locus", "prima", "sanctum"]
HELPER_BASE = "0.0.0"
# The written note each run of the helper is given (--notes): a heading
# whose # git's default cleanup would strip, so the tag must keep it as
# written.
HELPER_NOTE = "# Start on an empty database\n\nThe schema changed: run cyfr uninstall, then install this release.\n"


def helper_mixfiles(repo):
    return [os.path.join(repo, "mix.exs")] + [os.path.join(repo, "apps", app, "mix.exs") for app in HELPER_APPS]


def declare(path, version):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f'defmodule Planted.MixProject do\n  def project do\n    [\n      version: "{version}",\n    ]\n  end\nend\n')


def helper_env(repo, bin_dir=None):
    """What the helper runs under: no configuration of the host's git, an
    identity of its own, the range locale, and the stand-in gh and mix
    (helper_bin) ahead on PATH, gh answering HEAD green on GitHub with its
    Test run (HELPER_GREEN_RUNS, HELPER_GREEN_TEST) unless the caller's
    environment says otherwise; bin_dir, when given, ahead of them."""
    path = helper_bin() + ":" + os.environ.get("PATH", "/usr/bin:/bin")
    env = {
        "PATH": f"{bin_dir}:{path}" if bin_dir else path,
        "HOME": repo,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "graph",
        "GIT_AUTHOR_EMAIL": "graph@example.invalid",
        "GIT_COMMITTER_NAME": "graph",
        "GIT_COMMITTER_EMAIL": "graph@example.invalid",
        "LC_ALL": range_locale(),
        "GH_CHECK_RUNS": HELPER_GREEN_RUNS,
        "GH_WORKFLOW_RUNS": HELPER_GREEN_TEST,
    }
    return env


def helper_git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, env=helper_env(repo), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60
    ).stdout.decode(errors="replace").strip()


_HELPER_REPOS = []


def helper_repo(script, declared, scripts=None):
    """A repository of its own holding script as scripts/release.sh, the
    passing audits (HELPER_AUDIT) and each of scripts ({name: text}) as
    scripts/NAME, and the root's and five
    applications' mix.exs declaring declared, committed, with an origin of
    its own (helper_origin) whose main is that commit."""
    repo = os.path.join(scratch(), "helper-%d" % len(_HELPER_REPOS))
    _HELPER_REPOS.append(repo)
    os.makedirs(os.path.join(repo, "scripts"))
    with open(os.path.join(repo, "scripts", "release.sh"), "w") as f:
        f.write(script)
    for name, text in {"dependency-audit.sh": HELPER_AUDIT, **(scripts or {})}.items():
        with open(os.path.join(repo, "scripts", name), "w") as f:
            f.write(text)
        os.chmod(os.path.join(repo, "scripts", name), 0o755)
    for path in helper_mixfiles(repo):
        declare(path, declared)
    helper_git(repo, "init", "-q")
    helper_git(repo, "add", ".")
    helper_git(repo, "commit", "-qm", "baseline")
    helper_git(repo, "init", "-q", "--bare", helper_origin(repo))
    helper_git(repo, "remote", "add", "origin", helper_origin(repo))
    helper_git(repo, "push", "-q", "origin", "HEAD:refs/heads/main")
    return repo


def helper_origin(repo):
    """The bare repository beside repo that is its origin."""
    return repo + "-origin.git"


def run_helper(repo, version, answer=None, args=(), bin_dir=None, extra_env=None, notes=HELPER_NOTE):
    """scripts/release.sh VERSION ARGS... --notes FILE in repo, FILE outside
    it holding notes (no --notes when notes is None), its standard input a
    terminal holding answer when one is given (the dirty-tree prompt asks
    only on a terminal), else nothing, under helper_env(repo, bin_dir)
    and extra_env. Returns (status, output)."""
    if notes is not None:
        path = os.path.join(scratch(), "notes-" + hashlib.sha256(notes.encode()).hexdigest()[:12] + ".md")
        with open(path, "w") as f:
            f.write(notes)
        args = [*args, "--notes", path]
    master = slave = None
    stdin = subprocess.DEVNULL
    if answer is not None:
        master, slave = os.openpty()
        os.write(master, answer.encode())
        stdin = slave
    try:
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", os.path.join(repo, "scripts", "release.sh"), version, *args],
            cwd=repo,
            env={**helper_env(repo, bin_dir), **(extra_env or {})},
            stdin=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
    finally:
        for fd in (master, slave):
            if fd is not None:
                os.close(fd)
    return result.returncode, result.stdout.decode(errors="replace")


def helper_state(repo):
    """The repository's commits, tags and changes, which a refusal leaves as they were."""
    return (
        helper_git(repo, "rev-list", "--count", "HEAD"),
        helper_git(repo, "tag", "-l"),
        helper_git(repo, "status", "--porcelain"),
    )


def declares_at(repo, ref, version):
    """Whether every mix.exs at ref declares version."""
    for path in helper_mixfiles(repo):
        rel = os.path.relpath(path, repo)
        if f'version: "{version}"' not in helper_git(repo, "show", f"{ref}:{rel}"):
            return False
    return True


def tag_note_failure(repo, version):
    """Why the tag version in repo is not annotated with the subject
    `Release <version>` and HELPER_NOTE beneath it as written, or None."""
    ref = f"refs/tags/{version}"
    kind = helper_git(repo, "for-each-ref", "--format=%(objecttype)", ref)
    subject = helper_git(repo, "for-each-ref", "--format=%(contents:subject)", ref)
    body = helper_git(repo, "for-each-ref", "--format=%(contents:body)", ref)
    if kind != "tag" or subject != f"Release {version}" or body != HELPER_NOTE.strip():
        return f"release.sh's tag {version} is a {kind!r} with subject {subject!r} and note {body!r}, not its written note"
    return None


def helper_failure(script):
    """release.sh, run in disposable repositories: each accepted version is
    bumped, committed and tagged; each refused one is refused with nothing
    changed; a HEAD that declares the version already is tagged without a
    commit, with another file left uncommitted too; a version edited into
    the mix.exs files and not committed is refused, nothing tagged; a bump
    made over another change already staged commits the mix.exs files
    alone and leaves that change staged; then the proof on GitHub, the
    tag held to the proved commit and the pushes (helper_proof_failure,
    helper_bump_failure, helper_push_failure). The first failure, or None."""
    lines = script.splitlines()
    if not any("=~ $RELEASE" in line and "LC_ALL=C" in line for line in lines):
        return "release.sh does not match the version under LC_ALL=C"
    accepted, refused = version_vectors()
    for version in accepted:
        repo = helper_repo(script, "0.0.1" if version == HELPER_BASE else HELPER_BASE)
        status, output = run_helper(repo, version)
        if status != 0:
            return f"release.sh exits {status} on the release version {version!r}: {output.strip()[-300:]}"
        if helper_git(repo, "tag", "-l") != version or not declares_at(repo, version, version):
            return f"release.sh on {version!r} tagged {helper_git(repo, 'tag', '-l')!r}, not a commit declaring it"
        if helper_git(repo, "rev-list", "--count", "HEAD") != "2":
            return f"release.sh on {version!r} made no bump commit"
        reason = tag_note_failure(repo, version)
        if reason:
            return reason
    repo = helper_repo(script, HELPER_BASE)
    before = helper_state(repo)
    for version in refused:
        status, _ = run_helper(repo, version)
        if status == 0 or helper_state(repo) != before:
            return f"release.sh exits {status} on {version!r}, no release version, or changed the repository"
    # A release without its written note is refused before anything is made.
    for what, notes, args in (
        ("no --notes", None, ()),
        ("an empty notes file", "", ()),
        ("a notes file of blank lines", " \n\t\n", ()),
        ("a notes file that is not there", None, ("--notes", os.path.join(scratch(), "no-such-notes.md"))),
        ("a note one byte over 64 KiB", "x" * 65537, ()),
    ):
        status, output = run_helper(repo, "0.1.0", args=args, notes=notes)
        if status == 0 or helper_state(repo) != before:
            return f"release.sh with {what} exits {status} or changed the repository: {output.strip()[-300:]}"
    for answer, dirty in ((None, False), ("y\n", True)):
        repo = helper_repo(script, "0.6.0-alpha.1")
        head = helper_git(repo, "rev-parse", "HEAD")
        if dirty:
            with open(os.path.join(repo, "notes.txt"), "w") as f:
                f.write("not committed\n")
        status, output = run_helper(repo, "0.6.0-alpha.1", answer)
        tagged = helper_git(repo, "rev-list", "-n", "1", "0.6.0-alpha.1")
        if status != 0 or tagged != head or helper_git(repo, "rev-list", "--count", "HEAD") != "1":
            return (
                f"release.sh on a HEAD declaring 0.6.0-alpha.1 (another file uncommitted: {dirty}) exits {status}, "
                f"tagging {tagged!r} rather than HEAD without a commit: {output.strip()[-300:]}"
            )
        reason = tag_note_failure(repo, "0.6.0-alpha.1")
        if reason:
            return reason
    # A bump over a staged unrelated change, let through at the prompt (the
    # terminal then answers the commit message's prompt too): the tagged
    # commit is the version lines alone, and the change stays staged.
    repo = helper_repo(script, HELPER_BASE)
    with open(os.path.join(repo, "unrelated.txt"), "w") as f:
        f.write("staged, not the release's\n")
    helper_git(repo, "add", "unrelated.txt")
    status, output = run_helper(repo, "0.1.0", "y\n0.1.0\n")
    changed = sorted(helper_git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").splitlines())
    expected = sorted(os.path.relpath(path, repo) for path in helper_mixfiles(repo))
    if status != 0 or helper_git(repo, "tag", "-l") != "0.1.0" or changed != expected:
        return (
            f"release.sh bumped 0.1.0 over a staged unrelated file with exit {status}, tags "
            f"{helper_git(repo, 'tag', '-l')!r} and a commit changing {changed!r}, not the mix.exs files alone: "
            f"{output.strip()[-300:]}"
        )
    if helper_git(repo, "status", "--porcelain") != "A  unrelated.txt":
        return f"release.sh did not leave the unrelated staged file staged: {helper_git(repo, 'status', '--porcelain')!r}"
    for edited in (helper_mixfiles, lambda repo: helper_mixfiles(repo)[-2:-1]):
        repo = helper_repo(script, "0.6.0-alpha.1")
        for path in edited(repo):
            declare(path, "0.6.0-alpha.2")
        status, output = run_helper(repo, "0.6.0-alpha.2", "y\n0.6.0-alpha.2\n")
        if status == 0 or helper_git(repo, "tag", "-l") or helper_git(repo, "rev-list", "--count", "HEAD") != "1":
            return (
                f"release.sh tagged 0.6.0-alpha.2 over mix.exs files edited and not committed (exit {status}, "
                f"tags {helper_git(repo, 'tag', '-l')!r}): {output.strip()[-300:]}"
            )
        if "differ from HEAD" not in output:
            return f"release.sh refuses uncommitted mix.exs edits without saying why: {output.strip()[-300:]}"
    return helper_proof_failure(script) or helper_bump_failure(script) or helper_push_failure(script)


# A bin directory of stand-ins: a Mix that answers success and a gh that
# answers each `gh api PATH ... -q FILTER` from the JSON the case names
# for the endpoint (GH_CHECK_RUNS, GH_WORKFLOW_RUNS), through jq with the
# helper's own filter, or fails where the JSON is not given.
HELPER_GH = r"""#!/usr/bin/env bash
filter= path=$2
while [ "$#" -gt 0 ]; do [ "$1" != -q ] || filter=$2; shift; done
case "$path" in
  */check-runs*) json=${GH_CHECK_RUNS:-} ;;
  */actions/runs*) json=${GH_WORKFLOW_RUNS:-} ;;
  *) json= ;;
esac
[ -n "$json" ] || { echo "stand-in: no answer for $path" >&2; exit 1; }
printf '%s' "$json" | jq -r "$filter"
"""
HELPER_MIX = "#!/usr/bin/env bash\nexit 0\n"
# HEAD green on GitHub, as gh reads it: its check runs completed, and the
# Test workflow's latest run on it completed green.
HELPER_GREEN_RUNS = json.dumps({"check_runs": [{"status": "completed", "conclusion": "success", "name": "codex"}]})
HELPER_GREEN_TEST = json.dumps({"workflow_runs": [
    {"path": ".github/workflows/test.yml", "status": "completed", "conclusion": "success", "created_at": "2026-11-04T00:00:00Z"}
]})
# The audits the proof is followed by pass. The movers stand in for them,
# as the step between the proof and the tag: each passes once it has moved
# HEAD by a commit of its own, as another agent in the checkout could while
# the audits run.
HELPER_AUDIT = "#!/usr/bin/env bash\nexit 0\n"
HELPER_MOVING_AUDIT = """#!/usr/bin/env bash
echo moved > moved.txt
git add moved.txt
git commit -qm 'another agent'
"""
# Audits during which another merge lands on origin's main, HEAD left where
# it was.
HELPER_MAIN_MOVING_AUDIT = """#!/usr/bin/env bash
merged=$(git commit-tree "HEAD^{tree}" -p HEAD -m 'another merge')
git push -q origin "$merged:refs/heads/main"
"""
# Audits during which another agent commits the version bump itself, every
# mix.exs then declaring the version asked for.
HELPER_BUMPING_AUDIT = """#!/usr/bin/env bash
sed -i 's/version: "[^"]*"/version: "0.1.0"/' mix.exs apps/*/mix.exs
git commit -qam 'another agent'
"""


def helper_bin():
    path = os.path.join(scratch(), "helper-bin")
    if not os.path.isdir(path):
        os.makedirs(path)
        for name, text in (("gh", HELPER_GH), ("mix", HELPER_MIX)):
            with open(os.path.join(path, name), "w") as f:
                f.write(text)
            os.chmod(os.path.join(path, name), 0o755)
    return path


def helper_proof_failure(script):
    """The proof on GitHub: green check runs pass only with the Test
    workflow's latest run on HEAD completed green; with none (its path
    filter skipped HEAD), a failed latest run over a green older one, or
    one still running, nothing is tagged."""
    green = json.dumps({"check_runs": [{"status": "completed", "conclusion": "success", "name": "codex"}]})

    def runs(*states):
        return json.dumps({"workflow_runs": [
            {"path": ".github/workflows/test.yml", "status": status, "conclusion": conclusion,
             "created_at": f"2026-11-04T0{i}:00:00Z"} for i, (status, conclusion) in enumerate(states)
        ] + [{"path": ".github/workflows/codex-ci.yml", "status": "completed", "conclusion": "success",
              "created_at": "2026-11-04T09:00:00Z"}]})

    cases = [
        ("an older failed Test run and a green latest one", runs(("completed", "failure"), ("completed", "success")), True),
        ("no Test run", runs(), False),
        ("a green Test run and a failed latest one", runs(("completed", "success"), ("completed", "failure")), False),
        ("a Test run in progress", runs(("in_progress", None)), False),
    ]
    for name, workflow_runs, accepted in cases:
        repo = helper_repo(script, "0.6.0-alpha.1")
        head = helper_git(repo, "rev-parse", "HEAD")
        status, output = run_helper(repo, "0.6.0-alpha.1",
                                    extra_env={"GH_CHECK_RUNS": green, "GH_WORKFLOW_RUNS": workflow_runs})
        tagged = helper_git(repo, "rev-list", "-n", "1", "0.6.0-alpha.1") if helper_git(repo, "tag", "-l") else ""
        if accepted and (status != 0 or tagged != head):
            return f"release.sh refused green check runs with {name} (exit {status}): {output.strip()[-300:]}"
        if not accepted and (status == 0 or tagged):
            return f"release.sh tagged green check runs with {name} (exit {status}): {output.strip()[-300:]}"
    return None


def helper_bump_failure(script):
    """The tag names the proved commit: a HEAD moved after the proof, while
    the audits run, is refused, nothing tagged and no bump committed,
    whether the proved commit declares the version already, needs the bump,
    or the move is another agent's bump to that version; a bump commit
    that is not the proved commit plus version lines declaring the version
    (a hook adding another line, writing another version or changing a
    file's mode, or another commit landing under it) is not tagged; a bump
    of the files still behind, the root already at the version, is
    tagged."""
    for declared, version, mover in (
        ("0.6.0-alpha.1", "0.6.0-alpha.1", HELPER_MOVING_AUDIT),
        (HELPER_BASE, "0.1.0", HELPER_MOVING_AUDIT),
        ("0.0.1", "0.1.0", HELPER_BUMPING_AUDIT),
    ):
        repo = helper_repo(script, declared, {"dependency-audit.sh": mover})
        status, output = run_helper(repo, version)
        tags = helper_git(repo, "tag", "-l")
        moved = helper_git(repo, "log", "-1", "--format=%s")
        if status == 0 or tags or moved != "another agent" or "HEAD moved from the proved" not in output:
            return (
                f"release.sh asked for {version} on a commit declaring {declared} went on after HEAD moved during the proof "
                f"(exit {status}, tags {tags!r}, last commit {moved!r}): {output.strip()[-300:]}"
            )
    repo = helper_repo(script, HELPER_BASE)
    hook = os.path.join(repo, ".git", "hooks", "pre-commit")
    with open(hook, "w") as f:
        f.write("#!/bin/sh\necho '# not a version line' >> apps/arca/mix.exs\ngit add apps/arca/mix.exs\n")
    os.chmod(hook, 0o755)
    head = helper_git(repo, "rev-parse", "HEAD")
    status, output = run_helper(repo, "0.1.0")
    if status == 0 or helper_git(repo, "tag", "-l") or helper_git(repo, "rev-parse", "HEAD") != head:
        return f"release.sh tagged a bump commit holding a line other than the version (exit {status}): {output.strip()[-300:]}"
    # A hook that changes the bump as it is committed: another version on
    # an application's line, or the root's mode.
    for name, change in (
        ("another version", "sed -i 's/version: \"0.1.0\"/version: \"9.9.9\"/' apps/arca/mix.exs\ngit add apps/arca/mix.exs"),
        ("a mode change", "chmod +x mix.exs\ngit add mix.exs"),
    ):
        repo = helper_repo(script, HELPER_BASE)
        hook = os.path.join(repo, ".git", "hooks", "pre-commit")
        with open(hook, "w") as f:
            f.write(f"#!/bin/sh\n{change}\n")
        os.chmod(hook, 0o755)
        head = helper_git(repo, "rev-parse", "HEAD")
        status, output = run_helper(repo, "0.1.0")
        if status == 0 or helper_git(repo, "tag", "-l") or helper_git(repo, "rev-parse", "HEAD") != head:
            return f"release.sh tagged a bump commit a hook gave {name} (exit {status}): {output.strip()[-300:]}"
    # A git that lands another commit on HEAD right before the bump's.
    wrap = os.path.join(scratch(), "helper-landing-bin")
    if not os.path.isdir(wrap):
        os.makedirs(wrap)
        real = shutil.which("git")
        with open(os.path.join(wrap, "git"), "w") as f:
            f.write(f"""#!/usr/bin/env bash
if [ "$1" = commit ] && [ "$2" = --only ]; then
  landed=$("{real}" commit-tree "HEAD^{{tree}}" -p HEAD -m landed) && "{real}" update-ref HEAD "$landed" || exit 1
fi
exec "{real}" "$@"
""")
        os.chmod(os.path.join(wrap, "git"), 0o755)
    repo = helper_repo(script, HELPER_BASE)
    status, output = run_helper(repo, "0.1.0", bin_dir=wrap)
    if status == 0 or helper_git(repo, "tag", "-l"):
        return f"release.sh tagged a bump commit whose parent is not the proved commit (exit {status}): {output.strip()[-300:]}"
    repo = helper_repo(script, HELPER_BASE)
    declare(os.path.join(repo, "mix.exs"), "0.1.0")
    helper_git(repo, "commit", "-qam", "root first")
    helper_git(repo, "push", "-q", "origin", "HEAD:refs/heads/main")
    head = helper_git(repo, "rev-parse", "HEAD")
    status, output = run_helper(repo, "0.1.0")
    changed = sorted(helper_git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", "0.1.0").splitlines())
    expected = sorted(os.path.relpath(path, repo) for path in helper_mixfiles(repo)[1:])
    if status != 0 or not declares_at(repo, "0.1.0", "0.1.0") or changed != expected or helper_git(repo, "rev-parse", "0.1.0^{commit}^") != head:
        return f"release.sh did not tag a bump of the files still behind the version (exit {status}, changed {changed!r}): {output.strip()[-300:]}"
    return None


def helper_push_failure(script):
    """--push from a detached HEAD at main's head moves origin's main to
    the bump and pushes the tag, by full refs; on a HEAD that declares the
    version already it pushes the tag and leaves main; an origin that
    refuses the tag takes neither, the push being atomic, and it fails
    without saying Pushed!. A HEAD that is not main's head on origin
    (behind it, ahead of it, or with no origin to read) is refused with
    nothing made, with or without --push, before its proof is read or its
    audits run; a main that moves after the proof, while the audits run, is
    refused before the commit."""
    for declared, version in ((HELPER_BASE, "0.1.0"), ("0.6.0-alpha.1", "0.6.0-alpha.1")):
        repo = helper_repo(script, declared)
        head = helper_git(repo, "rev-parse", "HEAD")
        helper_git(repo, "checkout", "-q", "--detach")
        status, output = run_helper(repo, version, args=["--push"])
        tagged = helper_git(repo, "rev-parse", f"{version}^{{commit}}")
        main = helper_git(helper_origin(repo), "rev-parse", "main")
        remote_tag = helper_git(helper_origin(repo), "rev-parse", f"{version}^{{commit}}")
        expected_main = head if declared == version else tagged
        if status != 0 or "Pushed!" not in output or main != expected_main or remote_tag != tagged:
            return (
                f"release.sh --push of {version} from a detached HEAD declaring {declared} exits {status}, origin's main "
                f"{main!r} (expected {expected_main!r}), its tag {remote_tag!r} (expected {tagged!r}): {output.strip()[-300:]}"
            )
    repo = helper_repo(script, HELPER_BASE)
    head = helper_git(repo, "rev-parse", "HEAD")
    hook = os.path.join(helper_origin(repo), "hooks", "update")
    with open(hook, "w") as f:
        f.write('#!/bin/sh\ncase "$1" in refs/tags/*) exit 1 ;; esac\n')
    os.chmod(hook, 0o755)
    status, output = run_helper(repo, "0.1.0", args=["--push"])
    main = helper_git(helper_origin(repo), "rev-parse", "main")
    if status == 0 or "Pushed!" in output or main != head or helper_git(helper_origin(repo), "tag", "-l"):
        return (
            f"release.sh --push to an origin refusing the tag exits {status}, origin's main {main!r} "
            f"(expected {head!r}, untouched), its tags {helper_git(helper_origin(repo), 'tag', '-l')!r}: {output.strip()[-300:]}"
        )

    def behind(repo):
        helper_git(repo, "commit", "-q", "--allow-empty", "-m", "merged after")
        helper_git(repo, "push", "-q", "origin", "HEAD:refs/heads/main")
        helper_git(repo, "checkout", "-q", "--detach", "HEAD~1")

    def ahead(repo):
        helper_git(repo, "commit", "-q", "--allow-empty", "-m", "not on main")

    def no_origin(repo):
        helper_git(repo, "remote", "remove", "origin")

    ran = os.path.join(scratch(), "helper-audit-ran")
    recording_audit = f'#!/usr/bin/env bash\ntouch "{ran}"\n'
    for name, move, args, said in (
        ("behind main", behind, ["--push"], "is not main's head on origin"),
        ("ahead of main", ahead, [], "is not main's head on origin"),
        ("with no origin", no_origin, ["--push"], "origin's main could not be read"),
    ):
        repo = helper_repo(script, HELPER_BASE, {"dependency-audit.sh": recording_audit})
        move(repo)
        before = helper_state(repo)
        if os.path.exists(ran):
            os.remove(ran)
        status, output = run_helper(repo, "0.1.0", args=args)
        if status == 0 or helper_state(repo) != before or said not in output or os.path.exists(ran):
            return (
                f"release.sh on a HEAD {name} ({' '.join(args) or 'no flags'}) exits {status}, changed the repository "
                f"{helper_state(repo) != before} or ran the audits {os.path.exists(ran)}: {output.strip()[-300:]}"
            )
    repo = helper_repo(script, HELPER_BASE, {"dependency-audit.sh": HELPER_MAIN_MOVING_AUDIT})
    before = helper_state(repo)
    status, output = run_helper(repo, "0.1.0")
    if status == 0 or helper_state(repo) != before or "Main moved during the proof" not in output:
        return f"release.sh went on after main moved after the proof (exit {status}): {output.strip()[-300:]}"
    return None


RELEASE_SH_MUTANTS = [
    ("the rule without pre-releases", lambda t: t.replace(SCAFFOLD_RULE, "RELEASE=" + BARE_RULE, 1)),
    ("the rule unanchored at its end", lambda t: t.replace(SCAFFOLD_RULE, SCAFFOLD_RULE.replace("?$'", "?'"), 1)),
    ("no LC_ALL=C", lambda t: t.replace('(LC_ALL=C; [[ "$VERSION" =~ $RELEASE ]])', '[[ "$VERSION" =~ $RELEASE ]]', 1)),
    (
        "the version unchecked",
        lambda t: t.replace('(LC_ALL=C; [[ "$VERSION" =~ $RELEASE ]])', '(LC_ALL=C; [[ "$VERSION" =~ $RELEASE ]] || :)', 1),
    ),
    (
        "uncommitted mix.exs edits let through",
        lambda t: t.replace('if [ -n "$(git status --porcelain -- "${MIXFILES[@]}")" ]; then', "if false; then", 1),
    ),
    ("the Test workflow's run unread", lambda t: t.replace('if [ "$TEST_RUN" != "completed success" ]; then', "if false; then", 1)),
    ("a bump on a moved HEAD", lambda t: t.replace('if [ "$(git rev-parse HEAD)" != "$HEAD_SHA" ]; then', "if false; then", 1)),
    (
        "the bump's lines unread",
        lambda t: t.replace("! grep -qvE '^[+-][[:space:]]*version: \"[^\"]*\",?[[:space:]]*$' <<< \"$lines\"", ":", 1),
    ),
    ("the bump's versions unread", lambda t: t.replace(' || ! all_declare "$BUMP"; then', "; then", 1)),
    ("the bump's modes unread", lambda t: t.replace("""  [ -z "$(awk '!(substr($1, 2) == $2 && $5 == "M")' <<< "$raw")" ] || return 1\n""", "", 1)),
    (
        "the bump's parent unread",
        lambda t: t.replace('if [ "$(git rev-parse "$BUMP^")" != "$HEAD_SHA" ] || ! version_only', "if ! version_only", 1),
    ),
    (
        "the bump held to every mix.exs",
        lambda t: t.replace(
            '[ -n "$names" ] || return 1',
            """[ "$(LC_ALL=C sort <<< "$names")" = "$(printf '%s\\n' "${MIXFILES[@]}" | LC_ALL=C sort)" ] || return 1""",
            1,
        ),
    ),
    ("the push not atomic", lambda t: t.replace("git push --atomic origin", "git push origin", 1)),
    ("the push naming HEAD", lambda t: t.replace('"$TAGGED:refs/heads/main"', "HEAD", 1)),
    ("main's head unread before the proof", lambda t: t.replace("main_is_head || exit 1", ":", 1)),
    ("main's head unread after the proof", lambda t: t.replace("if ! main_is_head; then", "if false; then", 1)),
    ("an empty note let through", lambda t: t.replace(""" || ! grep -q '[^[:space:]]' <<<"$NOTE"; then""", "; then", 1)),
    ("the tag without the note", lambda t: t.replace('-F "$TAG_MESSAGE"', '-m "Release $VERSION"')),
    ("the note's size unbounded", lambda t: t.replace('if [ "$(wc -c <"$NOTES")" -gt "$NOTE_LIMIT" ]; then', "if false; then", 1)),
    ("the note's lines cleaned up by git", lambda t: t.replace("git tag -a --cleanup=verbatim", "git tag -a")),
]


# --- scripts/ci/release-note.sh: the tag's written note ---

# Tags on the note repository's origin: an annotated tag with the note, a
# lightweight tag and an annotated tag whose message is its subject alone,
# each on the run's commit, and an annotated tag with the note moved to the
# commit after it.
NOTE_TAGS = {"1.0.0": "note", "1.0.1": "lightweight", "1.0.2": "subject only", "1.0.3": "moved"}


def note_repo():
    """A repository whose origin holds NOTE_TAGS, holding each of them
    itself as a lightweight tag of the run's commit, as a checkout of a tag
    push may: the script must fetch the tag to read its note. Answers the
    repository and the run's commit."""
    repo = os.path.join(scratch(), "note-%d" % len(_HELPER_REPOS))
    _HELPER_REPOS.append(repo)
    os.makedirs(repo)
    helper_git(repo, "init", "-q")
    # The commit's message has a body, which a lightweight tag reads as its
    # contents: only the annotation tells it from a note.
    helper_git(repo, "commit", "-q", "--allow-empty", "-m", "release\n\nA commit's body, not a release note.")
    run = helper_git(repo, "rev-parse", "HEAD")
    helper_git(repo, "commit", "-q", "--allow-empty", "-m", "after the release")
    for tag, kind in NOTE_TAGS.items():
        if kind == "moved":
            helper_git(repo, "tag", "-a", "--cleanup=verbatim", tag, "HEAD", "-m", f"Release {tag}\n\n{HELPER_NOTE}")
        elif kind == "note":
            helper_git(repo, "tag", "-a", "--cleanup=verbatim", tag, run, "-m", f"Release {tag}\n\n{HELPER_NOTE}")
        elif kind == "subject only":
            helper_git(repo, "tag", "-a", tag, run, "-m", f"Release {tag}")
        else:
            helper_git(repo, "tag", tag, run)
    helper_git(repo, "init", "-q", "--bare", helper_origin(repo))
    helper_git(repo, "remote", "add", "origin", helper_origin(repo))
    helper_git(repo, "push", "-q", "origin", "HEAD:refs/heads/main", "--tags")
    for tag in NOTE_TAGS:
        helper_git(repo, "tag", "-f", tag, run)
    return repo, run


def release_note_failure(script):
    """release-note.sh against note_repo's tags for the run's commit: the
    annotated tag's note written to OUT as written, and the lightweight,
    subject-only and moved tags refused with an ::error:: line and OUT
    unwritten. The first failure, or None."""
    repo, run = note_repo()
    path = os.path.join(scratch(), "release-note-%d.sh" % len(_HELPER_REPOS))
    with open(path, "w") as f:
        f.write(script)
    for tag, kind in NOTE_TAGS.items():
        out = os.path.join(scratch(), f"note-{len(_HELPER_REPOS)}-{tag}.md")
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", path, tag, run, out],
            cwd=repo, env=helper_env(repo), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
        )
        output = result.stdout.decode(errors="replace")
        if kind == "note":
            written = open(out).read() if os.path.exists(out) else None
            if result.returncode != 0 or written != HELPER_NOTE:
                return f"release-note.sh on an annotated tag with a note exits {result.returncode}, writing {written!r}: {output.strip()[-300:]}"
        elif result.returncode == 0 or "::error::" not in output or os.path.exists(out):
            return f"release-note.sh on a {kind} tag exits {result.returncode} or writes the note, or says no ::error::: {output.strip()[-300:]}"
    return None


RELEASE_NOTE_MUTANTS = [
    ("a lightweight tag let through", lambda t: t.replace('!= tag ]; then', '= nothing ]; then', 1)),
    ("an empty note let through", lambda t: t.replace("""if ! grep -q '[^[:space:]]' <<<"$note"; then""", "if false; then", 1)),
    ("the tag not fetched", lambda t: t.replace('git fetch --quiet --force --no-tags origin "refs/tags/$tag:refs/tags/$tag"', ":", 1)),
    ("the tag not bound to the run's commit", lambda t: t.replace('if [ "$(git rev-parse "refs/tags/$tag^{commit}")" != "$commit" ]; then', "if false; then", 1)),
    ("the note not written", lambda t: t.replace(""">"$out"\n""", """>/dev/null\n""", 1)),
]


def release_note_failures():
    """release-note.sh held to its tags, and each mutant of it refused."""
    with open(RELEASE_NOTE_SH) as f:
        script = f.read()
    failures = [r for r in [release_note_failure(script)] if r]
    for name, mutate in RELEASE_NOTE_MUTANTS:
        mutant = mutate(script)
        if mutant == script:
            failures.append(f"a mutant changed nothing: release-note.sh, {name}")
        elif release_note_failure(mutant) is None:
            failures.append(f"a mutant of release-note.sh was accepted: {name}")
    return failures


def release_helper_failures():
    """release.sh held to the vectors and the no-commit tag, and each mutant
    of it refused. Returns (failures, versions run)."""
    failures = []
    with open(RELEASE_SH) as f:
        script = f.read()
    reason = helper_failure(script)
    if reason:
        failures.append(reason)
    for name, mutate in RELEASE_SH_MUTANTS:
        mutant = mutate(script)
        if mutant == script:
            failures.append(f"a mutant changed nothing: release.sh, {name}")
        elif helper_failure(mutant) is None:
            failures.append(f"a mutant of release.sh was accepted: {name}")
    accepted, refused = version_vectors()
    return failures, len(accepted) + len(refused)


def manifest_mode_failures(pinned, version):
    """The workflow's --manifest mode, run as the workflow runs it, on
    manifests written for the pinned scaffold, and on a release's and a
    pre-release's of the same MAJOR.MINOR.PATCH, each with its own pinned
    scaffold."""
    with open(COMPOSE) as f:
        compose = f.read()
    caddy, reason = compose_pinned(compose, "caddy")
    tailscale, other = compose_pinned(compose, "tailscale")
    if reason or other:
        return [reason or other], 0

    def manifest_for(at, tarball):
        with open(tarball, "rb") as f:
            scaffold = "sha256:" + hashlib.sha256(f.read()).hexdigest()
        return {
            "version": at,
            "images": {"cyfr": FAKE_CYFR, "cyfr_locus": FAKE_LOCUS, "caddy": caddy, "tailscale": tailscale},
            "scaffold": scaffold,
            "schema_fingerprint": "5e" * 32,
        }

    core = version.partition("-")[0]
    pre = version if core != version else other_prerelease(version)
    scaffolds = {version: pinned}
    for at in (core, pre):
        if at not in scaffolds:
            scaffolds[at] = os.path.join(scratch(), "pinned-%s.tar.gz" % at)
            status, output = run_scaffold(ROOT, [scaffolds[at], at, FAKE_CYFR, FAKE_LOCUS])
            if status != 0:
                return [f"scaffold-tarball.sh exits {status} on {at}: {output.strip()[-300:]}"], 0
    good = manifest_for(version, pinned)
    other = other_version(version)
    wrong = "sha256:" + "0" * 64

    def with_(**changes):
        m = copy.deepcopy(good)
        for key, value in changes.items():
            if key in m["images"]:
                m["images"][key] = value
            else:
                m[key] = value
        return json.dumps(m).encode()

    good_bytes = json.dumps(good).encode()
    released = json.dumps(manifest_for(core, scaffolds[core])).encode()
    prereleased = json.dumps(manifest_for(pre, scaffolds[pre])).encode()
    # (name, release.json, tag, scaffold, exit status, text the output holds)
    mismatch = "release.json is release"
    cases = [
        ("the manifest of the release", good_bytes, version, pinned, 0, ""),
        ("a release's manifest under its tag", released, core, scaffolds[core], 0, ""),
        ("a pre-release's manifest under its tag", prereleased, pre, scaffolds[pre], 0, ""),
        ("a release's manifest under a pre-release's tag", released, pre, scaffolds[core], 1, mismatch),
        ("a pre-release's manifest under its release's tag", prereleased, core, scaffolds[pre], 1, mismatch),
        ("a tag with build metadata", good_bytes, version + "+build.5", pinned, 1, RELEASE_VERSION),
    ]
    cases += [(name, data, tag, pinned, want, "") for name, data, tag, want in [
        ("another tag", good_bytes, other, 1),
        ("a v-prefixed tag", good_bytes, "v" + version, 1),
        ("another release's manifest", with_(version=other), other, 1),
        ("another scaffold digest", with_(scaffold=wrong), version, 1),
        ("another caddy digest", with_(caddy=wrong), version, 1),
        ("another tailscale digest", with_(tailscale=wrong), version, 1),
        ("the tailscale digest dropped", json.dumps({**good, "images": {k: v for k, v in good["images"].items() if k != "tailscale"}}).encode(), version, 1),
        ("another cyfr digest", with_(cyfr=wrong), version, 1),
        ("the image digests swapped", with_(cyfr=FAKE_LOCUS, cyfr_locus=FAKE_CYFR), version, 1),
        ("an extra key", json.dumps({**good, "latest": True}).encode(), version, 1),
        ("the schema fingerprint dropped", json.dumps({k: v for k, v in good.items() if k != "schema_fingerprint"}).encode(), version, 1),
        ("an empty schema fingerprint", with_(schema_fingerprint=""), version, 1),
        ("a duplicate key", good_bytes[:-1] + b', "version": "' + version.encode() + b'"}', version, 1),
        ("trailing data", good_bytes + b"{}", version, 1),
    ]]
    failures = []
    path = os.path.join(scratch(), "release.json")
    for name, data, tag, scaffold, want, text in cases:
        with open(path, "wb") as f:
            f.write(data)
        result = subprocess.run(
            [sys.executable, "-I", os.path.abspath(__file__)]
            + ["--manifest", path, "--version", tag, "--scaffold", scaffold],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
        output = result.stdout.decode(errors="replace").strip()
        if result.returncode != want or text not in output:
            failures.append(
                f"the manifest mode exits {result.returncode} on {name}, not {want}"
                + (f" naming {text!r}" if text else "")
                + f": {output[-300:]}"
            )
    usage = subprocess.run(
        [sys.executable, "-I", os.path.abspath(__file__), "--manifest", path, "--version", version],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=60,
    )
    if usage.returncode != 64:
        failures.append(f"the manifest mode exits {usage.returncode} without --scaffold, not 64")
    return failures, len(cases)


# codex-ci.yml's rehearsal of the release's packaging
# (tests/ci-release-rehearsal.sh) runs the release's own GoReleaser.
CODEX_CI = os.path.join(WORKFLOWS, "codex-ci.yml")
REHEARSAL_RUN = "bash tests/ci-release-rehearsal.sh"


def check_rehearsal(codex_ci, release_wf):
    job = (codex_ci.get("jobs") or {}).get("release-rehearsal") or {}
    # The job's own conditions as well as its steps': no if and no
    # continue-on-error.
    extra = set(job) - {"name", "runs-on", "timeout-minutes", "steps"}
    if extra:
        return f"codex-ci.yml's release-rehearsal carries {sorted(extra)}"
    steps = job.get("steps", [])
    runs = [s for s in steps if str(s.get("run", "")).strip() == REHEARSAL_RUN]
    if len(runs) != 1 or set(runs[0]) - {"name", "run"}:
        return "codex-ci.yml's release-rehearsal does not run the rehearsal once, unconditionally"
    tools = [s for s in steps if str(s.get("uses", "")).startswith("goreleaser/goreleaser-action")]
    theirs = next(s for s in release_wf["jobs"]["release"]["steps"] if str(s.get("uses", "")).startswith("goreleaser/goreleaser-action"))
    if len(tools) != 1 or tools[0].get("uses") != theirs["uses"] or tools[0].get("with") != {
        "version": theirs["with"]["version"], "install-only": True
    }:
        return "codex-ci.yml's rehearsal installs another GoReleaser than the release's"
    if steps.index(tools[0]) > steps.index(runs[0]):
        return "codex-ci.yml's rehearsal runs before GoReleaser is installed"
    return None


_DESKTOP_MAC = []


def desktop_mac():
    """desktop-mac.yml as the tree holds it, read once."""
    if not _DESKTOP_MAC:
        import yaml

        with open(DESKTOP_MAC) as f:
            _DESKTOP_MAC.append(yaml.safe_load(f))
    return copy.deepcopy(_DESKTOP_MAC[0])


def check_shape(wf, mac=None):
    mac = desktop_mac() if mac is None else mac
    reason = check_failures_pass_nothing(wf)
    if reason:
        return reason
    reason, build = check_build(wf)
    if reason:
        return reason
    reason, merge = check_merge(wf, build)
    if reason:
        return reason
    reason = check_permissions(wf, build, merge)
    if reason:
        return reason
    release = release_jobs(wf)[0]
    return (
        check_trigger(wf)
        # Read before the tag check, which runs its cases for every mutant
        # that reaches it.
        or check_linux_package(wf, merge, release)
        or check_mac_package(wf, mac, merge, release)
        or check_windows_package(wf, merge, release)
        or check_installers_job(wf)
        or check_secrets(wf, release)
        or check_tag(wf, build, release)
        or check_merged_digest(wf, merge)
        or check_release_manifest(wf, merge, release)
        or check_homebrew(wf, release)
    )


def refusal(wf, mac=None):
    return check_graph(wf) or check_shape(wf, mac)


# The publication test builds as release.yml does, after the same switch.
def check_static(test_wf):
    job = test_wf.get("jobs", {}).get("static")
    if job is None:
        return "test.yml has no static job"
    tests = [s for s in job.get("steps", []) if str(s.get("run", "")).strip() == PUBLISH_TEST]
    if len(tests) != 1:
        return "test.yml's static job does not run the publication test once"
    if "if" in tests[0] or "continue-on-error" in tests[0]:
        return "test.yml's publication test is conditional or allowed to fail"
    return check_store_switch(job, lambda s: str(s.get("run", "")).strip() == PUBLISH_TEST, "the publication test")


# --- fixtures and mutants, each of which must be refused ---


def graph_fixtures():
    v = {f"v{i}": {"uses": u} for i, u in enumerate(sorted(VERIFY))}

    def job(**kw):
        return {"runs-on": "x", "timeout-minutes": 5, **kw}

    def wf(jobs):
        return {"concurrency": {"cancel-in-progress": False}, "jobs": jobs}

    refused = [
        ("publish needs only an independent job", wf({**v, "provenance": job(), "publish": job(needs=["provenance"])})),
        ("publish runs always()", wf({**v, "publish": job(needs=list(v), **{"if": "${{ always() }}"})})),
        ("publish runs !success()", wf({**v, "publish": job(needs=list(v), **{"if": "${{ !success() }}"})})),
        ("publish runs failure() || success()", wf({**v, "publish": job(needs=list(v), **{"if": "failure() || success()"})})),
        ("a job without a timeout", wf({**v, "build": job(needs=list(v)), "publish": {"runs-on": "x", "needs": ["build"]}})),
    ]
    allowed = wf({**v, "publish": job(needs=list(v), **{"if": "${{ github.repository == 'cyfrworks/cyfr' && success() }}"})})
    return refused, allowed


def step_named(wf, job, name):
    return next(s for s in wf["jobs"][job]["steps"] if s.get("name") == name)


def step_using(wf, job, action):
    return next(s for s in wf["jobs"][job]["steps"] if action in str(s.get("uses")))


def drop_need(wf):
    wf["jobs"]["images"]["needs"].remove("security")


def merge_always(wf):
    wf["jobs"]["merge"]["if"] = "${{ always() }}"


def build_continues(wf):
    wf["jobs"]["images"]["continue-on-error"] = True


def no_locus(wf):
    matrix = wf["jobs"]["images"]["strategy"]["matrix"]
    matrix["image"].remove("cyfr-locus")
    matrix["include"] = [r for r in matrix["include"] if r.get("image") != "cyfr-locus"]


def group_publish(wf):
    wf["concurrency"]["group"] = "publish"


def job_concurrency(wf):
    wf["jobs"]["merge"]["concurrency"] = {"group": "x", "cancel-in-progress": True}


def scan_continues(wf):
    step_named(wf, "images", "Scan the image")["continue-on-error"] = True


def no_image_jobs(wf):
    del wf["jobs"]["images"]
    del wf["jobs"]["merge"]
    wf["jobs"]["release"]["needs"].remove("merge")


def download_by_pattern(wf):
    for s in wf["jobs"]["merge"]["steps"]:
        if "download-artifact" in str(s.get("uses")):
            s["with"] = {"pattern": "digest-${{ matrix.image }}-*", "path": "digests", "merge-multiple": True}


def secrets_inherited(wf):
    wf["jobs"]["test"]["secrets"] = "inherit"


def tag_pushed(wf):
    inputs = step_using(wf, "images", "build-push-action")["with"]
    inputs["tags"] = "x:amd64"
    inputs["push"] = True


def scan_may_fetch(wf):
    del step_named(wf, "images", "Scan the image")["env"]


def no_comparison(wf):
    steps = wf["jobs"]["images"]["steps"]
    wf["jobs"]["images"]["steps"] = [s for s in steps if "scanned-is-pushed" not in str(s.get("run"))]


def merge_ignores_failure(wf):
    step = next(s for s in wf["jobs"]["merge"]["steps"] if "merge-image.sh" in str(s.get("run")))
    step["run"] = step["run"].replace("\n", " || true\n", 1)


def broad_default_permissions(wf):
    wf["permissions"] = {"contents": "write", "packages": "write"}


def loaded_under_registry(wf):
    inputs = step_using(wf, "images", "build-push-action")["with"]
    inputs["outputs"] = inputs["outputs"].replace(LOAD + "cyfr-scan/", LOAD + "ghcr.io/cyfrworks/")
    step_named(wf, "images", "Scan the image")["with"]["image-ref"] = (
        "ghcr.io/cyfrworks/${{ matrix.image }}:${{ steps.meta.outputs.arch }}"
    )


def no_apt_refresh(wf):
    del step_using(wf, "images", "build-push-action")["with"]["build-args"]


def apt_refresh_fixed(wf):
    step = step_named(wf, "images", "Extract metadata")
    step["run"] = step["run"].replace("$(scripts/apt-key.sh)", "2026-10-15")


def apt_refresh_skipped(wf):
    step_named(wf, "images", "Extract metadata")["if"] = "matrix.image == 'cyfr-locus'"


def apt_refresh_after_build(wf):
    steps = wf["jobs"]["images"]["steps"]
    meta = step_named(wf, "images", "Extract metadata")
    steps.remove(meta)
    steps.append(meta)


def apt_refresh_exits_first(wf):
    step = step_named(wf, "images", "Extract metadata")
    step["run"] = step["run"].replace("apt_key=", "exit 0\napt_key=", 1)


def apt_refresh_overwritten(wf):
    step = step_named(wf, "images", "Extract metadata")
    step["run"] = step["run"].rstrip("\n") + '\necho "apt-refresh=2026-01-01" >> "$GITHUB_OUTPUT"\n'


def apt_refresh_for_locus_only(wf):
    step = step_named(wf, "images", "Extract metadata")
    step["run"] = step["run"].replace(
        'echo "apt-refresh=', '[ "$IMAGE" = cyfr ] || echo "apt-refresh=', 1
    )


def no_provenance(wf):
    del step_using(wf, "images", "build-push-action")["with"]["provenance"]


def scan_never_fails(wf):
    step_named(wf, "images", "Scan the image")["with"]["exit-code"] = "0"


def comparison_ignored(wf):
    step = next(s for s in wf["jobs"]["images"]["steps"] if "scanned-is-pushed" in str(s.get("run")))
    step["run"] = step["run"].replace('"$DIGEST"\n', '"$DIGEST" || :\n', 1)


def boot_step(wf):
    return next(s for s in wf["jobs"]["images"]["steps"] if "image-boots.sh" in str(s.get("run")))


def no_boot(wf):
    wf["jobs"]["images"]["steps"].remove(boot_step(wf))


def boot_amd64_only(wf):
    boot_step(wf)["if"] = "matrix.platform == 'linux/amd64'"


def boot_after_upload(wf):
    steps = wf["jobs"]["images"]["steps"]
    step = boot_step(wf)
    steps.remove(step)
    steps.append(step)


def boot_of_another_image(wf):
    boot_step(wf)["env"]["LOADED"] = "${{ env.REGISTRY }}/${{ matrix.image }}"


def boot_skipped(wf):
    boot_step(wf)["run"] = "true"


def release_widened(wf):
    wf["jobs"]["release"]["permissions"]["packages"] = "write"


def store_step(wf, job):
    return next(s for s in wf["jobs"][job]["steps"] if "containerd-image-store.sh" in str(s.get("run")))


def move_store_step(wf, job, after):
    steps = wf["jobs"][job]["steps"]
    step = store_step(wf, job)
    steps.remove(step)
    steps.insert(step_index(wf["jobs"][job], after) + 1, step)


def no_store_switch(job):
    def mutate(wf):
        wf["jobs"][job]["steps"].remove(store_step(wf, job))

    return mutate


def store_switch_if(job):
    def mutate(wf):
        store_step(wf, job)["if"] = "runner.arch == 'X64'"

    return mutate


def store_switch_continues(job):
    def mutate(wf):
        store_step(wf, job)["continue-on-error"] = True

    return mutate


def store_switch_ignored(job):
    def mutate(wf):
        store_step(wf, job)["run"] = STORE_SWITCH + " || true\n"

    return mutate


def store_switch_checks_only(job):
    def mutate(wf):
        store_step(wf, job)["run"] = STORE_SWITCH + " --check\n"

    return mutate


def store_switch_after_buildx(wf):
    move_store_step(wf, "images", lambda s: "docker/setup-buildx-action" in str(s.get("uses")))


def store_switch_after_build(wf):
    move_store_step(wf, "images", lambda s: "docker/build-push-action" in str(s.get("uses")))


def store_switch_after_test(wf):
    move_store_step(wf, "static", lambda s: str(s.get("run", "")).strip() == PUBLISH_TEST)


def publish_test_continues(wf):
    step = next(s for s in wf["jobs"]["static"]["steps"] if str(s.get("run", "")).strip() == PUBLISH_TEST)
    step["continue-on-error"] = True


def tag_step(wf):
    return wf["jobs"][TAG_JOB]["steps"][1]


def real_version():
    with open(os.path.join(ROOT, MIX_EXS)) as f:
        return declared_versions(f.read())[0]


def tag_need_dropped(job):
    def mutate(wf):
        wf["jobs"][job]["needs"].remove(TAG_JOB)

    return mutate


def no_tag_job(wf):
    del wf["jobs"][TAG_JOB]
    for job in wf["jobs"].values():
        if TAG_JOB in needs_of(job):
            job["needs"] = [n for n in needs_of(job) if n != TAG_JOB]


def tag_step_if(wf):
    tag_step(wf)["if"] = "startsWith(github.ref_name, 'v')"


def tag_step_ignored(wf):
    step = tag_step(wf)
    step["run"] = step["run"].replace("done < apps/prima/mix.exs", "done < apps/prima/mix.exs || true", 1)


def tag_step_continues(wf):
    tag_step(wf)["continue-on-error"] = True


def tag_job_continues(wf):
    wf["jobs"][TAG_JOB]["continue-on-error"] = True


def tag_against_fixed_version(wf):
    step = tag_step(wf)
    step["run"] = step["run"].replace(TAG_COMPARISON, '"$GITHUB_REF_NAME" != "%s"' % real_version(), 1)


def fixed_tag_against_declared(wf):
    step = tag_step(wf)
    step["run"] = step["run"].replace(TAG_COMPARISON, '"%s" != "${declared[0]}"' % real_version(), 1)


def tag_compared_inexactly(wf):
    # The tag compared after a leading character is trimmed: the check must
    # hold the tag to the declared version exactly.
    step = tag_step(wf)
    step["run"] = step["run"].replace(TAG_COMPARISON, '"${GITHUB_REF_NAME#v}" != "${declared[0]}"', 1)


def tag_mismatch_exits_0(wf):
    step = tag_step(wf)
    mismatch = 'apps/prima/mix.exs declares"\n  exit 1'
    step["run"] = step["run"].replace(mismatch, mismatch.replace("exit 1", "exit 0"), 1)


def tag_reads_another_file(wf):
    step = tag_step(wf)
    step["run"] = step["run"].replace("done < apps/prima/mix.exs", "done < mix.exs", 1)


def tag_env_fixed(wf):
    tag_step(wf)["env"] = {"GITHUB_REF_NAME": real_version()}


def tag_checkout_main(wf):
    wf["jobs"][TAG_JOB]["steps"][0]["with"] = {"ref": "main"}


def tag_job_extra_step(wf):
    wf["jobs"][TAG_JOB]["steps"].append({"name": "x", "run": "echo published"})


def tag_job_widened(wf):
    wf["jobs"][TAG_JOB]["permissions"]["packages"] = "write"


def tag_step_replace(old, new):
    def mutate(wf):
        step = tag_step(wf)
        step["run"] = step["run"].replace(old, new, 1)

    return mutate


TAG_RULE = "release=" + BASH_RULE
TAG_RULE_CHECK = '[ "${#declared[@]}" -ne 1 ] || ! [[ "${declared[0]}" =~ $release ]]'


def prerelease_filter_dropped(wf):
    wf.get("on", wf.get(True))["push"]["tags"] = TAG_FILTERS[:1]


def homebrew_step(wf):
    return step_named(wf, "release", HOMEBREW)


def homebrew_replace(old, new):
    def mutate(wf):
        step = homebrew_step(wf)
        step["run"] = step["run"].replace(old, new, 1)

    return mutate


def homebrew_without_skip(wf):
    step = homebrew_step(wf)
    step["run"] = re.sub(r'case "\$TAG" in\n.*?esac\n', "", step["run"], count=1, flags=re.DOTALL)


def homebrew_tag_elsewhere(wf):
    homebrew_step(wf)["env"]["TAG"] = "${{ github.sha }}"


def merge_step(wf, predicate):
    return next(s for s in wf["jobs"]["merge"]["steps"] if predicate(s))


def is_record(s):
    return run_lines(s) == run_lines({"run": RECORD_RUN})


def is_merged_upload(s):
    return "actions/upload-artifact" in str(s.get("uses"))


def no_merged_upload(wf):
    wf["jobs"]["merge"]["steps"].remove(merge_step(wf, is_merged_upload))


def merged_upload_renamed(wf):
    merge_step(wf, is_merged_upload)["with"]["name"] = "merged"


def merged_upload_may_be_empty(wf):
    merge_step(wf, is_merged_upload)["with"]["if-no-files-found"] = "warn"


def merged_digest_from_elsewhere(wf):
    merge_step(wf, is_record)["env"]["DIGEST"] = "${{ needs.images.outputs.digest }}"


def merged_digest_recorded_first(wf):
    steps = wf["jobs"]["merge"]["steps"]
    record = merge_step(wf, is_record)
    steps.remove(record)
    steps.insert(step_index(wf["jobs"]["merge"], lambda s: "merge-image.sh" in str(s.get("run"))), record)


def release_steps(wf):
    return wf["jobs"]["release"]["steps"]


def note_check_dropped(wf):
    del wf["jobs"][TAG_JOB]["steps"][2]


def note_check_continues(wf):
    wf["jobs"][TAG_JOB]["steps"][2]["continue-on-error"] = True


def note_check_ignored(wf):
    wf["jobs"][TAG_JOB]["steps"][2]["run"] = NOTE_CHECK_RUN + " || true"


def is_note(s):
    return "release-note.sh" in str(s.get("run", ""))


def note_not_written(wf):
    release_steps(wf).remove(release_step(wf, is_note))


def note_after_goreleaser(wf):
    steps = release_steps(wf)
    note = release_step(wf, is_note)
    steps.remove(note)
    steps.insert(step_index(wf["jobs"]["release"], lambda s: "goreleaser-action" in str(s.get("uses"))) + 1, note)


def goreleaser_without_note(wf):
    step_using(wf, "release", "goreleaser/goreleaser-action")["with"]["args"] = "release --clean"


def goreleaser_note_from_elsewhere(wf):
    step_using(wf, "release", "goreleaser/goreleaser-action")["with"]["args"] = GORELEASER_ARGS.replace("notes.md", "other.md")


def release_step(wf, predicate):
    return next(s for s in release_steps(wf) if predicate(s))


def is_scaffold(s):
    return "scaffold-tarball.sh" in str(s.get("run", ""))


def is_manifest(s):
    return MANIFEST_OUT in str(s.get("run", ""))


def is_validate(s):
    return "--manifest" in str(s.get("run", ""))


def is_sign(s):
    return "sign-blob" in str(s.get("run", ""))


def is_goreleaser(s):
    return "goreleaser/goreleaser-action" in str(s.get("uses"))


def move_release_step(predicate, before):
    def mutate(wf):
        steps = release_steps(wf)
        step = release_step(wf, predicate)
        steps.remove(step)
        steps.insert(step_index(wf["jobs"]["release"], before), step)

    return mutate


def remove_release_step(predicate):
    def mutate(wf):
        release_steps(wf).remove(release_step(wf, predicate))

    return mutate


def release_without_merge(wf):
    wf["jobs"]["release"]["needs"].remove("merge")


def merged_by_pattern(wf):
    steps = release_steps(wf)
    at = step_index(wf["jobs"]["release"], lambda s: "download-artifact" in str(s.get("uses")))
    download = steps[at]
    wf["jobs"]["release"]["steps"] = [s for s in steps if "download-artifact" not in str(s.get("uses"))]
    download["with"] = {"pattern": "merged-*", "path": "${{ runner.temp }}/merged"}
    wf["jobs"]["release"]["steps"].insert(at, download)


def one_merged_download(wf):
    release_steps(wf).remove(release_step(wf, lambda s: s.get("with", {}).get("name") == "merged-cyfr-locus"))


def scaffold_unpinned(wf):
    release_step(wf, is_scaffold)["run"] = "bash scripts/scaffold-tarball.sh apps/codex/cyfr-scaffold.tar.gz\n"


def scaffold_rebuilt(wf):
    steps = release_steps(wf)
    steps.insert(
        step_index(wf["jobs"]["release"], is_sign),
        {"name": "x", "run": "bash scripts/scaffold-tarball.sh apps/codex/cyfr-scaffold.tar.gz\n"},
    )


def validation_if(wf):
    release_step(wf, is_validate)["if"] = "github.event_name == 'push'"


def sign_without_bundle(wf):
    step = release_step(wf, is_sign)
    step["run"] = step["run"].replace("--bundle", "--output-signature", 1)


def bundle_renamed(wf):
    step = release_step(wf, is_sign)
    step["run"] = step["run"].replace("release.json.sigstore.json", "release.json.bundle")


def sign_legacy_bundle(wf):
    step = release_step(wf, is_sign)
    step["run"] = step["run"].replace(" --new-bundle-format", "", 1)


def sign_once(wf):
    step = release_step(wf, is_sign)
    step["run"] = step["run"].replace("scripts/ci/retry.sh ", "", 1)


def schema_not_read(wf):
    step = release_step(wf, is_manifest)
    step["run"] = "\n".join(line for line in step["run"].splitlines() if not line.strip().startswith("schema=$("))


def schema_from_a_tag(wf):
    step = release_step(wf, is_manifest)
    step["run"] = step["run"].replace('"ghcr.io/cyfrworks/cyfr@$cyfr"', '"ghcr.io/cyfrworks/cyfr:$GITHUB_REF_NAME"', 1)


def schema_not_written(wf):
    step = release_step(wf, is_manifest)
    step["run"] = step["run"].replace(", schema_fingerprint: $schema}", "}", 1)


def manifest_in_checkout(wf):
    step = release_step(wf, is_validate)
    step["run"] = step["run"].replace('"$RUNNER_TEMP/release/release.json"', "apps/codex/release.json")


def no_manifest_dir_env(wf):
    del release_step(wf, is_goreleaser)["env"]["RELEASE_MANIFEST_DIR"]


def manifest_dir_elsewhere(wf):
    release_step(wf, is_goreleaser)["env"]["RELEASE_MANIFEST_DIR"] = "${{ runner.temp }}"


def sign_args(args):
    def mutate(config):
        config["signs"][0]["args"] = args

    return mutate


def drop_glob(glob):
    def mutate(config):
        config["release"]["extra_files"].remove({"glob": glob})

    return mutate


def replace_glob(old, new):
    def mutate(config):
        files = config["release"]["extra_files"]
        files[files.index({"glob": old})] = {"glob": new}

    return mutate


def package_step(wf, action):
    return next(s for s in wf["jobs"][PACKAGE_JOB]["steps"] if action in str(s.get("uses", "")) + str(s.get("run", "")))


def package_change(action, change):
    def mutate(wf):
        change(package_step(wf, action))

    return mutate


def package_replace(action, old, new):
    def mutate(wf):
        step = package_step(wf, action)
        step["run"] = step["run"].replace(old, new)

    return mutate


def package_arm64_emulated(wf):
    wf["jobs"][PACKAGE_JOB]["strategy"]["matrix"]["include"][1]["runner"] = "ubuntu-24.04"


def package_amd64_alone(wf):
    wf["jobs"][PACKAGE_JOB]["strategy"]["matrix"]["include"].pop()


def package_uploaded_before_smoke(wf):
    steps = wf["jobs"][PACKAGE_JOB]["steps"]
    upload = steps.pop()
    steps.insert(steps.index(package_step(wf, "linux.sh")), upload)


def package_not_smoked(wf):
    wf["jobs"][PACKAGE_JOB]["steps"].remove(package_step(wf, "linux.sh"))


def package_identity_unchecked(wf):
    wf["jobs"][PACKAGE_JOB]["steps"].remove(package_step(wf, "installed-version.sh"))


def package_cached(wf):
    wf["jobs"][PACKAGE_JOB]["steps"].insert(3, {"uses": "actions/cache@x", "with": {"path": "~/.cache/electron", "key": "electron"}})


def installers_steps(wf):
    return wf["jobs"][INSTALLERS_JOB]["steps"]


def installers_step(wf, predicate):
    return next(s for s in installers_steps(wf) if predicate(s))


def packages_by_pattern(wf):
    steps = [s for s in installers_steps(wf) if not str(s.get("with", {}).get("name", "")).startswith("cyfr-desktop-")]
    steps.insert(1, {"uses": "actions/download-artifact@x",
                     "with": {"pattern": "cyfr-desktop-*", "path": "${{ runner.temp }}/checked/packages"}})
    wf["jobs"][INSTALLERS_JOB]["steps"] = steps


def one_package_download(wf):
    installers_steps(wf).remove(installers_step(wf, lambda s: s.get("with", {}).get("name") == "cyfr-desktop-linux-arm64"))


def package_into_the_checkout(wf):
    installers_step(wf, lambda s: s.get("with", {}).get("name") == "cyfr-desktop-linux-amd64")["with"]["path"] = "apps/codex/packages"


def packages_after_check(wf):
    steps = installers_steps(wf)
    moved = installers_step(wf, lambda s: s.get("with", {}).get("name") == "cyfr-desktop-linux-arm64")
    steps.remove(moved)
    steps.insert(steps.index(installers_step(wf, lambda s: "--installers" in str(s.get("run", "")))) + 1, moved)


def packages_fetched_again(wf):
    steps = release_steps(wf)
    steps.insert(steps.index(release_step(wf, is_goreleaser)), {"uses": "actions/download-artifact@x",
                 "with": {"name": "cyfr-desktop-linux-amd64", "path": "${{ runner.temp }}/checked/packages"}})


def no_packages_dir_env(wf):
    del release_step(wf, is_goreleaser)["env"]["RELEASE_PACKAGES_DIR"]


def drop_summed(glob):
    def mutate(config):
        config["checksum"]["extra_files"].remove({"glob": glob})

    return mutate


def needs_dropped(job, need):
    def mutate(wf):
        wf["jobs"][job]["needs"] = [n for n in needs_of(wf["jobs"][job]) if n != need]

    return mutate


def job_step(job, needle):
    """The step of `job` whose action or script names `needle`."""
    def find(wf):
        return next(s for s in wf["jobs"][job]["steps"] if needle in str(s.get("uses", "")) + str(s.get("run", "")))

    return find


def change_step(job, needle, change):
    def mutate(wf):
        change(job_step(job, needle)(wf))

    return mutate


def replace_in_step(job, needle, old, new):
    def mutate(wf):
        step = job_step(job, needle)(wf)
        step["run"] = step["run"].replace(old, new)

    return mutate


def remove_step(job, needle):
    def mutate(wf):
        wf["jobs"][job]["steps"].remove(job_step(job, needle)(wf))

    return mutate


def move_step_first(job, needle, before):
    """The step naming `needle` moved before the one naming `before`."""
    def mutate(wf):
        steps = wf["jobs"][job]["steps"]
        step = job_step(job, needle)(wf)
        steps.remove(step)
        steps.insert(steps.index(job_step(job, before)(wf)), step)

    return mutate


def apple_input_renamed(wf):
    wf["jobs"][MAC_JOB]["secrets"]["APPLE_TEAM_ID"] = "${{ secrets.APPLE_SIGNING_IDENTITY }}"


def apple_input_to_goreleaser(wf):
    release_step(wf, is_goreleaser)["env"]["APPLE_API_KEY"] = "${{ secrets.APPLE_API_KEY }}"


def tap_token_to_goreleaser(wf):
    release_step(wf, is_goreleaser)["env"]["HOMEBREW_TAP_TOKEN"] = "${{ secrets.HOMEBREW_TAP_TOKEN }}"


def apple_input_to_windows(wf):
    wf["jobs"][WINDOWS_JOB]["env"]["APPLE_CERTIFICATE"] = "${{ secrets.APPLE_CERTIFICATE }}"


def another_secret_read(wf):
    job_step(WINDOWS_JOB, "build.mjs")(wf)["env"] = {"NPM_TOKEN": "${{ secrets.NPM_TOKEN }}"}


def download_dropped(name):
    def mutate(wf):
        installers_steps(wf).remove(installers_step(wf, lambda s: s.get("with", {}).get("name") == name))

    return mutate


def windows_matrix(change):
    def mutate(wf):
        change(wf["jobs"][WINDOWS_JOB]["strategy"]["matrix"]["include"])

    return mutate


PACKAGE_JOB_MUTANTS = [
    ("no Mac package job", lambda wf: wf["jobs"].pop(MAC_JOB)),
    ("the installers' check without the Mac package", needs_dropped(INSTALLERS_JOB, MAC_JOB)),
    ("the tag check dropped from the Mac package's needs", needs_dropped(MAC_JOB, TAG_JOB)),
    ("a check dropped from the Mac package's needs", needs_dropped(MAC_JOB, "keeper-ci")),
    ("the Mac package run always()", lambda wf: wf["jobs"][MAC_JOB].update({"if": "always()"})),
    ("every secret passed to the Mac package", lambda wf: wf["jobs"][MAC_JOB].update(secrets="inherit")),
    ("an Apple input not passed", lambda wf: wf["jobs"][MAC_JOB]["secrets"].pop("APPLE_PROVISIONING_PROFILE")),
    ("an Apple input passed under another's name", apple_input_renamed),
    ("an Apple input given to GoReleaser", apple_input_to_goreleaser),
    ("an Apple input in the Windows package's job", apple_input_to_windows),
    ("the tap's token given to GoReleaser", tap_token_to_goreleaser),
    ("another secret read by a package's build", another_secret_read),
    ("desktop-mac.yml called at another ref", lambda wf: wf["jobs"][MAC_JOB].update(uses="cyfrworks/cyfr/.github/workflows/desktop-mac.yml@main")),
    ("the Mac package at a fixed version", lambda wf: wf["jobs"][MAC_JOB].update({"with": {"version": "0.0.0"}})),
    ("contents: write on the Mac package", lambda wf: wf["jobs"][MAC_JOB]["permissions"].update(contents="write")),
    ("no Windows package job", lambda wf: wf["jobs"].pop(WINDOWS_JOB)),
    ("no Windows cyfr job", lambda wf: wf["jobs"].pop(WINDOWS_CYFR_JOB)),
    ("the installers' check without the Windows package", needs_dropped(INSTALLERS_JOB, WINDOWS_JOB)),
    ("the Windows package without its cyfr", needs_dropped(WINDOWS_JOB, WINDOWS_CYFR_JOB)),
    ("the tag check dropped from the Windows package's needs", needs_dropped(WINDOWS_JOB, TAG_JOB)),
    ("the tag check dropped from the Windows cyfr's needs", needs_dropped(WINDOWS_CYFR_JOB, TAG_JOB)),
    ("Windows arm64 built on amd64's runner", windows_matrix(lambda m: m[1].update(runner="windows-latest"))),
    ("the Windows package on amd64 alone", windows_matrix(lambda m: m.pop())),
    ("contents: write on the Windows package", lambda wf: wf["jobs"][WINDOWS_JOB]["permissions"].update(contents="write")),
    ("the Windows package's npm from a cache", change_step(WINDOWS_JOB, "actions/setup-node", lambda s: s["with"].pop("package-manager-cache"))),
    ("the Windows package's version fixed", replace_in_step(WINDOWS_JOB, "build.mjs", '"$GITHUB_REF_NAME"', "0.0.0-ci")),
    ("the Windows package's cyfr built in place", replace_in_step(WINDOWS_JOB, "build.mjs", '"$RUNNER_TEMP/cyfr/cyfr.exe"', "cyfr.exe")),
    ("the Windows package not smoked", remove_step(WINDOWS_JOB, "smoke.sh")),
    ("the Windows package's installed cyfr unchecked", remove_step(WINDOWS_JOB, "installed-version.sh")),
    ("the Windows package not removed", remove_step(WINDOWS_JOB, "windows.ps1 remove")),
    ("the Windows package's smoke allowed to fail", change_step(WINDOWS_JOB, "smoke.sh", lambda s: s.update({"continue-on-error": True}))),
    ("the Windows package uploaded before its smoke", move_step_first(WINDOWS_JOB, "upload-artifact", "smoke.sh")),
    ("the Windows package uploaded by a wildcard",
     change_step(WINDOWS_JOB, "upload-artifact", lambda s: s["with"].update(path="${{ runner.temp }}/package/*.msi"))),
    ("the Windows cyfr built for Linux", lambda wf: wf["jobs"][WINDOWS_CYFR_JOB]["env"].pop("GOOS")),
    ("the Windows cyfr built as a snapshot",
     change_step(WINDOWS_CYFR_JOB, "goreleaser-action", lambda s: s["with"].update(args=WINDOWS_CYFR_BUILD_ARGS + " --snapshot"))),
    ("the Windows cyfr by another GoReleaser", change_step(WINDOWS_CYFR_JOB, "goreleaser-action", lambda s: s["with"].update(version="latest"))),
    ("the Windows cyfr's Go from a cache", change_step(WINDOWS_CYFR_JOB, "actions/setup-go", lambda s: s["with"].pop("cache"))),
    ("the DMG not downloaded", download_dropped("cyfr-desktop-darwin-arm64")),
    ("an MSI not downloaded", download_dropped("cyfr-desktop-windows-arm64")),
    ("no cask written", remove_step(INSTALLERS_JOB, "homebrew-cask.sh")),
    ("no check of the installers and the cask", remove_step(INSTALLERS_JOB, "--installers")),
    ("the installers' check allowed to fail", change_step(INSTALLERS_JOB, "--installers", lambda s: s.update({"continue-on-error": True}))),
    ("the installers' check with an if:", change_step(INSTALLERS_JOB, "--installers", lambda s: s.update({"if": "!contains(github.ref_name, '-')"}))),
    ("the checked set handed on before the check", move_step_first(INSTALLERS_JOB, "upload-artifact", "--installers")),
    ("the cask written after its check", move_step_first(INSTALLERS_JOB, "--installers", "homebrew-cask.sh")),
    ("the cask written for another folder",
     replace_in_step(INSTALLERS_JOB, "homebrew-cask.sh", '"$RUNNER_TEMP/checked/packages"', '"$RUNNER_TEMP/other"')),
    ("the cask naming another download folder", replace_in_step(INSTALLERS_JOB, "homebrew-cask.sh", "releases/download", "releases/latest/download")),
    ("the installers checked in another folder",
     replace_in_step(INSTALLERS_JOB, "--installers", '--installers "$RUNNER_TEMP/checked/packages"', '--installers "$RUNNER_TEMP/other"')),
    ("the checked set handed on by another name", change_step(INSTALLERS_JOB, "upload-artifact", lambda s: s["with"].update(name="installers"))),
    ("the installers' check job allowed to fail", lambda wf: wf["jobs"][INSTALLERS_JOB].update({"continue-on-error": True})),
    ("the installers' check job switched off", lambda wf: wf["jobs"][INSTALLERS_JOB].update({"if": "false"})),
    ("the Windows package switched off", lambda wf: wf["jobs"][WINDOWS_JOB].update({"if": "false"})),
    ("the merge without the installers' check", needs_dropped("merge", INSTALLERS_JOB)),
    ("the merge needing the packages and not their check",
     lambda wf: wf["jobs"]["merge"].update(needs=["images", PACKAGE_JOB, MAC_JOB, WINDOWS_JOB])),
    ("a new publishing job without the check", lambda wf: wf["jobs"].update(notes={
        "needs": ["version"] + CHECKS, "if": "github.repository == 'cyfrworks/cyfr'", "timeout-minutes": 5,
        "permissions": {"contents": "write"}, "runs-on": "ubuntu-latest", "steps": [{"run": "gh release create x"}]})),
    ("the Linux package's architecture unchecked", remove_step(PACKAGE_JOB, "installed-machine.sh")),
    ("the Windows package's architecture unchecked", remove_step(WINDOWS_JOB, "installed-machine.sh")),
    ("the Windows package checked for amd64 alone", replace_in_step(WINDOWS_JOB, "installed-machine.sh", '"$ARCH"', "amd64")),
    ("the Windows package's app unread", replace_in_step(WINDOWS_JOB, "installed-machine.sh", ' "$APP"', "")),
    ("the tap replaced by an older release", homebrew_replace("if newer_in_tap; then keep_newer; fi\nstage\n", "stage\n")),
    ("a retry that does not read the tap again", homebrew_replace("git -C \"$workdir\" reset --hard origin/main\n  if newer_in_tap; then keep_newer; fi\n", "git -C \"$workdir\" reset --hard origin/main\n")),
    ("an unreadable cask taken as an empty tap",
     homebrew_replace('[ -e "$tap_cask" ] || return 1', 'grep -qE \'^[[:space:]]*version "\' "$tap_cask" 2>/dev/null || return 1')),
    ("the tap's version compared as text", homebrew_replace("| sort -V |", "| sort |")),
    ("the token in the clone's URL", homebrew_replace(
        'tap_git clone --depth 1 https://github.com/cyfrworks/homebrew-cyfr.git "$workdir"',
        'git clone --depth 1 "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/cyfrworks/homebrew-cyfr.git" "$workdir"')),
    ("the tap fed a cask from dist", homebrew_replace('CASK_SRC="$RUNNER_TEMP/checked/cask/cyfr.rb"', 'CASK_SRC="apps/codex/dist/homebrew/Casks/cyfr.rb"')),
]


# Mutants of desktop-mac.yml, each refused with the real release.yml.
def mac_steps(mac):
    return mac["jobs"]["mac"]["steps"]


def mac_step(mac, needle):
    return next(s for s in mac_steps(mac) if needle in str(s.get("uses", "")) + str(s.get("run", "")))


def mac_on(mac):
    return mac.get("on", mac.get(True))


def mac_change(needle, change):
    def mutate(mac):
        change(mac_step(mac, needle))

    return mutate


def mac_removed(needle):
    def mutate(mac):
        mac_steps(mac).remove(mac_step(mac, needle))

    return mutate


def mac_by_go_build(mac):
    step = mac_step(mac, "goreleaser-action")
    step.pop("uses")
    step.pop("with")
    step["working-directory"] = "apps/codex"
    step["run"] = 'CGO_ENABLED=0 go build -o "$RUNNER_TEMP/cyfr/cyfr" .'


MAC_MUTANTS = [
    ("desktop-mac.yml started by a pull request", lambda m: mac_on(m).update(pull_request=None)),
    ("desktop-mac.yml started by a push", lambda m: mac_on(m).update(push={"branches": ["main"]})),
    ("an Apple input the call does not require", lambda m: mac_on(m)["workflow_call"]["secrets"]["APPLE_TEAM_ID"].update(required=False)),
    ("an Apple input the call does not take", lambda m: mac_on(m)["workflow_call"]["secrets"].pop("APPLE_API_ISSUER")),
    ("an Apple input in the job's environment", lambda m: m["jobs"]["mac"]["env"].update(APPLE_API_KEY="${{ secrets.APPLE_API_KEY }}")),
    ("an Apple input in the smoke's step", mac_change("mac.sh", lambda s: s.update(env={"APPLE_API_KEY": "${{ secrets.APPLE_API_KEY }}"}))),
    ("an Apple input to the workflow", lambda m: m.update(env={"APPLE_TEAM_ID": "${{ secrets.APPLE_TEAM_ID }}"})),
    ("an Apple input under another's name",
     mac_change("--distribution", lambda s: s["env"].update(APPLE_TEAM_ID="${{ secrets.APPLE_SIGNING_IDENTITY }}"))),
    ("the package built on an Intel runner", lambda m: m["jobs"]["mac"].update({"runs-on": "macos-15-intel"})),
    ("an Intel package beside it", lambda m: m["jobs"]["mac"].update(strategy={"matrix": {"include": [{"arch": "arm64"}, {"arch": "amd64"}]}})),
    ("the package built for Intel", lambda m: m["jobs"]["mac"]["env"].update(ARCH="amd64")),
    ("contents: write on desktop-mac.yml", lambda m: m["permissions"].update(contents="write")),
    ("a second job in desktop-mac.yml", lambda m: m["jobs"].update(other={"runs-on": "macos-latest", "steps": [{"run": "true"}]})),
    ("the package's cyfr built with go build", mac_by_go_build),
    ("the package's cyfr by another GoReleaser", mac_change("goreleaser-action", lambda s: s["with"].update(version="latest"))),
    ("the package's cyfr always a snapshot",
     mac_change("goreleaser-action", lambda s: s["with"].update(args="build --single-target --clean --snapshot --output ${{ runner.temp }}/cyfr/cyfr"))),
    ("the package's npm from a cache", mac_change("actions/setup-node", lambda s: s["with"].update(cache="npm"))),
    ("the package built unsigned", mac_change("--distribution", lambda s: s.update(run=s["run"].replace(" --distribution", "")))),
    ("the package's signing allowed to fail", mac_change("--distribution", lambda s: s.update({"continue-on-error": True}))),
    ("the package not smoked", mac_removed("mac.sh")),
    ("the package's architecture unchecked", mac_removed("installed-machine.sh")),
    ("the package's architecture checked on a call alone", mac_change("installed-machine.sh", lambda s: s.update({"if": "inputs.version != ''"}))),
    ("the job switched off", lambda m: m["jobs"]["mac"].update({"if": "false"})),
    ("the job allowed to fail", lambda m: m["jobs"]["mac"].update({"continue-on-error": True})),
    ("the installed cyfr unchecked", mac_removed("installed-version.sh")),
    ("the installed cyfr checked on a dispatch alone", mac_change("installed-version.sh", lambda s: s.update({"if": "inputs.upload == true"}))),
    ("the package uploaded only when a dispatch asks", mac_change("upload-artifact", lambda s: s.update({"if": "inputs.upload == true"}))),
    ("the package uploaded before its smoke",
     lambda m: mac_steps(m).insert(mac_steps(m).index(mac_step(m, "mac.sh")), mac_steps(m).pop())),
    ("another DMG uploaded", lambda m: m["jobs"]["mac"]["env"].update(DMG="apps/codex/desktop/dist/*.dmg")),
    ("a package upload that may be empty", mac_change("upload-artifact", lambda s: s["with"].update({"if-no-files-found": "warn"}))),
]


GORELEASER_MUTANTS = [
    ("a package not attached", drop_glob(PACKAGE_GLOBS[1])),
    ("a package attached and not summed", drop_summed(PACKAGE_GLOBS[1])),
    ("the packages attached by a wildcard", replace_glob(PACKAGE_GLOBS[0], "{{ .Env.RELEASE_PACKAGES_DIR }}/*.deb")),
    ("the scaffold not summed", drop_summed(SCAFFOLD_GLOB)),
    ("the changelog disabled", lambda c: c.update(changelog={"disable": True})),
    ("the changelog disabled by a template", lambda c: c.update(changelog={"disable": "{{ true }}"})),
    ("release.json not attached", drop_glob(MANIFEST_GLOBS[0])),
    ("release.json's bundle not attached", drop_glob(MANIFEST_GLOBS[1])),
    ("the scaffold not attached", drop_glob(SCAFFOLD_GLOB)),
    ("release.json attached from the workdir", replace_glob(MANIFEST_GLOBS[0], "release.json")),
    ("the bundle attached by a wildcard", replace_glob(MANIFEST_GLOBS[1], "{{ .Env.RELEASE_MANIFEST_DIR }}/*")),
    ("a second release.json attached", lambda c: c["release"]["extra_files"].append({"glob": "dist/release.json"})),
    ("checksums.txt signed into the legacy bundle", sign_args([a for a in CHECKSUM_SIGN_ARGS if a != "--new-bundle-format"])),
    ("checksums.txt signed without a bundle", sign_args(["cosign", "sign-blob", "--new-bundle-format", "${artifact}", "--yes"])),
    ("checksums.txt signed once", lambda c: c["signs"][0].update(cmd="cosign", args=CHECKSUM_SIGN_ARGS[1:])),
    ("no prerelease: auto", lambda c: c["release"].pop("prerelease")),
    ("every release a pre-release", lambda c: c["release"].update(prerelease=True)),
    ("no release a pre-release", lambda c: c["release"].update(prerelease=False)),
    ("no make_latest: false", lambda c: c["release"].pop("make_latest")),
    ("make_latest: true", lambda c: c["release"].update(make_latest=True)),
    ("the release binary check removed", lambda c: c["builds"][0].pop("hooks")),
    ("the release binary check on one of two builds",
     lambda c: c["builds"].append({k: v for k, v in copy.deepcopy(c["builds"][0]).items() if k != "hooks"} | {"id": "second"})),
    ("a DMG not summed", drop_summed(PACKAGE_GLOBS[2])),
    ("an MSI not attached", drop_glob(PACKAGE_GLOBS[4])),
    ("the cask's raw binary and quarantine hook back", lambda c: c.update(homebrew_casks=[{
        "binaries": ["cyfr"], "hooks": {"post": {"install": "system_command \"/usr/bin/xattr\""}}, "skip_upload": True}])),
    ("a Homebrew formula", lambda c: c.update(brews=[{"name": "cyfr"}])),
    ("the release binary check's command changed",
     lambda c: c["builds"][0]["hooks"]["post"][0].update(cmd='../../scripts/ci/release-binary-check.sh "{{ .Name }}"')),
]


MUTANTS = [
    ("no Linux package job", lambda wf: wf["jobs"].pop(PACKAGE_JOB)),
    ("the Linux package needing the merge that needs it", lambda wf: wf["jobs"][PACKAGE_JOB]["needs"].append("merge")),
    ("the installers' check without the Linux package", needs_dropped(INSTALLERS_JOB, PACKAGE_JOB)),
    ("the tag check dropped from the Linux package's needs", tag_need_dropped(PACKAGE_JOB)),
    ("a check dropped from the Linux package's needs", lambda wf: wf["jobs"][PACKAGE_JOB]["needs"].remove("codex-ci")),
    ("contents: write on the Linux package", lambda wf: wf["jobs"][PACKAGE_JOB]["permissions"].update(contents="write")),
    ("a secret in the Linux package's job", lambda wf: wf["jobs"][PACKAGE_JOB]["env"].update(T="${{ secrets.GITHUB_TOKEN }}")),
    ("a secret on the Linux package's GoReleaser", package_change("goreleaser-action", lambda s: s.update(env={"T": "${{ secrets.X }}"}))),
    ("the checkout's credential kept for the package's build", package_change("actions/checkout", lambda s: s["with"].pop("persist-credentials"))),
    ("arm64 built on amd64's runner", package_arm64_emulated),
    ("the Linux package on amd64 alone", package_amd64_alone),
    ("the package's Go from a cache", package_change("actions/setup-go", lambda s: s["with"].pop("cache"))),
    ("the package's npm from a cache", package_change("actions/setup-node", lambda s: s["with"].pop("package-manager-cache"))),
    ("a cache in the package's job", package_cached),
    ("the package's cyfr built as a snapshot", package_change("goreleaser-action", lambda s: s["with"].update(args=PACKAGE_BUILD_ARGS + " --snapshot"))),
    ("the package's cyfr by another GoReleaser", package_change("goreleaser-action", lambda s: s["with"].update(version="latest"))),
    ("the package's version fixed", package_replace("build.mjs", '"$GITHUB_REF_NAME"', "0.0.0-ci")),
    ("the package's install scripts run", package_replace("build.mjs", " --ignore-scripts", "")),
    ("the package not smoked", package_not_smoked),
    ("the package's smoke with an if:", package_change("linux.sh", lambda s: s.update({"if": "runner.arch == 'X64'"}))),
    ("the installed cyfr's version unchecked", package_identity_unchecked),
    ("the installed cyfr checked against a fixed version", package_replace("installed-version.sh", '"$GITHUB_REF_NAME"', "0.0.0")),
    ("another cyfr's version checked", package_replace("installed-version.sh", "/usr/bin/cyfr", "/usr/local/bin/cyfr")),
    ("the package uploaded before its smoke", package_uploaded_before_smoke),
    ("the package uploaded by a wildcard", package_change("upload-artifact", lambda s: s["with"].update(path="${{ runner.temp }}/package/*.deb"))),
    ("a package upload that may be empty", package_change("upload-artifact", lambda s: s["with"].update({"if-no-files-found": "warn"}))),
    ("the packages downloaded by pattern", packages_by_pattern),
    ("one package downloaded", one_package_download),
    ("a package downloaded into the checkout", package_into_the_checkout),
    ("a package downloaded after the check", packages_after_check),
    ("the CLI release fetching a package again", packages_fetched_again),
    ("no RELEASE_PACKAGES_DIR on GoReleaser", no_packages_dir_env),
    ("a check dropped from the build's needs", drop_need),
    ("the merge runs always()", merge_always),
    ("continue-on-error on the build job", build_continues),
    ("no cyfr-locus row", no_locus),
    ("the concurrency group publish", group_publish),
    ("a job-level concurrency", job_concurrency),
    ("continue-on-error on the scan step", scan_continues),
    ("no image jobs", no_image_jobs),
    ("digests downloaded by pattern", download_by_pattern),
    ("secrets: inherit", secrets_inherited),
    ("a tag pushed beside the outputs", tag_pushed),
    ("a scan that may fetch from a registry", scan_may_fetch),
    ("no scanned-is-pushed step", no_comparison),
    ("|| true on the merge", merge_ignores_failure),
    ("broad default permissions", broad_default_permissions),
    ("the loaded image named under the registry", loaded_under_registry),
    ("no max-mode provenance on the build", no_provenance),
    ("no APT_REFRESH build argument", no_apt_refresh),
    ("an APT_REFRESH that is not the archive's key", apt_refresh_fixed),
    ("an APT_REFRESH written for one image only", apt_refresh_for_locus_only),
    ("an APT_REFRESH step with an if:", apt_refresh_skipped),
    ("an APT_REFRESH step after the build", apt_refresh_after_build),
    ("an exit before the APT_REFRESH date", apt_refresh_exits_first),
    ("the APT_REFRESH date overwritten after it", apt_refresh_overwritten),
    ("a scan whose findings never fail it", scan_never_fails),
    ("|| : after the scanned-is-pushed check", comparison_ignored),
    ("packages: write on the CLI release", release_widened),
    ("no boot of the loaded image", no_boot),
    ("the boot on amd64 alone", boot_amd64_only),
    ("the boot after the digest's upload", boot_after_upload),
    ("the boot of an image the build did not load", boot_of_another_image),
    ("a boot step that runs nothing", boot_skipped),
    ("no switch to the containerd image store", no_store_switch("images")),
    ("the store switch after buildx's setup", store_switch_after_buildx),
    ("the store switch after the build", store_switch_after_build),
    ("the store switch with an if:", store_switch_if("images")),
    ("continue-on-error on the store switch", store_switch_continues("images")),
    ("|| true after the store switch", store_switch_ignored("images")),
    ("a store switch that only checks", store_switch_checks_only("images")),
    ("the tag check dropped from the build's needs", tag_need_dropped("images")),
    ("the tag check dropped from the CLI release's needs", tag_need_dropped("release")),
    ("no tag check job", no_tag_job),
    ("the tag comparison with an if:", tag_step_if),
    ("|| true in the tag comparison", tag_step_ignored),
    ("continue-on-error on the tag comparison", tag_step_continues),
    ("continue-on-error on the tag check job", tag_job_continues),
    ("the tag compared with a fixed version", tag_against_fixed_version),
    ("a fixed tag compared with the declared version", fixed_tag_against_declared),
    ("an inexact tag comparison", tag_compared_inexactly),
    ("a tag mismatch that exits 0", tag_mismatch_exits_0),
    ("no note check in the tag check", note_check_dropped),
    ("continue-on-error on the note check", note_check_continues),
    ("the note check's refusal ignored", note_check_ignored),
    ("the release note not written", note_not_written),
    ("the release note written after GoReleaser", note_after_goreleaser),
    ("GoReleaser without the release note", goreleaser_without_note),
    ("GoReleaser's notes from another file", goreleaser_note_from_elsewhere),
    ("the version read from another file", tag_reads_another_file),
    ("GITHUB_REF_NAME fixed on the tag comparison", tag_env_fixed),
    ("the tag check checking out main", tag_checkout_main),
    ("a step added to the tag check", tag_job_extra_step),
    ("packages: write on the tag check", tag_job_widened),
    ("the tag check's rule without pre-releases", tag_step_replace(TAG_RULE, "release=" + BARE_RULE)),
    ("the tag check's rule unanchored at its end", tag_step_replace(TAG_RULE, TAG_RULE.replace("?$'", "?'"))),
    ("the tag check without LC_ALL=C", tag_step_replace(C_LOCALE + "\n", "")),
    ("the declared version unchecked against the rule", tag_step_replace(TAG_RULE_CHECK, '[ "${#declared[@]}" -ne 1 ]')),
    ("no pre-release tag starts the workflow", prerelease_filter_dropped),
    ("the Homebrew step without its pre-release skip", homebrew_without_skip),
    ("the Homebrew step skipping only an rc", homebrew_replace("*-*)", "*-rc*)")),
    ("a git call before the Homebrew step's skip", homebrew_replace('case "$TAG" in\n', 'git ls-remote x\ncase "$TAG" in\n')),
    ("the Homebrew step's TAG not the tag", homebrew_tag_elsewhere),
    ("no merged digest upload", no_merged_upload),
    ("the merged digest uploaded under another name", merged_upload_renamed),
    ("a merged digest upload that may be empty", merged_upload_may_be_empty),
    ("a merged digest that is not merge-image.sh's", merged_digest_from_elsewhere),
    ("the merged digest recorded before the merge", merged_digest_recorded_first),
    ("the CLI release without the merge", release_without_merge),
    ("the merged digests downloaded by pattern", merged_by_pattern),
    ("one merged digest downloaded", one_merged_download),
    ("the scaffold built without the digests", scaffold_unpinned),
    ("the scaffold rebuilt after the validation", scaffold_rebuilt),
    ("the manifest written before the scaffold", move_release_step(is_manifest, is_scaffold)),
    ("no manifest validation", remove_release_step(is_validate)),
    ("the manifest validation with an if:", validation_if),
    ("the manifest signed before its validation", move_release_step(is_sign, is_validate)),
    ("no manifest signature", remove_release_step(is_sign)),
    ("a manifest signature without --bundle", sign_without_bundle),
    ("a manifest signed into the legacy bundle", sign_legacy_bundle),
    ("the manifest signed once", sign_once),
    ("the manifest's bundle under another name", bundle_renamed),
    ("GoReleaser before the manifest's signature", move_release_step(is_goreleaser, is_sign)),
    ("the manifest validated inside the checkout", manifest_in_checkout),
    ("no schema fingerprint read for the manifest", schema_not_read),
    ("the schema fingerprint read from a tag, not the merged digest", schema_from_a_tag),
    ("the schema fingerprint read and not written", schema_not_written),
    ("no RELEASE_MANIFEST_DIR on GoReleaser", no_manifest_dir_env),
    ("a RELEASE_MANIFEST_DIR that is not the manifest's", manifest_dir_elsewhere),
]

# Mutants of CI's image builds, each refused by check_ci_builds.
def locus_built_plainly(workflows, actions):
    step = next(s for s in workflows["test.yml"]["jobs"]["locus-image"]["steps"] if s.get("uses") == IMAGE_BUILD)
    step.pop("uses")
    step.pop("with")
    step["run"] = "docker build -f Dockerfile.locus -t cyfr-locus:ci ."


def app_built_by_build_push(workflows, actions):
    step = next(s for s in workflows["test.yml"]["jobs"]["app-image"]["steps"] if s.get("uses") == IMAGE_BUILD)
    step["uses"] = "docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc"
    step["with"] = {"context": ".", "file": "Dockerfile", "load": True, "tags": "cyfr:push"}


def arm64_built_by_buildx(workflows, actions):
    step = next(s for s in workflows["locus-arm64.yml"]["jobs"]["pinned-programs"]["steps"] if s.get("uses") == IMAGE_BUILD)
    step.pop("uses")
    step.pop("with")
    step["run"] = "docker buildx build --load -f Dockerfile.locus -t cyfr-locus:ci ."


def image_build_dated(workflows, actions):
    step = next(s for s in actions["image-build"]["runs"]["steps"] if s.get("id") == "apt-key")
    step["run"] = step["run"].replace("$(scripts/apt-key.sh)", "$(date -u +%F)")


def image_build_without_key(workflows, actions):
    build = next(s for s in actions["image-build"]["runs"]["steps"] if "build-push-action" in str(s.get("uses")))
    del build["with"]["build-args"]


def image_build_twice(workflows, actions):
    steps = actions["image-build"]["runs"]["steps"]
    steps.append({"name": "Build again", "shell": "bash", "run": "docker build -f Dockerfile ."})


def another_action_builds(workflows, actions):
    actions["planted"] = {"runs": {"using": "composite", "steps": [{"uses": "docker/build-push-action@v7"}]}}


CI_BUILD_MUTANTS = [
    ("Test's Locus image made with a plain docker build", locus_built_plainly),
    ("Test's app image made with build-push-action", app_built_by_build_push),
    ("the arm64 Locus image made with docker buildx build", arm64_built_by_buildx),
    ("the action's key the UTC date", image_build_dated),
    ("the action's build without APT_REFRESH", image_build_without_key),
    ("the action building a second time with no key", image_build_twice),
    ("another action that builds an image", another_action_builds),
]

# Mutants of test.yml's static job, each refused by check_static.
TEST_MUTANTS = [
    ("no switch to the containerd image store", no_store_switch("static")),
    ("the store switch after the publication test", store_switch_after_test),
    ("the store switch with an if:", store_switch_if("static")),
    ("continue-on-error on the store switch", store_switch_continues("static")),
    ("|| true after the store switch", store_switch_ignored("static")),
    ("a store switch that only checks", store_switch_checks_only("static")),
    ("continue-on-error on the publication test", publish_test_continues),
]


def graph_mode():
    # Imported here: the release job's manifest mode runs without PyYAML.
    import yaml

    with open(RELEASE) as f:
        real = yaml.safe_load(f)
    reason = refusal(real)
    if reason is not None:
        print(f"FAIL: release.yml: {reason}")
        return 1
    with open(TEST) as f:
        test = yaml.safe_load(f)
    reason = check_static(test)
    if reason is not None:
        print(f"FAIL: test.yml: {reason}")
        return 1
    files = dockerfiles()
    reason = check_apt_layers(files)
    if reason is not None:
        print(f"FAIL: {reason}")
        return 1
    ci_workflows, ci_actions = ci_build_sources()
    reason = check_ci_builds(ci_workflows, ci_actions)
    if reason is not None:
        print(f"FAIL: {reason}")
        return 1
    with open(GORELEASER) as f:
        goreleaser = yaml.safe_load(f)
    reason = check_goreleaser(goreleaser) or check_ignored(CHECKOUT_WRITES)
    if reason is not None:
        print(f"FAIL: {reason}")
        return 1
    with open(CODEX_CI) as f:
        codex_ci = yaml.safe_load(f)
    reason = check_rehearsal(codex_ci, real)
    if reason is not None:
        print(f"FAIL: {reason}")
        return 1

    failures = []
    refused, allowed = graph_fixtures()
    for name, wf in refused:
        if check_graph(wf) is None:
            failures.append(f"the graph check accepted a fixture: {name}")
    if check_graph(allowed) is not None:
        failures.append("the graph check refused an allowed condition")
    for name, mutate in MUTANTS:
        wf = copy.deepcopy(real)
        mutate(wf)
        if wf == real:
            failures.append(f"a mutant changed nothing: {name}")
        elif refusal(wf) is None:
            failures.append(f"a mutant of release.yml was accepted: {name}")
    for name, mutate in PACKAGE_JOB_MUTANTS:
        wf = copy.deepcopy(real)
        mutate(wf)
        if wf == real:
            failures.append(f"a mutant changed nothing: {name}")
        elif refusal(wf) is None:
            failures.append(f"a mutant of release.yml was accepted: {name}")
    mac = desktop_mac()
    for name, mutate in MAC_MUTANTS:
        changed = copy.deepcopy(mac)
        mutate(changed)
        if changed == mac:
            failures.append(f"a mutant changed nothing: desktop-mac.yml, {name}")
        elif refusal(copy.deepcopy(real), changed) is None:
            failures.append(f"a mutant of desktop-mac.yml was accepted: {name}")
    for name, mutate in [
        ("no rehearsal", lambda c: c["jobs"].pop("release-rehearsal")),
        ("the rehearsal allowed to fail", lambda c: next(s for s in c["jobs"]["release-rehearsal"]["steps"] if "run" in s).update({"continue-on-error": True})),
        ("another GoReleaser", lambda c: next(s for s in c["jobs"]["release-rehearsal"]["steps"] if "goreleaser" in str(s.get("uses"))).update({"with": {"version": "latest", "install-only": True}})),
        ("the rehearsal job switched off", lambda c: c["jobs"]["release-rehearsal"].update({"if": False})),
        ("the rehearsal job allowed to fail", lambda c: c["jobs"]["release-rehearsal"].update({"continue-on-error": True})),
    ]:
        changed = copy.deepcopy(codex_ci)
        mutate(changed)
        if check_rehearsal(changed, real) is None:
            failures.append(f"a mutant of codex-ci.yml's rehearsal was accepted: {name}")
    for name, mutate in TEST_MUTANTS:
        wf = copy.deepcopy(test)
        mutate(wf)
        if wf == test:
            failures.append(f"a mutant changed nothing: test.yml, {name}")
        elif check_static(wf) is None:
            failures.append(f"a mutant of test.yml was accepted: {name}")
    for name, mutate in CI_BUILD_MUTANTS:
        mutated = copy.deepcopy((ci_workflows, ci_actions))
        mutate(*mutated)
        if mutated == (ci_workflows, ci_actions):
            failures.append(f"a mutant changed nothing: CI's image builds, {name}")
        elif check_ci_builds(*mutated) is None:
            failures.append(f"a mutant of CI's image builds was accepted: {name}")
    for name, mutate in GORELEASER_MUTANTS:
        config = copy.deepcopy(goreleaser)
        mutate(config)
        if check_goreleaser(config) is None:
            failures.append(f"a mutant of .goreleaser.yml was accepted: {name}")
    # The ignore check's positive control: a tracked source is not ignored.
    if check_ignored(["apps/codex/go.mod"]) is None:
        failures.append("the ignore check reports apps/codex/go.mod as ignored")
    for path, text in files.items():
        for name, mutant in [
            ("no ARG APT_REFRESH", text.replace("\nARG APT_REFRESH", "\n# ARG APT_REFRESH")),
            ("an upgrade that does not read it", text.replace("${APT_REFRESH}", "refresh")),
            ("an upgrade without the key's guard", text.replace("--update", "--of")),
            ("the ARG above the upgrade stage's FROM", arg_above_stage(text)),
        ]:
            if mutant == text:
                failures.append(f"a mutant changed nothing: {path}, {name}")
            elif check_apt_layers({**files, path: mutant}) is None:
                failures.append(f"a mutant of {path} was accepted: {name}")

    try:
        with open(VECTORS, "rb") as f:
            vector_file = strict_json(f.read())
    except (OSError, ValueError) as e:
        vector_file = None
        failures.append(f"the manifest vectors cannot be read: {e}")
    vectors = versions = file_mutants = 0
    if vector_file is not None:
        found, vectors, versions = vector_failures(vector_file)
        failures += found
        # Each rule that is not SEMVER, and each vector file that drops or
        # misfiles a vector, is told from the real ones.
        for name, pattern in RULE_MUTANTS:
            if not vector_failures(vector_file, re.compile(pattern))[0]:
                failures.append(f"the vectors accept a rule with {name}")
        mutants = vector_mutants(vector_file)
        file_mutants = len(mutants)
        for name, mutant in mutants:
            if mutant == vector_file:
                failures.append(f"a mutant changed nothing: the vector file, {name}")
            elif not vector_failures(mutant)[0]:
                failures.append(f"a mutant of the vector file was accepted: {name}")
    version = real_version()
    scaffold, pinned, (forms, planted, scaffold_accepted, scaffold_refused) = scaffold_failures(version)
    failures += scaffold
    helper, helper_versions = release_helper_failures()
    failures += helper
    failures += release_note_failures()
    found, cask_cases = cask_failures(version)
    failures += found
    found, installed_cases = installed_version_failures()
    failures += found
    found, machine_cases = installed_machine_failures()
    failures += found
    modes = 0
    if not scaffold:
        mode_failures, modes = manifest_mode_failures(pinned, version)
        failures += mode_failures

    for line in failures:
        print(f"FAIL: {line}")
    if failures:
        return 1
    print(
        f"tag pipeline ok: release.yml, test.yml's static job, .goreleaser.yml, the Dockerfiles, "
        f"the tag check run in {len(tag_cases())} cases, the Homebrew step on {scaffold_accepted} versions "
        f"and the scaffold pinned at {version} and at {scaffold_accepted} versions pass, release.sh in "
        f"{helper_versions} versions, its tag on a HEAD that declares the version, its proof, its tag of the proved commit "
        f"and its pushes pass, under {range_locale()}; "
        f"{len(refused)} fixtures, {len(MUTANTS) + len(PACKAGE_JOB_MUTANTS)} mutants of release.yml, "
        f"{len(MAC_MUTANTS)} of desktop-mac.yml, {len(TEST_MUTANTS)} of "
        f"test.yml, {len(CI_BUILD_MUTANTS)} of CI's image builds, {len(GORELEASER_MUTANTS)} of .goreleaser.yml, {len(SCAFFOLD_MUTANTS)} of "
        f"scaffold-tarball.sh, {len(RELEASE_SH_MUTANTS)} of release.sh, {len(RELEASE_NOTE_MUTANTS)} of "
        f"release-note.sh and {4 * len(files)} of the Dockerfiles, "
        f"{vectors} manifest vectors, {scaffold_refused} versions, {forms} scaffold argument forms and "
        f"{planted} planted composes refused; {versions} versions held to the rule, which "
        f"{len(RULE_MUTANTS)} other rules and {file_mutants} mutants of the vector file fail; "
        f"{modes} manifest-mode cases, {cask_cases} cases of the cask and the installers and "
        f"{installed_cases} of the installed cyfr's version and {machine_cases} of the installed executables' "
        f"architecture checked"
    )
    return 0


def main(argv):
    if "--installers" in argv:
        return installers_mode(argv)
    if argv:
        return manifest_mode(argv)
    try:
        return graph_mode()
    finally:
        for path in _SCRATCH:
            shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

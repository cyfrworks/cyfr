#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The tag pipeline's graph: .github/workflows/release.yml publishes nothing
# unless all six verification workflows passed and the tag names the
# version apps/prima/mix.exs declares, can neither be cancelled nor let a
# failure pass, builds both images for both platforms with the scan reading
# the loaded image and each image's upgrade layer refreshed on the UTC date
# (APT_REFRESH, read by both Dockerfiles), merges each image's two digests
# by exact name, attests the merge's printed digest and hands it to the
# CLI release, which pins the scaffold's compose to the merged digests,
# writes release.json, checks it and signs it before GoReleaser attaches
# both, and grants each job only what it needs. The build, and the
# publication test in test.yml's static job, first switch the runner's
# Docker daemon to the containerd image store, which alone can load an
# image carrying its attestation.
#
# The checks run on the real files, then on fixtures and on mutants of the
# real files, each of which must be refused, so a check that stops checking
# fails here. Beside reading files, they execute the tag check's step under
# bash against the real tree and a planted one, and scripts/
# scaffold-tarball.sh into temporary directories, and check the manifest
# rules against tests/fixtures/release_manifest.json's vectors. Needs
# PyYAML for this mode.
#
# The release job's own mode checks the manifest it wrote, without PyYAML:
# its shape by the vector file's rules, its version against the tag, its
# scaffold digest against the tarball's, its Caddy digest against the one
# docker-compose.yml pins, and the tarball's compose against its image
# digests.
#
# Usage: python3 -I tests/ci-release-graph.py
#        python3 -I tests/ci-release-graph.py --manifest FILE --version VERSION --scaffold TARBALL
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
# The CLI release's permissions at BASE, which it may narrow and never widen.
RELEASE_PERMISSIONS = {"contents": "write", "id-token": "write", "attestations": "write"}
IMAGES = {"cyfr": "Dockerfile", "cyfr-locus": "Dockerfile.locus"}
PUSH_BY_DIGEST = (
    "type=image,name=${{ env.REGISTRY }}/${{ matrix.image }},"
    "push-by-digest=true,name-canonical=true,push=true"
)
LOAD = "type=docker,name="
# The upgrade layer's cache key: one build argument, the output of a step
# that writes the UTC date on every run, so each image's upgrade refreshes
# daily (Dockerfile and Dockerfile.locus read it as ARG APT_REFRESH).
APT_ARG = re.compile(r"^APT_REFRESH=\$\{\{ steps\.([\w-]+)\.outputs\.([\w-]+) \}\}$")
OUTPUT_LINE = re.compile(r'^echo "[\w-]+=[^"]*" >> "\$GITHUB_OUTPUT"$')
APT_UPGRADE = re.compile(r"^RUN .*\$\{APT_REFRESH\}.*apt-get upgrade", re.MULTILINE)
# The switch to the containerd image store. It restarts the daemon, so it
# precedes buildx's builder and every build.
STORE_SWITCH = "sudo scripts/ci/containerd-image-store.sh"
PUBLISH_TEST = "bash tests/ci-publish-test.sh"
# The tag check: a job of its own, its checkout and the one comparison of
# $GITHUB_REF_NAME with the version apps/prima/mix.exs declares.
TAG_JOB = "version"
TAG_COMPARISON = '"$GITHUB_REF_NAME" != "${declared[0]}"'
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
SCAFFOLD_RUN = """set -euo pipefail
cyfr=$(cat "$RUNNER_TEMP/merged/cyfr/digest")
locus=$(cat "$RUNNER_TEMP/merged/cyfr-locus/digest")
bash scripts/scaffold-tarball.sh apps/codex/cyfr-scaffold.tar.gz "$GITHUB_REF_NAME" "$cyfr" "$locus"
"""
MANIFEST_OUT = '> "$RUNNER_TEMP/release/release.json"\n'
VALIDATE_RUN = (
    'python3 -I tests/ci-release-graph.py --manifest "$RUNNER_TEMP/release/release.json" '
    '--version "$GITHUB_REF_NAME" --scaffold apps/codex/cyfr-scaffold.tar.gz'
)
SIGN_RUN = (
    'cosign sign-blob --yes --new-bundle-format --bundle "$RUNNER_TEMP/release/release.json.sigstore.json" '
    '"$RUNNER_TEMP/release/release.json"'
)
MANIFEST_DIR_ENV = {"RELEASE_MANIFEST_DIR": "${{ runner.temp }}/release"}
# .goreleaser.yml's release attaches the scaffold from its workdir,
# apps/codex, and the manifest and its bundle from RELEASE_MANIFEST_DIR
# alone: an unset variable or a missing file fails the release.
SCAFFOLD_GLOB = "cyfr-scaffold.tar.gz"
# GoReleaser's signature over checksums.txt, as the protobuf bundle.
CHECKSUM_SIGN_ARGS = ["sign-blob", "--new-bundle-format", "--bundle=${signature}", "${artifact}", "--yes"]
MANIFEST_GLOBS = [
    "{{ .Env.RELEASE_MANIFEST_DIR }}/release.json",
    "{{ .Env.RELEASE_MANIFEST_DIR }}/release.json.sigstore.json",
]
# GoReleaser refuses a dirty tree, so what the job writes into the
# checkout before it runs is ignored by git.
CHECKOUT_WRITES = ["apps/codex/" + SCAFFOLD_GLOB]

DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
IMAGE_LINE = re.compile(r"^(\s*image:\s*)(\S+)\s*$")
CYFR_REPO = "ghcr.io/cyfrworks/cyfr"
LOCUS_REPO = "ghcr.io/cyfrworks/cyfr-locus"


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
    return None, name


def check_apt_refresh(job, inputs):
    args = str(inputs.get("build-args", "")).strip()
    match = APT_ARG.match(args)
    if not match:
        return f"the build's build-args are {args!r}, not APT_REFRESH from a step's output"
    step_id, output = match.groups()
    dated = f'echo "{output}=$(date -u +%F)" >> "$GITHUB_OUTPUT"'
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
    # Every line before the dated one writes an output and nothing else, so
    # nothing in the step can end it before the date is written.
    lines = [line.strip() for line in str(step.get("run", "")).splitlines() if line.strip()]
    if dated not in lines:
        return f"the step {step_id} does not write {output} as the UTC date"
    at_date = lines.index(dated)
    for line in lines[:at_date]:
        if not OUTPUT_LINE.match(line):
            return f"the step {step_id} runs {line!r} before it writes the date"
    # A later write of the same output would replace the date.
    for line in lines[at_date + 1 :]:
        if re.search(rf"(?<![\w-]){re.escape(output)}=", line):
            return f"the step {step_id} writes {output} again after the date: {line!r}"
    return None


# The ARG must be declared in the upgrade layer's own stage, between its
# FROM and the RUN: an ARG above the FROM, or in another stage, leaves
# ${APT_REFRESH} empty there, and the layer is served from cache forever.
def check_apt_layers(dockerfiles):
    for path, text in dockerfiles.items():
        layer = APT_UPGRADE.search(text)
        if layer is None:
            return f"{path} has no apt-get upgrade layer that reads ${{APT_REFRESH}}"
        stage = [m.end() for m in re.finditer(r"^FROM\b.*$", text[: layer.start()], re.MULTILINE)]
        if not stage or not re.search(r"^ARG APT_REFRESH\b", text[stage[-1] : layer.start()], re.MULTILINE):
            return f"{path}'s apt-get upgrade layer does not read an ARG APT_REFRESH of its own stage"
    return None


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


def check_permissions(wf, build, merge):
    jobs = wf["jobs"]
    if wf.get("permissions") != {"contents": "read"}:
        return f"the workflow's default permissions are {wf.get('permissions')}"
    if jobs[build].get("permissions") != {"contents": "read", "packages": "write"}:
        return f"the build's permissions are {jobs[build].get('permissions')}"
    want = {"contents": "read", "packages": "write", "id-token": "write", "attestations": "write"}
    if jobs[merge].get("permissions") != want:
        return f"the merge's permissions are {jobs[merge].get('permissions')}"
    release = [k for k, job in jobs.items() if steps_using(job, "goreleaser/goreleaser-action")]
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
    major, minor, patch = version.split(".")
    return f"{major}.{minor}.{int(patch) + 1}"


# Executions of one step's script, by (script, tree, tag): mutants that
# leave the step alone reuse the real step's results.
_TAG_RUNS = {}
_SCRATCH = []


def scratch():
    if not _SCRATCH:
        _SCRATCH.append(tempfile.mkdtemp(prefix="ci-release-graph."))
    return _SCRATCH[0]


def run_tag_step(script, tree, tag):
    key = (script, tree, tag)
    if key not in _TAG_RUNS:
        path = os.path.join(scratch(), "tag-step-%d.sh" % len(_TAG_RUNS))
        with open(path, "w") as f:
            f.write(script)
        # As the runner runs a step: bash -e with pipefail, its script a
        # file, the working directory the checkout, and nothing in the
        # environment but PATH and the tag.
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C", "GITHUB_REF_NAME": tag}
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
    """(description, tree, tag, expected) cases the comparison is run on."""
    with open(os.path.join(ROOT, MIX_EXS)) as f:
        text = f.read()
    found = declared_versions(text)
    if len(found) != 1 or not SEMVER.fullmatch(found[0]):
        raise SystemExit(f"FAIL: {MIX_EXS} declares {found}, not one MAJOR.MINOR.PATCH")
    real = found[0]
    other = other_version(real)
    line = re.search(r'^\s*version:\s*"[^"]*",?\s*$', text, re.MULTILINE).group(0)
    moved = planted_mix("other", text.replace(line, line.replace(real, other), 1))
    twice = planted_mix("twice", text.replace(line, line + "\n" + line.replace(real, other), 1))
    none = planted_mix("none", text.replace(line + "\n", "", 1))
    return [
        ("the declared version", ROOT, real, True),
        ("another version", ROOT, other, False),
        ("the declared version with a v", ROOT, "v" + real, False),
        ("the declared version with a suffix", ROOT, real + "-rc.1", False),
        ("an empty tag", ROOT, "", False),
        ("the real tag on a tree that declares another version", moved, real, False),
        ("the tag a tree that declares another version names", moved, other, True),
        ("a tree that declares two versions", twice, real, False),
        ("a tree that declares none", none, real, False),
    ]


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
        len(steps) != 2
        or str(steps[0].get("uses", "")).split("@")[0] != "actions/checkout"
        or set(steps[0]) != {"uses"}
    ):
        return "the tag check's steps are not the checkout of the tag and the comparison"
    step = steps[1]
    if set(step) - {"name", "run"} or "run" not in step:
        return f"the tag check's comparison carries {sorted(set(step) - {'name', 'run'})}"
    script = str(step["run"])
    if "$GITHUB_REF_NAME" not in script or MIX_EXS not in script:
        return f"the tag check does not compare $GITHUB_REF_NAME with {MIX_EXS}"
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
        len(downloads) != 2
        or got != MERGED_DOWNLOADS
        or any(
            set(steps[i]) - {"name", "uses", "with"} or set(steps[i].get("with", {})) != {"name", "path"}
            for i in downloads
        )
    ):
        return "the CLI release does not download the two merged digests by exact name"

    def only(predicate, what):
        at = [i for i, s in enumerate(steps) if predicate(s)]
        return (at[0], None) if len(at) == 1 else (None, f"the CLI release does not {what} once")

    order = []
    for predicate, what in [
        (lambda s: "scaffold-tarball.sh" in str(s.get("run", "")), "build the scaffold"),
        (lambda s: MANIFEST_OUT in str(s.get("run", "")), "write release.json"),
        (lambda s: "--manifest" in str(s.get("run", "")), "validate release.json"),
        (lambda s: "sign-blob" in str(s.get("run", "")), "sign release.json"),
        (lambda s: str(s.get("uses", "")).split("@")[0] == "goreleaser/goreleaser-action", "run GoReleaser"),
    ]:
        at, reason = only(predicate, what)
        if reason:
            return reason
        order.append(at)
    scaffold, manifest, validate, sign, goreleaser = order
    for at, want in [(scaffold, SCAFFOLD_RUN), (validate, VALIDATE_RUN), (sign, SIGN_RUN)]:
        if run_lines(steps[at]) != run_lines({"run": want}):
            return f"the CLI release runs {steps[at].get('run')!r}, not {want!r}"
    for at in (scaffold, manifest, validate, sign):
        if set(steps[at]) - {"name", "run"}:
            extra = sorted(set(steps[at]) - {"name", "run"})
            return f"the CLI release's step {steps[at].get('name')!r} carries {extra}"
    installer = step_index(job, lambda s: str(s.get("uses", "")).split("@")[0] == "sigstore/cosign-installer")
    if installer is None or installer > sign:
        return "cosign is not installed before the manifest is signed"
    if [max(downloads)] + order != sorted([max(downloads)] + order):
        return (
            "the CLI release does not download the digests, build the scaffold, write, validate "
            "and sign release.json, then run GoReleaser, in that order"
        )
    if steps[goreleaser].get("with", {}).get("workdir") != "apps/codex":
        return "GoReleaser does not run in apps/codex"
    env = steps[goreleaser].get("env") or {}
    if {k: env.get(k) for k in MANIFEST_DIR_ENV} != MANIFEST_DIR_ENV:
        return f"GoReleaser's RELEASE_MANIFEST_DIR is {env.get('RELEASE_MANIFEST_DIR')!r}, not {MANIFEST_DIR_ENV}"
    return None


def check_goreleaser(config):
    globs = [str(e.get("glob")) for e in (config.get("release") or {}).get("extra_files") or []]
    if SCAFFOLD_GLOB not in globs:
        return f".goreleaser.yml's release does not attach {SCAFFOLD_GLOB}"
    manifest = sorted(g for g in globs if "release.json" in g)
    if manifest != sorted(MANIFEST_GLOBS):
        return f".goreleaser.yml's release attaches {manifest} for the manifest, not exactly {MANIFEST_GLOBS}"
    # checksums.txt is signed into the protobuf bundle sigstore-go reads:
    # cosign 2 writes its legacy bundle without --new-bundle-format, which
    # `cyfr init` and `cyfr update` refuse.
    signs = config.get("signs") or []
    if [(s.get("cmd"), s.get("artifacts"), s.get("signature"), s.get("args")) for s in signs] != [
        ("cosign", "checksum", "${artifact}.sigstore.json", CHECKSUM_SIGN_ARGS)
    ]:
        return f".goreleaser.yml's signs are {signs}, not cosign over checksums.txt with {CHECKSUM_SIGN_ARGS}"
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


def validate_manifest(obj):
    """None when obj is a release manifest, else the reason it is not:
    exactly version, images and scaffold; images exactly cyfr, cyfr_locus
    and caddy; every digest sha256:<64 lowercase hex>; the version a bare
    MAJOR.MINOR.PATCH."""
    if not isinstance(obj, dict):
        return f"the manifest is {type(obj).__name__}, not an object"
    if set(obj) != {"version", "images", "scaffold"}:
        return f"the manifest's keys are {sorted(obj)}, not images, scaffold and version"
    version = obj["version"]
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        return f"the version {version!r} is not a bare MAJOR.MINOR.PATCH"
    images = obj["images"]
    if not isinstance(images, dict) or set(images) != {"cyfr", "cyfr_locus", "caddy"}:
        return f"the images are {images!r}, not exactly caddy, cyfr and cyfr_locus"
    for name, digest in [*sorted(images.items()), ("scaffold", obj["scaffold"])]:
        if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
            return f"{name}'s digest {digest!r} is not sha256:<64 lowercase hex>"
    return None


def check_vectors(path=VECTORS):
    """The vector file's valid manifest accepted and every refused one refused."""
    with open(path, "rb") as f:
        vectors = strict_json(f.read())
    failures = []
    reason = validate_manifest(vectors.get("valid"))
    if reason:
        failures.append(f"the vector file's valid manifest is refused: {reason}")
    refused = vectors.get("refused")
    if not isinstance(refused, list) or not refused:
        return [f"{path} has no refused manifests"], 0
    for case in refused:
        if not isinstance(case, dict) or set(case) != {"name", "manifest"}:
            failures.append(f"a refused vector is not {{name, manifest}}: {case!r}")
        elif validate_manifest(case["manifest"]) is None:
            failures.append(f"a refused manifest vector was accepted: {case['name']}")
    return failures, len(refused)


def image_ref(line):
    match = IMAGE_LINE.match(line)
    return (match.group(1), match.group(2)) if match else (None, None)


def repository(ref):
    name = ref.split("@", 1)[0]
    head, sep, tail = name.rpartition(":")
    return head if sep and "/" not in tail else name


def compose_caddy(text):
    digests = []
    for line in text.splitlines():
        _, ref = image_ref(line)
        if ref is not None and repository(ref) == "caddy":
            digests.append(ref.split("@", 1)[1] if "@" in ref else None)
    if len(digests) < 1 or len(set(digests)) != 1 or not DIGEST.fullmatch(digests[0] or ""):
        return None, f"docker-compose.yml's caddy images name {digests}, not one digest"
    return digests[0], None


def check_scaffold_compose(text, manifest):
    """The scaffold's compose names exactly the manifest's images: every
    cyfr and cyfr-locus image at the release's version and digest, Caddy
    at its digest, and no other image."""
    version, images = manifest["version"], manifest["images"]
    want = {
        CYFR_REPO: f"{CYFR_REPO}:{version}@{images['cyfr']}",
        LOCUS_REPO: f"{LOCUS_REPO}:{version}@{images['cyfr_locus']}",
    }
    seen = {CYFR_REPO: 0, LOCUS_REPO: 0, "caddy": 0}
    for line in text.splitlines():
        if not re.match(r"^\s*image:", line):
            continue
        _, ref = image_ref(line)
        repo = repository(ref) if ref else None
        if repo in want and ref != want[repo]:
            return f"the scaffold's compose names {ref}, not {want[repo]}"
        if repo == "caddy" and not ref.endswith("@" + images["caddy"]):
            return f"the scaffold's compose names {ref}, not caddy at {images['caddy']}"
        if repo not in seen:
            return f"the scaffold's compose names {line.strip()!r}, which the manifest does not cover"
        seen[repo] += 1
    if 0 in seen.values():
        return f"the scaffold's compose names images {seen}, not each of cyfr, cyfr-locus and caddy"
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
        return f"the tag {version!r} is not a bare MAJOR.MINOR.PATCH"
    if manifest["version"] != version:
        return f"release.json is release {manifest['version']}, the tag {version}"
    with open(scaffold, "rb") as f:
        digest = "sha256:" + hashlib.sha256(f.read()).hexdigest()
    if manifest["scaffold"] != digest:
        return f"release.json's scaffold is {manifest['scaffold']}, the tarball's digest {digest}"
    caddy, reason = compose_caddy(compose_text)
    if reason:
        return reason
    if manifest["images"]["caddy"] != caddy:
        return f"release.json's caddy is {manifest['images']['caddy']}, docker-compose.yml's {caddy}"
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


# --- the scaffold pinned to the release's images, run for real ---

FAKE_CYFR = "sha256:" + hashlib.sha256(b"cyfr").hexdigest()
FAKE_LOCUS = "sha256:" + hashlib.sha256(b"cyfr-locus").hexdigest()


def run_scaffold(root, args):
    result = subprocess.run(
        ["bash", os.path.join(root, "scripts", "scaffold-tarball.sh"), *args],
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
        ("a version without digests", [o, version]),
        ("one digest", [o, version, a]),
        ("five arguments", [o, version, a, b, b]),
        ("a v-prefixed version", [o, "v" + version, a, b]),
        ("a version with a suffix", [o, version + "-rc.1", a, b]),
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
    extra = "\n  extra:\n    image: %s\n"
    return [
        ("an unpinned caddy", text.replace(caddy.group(0), caddy.group(1)) if caddy else text),
        ("another unpinned image", text + extra % "postgres:18"),
        ("a repository cyfr-locus is a prefix of", text + extra % (LOCUS_REPO + "-extra:latest")),
        ("no cyfr image", re.sub(r"ghcr\.io/cyfrworks/cyfr:\S+", LOCUS_REPO + ":latest", text)),
        ("no cyfr-locus image", re.sub(r"ghcr\.io/cyfrworks/cyfr-locus:\S+", CYFR_REPO + ":latest", text)),
    ]


def scaffold_failures(version):
    """The scaffold pinned on the real tree, its refused argument forms and
    its refusal of planted composes. Returns (failures, pinned tarball, counts)."""
    failures = []
    out = os.path.join(scratch(), "scaffold")
    os.makedirs(out)
    reason = check_scaffold(ROOT, out, version)
    if reason:
        failures.append(reason)
    target, cases = refused_scaffold_args(out, version)
    for name, args in cases:
        status, output = run_scaffold(ROOT, args)
        if status != 64 or os.path.exists(target):
            failures.append(f"scaffold-tarball.sh exits {status} on {name}, not 64 with nothing written")
    with open(COMPOSE) as f:
        text = f.read()
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
    return failures, os.path.join(out, "pinned.tar.gz"), (len(cases), len(planted))


def manifest_mode_failures(pinned, version):
    """The workflow's --manifest mode, run as the workflow runs it, on
    manifests written for the pinned scaffold."""
    with open(COMPOSE) as f:
        caddy, reason = compose_caddy(f.read())
    if reason:
        return [reason], 0
    with open(pinned, "rb") as f:
        scaffold = "sha256:" + hashlib.sha256(f.read()).hexdigest()
    good = {
        "version": version,
        "images": {"cyfr": FAKE_CYFR, "cyfr_locus": FAKE_LOCUS, "caddy": caddy},
        "scaffold": scaffold,
    }
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
    cases = [
        ("the manifest of the release", good_bytes, version, 0),
        ("another tag", good_bytes, other, 1),
        ("a v-prefixed tag", good_bytes, "v" + version, 1),
        ("another release's manifest", with_(version=other), other, 1),
        ("another scaffold digest", with_(scaffold=wrong), version, 1),
        ("another caddy digest", with_(caddy=wrong), version, 1),
        ("another cyfr digest", with_(cyfr=wrong), version, 1),
        ("the image digests swapped", with_(cyfr=FAKE_LOCUS, cyfr_locus=FAKE_CYFR), version, 1),
        ("an extra key", json.dumps({**good, "latest": True}).encode(), version, 1),
        ("a duplicate key", good_bytes[:-1] + b', "version": "' + version.encode() + b'"}', version, 1),
        ("trailing data", good_bytes + b"{}", version, 1),
    ]
    failures = []
    path = os.path.join(scratch(), "release.json")
    for name, data, tag, want in cases:
        with open(path, "wb") as f:
            f.write(data)
        result = subprocess.run(
            [sys.executable, "-I", os.path.abspath(__file__)]
            + ["--manifest", path, "--version", tag, "--scaffold", pinned],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
        if result.returncode != want:
            failures.append(
                f"the manifest mode exits {result.returncode} on {name}, not {want}: "
                f"{result.stdout.decode(errors='replace').strip()[-300:]}"
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


def check_shape(wf):
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
    release = next(k for k, job in wf["jobs"].items() if steps_using(job, "goreleaser/goreleaser-action"))
    return (
        check_tag(wf, build, release)
        or check_merged_digest(wf, merge)
        or check_release_manifest(wf, merge, release)
    )


def refusal(wf):
    return check_graph(wf) or check_shape(wf)


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
    step["run"] = step["run"].replace("$(date -u +%F)", "2026-10-15")


def apt_refresh_skipped(wf):
    step_named(wf, "images", "Extract metadata")["if"] = "matrix.image == 'cyfr-locus'"


def apt_refresh_after_build(wf):
    steps = wf["jobs"]["images"]["steps"]
    meta = step_named(wf, "images", "Extract metadata")
    steps.remove(meta)
    steps.append(meta)


def apt_refresh_exits_first(wf):
    step = step_named(wf, "images", "Extract metadata")
    step["run"] = step["run"].replace('echo "apt-refresh=', 'exit 0\necho "apt-refresh=', 1)


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


def tag_without_v(wf):
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


GORELEASER_MUTANTS = [
    ("release.json not attached", drop_glob(MANIFEST_GLOBS[0])),
    ("release.json's bundle not attached", drop_glob(MANIFEST_GLOBS[1])),
    ("the scaffold not attached", drop_glob(SCAFFOLD_GLOB)),
    ("release.json attached from the workdir", replace_glob(MANIFEST_GLOBS[0], "release.json")),
    ("the bundle attached by a wildcard", replace_glob(MANIFEST_GLOBS[1], "{{ .Env.RELEASE_MANIFEST_DIR }}/*")),
    ("a second release.json attached", lambda c: c["release"]["extra_files"].append({"glob": "dist/release.json"})),
    ("checksums.txt signed into the legacy bundle", sign_args([a for a in CHECKSUM_SIGN_ARGS if a != "--new-bundle-format"])),
    ("checksums.txt signed without a bundle", sign_args(["sign-blob", "--new-bundle-format", "${artifact}", "--yes"])),
]


MUTANTS = [
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
    ("an APT_REFRESH that is not the date", apt_refresh_fixed),
    ("an APT_REFRESH written for one image only", apt_refresh_for_locus_only),
    ("an APT_REFRESH step with an if:", apt_refresh_skipped),
    ("an APT_REFRESH step after the build", apt_refresh_after_build),
    ("an exit before the APT_REFRESH date", apt_refresh_exits_first),
    ("the APT_REFRESH date overwritten after it", apt_refresh_overwritten),
    ("a scan whose findings never fail it", scan_never_fails),
    ("|| : after the scanned-is-pushed check", comparison_ignored),
    ("packages: write on the CLI release", release_widened),
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
    ("a v-prefixed tag accepted", tag_without_v),
    ("a tag mismatch that exits 0", tag_mismatch_exits_0),
    ("the version read from another file", tag_reads_another_file),
    ("GITHUB_REF_NAME fixed on the tag comparison", tag_env_fixed),
    ("the tag check checking out main", tag_checkout_main),
    ("a step added to the tag check", tag_job_extra_step),
    ("packages: write on the tag check", tag_job_widened),
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
    ("the manifest's bundle under another name", bundle_renamed),
    ("GoReleaser before the manifest's signature", move_release_step(is_goreleaser, is_sign)),
    ("the manifest validated inside the checkout", manifest_in_checkout),
    ("no RELEASE_MANIFEST_DIR on GoReleaser", no_manifest_dir_env),
    ("a RELEASE_MANIFEST_DIR that is not the manifest's", manifest_dir_elsewhere),
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
    with open(GORELEASER) as f:
        goreleaser = yaml.safe_load(f)
    reason = check_goreleaser(goreleaser) or check_ignored(CHECKOUT_WRITES)
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
    for name, mutate in TEST_MUTANTS:
        wf = copy.deepcopy(test)
        mutate(wf)
        if wf == test:
            failures.append(f"a mutant changed nothing: test.yml, {name}")
        elif check_static(wf) is None:
            failures.append(f"a mutant of test.yml was accepted: {name}")
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
            ("the ARG above the upgrade stage's FROM", arg_above_stage(text)),
        ]:
            if mutant == text:
                failures.append(f"a mutant changed nothing: {path}, {name}")
            elif check_apt_layers({**files, path: mutant}) is None:
                failures.append(f"a mutant of {path} was accepted: {name}")

    try:
        vector_failures, vectors = check_vectors()
    except (OSError, ValueError) as e:
        vector_failures, vectors = [f"the manifest vectors cannot be read: {e}"], 0
    failures += vector_failures
    version = real_version()
    scaffold, pinned, (forms, planted) = scaffold_failures(version)
    failures += scaffold
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
        f"the tag check run in {len(tag_cases())} cases and the pinned scaffold pass; "
        f"{len(refused)} fixtures, {len(MUTANTS)} mutants of release.yml, {len(TEST_MUTANTS)} of "
        f"test.yml, {len(GORELEASER_MUTANTS)} of .goreleaser.yml and {3 * len(files)} of the Dockerfiles, "
        f"{vectors} manifest vectors, {forms} scaffold argument forms and {planted} planted composes refused; "
        f"{modes} manifest-mode cases checked"
    )
    return 0


def main(argv):
    if argv:
        return manifest_mode(argv)
    try:
        return graph_mode()
    finally:
        for path in _SCRATCH:
            shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

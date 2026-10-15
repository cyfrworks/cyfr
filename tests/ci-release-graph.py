#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The tag pipeline's graph: .github/workflows/release.yml publishes nothing
# unless all six verification workflows passed, can neither be cancelled
# nor let a failure pass, builds both images for both platforms with the
# scan reading the loaded image and each image's upgrade layer refreshed on
# the UTC date (APT_REFRESH, read by both Dockerfiles), merges each image's
# two digests by exact name and attests the merge's printed digest, and
# grants each job only what it needs.
#
# The checks run on the real file, then on fixtures and on mutants of the
# real file, each of which must be refused, so a check that stops checking
# fails here. Needs PyYAML; reads files only.
#
# Usage: python3 -I tests/ci-release-graph.py
import copy
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASE = os.path.join(ROOT, ".github", "workflows", "release.yml")

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

    for j in jobs:
        if j in verify:
            continue
        if not verify <= ancestors(j):
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
    for line in lines[: lines.index(dated)]:
        if not OUTPUT_LINE.match(line):
            return f"the step {step_id} runs {line!r} before it writes the date"
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
    return check_permissions(wf, build, merge)


def refusal(wf):
    return check_graph(wf) or check_shape(wf)


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
    ("a scan whose findings never fail it", scan_never_fails),
    ("|| : after the scanned-is-pushed check", comparison_ignored),
    ("packages: write on the CLI release", release_widened),
]


def main():
    with open(RELEASE) as f:
        real = yaml.safe_load(f)
    reason = refusal(real)
    if reason is not None:
        print(f"FAIL: release.yml: {reason}")
        return 1
    files = dockerfiles()
    reason = check_apt_layers(files)
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

    for line in failures:
        print(f"FAIL: {line}")
    if failures:
        return 1
    print(
        f"tag pipeline ok: release.yml and its Dockerfiles pass; {len(refused)} fixtures, "
        f"{len(MUTANTS)} mutants of release.yml and {3 * len(files)} of the Dockerfiles refused"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

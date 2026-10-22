# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""One job of a GitHub workflow as the commit gate runs it on this host.

    python3 -I scripts/lib/workflow_plan.py ROOT WORKFLOW JOB PLAN_DIR TEMP_DIR \
        [KEY=VALUE]... [--except STEP]... [--only STEP] [--env NAME=VALUE]...

KEY=VALUE picks the job's matrix entry (each key the matrix has, its value
one the matrix lists; an `include` entry is picked by the keys given).
`--except STEP` leaves a step out by name and `--only STEP` keeps one step
alone; each name must be one of the job's steps. `--env` adds a variable
to every step after the workflow's own, for what this host supplies in
place of a runner (a build path, a tool directory).

Writes PLAN_DIR/plan, one line a step in the job's order:

    SLUG<TAB>RUNS<TAB>DEADLINE<TAB>KIND<TAB>NAME

and PLAN_DIR/SLUG.sh for every step that runs. RUNS says when the step
runs, from its `if:` with the job's earlier steps passed (`ok`), failed
(`failed`), either (`always`) or never (`never`), the condition evaluated
on the matrix entry. DEADLINE is the job's `timeout-minutes` in seconds.
KIND is `run` (the step's script), `trivy` (aquasecurity/trivy-action as
the trivy command line it runs), `build` (docker/build-push-action as
`docker build`, under --only), `built` (the same step in a whole job: the
image the gate built is checked present; for both, PLAN_DIR/SLUG.tags
lists the step's tags), `artifact` (actions/upload-
artifact, its files copied under TEMP_DIR's parent's artifacts directory)
`setup` (checkout, toolchain setup, caches, downloads and `mix
deps.get`, which this host's checkout already holds: nothing runs), or `-`
for a step that never runs here. TEMP_DIR is the job's
RUNNER_TEMP. A `run` step's script is its `run:` text after a preamble
that leaves the caller's Mix and database selection out, exports the
workflow's, the job's and the step's env (then --env), sets GITHUB_* and
RUNNER_TEMP as a runner does, and enters its working directory. Its one
local substitution: the line that loads the Locus image a download step
fetched becomes a check that the image the gate built is there.

A construct the plan cannot run as CI does fails it, naming the step:
an expression beyond the matrix, runner.temp, github.workspace, the status
functions, contains(), ==, !=, !, && and || (and, in a build's
build-args, a step's output), an unknown action or `with:` input, a
`shell:` other than bash, continue-on-error, a job container or services,
or a step that writes GITHUB_ENV or GITHUB_PATH.
"""

import os
import re
import shlex
import sys

import yaml

# A step whose whole script is one of these fetches what this checkout
# already holds, so it is setup too.
SETUP_RUNS = {"mix deps.get"}
SETUP_ACTIONS = {
    "actions/checkout", "actions/setup-go", "actions/setup-node", "./.github/actions/setup-elixir",
    "actions/cache", "actions/download-artifact", "docker/setup-buildx-action",
}
# The job fetched the image the gate built from the tree; the line that
# loads the fetched copy is the one line the plan replaces.
LOAD_LINE = 'zstd -dc "$RUNNER_TEMP/locus-image/cyfr-locus.tar.zst" | docker load'
LOAD_CHECK = 'docker image inspect --format "the gate built cyfr-locus:ci as {{.Id}}" cyfr-locus:ci'
TRIVY_INPUTS = {"version", "scan-type", "scan-ref", "image-ref", "scanners", "format", "exit-code",
                "severity", "ignore-unfixed", "trivyignores"}
BUILD_INPUTS = {"context", "file", "build-args", "load", "tags", "cache-from", "cache-to"}
UPLOAD_INPUTS = {"name", "path", "retention-days", "if-no-files-found", "compression-level", "overwrite"}
# The caller's selections a runner never has: a step's own come from the
# workflow alone.
UNSET = ["MIX_ENV", "MIX_BUILD_PATH", "MIX_TEST_PARTITION", "CYFR_DATABASE", "CYFR_DATABASE_URL",
         "CYFR_CLUSTER_DATABASE_URL"]


class Refused(Exception):
    pass


# --- expressions --------------------------------------------------------------

TOKEN = re.compile(r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<num>\d+)|(?P<op>==|!=|&&|\|\||!|\(|\)|,)"
                   r"|(?P<id>[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*))")
STATUS = {"success", "failure", "always", "cancelled"}


def tokens(text):
    out, pos = [], 0
    text = text.strip()
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m or m.end() == pos:
            raise Refused(f"the expression {text!r} holds what the plan cannot read at {text[pos:]!r}")
        pos = m.end()
        kind = m.lastgroup
        out.append((kind, m.group(kind)))
    return out


def truthy(v):
    return v not in (None, False, "", 0)


def text_of(v):
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    return str(v)


class Expr:
    """GitHub's expression grammar, as far as the jobs the gate runs use it."""

    def __init__(self, text, ctx, failed=False):
        self.toks, self.i, self.ctx, self.failed, self.text = tokens(text), 0, ctx, failed, text

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def take(self, value=None):
        tok = self.peek()
        if tok[0] is None or (value is not None and tok[1] != value):
            raise Refused(f"the expression {self.text!r} is not one the plan reads")
        self.i += 1
        return tok

    def value(self):
        v = self.disjunction()
        if self.i != len(self.toks):
            raise Refused(f"the expression {self.text!r} is not one the plan reads")
        return v

    def disjunction(self):
        v = self.conjunction()
        while self.peek() == ("op", "||"):
            self.take()
            r = self.conjunction()
            v = v if truthy(v) else r
        return v

    def conjunction(self):
        v = self.comparison()
        while self.peek() == ("op", "&&"):
            self.take()
            r = self.comparison()
            v = r if truthy(v) else v
        return v

    def comparison(self):
        v = self.unary()
        while self.peek() in (("op", "=="), ("op", "!=")):
            op = self.take()[1]
            r = self.unary()
            same = text_of(v).lower() == text_of(r).lower()
            v = same if op == "==" else not same
        return v

    def unary(self):
        if self.peek() == ("op", "!"):
            self.take()
            return not truthy(self.unary())
        return self.primary()

    def primary(self):
        kind, tok = self.take()
        if kind == "str":
            return tok[1:-1].replace("''", "'")
        if kind == "num":
            return int(tok)
        if (kind, tok) == ("op", "("):
            v = self.disjunction()
            self.take(")")
            return v
        if kind != "id":
            raise Refused(f"the expression {self.text!r} is not one the plan reads")
        if tok in ("true", "false"):
            return tok == "true"
        if self.peek() == ("op", "("):
            self.take()
            args = []
            if self.peek() != ("op", ")"):
                args.append(self.disjunction())
                while self.peek() == ("op", ","):
                    self.take()
                    args.append(self.disjunction())
            self.take(")")
            return self.call(tok, args)
        return self.lookup(tok)

    def call(self, name, args):
        if name in STATUS and not args:
            return {"success": not self.failed, "failure": self.failed, "always": True, "cancelled": False}[name]
        if name == "contains" and len(args) == 2:
            hay, needle = args
            if isinstance(hay, list):
                return any(text_of(x).lower() == text_of(needle).lower() for x in hay)
            return text_of(needle).lower() in text_of(hay).lower()
        raise Refused(f"the expression {self.text!r} calls {name}(), which the plan does not run")

    def lookup(self, name):
        if name in self.ctx:
            return self.ctx[name]
        if name.startswith("matrix.") and "matrix" in self.ctx:
            key = name[len("matrix."):]
            if key in self.ctx["matrix"]:
                return self.ctx["matrix"][key]
        raise Refused(f"the expression {self.text!r} reads {name}, which the plan does not supply")


def evaluate(text, ctx, failed=False):
    return Expr(text, ctx, failed).value()


INLINE = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def substitute(text, ctx):
    """A value with each `${{ expression }}` in it replaced by its text."""
    return INLINE.sub(lambda m: text_of(evaluate(m.group(1), ctx)), str(text))


def runs(cond, ctx):
    """When a step runs: ok, failed, always or never."""
    if cond is None or str(cond).strip() == "":
        return "ok"
    text = text_of(cond).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", text, re.S)
    text = (m.group(1) if m else text).strip()
    named = any(kind == "id" and tok in STATUS for kind, tok in tokens(text))
    if not named:
        text = f"success() && ({text})"
    when_ok, when_failed = truthy(evaluate(text, ctx, False)), truthy(evaluate(text, ctx, True))
    return {(True, True): "always", (True, False): "ok", (False, True): "failed", (False, False): "never"}[
        (when_ok, when_failed)]


# --- the plan -----------------------------------------------------------------

def matrix_entry(job, picks):
    strategy = job.get("strategy") or {}
    matrix = strategy.get("matrix")
    if matrix is None:
        if picks:
            raise Refused(f"the job has no matrix, and {picks} picks an entry of one")
        return {}
    if isinstance(matrix, str):
        raise Refused("the job's matrix is an expression")
    if "exclude" in matrix:
        raise Refused("the job's matrix excludes entries, which the plan does not read")
    axes = {k: v for k, v in matrix.items() if k != "include"}
    entry = {}
    for k, values in axes.items():
        if k not in picks:
            raise Refused(f"the job's matrix has the key {k}, which no KEY=VALUE picks")
        if picks[k] not in [text_of(v) for v in values]:
            raise Refused(f"the job's matrix lists no {k}={picks[k]}")
        entry[k] = picks[k]
    rest = {k: v for k, v in picks.items() if k not in axes}
    if rest:
        found = [e for e in matrix.get("include", []) if all(text_of(e.get(k)) == v for k, v in rest.items())]
        if len(found) != 1:
            raise Refused(f"the job's matrix includes {len(found)} entries with {rest}, not one")
        entry.update(found[0])
    elif matrix.get("include"):
        raise Refused("the job's matrix includes entries, and no KEY=VALUE picks one")
    return entry


def env_lines(env, ctx, where):
    out = []
    for k, v in (env or {}).items():
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", str(k)):
            raise Refused(f"{where} sets the variable {k!r}")
        out.append(f"export {k}={shlex.quote(substitute(v, ctx))}")
    return out


def build_script(step, steps, ctx, outputs):
    w = step.get("with") or {}
    unknown = set(w) - BUILD_INPUTS
    if unknown:
        raise Refused(f"the build sets {sorted(unknown)}, which the plan does not run")
    if str(w.get("context", ".")) != "." or w.get("load") is not True:
        raise Refused("the build is not of the checkout's root loaded into the local image store")
    tags = str(w.get("tags", "")).split()
    if not tags or "file" not in w:
        raise Refused("the build names no Dockerfile or no tag")
    pre, args = [], []
    for line in str(w.get("build-args", "")).splitlines():
        line = line.strip()
        if not line:
            continue
        k, sep, v = line.partition("=")
        if not sep or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
            raise Refused(f"the build's build-args line {line!r} is not NAME=VALUE")
        m = re.fullmatch(r"\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)\s*\}\}", v)
        if m:
            sid, key = m.groups()
            src = next((s for s in steps if s.get("id") == sid), None)
            if src is None or "run" not in src or src.get("env"):
                raise Refused(f"the build reads steps.{sid}, which is no plain run step of the job")
            if sid not in outputs:
                pre += [f"GITHUB_OUTPUT=\"$RUNNER_TEMP/.outputs/{sid}\"", ": >\"$GITHUB_OUTPUT\"",
                        f"( {str(src['run']).strip()} )"]
                outputs.add(sid)
            args.append(f"--build-arg \"{k}=$(sed -n 's/^{key}=//p' \"$RUNNER_TEMP/.outputs/{sid}\")\"")
        else:
            args.append("--build-arg " + shlex.quote(f"{k}={substitute(v, ctx)}"))
    tag_args = " ".join("--tag " + shlex.quote(t) for t in tags)
    return pre + [f"docker build --file {shlex.quote(str(w['file']))} {tag_args} {' '.join(args)} ."], tags


def trivy_script(step, ctx):
    w = {k: substitute(v, ctx) for k, v in (step.get("with") or {}).items()}
    unknown = set(w) - TRIVY_INPUTS
    if unknown:
        raise Refused(f"the scan sets {sorted(unknown)}, which the plan does not run")
    kind = w.get("scan-type", "image")
    flags = []
    for key, flag in (("scanners", "--scanners"), ("format", "--format"), ("exit-code", "--exit-code"),
                      ("severity", "--severity")):
        if key in w:
            flags.append(f"{flag} {shlex.quote(w[key])}")
    if w.get("ignore-unfixed") in ("true", "True"):
        flags.append("--ignore-unfixed")
    if "trivyignores" in w:
        flags.append(f"--ignorefile {shlex.quote(w['trivyignores'])}")
    lines = [f"echo 'trivy-action pins trivy {w.get('version', '(its default)')}; this host runs:'",
             "trivy --version | head -n 1"]
    if kind == "image":
        if "image-ref" not in w:
            raise Refused("the image scan names no image")
        lines.append(f"trivy image {' '.join(flags)} {shlex.quote(w['image-ref'])}")
    elif kind == "fs":
        ref = w.get("scan-ref", ".")
        if ref != ".":
            raise Refused(f"the filesystem scan reads {ref}, not the checkout")
        # A runner's checkout holds the tracked tree alone; this checkout
        # also holds deps, builds and installs, so the scan reads a copy of
        # what git tracks or would add, as it stands in the working tree.
        lines += [
            'tree="$RUNNER_TEMP/scanned-tree"',
            'rm -rf "$tree" && mkdir -p "$tree"',
            '(cd "$GITHUB_WORKSPACE" && git ls-files -z --cached --others --exclude-standard |'
            ' tar --null --ignore-failed-read -T - -cf -) | tar -xf - -C "$tree"',
            'cd "$tree"',
            f"trivy fs {' '.join(flags)} .",
        ]
    else:
        raise Refused(f"the scan's type {kind!r} is not one the plan runs")
    return lines


def upload_script(step, ctx, artifacts):
    w = {k: substitute(v, ctx) for k, v in (step.get("with") or {}).items()}
    unknown = set(w) - UPLOAD_INPUTS
    if unknown:
        raise Refused(f"the upload sets {sorted(unknown)}, which the plan does not run")
    name = w.get("name", "artifact")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        raise Refused(f"the artifact's name {name!r} is not one the plan keeps")
    dest = os.path.join(artifacts, name)
    lines = ["shopt -s globstar nullglob", f"dest={shlex.quote(dest)}", 'mkdir -p "$dest"', "kept=0"]
    for path in w.get("path", "").splitlines():
        path = path.strip()
        if not path:
            continue
        if any(c in path for c in "\"'`$\\"):
            raise Refused(f"the upload's path {path!r} is not one the plan reads")
        lines.append(f"for f in {path.replace(' ', '?')}; do")
        lines.append('  [ -f "$f" ] || continue; rel="${f#"$RUNNER_TEMP"/}"; rel="${rel#/}"')
        lines.append('  mkdir -p "$dest/$(dirname "$rel")" && cp "$f" "$dest/$rel" && kept=$((kept + 1))')
        lines.append("done")
    lines.append('echo "kept $kept files under $dest"')
    if w.get("if-no-files-found") == "error":
        lines.append('[ "$kept" -gt 0 ] || { echo "the upload found no file" >&2; exit 1; }')
    return lines


def plan(root, wf_name, job_name, plan_dir, temp, picks, excepts, only, extra_env):
    spec = yaml.safe_load(open(os.path.join(root, ".github", "workflows", wf_name)))
    job = (spec.get("jobs") or {}).get(job_name)
    if job is None:
        raise Refused(f"{wf_name} has no job {job_name}")
    for key in ("container", "services", "uses", "if"):
        if key in job:
            raise Refused(f"the job has {key}:, which the plan does not run")
    if "timeout-minutes" not in job:
        raise Refused("the job has no timeout-minutes, which is each step's deadline here")
    deadline = int(job["timeout-minutes"]) * 60
    entry = matrix_entry(job, picks)
    artifacts = os.path.join(os.path.dirname(temp.rstrip("/")), "artifacts")
    ctx = {"matrix": entry, "runner.temp": temp, "github.workspace": root}
    steps = job.get("steps") or []
    names = [s.get("name") for s in steps]
    for n in excepts + ([only] if only else []):
        if n not in names:
            raise Refused(f"the job has no step named {n!r}")
    job_env = env_lines(spec.get("env"), ctx, "the workflow") + env_lines(job.get("env"), ctx, "the job")
    defaults = ((job.get("defaults") or {}).get("run") or {})
    os.makedirs(plan_dir, exist_ok=True)
    rows, outputs = [], set()
    for n, step in enumerate(steps, 1):
        name = step.get("name") or ("uses: " + step["uses"].split("@")[0] if "uses" in step else f"step {n}")
        slug = f"{n:02d}"
        where = f"the step {name!r}"
        try:
            if name in excepts or (only and name != only):
                continue
            if "continue-on-error" in step:
                raise Refused("it sets continue-on-error")
            when = runs(step.get("if"), ctx)
            if when == "never":
                rows.append((slug, when, deadline, "-", name))
                continue
            body, kind = [], None
            if "uses" in step:
                action = step["uses"].split("@")[0]
                if action in SETUP_ACTIONS:
                    kind = "setup"
                elif action == "aquasecurity/trivy-action":
                    kind, body = "trivy", trivy_script(step, ctx)
                elif action == "actions/upload-artifact":
                    kind, body = "artifact", upload_script(step, ctx, artifacts)
                elif action == "docker/build-push-action":
                    lines, tags = build_script(step, steps, ctx, outputs)
                    with open(os.path.join(plan_dir, slug + ".tags"), "w") as out:
                        out.write("\n".join(tags) + "\n")
                    if only:
                        kind, body = "build", lines
                    else:
                        kind = "built"
                        body = [f"docker image inspect --format {shlex.quote(t + ' is {{.Id}}')} {shlex.quote(t)}"
                                for t in tags]
                else:
                    raise Refused(f"it uses {action}, which the plan does not run")
            elif str(step["run"]).strip() in SETUP_RUNS:
                kind = "setup"
            else:
                kind = "run"
                text = substitute(step["run"], ctx)
                if re.search(r"\bGITHUB_(ENV|PATH)\b", text):
                    raise Refused("it writes GITHUB_ENV or GITHUB_PATH, which the plan does not carry")
                lines = text.split("\n")
                body = [LOAD_CHECK if l.strip() == LOAD_LINE else l for l in lines]
            shell = step.get("shell", defaults.get("shell"))
            if shell not in (None, "bash"):
                raise Refused(f"it runs under the shell {shell!r}")
            rows.append((slug, when, deadline, kind, name))
            if kind == "setup":
                continue
            wd = step.get("working-directory", defaults.get("working-directory", "."))
            wd = substitute(wd, ctx) if kind == "run" else "."
            out_id = step.get("id") or f"step-{slug}"
            pre = [
                "#!/usr/bin/env bash",
                f"# {wf_name} {job_name}: {name}",
                "set -eo pipefail" if shell == "bash" else "set -e",
                "unset " + " ".join(UNSET),
                f"export GITHUB_WORKSPACE={shlex.quote(root)} RUNNER_TEMP={shlex.quote(temp)}",
                'mkdir -p "$RUNNER_TEMP/.outputs"',
                f"export GITHUB_OUTPUT=\"$RUNNER_TEMP/.outputs/{out_id}\" GITHUB_STEP_SUMMARY=\"$RUNNER_TEMP/.summary.md\"",
            ] + job_env + env_lines(step.get("env"), ctx, where) + [
                f"export {shlex.quote(e)}" for e in extra_env
            ] + [
                f"cd {shlex.quote(os.path.join(root, wd))}",
            ]
            with open(os.path.join(plan_dir, slug + ".sh"), "w") as out:
                out.write("\n".join(pre + body) + "\n")
        except Refused as e:
            raise Refused(f"{wf_name} {job_name}: {where}: {e}")
    with open(os.path.join(plan_dir, "plan"), "w") as out:
        for row in rows:
            out.write("\t".join(map(str, row)) + "\n")


def main(argv):
    if len(argv) < 5:
        sys.exit(__doc__.split("\n\n")[1])
    root, wf_name, job_name, plan_dir, temp = argv[:5]
    picks, excepts, only, extra = {}, [], None, []
    rest = argv[5:]
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in ("--except", "--only", "--env") and i + 1 < len(rest):
            v = rest[i + 1]
            if a == "--except":
                excepts.append(v)
            elif a == "--only":
                only = v
            else:
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", v, re.S):
                    sys.exit(f"--env takes NAME=VALUE, not {v!r}")
                extra.append(v)
            i += 2
        elif re.fullmatch(r"[a-z][a-z0-9_-]*=.+", a):
            k, v = a.split("=", 1)
            picks[k] = v
            i += 1
        else:
            sys.exit(f"workflow_plan: {a!r} is neither KEY=VALUE nor --except, --only or --env with a value")
    try:
        plan(os.path.abspath(root), wf_name, job_name, plan_dir, os.path.abspath(temp), picks, excepts, only, extra)
    except Refused as e:
        sys.exit(f"workflow_plan: {e}")


if __name__ == "__main__":
    main(sys.argv[1:])

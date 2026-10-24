# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
"""One job of a GitHub workflow as the commit gate runs it on this host.

    python3 -I scripts/lib/workflow_plan.py ROOT WORKFLOW JOB PLAN_DIR TEMP_DIR \
        [KEY=VALUE]... [--except STEP]... [--only STEP] [--env NAME=VALUE]... \
        [--image-namespace NS] [--artifacts DIR]
    python3 -I scripts/lib/workflow_plan.py --trivy-version ROOT
    python3 -I scripts/lib/workflow_plan.py --image-tags

The second form prints the one trivy release every trivy-action step of
the workflows pins, and fails when they pin more than one; the third the
table of image tags below, a tag a line with the variable beside it.

With --image-namespace NS every image tag of the table a step names (in
its script, its env, a build's tags or a scan's image) is NS/TAG instead,
so the job builds and runs images of the gate's own and touches no tag
the host has; each variable of the table is set to its tag's NS/TAG for
every step; and a step that gives an image a name the table does not
hold (a build's tags, a `docker tag` target, a `docker save`, `docker
commit` or `docker import`, whatever the repository), or names a tag of
the table's repositories the table does not hold, fails the plan. An
image a step only runs or pulls (postgres, the Playwright image) is named
as CI names it. Without --image-namespace a step that gives an image any
name fails it. Whatever the namespace, a step's docker commands are read
as docker reads them (its global options, then every option form of a
verb that gives a name), and one the plan cannot read that far, one that
loads images other than the line the plan replaces, and one that starts
a container under a name CI gives (`docker run`, `docker create`) fail
it. An upload step keeps its files under DIR/NAME (--artifacts).

This reading guards our own workflows against a step that would touch a
host's names by accident; it is no defence against a hostile author.
Quoting can hide a command from it: a word bash assembles from quoted
pieces (`doc""ker`) inside an expansion's default, where the plan reads
the quotes as written and bash does not, runs as docker unread. A hostile
step is a hostile commit, reviewed as code.

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
the trivy command line it runs, failing unless the trivy on PATH is the
release the step pins), `build` (docker/build-push-action as
`docker build`, under --only), `built` (the same step in a whole job: the
image the gate built is checked present), `artifact` (actions/upload-
artifact, its files copied under --artifacts), `setup` (checkout, toolchain setup, caches, downloads and `mix
deps.get` with the prebuilt binary fetch after it, which this host's
checkout and the gate's own fetch already hold: nothing runs), or `-`
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

import glob
import os
import re
import shlex
import sys

import yaml

# The fixed image tags the jobs the gate runs build and name. Under
# --image-namespace each is run as NS/TAG; a variable beside a tag is one a
# harness script reads that tag from by default (tests/compose-proof/run.sh
# takes COMPOSE_PROOF_IMAGE), set to NS/TAG for every step.
# tests/commit-gate-test.sh holds the table to the jobs the gate runs: a
# tag of these repositories one of them names that is not here, or one
# here that none names, fails it.
IMAGE_TAGS = {
    "cyfr-locus:ci": None,
    "cyfr-locus:smoke": None,
    "cyfr-locus:runtime": None,
    "cyfr-locus:backends": None,
    "cyfr-locus:tincture-proof": None,
    "cyfr:push": None,
    "cyfr:compose-proof": "COMPOSE_PROOF_IMAGE",
}
# A tag of the table's repositories, wherever a step names one: not part
# of a longer word, a path or a URL's userinfo.
IMAGE_REF = re.compile(r"(?<![A-Za-z0-9_./:@-])((?:cyfr|cyfr-locus):[A-Za-z0-9_][A-Za-z0-9_.-]*)(?![A-Za-z0-9_.:@/-])")
NAMESPACE = None

# A step whose whole script is one of these fetches what this checkout
# already holds, so it is setup too: the gate runs the prebuilt binary
# fetch itself before any leg.
SETUP_RUNS = {"mix deps.get\nscripts/fetch-prebuilt-binaries.sh"}
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


def rename(text):
    """TEXT with each image tag of the table as the gate's own (NS/TAG)."""
    if NAMESPACE is None:
        return text

    def one(m):
        if m.group(1) not in IMAGE_TAGS:
            raise Refused(f"it names the image tag {m.group(1)}, which the gate's table of image tags does not hold")
        return f"{NAMESPACE}/{m.group(1)}"
    return IMAGE_REF.sub(one, text)


# --- docker commands in a step's script ---------------------------------------
# A step's script is read as bash reads it, far enough to find each docker
# command and its words: quotes, escapes, line continuations, comments,
# operators and redirections, here-documents, and the commands inside
# command substitutions, backquotes and process substitutions, each read as
# a command of its own. Then each docker command is read as the docker CLI
# reads it: its global options, its verb and, for a verb that gives an
# image a name, every option form of that verb. A docker command the plan
# cannot read that far fails it.


class Word:
    """A shell word: its text with quotes removed and each command
    substitution as NUL, whether it expands nothing (`plain`), and whether
    an expansion in it is unquoted, so it may split into several words."""

    def __init__(self):
        self.text, self.plain, self.splits, self.elements = "", True, False, None


SEPARATORS = ("&&", "||", ";;&", ";;", ";&", "|&", ";", "|", "&", "(", ")", "\n")
REDIRECTS = ("<<<", "<<-", "<<", "&>>", "&>", ">>", ">&", "<&", "<>", ">|", ">", "<")
RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "for", "in", "case", "esac",
            "select", "function", "time", "!", "{", "}", "coproc"}
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")


class Lexer:
    """With `strict` off, a here-document's body is kept in `bodies` rather
    than refused for mentioning docker (tests/commit-gate-test.sh reads the
    scripts the close runs so)."""

    def __init__(self, s, strict=True):
        self.s, self.commands, self.heredocs, self.strict, self.bodies = s, [], [], strict, []

    def fail(self, why):
        raise Refused(f"its script is not one the plan reads: {why}")

    def script(self, i, stop=None):
        """Reads commands from i up to the `)` that closes a command or
        process substitution (`stop`), a subshell's own aside, or to the
        end; returns the index past it."""
        s, words, word, redirect, depth = self.s, [], None, False, 0

        def end_word():
            nonlocal word, redirect
            if word is not None:
                if redirect:
                    redirect = False
                else:
                    words.append(word)
            word = None

        def end_command(ended):
            end_word()
            self.commands.append((list(words), ended))
            words.clear()

        while i < len(s):
            c = s[i]
            if stop is not None and c == stop and not (c == ")" and depth):
                end_command(stop)
                return i + 1
            if c == "\\" and s.startswith("\\\n", i):
                i += 2
                continue
            if c in " \t":
                end_word()
                i += 1
                continue
            if c == "#" and word is None:
                while i < len(s) and s[i] != "\n":
                    i += 1
                continue
            if c == "\n":
                end_command("\n")
                i = self.read_heredocs(i + 1)
                continue
            if any(w.plain and w.text == "[[" for w in words) and not any(
                    w.plain and w.text == "]]" for w in words + ([word] if word else [])):
                # Within [[ ]], operators are words of the expression, or
                # part of one (a pattern's or a regex's parentheses).
                op = next((o for o in SEPARATORS + REDIRECTS if o != "\n" and s.startswith(o, i)), None)
                if op:
                    if word is None:
                        word = Word()
                    word.text += op
                    i += len(op)
                    continue
            op = next((o for o in REDIRECTS if s.startswith(o, i)), None)
            if op and not (op in ("<", ">") and s.startswith("(", i + 1)):
                # A word of digits directly before it names a descriptor.
                if word is not None and word.plain and word.text.isdigit():
                    word = None
                end_word()
                i += len(op)
                if op in ("<<", "<<-"):
                    while i < len(s) and s[i] in " \t":
                        i += 1
                    start = i
                    while i < len(s) and s[i] not in " \t\n;&|<>()":
                        i += 1
                    delim = re.sub(r"[\"'\\]", "", s[start:i])
                    if not delim:
                        self.fail("a here-document names no delimiter")
                    self.heredocs.append((delim, op == "<<-"))
                else:
                    redirect = True
                continue
            op = next((o for o in SEPARATORS if s.startswith(o, i)), None)
            if op == "(" and word is not None:
                if s.startswith("()", i) and word.plain:
                    # A function's definition: its name is no command.
                    word = None
                    end_command("()")
                    i += 2
                    continue
                if not (word.plain and ASSIGNMENT.fullmatch(word.text)):
                    self.fail("a ( inside a word")
                # An array's assignment: its elements are data of the
                # assignment's word, up to its `)`, each also kept as a
                # word of its own (`elements`).
                i += 1
                word.elements, element = [], None
                while i < len(s) and s[i] != ")":
                    if s[i] in " \t\n":
                        word.text += " "
                        if element is not None:
                            word.elements.append(element)
                            element = None
                        i += 1
                    elif s[i] == "#" and element is None:
                        while i < len(s) and s[i] != "\n":
                            i += 1
                    else:
                        element = element or Word()
                        j = self.word_part(i, element, quoted=False)
                        word.text += s[i:j]
                        i = j
                if element is not None:
                    word.elements.append(element)
                word.plain = word.plain and all(e.plain for e in word.elements)
                if i >= len(s):
                    self.fail("an unterminated array")
                i += 1
                continue
            if op:
                if op == "(":
                    depth += 1
                elif op == ")" and depth:
                    depth -= 1
                end_command(op)
                i += len(op)
                continue
            if word is None:
                word = Word()
            i = self.word_part(i, word, quoted=False)
        if stop is not None:
            self.fail("an unterminated command substitution")
        end_command(None)
        return i

    def read_heredocs(self, i):
        s = self.s
        for delim, tabs in self.heredocs:
            while True:
                if i >= len(s):
                    self.fail(f"the here-document {delim} is not closed")
                j = s.find("\n", i)
                j = len(s) if j < 0 else j
                line = s[i:j]
                i = j + 1
                if (line.lstrip("\t") if tabs else line) == delim:
                    break
                self.bodies.append(line)
                if self.strict and re.search(r"\bdocker\b", line):
                    self.fail("a here-document mentions docker")
        self.heredocs = []
        return i

    def word_part(self, i, word, quoted):
        """One piece of a word from i; returns the index past it."""
        s, c = self.s, self.s[i]
        if c == "\\":
            if i + 1 >= len(s):
                self.fail("a trailing backslash")
            if not quoted or s[i + 1] in '$`"\\\n':
                word.text += s[i + 1]
            else:
                word.text += s[i:i + 2]
            return i + 2
        if c == "'" and not quoted:
            j = s.find("'", i + 1)
            if j < 0:
                self.fail("an unterminated single quote")
            word.text += s[i + 1:j]
            return j + 1
        if s.startswith("$'", i) and not quoted:
            j = i + 2
            while j < len(s) and s[j] != "'":
                j += 2 if s[j] == "\\" else 1
            if j >= len(s):
                self.fail("an unterminated $' quote")
            word.text += s[i + 2:j]
            return j + 1
        if c == '"' and not quoted:
            i += 1
            while i < len(s) and s[i] != '"':
                i = self.word_part(i, word, quoted=True)
            if i >= len(s):
                self.fail("an unterminated double quote")
            return i + 1
        if s.startswith("$((", i):
            j = self.inside(i + 3, "))", "an arithmetic expansion")
            return self.expansion(word, quoted, s[i:j], j)
        if s.startswith("$(", i) or (c in "<>" and s.startswith("(", i + 1) and not quoted):
            j = self.script(i + 2, ")")
            return self.expansion(word, quoted, "\0", j)
        if c == "`":
            j = i + 1
            while j < len(s) and s[j] != "`":
                j += 2 if s[j] == "\\" else 1
            if j >= len(s):
                self.fail("an unterminated backquote")
            inner = Lexer(re.sub(r"\\([$`\\])", r"\1", s[i + 1:j]), self.strict)
            inner.script(0)
            self.commands += inner.commands
            self.bodies += inner.bodies
            return self.expansion(word, quoted, "\0", j + 1)
        if s.startswith("${", i):
            j = self.inside(i + 2, "}", "a parameter expansion")
            return self.expansion(word, quoted, s[i:j], j)
        if c == "$" and i + 1 < len(s) and re.match(r"[A-Za-z0-9_@*#?$!-]", s[i + 1]):
            m = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])", s[i:])
            return self.expansion(word, quoted, m.group(0), i + len(m.group(0)))
        word.text += c
        return i + 1

    def inside(self, j, close, what):
        """Past the `close` that ends the parameter or arithmetic expansion
        whose content starts at j. Its content is kept as text, a value;
        a command it could run (a command substitution, backquotes, a
        process substitution) or a mention of docker fails the plan, and
        with `strict` off (the guard's reading) is read as commands of its
        own instead."""
        s, depth, start = self.s, 1, j
        while j < len(s):
            c = s[j]
            if c == "\\":
                j += 2
                continue
            if (s.startswith("$(", j) and not s.startswith("$((", j)) or (c in "<>" and s.startswith("(", j + 1)):
                if self.strict:
                    self.fail(f"{what} holds a command, which the plan does not read")
                j = self.script(j + 2, ")")
                continue
            if c == "`":
                if self.strict:
                    self.fail(f"{what} holds a command, which the plan does not read")
                k = j + 1
                while k < len(s) and s[k] != "`":
                    k += 2 if s[k] == "\\" else 1
                inner = Lexer(re.sub(r"\\([$`\\])", r"\1", s[j + 1:k]), self.strict)
                inner.script(0)
                self.commands += inner.commands
                self.bodies += inner.bodies
                j = k + 1
                continue
            if c == "'" and close == "}":
                k = s.find("'", j + 1)
                j = len(s) if k < 0 else k + 1
                continue
            if close == "}":
                depth += {"{": 1, "}": -1}.get(c, 0)
            elif c == "(":
                depth += 1
            elif s.startswith("))", j) and depth == 1:
                if self.strict and re.search(r"\bdocker\b", s[start:j]):
                    self.fail(f"{what} mentions docker")
                return j + 2
            elif c == ")":
                depth -= 1
            j += 1
            if depth == 0:
                if self.strict and re.search(r"\bdocker\b", s[start:j]):
                    self.fail(f"{what} mentions docker")
                return j
        self.fail(f"{what} is not closed")

    def expansion(self, word, quoted, text, j):
        # "$@" and "${a[@]}" are as many words as they hold, quoted or not.
        if re.fullmatch(r"\$@|\$\{!?(@|[A-Za-z_][A-Za-z0-9_]*\[@\])[^}]*\}", text):
            word.splits = True
        word.text += text
        word.plain = False
        word.splits = word.splits or not quoted
        return j


def shell_commands(script):
    """Each simple command of a bash script, a list of Words (empty
    between two separators), with the separator that ended it (an operator,
    a newline, `()` after a function's name, or a substitution's closing
    character), the commands in its substitutions among them, each before
    the command it is in."""
    lexer = Lexer(script)
    lexer.script(0)
    if lexer.heredocs:
        lexer.read_heredocs(len(script))
    return lexer.commands


# Docker's global options, which come before its verb: those that take a
# value, and those that take none.
DOCKER_VALUES = {"--config", "-c", "--context", "-H", "--host", "-l", "--log-level", "--tlscacert", "--tlscert",
                 "--tlskey"}
DOCKER_BOOLS = {"-D", "--debug", "--tls", "--tlsverify", "-v", "--version", "-h", "--help"}
# Each verb that gives an image a name: the options it takes a value for,
# those it takes none for, and which of its operands are names it gives
# (`all`, or the index of one). A build's --output and --push give names
# the plan cannot hold to the table, so a build refuses them.
NAMING = {
    "build": ({"--add-host", "--allow", "--annotation", "--attest", "--build-arg", "--build-context", "--builder",
               "--cache-from", "--cache-to", "--call", "--cgroup-parent", "-f", "--file", "--iidfile", "--label",
               "--metadata-file", "--network", "--no-cache-filter", "--platform", "--progress", "--provenance",
               "--sbom", "--secret", "--shm-size", "--ssh", "-t", "--tag", "--target", "--ulimit", "--cpu-period",
               "--cpu-quota", "-c", "--cpu-shares", "--cpuset-cpus", "--cpuset-mems", "--isolation", "-m",
               "--memory", "--memory-swap", "--security-opt", "-o", "--output"},
              {"--check", "--load", "--no-cache", "--pull", "--push", "-q", "--quiet", "-D", "--debug", "--compress",
               "--disable-content-trust", "--force-rm", "--rm", "--squash", "-h", "--help"},
              None),
    "tag": (set(), {"-h", "--help"}, 1),
    "save": ({"-o", "--output", "--platform"}, {"-h", "--help"}, "all"),
    "commit": ({"-a", "--author", "-c", "--change", "-m", "--message"}, {"-p", "--pause", "-h", "--help"}, 1),
    "import": ({"-c", "--change", "-m", "--message", "--platform"}, {"-h", "--help"}, 1),
}
NAMING_VERBS = {"build": "build", "image build": "build", "buildx build": "build", "builder build": "build",
                "tag": "tag", "image tag": "tag", "save": "save", "image save": "save", "commit": "commit",
                "container commit": "commit", "import": "import", "image import": "import"}
# Verbs that give no image a name and start no container.
READING_VERBS = {"version", "info", "inspect", "image inspect", "images", "image ls", "image list", "ps",
                 "container ls", "container list", "logs", "container logs", "pull", "image pull",
                 "compose version"}
DOCKER_GROUPS = {"image", "container", "buildx", "builder", "compose"}


def options(words, values, bools, interspersed=True, arrays=None):
    """WORDS read as docker's flag library reads them, against the options
    that take a value and those that take none: the options given, as
    (option, value) pairs, and the operands; with interspersed off, the
    operands start at the first word that is no option. An option not in
    either set, or a word that may split into options, fails it, but for
    an array's expansion ("${A[@]}" or ${A[@]+"${A[@]}"}) where `arrays`
    holds every assignment of A, each a list of words that are options and
    their values alone, none of them --name."""
    given, operands, i = [], [], 0
    while i < len(words):
        w = words[i]
        i += 1
        if operands and not interspersed:
            operands.append(w)
            continue
        # `${VAR:+--option "VALUE"}` is nothing, or the option and its one
        # value (VALUE one double-quoted word).
        m = None if w.plain else re.fullmatch(r'\$\{[A-Za-z_][A-Za-z0-9_]*:\+(--[A-Za-z][A-Za-z0-9-]*) "(.*)"\}', w.text, re.S)
        if m and m.group(1) in values and not re.search(r'"|\$@|\[@\]', re.sub(r"\$\([^()]*\)", "", m.group(2))):
            given.append((m.group(1), m.group(2)))
            continue
        a = re.fullmatch(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\}|\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\+"\$\{\2\[@\]\}"\}', w.text)
        a = a and (a.group(1) or a.group(2))
        if w.splits and a and arrays is not None and a in arrays:
            for elements in arrays[a]:
                held, extra = options(elements, values, bools)
                if extra or any(name == "--name" for name, _ in held):
                    raise Refused(f"the array {a} holds {'an operand' if extra else '--name'}, which the plan cannot place")
            continue
        if w.splits:
            raise Refused(f"a docker command's word {w.text!r} may split into options the plan cannot read")
        t = w.text
        if t == "--":
            operands += words[i:]
            break
        if t.startswith("--"):
            name, eq, value = t.partition("=")
            if name in values:
                if not eq:
                    if i >= len(words):
                        raise Refused(f"docker's {name} has no value")
                    value, i = words[i].text, i + 1
                given.append((name, value))
            elif name in bools:
                if eq and value not in ("true", "false"):
                    raise Refused(f"docker's {name}={value} is not true or false")
                given.append((name, value if eq else "true"))
            else:
                raise Refused(f"docker's option {name} is not one the plan reads")
        elif t.startswith("-") and t != "-":
            j = 1
            while j < len(t):
                name = "-" + t[j]
                j += 1
                if name in bools:
                    if t.startswith("=", j):
                        raise Refused(f"docker's {name}{t[j:]} is not one the plan reads")
                    given.append((name, "true"))
                elif name in values:
                    value = t[j:]
                    value = value[1:] if value.startswith("=") else value
                    if not value:
                        if i >= len(words):
                            raise Refused(f"docker's {name} has no value")
                        value, i = words[i].text, i + 1
                    given.append((name, value))
                    break
                else:
                    raise Refused(f"docker's option {name} (in {t}) is not one the plan reads")
        else:
            operands.append(w)
    return given, operands


# docker run's and docker create's options (docker 29's `docker run
# --help`; create takes the same less --detach, --detach-keys and
# --sig-proxy), those that take a value and those that take none, through
# which container_name reads a container's --name.
RUN_VALUES = {
    "--add-host", "--annotation", "-a", "--attach", "--blkio-weight", "--blkio-weight-device", "--cap-add",
    "--cap-drop", "--cgroup-parent", "--cgroupns", "--cidfile", "--cpu-period", "--cpu-quota", "--cpu-rt-period",
    "--cpu-rt-runtime", "-c", "--cpu-shares", "--cpus", "--cpuset-cpus", "--cpuset-mems", "--detach-keys",
    "--device", "--device-cgroup-rule", "--device-read-bps", "--device-read-iops", "--device-write-bps",
    "--device-write-iops", "--dns", "--dns-option", "--dns-search", "--domainname", "--entrypoint", "-e", "--env",
    "--env-file", "--expose", "--gpus", "--group-add", "--health-cmd", "--health-interval", "--health-retries",
    "--health-start-interval", "--health-start-period", "--health-timeout", "-h", "--hostname", "--ip", "--ip6",
    "--ipc", "--isolation", "-l", "--label", "--label-file", "--link", "--link-local-ip", "--log-driver",
    "--log-opt", "--mac-address", "-m", "--memory", "--memory-reservation", "--memory-swap",
    "--memory-swappiness", "--mount", "--name", "--network", "--network-alias", "--oom-score-adj", "--pid",
    "--pids-limit", "--platform", "-p", "--publish", "--pull", "--restart", "--runtime", "--security-opt",
    "--shm-size", "--stop-signal", "--stop-timeout", "--storage-opt", "--sysctl", "--tmpfs", "--ulimit", "-u",
    "--user", "--userns", "--uts", "-v", "--volume", "--volume-driver", "--volumes-from", "-w", "--workdir",
}
RUN_BOOLS = {"-d", "--detach", "--help", "--init", "-i", "--interactive", "--no-healthcheck", "--oom-kill-disable",
             "--privileged", "-P", "--publish-all", "-q", "--quiet", "--read-only", "--rm", "--sig-proxy", "-t",
             "--tty", "--use-api-socket"}


def container_name(words, arrays=None):
    """For the words after `docker`: None when they start no container
    (no run or create, in either spelling); else the text of the --name
    the run or create itself is given, the last one as docker takes it, or
    "" when it is given none. Its options are read as docker reads them,
    the global options before the verb among them, up to the image; a word
    there that may split into options (an array's expansion aside, read
    through `arrays` as options() reads one), an option the tables above do
    not hold or an expansion naming the verb fails it."""
    _, rest = options(words, DOCKER_VALUES, DOCKER_BOOLS, interspersed=False)
    if not rest:
        return None
    if not rest[0].plain:
        raise Refused(f"its docker verb {rest[0].text!r} is an expansion the plan cannot read")
    verb, rest = rest[0].text, rest[1:]
    if verb == "container":
        if not rest or not rest[0].plain:
            raise Refused("its docker container command is not one the plan reads")
        verb, rest = rest[0].text, rest[1:]
    if verb not in ("run", "create"):
        return None
    given, operands = options(rest, RUN_VALUES, RUN_BOOLS, interspersed=False, arrays=arrays)
    if not operands:
        raise Refused(f"its docker {verb} names no image")
    names = [value for name, value in given if name == "--name"]
    return names[-1] if names else ""


def docker_names(words):
    """The image names one docker command (its words after `docker`) gives,
    or a failure when it gives names the plan cannot read, loads images,
    starts a container, or is a command the plan does not read."""
    _, rest = options(words, DOCKER_VALUES, DOCKER_BOOLS, interspersed=False)
    if not rest:
        return []
    verb, rest = rest[0], rest[1:]
    if not verb.plain:
        raise Refused(f"its docker verb {verb.text!r} is an expansion the plan cannot read")
    verb = verb.text
    if verb in DOCKER_GROUPS:
        if not rest or not rest[0].plain or rest[0].text.startswith("-"):
            raise Refused(f"its docker {verb} command is not one the plan reads")
        verb, rest = f"{verb} {rest[0].text}", rest[1:]
    if verb in ("load", "image load"):
        raise Refused("it loads images whose names the plan cannot read")
    if verb in ("run", "create", "container run", "container create"):
        raise Refused(f"it starts a container (docker {verb}) under a name CI gives, which the gate cannot "
                      "own: a step starts containers through a script that names them under PROOF_RUN_PREFIX")
    if verb in READING_VERBS:
        return []
    if verb not in NAMING_VERBS:
        raise Refused(f"it runs docker {verb}, which the plan does not read")
    kind = NAMING_VERBS[verb]
    values, bools, named = NAMING[kind]
    given, operands = options(rest, values, bools)
    if kind == "build":
        if any(name in ("-o", "--output", "--push") for name, _ in given):
            raise Refused("its build gives names through --output or --push, which the plan does not read")
        return [value for name, value in given if name in ("-t", "--tag")]
    if kind == "tag" and len(operands) != 2:
        raise Refused(f"its docker tag has {len(operands)} operands, not a source and a target")
    if kind in ("commit", "import") and len(operands) not in (1, 2):
        raise Refused(f"its docker {verb} has {len(operands)} operands")
    if named == "all":
        if not operands:
            raise Refused(f"its docker {verb} names no image")
        return [w.text.replace("\0", "$(…)") for w in operands]
    return [w.text.replace("\0", "$(…)") for w in operands[named:named + 1]]


def given_names(script):
    """The image names a step's script gives an image: a build's tags, a
    `docker tag`'s target, what a `docker save` writes, a `docker commit`'s
    or `docker import`'s name, however the command spells its options. An
    image a script only runs, pulls or inspects is a reference, and its
    name is not the plan's to give. The one `docker load` the plan replaces
    is left out; a docker command it cannot read fails it: docker named
    where it is no command (an argument of xargs, env, sudo or command, a
    string a shell or eval runs), a load, a run, a verb or option it does
    not read, or a word that may split into options."""
    script = "\n".join("" if line.strip() == LOAD_LINE else line for line in script.split("\n"))
    names, cases = [], []
    for words, ended in shell_commands(script):
        first = words[0].text if words and words[0].plain else None
        # A case statement's subject and patterns are no commands: after
        # `case WORD in`, and after each `;;`, `;&` or `;;&` of its body,
        # the words up to a `)` are a pattern (its alternatives split at
        # `|`), until its `esac`.
        if first == "esac" and cases:
            cases.pop()
            continue
        if cases and cases[-1] == "pattern" and words:
            if ended == "|":
                continue
            if ended == ")":
                cases[-1] = "body"
                continue
            if first != "(":
                raise Refused("its case statement has a pattern the plan does not read")
        if first == "case":
            if len(words) < 3 or not words[2].plain or words[2].text != "in":
                raise Refused("its case statement is not one the plan reads")
            cases.append("body" if ended == ")" and len(words) > 3 else "pattern")
            continue
        if cases and ended in (";;", ";&", ";;&"):
            cases[-1] = "pattern"
        names += command_names(words)
    if cases:
        raise Refused("its case statement has no esac")
    return names


def command_names(words):
    """The image names one simple command gives, as given_names reads it."""
    k = 0
    while k < len(words) and ((words[k].plain and words[k].text in RESERVED) or ASSIGNMENT.match(words[k].text)):
        k += 1
    for n, w in enumerate(words):
        if n == k:
            continue
        if w.plain and os.path.basename(w.text) == "docker":
            raise Refused("it names docker where the plan does not read it as a command")
        if re.search(r"(^|[\s;&|(])docker\s+\S", w.text.replace("\0", " ")):
            raise Refused(f"its word {w.text!r} holds a docker command the plan does not read")
    if k >= len(words):
        return []
    command = words[k]
    # A conditional expression and a loop's variable and list name no
    # command.
    if command.plain and command.text in ("[[", "for", "select"):
        return []
    if not command.plain:
        raise Refused(f"it runs {command.text!r}, a command an expansion names, which may be docker")
    if os.path.basename(command.text) == "docker":
        return docker_names(words[k + 1:])
    return []


def check_given(names):
    """Every image name a step gives is one of the table's, whatever its
    repository, so the plan can give it as the gate's own instead."""
    for name in names:
        if name not in IMAGE_TAGS:
            raise Refused(f"it gives an image the name {name}, which the gate's table of image tags does not hold")


def substitute(text, ctx):
    """A value with each `${{ expression }}` in it replaced by its text, and
    each image tag of the table by the gate's own."""
    return rename(INLINE.sub(lambda m: text_of(evaluate(m.group(1), ctx)), str(text)))


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
    if NAMESPACE is not None:
        check_given(tags)
    tags = [rename(t) for t in tags]
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
    if not re.fullmatch(r"v?\d+\.\d+\.\d+", w.get("version", "")):
        raise Refused("the scan pins no trivy release")
    pin = w["version"].lstrip("v")
    # The gate installs the pinned trivy ahead on PATH; a scan by any other
    # would not be CI's.
    # Its version is read whole, then matched through a here-string: a pipe
    # into grep -q could fail on a version that matches.
    lines = ['have=$(trivy --version) || have=',
             f"grep -qxF {shlex.quote('Version: ' + pin)} <<<\"$have\" ||"
             f" {{ echo {shlex.quote('the trivy on PATH is not ' + pin + ', the version the step pins')} >&2; exit 1; }}"]
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


def plan(root, wf_name, job_name, plan_dir, temp, picks, excepts, only, extra_env, artifacts):
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
                    if artifacts is None:
                        raise Refused("it uploads artifacts, and no --artifacts directory keeps them")
                    kind, body = "artifact", upload_script(step, ctx, artifacts)
                elif action == "docker/build-push-action":
                    lines, tags = build_script(step, steps, ctx, outputs)
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
                given = given_names(INLINE.sub(lambda m: text_of(evaluate(m.group(1), ctx)), str(step["run"])))
                if NAMESPACE is not None:
                    check_given(given)
                elif given:
                    raise Refused(f"it gives an image the name {given[0]}, and with no --image-namespace the plan "
                                  "has no name of the gate's to give it")
                text = substitute(step["run"], ctx)
                if re.search(r"\bGITHUB_(ENV|PATH)\b", text):
                    raise Refused("it writes GITHUB_ENV or GITHUB_PATH, which the plan does not carry")
                lines = text.split("\n")
                body = [rename(LOAD_CHECK) if l.strip() == LOAD_LINE else l for l in lines]
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
                f"export {var}={shlex.quote(rename(tag))}" for tag, var in IMAGE_TAGS.items()
                if var and NAMESPACE is not None
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


def trivy_version(root):
    """The one trivy release every trivy-action step of the workflows pins."""
    pins = set()
    for path in sorted(glob.glob(os.path.join(root, ".github", "workflows", "*.yml"))):
        for job in (yaml.safe_load(open(path)).get("jobs") or {}).values():
            for step in job.get("steps") or []:
                if str(step.get("uses", "")).split("@")[0] == "aquasecurity/trivy-action":
                    pins.add(str((step.get("with") or {}).get("version", "")).lstrip("v"))
    if len(pins) != 1 or not re.fullmatch(r"\d+\.\d+\.\d+", next(iter(pins))):
        raise Refused(f"the workflows' trivy-action steps pin {sorted(pins)}, not one release")
    return next(iter(pins))


def main(argv):
    global NAMESPACE
    if argv == ["--image-tags"]:
        for tag, var in IMAGE_TAGS.items():
            print(f"{tag} {var}" if var else tag)
        return
    if len(argv) == 2 and argv[0] == "--trivy-version":
        try:
            print(trivy_version(os.path.abspath(argv[1])))
        except Refused as e:
            sys.exit(f"workflow_plan: {e}")
        return
    if len(argv) < 5:
        sys.exit(__doc__.split("\n\n")[1])
    root, wf_name, job_name, plan_dir, temp = argv[:5]
    picks, excepts, only, extra, artifacts = {}, [], None, [], None
    rest = argv[5:]
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in ("--except", "--only", "--env", "--image-namespace", "--artifacts") and i + 1 < len(rest):
            v = rest[i + 1]
            if a == "--image-namespace":
                if not re.fullmatch(r"[a-z0-9]+(?:[._-][a-z0-9]+)*", v):
                    sys.exit(f"workflow_plan: {v!r} is no image repository namespace")
                NAMESPACE = v
            elif a == "--artifacts":
                artifacts = os.path.abspath(v)
            elif a == "--except":
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
            sys.exit(f"workflow_plan: {a!r} is neither KEY=VALUE nor an option with its value")
    try:
        plan(os.path.abspath(root), wf_name, job_name, plan_dir, os.path.abspath(temp), picks, excepts, only, extra,
             artifacts)
    except Refused as e:
        sys.exit(f"workflow_plan: {e}")


if __name__ == "__main__":
    main(sys.argv[1:])

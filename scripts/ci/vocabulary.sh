#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# Refuse a retired name and a storage layout that is not Arca's: scripts/ci/vocabulary.sh
#
# CI's vocabulary job runs this script, and so does the handoff stage's
# vocabulary row (scripts/stages.tsv): its patterns are defined here only.
#
# The tenancy unit is the athanor and a conversation is a thread. Code,
# configuration and the operator-facing docs spell none of the retired
# names below: the org/project tenancy vocabulary and conversation and
# topic subscription with the prism: PubSub prefix, in every form; the
# athanor's retired second name and the WASM engine's, as words; and
# the apps, images, environment variables and paths the umbrella's
# applications replaced: Porta and the separate Prism endpoint, spawn
# and its spawner, the standalone Opus app and its worker image, the
# keeper's retired home and the worker settings. Other retired module
# and function names are not listed: a call to one fails to compile.
# Each name is matched as a word or inside an identifier, never inside
# an English word that merely contains its letters; the free words
# "org" and "project" are not gated (OCI annotations, Mix.Project, Go
# module paths and "project directory" prose are legitimate). macOS git
# grep -E ignores \b, so there the patterns run as PCRE, which reads them
# the same way.
#
# It reads the tracked tree from the root, whatever directory it is run
# from. Exit 0 when clean, 1 naming each finding as a ::error:: line on
# stdout, 64 when given any argument.
set -euo pipefail

[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 64; }
cd "$(git rev-parse --show-toplevel)"
regex=-E
if [ "$(uname -s)" = Darwin ]; then regex=-P; fi

paths='apps config wit scripts tests Caddyfile docker-compose.yml Dockerfile Dockerfile.locus docker-entrypoint.sh .env.example .env.locus.example .gitignore .dockerignore README.md ARCHITECTURE.md CONTRIBUTING.md component-guide.md configuration-guide.md integration-guide.md tincture-guide.md identity-guide.md devices-guide.md'
# The passphrase word list is BIP-0039's English list, third-party
# data pinned by its SHA-256 (internal/holder), not CYFR's words.
# The stand-in for Claude Code writes the line the harness itself
# writes for a session it holds no transcript of, word for word,
# since the catalyst reads those words: the harness's, not CYFR's.
# This script spells every pattern it refuses.
excl=':(exclude)**/node_modules/** :(exclude)**/package-lock.json :(exclude)**/priv/static/** :(exclude)apps/codex/internal/holder/bip39_english.txt :(exclude)tests/locus-backends-image/fake-claude.mjs :(exclude)scripts/ci/vocabulary.sh'
fail=0
# A path the list names that is gone, or a pattern git grep cannot
# read (exit 2 or more), fails: either would end that part of the
# scan silently.
for f in $paths; do
  [ -e "$f" ] || { echo "::error::the scanned path $f does not exist"; fail=1; }
done
for p in \
  '\borg_id\b' \
  '\bproject_id\b' \
  '\bnormalize_(org|project|athanor)_id\b' \
  '\bscope_type\b' \
  '\bno_org\b' \
  '\buser_active_in_org\?' \
  'Arca\.Schemas\.(Org|Project)\b' \
  'Sanctum\.Tenancy\.(Orgs|Projects|Memberships)\b' \
  'Compendium\.ProjectSeeder\b' \
  ':org([^a-z_]|$)' \
  ':project([^a-z_]|$)' \
  'CYFR_PRISM_' \
  ':4001\b|4001:4001' \
  'CYFR_PORTA_' \
  'cyfr-porta' \
  'apps/porta/' \
  '[Cc]onversation|CONVERSATION' \
  'topic_subscription|TopicSubscription' \
  'Cyfr\.Topics\b' \
  'prism:[a-z_]' \
  '[Cc]rucible|CRUCIBLE' \
  'apps/spawn/' \
  'cyfr-spawn' \
  'spawn_protocol\.json' \
  'CYFR_SPAWN_CHANNEL' \
  'cyfr-worker/v1' \
  'cyfr\.worker\.key' \
  '(^|[^A-Za-z])([Ss]pawners?([^a-z]|$)|SPAWNERS?([^A-Z]|$))|[a-z]Spawner' \
  'apps/opus\b' \
  '"apps", *"(opus|keeper)"' \
  'apps/\{([^},]*,)*(opus|keeper)[,}]' \
  'Dockerfile\.opus' \
  '\.env\.opus' \
  'cyfr-opus([^-A-Za-z0-9_]|$)' \
  '(^|[^A-Z0-9_])OPUS_' \
  '\bOPUS\b' \
  'CYFR_OPUS_(KEY|WORKERS|WATCH_)' \
  'wrk_opus' \
  'cyfr\.opus\.key' \
  'http:\\?/\\?/opus:' \
  '/app/bin/opus\b' \
  '/run/opus\b' \
  '/var/lib/opus\b' \
  '\bopus-runner' \
  'cyfr-opus-(canary|memory|namespace|runners|unbounded)\b' \
  '\bintegration/opus\b' \
  '"integration", *"opus"' \
  '\.\./opus/(lib|test)\b' \
  '\bworker-image\b' \
  'compose\.worker\.yml' \
  'opus-independence' \
  'LOCUS_BUILDS_LOG_' \
  'cyfr-keeper' \
  'apps/keeper\b' \
  'github\.com/cyfr/keeper\b' \
  'CYFR_WORKER_KEY' \
  'CYFR_WORKERS\b' \
  'CYFR_EXECUTION_EVENTS_' \
  'CYFR_MAX_CONCURRENT_EXECUTIONS' \
  'CYFR_WORKER_WATCH_' \
  '(^|[^A-Za-z])([Ee]states?([^a-z]|$)|ESTATES?([^A-Z]|$))|[a-z]Estate' \
  ; do
  status=0
  hits="$(git grep -In "$regex" "$p" -- $paths $excl)" || status=$?
  if [ "$status" -gt 1 ]; then
    echo "::error::fossil pattern $p could not be searched (git grep exited $status)"
    fail=1
  elif [ -n "$hits" ]; then
    echo "::error::fossil pattern $p"
    echo "$hits"
    fail=1
  fi
done
# Check athanor_id constraints in every migration. Only the baseline's
# sessions and decision_logs columns may be nullable.
# `grep -c` exits 1 when the count is zero and the job's shell is
# `bash -e`, so every count is guarded: an unguarded one on a
# migration that adds no athanor_id column would end the job there,
# silently, with every check below it unrun.
m=apps/arca/priv/repo/migrations/20260815000000_baseline.exs
nullable="$(grep -cE 'add :athanor_id' "$m" || true)"
notnull="$(grep -cE 'add :athanor_id.*null: false' "$m" || true)"
if [ "$((nullable - notnull))" -ne 2 ]; then
  echo "::error::exactly two nullable athanor_id columns are allowed (sessions, decision_logs); found $((nullable - notnull))"; fail=1
fi
for other in apps/arca/priv/repo/migrations/*.exs; do
  [ "$other" = "$m" ] && continue
  n="$(grep -cE 'add :athanor_id' "$other" || true)"
  nn="$(grep -cE 'add :athanor_id.*null: false' "$other" || true)"
  if [ "$n" -ne "$nn" ]; then
    echo "::error file=$other::athanor_id must be null: false outside the baseline (the two nullable fabrics are baseline-only)"; fail=1
  fi
done
if grep -nE 'add :athanor_id.*default:' apps/arca/priv/repo/migrations/*.exs; then
  echo "::error::athanor_id column with a default — a forgotten athanor must fail, never default into somebody's"; fail=1
fi
# Runtime storage stays under data/, which the repository ignores.
if ! grep -q '^/data/$' .gitignore; then
  echo "::error::.gitignore must ignore /data/"; fail=1
fi
# The template `cyfr init` writes ignores it too. Anchored as the
# .gitignore check above is: an unanchored '/data/' also matches the
# config template's `./data/cyfr.db` and a code comment, and would
# pass with the ignore entry itself deleted.
if ! grep -q '^/data/$' apps/codex/cmd/lifecycle.go; then
  echo "::error::lifecycle.go .gitignore template must ignore /data/"; fail=1
fi
# Each directory a guide's per-athanor storage diagram draws under
# an athanor's tree is a tenant root: Arca.Storage.tenant_roots/0,
# read from the @layout that builds it.
python3 -I scripts/ci/storage-diagrams.py README.md component-guide.md configuration-guide.md integration-guide.md tincture-guide.md identity-guide.md devices-guide.md || fail=1
# Tracked seed media holds the two seed roots alone.
if git ls-files 'seed/*' | grep -vE '^seed/(components|aqua)/' | grep -q .; then
  echo "::error::seed/ carries only its two roots, components/ and aqua/"; fail=1
fi
# The deployment shell spells the volume/seed layout outside Elixir
# — compose mounts, the Docker seed bake, the init template, the
# scaffold tarball. Witness each spelling so a layout rename in
# Arca.Storage cannot silently drift past them.
# A comment that mentions the spelling is not the spelling: whole-
# line comments are stripped first, so deleting the code a guard
# names fails even when a comment above it still names the string.
# No pipe: `grep -q` exits at the first match, and the strip
# upstream of it would then die of SIGPIPE, which `pipefail`
# reports as a failed pipeline although the string was found.
assert_spelling() {
  stripped="$(grep -vE '^[[:space:]]*(#|//)' "$1" || true)"
  case "$stripped" in
    *"$2"*) : ;;
    *) echo "::error::$1 does not spell '$2' — the deployment layout drifted from Arca.Storage"; fail=1 ;;
  esac
}
assert_spelling docker-compose.yml './data:/app/data'
assert_spelling docker-compose.yml './aqua:/app/seed/aqua'
assert_spelling Dockerfile 'CYFR_SEED_PATH=/app/seed'
assert_spelling Dockerfile 'COPY seed/components/'
assert_spelling docker-entrypoint.sh '/app/seed/aqua'
assert_spelling apps/codex/cmd/lifecycle.go '"data"'
assert_spelling apps/codex/cmd/lifecycle.go '"aqua"'
assert_spelling scripts/scaffold-tarball.sh '-C seed aqua'
# The prose surfaces (README.md, the six guides, the setup pages and
# the access vector's words and refusal templates, which `cyfr`
# prints) name the installation CYFR and the assistant Aqua, and
# carry none of the concept words home, hub, cell, door or glass
# where a person reads them: a cluster, a sign-in method and a
# device say so. "node" and "member" are not gated: each is also
# ordinary English and technical vocabulary (Node.js, a tree's or a
# graph's nodes, Tailscale's and Erlang's nodes, a person who is a
# member), so their installation and cluster senses are the
# reviewer's to check. In Markdown and in the vector a `code span`
# (delimited by a run of backticks, closed by a run of the same
# length) is not prose: an identifier, event name, wire field or
# command is spelled as the code spells it (`door.*`, a program's
# `home`), so the check skips code spans. In the setup pages a
# backtick delimits a JavaScript template literal, whose text a
# person reads, so it is scanned with only its ${...} placeholders
# taken out; a refusal template is likewise read with its `{slot}`
# placeholders taken out, since a slot is a payload key. The other
# exceptions, exact, all of the word home:
# - "Add to Home Screen": the phone's own wording for installing Prism.
# - $HOME and ${HOME}: the environment variable.
# - "home directory": the operating system's, a person's files.
# "Homebrew", UserHomeDir, home_dir and CYFR_CELL_COOKIE are not the
# words: the letters around each make it another word.
python3 -I - <<'PY' || fail=1
import json, re, subprocess, sys
def word(spelled):
    return re.compile(r"(?<![A-Za-z0-9_])(?:" + spelled + r")(?![A-Za-z0-9_])", re.I)
code = re.compile(r"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)")
placeholder = re.compile(r"\$\{[^}]*\}")
words = {
    "home": (word(r"homes?|home's"),
             re.compile(r"Add to Home Screen|\$\{?HOME\b\}?|\b[Hh]ome director(?:y|ies)\b")),
    "hub": (word(r"hubs?|hub's"), None),
    "cell": (word(r"cells?|cell's"), None),
    "door": (word(r"doors?|door's"), None),
    "glass": (word(r"glass(?:es)?|glass's"), None),
}
def found(where, text, markdown=True):
    bad = False
    for line in text.split("\n"):
        prose = code.sub("", line) if markdown else placeholder.sub("", line)
        for name, (pattern, stays) in words.items():
            if pattern.search(stays.sub("", prose) if stays else prose):
                print(f"::error::{where} says {name}: {line.strip()}")
                bad = True
    return bad
files = ["README.md", "devices-guide.md", "identity-guide.md", "configuration-guide.md",
         "integration-guide.md", "component-guide.md", "tincture-guide.md"]
files += subprocess.run(["git", "ls-files", "apps/codex/internal/setup/assets"],
                        capture_output=True, text=True, check=True).stdout.split()
bad = False
for path in files:
    data = open(path, "rb").read()
    if b"\0" in data:
        continue
    for n, line in enumerate(data.decode().split("\n"), 1):
        bad |= found(f"{path}:{n}", line, markdown=path.endswith(".md"))
vector = json.load(open("tests/fixtures/access_modes.json"))
for words_row in vector["words"]:
    for sentence in words_row["sentences"]:
        bad |= found("tests/fixtures/access_modes.json words", sentence)
for refusal in vector["refusals"]:
    for variant in refusal["variants"]:
        template = re.sub(r"\{[a-z_]+\}", "", variant["template"])
        bad |= found(f"tests/fixtures/access_modes.json refusals {refusal['code']}", template)
sys.exit(1 if bad else 0)
PY
exit $fail

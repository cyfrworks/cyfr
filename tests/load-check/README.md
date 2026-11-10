# The load check

`run.sh` measures whether a check still proves what it proves when it
runs on a quarter of this host's cores with the other quarters busy, or
beside a second copy of itself. `scripts/heavy-check.sh` places each
check on one of the same four quarters or on all four, and the answer
decides what each check takes:

- a whole-machine check may take two quarters when its busy run there
  takes less than about 2.5 times its run on the whole machine, and keeps
  four otherwise;
- a subject that fails busy and passes alone is fixed at its owner, or
  takes four quarters until it is.

The header of `run.sh` is the contract: the options, the table's columns,
the order of the runs, the statuses, the exits and the clean-up. This page
says how to run it and why the table holds what it holds.

## Running it

It takes the whole machine, so it runs only on all four of heavy-check's
quarters and refuses with 64 anywhere else:

```bash
tests/load-check/run.sh -n                      # the plan and its time, anywhere
scripts/heavy-check.sh -t 21600 -- tests/load-check/run.sh -s suite-sqlite,suite-postgres,gate,go-race
scripts/heavy-check.sh -t 86400 -- tests/load-check/run.sh -r 3
```

- `-s` picks subjects, `-c` conditions (`busy`, `pair`, `whole`, `alone`),
  `-r` rounds (one by default), `-o` the report directory (by default
  `/tmp/cyfr-evidence.load-check.XXXXXX`, which the janitor removes after
  seven days). `-n` prints every run's processors, what is warmed, and
  the expected time.
- A subject whose precondition fails is skipped with the reason before
  any work: the handle proof needs `CYFR_RUN_DIR` (a cyfr.run checkout),
  the PostgreSQL release boot `LOAD_CHECK_BOOT_DATABASE_URL` (any database
  on the server, as a role that may create databases: each run gets one
  of its own from `fresh-database.sh`), and the real-tailnet run
  `TAILNET_REAL_AUTH_KEY_FILE` and what `tests/tailnet-real/run.sh` names.
  A subject that exits 69, or 77 as the proxy HSTS proof does, is skipped
  with its own words: the install proof without its prepared image, the
  gate without cargo-component. A skipped subject never counts as passed;
  a run with a skip and no failure exits 69.
- The busy load needs the PostgreSQL server the test runs use and a
  Docker daemon; without either the check refuses with 69 before any work.

Run it again when the host, the table or the quarters change. Its report
goes in the pull request that acts on it.

## The runs

Each round runs, per subject, in this order:

| Condition | Subject on | Beside it |
|---|---|---|
| busy | its quarters | the busy load on every other quarter |
| pair | copy a on 1 to q, copy b on q+1 to 2q, from another worktree | each other |
| whole (the suites, the gate, `go test -race`) | all four quarters | nothing |
| alone, after a failed busy or pair run | its quarters | nothing |

The alone run tells a failure the load caused (FAILS BUSY) from a subject
that is broken anyway (fails alone). The busy load is one worker per
quarter the subject leaves, each in a worktree of its own, repeating a
save or handoff row's work, a forced `mix compile` and a one-partition
PostgreSQL run of `apps/arca/test`, and on the last of those quarters a
second worker repeating a cold build of the app image (`docker build
--no-cache`). A busy run in which a worker ended or a load step failed is
void, not passed.

A run's time is from its leader's start to its exit. Before a subject's
first run, the worktrees that run it are warmed, once each, with what that
first run would otherwise build: the suites' test build, go's race build,
and the release the release proofs start. The gate forces its own builds
and a harness self-test builds what it tests inside each run, so neither
is warmed. A warm row that fails in a worktree leaves every subject that
names it unmeasured: one void row names the warm row, and the run exits
1. A warm's scratch directory is named under the run's prefix, so the
run's clean-up removes it however the warm ended.

## Placement

The quarters are the host's whole cores, a core being one
`thread_siblings_list`, cut in order into four: on this host processors
`0,1,8,9`, `2,3,10,11`, `4,5,12,13` and `6,7,14,15`. Every command runs
under `taskset -c`, so `nproc`, the Erlang runtime and cargo see only its
processors; the suites and the gate pick their partitions by the gate's
rule for that count (the self-test holds the two rules together).

Each run is handed its processors as `HEAVY_CHECK_CPUS`. The browser
harness (`tests/browser/harness.sh`: the Playwright run and its library's
install) and the install proof (`tests/install-screen-proof/lib.sh`: the
KVM check, the base image's check and the guest) pass them to every
container they start as `--cpuset-cpus`, and change nothing without it.
The other proofs' containers are left where Docker puts them: the release
boot's PostgreSQL clients, the handle proof's registry and database, the
tincture proof's builds, the setup proof's Compose project and the proxy
HSTS proof's Caddy; so is the busy load's image build, which BuildKit
runs without a cpuset.

While each run goes, every 5 s, every process descended from its leader
must be allowed exactly its processors, and every container named under
its prefix that has a cpuset must have them; one that does not is named
in `masks.tsv` and voids the run. A container without a cpuset is listed
in `docker.tsv` as on any processor, beside the host's own containers:
with the host's services and the agents' own processes, the placement
this check does not hold.

## The subjects

`subjects.tsv` is the one list, each subject by its own entry point as the
workflow step or its README runs it. Its `expect` column is the median
time of the passing runs this host recorded before the quarters, doubled for
the four subjects that also run on the whole machine.

| Subjects | Quarters | Also | Warmed |
|---|---|---|---|
| `suite-sqlite`, `suite-postgres` | 2 | whole | the adapter's test build |
| `gate` | 2 | pair, whole | nothing |
| `go-race` | 2 | pair, whole | go's race build |
| `commit-gate-test`, `heavy-check-test`, `contain-test`, `stage-test`, `test-partitioned-test`, `partition-env-test`, `release-boot-test`, `access-test`, `ci-publish-test`, `install-verify-test`: every harness self-test a pull-request workflow runs and no handoff row does | 2 | pair | nothing |
| `canvas` (both viewports, the reference budget), `handle`, `join`, `pairing`, `identity`, `approval`, `file-offer`, `share`, `grant`, `hostile-frame`, `multi-home-smoke`, `tincture`, `frame-facts`, `release-boot-sqlite` | 1 | pair | the SQLite release |
| `release-boot-postgres` | 1 | pair | the PostgreSQL release |
| `install-screen`, `markdown`, `setup`, `proxy-hsts`, `tailnet-real` | 1 | pair | nothing |
| `compose` | 4 | listed, not measured: it publishes the fixed port `127.0.0.1:1055` | |

The gate's close is not a subject: it holds the host for hours and runs
only for a release with no run on GitHub.

## The report

`report.tsv` keeps every run: subject, round, condition, copy,
processors, status, exit, seconds, start and end, a note and the log. The
summary, printed last and kept as `report.txt`, gives per subject and
condition the runs passed and the median seconds of the passed runs, and
for the four whole-machine subjects `busy/whole`: the busy median on two
quarters over the whole-machine median, the ratio the 2.5 rule reads.

A subject's verdict is the first that applies of: a failed or stopped run
(`FAILS BUSY` when it failed busy or beside its copy and passed alone,
`fails alone`, `fails busy; alone not decided` when the alone run was
skipped or not chosen, `fails on the whole machine`); a void run (`not
decided`, naming a failed warm row); a skip (`skipped`). It `holds` only
when every run passed; a four-quarter subject is `not measured`. So no
later run hides an earlier one that was worse.

A line the check quotes from a subject or a precondition, and the
database helper's own messages, show a URL without its userinfo. The
subjects' own logs are theirs, as they wrote them.

## The scratch worktrees

`a` runs the subjects, `b` the second copy of a paired subject, `w1` to
`w3` the busy load: detached checkouts of the checkout's HEAD (uncommitted
changes are not measured) beside it, under the run's prefix, each with its
own sources, `_build` and `deps`, prepared cold by the table's prep rows
(the deps, then the deps compiled into each build path in turn). `a` is
prepared first, the others side by side; `prep.tsv` and `warm.tsv` record
what each cost. A warm checkout of this repository holds about 2 GB in
`_build` and `deps`, so the five take about 10 GB.

Every exit path, a signal and a deadline included, stops what the check
started, removes the Docker objects named under its prefixes, then the
worktrees and the `$TMPDIR` entries named under them. When a process
outlived its stop or a container could not be removed, the worktrees and
entries it may hold are kept and each is named. A worktree that a load
check that is gone left is removed at the next one's start. The image
builds' BuildKit cache cannot be told apart from anyone else's; the
janitor's rule 3 removes it after seven days unused.

## Expected time

From the dry run on this host, one round: about 4 h for the first
decisive run (the two suites, the gate, `go test -race`, the ten harness
self-tests, the canvas proof, and the install, join, pairing and SQLite
release-boot proofs), of which about 10 min prepare and 10 min warm; about
5 h 45 min for the whole list with the handle, PostgreSQL boot and
real-tailnet settings given. The times assume the four whole-machine
subjects take twice as long busy on two quarters; their real ratio is
what the run measures. An alone run after a failure adds its own time.

## The self-test

`run-test.sh` runs the check against stub subjects in a toy repository,
on four of the processors it may use, with a stand-in topology, a
stand-in `docker` and a stand-in release boot. Every check it makes is
shown failing on a copy of `run.sh` (or of the file it reads) with the
protection it checks taken out. The handoff runs it when the check, the
scripts it reads or the files it places change, and so does the pull
request's harness job. It never runs a real subject: the real run is
scheduled on the host, with the whole machine, by hand.

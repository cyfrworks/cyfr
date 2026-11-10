# The load check

`run.sh` measures whether a check still proves what it proves when it
runs on a quarter of this host's cores, with the other quarters busy or
holding a second copy of itself. Its answer decides whether the lanes of
`scripts/heavy-check.sh` can give way to four placed quarters:

- the quarters replace the lanes when no subject fails busy that passes
  alone;
- a check that takes the whole machine today takes two quarters when it
  runs less than about 2.5 times as long there as on the whole machine,
  and four otherwise;
- a subject that fails busy is fixed at its owner, or takes four quarters
  until it is.

The header of `run.sh` is the contract: options, the table's columns,
statuses, exits and clean-up. This page says how to run it and why the
table holds what it holds.

## Running it

It takes the whole machine for hours, so it runs only in heavy-check's
exclusive lane and refuses with 64 anywhere else:

```bash
tests/load-check/run.sh -n                      # the plan and the time, anywhere
scripts/heavy-check.sh -t 129600 -- tests/load-check/run.sh
scripts/heavy-check.sh -t 43200 -- tests/load-check/run.sh -r 1 -s suite-sqlite,suite-postgres,gate
```

- `-n` prints the quarters, the processors of every run, the subjects it
  skips and why, and the expected time, and runs nothing.
- `-s` picks subjects by name; `-r` sets the rounds (3 by default); `-o`
  names the report directory (by default
  `/tmp/cyfr-evidence.load-check.XXXXXX`, which the janitor removes after
  seven days).
- A subject whose precondition is not met is skipped with the reason
  before any work: the handle proof needs `CYFR_RUN_DIR` (a cyfr.run
  checkout), the PostgreSQL release boot `LOAD_CHECK_BOOT_DATABASE_URL`
  (an existing empty database, as `tests/release-boot/boot.sh` says), the
  real-tailnet run `TAILNET_REAL_AUTH_KEY_FILE` and the rest of what
  `tests/tailnet-real/run.sh` names. A subject that exits 69 in any run
  (the install proof without its prepared image, the gate without
  cargo-component) is skipped with its own last line. A skipped subject
  never counts as passed, and a run with one skipped and nothing failed
  exits 69.
- The busy load needs the PostgreSQL server the test runs use and a
  Docker daemon; without either the check refuses with 69 before any work.

Run it again when the host, the table or the lanes change. Its report
goes in the pull request that acts on it.

## The quarters

The host's whole cores, a core being one `thread_siblings_list`, are cut
in order into four equal quarters; both threads of a core are always in
one quarter, and cores left over run nothing of the check's. On this
host, 8 cores of 2 threads, the quarters are processors `0,1,8,9`,
`2,3,10,11`, `4,5,12,13` and `6,7,14,15`. Every command runs under
`taskset -c`, which every process it starts inherits: `nproc`, the Erlang
runtime and cargo see only those processors, so the gate on two quarters
picks four partitions by its own rule, two schedulers each.

While each run goes, every process descended from its leader is checked
against its processors every 5 s; one outside them is named in
`masks.tsv` and voids the run.

## The subjects

`subjects.tsv` is the one list. Each subject's command is the check's own
entry point, as the workflow step or the README runs it.

| Subjects | Quarters | Pair | Why |
|---|---|---|---|
| `suite-sqlite`, `suite-postgres` | 2 | no | the full suite on each adapter in the gate's shape |
| `gate` | 2 | yes | `scripts/commit-gate.sh` |
| `go-race` | 2 | yes | `go test ./... -race`, a whole-machine check today |
| `commit-gate-test`, `heavy-check-test`, `contain-test`, `stage-test`, `test-partitioned-test`, `partition-env-test`, `release-boot-test`, `access-test`, `ci-publish-test`, `install-verify-test` | 2 | yes | every harness self-test a pull-request workflow runs and no handoff row does |
| `canvas` | 1 | yes | both viewports, held to the reference host class's budget (`tests/canvas-proof/proof.mjs`), unchanged |
| `install-screen`, `handle`, `join`, `pairing`, `identity`, `approval`, `file-offer`, `share`, `grant`, `hostile-frame`, `multi-home-smoke`, `markdown`, `tincture`, `frame-facts`, `release-boot-sqlite`, `release-boot-postgres`, `setup`, `proxy-hsts`, `tailnet-real` | 1 | yes | every other proof |
| `compose` | 4 | no | listed, not measured: it publishes the compose file's fixed port `127.0.0.1:1055` |

The gate's close is not a subject: it holds the host for hours and is
run only for a release with no run on GitHub.

## The runs

Each subject first runs once unmeasured in each worktree that will run
it, so that every measured run starts warm. Then each round runs:

| Condition | Subject | The other quarters |
|---|---|---|
| alone | quarters 1 to q | idle |
| busy | quarters 1 to q | the busy load |
| pair | copy a on 1 to q, copy b on q+1 to 2q, from another worktree | idle |
| whole (two-quarter subjects) | all four quarters, as today | none |

The order turns by one each round. A run's time is from its leader's
start to its exit, the same in every condition.

The busy load is one worker per quarter the subject leaves, each in a
worktree of its own, repeating a save or handoff row's work: a forced
`mix compile` and a one-partition PostgreSQL run of `apps/arca/test`. On
the last of those quarters a second worker repeats a cold build of the
app image (`docker build --no-cache`). Each step is stopped at its row's
deadline. The subject starts once every worker has begun. A busy run in
which a worker ended or a load step failed while the subject ran is void,
not passed, and names the worker.

## The report

`report.tsv` keeps every run: subject, round, condition, copy,
processors, status (passed, failed, deadline, skipped, void), exit,
seconds, start and end times, a note and the log. The summary, printed
last and kept as `report.txt`, gives per subject and condition the runs
passed and the median seconds of the passed runs, and two ratios kept
apart:

- busy/alone and pair/alone: that condition's median over the alone
  median (pair counts both copies);
- two quarters/whole machine, for a two-quarter subject: the alone median
  over the whole median. This is the ratio the 2.5 rule reads.

A ratio with no passed run on one side is `n/a`. Each subject's verdict is
`holds`, `FAILS BUSY` (it passed alone and failed busy or beside its
pair), `fails alone`, `fails on the whole machine`, `not decided` (a run
was void) or `skipped`. The check exits 0 only when every selected
subject held.

## What it does not place

- What Docker runs: a container or an image build runs where the daemon
  puts it. The browser proofs' Playwright container, the install proof's
  VM and the busy load's image build all run outside every quarter.
  `docker.tsv` lists each container a run started with its cpuset, and
  the host's other containers at the start.
- The host's services: every worktree uses the one `cyfr-postgres` and
  the one object store, as today.
- The agents and their harnesses, and anything the host runs besides.

## The scratch worktrees

`a` runs the subjects, `b` the second copy of a paired subject, `w1` to
`w3` the busy load. Each is a detached checkout of the checkout's HEAD
(uncommitted changes are not measured), beside the checkout under its run
prefix (`cyfr-<seed>-<pid>-load-check-<role>`), with its own sources,
`_build` and `deps`. Each is prepared cold by the table's prep rows: the
deps, then the deps compiled into each build path one at a time, as the
gate does before its legs. `a` is prepared first, then the others side by
side; `prep.tsv` and the summary record what each cost. A warm checkout
of this repository holds about 2 GB in `_build` and `deps`, so the five
take about 10 GB beside the checkout while the check runs.

Every exit path, a signal and a deadline included, stops what the check
started, removes the Docker objects and `$TMPDIR` entries named under its
prefixes, then the worktrees. A worktree that a load check that is gone
left is removed at the next one's start. What the check cannot remove is
named on stderr and makes the exit 1. The image builds' BuildKit cache
cannot be told apart from anyone else's; the janitor's rule 3 removes it
once it has gone unused for seven days.

## Expected time

The dry run's estimate counts each run at the table's `expect`, the
median of this host's passing runs in today's lanes, doubled for a
subject that moves from the whole machine to two quarters, so it is high
for the whole-machine runs. On this host, without the handle proof's,
the PostgreSQL boot's and the real tailnet's settings:

- the whole list, 3 rounds: about 33 h; 1 round: about 13 h;
- a first decisive run (the two suites, the gate, the harness self-tests,
  the canvas, install, handle, join and pairing proofs and both release
  boots), 1 round: about 13 h with the handle and boot settings given;
- preparation: the table's estimate is 18 min for `a`, then about as long
  for the other four side by side; it is high, since a cold SQLite test
  build of a fresh worktree, two test files included, took 67 s on five
  processors in this change's handoff.

## The self-test

`run-test.sh` runs the check against stub subjects in a toy repository,
on four of the processors it may use, with a stand-in topology and a
stand-in `docker`. Every check it makes is shown failing on a copy of
`run.sh` with the protection it checks taken out. The handoff runs it
when `tests/load-check/` or the libraries it sources change, and so does
the pull request's harness job. It never runs a real subject: the real
run is scheduled on the host, with the whole machine, by hand.

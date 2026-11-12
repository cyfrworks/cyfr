# Contributing to CYFR

Thanks for your interest in improving CYFR. Issues and pull requests are
welcome.

## Licensing of contributions (inbound = outbound)

CYFR uses **mixed per-file licensing** (see [`LICENSE`](LICENSE) and
[`FAIR_SOURCE.md`](FAIR_SOURCE.md)). Contributions are accepted under the
license of the **file being changed**:

- Files under `apps/sanctum/**` are **FSL-1.1-Apache-2.0**. Contributions
  to those files are made under FSL-1.1-Apache-2.0.
- Every other file is **Apache-2.0**. Contributions to those files are made
  under Apache-2.0.

By submitting a contribution, you agree to license it under the license that
already applies to the file(s) you change. There is no separate CLA and no
sign-off requirement.

## New files

Open every source file with the SPDX header that matches the directory it
lives in, after a shebang line if it has one, in the file's own comment
syntax:

```
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
```

(use `FSL-1.1-Apache-2.0` only for files inside `apps/sanctum/`).

The `license-lint` workflow enforces this boundary on every pull request for
Elixir, Go, WIT, the console's JavaScript and the backends image suite — a
missing or wrong header fails CI.

## Running from source

`scripts/dev-stack.sh`, from the checkout, runs CYFR from source the way an
install runs it: Prism, the server and live reload from `mix phx.server`,
the runtime, the backends service (stdio MCP servers) and the builds
service in their containers under `cyfr-locus`, each with the shipped
security options and its egress guard, run from this tree's Locus image,
and a cyfr.run of its own on this machine as its registry and account
service. Besides the setup the next section names (the pinned
`wasm-tools`, the prebuilt binaries and the tailwind CLI), it needs Docker
with its compose plugin, `python3`, `openssl`, a host that allows
unprivileged user namespaces (`docker-compose.yml`'s `locus-runtime`
service says why), and a checkout of
[cyfr.run](https://github.com/cyfrworks/cyfr.run) beside this one
(`../cyfr.run`), or wherever `DEV_STACK_CYFR_RUN` names.

**The local cyfr.run.** A CYFR always names a registry and calls it, and
development takes the release's path: the loop's server names
`cyfr.test` as its registry, `registry.cyfr.test` as its OCI registry and
`https://cyfr.test` as its account service, whatever `.env` says, and
prints them as it starts. They are cyfr.run's own local stack (Caddy, the
`cyfrrun` server, Zot and its PostgreSQL, as that checkout's
`docker-compose.yml` merges them), run under the compose project
`cyfr-run-dev`, which serves both names on `127.0.0.1:443`. It is built
and run from the checkout's committed HEAD: the loop exports that
commit's tracked files into
`~/.local/state/cyfr-dev-stack/cyfr-run/<commit>` and runs compose there,
and prints the commit as it starts. An uncommitted change in the
checkout is not in the stack, and a new commit there rebuilds it at the
next start. Nothing in the export reaches outside it: the loop refuses a
commit holding a symbolic link, or a compose file binding a path, whose
real path leaves the export, and it removes only the exports it made
(named for a commit and holding its marker), naming anything else it
finds there. A `.env` that is tracked in that repository is exported with
the rest and can enter the builder's cache; the loop's own env file keeps
it out of the services. The accounts, names and components a loop makes exist
there alone, and nothing the loop does reaches the public cyfr.run. A
`mix` boot outside the loop names the public cyfr.run, as a release does,
unless `.env` names others: the loop is how a developer stays local.
Nothing is seeded: a new athanor's components ship with CYFR, so a fresh
sign-in pulls nothing, and `cyfr push` publishes into the local registry
when that is what you test. Its admin pages are at
https://cyfr.test/admin; the first administrator is made once at
`https://cyfr.test/admin/bootstrap?token=<ADMIN_TOKEN>`, the token the
loop mints into the machine's dev-stack directory,
`~/.local/state/cyfr-dev-stack/cyfr-run.env` (under `XDG_STATE_HOME` when
it is set, mode 0700), beside the copy of Caddy's certificate authority,
`cyfr-run-root.crt`. Nothing is written into the cyfr.run checkout, and
none of its untracked files, its `.env` among them, reaches the stack or
its images.

One machine runs one local cyfr.run, shared by every worktree's loop: a
loop starts it when it is not running and leaves it running when it
stops, and no worktree's `down` stops it. `docker compose -p cyfr-run-dev
down` stops it for good and keeps its accounts;
`docker compose -p cyfr-run-dev down -v` resets it, deleting every
account, name and component in it.

Three things are set once per machine, with administrator rights; the
loop checks each and never does it, and refuses with the command until it
is done:

- both names resolve to 127.0.0.1 alone (`::1` beside it is accepted), and to no other address:
  `echo '127.0.0.1 cyfr.test registry.cyfr.test' | sudo tee -a /etc/hosts`;
- Docker publishes `127.0.0.1:443`, which rootful Docker and Docker
  Desktop do as they are; rootless Docker needs
  `echo net.ipv4.ip_unprivileged_port_start=443 | sudo tee /etc/sysctl.d/90-cyfr-dev.conf && sudo sysctl --system`
  (443, since the account pages' addresses name no port);
- the operating system trusts Caddy's certificate authority, which the
  server's TLS reads (the loop prints the command: on Debian and Ubuntu,
  `sudo cp ~/.local/state/cyfr-dev-stack/cyfr-run-root.crt /usr/local/share/ca-certificates/cyfr-test-root.crt && sudo update-ca-certificates`;
  on macOS, `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/.local/state/cyfr-dev-stack/cyfr-run-root.crt`),
  and so does the browser that signs in, which the loop cannot see:
  Chrome and Chromium on Linux read their own store,
  `certutil -d sql:$HOME/.pki/nssdb -A -t C,, -n cyfr-test -i ~/.local/state/cyfr-dev-stack/cyfr-run-root.crt`
  (libnss3-tools), and Firefox its profile's. A reset of the local
  cyfr.run makes a new authority, to trust again.

**A start.** On its first run the loop makes `.env` mode 0600 and writes
into it what a `mix` boot needs and nothing sets: `CYFR_SETUP_TOKEN`, the
runtime root and the backends key, minted as `cyfr init` mints them. Later
runs keep every value. The builds key, which a `mix` boot refuses without
the builds URL only the stack sets, is minted for each run unless `.env`
sets one. It then builds the tree's Locus image with `scripts/image.sh`
when the host does not hold it already (every worktree at the same inputs
shares one), starts the containers, and runs `mix phx.server` in the
foreground at http://localhost:4000. The run that writes the setup token
prints the setup link, `http://localhost:4000/setup#<token>`, as `cyfr
init` does: it asks for a name and a passkey at the local cyfr.run's
account pages, which set up CYFR's first person, who administers it, and
shows their recovery code. Prism and the server reload as their files
change; a change under `apps/locus` or to the Locus image's other inputs
takes effect at the next start. Ctrl-C stops the server and removes the
worktree's containers; the image stays, so a start with nothing changed
builds nothing. The image is shared, so the janitor, not the loop, removes
it once no worktree produces it and no loop uses it: run
`scripts/janitor.sh --dry-run` to see what it would remove, then
`scripts/janitor.sh` to remove it by hand. `scripts/dev-stack.sh down`
stops the server and removes the containers a killed run of the same
worktree left.

A dev database's people are bound to the local cyfr.run their accounts
were made at, since every account names its account service. The loop
writes a random id once into the local cyfr.run's PostgreSQL volume; a
new database records it in `data/dev-stack/cyfr-run.id`, and a database
that is not new refuses to start when the running local cyfr.run has
another id (it was reset, or an older copy of its volume was put back),
or when it has none (it was made beside the stand-in an earlier loop
ran), since its people's accounts are not there; the refusal names the
ways out. A `down -v` leaves no way back, so delete the dev database
(`data/cyfr.db` unless `.env` names another) to start afresh.
`docker compose -p cyfr-run-dev down -v && rm -f data/cyfr.db*` resets
both; every other worktree's database then refuses in the same way.

Each worktree runs a loop of its own, beside the others, a test suite, a
proof or a CI-style run on the same host. Its containers are named
`cyfr-dev-<seed>`, the worktree's seed, and its ports and networks are a
slot's, one of twenty. The first loop on a host keeps
http://localhost:4000, so a lone worktree sees no change; a second
worktree's loop takes the next free slot, Prism on 4010 and so on, and
prints its address, which the worktree remembers in
`data/dev-stack.slot` for its next run. A `.env` that sets `CYFR_PORT` or
another address of the stack refuses a slot it disagrees with, by name.
With an API key from Prism's API Keys page, or the session token of a
`cyfr login`, `CYFR_TOKEN=<key> scripts/dev-stack.sh check` runs a
component through the worktree's running loop and asserts its answer.

AQUA answers in its panel once a model provider's key is in the vault, as on
any install. While a worktree's loop runs, a second start or `down` in the
same worktree refuses, naming the run that holds it.

## Before opening a PR

- Consult [`ARCHITECTURE.md`](ARCHITECTURE.md) when deciding ownership,
  changing a layer edge, a port or an invariant, or resolving an unclear
  architectural contract. A change to a principle, a layer edge, a port or an
  invariant changes that document in the same pull request.
- Keep changes focused and match the surrounding code style.
- Every component is validated by the pinned `wasm-tools`, which the dev
  and test configurations name at `_tools/wasm-tools`, and the application
  refuses to start without it: install it once with
  `scripts/wasm-tools.sh install _tools` (`scripts/test-partitioned.sh`
  installs it when it is missing).
- After `mix deps.get` in a fresh checkout, and after a change to
  `mix.lock`, run `scripts/fetch-prebuilt-binaries.sh` before the first
  compile, and `scripts/fetch-prebuilt-binaries.sh --tailwind` before the
  first `mix assets.deploy` or dev server: neither the deps' precompiled
  NIFs (wasmex's, exqlite's and lazy_html's) nor the tailwind CLI download
  through the deps' own downloads, and the script's header says why.
- The tests tagged `:requires_cargo_component` build real components, and
  the test helpers exclude them where `cargo-component` is not on `PATH`.
  CI runs them on both adapters, so install it
  (`cargo install cargo-component --locked`) with the `wasm32-wasip1` and
  `wasm32-wasip2` targets on rustup's default toolchain: a build runs
  outside the checkout, where `rust-toolchain.toml` does not choose the
  toolchain. `scripts/commit-gate.sh` looks for it in
  `${CARGO_HOME:-~/.cargo}/bin` and on `PATH`, and refuses to run without it.
- Checks run in stages. `scripts/stages.tsv` names what each stage runs,
  and `scripts/stage.sh STAGE` runs it, queuing each check through
  `scripts/heavy-check.sh` for the quarters the table names. In `save`
  and `handoff` the checks that use one build folder (`_build/dev`,
  `dev_pg`, `test` or `test_pg`, the table's folder column) run one after
  another and the rest side by side, so one stage can hold all four
  quarters for a while; every other stage runs its checks one after
  another. A stage's summary lists every check in the table's order. The
  host answers while you edit and keeps itself; GitHub proves the tree:
  - `save`, after an edit: the format and credo checks, an incremental
    compile with warnings as errors, and the touched tests on SQLite;
  - `handoff`, before you report a change ready, one quarter for each
    check: the format and credo checks, a forced compile on both
    adapters, the generated files' checks, the touched tests on both
    adapters (all of `apps/arca/test` when Arca changed), the roster
    tests that read the whole source tree (the boundaries, the test seams,
    Sanctum's gate rosters, the restore order, the cross-language drift and
    the router's route map)
    and CI's vocabulary scan (`scripts/ci/vocabulary.sh`) on every change,
    the configuration check when an `apps` source changed, `mix dialyzer`
    when a `lib` file changed, the light self-test of every harness
    script you touched, and the install proof when its inputs changed.
    Each app compiled and tested alone (CI's island jobs), the proofs
    under `tests/` and the suites' untouched files are the pull request's
    run's;
  - `pull-request`: the pull request's run on GitHub is the check, and it
    runs every check in parallel. `scripts/stage.sh pull-request` runs
    `scripts/commit-gate.sh`, CI's checks on this host, for working
    offline or reproducing a failing CI job;
  - `release`: the gate's close, which holds the host for over an hour,
    run by `scripts/release.sh --gate` for a HEAD with no run on GitHub;
  - `nightly`: `scripts/janitor.sh`, then the install proof and the handle
    proof, which no workflow runs, each on one quarter, then the canvas
    proof at both viewports on all four with its reference budget. The host's
    timer runs it once a day on main's head through `scripts/nightly.sh`, which
    reports the night to GitHub (the nightly, below).

  The touched tests are the changed test files and, for each changed or
  deleted `apps/<app>/lib/<path>.ex`, `apps/<app>/test/<path>_test.exs`
  where it exists; name others after `--`. `scripts/stage.sh -n STAGE`
  lists what it would run. A branch stacked on another sets `STAGE_BASE`
  to that branch, so the handoff stage runs its own changes alone rather
  than everything since `origin/main`.

  The self-tests that need the whole machine, those a workflow runs and
  no handoff row does, and `go test ./... -race` are the pull request's
  run's alone: a defect in one shows there. To have one's answer before
  the pull request, run it here by name on all four quarters, as its
  workflow step runs it:
  `scripts/heavy-check.sh bash tests/commit-gate-test.sh`, or
  `scripts/heavy-check.sh bash -c 'cd apps/codex && go test ./... -race'`.
- A release tag is cut on a tree its run on GitHub proved green, and
  that run is the release's proof: `scripts/release.sh`, which runs only
  on origin's main head (a detached checkout of it will do), reads HEAD's
  check runs through `gh` before it tags HEAD, or HEAD plus a bump commit
  holding the version lines alone, which the tag's own workflow checks
  again before it publishes; `--push` pushes main and the tag together,
  by full refs, in one atomic push. `--gate` is the fallback for a HEAD with no
  run: it runs the release stage, the gate's close, here first. Right
  before it tags it runs the dependency audits again
  (`scripts/dependency-audit.sh`, the same ones CI runs), because the
  advisory feeds they read change independently of the tree, and a tag
  whose own run fails them publishes nothing. The gate's
  header lists what it runs and which of CI's checks stay CI's alone.
  Besides `cargo-component` it needs `go` at the version both `go.mod`
  files name and a running Docker daemon, and it refuses to run without
  them; it installs `govulncheck` and the close's `trivy` itself, at the
  versions CI pins.
- `scripts/heavy-check.sh` queues the checks of everyone sharing a host.
  It cuts the machine's cores into four quarters of whole cores. A check
  takes all four by default and runs alone: a gate, a full or
  multi-partition suite, `go test -race`, a harness self-test that needs
  the machine, the canvas proof, the compose proof. With `-q 1` it takes
  one quarter: named test paths in one partition, a compile, dialyzer,
  credo, a light self-test, any other browser proof or an install proof,
  an image suite or build, a release boot. Four of those run side by
  side, each on its own quarter's processors, which it is told as
  `HEAVY_CHECK_CPUS` for the containers it starts. Checks start in the
  order they queued, none past an earlier one, and
  `scripts/heavy-check.sh --status` shows who holds which quarters and
  who waits.
- `tests/load-check/run.sh` measures whether each check still passes, and
  how much slower it runs, on a quarter of the host's cores beside busy
  neighbours or a second copy of itself. It takes the whole machine for
  hours: `tests/load-check/run.sh -n` prints the plan and its time, `-s`,
  `-c` and `-r` bound a run to subjects, conditions and rounds, and
  `scripts/heavy-check.sh -t 28800 -- tests/load-check/run.sh` runs it,
  again whenever the host, its subject table or the quarters change
  (`tests/load-check/README.md`).
- Local runs take the Locus and app images from `scripts/image.sh locus`
  and `scripts/image.sh app`, which tag each by a hash of its inputs, so
  every checkout at the same inputs shares one build.
  `scripts/janitor.sh --dry-run` lists what the nightly janitor would
  remove.
- The nightly runs on GitHub (`.github/workflows/nightly.yml`), each day
  at 02:37 Taipei time and on demand: one run of the Test workflow on
  main's head under its `nightly` input, in which each test shard runs
  its suite twice with the timing formatter, then a job that runs
  `scripts/lib/nightly.py` over every shard's two runs. Its summary and artifacts carry the flake list
  (each test that failed in one run and passed in the other, or failed in
  both) and the regenerated `scripts/test-partition-weights.tsv`. When
  the table differs from the tracked one, the job force-pushes it, on
  main's head, to the branch `nightly/weights` and prints the
  `gh pr create` command for its owner: a pull request opened with the
  job's own token would get no Test run. The weights are seconds on CI's
  four-vCPU runners, relative, which is all the split reads.
- The host has a nightly of its own, from a user timer at about 04:00,
  in two checkouts kept for the timer alone: `~/Projects/cyfr-nightly`, a
  detached worktree of this repository, and `~/Projects/cyfr.run-nightly`,
  a detached worktree of a cyfr.run checkout, which the handle proof builds
  its registry from (`CYFR_RUN_DIR`). Nobody works in either: before each
  night the unit moves both to their origin's main and removes whatever
  else they hold but ignored build output. `scripts/nightly.sh` then runs
  the nightly stage there, the janitor and the host's proofs,
  and triggers `.github/workflows/host-nightly.yml` with the commit, the
  stage's exit, its row lines and its logs' path on the host. That run
  fails unless the exit is 0, a check that did not run included, and
  GitHub tells the account that triggered it, the one `gh` is logged in as
  here, of a failed run as of any it triggered. The workflow's watchdog
  fails each day no report has arrived from the host within 26 hours, as
  after a night the unit could not fetch, which runs and reports nothing. A
  host sets it up by making the two worktrees (`git -C ~/Projects/cyfr
  worktree add --detach ~/Projects/cyfr-nightly origin/main`, and the same
  from its cyfr.run checkout), logging `gh` in with the workflow scope, and
  copying these two units into `~/.config/systemd/user/` with its own
  paths and the PATH its `mix`, `go` and `gh` are on, then `systemctl
  --user enable --now cyfr-nightly.timer` (with `loginctl enable-linger`
  it runs without a session). `systemctl --user start cyfr-nightly` runs a
  night by hand:

  ```ini
  # cyfr-nightly.service
  [Unit]
  Description=CYFR nightly: the janitor and the host's proofs (scripts/nightly.sh)

  [Service]
  Type=oneshot
  WorkingDirectory=%h/Projects/cyfr-nightly
  Environment=PATH=%h/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin
  Environment=CYFR_RUN_DIR=%h/Projects/cyfr.run-nightly
  ExecStartPre=git -C %h/Projects/cyfr-nightly fetch -q origin
  ExecStartPre=git -C %h/Projects/cyfr-nightly checkout -q --detach --force origin/main
  ExecStartPre=git -C %h/Projects/cyfr-nightly clean -q -f -d
  ExecStartPre=git -C %h/Projects/cyfr.run-nightly fetch -q origin
  ExecStartPre=git -C %h/Projects/cyfr.run-nightly checkout -q --detach --force origin/main
  ExecStartPre=git -C %h/Projects/cyfr.run-nightly clean -q -f -d
  ExecStart=%h/Projects/cyfr-nightly/scripts/nightly.sh

  # cyfr-nightly.timer
  [Unit]
  Description=CYFR nightly at about 04:00

  [Timer]
  OnCalendar=*-*-* 04:00
  RandomizedDelaySec=10min
  Persistent=true

  [Install]
  WantedBy=timers.target
  ```
- Run the tests for what you touched as operating-system partitions:
  `scripts/test-partitioned.sh <test paths>` on SQLite, and
  `scripts/test-partitioned.sh -a postgres <test paths>` on PostgreSQL.
  CI runs the whole suite on both, each across four runners: `--shard I/N`
  runs only shard I's partitions of the whole split, so a shard is CI's
  split of the suite between machines, not the local one, which runs it
  whole. After a run,
  `scripts/test-partitioned.sh -- --failed` with the same `-a` reruns
  exactly the failures every partition recorded: each adapter keeps its
  record under its own build path. `mix test --failed` reads SQLite's;
  it reaches PostgreSQL's only with
  `MIX_BUILD_PATH=_build/test_pg CYFR_DATABASE=postgres`. The split
  weighs each file by `scripts/test-partition-weights.tsv`, which the
  nightly regenerates; to regenerate it by hand, with the table in place
  (a file's timing does not depend on the split), make two runs of
  `CYFR_TEST_TIMINGS_DIR=<absolute dir> scripts/test-partitioned.sh -n 8 -- --formatter ExUnit.CLIFormatter --formatter Prima.Test.TimingFormatter`,
  each into a fresh directory, and keep each file's larger
  `elixir scripts/test-timings.exs weights <dir>` value, as its header
  says.
- If you changed a `@spec` or a function's return shape, run `mix dialyzer`.
  CI runs it too. It is fast once the PLT is built, and the findings it
  reports are recorded in [`.dialyzer_ignore.exs`](.dialyzer_ignore.exs)
  — fixing one means deleting its line and its reason there, since a filter
  that matches nothing also fails the build.
- Don't describe the product as "open source" in user-facing copy — it is
  "Fair Source" / "source available" (see [`FAIR_SOURCE.md`](FAIR_SOURCE.md)).

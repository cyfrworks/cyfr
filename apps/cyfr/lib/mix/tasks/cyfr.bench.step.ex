# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.Bench.Step do
  @shortdoc "Measure the per-step latency of a turn's model step"

  @moduledoc """
  Runs model steps through the real turn loop and execution path against
  a streaming stub catalyst and prints the p50, p95 and p99 of each step's
  spans (`Crucible.StepSpans`): admission, the guest's first delta,
  time to first delta, completion and the whole `run_child`, with the
  commit, the mode, the database and storage adapters in use and what the
  bench's upstream received. Before its first delta every step makes one
  request for one byte to an upstream the bench serves on loopback;
  `--mode` decides how that request travels. `Cyfr.Test.StepBench`
  describes what one step runs.

      mix cyfr.bench.step                       # attached, 200 steps after 20 warmup
      mix cyfr.bench.step --mode pinned
      mix cyfr.bench.step --steps 50 --warmup 5

  Options:

    * `--mode attached|pinned` — `attached` (the default) names the stub's
      connection, so CYFR makes the request with the key attached;
      `pinned` makes the same request without a connection or credential,
      so CYFR pins it and the worker service makes it. Both modes lay the
      same manifest and bind the same attach-only key, so the difference
      between them is the attached request's own hop.
    * `--steps N` — measured steps (positive, default 200)
    * `--warmup N` — unmeasured steps run first, which compile the stub
      and fill the caches (non-negative, default 20)

  The bench runs in the test environment, from the umbrella root: the
  athanor is built from test fixtures inside one SQL sandbox checkout of
  the test database and rolled back, so nothing it writes outlives it.
  `mix cyfr.bench.step` selects `MIX_ENV=test` and migrates the test
  database first. On Postgres, name the database and a build path of its
  own:

      CYFR_DATABASE=postgres CYFR_DATABASE_URL=postgres://… \\
        MIX_BUILD_PATH=_build/test_pg mix cyfr.bench.step

  Every write lands in the sandbox's one open transaction, so the numbers
  carry each statement's cost but not a commit's (a synchronous write's
  flush to disk). Numbers from a loaded machine are indicative only.
  """

  use Boundary, classify_to: Cyfr.Mix

  use Mix.Task

  # The harness is test support, compiled only under MIX_ENV=test.
  @compile {:no_warn_undefined, Cyfr.Test.StepBench}

  @switches [mode: :string, steps: :integer, warmup: :integer]
  @modes %{"attached" => :attached, "pinned" => :pinned}
  @usage "usage: mix cyfr.bench.step [--mode attached|pinned] [--steps N] [--warmup N]"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [], do: Mix.raise(@usage)

    steps = Keyword.get(opts, :steps, 200)
    warmup = Keyword.get(opts, :warmup, 20)
    mode = Map.get(@modes, Keyword.get(opts, :mode, "attached"))

    if mode == nil, do: Mix.raise("--mode is attached or pinned\n" <> @usage)

    if steps < 1 or warmup < 0,
      do: Mix.raise("--steps must be positive and --warmup non-negative")

    if Mix.env() != :test,
      do: Mix.raise("mix cyfr.bench.step runs under MIX_ENV=test (it is #{Mix.env()})")

    Mix.Task.run("app.start")

    if not Code.ensure_loaded?(Cyfr.Test.StepBench),
      do:
        Mix.raise(
          "mix cyfr.bench.step runs from the umbrella root, where its harness is compiled"
        )

    report = Cyfr.Test.StepBench.run(steps: steps, warmup: warmup, mode: mode)
    Mix.shell().info(Cyfr.Test.StepBench.render(report))
  end
end

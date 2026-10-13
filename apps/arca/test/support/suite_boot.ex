# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.SuiteBoot do
  @moduledoc """
  What every database app's `test_helper.exs` does before its suite runs,
  in one place: arca's, sanctum's and cyfr's each call `boot!/1` once,
  after their own blocks, with their app's options.

  An umbrella run evaluates each app's helper in one VM, one after
  another, and `ExUnit.after_suite/1` callbacks accumulate there: one
  registered by the first helper runs after every later app's suite too.
  So the storage roots are made by every boot, since the cleanup after the
  previous app's suite removed them, and the cleanup is registered once
  per VM, under a `:persistent_term` key; `boot!/1` refuses to go on when
  the callback list holds it more than once.
  """

  @cleanup_key {__MODULE__, :roots}

  @doc """
  Prepare the suite's process-wide state and its database.

  Options:

  - `:seed` (required) — a zero-arity function committing the athanor rows
    the fixtures name by hand (`Arca.Test.Actor.seed_athanors!/0`,
    `Sanctum.TestContext.seed_athanors!/0`).
  - `:stand_ins` — when true (arca's and sanctum's own builds, which have
    no host), mint the boot identity and install the persistence suite's
    unit locators when nothing has. Default false: in cyfr's suite the
    host's boot has done both.
  - `:seed_templates` — shipped templates under the repository's `seed/`
    copied into the throwaway seed tree, so template reads stay real
    without the suite touching the repository's own tree. Default `[]`.
  """
  @spec boot!(keyword()) :: :ok
  def boot!(opts) when is_list(opts) do
    seed = Keyword.fetch!(opts, :seed)

    if Keyword.get(opts, :stand_ins, false), do: install_stand_ins!()

    # Owned by the test-runner process so it outlives every test and no
    # two tests race to create it. `Prima.Test.SourceTree` fills it lazily.
    Prima.Test.SourceTree.ensure_table()

    {base_path, seed_path} = make_roots!(Keyword.get(opts, :seed_templates, []))

    # A suite database built from a different schema would run stale,
    # since the baseline still reads as applied; refuse it before any test
    # touches it.
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, &Arca.SchemaFingerprint.verify!/0)

    # Every connection is lent by a test's sandbox owner, and never taken
    # by a process on its own: in the pool's default automatic mode a
    # process no test allowed (the decision log's writer, spawned from an
    # asynchronous test) is handed a real connection and its rows commit
    # for the tests after it to see.
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)

    # The athanor rows the fixtures name by hand, committed once for the run.
    seed.()

    register_cleanup!(base_path, seed_path)
  end

  @doc """
  The after-suite cleanup: removes the two storage roots the first boot
  made, as they were named then. Tests point both keys elsewhere while
  they run (the repository's own `seed/` among those places), and a run
  stopped mid-test would remove whatever the key named at that moment.
  """
  @spec cleanup(term()) :: :ok
  def cleanup(_suite_result) do
    {base_path, seed_path} = :persistent_term.get(@cleanup_key)
    File.rm_rf(base_path)
    File.rm_rf(seed_path)
    :ok
  end

  @doc "How many times the cleanup is registered in this VM: 1 after any boot."
  @spec cleanups() :: non_neg_integer()
  def cleanups do
    cleanup = &__MODULE__.cleanup/1
    :ex_unit |> Application.get_env(:after_suite, []) |> Enum.count(&(&1 == cleanup))
  end

  # Independent app suites have no host: preserve an umbrella boot's
  # identity, and install the unit locators only when nothing has. An
  # umbrella run's boot installed the component domain's locators and
  # keeps them; a build of the contracts and the persistence app alone
  # has no component domain, and installs the suite's stand-ins.
  defp install_stand_ins! do
    try do
      Prima.Boot.id()
    rescue
      Prima.Boot.NotInitializedError -> Prima.Boot.mint()
    end

    try do
      Arca.Storage.UnitLocator.impl!()
    rescue
      Arca.Storage.UnitLocator.NotInstalledError ->
        Arca.Storage.UnitLocator.install!(Arca.Test.UnitLocator.locators())
    end

    :ok
  end

  # The throwaway storage roots `config/test.exs` names: the tenant root,
  # and a seed tree with an empty bundle plus the templates asked for.
  defp make_roots!(templates) do
    base_path = Application.fetch_env!(:arca, :base_path)
    File.mkdir_p!(base_path)

    seed_path = Application.fetch_env!(:arca, :seed_path)
    File.mkdir_p!(Path.join(seed_path, "components"))

    for template <- templates do
      File.cp_r!(Path.join(repository_seed(), template), Path.join(seed_path, template))
    end

    {base_path, seed_path}
  end

  defp repository_seed, do: Path.expand("../../../../seed", __DIR__)

  defp register_cleanup!(base_path, seed_path) do
    unless :persistent_term.get(@cleanup_key, nil) do
      :persistent_term.put(@cleanup_key, {base_path, seed_path})
      ExUnit.after_suite(&__MODULE__.cleanup/1)
    end

    case cleanups() do
      1 -> :ok
      count -> raise "the suite's storage cleanup is registered #{count} times in this VM"
    end
  end
end

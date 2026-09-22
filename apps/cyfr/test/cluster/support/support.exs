# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cluster.Support do
  @moduledoc """
  Loads this suite's own modules, and remembers their compiled form so
  each member can be given it.

  The modules live in `.exs` files under `test/cluster/support`, which is
  not on any `elixirc_paths`: they are the two-node suite's alone, and a
  single-node run must not pay to compile them. A member node therefore
  has no beam to load them from — `Cyfr.Cluster.Cell` pushes the binaries
  this module holds, which is also what lets a case send a closure to a
  member, since a function term is decoded only where its module exists at
  the same version.

  Compilation happens once per run, on the first cluster case, and its
  result is kept in `:persistent_term`: `Code.compile_file/1` both
  compiles and loads, and compiling twice would redefine every module.
  """

  @files ~w(wait.exs store.exs observer.exs wire.exs barrier.exs boot.exs fixtures.exs cell.exs)

  @key {__MODULE__, :modules}

  @doc "Compile and load this suite's modules, once for the run."
  @spec load!() :: :ok
  def load! do
    _ = modules()
    :ok
  end

  @doc "Every module of this suite, as `{module, binary}` for a member to load."
  @spec modules() :: [{module(), binary()}]
  def modules do
    case :persistent_term.get(@key, nil) do
      nil ->
        compiled = Enum.flat_map(@files, &Code.compile_file(&1, dir()))
        :persistent_term.put(@key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  defp dir, do: Path.expand(".", __DIR__)
end

defmodule Cyfr.Cluster.Case do
  @moduledoc """
  The two-node suite's case template: one real cell, healed before each
  case.

  Every case is `async: false` — there is one cell, one Postgres database
  and one object store for the run — and tagged `:cluster`, which the
  suite excludes unless it is asked for, because a cell costs two
  operating-system processes and a full application boot.

  The cell is **healed before** a case rather than after one: a case that
  fails leaves its members exactly as it left them, for a reader to look
  at, and the next case pays for putting them back.
  """

  use ExUnit.CaseTemplate

  @compile {:no_warn_undefined, [Cyfr.Cluster.Cell, Cyfr.Cluster.Observer]}

  using do
    quote do
      alias Cyfr.Cluster.{Barrier, Cell, Fixtures, Observer, Wait, Wire}

      # This suite's own modules are compiled by `setup_all` rather than
      # by the compiler, so at the moment a case is compiled none of them
      # exists yet. The one that would catch a typo is the case's own
      # first run, which is where every other mistake in it shows too.
      @compile {:no_warn_undefined,
                [
                  Cyfr.Cluster.Barrier,
                  Cyfr.Cluster.Boot,
                  Cyfr.Cluster.Cell,
                  Cyfr.Cluster.Fixtures,
                  Cyfr.Cluster.Observer,
                  Cyfr.Cluster.Wait,
                  Cyfr.Cluster.Wire
                ]}

      @moduletag :cluster
      @moduletag timeout: 300_000
    end
  end

  setup_all do
    Cyfr.Cluster.Support.load!()
    Cyfr.Cluster.Observer.start!()
    members = Cyfr.Cluster.Cell.ensure!()
    {:ok, members: members}
  end

  setup do
    {:ok, members: Cyfr.Cluster.Cell.heal!()}
  end
end

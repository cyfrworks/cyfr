# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.DispatchBoundaryTest do
  @moduledoc """
  `Sanctum.Gate` is the one admission entry, and `Sanctum.Dispatch` runs
  what it admits.

  No production module but `Sanctum.Gate` names `Sanctum.Dispatch`, in
  any app of the umbrella, Sanctum's own included, and `Sanctum.Catalog`,
  which holds the table, exports neither dispatching entry. The compiled
  beams are the reader (`Prima.Test.Beams`): a module's atom table holds
  every module it calls or names as a literal and its literal table every
  capture, so a call through an alias or an import, a capture and an
  `apply/3` on the literal module are seen,
  while a name inside a string or a doc is not. `dispatch/4` is private,
  so an export check alone would hold vacuously; the reach is what is
  read, and a planted module shows each spelling reported.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.Beams

  @dispatch Sanctum.Dispatch
  @entry Sanctum.Gate
  @apps ~w(prima arca sanctum locus cyfr)a

  test "only the gate names the dispatch" do
    beams = production_beams()

    for app <- @apps,
        do: assert(Map.has_key?(beams, app), "no production beam of #{app} was read")

    offenders =
      for {_app, modules} <- beams,
          {module, beam} <- modules,
          module not in [@dispatch, @entry],
          names?(beam),
          do: "#{inspect(module)} names #{inspect(@dispatch)}: #{inspect(reaches(beam))}"

    assert offenders == [],
           "dispatch is reached past the gate — admit through #{inspect(@entry)}:\n" <>
             Enum.join(offenders, "\n")

    # The gate's own delegation is the reach the scan must see, so a
    # passing scan is reading dispatch and not an empty table.
    gate = beams |> Map.fetch!(:sanctum) |> Map.fetch!(@entry)

    assert Enum.sort(reaches(gate)) == [
             {@dispatch, :call_external, 4},
             {@dispatch, :call_in_chain, 5}
           ]
  end

  test "the catalog exports neither dispatching entry" do
    assert {:module, Sanctum.Catalog} = Code.ensure_loaded(Sanctum.Catalog)

    exported =
      for {function, arity} <- Sanctum.Catalog.__info__(:functions),
          function in [:call_external, :call_in_chain],
          do: {function, arity}

    assert exported == [],
           "Sanctum.Catalog exports #{inspect(exported)}: the table dispatches nothing, " <>
             "and a second public entry is a second admission path"
  end

  # `uncertain_message/2` dispatches nothing: it is the one definition, on
  # its producer, of the sentence an unanswered handler's call answers
  # with, and only tests name it (the component guide's drift check,
  # `Cyfr.DocsDriftTest`). The beam scan above, which lets no production
  # module but `Sanctum.Gate` name `Sanctum.Dispatch`, is unchanged.
  test "the dispatch exports the two entries and the uncertain sentence, nothing else" do
    assert {:module, @dispatch} = Code.ensure_loaded(@dispatch)

    assert Enum.sort(@dispatch.__info__(:functions)) == [
             call_external: 3,
             call_external: 4,
             call_in_chain: 4,
             call_in_chain: 5,
             uncertain_message: 2
           ]
  end

  test "a planted call, alias, import, capture or apply is reported, a string and a gate call are not" do
    compiled =
      Code.compile_string(~S'''
      defmodule Sanctum.PlantedDispatchDirect do
        def plant(ctx, args), do: Sanctum.Dispatch.call_external("t", ctx, args)
      end

      defmodule Sanctum.PlantedDispatchAlias do
        alias Sanctum.Dispatch
        def plant(ctx, args, authority), do: Dispatch.call_in_chain("t", ctx, args, authority)
      end

      defmodule Sanctum.PlantedDispatchImport do
        import Sanctum.Dispatch, only: [call_external: 4]
        def plant(ctx, args), do: call_external("t", ctx, args, [])
      end

      defmodule Sanctum.PlantedDispatchCapture do
        def plant, do: &Sanctum.Dispatch.call_in_chain/5
      end

      defmodule Sanctum.PlantedDispatchApply do
        def plant(ctx, args), do: apply(Sanctum.Dispatch, :call_external, ["t", ctx, args])
      end

      defmodule Sanctum.PlantedDispatchString do
        @moduledoc "Calls `Sanctum.Dispatch.call_external/4` — in words only."
        def plant, do: "Sanctum.Dispatch.call_external(\"t\", ctx, args)"
      end

      defmodule Sanctum.PlantedGateCall do
        def plant(ctx, args), do: Sanctum.Gate.call_external("t", ctx, args)
      end
      ''')

    for {module, _beam} <- compiled do
      :code.purge(module)
      :code.delete(module)
    end

    reported = for {module, beam} <- compiled, into: %{}, do: {module, names?(beam)}

    assert reported == %{
             Sanctum.PlantedDispatchDirect => true,
             Sanctum.PlantedDispatchAlias => true,
             Sanctum.PlantedDispatchImport => true,
             Sanctum.PlantedDispatchCapture => true,
             Sanctum.PlantedDispatchApply => true,
             Sanctum.PlantedDispatchString => false,
             Sanctum.PlantedGateCall => false
           }

    reaches = for {module, beam} <- compiled, into: %{}, do: {module, reaches(beam)}
    assert reaches[Sanctum.PlantedDispatchCapture] == [{@dispatch, :call_in_chain, 5}]
    assert reaches[Sanctum.PlantedDispatchImport] == [{@dispatch, :call_external, 4}]
  end

  # Every production beam of the umbrella's applications, by app, as
  # `%{module => path}`; test support compiled into the same ebin is left
  # out.
  defp production_beams do
    for app <- @apps,
        dir = :code.lib_dir(app),
        is_list(dir),
        path <- Path.wildcard(Path.join([to_string(dir), "ebin", "Elixir.*.beam"])),
        Beams.production?(path),
        reduce: %{} do
      acc ->
        module =
          path
          |> Path.basename(".beam")
          |> String.replace_prefix("Elixir.", "")
          |> List.wrap()
          |> Module.safe_concat()

        Map.update(
          acc,
          app,
          %{module => String.to_charlist(path)},
          &Map.put(&1, module, String.to_charlist(path))
        )
    end
  end

  # Whether the beam names the dispatch module in its code: the atom table
  # holds every module a call, an import or a literal names, and an
  # external capture is a fun in the literal table (`Prima.Test.Beams`).
  defp names?(beam) do
    {:ok, {_module, [atoms: atoms]}} = :beam_lib.chunks(beam, [:atoms])

    Enum.any?(atoms, fn {_index, atom} -> atom == @dispatch end) or reaches(beam) != []
  end

  defp reaches(beam) do
    for {module, _function, _arity} = reach <- Beams.reaches(beam),
        module == @dispatch,
        uniq: true,
        do: reach
  end
end

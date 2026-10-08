# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ToolSeamTest do
  @moduledoc """
  `Aqua.Ops` is the assistant's one door onto the gate's dispatch — the
  same contract `PrismWeb.ToolSeamTest` pins for the console.

  The assistant reads the operation table wherever it needs to
  (`Aqua.Kinds`, `Aqua.Hands`, the loop's policy); what it does not do is
  dispatch past the seam. `Grimoire.call_external` and
  `Grimoire.call_in_chain`, and the `Grimoire.Catalog` functions they
  delegate to, are called or captured by `Aqua.Ops` alone. The compiled
  beams are the reader (`Prima.Test.Beams`), so a call through an alias
  or an import and a capture are seen and a name inside a string is not,
  and a planted module shows each spelling reported.

  The assistant naming the transport (`Emissary`) is the Boundary
  compiler's refusal, shown failing in `Cyfr.BoundariesTest.CompilerPlants`.
  """

  use ExUnit.Case, async: true

  alias Prima.Test.Beams

  @seam Aqua.Ops
  @gate [Grimoire, Grimoire.Catalog]
  @dispatch [:call_external, :call_in_chain]

  test "the assistant dispatches through the gate only at its seam" do
    beams = assistant_beams()
    assert beams != [], "no assistant beam was read"

    offenders =
      for {module, beam} <- beams,
          module != @seam,
          {callee, function, arity} <- dispatches(beam),
          do: "#{inspect(module)} reaches #{inspect(callee)}.#{function}/#{arity}"

    assert offenders == [],
           "the assistant dispatches past its seam — go through #{inspect(@seam)} " <>
             "(or grow it), never the gate directly:\n" <> Enum.join(offenders, "\n")

    # The seam itself makes the reach, so the scan is reading dispatch and
    # not passing on an empty read.
    seam = Enum.find_value(beams, fn {module, beam} -> module == @seam and beam end)
    assert seam, "#{inspect(@seam)} has no beam"
    assert dispatches(seam) != [], "#{inspect(@seam)} dispatches nothing: the reader sees no call"
  end

  test "a planted call, alias, import or capture is reported and a string is not" do
    compiled =
      Code.compile_string(~S'''
      defmodule Aqua.PlantedDirect do
        def plant(ctx, args), do: Grimoire.call_external("t", ctx, args)
      end

      defmodule Aqua.PlantedAlias do
        alias Grimoire, as: Gate
        def plant(ctx, args, authority), do: Gate.call_in_chain("t", ctx, args, authority)
      end

      defmodule Aqua.PlantedImport do
        import Grimoire, only: [call_external: 4]
        def plant(ctx, args), do: call_external("t", ctx, args, [])
      end

      defmodule Aqua.PlantedCapture do
        def plant, do: &Grimoire.Catalog.call_external/3
      end

      defmodule Aqua.PlantedString do
        def plant, do: "Grimoire.call_external(\"t\", ctx, args)"
      end
      ''')

    for {module, _beam} <- compiled do
      :code.purge(module)
      :code.delete(module)
    end

    reported = for {module, beam} <- compiled, into: %{}, do: {module, dispatches(beam)}

    assert reported == %{
             Aqua.PlantedDirect => [{Grimoire, :call_external, 3}],
             Aqua.PlantedAlias => [{Grimoire, :call_in_chain, 4}],
             Aqua.PlantedImport => [{Grimoire, :call_external, 4}],
             Aqua.PlantedCapture => [{Grimoire.Catalog, :call_external, 3}],
             Aqua.PlantedString => []
           }
  end

  # Every production beam of the assistant, `Aqua` and `Aqua.*`, as
  # `{module, path}`; test support compiled into the same ebin is left out.
  defp assistant_beams do
    for path <-
          :cyfr
          |> Application.app_dir("ebin")
          |> Path.join("Elixir.Aqua*.beam")
          |> Path.wildcard(),
        name = path |> Path.basename(".beam") |> String.replace_prefix("Elixir.", ""),
        name == "Aqua" or String.starts_with?(name, "Aqua."),
        Beams.production?(path),
        do: {Module.concat([name]), String.to_charlist(path)}
  end

  # The gate dispatch `beam` calls or captures.
  defp dispatches(beam) do
    for {module, function, arity} <- Beams.reaches(beam),
        module in @gate,
        function in @dispatch,
        uniq: true,
        do: {module, function, arity}
  end
end

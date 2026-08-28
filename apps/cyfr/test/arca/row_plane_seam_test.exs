# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RowPlaneSeamTest do
  @moduledoc """
  Who is allowed to talk to the database.

  The blob plane has had this for a while: every `File.*` outside the
  storage adapters must carry an `arca:bypass-ok` tag, and CI greps for it.
  The row plane had the same convention by habit and nothing enforcing it —
  and habit is exactly what `Emissary.MCP.Tools.RecordsProvider` drifted
  out of, writing `from(e in Arca.Execution, …) |> Arca.Repo.all()` inline
  for two of its actions. Tenancy was applied correctly there, so nothing
  was exposed; what was wrong is that an MCP tool handler had become a
  query layer, and the next one to need a query would have copied it.

  Rows belong to `Arca` (its schemas and `*Storage` modules) and to
  `Sanctum`, whose tenancy fabric — users, memberships, athanors, the door
  — is its own domain rather than a storage concern. The surfaces do not
  reach past them.
  """

  use ExUnit.Case, async: true

  # Namespaces that render or route, and must ask a domain module for rows.
  #
  # `apps/cyfr/lib/cyfr` is DELIBERATELY absent: the glue namespace holds
  # boot, the write-behind sink and the retention sweep — infrastructure
  # that batches rows for the domain modules rather than serving a surface.
  # Its repo touches are covered by the arca-side seams
  # (`Arca.UnscopedQuerySeamTest`, `Arca.DbRescueCoverageTest` for what it
  # reaches through Arca modules), not by this roster.
  @surface_dirs ~w(
    apps/cyfr/lib/emissary
    apps/cyfr/lib/emissary_web
    apps/cyfr/lib/prism
    apps/cyfr/lib/prism_web
    apps/cyfr/lib/aqua
    apps/cyfr/lib/compendium
  )

  # The liveness probe: readiness has to prove the database answers, and
  # "ask a storage module to read something" would prove a table instead.
  @allowed %{
    "apps/cyfr/lib/emissary_web/controllers/health_controller.ex" => 1
  }

  defp root, do: Path.expand("../../../..", __DIR__)

  defp repo_calls do
    @surface_dirs
    |> Enum.flat_map(fn dir ->
      root() |> Path.join(dir) |> Path.join("**/*.ex") |> Path.wildcard()
    end)
    |> Enum.flat_map(fn path ->
      hits =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
        |> Enum.count(&String.match?(&1, ~r/\bArca\.Repo\./))

      if hits > 0, do: [{Path.relative_to(path, root()), hits}], else: []
    end)
    |> Map.new()
  end

  test "the rendering and routing surfaces do not query the database" do
    found = repo_calls()
    unexpected = Map.drop(found, Map.keys(@allowed))

    assert unexpected == %{},
           """
           These surface modules call Arca.Repo directly:

           #{Enum.map_join(unexpected, "\n", fn {file, n} -> "  #{file} (#{n} call(s))" end)}

           Put the query on the schema's own module (Arca.Execution,
           Arca.*Storage) or on the Sanctum module that owns those rows, and
           call that. A handler that grows its own Ecto is a second data
           layer with none of the tenancy conventions attached to it.
           """
  end

  test "the one allowed exception still needs its exception" do
    found = repo_calls()

    for {file, count} <- @allowed do
      assert found[file] == count,
             "#{file} is allowed #{count} Arca.Repo call(s) but has #{inspect(found[file])} — " <>
               "update the roster and say why"
    end
  end
end

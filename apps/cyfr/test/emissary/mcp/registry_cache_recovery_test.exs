# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RegistryCacheRecoveryTest do
  @moduledoc """
  The MCP catalogues live in `Arca.Cache`, which dies with its owner.

  `Arca.Cache.Sweeper` owns the table; `ToolRegistry` and `ResourceRegistry`
  sit below it in a `:rest_for_one` group, so a sweeper crash restarts the
  registries with it and their init repopulates the fresh table. Without
  that coupling the failure was silent: both registries write their
  catalogue once at boot and refresh every 23 hours, and `Arca.Cache.get/1`
  rescues the missing table into an ordinary miss — every tool read as
  "Unknown tool" for up to a day.
  """

  use ExUnit.Case, async: false

  alias Emissary.MCP.ResourceRegistry
  alias Cyfr.Ops.Catalog

  # The registries wait on the sweeper's restart before rebuilding.
  defp wait_until(fun, remaining \\ 200)

  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, remaining - 1)
    end
  end

  test "the tool catalogue survives losing the cache table with its owner" do
    tools_before = Catalog.list_tools()
    refute tools_before == [], "no tools registered — the fixture proves nothing"

    owner = Process.whereis(Arca.Cache.Sweeper)
    assert is_pid(owner)

    # Exactly what a sweep that raises would do to the table.
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 5_000

    assert wait_until(fn ->
             is_pid(Process.whereis(Arca.Cache.Sweeper)) and
               Catalog.list_tools() != []
           end),
           "the tool catalogue stayed empty after the cache table was lost"

    # And the entries are usable, not just present.
    name = Catalog.list_tools() |> hd() |> Map.fetch!("name")
    assert {:ok, _} = Catalog.lookup(name)
  end

  test "the resource catalogue is rebuilt too" do
    refute ResourceRegistry.list_resources() == []

    owner = Process.whereis(Arca.Cache.Sweeper)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 5_000

    assert wait_until(fn ->
             is_pid(Process.whereis(Arca.Cache.Sweeper)) and
               ResourceRegistry.list_resources() != []
           end),
           "the resource catalogue stayed empty after the cache table was lost"
  end
end

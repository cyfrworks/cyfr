# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RegistryCacheRecoveryTest do
  @moduledoc """
  The MCP catalogues live in `Arca.Cache`, which dies with its owner.

  The cache sweeper and registries form a rest_for_one group. A sweeper
  restart must restart the registries and repopulate their catalogs.
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

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RegistryCacheRecoveryTest do
  @moduledoc """
  The MCP catalogues live in `Arca.Cache`, which dies with its owner.

  `Arca.Cache.Sweeper` owns the table; `ToolRegistry` and `ResourceRegistry`
  are its siblings under a `:one_for_one` tier, so a sweeper crash restarts
  the sweeper alone and the table comes back empty. Both registries write
  their catalogue once at boot and refresh it every 23 hours — and
  `Arca.Cache.get/1` rescues the missing table into an ordinary miss — so
  the failure is silent: every tool reads as "Unknown tool" until the next
  refresh, up to a day later.
  """

  use ExUnit.Case, async: false

  alias Emissary.MCP.ResourceRegistry
  alias Emissary.MCP.ToolRegistry

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
    tools_before = ToolRegistry.list_tools()
    refute tools_before == [], "no tools registered — the fixture proves nothing"

    owner = Process.whereis(Arca.Cache.Sweeper)
    assert is_pid(owner)

    # Exactly what a sweep that raises would do to the table.
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 5_000

    assert wait_until(fn ->
             is_pid(Process.whereis(Arca.Cache.Sweeper)) and
               ToolRegistry.list_tools() != []
           end),
           "the tool catalogue stayed empty after the cache table was lost"

    # And the entries are usable, not just present.
    name = ToolRegistry.list_tools() |> hd() |> Map.fetch!("name")
    assert {:ok, _} = ToolRegistry.lookup(name)
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

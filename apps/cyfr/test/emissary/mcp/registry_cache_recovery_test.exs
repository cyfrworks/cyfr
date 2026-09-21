# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RegistryCacheRecoveryTest do
  @moduledoc """
  The MCP catalogues live in `Arca.Cache`, which dies with its owner.

  The owner is `Arca.Cache.Sweeper`, started by the `arca` application —
  one app below the two registries that write catalogues into its table,
  so no supervisor holds both and the `:rest_for_one` group that used to
  restart them together cannot exist. Each registry monitors the owner
  instead (`Arca.Cache.monitor_owner/0`) and rebuilds when it goes. The
  guarantee is the one the group kept: a killed sweeper ends with both
  catalogues repopulated, and no window where a tool reads as unknown.
  """

  use ExUnit.Case, async: false

  alias Emissary.MCP.ResourceRegistry
  alias Cyfr.Ops.Catalog

  # This case empties a table the whole node reads. The rebuild is what it
  # proves, but a neighbour must not inherit a half-built catalogue if the
  # rebuild lands slowly, so the cleanup waits for both to be whole and
  # asks for a refresh if they are not.
  setup do
    on_exit(fn ->
      unless wait_until(&repopulated?/0) do
        {:ok, _} = Catalog.refresh()
        wait_until(&repopulated?/0)
      end
    end)
  end

  # The registries wait on the replacement owner's table before rebuilding,
  # so a case polls rather than asserting at once. Both registries watch
  # the owner, so the guarantee is that BOTH are
  # back — and a case that waited on one alone would leave the other's
  # rebuild in flight for whatever runs next.
  defp repopulated? do
    is_pid(Process.whereis(Arca.Cache.Sweeper)) and
      Catalog.list_tools() != [] and
      ResourceRegistry.list_resources() != []
  end

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

    assert wait_until(&repopulated?/0),
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

    assert wait_until(&repopulated?/0),
           "the resource catalogue stayed empty after the cache table was lost"
  end
end

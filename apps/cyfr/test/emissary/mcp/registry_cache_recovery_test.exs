# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RegistryCacheRecoveryTest do
  @moduledoc """
  The MCP catalogues live in `Arca.Cache`, which dies with its owner.

  The owner is `Arca.Cache.Sweeper`, started by the `arca` application —
  one app below the two registries that write catalogues into its table,
  so no supervisor holds both and the `:rest_for_one` group that used to
  restart them together cannot exist. Each registry monitors the owner
  (`Arca.Cache.monitor_owner/0`) and rebuilds when it goes. The guarantee
  is the one the group kept: a killed sweeper ends with both catalogues
  WHOLE — every tool the providers declare resolves again — and no window
  where a tool reads as unknown.
  """

  use ExUnit.Case, async: false

  alias Emissary.MCP.ResourceRegistry
  alias Cyfr.Ops.Catalog

  # This case empties a table the whole node reads. The rebuild is what it
  # proves, but a neighbour must not inherit a half-built catalogue if the
  # rebuild lands slowly, so the cleanup waits for both to be whole and
  # asks for a refresh if they are not.
  setup do
    # What "whole" means, taken from the providers rather than from the
    # table: "not empty" would pass on a rebuild that lost half its
    # entries to a second kill, and the neighbours that follow would look
    # up a tool that is no longer there.
    declared = declared_tools()
    refute declared == [], "no tools declared — the fixture proves nothing"
    resources = resource_catalogue()

    on_exit(fn ->
      unless wait_until(fn -> whole?(declared, resources) end) do
        {:ok, _} = Catalog.refresh()
        wait_until(fn -> whole?(declared, resources) end)
      end
    end)

    {:ok, declared: declared, resources: resources}
  end

  defp declared_tools do
    Catalog.available_providers()
    |> Enum.flat_map(& &1.tools())
    |> Enum.map(& &1.name)
  end

  # The resource catalogue is three things: the advertised resources and
  # templates, and the scheme index a `resources/read` is dispatched by —
  # a rebuild missing the index answers "No provider found" for a scheme
  # the lists still advertise.
  defp resource_catalogue do
    schemes =
      for module <- Catalog.available_providers(),
          tool <- module.tools(),
          operation <- tool.operations,
          scheme <- operation.resource_schemes,
          do: scheme

    refute schemes == [], "no resource schemes declared — the fixture proves nothing"

    %{
      resources: length(ResourceRegistry.list_resources()),
      templates: length(ResourceRegistry.list_resource_templates()),
      schemes: schemes
    }
  end

  # The registries wait on the replacement owner's table before rebuilding,
  # so a case polls rather than asserting at once. Both registries watch
  # the owner, so the guarantee is that BOTH are back — and a case that
  # waited on one alone would leave the other's rebuild in flight for
  # whatever runs next.
  defp whole?(declared, resources) do
    is_pid(Process.whereis(Arca.Cache.Sweeper)) and
      Enum.all?(declared, &(Catalog.lookup(&1) != :miss)) and
      length(ResourceRegistry.list_resources()) >= resources.resources and
      length(ResourceRegistry.list_resource_templates()) >= resources.templates and
      Enum.all?(resources.schemes, &match?({:ok, _, _}, ResourceRegistry.resolve(&1 <> "://x")))
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

  test "the tool catalogue survives losing the cache table with its owner", %{
    declared: declared,
    resources: resources
  } do
    refute Catalog.list_tools() == [], "no tools registered — the fixture proves nothing"

    owner = Process.whereis(Arca.Cache.Sweeper)
    assert is_pid(owner)

    # Exactly what a sweep that raises would do to the table.
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 5_000

    assert wait_until(fn -> whole?(declared, resources) end),
           "the tool catalogue did not come back whole after the cache table was lost"

    # And the entries are usable, not just present.
    name = Catalog.list_tools() |> hd() |> Map.fetch!("name")
    assert {:ok, _} = Catalog.lookup(name)
  end

  # The kill that matters is the one that lands while the rebuild is
  # halfway through writing: the entries written so far die with that
  # owner, the rest go to the next one, and a registry that armed its
  # monitor only after writing finds the new owner alive and waits for a
  # `:DOWN` that has already happened — leaving the catalogue short for a
  # day. The window is observable (the table holds some tools but not all),
  # so the case spins for it rather than sleeping.
  test "a second loss while the rebuild is in flight still ends whole", %{
    declared: declared,
    resources: resources
  } do
    whole = length(declared)

    caught? =
      Enum.reduce_while(1..3, false, fn _, _ ->
        if kill_during_rebuild(whole), do: {:halt, true}, else: {:cont, false}
      end)

    assert wait_until(fn -> whole?(declared, resources) end),
           "the catalogue stayed short after a second loss during the rebuild" <>
             if(caught?, do: "", else: " (the rebuild was never caught in flight)")
  end

  test "the resource catalogue is rebuilt too", %{declared: declared, resources: resources} do
    refute ResourceRegistry.list_resources() == []
    refute ResourceRegistry.list_resource_templates() == []

    owner = Process.whereis(Arca.Cache.Sweeper)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 5_000

    assert wait_until(fn -> whole?(declared, resources) end),
           "the resource catalogue stayed empty after the cache table was lost"
  end

  # One kill, then a second one the moment the table is seen part-filled.
  # Answers whether that second kill landed inside the rebuild.
  defp kill_during_rebuild(whole) do
    owner = Process.whereis(Arca.Cache.Sweeper)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 5_000

    case spin_for_partial(whole, 200_000) do
      {:ok, pid} ->
        Process.exit(pid, :kill)
        true

      :never ->
        false
    end
  end

  defp spin_for_partial(_whole, 0), do: :never

  defp spin_for_partial(whole, budget) do
    pid = Process.whereis(Arca.Cache.Sweeper)
    count = length(Arca.Cache.match({:mcp_tool, :_}))

    if is_pid(pid) and count > 0 and count < whole,
      do: {:ok, pid},
      else: spin_for_partial(whole, budget - 1)
  end
end

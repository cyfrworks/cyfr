# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.SettingsTest do
  @moduledoc """
  The platform settings on two real members: two operators' writes
  serialize through the store revision, a pin on one member reaches the
  other through the store, a disagreeing pin refuses a boot naming both
  members, and a member that died holding a pin has it retired by the
  next claim of its slot.

  A member's environment pins are what `config/runtime.exs` records in
  `:deployment_pinned`; a case writes that key on a member and restarts
  the member's application, which is the boot that reads it.
  """

  use Cyfr.Cluster.Case, async: false

  alias Cyfr.Platform.Settings

  # The accessor's cache bound, and the slack a delivery takes on a loaded
  # machine.
  @converge_ms 30_000 + 10_000

  setup do
    ctx = Cell.call(:a, Sanctum, :system_context, [])

    on_exit(fn ->
      # Whatever a case left pinned or stopped, the next one starts from
      # fresh members, and from a store with none of these rows.
      for id <- [:a, :b], do: Cell.kill(id)
      Cell.heal!()

      for key <- ["device_label", "mcp_rate_limit_max"] do
        {:ok, _} = Cell.call(:a, Settings, :reset, [ctx, key])
      end
    end)

    {:ok, ctx: ctx}
  end

  defp node_of(id), do: id |> Cell.member() |> Map.fetch!(:node) |> Atom.to_string()

  defp effective(id, key), do: Cell.call(id, Arca.PlatformSettings, :effective, [key])

  defp listed(id, key) do
    {:ok, listing} = Cell.call(id, Settings, :list, [])
    {listing, Enum.find(listing.settings, &(&1.key == key))}
  end

  # Restart `id`'s application under `pins`: its slot is released at the
  # stop and taken again, under a new generation, by the start.
  defp restart(id, pins) do
    :ok = Cell.call(id, Cyfr.Cluster.Boot, :stop!, [])
    :ok = Cell.call(id, Application, :put_env, [:cyfr, :deployment_pinned, pins])
    Cell.call(id, Cyfr.Cluster.Boot, :start!, [Cell.member(id).worker], 180_000)
  end

  test "two operators saving at once on two members: one write stands, the other is stale",
       %{ctx: ctx} do
    {:ok, %{revision: read}} = Cell.call(:a, Settings, :list, [])

    results =
      [a: "from-a", b: "from-b"]
      |> Enum.map(fn {id, value} ->
        Task.async(fn ->
          {value, Cell.call(id, Settings, :set, [ctx, "device_label", value, [revision: read]])}
        end)
      end)
      |> Task.await_many(60_000)

    assert [{winner, {:ok, %{revision: written}}}] =
             Enum.filter(results, &match?({_, {:ok, _}}, &1))

    assert [{_loser, {:error, :stale}}] = Enum.filter(results, &match?({_, {:error, _}}, &1))
    assert written == read + 1

    # Both members read the write that stood, and each says it saw it.
    for id <- [:a, :b] do
      Wait.until!(
        fn -> effective(id, "device_label") == {:ok, winner} end,
        "member #{id} did not converge on the write that stood",
        @converge_ms
      )
    end

    Wait.until!(
      fn ->
        {listing, _} = listed(:a, "device_label")
        Enum.all?(listing.members, &(is_integer(&1.revision) and &1.revision >= written))
      end,
      "a member's observed revision was not reported",
      @converge_ms
    )
  end

  test "a pin on one member reaches the other, and a disagreeing pin refuses a boot naming both",
       %{ctx: ctx} do
    a = node_of(:a)
    b = node_of(:b)

    assert restart(:b, [{"mcp_rate_limit_max", 77}]) == :ok

    # The unpinned member reads the pinned value through the store.
    Wait.until!(
      fn -> effective(:a, "mcp_rate_limit_max") == {:ok, 77} end,
      "the unpinned member did not converge on the pin",
      @converge_ms
    )

    {_listing, entry} = listed(:a, "mcp_rate_limit_max")

    assert %{source: "deployment", desired: 77, divergent: true, pins: [%{member: ^b, value: 77}]} =
             entry

    assert Cell.call(:a, Settings, :set, [ctx, "mcp_rate_limit_max", "10"]) == {:error, :pinned}

    # The same key pinned to another value on a second member refuses its
    # boot, and the refusal names the key and both members.
    assert {:error, reason} = restart(:a, [{"mcp_rate_limit_max", 88}])
    refusal = inspect(reason, limit: :infinity, printable_limit: :infinity)
    assert refusal =~ "mcp_rate_limit_max"
    assert refusal =~ a
    assert refusal =~ b

    # The same value agrees, and the two members show no divergence.
    assert restart(:a, [{"mcp_rate_limit_max", 77}]) == :ok
    {_listing, entry} = listed(:a, "mcp_rate_limit_max")
    assert %{divergent: false} = entry
    assert Enum.sort(Enum.map(entry.pins, & &1.member)) == Enum.sort([a, b])
  end

  test "a member that dies holding a pin has it retired by the next claim of its slot" do
    b = node_of(:b)
    assert restart(:b, [{"mcp_rate_limit_max", 77}]) == :ok

    {:ok, pins} = Cell.call(:a, Arca.PlatformSettings, :pins, [])
    assert Enum.any?(pins, &(&1.member == b and &1.key == "mcp_rate_limit_max"))

    # Killed, it retires nothing; its successor on the slot, booted with no
    # pin, retires what it left and clears the deployment's row.
    Cell.kill(:b)
    Cell.heal!()

    {:ok, pins} = Cell.call(:a, Arca.PlatformSettings, :pins, [])
    refute Enum.any?(pins, &(&1.member == b))

    Wait.until!(
      fn -> effective(:a, "mcp_rate_limit_max") == {:ok, 120} end,
      "the retired pin's value outlived it",
      @converge_ms
    )

    {_listing, entry} = listed(:a, "mcp_rate_limit_max")
    assert %{source: "default", pins: []} = entry
  end
end

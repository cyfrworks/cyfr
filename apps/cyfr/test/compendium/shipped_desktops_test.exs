# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ShippedDesktopsTest do
  @moduledoc """
  The shipped desktops each ship a new version beside the one they shipped
  with: the five at 0.2.0 beside 0.1.0, and the shipped canvas at 0.6.0
  beside 0.5.0. An athanor filled while only the earlier version shipped
  sees an update once the seed carries the new one, and one filled from
  the seed holds both versions as the components list reads them, the
  earlier marked so.
  """
  use ExUnit.Case, async: false

  alias Compendium.Providers.Component

  @repo_desktops Path.expand("../../../../seed/components/tinctures/local", __DIR__)
  # Each desktop, the version it shipped with and the version beside it.
  @shipped [
    {"canvas", "0.5.0", "0.6.0"},
    {"line", "0.1.0", "0.2.0"},
    {"night", "0.1.0", "0.2.0"},
    {"road", "0.1.0", "0.2.0"},
    {"street", "0.1.0", "0.2.0"},
    {"switchboard", "0.1.0", "0.2.0"}
  ]
  @names Enum.map(@shipped, &elem(&1, 0))

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_dir =
      Path.join(System.tmp_dir!(), "cyfr_shipped_desktops_#{System.unique_integer([:positive])}")

    seed = Path.join(test_dir, "seed")
    File.mkdir_p!(Path.join(seed, "components/tinctures/local"))
    on_exit(fn -> File.rm_rf!(test_dir) end)
    Prima.Test.Env.put_app_env(:arca, :base_path, Path.join(test_dir, "data"))
    Prima.Test.Env.put_app_env(:arca, :seed_path, seed)

    {:ok, seed: seed, ctx: Sanctum.TestContext.local()}
  end

  # The seed ships each desktop's version `pick` chooses, copied from the
  # repository's.
  defp ship!(seed, pick) do
    for {name, _before, _after} = desktop <- @shipped do
      version = pick.(desktop)
      target = Path.join([seed, "components/tinctures/local", name, version])
      File.mkdir_p!(target)
      File.cp_r!(Path.join([@repo_desktops, name, version]), target)
    end
  end

  # The athanor filled as a fill fills it: what the seed ships copied in
  # and the scan minting its rows.
  defp fill!(ctx) do
    actor = Sanctum.Context.actor(ctx)
    {:ok, _copied} = Arca.Overlay.materialize_shipped(actor, "components")
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
  end

  # Each desktop's installed versions as `components.changes` reads them:
  # {name, version, update_available}.
  defp desktops!(ctx) do
    {:ok, items} = Component.installed(ctx, nil)

    for %{type: "tincture", name: name} = item <- items, name in @names do
      {name, item.version, item.update_available}
    end
    |> Enum.sort()
  end

  test "the seed ships each desktop's new version beside the one it shipped with" do
    for {name, before, now} <- @shipped do
      versions = File.ls!(Path.join(@repo_desktops, name))
      assert before in versions and now in versions, name
    end
  end

  test "an installed earlier version shows an update once the new one ships, and a fill lists both",
       %{seed: seed, ctx: ctx} do
    ship!(seed, &elem(&1, 1))
    fill!(ctx)
    assert desktops!(ctx) == for({name, before, _now} <- @shipped, do: {name, before, false})

    # The next release's seed carries the new version beside it.
    ship!(seed, &elem(&1, 2))

    for {name, before, now} <- @shipped do
      assert Compendium.Provenance.shipped_versions("tincture", name) == {:ok, [now, before]}
    end

    assert desktops!(ctx) == for({name, before, _now} <- @shipped, do: {name, before, true})

    fill!(ctx)

    assert desktops!(ctx) ==
             for(
               {name, before, now} <- @shipped,
               version <- [before, now],
               do: {name, version, version == before}
             )
  end
end

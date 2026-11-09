# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ShippedDesktopsTest do
  @moduledoc """
  The five shipped desktops ship two versions each: 0.1.0 as it shipped,
  and 0.2.0 beside it. An athanor filled while only 0.1.0 shipped sees an
  update once the seed carries 0.2.0, and one filled from the seed holds
  both versions as the components list reads them, its 0.1.0 marked so.
  """
  use ExUnit.Case, async: false

  alias Compendium.Providers.Component

  @repo_desktops Path.expand("../../../../seed/components/tinctures/local", __DIR__)
  @desktops ~w(line night road street switchboard)

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

  # The seed ships `version` of every desktop, copied from the repository's.
  defp ship!(seed, version) do
    for name <- @desktops do
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

    for %{type: "tincture", name: name} = item <- items, name in @desktops do
      {name, item.version, item.update_available}
    end
    |> Enum.sort()
  end

  test "the seed ships 0.1.0 and 0.2.0 of each desktop" do
    for name <- @desktops do
      assert File.ls!(Path.join(@repo_desktops, name)) |> Enum.sort() == ["0.1.0", "0.2.0"]
    end
  end

  test "an installed 0.1.0 shows an update once 0.2.0 ships, and a fill lists both", %{
    seed: seed,
    ctx: ctx
  } do
    ship!(seed, "0.1.0")
    fill!(ctx)
    assert desktops!(ctx) == for(name <- @desktops, do: {name, "0.1.0", false})

    # The next release's seed carries 0.2.0 beside it.
    ship!(seed, "0.2.0")

    for name <- @desktops do
      assert Compendium.Provenance.shipped_versions("tincture", name) == {:ok, ["0.2.0", "0.1.0"]}
    end

    assert desktops!(ctx) == for(name <- @desktops, do: {name, "0.1.0", true})

    fill!(ctx)

    assert desktops!(ctx) ==
             for(
               name <- @desktops,
               version <- ["0.1.0", "0.2.0"],
               do: {name, version, version == "0.1.0"}
             )
  end
end

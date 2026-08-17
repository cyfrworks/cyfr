# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AthanorSeederTest do
  use ExUnit.Case, async: false

  alias Compendium.AthanorSeeder

  @valid_wasm File.read!(Path.join([File.cwd!(), "test/support/test_wasm/math.wasm"]))

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_seeder_#{:rand.uniform(100_000)}")
    components_dir = Path.join(test_dir, "components")
    File.mkdir_p!(components_dir)
    prev_base = Application.get_env(:cyfr, :base_path)
    prev_components = Application.get_env(:cyfr, :components_path)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :components_path, components_dir)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :components_path, prev_components)
      File.rm_rf!(test_dir)
    end)

    {:ok, components_dir: components_dir}
  end

  # A bundled catalyst under the seed source components/_bundle.
  defp write_bundle!(components_dir) do
    src = Path.join([components_dir, "_bundle", "catalysts", "local", "foo", "1.0.0"])
    File.mkdir_p!(src)
    File.write!(Path.join(src, "catalyst.wasm"), @valid_wasm)

    manifest = %{
      "name" => "foo",
      "version" => "1.0.0",
      "type" => "catalyst",
      "caps" => %{"egress" => %{"domains" => []}}
    }

    File.write!(Path.join(src, "cyfr-manifest.json"), Jason.encode!(manifest))
    :ok
  end

  defp athanor_ctx(id) do
    Sanctum.internal_context(user_id: "_seed", athanor_id: id, scope: :athanor)
  end

  test "copies the bundle into the athanor and registers a DB row", %{
    components_dir: components_dir
  } do
    write_bundle!(components_dir)

    assert :ok = AthanorSeeder.seed("ath_acme")

    # Blob copied under the athanor.
    copied =
      Path.join([
        components_dir,
        "ath_acme",
        "catalysts",
        "local",
        "foo",
        "1.0.0",
        "catalyst.wasm"
      ])

    assert File.exists?(copied)

    # DB row registered under the athanor.
    ctx = athanor_ctx("ath_acme")

    assert {:ok, row} =
             Arca.ComponentStorage.get_component(ctx, "foo", "1.0.0", "local", "catalyst")

    assert row.athanor_id == "ath_acme"

    # And NOT visible to a different athanor.
    other = athanor_ctx("ath_other")

    assert {:error, :not_found} =
             Arca.ComponentStorage.get_component(other, "foo", "1.0.0", "local", "catalyst")
  end

  test "accepts an athanor row", %{components_dir: components_dir} do
    write_bundle!(components_dir)

    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "group",
        name: "Seeded",
        slug: "seeded-#{System.unique_integer([:positive])}",
        created_by: "test"
      })

    assert :ok = AthanorSeeder.seed(athanor)

    assert {:ok, _} =
             Arca.ComponentStorage.get_component(
               athanor_ctx(athanor.id),
               "foo",
               "1.0.0",
               "local",
               "catalyst"
             )
  end

  test "is idempotent", %{components_dir: components_dir} do
    write_bundle!(components_dir)

    assert :ok = AthanorSeeder.seed("ath_acme")
    assert :ok = AthanorSeeder.seed("ath_acme")

    assert {:ok, _} =
             Arca.ComponentStorage.get_component(
               athanor_ctx("ath_acme"),
               "foo",
               "1.0.0",
               "local",
               "catalyst"
             )
  end

  test "an install without a bundle cannot seed" do
    assert {:error, :bundle_missing} = AthanorSeeder.seed("ath_acme")
  end

  test "the bundle itself is never indexed as the athanor's rows", %{
    components_dir: components_dir
  } do
    write_bundle!(components_dir)
    assert :ok = AthanorSeeder.seed("ath_acme")

    # The seeded athanor's scan lists only its own tree — the bundle is not a
    # component of anyone.
    ctx = athanor_ctx("ath_acme")
    {:ok, rows} = Arca.ComponentStorage.list_components(ctx, publisher: "local")
    assert Enum.all?(rows, &(&1.athanor_id == "ath_acme"))
  end
end

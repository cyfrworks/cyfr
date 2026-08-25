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
    bundle_dir = Path.join(test_dir, "bundle")
    File.mkdir_p!(bundle_dir)
    prev_base = Application.get_env(:cyfr, :base_path)
    prev_bundle = Application.get_env(:cyfr, :bundle_path)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :bundle_path, bundle_dir)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :bundle_path, prev_bundle)
      File.rm_rf!(test_dir)
    end)

    {:ok, bundle_dir: bundle_dir}
  end

  # A bundled catalyst under the seed source (`:bundle_path`).
  defp write_bundle!(bundle_dir) do
    src = Path.join([bundle_dir, "catalysts", "local", "foo", "1.0.0"])
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
    bundle_dir: bundle_dir
  } do
    write_bundle!(bundle_dir)

    assert :ok = AthanorSeeder.seed("ath_acme")

    # Blob copied under the athanor.
    copied =
      Arca.Adapters.Local.build_path(
        athanor_ctx("ath_acme"),
        ["components", "catalysts", "local", "foo", "1.0.0", "catalyst.wasm"]
      )

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

  test "accepts an athanor row", %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)

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

  test "is idempotent", %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)

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

  test "build droppings in the bundle are not copied or counted", %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)

    # A checked-out bundle where someone ran cargo/npm inside a component.
    src = Path.join([bundle_dir, "catalysts", "local", "foo", "1.0.0", "src"])
    File.mkdir_p!(Path.join([src, "target", "debug"]))
    File.write!(Path.join([src, "target", "debug", "foo.o"]), String.duplicate("x", 1024))
    File.mkdir_p!(Path.join(src, "node_modules"))
    File.write!(Path.join([src, "node_modules", "pkg.js"]), "js")
    File.write!(Path.join(src, "lib.rs"), "fn main() {}")

    assert :ok = AthanorSeeder.seed("ath_acme")

    ctx = athanor_ctx("ath_acme")
    prefix = ["components", "catalysts", "local", "foo", "1.0.0", "src"]

    assert {:ok, "fn main() {}"} = Arca.get(ctx, prefix ++ ["lib.rs"])
    refute Arca.exists?(ctx, prefix ++ ["target", "debug", "foo.o"])
    refute Arca.exists?(ctx, prefix ++ ["node_modules", "pkg.js"])
  end

  describe "sync/1" do
    test "copies only the versions the athanor lacks", %{bundle_dir: bundle_dir} do
      write_bundle!(bundle_dir)
      assert :ok = AthanorSeeder.seed("ath_acme")

      # A later release ships a newer version of the same catalyst.
      newer = Path.join([bundle_dir, "catalysts", "local", "foo", "1.1.0"])
      File.mkdir_p!(newer)
      File.write!(Path.join(newer, "catalyst.wasm"), @valid_wasm)

      File.write!(
        Path.join(newer, "cyfr-manifest.json"),
        Jason.encode!(%{
          "name" => "foo",
          "version" => "1.1.0",
          "type" => "catalyst",
          "caps" => %{"egress" => %{"domains" => []}}
        })
      )

      assert {:ok, report} = AthanorSeeder.sync("ath_acme")
      assert report.copied == ["catalysts/local/foo/1.1.0"]
      assert report.present == ["catalysts/local/foo/1.0.0"]
      assert report.modified == []

      ctx = athanor_ctx("ath_acme")

      assert Arca.exists?(
               ctx,
               ["components", "catalysts", "local", "foo", "1.1.0", "catalyst.wasm"]
             )

      # The new arrival is registered.
      assert {:ok, _} =
               Arca.ComponentStorage.get_component(ctx, "foo", "1.1.0", "local", "catalyst")
    end

    test "never touches an existing version dir, and reports its drift", %{
      bundle_dir: bundle_dir
    } do
      write_bundle!(bundle_dir)
      assert :ok = AthanorSeeder.seed("ath_acme")

      # The member edits the seeded copy in place.
      ctx = athanor_ctx("ath_acme")
      edited = ["components", "catalysts", "local", "foo", "1.0.0", "cyfr-manifest.json"]
      :ok = Arca.put(ctx, edited, ~s({"edited": true}))

      assert {:ok, report} = AthanorSeeder.sync("ath_acme")
      assert report.copied == []
      assert report.modified == ["catalysts/local/foo/1.0.0"]

      # The member's bytes survive.
      assert {:ok, ~s({"edited": true})} = Arca.get(ctx, edited)
    end

    test "is idempotent — a second sync reports everything present", %{
      bundle_dir: bundle_dir
    } do
      write_bundle!(bundle_dir)
      assert {:ok, %{copied: [_]}} = AthanorSeeder.sync("ath_acme")
      assert {:ok, %{copied: [], present: [_], modified: []}} = AthanorSeeder.sync("ath_acme")
    end
  end

  test "Upstream.bundle_versions lists what the bundle ships", %{bundle_dir: bundle_dir} do
    write_bundle!(bundle_dir)
    assert Compendium.Upstream.bundle_versions("catalyst", "foo") == ["1.0.0"]
    assert Compendium.Upstream.bundle_versions("catalyst", "nope") == []
  end

  test "the bundle itself is never indexed as the athanor's rows", %{
    bundle_dir: bundle_dir
  } do
    write_bundle!(bundle_dir)
    assert :ok = AthanorSeeder.seed("ath_acme")

    # The seeded athanor's scan lists only its own tree — the bundle is not a
    # component of anyone.
    ctx = athanor_ctx("ath_acme")
    {:ok, rows} = Arca.ComponentStorage.list_components(ctx, publisher: "local")
    assert Enum.all?(rows, &(&1.athanor_id == "ath_acme"))
  end
end

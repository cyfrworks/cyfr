# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ProjectSeederTest do
  use ExUnit.Case, async: false

  alias Compendium.ProjectSeeder

  @valid_wasm File.read!(Path.join([File.cwd!(), "test/support/test_wasm/math.wasm"]))

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_seeder_#{:rand.uniform(100_000)}")
    components_dir = Path.join(test_dir, "components")
    File.mkdir_p!(components_dir)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :components_path, components_dir)

    # A bundled catalyst under the seed source local/default.
    src = Path.join([components_dir, "local", "default", "catalysts", "local", "foo", "1.0.0"])
    File.mkdir_p!(src)
    File.write!(Path.join(src, "catalyst.wasm"), @valid_wasm)

    manifest = %{
      "name" => "foo",
      "version" => "1.0.0",
      "type" => "catalyst",
      "setup" => %{"policy" => %{}}
    }

    File.write!(Path.join(src, "cyfr-manifest.json"), Jason.encode!(manifest))

    on_exit(fn -> File.rm_rf!(test_dir) end)

    {:ok, components_dir: components_dir}
  end

  test "copies bundled blobs into the target tenant and registers a DB row", %{
    components_dir: components_dir
  } do
    assert :ok = ProjectSeeder.seed(%{org_id: "acme", project_id: "p1"})

    # Blob copied under the target tenant.
    copied =
      Path.join([components_dir, "acme", "p1", "catalysts", "local", "foo", "1.0.0", "catalyst.wasm"])

    assert File.exists?(copied)

    # DB row registered under the target tenant.
    ctx = Sanctum.internal_context(org_id: "acme", project_id: "p1")
    assert {:ok, row} = Arca.ComponentStorage.get_component(ctx, "foo", "1.0.0", "local", "catalyst")
    assert row.org_id == "acme"
    assert row.project_id == "p1"

    # And NOT visible to a different project in the same org.
    other = Sanctum.internal_context(org_id: "acme", project_id: "p2")
    assert {:error, :not_found} =
             Arca.ComponentStorage.get_component(other, "foo", "1.0.0", "local", "catalyst")
  end

  test "is idempotent" do
    assert :ok = ProjectSeeder.seed(%{org_id: "acme", project_id: "p1"})
    assert :ok = ProjectSeeder.seed(%{org_id: "acme", project_id: "p1"})

    ctx = Sanctum.internal_context(org_id: "acme", project_id: "p1")
    assert {:ok, _} = Arca.ComponentStorage.get_component(ctx, "foo", "1.0.0", "local", "catalyst")
  end

  test "seeding the bundle source (local/default) is a no-op" do
    assert {:ok, :is_seed_source} =
             ProjectSeeder.seed(%{org_id: "local", project_id: "default"})

    assert {:ok, :is_seed_source} = ProjectSeeder.seed(%{org_id: nil, project_id: nil})
  end
end

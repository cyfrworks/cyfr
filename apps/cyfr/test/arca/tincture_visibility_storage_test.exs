defmodule Arca.TinctureData.VisibilityStorageTest do
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Arca.TinctureData.VisibilityStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    # Use unique names per test to avoid conflicts
    rand = :rand.uniform(1_000_000)

    on_exit(fn ->
      # Clean up cache entries
      Arca.Cache.invalidate({:tincture_visibility, "", "default", "local", "vis-test-#{rand}"})
    end)

    %{ctx: Context.local(), name: "vis-test-#{rand}"}
  end

  describe "put/4 and get/3" do
    test "stores and retrieves visibility (public)", %{ctx: ctx, name: name} do
      assert :ok = VisibilityStorage.put(ctx, "local", name, true)
      assert {:ok, record} = VisibilityStorage.get(ctx, "local", name)
      assert record.is_public in [true, 1, "true"]
      assert record.publisher == "local"
      assert record.name == name
    end

    test "stores and retrieves visibility (private)", %{ctx: ctx, name: name} do
      assert :ok = VisibilityStorage.put(ctx, "local", name, false)
      assert {:ok, record} = VisibilityStorage.get(ctx, "local", name)
      assert record.is_public in [false, 0, "false"]
    end

    test "upserts on conflict (updates visibility)", %{ctx: ctx, name: name} do
      assert :ok = VisibilityStorage.put(ctx, "local", name, true)
      assert {:ok, r1} = VisibilityStorage.get(ctx, "local", name)
      assert r1.is_public in [true, 1, "true"]

      assert :ok = VisibilityStorage.put(ctx, "local", name, false)
      assert {:ok, r2} = VisibilityStorage.get(ctx, "local", name)
      assert r2.is_public in [false, 0, "false"]
    end

    test "returns :not_found for nonexistent record", %{ctx: ctx} do
      assert {:error, :not_found} =
               VisibilityStorage.get(ctx, "local", "nonexistent-#{:rand.uniform(100_000)}")
    end
  end

  describe "get_visibility/3" do
    test "retrieves public visibility via unauthenticated context", %{ctx: ctx, name: name} do
      assert :ok = VisibilityStorage.put(ctx, "local", name, true)

      public_ctx = Context.build(org_id: "", project_id: "default", authenticated: false)
      assert {:ok, record} = VisibilityStorage.get_visibility(public_ctx, "local", name)
      assert record.is_public in [true, 1, "true"]
    end

    test "retrieves private visibility via unauthenticated context", %{ctx: ctx, name: name} do
      assert :ok = VisibilityStorage.put(ctx, "local", name, false)

      public_ctx = Context.build(org_id: "", project_id: "default", authenticated: false)
      assert {:ok, record} = VisibilityStorage.get_visibility(public_ctx, "local", name)
      assert record.is_public in [false, 0, "false"]
    end

    test "returns :not_found for missing record" do
      public_ctx = Context.build(org_id: "", project_id: "default", authenticated: false)

      assert {:error, :not_found} =
               VisibilityStorage.get_visibility(public_ctx, "local", "none-#{:rand.uniform(100_000)}")
    end
  end

  describe "delete/3" do
    test "deletes visibility record", %{ctx: ctx, name: name} do
      assert :ok = VisibilityStorage.put(ctx, "local", name, true)
      assert {:ok, _} = VisibilityStorage.get(ctx, "local", name)

      assert :ok = VisibilityStorage.delete(ctx, "local", name)
      assert {:error, :not_found} = VisibilityStorage.get(ctx, "local", name)
    end

    test "delete is idempotent for missing record", %{ctx: ctx} do
      assert :ok = VisibilityStorage.delete(ctx, "local", "never-existed-#{:rand.uniform(100_000)}")
    end
  end

  describe "cache behavior" do
    test "cached value is returned on second read", %{ctx: ctx, name: name} do
      assert :ok = VisibilityStorage.put(ctx, "local", name, true)

      # First read populates cache
      assert {:ok, _} = VisibilityStorage.get(ctx, "local", name)

      # Second read should come from cache
      assert {:ok, record} = VisibilityStorage.get(ctx, "local", name)
      assert record.is_public in [true, 1, "true"]
    end

    test "put invalidates cache", %{ctx: ctx, name: name} do
      assert :ok = VisibilityStorage.put(ctx, "local", name, true)
      assert {:ok, r1} = VisibilityStorage.get(ctx, "local", name)
      assert r1.is_public in [true, 1, "true"]

      # Update — should invalidate cache
      assert :ok = VisibilityStorage.put(ctx, "local", name, false)
      assert {:ok, r2} = VisibilityStorage.get(ctx, "local", name)
      assert r2.is_public in [false, 0, "false"]
    end

    test "delete invalidates cache", %{ctx: ctx, name: name} do
      assert :ok = VisibilityStorage.put(ctx, "local", name, true)
      assert {:ok, _} = VisibilityStorage.get(ctx, "local", name)

      assert :ok = VisibilityStorage.delete(ctx, "local", name)
      assert {:error, :not_found} = VisibilityStorage.get(ctx, "local", name)
    end
  end

  describe "Sanctum.TinctureVisibility integration" do
    test "public?/3 returns false for nonexistent tincture" do
      public_ctx = Context.build(org_id: "", project_id: "default", authenticated: false)
      refute Sanctum.TinctureVisibility.public?(public_ctx, "local", "no-such-#{:rand.uniform(100_000)}")
    end

    test "public?/3 returns true after set_public", %{ctx: ctx, name: name} do
      assert :ok = Sanctum.TinctureVisibility.set_public(ctx, "local", name, true)

      public_ctx = Context.build(org_id: "", project_id: "default", authenticated: false)
      assert Sanctum.TinctureVisibility.public?(public_ctx, "local", name)
    end

    test "public?/3 returns false after set_public(false)", %{ctx: ctx, name: name} do
      assert :ok = Sanctum.TinctureVisibility.set_public(ctx, "local", name, false)

      public_ctx = Context.build(org_id: "", project_id: "default", authenticated: false)
      refute Sanctum.TinctureVisibility.public?(public_ctx, "local", name)
    end

    test "get/3 returns visibility state", %{ctx: ctx, name: name} do
      assert :ok = Sanctum.TinctureVisibility.set_public(ctx, "local", name, true)
      assert {:ok, record} = Sanctum.TinctureVisibility.get(ctx, "local", name)
      assert record.is_public in [true, 1, "true"]
    end

    test "get/3 returns :not_found when no record exists", %{ctx: ctx} do
      assert {:error, :not_found} =
               Sanctum.TinctureVisibility.get(ctx, "local", "nope-#{:rand.uniform(100_000)}")
    end
  end
end

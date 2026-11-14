# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ResolverTest do
  use ExUnit.Case, async: false

  alias Compendium.Resolver
  alias Compendium.Registry

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_dir = Path.join(System.tmp_dir!(), "cyfr_resolver_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_dir)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir, ctx: ctx}
  end

  defp register_component(ctx, name, version, type \\ "catalyst") do
    Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(type), %{
      name: name,
      version: version,
      type: type,
      description: "Test component"
    })
  end

  describe "resolve/2 with already-pinned ref" do
    test "passes through exact version refs", %{ctx: ctx} do
      register_component(ctx, "claude", "0.1.0")

      assert {:ok, "catalyst:local.claude:0.1.0", metadata} =
               Resolver.resolve(ctx, "c:local.claude:0.1.0")

      assert metadata.was_resolved == false
      assert metadata.resolved_from == "c:local.claude:0.1.0"
      assert metadata.resolved_to == "catalyst:local.claude:0.1.0"
    end
  end

  describe "resolve/2 with version-less ref" do
    test "resolves to latest version", %{ctx: ctx} do
      register_component(ctx, "claude", "0.1.0")

      assert {:ok, resolved, metadata} = Resolver.resolve(ctx, "c:local.claude")
      assert resolved == "catalyst:local.claude:0.1.0"
      assert metadata.was_resolved == true
      assert metadata.resolved_from == "c:local.claude"
      assert metadata.resolved_to == "catalyst:local.claude:0.1.0"
      assert %DateTime{} = metadata.resolved_at
    end

    test "resolves to latest among multiple versions", %{ctx: ctx} do
      register_component(ctx, "claude", "0.1.0")
      register_component(ctx, "claude", "0.2.0")

      assert {:ok, resolved, _metadata} = Resolver.resolve(ctx, "c:local.claude")
      # get_latest returns the highest semver version, which should be 0.2.0
      assert resolved == "catalyst:local.claude:0.2.0"
    end
  end

  describe "resolve/2 error cases" do
    test "errors when type prefix is missing", %{ctx: ctx} do
      assert {:error, msg} = Resolver.resolve(ctx, "local.claude")
      assert msg =~ "type prefix"
    end

    test "errors when component not found", %{ctx: ctx} do
      assert {:error, {:not_found, {:component, "c:local.nonexistent"}} = reason} =
               Resolver.resolve(ctx, "c:local.nonexistent")

      assert Prima.Refusal.message(reason) =~ "Component not found"
    end

    test "errors on empty ref", %{ctx: ctx} do
      assert {:error, _} = Resolver.resolve(ctx, "")
    end
  end
end

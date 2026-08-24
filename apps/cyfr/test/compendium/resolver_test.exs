# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ResolverTest do
  use ExUnit.Case, async: false

  alias Compendium.Resolver
  alias Compendium.Registry

  # Valid minimal WASM with export section
  # magic + version
  # type section
  # function section
  # export section
  # code section
  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_resolver_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    prev_base = Application.fetch_env!(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir, ctx: ctx}
  end

  defp register_component(ctx, name, version, type \\ "catalyst") do
    Registry.publish_bytes(ctx, @valid_wasm, %{
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
      assert {:error, msg} = Resolver.resolve(ctx, "c:local.nonexistent")
      assert msg =~ "No versions found"
    end

    test "errors on empty ref", %{ctx: ctx} do
      assert {:error, _} = Resolver.resolve(ctx, "")
    end
  end

  describe "resolve_or_passthrough/2" do
    test "typed version-less ref resolves to latest", %{ctx: ctx} do
      register_component(ctx, "passthrough-test", "0.3.0")

      assert {:ok, resolved} = Resolver.resolve_or_passthrough(ctx, "c:local.passthrough-test")
      assert resolved == "catalyst:local.passthrough-test:0.3.0"
    end

    test "already-pinned ref passes through unchanged", %{ctx: ctx} do
      assert {:ok, ref} = Resolver.resolve_or_passthrough(ctx, "c:local.some-tool:1.0.0")
      assert ref == "catalyst:local.some-tool:1.0.0"
    end

    test "typed version-less ref with no registry entry passes through", %{ctx: ctx} do
      assert {:ok, ref} = Resolver.resolve_or_passthrough(ctx, "c:local.nonexistent")
      assert ref == "c:local.nonexistent"
    end

    test "untyped/OCI-like ref passes through when resolution fails", %{ctx: ctx} do
      assert {:ok, ref} = Resolver.resolve_or_passthrough(ctx, "ghcr.io/user/repo:1.0.0")
      assert ref == "ghcr.io/user/repo:1.0.0"
    end
  end
end

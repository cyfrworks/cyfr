# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ComponentValidationTest do
  use ExUnit.Case, async: false

  # Component-identity validation lives with the registry (the component domain),
  # not the Arca storage layer — Arca persists already-validated attributes.
  alias Compendium.Registry

  @wasm Cyfr.Test.Guests.wasm(:reagent)

  # A core module exporting `sum` and `multiply`: valid WebAssembly, but no
  # component.
  @core_module File.read!(
                 Path.join(__DIR__, "../../../locus/test/support/runtime/test_wasm/math.wasm")
               )

  @valid_attrs %{name: "my-tool", version: "1.0.0", type: "reagent", publisher: "local"}

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    original_base_path = Application.fetch_env!(:arca, :base_path)
    on_exit(fn -> Application.put_env(:arca, :base_path, original_base_path) end)

    test_path = Path.join(System.tmp_dir!(), "component_validation_#{:rand.uniform(1_000_000)}")
    on_exit(fn -> File.rm_rf!(test_path) end)
    Application.put_env(:arca, :base_path, test_path)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  describe "publishing a component's identity" do
    test "accepts valid attributes", %{ctx: ctx} do
      assert {:ok, %{name: "my-tool", version: "1.0.0"}} =
               Registry.publish_bytes(ctx, @wasm, @valid_attrs)
    end

    test "refuses a missing or empty name, version or type", %{ctx: ctx} do
      for key <- [:name, :version, :type] do
        assert {:error, {:missing_required, ^key}} =
                 Registry.publish_bytes(ctx, @wasm, Map.delete(@valid_attrs, key))

        assert {:error, {:missing_required, ^key}} =
                 Registry.publish_bytes(ctx, @wasm, %{@valid_attrs | key => ""})
      end
    end

    test "refuses an invalid name, version, type or publisher", %{ctx: ctx} do
      for {key, value} <- [
            name: "MY_CAPS",
            version: "not-semver",
            type: "widget",
            publisher: "UPPER_CASE"
          ] do
        assert {:error, _} = Registry.publish_bytes(ctx, @wasm, %{@valid_attrs | key => value}),
               "#{key} #{inspect(value)} was accepted"
      end
    end

    test "refuses a core module as one, for every type, writing nothing", %{ctx: ctx} do
      for type <- ~w(reagent catalyst formula) do
        assert {:error, {:core_module, message}} =
                 Registry.publish_bytes(ctx, @core_module, %{@valid_attrs | type: type})

        assert message =~ "core WebAssembly module, not a component"
        assert {:error, :not_found} = Registry.get(ctx, "my-tool", "1.0.0", "local", type)

        refute Arca.exists?(
                 Sanctum.Context.actor(ctx),
                 Compendium.ComponentPath.version_dir(type, "local", "my-tool", "1.0.0")
               )
      end
    end

    test "refuses an invalid type or publisher before the unit is written", %{ctx: ctx} do
      assert {:error, {:invalid_type, _}} =
               Registry.publish_bytes(ctx, @wasm, %{@valid_attrs | type: "widget"})

      assert {:error, {:invalid_publisher, _}} =
               Registry.publish_bytes(ctx, @wasm, %{@valid_attrs | publisher: "UPPER_CASE"})

      assert {:error, :not_found} = Registry.get(ctx, "my-tool", "1.0.0", "UPPER_CASE", "reagent")
    end
  end
end

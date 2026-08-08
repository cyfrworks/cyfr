# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Compendium.ReleaseImmutabilityTest do
  # The model §6 "Release immutability" gate: re-publishing an existing
  # version with different bytes or a different manifest is refused on every
  # publish path, and the refusal leaves nothing behind. The directory /
  # scanner ingress is exempt — that exemption is keyed on the ingress path,
  # not on the publisher string (D4).
  use ExUnit.Case, async: false

  alias Compendium.Registry

  # Two distinct, both-valid artifacts: the test module, and the same module
  # plus an empty "cyfr" custom section — different bytes, same behaviour,
  # exactly the shape a rebuild produces.
  @wasm_a File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))
  @wasm_b @wasm_a <> <<0x00, 0x05, 0x04>> <> "cyfr"

  setup do
    test_path = Path.join(System.tmp_dir!(), "release_immutability_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local(), test_path: test_path}
  end

  defp publish(ctx, opts) do
    Registry.publish_bytes(
      ctx,
      Keyword.get(opts, :bytes, @wasm_a),
      %{
        name: Keyword.fetch!(opts, :name),
        version: "1.0.0",
        type: "reagent",
        description: Keyword.get(opts, :description, "original"),
        manifest: Keyword.get(opts, :manifest)
      },
      allow_overwrite: Keyword.get(opts, :allow_overwrite, true)
    )
  end

  # ============================================================================
  # publish_bytes
  # ============================================================================

  describe "publish_bytes" do
    test "refuses a republish with different bytes", %{ctx: ctx} do
      {:ok, _} = publish(ctx, name: "immutable-bytes")

      assert {:error, {:release_immutable, details}} =
               publish(ctx, name: "immutable-bytes", bytes: @wasm_b)

      assert details.name == "immutable-bytes"
      assert details.version == "1.0.0"
      assert details.type == "reagent"
      assert details.publisher == "local"
    end

    test "refuses a republish with a different manifest at identical bytes", %{ctx: ctx} do
      manifest = Jason.encode!(%{"caps" => %{"egress" => %{"domains" => ["a.example"]}}})
      widened = Jason.encode!(%{"caps" => %{"egress" => %{"domains" => ["*"]}}})

      {:ok, _} = publish(ctx, name: "immutable-manifest", manifest: manifest)

      assert {:error, {:release_immutable, _}} =
               publish(ctx, name: "immutable-manifest", manifest: widened)
    end

    test "an identical republish proceeds and refreshes metadata", %{ctx: ctx} do
      manifest = Jason.encode!(%{"caps" => %{"tools" => ["execution.run"]}})

      {:ok, first} = publish(ctx, name: "idempotent", manifest: manifest)

      assert {:ok, second} =
               publish(ctx, name: "idempotent", manifest: manifest, description: "refreshed")

      assert second.digest == first.digest
      assert second.release_digest == first.release_digest
      assert second.description == "refreshed"
    end

    test "a refused republish writes no bytes", %{ctx: ctx} do
      {:ok, _} = publish(ctx, name: "no-orphans")

      wasm_path =
        Compendium.ComponentPath.wasm_path("reagent", "local", "no-orphans", "1.0.0", ctx)

      {:ok, stored_before} = Arca.get(ctx, wasm_path)

      assert {:error, {:release_immutable, _}} =
               publish(ctx, name: "no-orphans", bytes: @wasm_b)

      # The artifact on disk is still the original — a refused publish must
      # not leave new bytes for the scanner to index.
      assert {:ok, ^stored_before} = Arca.get(ctx, wasm_path)

      {:ok, row} = Arca.ComponentStorage.get_component(ctx, "no-orphans", "1.0.0", "local")
      assert row.digest == Compendium.WasmValidator.compute_digest(@wasm_a)
    end

    test "different versions of the same component are unaffected", %{ctx: ctx} do
      {:ok, _} = publish(ctx, name: "versioned")

      assert {:ok, _} =
               Registry.publish_bytes(
                 ctx,
                 @wasm_b,
                 %{name: "versioned", version: "1.0.1", type: "reagent"},
                 allow_overwrite: true
               )
    end
  end

  # ============================================================================
  # The directory / scanner exemption (D4)
  # ============================================================================

  describe "directory register exemption" do
    test "a local rebuild re-registers with new bytes at an unchanged version", %{
      ctx: ctx,
      test_path: test_path
    } do
      manifest = %{
        "name" => "rebuilt",
        "version" => "1.0.0",
        "type" => "reagent",
        "description" => "local build"
      }

      segments = [
        "components",
        Arca.QueryHelpers.normalize_org_id(ctx.org_id),
        Arca.QueryHelpers.normalize_project_id(ctx.project_id),
        "reagents",
        "local",
        "rebuilt",
        "1.0.0"
      ]

      write_component = fn bytes ->
        base = Path.join([test_path | segments])
        File.mkdir_p!(base)
        File.write!(Path.join(base, "reagent.wasm"), bytes)
        File.write!(Path.join(base, "cyfr-manifest.json"), Jason.encode!(manifest))
      end

      write_component.(@wasm_a)
      assert {:ok, _} = Registry.register_from_arca(ctx, segments)

      # A rebuild changes bytes at the same version: the scanner path is
      # exempt by design, and the release simply takes a new identity.
      write_component.(@wasm_b)
      assert {:ok, registered} = Registry.register_from_arca(ctx, segments)
      refute registered == :unchanged

      {:ok, row} = Arca.ComponentStorage.get_component(ctx, "rebuilt", "1.0.0", "local")
      assert row.digest == Compendium.WasmValidator.compute_digest(@wasm_b)
      assert row.release_digest != nil
    end
  end
end

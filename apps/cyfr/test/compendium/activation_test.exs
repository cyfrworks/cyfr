# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Compendium.ActivationTest do
  use ExUnit.Case, async: false

  alias Compendium.Activation
  alias Compendium.Registry

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))
  # The same module plus an empty custom section: different bytes, same
  # behaviour — what a rebuild produces.
  @wasm_variant @wasm <> <<0x00, 0x05, 0x04>> <> "cyfr"

  setup do
    test_path = Path.join(System.tmp_dir!(), "activation_test_#{:rand.uniform(1_000_000)}")
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

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp publish!(ctx, name, opts \\ []) do
    manifest = Keyword.get(opts, :manifest)

    {:ok, component} =
      Registry.publish_bytes(
        ctx,
        Keyword.get(opts, :bytes, @wasm),
        %{
          name: name,
          version: Keyword.get(opts, :version, "1.0.0"),
          type: Keyword.get(opts, :type, "reagent"),
          manifest: manifest && Jason.encode!(manifest)
        },
        allow_overwrite: true
      )

    component
  end

  # A local rebuild: new bytes at an unchanged version, registered from the
  # filesystem — the ingress the immutability rule deliberately exempts.
  defp rebuild_locally(ctx, name) do
    segments = [
      "components",
      Arca.QueryHelpers.normalize_org_id(ctx.org_id),
      Arca.QueryHelpers.normalize_project_id(ctx.project_id),
      "reagents",
      "local",
      name,
      "1.0.0"
    ]

    base = Path.join([Application.get_env(:cyfr, :base_path) | segments])
    File.mkdir_p!(base)
    File.write!(Path.join(base, "reagent.wasm"), @wasm_variant)

    File.write!(
      Path.join(base, "cyfr-manifest.json"),
      Jason.encode!(%{"name" => name, "version" => "1.0.0", "type" => "reagent"})
    )

    {:ok, _} = Registry.register_from_arca(ctx, segments)
    :ok
  end

  defp row!(ctx, name, version \\ "1.0.0") do
    {:ok, row} = Arca.ComponentStorage.get_component(ctx, name, version, "local")
    row
  end

  # ============================================================================
  # Graph shape
  # ============================================================================

  describe "resolve/2" do
    test "a leaf component activates as a single node", %{ctx: ctx} do
      component = publish!(ctx, "leaf")

      assert {:ok, %{digest: digest, graph: graph}} = Activation.resolve(ctx, component)
      assert graph == %{"reagent:local.leaf" => component.release_digest}
      assert "sha256:" <> _ = digest
    end

    test "the graph includes the static closure, keyed name-level", %{ctx: ctx} do
      publish!(ctx, "dep-a")
      publish!(ctx, "dep-b")

      root =
        publish!(ctx, "root",
          type: "formula",
          manifest: %{
            "dependencies" => %{
              "static" => [
                %{"ref" => "reagent:local.dep-a:1.0.0"},
                %{"ref" => "reagent:local.dep-b:1.0.0"}
              ]
            }
          }
        )

      assert {:ok, %{graph: graph}} = Activation.resolve(ctx, root)

      assert Map.keys(graph) |> Enum.sort() == [
               "formula:local.root",
               "reagent:local.dep-a",
               "reagent:local.dep-b"
             ]

      # Version never appears in a key — code identity is the digest.
      refute Enum.any?(Map.keys(graph), &String.contains?(&1, ":1.0.0"))
      assert graph["reagent:local.dep-a"] == row!(ctx, "dep-a").release_digest
    end

    test "keys match the Authority blob's node-key grammar", %{ctx: ctx} do
      root =
        publish!(ctx, "grammar",
          type: "formula",
          manifest: %{"dependencies" => %{"static" => [%{"ref" => "reagent:local.leaf:1.0.0"}]}}
        )

      publish!(ctx, "leaf")
      {:ok, %{graph: graph}} = Activation.resolve(ctx, root)

      # A blob whose node keys are exactly these must parse — that is what
      # ties a recorded activation to a future consent.
      nodes =
        Map.new(graph, fn {key, _digest} ->
          {key,
           %{
             "limits" => %{
               "timeout" => "30s",
               "max_memory_bytes" => 1,
               "max_request_size" => 1,
               "max_response_size" => 1,
               "rate_limit" => %{"requests" => 1, "window" => "1m"},
               "max_concurrent_tasks" => 1,
               "batch_timeout" => "30s"
             },
             "edges" => %{}
           }}
        end)

      assert {:ok, _blob} =
               Sanctum.Authority.Blob.parse(%{"canonical" => "jcs-1", "nodes" => nodes})
    end

    test "a version-pinned dependency resolves to that exact release", %{ctx: ctx} do
      publish!(ctx, "pinned", version: "1.0.0")
      # Distinct bytes, so the two releases have genuinely distinct digests.
      v2 = publish!(ctx, "pinned", version: "2.0.0", bytes: @wasm_variant)

      root =
        publish!(ctx, "pinner",
          type: "formula",
          manifest: %{"dependencies" => %{"static" => [%{"ref" => "reagent:local.pinned:1.0.0"}]}}
        )

      {:ok, %{graph: graph}} = Activation.resolve(ctx, root)

      assert graph["reagent:local.pinned"] == row!(ctx, "pinned", "1.0.0").release_digest
      refute graph["reagent:local.pinned"] == v2.release_digest
    end

    test "cycles and diamonds terminate", %{ctx: ctx} do
      # a -> b -> a
      publish!(ctx, "cyc-b",
        type: "formula",
        manifest: %{"dependencies" => %{"static" => [%{"ref" => "formula:local.cyc-a:1.0.0"}]}}
      )

      root =
        publish!(ctx, "cyc-a",
          type: "formula",
          manifest: %{"dependencies" => %{"static" => [%{"ref" => "formula:local.cyc-b:1.0.0"}]}}
        )

      assert {:ok, %{graph: graph}} = Activation.resolve(ctx, root)
      assert Map.keys(graph) |> Enum.sort() == ["formula:local.cyc-a", "formula:local.cyc-b"]
    end
  end

  # ============================================================================
  # All-or-nothing
  # ============================================================================

  describe "incompleteness" do
    test "a missing dependency makes the whole activation incomplete", %{ctx: ctx} do
      root =
        publish!(ctx, "orphan",
          type: "formula",
          manifest: %{"dependencies" => %{"static" => [%{"ref" => "reagent:local.absent:1.0.0"}]}}
        )

      assert {:error, {:incomplete, :unresolvable_dependency}} = Activation.resolve(ctx, root)
    end

    test "a node without a release digest makes the activation incomplete", %{ctx: ctx} do
      component = publish!(ctx, "legacy")
      legacy = %{component | release_digest: nil}

      assert {:error, {:incomplete, :missing_release_digest}} = Activation.resolve(ctx, legacy)
    end
  end

  # ============================================================================
  # Digest properties
  # ============================================================================

  describe "digest" do
    test "the recorded graph re-hashes to the recorded digest", %{ctx: ctx} do
      publish!(ctx, "dep-a")

      root =
        publish!(ctx, "hashed",
          type: "formula",
          manifest: %{"dependencies" => %{"static" => [%{"ref" => "reagent:local.dep-a:1.0.0"}]}}
        )

      {:ok, %{digest: digest, graph: graph}} = Activation.resolve(ctx, root)
      {:ok, encoded} = Activation.encode_graph(graph)

      assert Sanctum.JCS.hash_binary(encoded) == digest
      assert Jason.decode!(encoded) == graph
    end

    test "a rebuilt dependency changes the root's activation digest", %{ctx: ctx} do
      publish!(ctx, "rebuilt-dep")

      root =
        publish!(ctx, "rebuild-watcher",
          type: "formula",
          manifest: %{
            "dependencies" => %{"static" => [%{"ref" => "reagent:local.rebuilt-dep:1.0.0"}]}
          }
        )

      {:ok, before} = Activation.resolve(ctx, root)

      # Same version, different bytes — exactly what a local rebuild does.
      # Rebuilds arrive through the scanner path (publish refuses them), and
      # the activation must notice even though nothing about the ref changed.
      rebuild_locally(ctx, "rebuilt-dep")

      {:ok, after_rebuild} = Activation.resolve(ctx, root)

      assert after_rebuild.digest != before.digest
      assert Map.keys(after_rebuild.graph) == Map.keys(before.graph)
    end
  end
end

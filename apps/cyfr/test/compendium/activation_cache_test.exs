# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Compendium.ActivationCacheTest do
  # A resolved activation is a function of the athanor's registry: a warm
  # root answers from the cache with no dependency walk, and a registry
  # change sweeps it.
  use ExUnit.Case, async: false

  alias Compendium.Activation
  alias Compendium.Registry
  alias Cyfr.Test.QueryCounter

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup do
    test_path = Path.join(System.tmp_dir!(), "activation_cache_#{:rand.uniform(1_000_000)}")
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

    ctx = Sanctum.TestContext.local()
    Registry.invalidate_executor_caches(ctx)
    {:ok, ctx: ctx}
  end

  defp publish!(ctx, name, opts \\ []) do
    manifest = Keyword.get(opts, :manifest)

    {:ok, component} =
      Registry.publish_bytes(
        ctx,
        @wasm,
        %{
          name: name,
          version: "1.0.0",
          type: Keyword.get(opts, :type, "reagent"),
          manifest: manifest && Jason.encode!(manifest)
        },
        allow_overwrite: true
      )

    component
  end

  defp root_with_two_deps(ctx) do
    publish!(ctx, "dep-a")
    publish!(ctx, "dep-b")

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
  end

  test "a warm root resolves without a walk", %{ctx: ctx} do
    root = root_with_two_deps(ctx)
    Registry.invalidate_executor_caches(ctx)

    handler = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      handler,
      [:cyfr, :compendium, :activation, :resolve],
      fn _e, _m, meta, _ -> send(parent, {:resolved, meta.cached}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {{:ok, cold}, cold_q} = QueryCounter.count(fn -> Activation.resolve(ctx, root) end)
    assert_receive {:resolved, false}
    assert cold_q.total > 0

    {{:ok, warm}, warm_q} = QueryCounter.count(fn -> Activation.resolve(ctx, root) end)
    assert_receive {:resolved, true}
    assert warm == cold
    assert warm_q.total == 0
  end

  test "a registry change sweeps the cached activation", %{ctx: ctx} do
    root = root_with_two_deps(ctx)
    {:ok, before} = Activation.resolve(ctx, root)

    # A new dependency version changes what a versionless walk would pick;
    # the registry sweep makes the next resolve look again.
    Registry.invalidate_executor_caches(ctx)
    {{:ok, after_sweep}, q} = QueryCounter.count(fn -> Activation.resolve(ctx, root) end)
    assert after_sweep == before
    assert q.total > 0
  end

  test "another athanor's sweep leaves this athanor's activations warm", %{ctx: ctx} do
    root = root_with_two_deps(ctx)
    {:ok, _} = Activation.resolve(ctx, root)

    other = %{ctx | athanor_id: "ath_b"}
    Registry.invalidate_executor_caches(other)

    {{:ok, _}, q} = QueryCounter.count(fn -> Activation.resolve(ctx, root) end)
    assert q.total == 0
  end
end

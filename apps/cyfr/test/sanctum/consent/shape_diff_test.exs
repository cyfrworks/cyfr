# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeDiffTest do
  use ExUnit.Case, async: false

  alias Sanctum.Consent.ShapeDiff

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "shape_diff_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    ctx = Sanctum.TestContext.local()

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "diffed",
        version: "1.0.0",
        type: "reagent",
        manifest:
          Jason.encode!(%{
            "name" => "diffed",
            "version" => "1.0.0",
            "type" => "reagent"
          })
      })

    {:ok, ctx: ctx}
  end

  @source "reagent:local.diffed"

  defp blob(edge) do
    Jason.encode!(%{
      "canonical" => "jcs-1",
      "nodes" => %{
        @source => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 100, "window" => "1m"},
            "max_concurrent_tasks" => 1,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => edge}
        }
      }
    })
  end

  # The live side is the latest release's manifest caps: publishing a newer
  # version with the wanted caps is how a test moves the live shape.
  defp publish_live!(ctx, version, caps) do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "diffed",
        version: version,
        type: "reagent",
        manifest:
          Jason.encode!(%{
            "name" => "diffed",
            "version" => version,
            "type" => "reagent",
            "caps" => caps
          })
      })

    :ok
  end

  test "a widened capability is named with what appeared", %{ctx: ctx} do
    publish_live!(ctx, "1.0.1", %{"egress" => %{"domains" => ["a.example", "b.example"]}})

    granted = blob(%{"egress" => %{"domains" => ["a.example"]}})
    diff = ShapeDiff.compute(ctx, @source, granted)

    assert %{capability: "egress.domains", change: :widened, added: ["b.example"], removed: []} =
             Enum.find(diff, &(&1.capability == "egress.domains"))
  end

  test "a narrowed capability is named with what went away", %{ctx: ctx} do
    publish_live!(ctx, "1.0.2", %{"egress" => %{"domains" => ["a.example"]}})

    granted = blob(%{"egress" => %{"domains" => ["a.example", "gone.example"]}})
    diff = ShapeDiff.compute(ctx, @source, granted)

    assert %{change: :narrowed, added: [], removed: ["gone.example"]} =
             Enum.find(diff, &(&1.capability == "egress.domains"))
  end

  test "both directions at once read as changed", %{ctx: ctx} do
    publish_live!(ctx, "1.0.3", %{"egress" => %{"domains" => ["new.example"]}})

    granted = blob(%{"egress" => %{"domains" => ["old.example"]}})
    diff = ShapeDiff.compute(ctx, @source, granted)

    assert %{change: :changed, added: ["new.example"], removed: ["old.example"]} =
             Enum.find(diff, &(&1.capability == "egress.domains"))
  end

  test "an unchanged capability produces no entry", %{ctx: ctx} do
    publish_live!(ctx, "1.0.4", %{"egress" => %{"domains" => ["same.example"]}})

    granted = blob(%{"egress" => %{"domains" => ["same.example"]}})
    diff = ShapeDiff.compute(ctx, @source, granted)

    refute Enum.any?(diff, &(&1.capability == "egress.domains"))
  end

  test "storage and tools are covered too", %{ctx: ctx} do
    publish_live!(ctx, "1.0.5", %{
      "storage" => %{"paths" => ["data/"], "actions" => ["read", "write"]}
    })

    granted = blob(%{"storage" => %{"paths" => ["data/"], "actions" => ["read"]}})
    diff = ShapeDiff.compute(ctx, @source, granted)

    assert %{change: :widened, added: ["write"]} =
             Enum.find(diff, &(&1.capability == "storage.actions"))
  end

  test "an underivable side yields no diff, never a wrong one", %{ctx: ctx} do
    assert ShapeDiff.compute(ctx, @source, "not a blob") == []
    assert ShapeDiff.compute(ctx, "reagent:local.never-published", blob(%{})) == []
  end
end

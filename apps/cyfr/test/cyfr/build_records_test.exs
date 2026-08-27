# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BuildRecordsTest do
  use ExUnit.Case, async: false

  alias Cyfr.BuildRecords

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    rand = :rand.uniform(100_000)

    ctx =
      Sanctum.Context.build(
        user_id: "build_user_#{rand}",
        athanor_id: "ath_build_#{rand}",
        permissions: [:*],
        scope: :athanor,
        authenticated: true
      )

    {:ok, ctx: ctx}
  end

  test "a build's lifecycle round-trips as the status tool's map", %{ctx: ctx} do
    :ok = BuildRecords.record_started(ctx, "build_x", "reagent:local.demo:0.1.0")

    assert {:ok, started} = BuildRecords.get(ctx, "build_x")
    assert started["build_id"] == "build_x"
    assert started["reference"] == "reagent:local.demo:0.1.0"
    assert started["status"] == "started"
    assert is_binary(started["started_at"])
    refute Map.has_key?(started, "finished_at")

    :ok = BuildRecords.record_finished(ctx, "build_x", "compiled", %{"digest" => "sha256:abc"})

    assert {:ok, done} = BuildRecords.get(ctx, "build_x")
    assert done["status"] == "compiled"
    assert done["result"] == %{"digest" => "sha256:abc"}
    assert is_binary(done["finished_at"])
  end

  test "a failure records its error string", %{ctx: ctx} do
    :ok = BuildRecords.record_started(ctx, "build_f", "reagent:local.demo:0.1.0")
    :ok = BuildRecords.record_finished(ctx, "build_f", "failed", "cargo exploded")

    assert {:ok, record} = BuildRecords.get(ctx, "build_f")
    assert record["status"] == "failed"
    assert record["error"] == "cargo exploded"
    refute Map.has_key?(record, "result")
  end

  test "registration outcome lands on the finished row, and a missing row is a no-op", %{
    ctx: ctx
  } do
    :ok = BuildRecords.record_started(ctx, "build_r", "reagent:local.demo:0.1.0")

    :ok =
      BuildRecords.record_finished(ctx, "build_r", "compiled", %{
        "digest" => "sha256:abc",
        "registration" => "pending"
      })

    :ok = BuildRecords.record_registration(ctx, "build_r", "done")

    assert {:ok, %{"result" => result}} = BuildRecords.get(ctx, "build_r")
    assert result["registration"] == "done"
    assert result["digest"] == "sha256:abc"

    # Sync builds have no row — the outcome went to the caller inline.
    assert :ok = BuildRecords.record_registration(ctx, "build_none", "done", 1)
  end

  test "records are tenant-scoped", %{ctx: ctx} do
    :ok = BuildRecords.record_started(ctx, "build_t", "reagent:local.demo:0.1.0")

    other = %{ctx | athanor_id: "ath_other_#{:rand.uniform(100_000)}"}
    assert {:error, :not_found} = BuildRecords.get(other, "build_t")
    assert {:error, :not_found} = BuildRecords.record_finished(other, "build_t", "failed", "no")

    # The foreign finish touched nothing.
    assert {:ok, %{"status" => "started"}} = BuildRecords.get(ctx, "build_t")
  end
end

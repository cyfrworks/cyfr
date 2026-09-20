# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.BuildRecordsTest do
  @moduledoc """
  The build-record rows, and who may reach them.

  Two properties carry the tenancy: a build id is caller-supplied, so a
  row of another athanor must read exactly like no row at all; and the
  facade takes the actor, so a caller that cannot name an athanor is
  refused before a connection is asked for anything.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.BuildRecords

  setup context do
    unless context[:no_connection] do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    end

    rand = :rand.uniform(100_000)

    {:ok, actor: actor("ath_build_#{rand}", "build_user_#{rand}")}
  end

  defp actor(athanor_id, user_id \\ "build_user"),
    do: %Cyfr.Actor{athanor_id: athanor_id, user_id: user_id, authenticated: true}

  test "a build's lifecycle round-trips as the status tool's map", %{actor: actor} do
    :ok = BuildRecords.record_started(actor, "build_x", "reagent:local.demo:0.1.0")

    assert {:ok, started} = BuildRecords.get(actor, "build_x")
    assert started["build_id"] == "build_x"
    assert started["reference"] == "reagent:local.demo:0.1.0"
    assert started["status"] == "started"
    assert is_binary(started["started_at"])
    refute Map.has_key?(started, "finished_at")

    :ok = BuildRecords.record_finished(actor, "build_x", "compiled", %{"digest" => "sha256:abc"})

    assert {:ok, done} = BuildRecords.get(actor, "build_x")
    assert done["status"] == "compiled"
    assert done["result"] == %{"digest" => "sha256:abc"}
    assert is_binary(done["finished_at"])
  end

  test "a failure records its error string", %{actor: actor} do
    :ok = BuildRecords.record_started(actor, "build_f", "reagent:local.demo:0.1.0")
    :ok = BuildRecords.record_finished(actor, "build_f", "failed", "cargo exploded")

    assert {:ok, record} = BuildRecords.get(actor, "build_f")
    assert record["status"] == "failed"
    assert record["error"] == "cargo exploded"
    refute Map.has_key?(record, "result")
  end

  test "registration outcome lands on the finished row, and a missing row is a no-op", %{
    actor: actor
  } do
    :ok = BuildRecords.record_started(actor, "build_r", "reagent:local.demo:0.1.0")

    :ok =
      BuildRecords.record_finished(actor, "build_r", "compiled", %{
        "digest" => "sha256:abc",
        "registration" => "pending"
      })

    :ok = BuildRecords.record_registration(actor, "build_r", "done")

    assert {:ok, %{"result" => result}} = BuildRecords.get(actor, "build_r")
    assert result["registration"] == "done"
    assert result["digest"] == "sha256:abc"

    # Sync builds have no row — the outcome went to the caller inline.
    assert :ok = BuildRecords.record_registration(actor, "build_none", "done", 1)
  end

  test "records are tenant-scoped", %{actor: actor} do
    :ok = BuildRecords.record_started(actor, "build_t", "reagent:local.demo:0.1.0")

    other = actor("ath_other_#{:rand.uniform(100_000)}")
    assert {:error, :not_found} = BuildRecords.get(other, "build_t")
    assert {:error, :not_found} = BuildRecords.record_finished(other, "build_t", "failed", "no")

    # The foreign finish touched nothing.
    assert {:ok, %{"status" => "started"}} = BuildRecords.get(actor, "build_t")
  end

  test "a foreign start cannot overwrite another athanor's record", %{actor: actor} do
    # Caller-supplied build ids must be scoped to the caller's athanor.
    :ok = BuildRecords.record_started(actor, "build_shared", "reagent:local.demo:0.1.0")

    :ok =
      BuildRecords.record_finished(actor, "build_shared", "compiled", %{"digest" => "sha256:a"})

    other = actor("ath_other_#{:rand.uniform(100_000)}")

    assert {:error, :not_found} =
             BuildRecords.record_started(other, "build_shared", "reagent:evil.x:9.9.9")

    assert {:ok, mine} = BuildRecords.get(actor, "build_shared")
    assert mine["status"] == "compiled"
    assert mine["result"] == %{"digest" => "sha256:a"}
    assert mine["reference"] == "reagent:local.demo:0.1.0"

    # ...and the foreign athanor got no row of its own out of the attempt.
    assert {:error, :not_found} = BuildRecords.get(other, "build_shared")
  end

  test "restarting a build of one's own id still overwrites the stale row", %{actor: actor} do
    :ok = BuildRecords.record_started(actor, "build_retry", "reagent:local.demo:0.1.0")
    :ok = BuildRecords.record_finished(actor, "build_retry", "failed", "boom")

    :ok = BuildRecords.record_started(actor, "build_retry", "reagent:local.demo:0.2.0")

    assert {:ok, again} = BuildRecords.get(actor, "build_retry")
    assert again["status"] == "started"
    assert again["reference"] == "reagent:local.demo:0.2.0"
    refute Map.has_key?(again, "error")
  end

  test "a registration outcome cannot be written onto another athanor's row", %{actor: actor} do
    :ok = BuildRecords.record_started(actor, "build_reg", "reagent:local.demo:0.1.0")

    :ok =
      BuildRecords.record_finished(actor, "build_reg", "compiled", %{
        "digest" => "sha256:abc",
        "registration" => "pending"
      })

    other = actor("ath_other_#{:rand.uniform(100_000)}")
    # One attempt: a foreign row reads as no row, which is the no-op arm.
    assert :ok = BuildRecords.record_registration(other, "build_reg", "stolen", 1)

    assert {:ok, %{"result" => result}} = BuildRecords.get(actor, "build_reg")
    assert result["registration"] == "pending"
  end

  test "prune keeps the newest rows of the actor's athanor and no one else's", %{actor: actor} do
    other = actor("ath_other_#{:rand.uniform(100_000)}")
    base = DateTime.add(DateTime.utc_now(), -:timer.hours(48), :millisecond)

    for n <- 1..3 do
      id = "build_p#{n}"
      :ok = BuildRecords.record_started(actor, id, "reagent:local.demo:0.#{n}.0")
      :ok = BuildRecords.record_finished(actor, id, "compiled", %{"digest" => "sha256:#{n}"})
      backdate(actor, id, DateTime.add(base, n, :second))
    end

    :ok = BuildRecords.record_started(other, "build_theirs", "reagent:local.demo:9.9.9")
    :ok = BuildRecords.record_finished(other, "build_theirs", "compiled", %{"digest" => "x"})
    backdate(other, "build_theirs", base)

    assert {:ok, 2} = BuildRecords.prune(actor, 1, dry_run: true)
    assert {:ok, 2} = BuildRecords.prune(actor, 1)

    assert {:ok, %{"build_id" => "build_p3"}} = BuildRecords.get(actor, "build_p3")
    assert {:error, :not_found} = BuildRecords.get(actor, "build_p1")
    # The other athanor's row was never in the sweep's sight.
    assert {:ok, _} = BuildRecords.get(other, "build_theirs")
  end

  describe "the actor is the only tenant this facade accepts" do
    setup do
      ctx =
        Sanctum.Context.build(
          user_id: "usr_ctx",
          athanor_id: "ath_ctx",
          permissions: [:*],
          scope: :athanor,
          authenticated: true
        )

      {:ok, ctx: ctx}
    end

    @tag :no_connection
    test "a Sanctum context matches no head", %{ctx: ctx} do
      assert_raise FunctionClauseError, fn ->
        BuildRecords.get(ctx, "build_ctx")
      end

      assert_raise FunctionClauseError, fn ->
        BuildRecords.record_started(ctx, "build_ctx", "reagent:local.demo:0.1.0")
      end

      assert_raise FunctionClauseError, fn ->
        BuildRecords.record_finished(ctx, "build_ctx", "failed", "no")
      end

      assert_raise FunctionClauseError, fn ->
        BuildRecords.prune(ctx, 10)
      end
    end

    # Through `apply/3`, because the type checker reads the heads and
    # refuses the direct call at compile time — which is the point being
    # asserted, one layer earlier than this test can reach.
    @tag :no_connection
    test "a bare athanor id matches no head" do
      assert_raise FunctionClauseError, fn ->
        apply(BuildRecords, :get, ["ath_ctx", "build_ctx"])
      end

      assert_raise FunctionClauseError, fn ->
        apply(BuildRecords, :record_started, ["ath_ctx", "build_ctx", "reagent:local.demo:0.1.0"])
      end

      assert_raise FunctionClauseError, fn -> apply(BuildRecords, :prune, ["ath_ctx", 10]) end
    end

    # No sandbox connection is checked out and the repo is in manual mode,
    # so a query cannot answer here — it raises. A refusal is therefore a
    # refusal taken before the query, not a query that found nothing.
    @tag :no_connection
    test "an actor with no athanor is refused before any query runs" do
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)

      assert_raise DBConnection.OwnershipError, fn ->
        Arca.Repo.aggregate(Arca.Schemas.BuildRecord, :count)
      end

      nobody = %Cyfr.Actor{athanor_id: nil, user_id: "usr_nobody"}

      assert {:error, :no_athanor} = BuildRecords.get(nobody, "build_x")

      assert {:error, :no_athanor} =
               BuildRecords.record_started(nobody, "build_x", "reagent:local.demo:0.1.0")

      assert {:error, :no_athanor} =
               BuildRecords.record_finished(nobody, "build_x", "failed", "no")

      assert {:error, :no_athanor} = BuildRecords.record_registration(nobody, "build_x", "done")
      assert {:error, :no_athanor} = BuildRecords.prune(nobody, 10)
    end

    # The witness for the clause above: with a connection, the same calls
    # would have reached the database.
    test "the same calls do reach the database once the actor carries an athanor", %{
      actor: actor
    } do
      assert {:error, :not_found} = BuildRecords.get(actor, "build_absent")
      assert {:ok, 0} = BuildRecords.prune(actor, 10)
    end
  end

  # `record_started` writes `started_at` itself, so ordering a prune's
  # input means writing the column directly.
  defp backdate(%Cyfr.Actor{athanor_id: athanor_id}, build_id, at) do
    {1, _} =
      Arca.Schemas.BuildRecord
      |> where([b], b.id == ^build_id and b.athanor_id == ^athanor_id)
      |> Arca.Repo.update_all(set: [started_at: at])
  end
end

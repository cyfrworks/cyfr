# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.BarrierRefusalTest do
  @moduledoc """
  A run an admission barrier refuses before its row exists — an expired
  hold, a superseded step, an occurrence not claimed, a child whose parent
  attempt ended — answers the refusal and records nothing: no row, no
  second admission, no start or exception telemetry and no error log.
  That holds when the barrier refuses the run's own row, and when it
  refuses the row an earlier refusal would have been recorded on.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cyfr.Authority
  alias Cyfr.Execution.Admission

  @math_wasm_path Path.expand("../../support/test_wasm/math.wasm", __DIR__)
  @reference "reagent:local.barrier-target:0.1.0"
  @lifecycle [[:cyfr, :opus, :execute, :start], [:cyfr, :opus, :execute, :exception]]
  @parent_ended "Execution refused: its parent execution is no longer running"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "barrier_#{System.unique_integer([:positive])}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    ctx = Sanctum.TestContext.local()

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "barrier-target",
        version: "0.1.0",
        type: "reagent",
        description: "Barrier refusal test component"
      })

    test = self()
    handler = "barrier-lifecycle-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      @lifecycle,
      fn event, _measurements, metadata, _config ->
        send(test, {:lifecycle, event, metadata[:execution_id]})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, ctx: ctx}
  end

  # A parent row whose attempt has since ended, and an attempt id that is
  # not the one owning it.
  defp ended_parent(ctx) do
    parent_id = Cyfr.UUID7.execution_id()

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: parent_id,
          reference: "formula:local.barrier-parent:0.1.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        Cyfr.Test.AttemptFixtures.standing(ctx.athanor_id)
      )

    {:ok, _} =
      Arca.Execution.record_end(
        Sanctum.Context.actor(ctx),
        parent_id,
        "completed",
        %{completed_at: DateTime.utc_now(), duration_ms: 1, output: "{}"},
        attempt.attempt,
        Cyfr.Test.AttemptFixtures.stored()
      )

    [
      parent_execution_id: parent_id,
      root_execution_id: parent_id,
      parent_attempt: attempt.attempt
    ]
  end

  defp barriers(ctx) do
    [
      {:hold_expired, [charge: %{reservation_id: "rsv_gone", id: "chg_gone"}], :hold_expired},
      {:step_superseded, [step: %{id: "step_gone", generation: 0}], :step_superseded},
      {:occurrence_not_claimed, [occurrence_id: "occ_gone"], :occurrence_not_claimed},
      {:parent_ended, ended_parent(ctx), @parent_ended}
    ]
  end

  defp admit(ctx, input, barrier_opts) do
    execution_id = Cyfr.UUID7.execution_id()
    opts = [authority: Authority.zero(), execution_id: execution_id] ++ barrier_opts

    log =
      capture_log([level: :error], fn ->
        send(self(), {:answer, Admission.admit(ctx, @reference, input, opts)})
      end)

    assert_received {:answer, answer}
    {answer, execution_id, log}
  end

  defp assert_nothing_recorded(execution_id, log) do
    assert Arca.Repo.get(Arca.Execution, execution_id) == nil
    refute_received {:lifecycle, _event, ^execution_id}
    assert log == ""
  end

  test "a barrier that refuses the run's row answers its refusal and records nothing", %{ctx: ctx} do
    for {kind, barrier_opts, refusal} <- barriers(ctx) do
      {answer, execution_id, log} = admit(ctx, %{"a" => 1}, barrier_opts)

      assert answer == {:error, refusal}, "#{kind} answered #{inspect(answer)}"
      assert_nothing_recorded(execution_id, log)
    end
  end

  test "a barrier that refuses the row a refusal would be recorded on answers its refusal and records nothing",
       %{ctx: ctx} do
    oversized = %{"blob" => String.duplicate("x", Authority.zero_limits().max_request_size + 1)}

    for {kind, barrier_opts, refusal} <- barriers(ctx) do
      {answer, execution_id, log} = admit(ctx, oversized, barrier_opts)

      assert answer == {:error, refusal}, "#{kind} answered #{inspect(answer)}"
      assert_nothing_recorded(execution_id, log)
    end
  end

  test "a refusal with no barrier in its way is recorded failed", %{ctx: ctx} do
    oversized = %{"blob" => String.duplicate("x", Authority.zero_limits().max_request_size + 1)}
    {answer, execution_id, _log} = admit(ctx, oversized, [])

    assert {:error, "Input size" <> _} = answer
    assert %{status: "failed"} = Arca.Repo.get(Arca.Execution, execution_id)
    assert_received {:lifecycle, [:cyfr, :opus, :execute, :start], ^execution_id}
    assert_received {:lifecycle, [:cyfr, :opus, :execute, :exception], ^execution_id}
  end
end

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RestartRequiredTest do
  # §4.4: runtime consent does not resume the running execution. A delta
  # revision commits for future roots; the in-flight execution — which may
  # already have taken side effects under the authority it started with —
  # terminates carrying restart_required, and the operator re-runs.
  use ExUnit.Case, async: false

  alias Opus.ExecutionRecord

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp running!(ctx) do
    record =
      ExecutionRecord.new(ctx, "formula:local.restarter:1.0.0", %{}, component_type: :formula)

    :ok = ExecutionRecord.write_started(record)
    record
  end

  @payload %{
    profile_id: "prof-restart",
    new_revision: 2,
    missing: %{
      chain: ["formula:local.restarter"],
      edge: "catalyst:local.gmail",
      activation: "sha256:act"
    }
  }

  test "the running execution terminates carrying the typed payload", %{ctx: ctx} do
    record = running!(ctx)

    Phoenix.PubSub.subscribe(
      Emissary.PubSub,
      Sanctum.PubSub.topic("execution:events:#{record.id}", ctx)
    )

    assert {:ok, %{cancelled: true}} =
             Opus.Executor.cancel_for_restart(ctx, record.id, @payload)

    assert_receive {:execution_event, event}, 2_000
    assert event.type == "restart_required"
    assert event.origin == "host"
    assert event.data.profile_id == "prof-restart"
    assert event.data.new_revision == 2
    assert event.data.missing.edge == "catalyst:local.gmail"
  end

  test "the execution is really stopped, not re-bound", %{ctx: ctx} do
    record = running!(ctx)

    {:ok, _} = Opus.Executor.cancel_for_restart(ctx, record.id, @payload)

    {:ok, reloaded} = ExecutionRecord.get(ctx, record.id)
    assert reloaded.status == :cancelled

    # And it cannot be restarted in place — a re-run is a new execution.
    assert {:error, :not_cancellable} =
             Opus.Executor.cancel_for_restart(ctx, record.id, @payload)
  end

  test "an ordinary cancel still reports as cancelled", %{ctx: ctx} do
    record = running!(ctx)

    Phoenix.PubSub.subscribe(
      Emissary.PubSub,
      Sanctum.PubSub.topic("execution:events:#{record.id}", ctx)
    )

    assert {:ok, _} = Opus.Executor.cancel(ctx, record.id)

    assert_receive {:execution_event, event}, 2_000
    assert event.type == "cancelled"
    assert event.data == %{}
  end

  test "a surface reading the event sees a payload it can act on", %{ctx: ctx} do
    record = running!(ctx)

    Phoenix.PubSub.subscribe(
      Emissary.PubSub,
      Sanctum.PubSub.topic("execution:events:#{record.id}", ctx)
    )

    {:ok, _} = Opus.Executor.cancel_for_restart(ctx, record.id, @payload)
    assert_receive {:execution_event, event}, 2_000

    # Everything the console needs to say "approved — re-run to continue"
    # and to show what was missing, without re-deriving anything.
    assert %{profile_id: _, new_revision: _, missing: %{chain: _, edge: _, activation: _}} =
             event.data
  end
end

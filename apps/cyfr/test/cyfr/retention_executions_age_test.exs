# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Retention.ExecutionsAgeTest do
  use ExUnit.Case, async: false

  alias Arca.Execution
  alias Cyfr.Retention.ExecutionsAge

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp execution!(ctx, days_ago, status) do
    id = "exec_age_#{System.unique_integer([:positive])}"
    started = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    {:ok, _} =
      Execution.record_start(%{
        id: id,
        reference: "catalyst:local.test:1.0.0",
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        started_at: started,
        status: "running",
        component_type: "catalyst"
      })

    if status != "running" do
      {:ok, _} =
        Execution.record_complete(
          Sanctum.Context.actor(ctx),
          id,
          %{
            completed_at: DateTime.add(started, 1, :second),
            duration_ms: 1000,
            status: status
          },
          Cyfr.Test.AttemptFixtures.standing(ctx.athanor_id)
        )
    end

    id
  end

  test "rows older than the bound go; a running one never does", %{ctx: ctx} do
    old = execution!(ctx, 120, "completed")
    old_running = execution!(ctx, 120, "running")
    recent = execution!(ctx, 3, "failed")

    assert ExecutionsAge.key() == "execution_days"
    assert ExecutionsAge.unit() == :days
    assert {:ok, 1} = ExecutionsAge.prune(ctx, 90, true)
    assert {:ok, 1} = ExecutionsAge.prune(ctx, 90, false)

    assert is_nil(Execution.get_tenant(Sanctum.Context.actor(ctx), old))
    refute is_nil(Execution.get_tenant(Sanctum.Context.actor(ctx), old_running))
    refute is_nil(Execution.get_tenant(Sanctum.Context.actor(ctx), recent))
  end

  test "the kind is on the roster the settings document derives from" do
    assert ExecutionsAge in Cyfr.Retention.kinds()
    {:ok, settings} = Cyfr.Retention.get_settings(Sanctum.TestContext.local())
    assert settings["execution_days"] == 90
  end
end

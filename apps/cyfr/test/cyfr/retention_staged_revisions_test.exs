# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RetentionStagedRevisionsTest do
  @moduledoc """
  The staged-revisions kind: on the roster, a day's grace by default,
  per athanor on the retention tick, and nothing at all on a boot that
  does not own the control plane.
  """

  use ExUnit.Case, async: false

  alias Arca.Storage.UnitLocator
  alias Arca.ControlPlane
  alias Cyfr.Retention.StagedRevisions

  @sentinel "cyfr-manifest.json"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "retention_staged_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, Path.join(base, "data"))

    on_exit(fn ->
      ControlPlane.record(:unclaimed)
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    {:ok, athanor} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "group",
        name: "Staging",
        slug: "staging-#{System.unique_integer([:positive])}",
        created_by: "test"
      })

    ctx =
      Sanctum.internal_context(
        user_id: "system",
        athanor_id: athanor.id,
        scope: :athanor,
        permissions: [:storage_read, :storage_write]
      )

    name = "kind-#{System.unique_integer([:positive])}"
    {:ok, ctx: ctx, unit: ["components", "catalysts", "local", name, "1.0.0"]}
  end

  # A whole revision no row names, begun `days` ago by its name's own time.
  defp lay_orphan(ctx, unit, days) do
    begun = System.system_time(:millisecond) - days * 86_400_000
    revision = "rev_" <> Cyfr.UUID7.generate_at(begun)

    for {rel, bytes} <- [{[@sentinel], "{}"}, {["a.txt"], "a"}] do
      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          UnitLocator.staged_object(unit, revision, rel),
          bytes
        )
    end

    revision
  end

  defp staged(ctx, unit) do
    {:ok, leaves} =
      Arca.list_recursive(Sanctum.Context.actor(ctx), UnitLocator.staging_prefix(unit))

    leaves |> Enum.map(&Enum.at(&1, length(unit) + 1)) |> Enum.uniq()
  end

  test "is on the roster, in days, a day by default" do
    assert StagedRevisions in Cyfr.Retention.kinds()
    assert StagedRevisions.key() == "staging_days"
    assert StagedRevisions.unit() == :days
    assert StagedRevisions.default() == 1
    assert StagedRevisions.limit() > 0

    Application.put_env(:cyfr, Cyfr.Retention, staging_days: 3, staging_sweep_limit: 7)
    on_exit(fn -> Application.delete_env(:cyfr, Cyfr.Retention) end)

    assert StagedRevisions.default() == 3
    assert StagedRevisions.limit() == 7
  end

  test "collects what is older than the athanor's days, and counts on a dry run", %{
    ctx: ctx,
    unit: unit
  } do
    old = lay_orphan(ctx, unit, 3)
    young = lay_orphan(ctx, unit, 0)

    assert {:ok, 0} = Cyfr.Retention.cleanup(ctx, "staging_days", value: 5)
    assert {:ok, 1} = Cyfr.Retention.cleanup(ctx, "staging_days", dry_run: true)
    assert Enum.sort(staged(ctx, unit)) == Enum.sort([old, young])

    assert {:ok, 1} = Cyfr.Retention.cleanup(ctx, "staging_days")
    assert staged(ctx, unit) == [young]
  end

  test "reports each sweep as telemetry", %{ctx: ctx, unit: unit} do
    lay_orphan(ctx, unit, 3)
    test_pid = self()
    handler = "staged-revisions-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:cyfr, :storage_gc, :sweep],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:swept, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, 1} = Cyfr.Retention.cleanup(ctx, "staging_days")
    athanor_id = ctx.athanor_id

    assert_received {:swept, %{collected: 1, examined: 1, errors: 0},
                     %{athanor_id: ^athanor_id, dry_run: false}}
  end

  test "refuses on a boot that does not own the control plane", %{ctx: ctx, unit: unit} do
    old = lay_orphan(ctx, unit, 3)

    ControlPlane.record(:lost)
    assert {:error, :control_plane_lost} = Cyfr.Retention.cleanup(ctx, "staging_days")
    assert {:error, :control_plane_lost} = StagedRevisions.prune(ctx, 1, true)
    assert staged(ctx, unit) == [old]
  end

  test "the retention tick sweeps nothing without ownership, and sweeps once it is regained", %{
    ctx: ctx,
    unit: unit
  } do
    old = lay_orphan(ctx, unit, 3)
    state = %{interval: :timer.hours(999)}

    ControlPlane.record(:lost)
    assert {:noreply, ^state} = Cyfr.RetentionScheduler.handle_info(:run_cleanup, state)
    assert staged(ctx, unit) == [old]

    ControlPlane.record(:unclaimed)
    assert {:noreply, ^state} = Cyfr.RetentionScheduler.handle_info(:run_cleanup, state)
    assert staged(ctx, unit) == []
  end
end

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RetentionTest do
  @moduledoc """
  The retention policy the storage layer owns (`Arca.Retention`): the
  roster, the settings an athanor sets in its own row, one kind's cleanup
  for a caller and the whole policy for the server's walk — and the
  refusals that keep a destructive sweep from running on settings it
  could not read, or under an actor that is not the server's own.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Retention
  alias Arca.Schemas.{RetentionSettings, StorageProjectionChange}
  alias Arca.{StorageProjectionChanges, StorageProjectionRoots, StorageUnits}

  setup do
    # Use a test-specific base path for file-based operations (blobs)
    rand_id = System.unique_integer([:positive])
    test_path = Path.join(System.tmp_dir!(), "retention_test_#{rand_id}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # A unique athanor per test: retention is per athanor, so a unique id
    # isolates each test's rows from every other's.
    athanor = "ath_retention_#{rand_id}"

    ctx =
      Sanctum.Context.build(
        user_id: "retention_test_user_#{rand_id}",
        namespace: "retention_test_user_#{rand_id}",
        athanor_id: athanor,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx), system: system_actor(athanor)}
  end

  # The actor the scheduler hands each estate: the server's own, inside
  # that one athanor.
  defp system_actor(athanor) do
    Sanctum.Context.actor(
      Sanctum.internal_context(
        user_id: "_retention",
        athanor_id: athanor,
        scope: :athanor,
        permissions: [:storage_read, :storage_write]
      )
    )
  end

  # ============================================================================
  # The roster
  # ============================================================================

  describe "kinds/0" do
    test "every kind implements the behaviour, with a unique key" do
      kinds = Retention.kinds()
      assert [_ | _] = kinds

      for kind <- kinds do
        assert is_binary(kind.key())
        assert kind.default() > 0
        assert kind.unit() in [:keep, :days]
      end

      keys = Enum.map(kinds, & &1.key())
      assert keys == Enum.uniq(keys)
    end

    test "the projection tombstones are the thirteenth kind, in days, a week by default" do
      assert length(Retention.kinds()) == 13
      assert List.last(Retention.kinds()) == Retention.ProjectionTombstones
      assert Retention.ProjectionTombstones.key() == "projection_tombstone_days"
      assert Retention.ProjectionTombstones.unit() == :days
      assert Retention.ProjectionTombstones.default() == 7
    end

    test "config :arca, Arca.Retention overrides a kind's default" do
      previous = Application.fetch_env(:arca, Arca.Retention)

      on_exit(fn ->
        case previous do
          {:ok, config} -> Application.put_env(:arca, Arca.Retention, config)
          :error -> Application.delete_env(:arca, Arca.Retention)
        end
      end)

      Application.put_env(:arca, Arca.Retention, executions: 5, builds: 3)

      assert Retention.Executions.default() == 5
      assert Retention.Builds.default() == 3
      assert Retention.McpLogs.default() == 30

      Application.delete_env(:arca, Arca.Retention)
      assert Retention.Executions.default() == 10_000
    end
  end

  describe "default_class/1" do
    test "a webhook's, the server's own, and everything else" do
      assert Retention.default_class(%Prima.Actor{user_id: "webhook:wh_1"}) == "webhook"
      assert Retention.default_class(%Prima.Actor{user_id: "usr_1", system: true}) == "system"
      assert Retention.default_class(%Prima.Actor{user_id: "usr_1"}) == "api"
    end
  end

  # ============================================================================
  # Settings
  # ============================================================================

  describe "get_settings/set_settings" do
    test "defaults cover every kind when nothing is configured", %{actor: actor} do
      {:ok, settings} = Retention.get_settings(actor)

      for kind <- Retention.kinds() do
        assert settings[kind.key()] == kind.default()
      end
    end

    test "set_settings answers the merged settings, and get_settings reads them", %{actor: actor} do
      assert {:ok, set} = Retention.set_settings(actor, %{"executions" => 5, "builds" => 3})
      assert set["executions"] == 5
      assert set["builds"] == 3
      assert set["mcp_log_days"] == Retention.McpLogs.default()

      assert {:ok, ^set} = Retention.get_settings(actor)
    end

    test "partial update preserves other settings", %{actor: actor} do
      {:ok, _} = Retention.set_settings(actor, %{"executions" => 5, "builds" => 3})
      {:ok, _} = Retention.set_settings(actor, %{"executions" => 20})

      {:ok, settings} = Retention.get_settings(actor)
      assert settings["executions"] == 20
      assert settings["builds"] == 3
    end

    test "an estate with no athanor row sets and reads its own settings" do
      # The settings are the storage layer's own row, not a column of the
      # athanor's: nothing about the athanor row is asked for.
      actor = %Prima.Actor{athanor_id: "ath_rowless_#{System.unique_integer([:positive])}"}

      assert {:ok, %{"executions" => 10_000}} = Retention.get_settings(actor)
      assert {:ok, %{"executions" => 5}} = Retention.set_settings(actor, %{"executions" => 5})
      assert {:ok, %{"executions" => 5}} = Retention.get_settings(actor)
    end

    test "a retention key in the athanor's security settings is inert", %{actor: actor} do
      athanor = Arca.Test.Actor.ensure_athanor_row(actor.athanor_id)

      {:ok, _} =
        Sanctum.Tenancy.Athanors.put_settings(athanor, %{"retention" => %{"executions" => 1}})

      assert {:ok, %{"executions" => 10_000}} = Retention.get_settings(actor)
    end

    test "settings are isolated across athanors" do
      # Within an athanor, members share settings (one config); the isolation
      # boundary is the athanor, not the user.
      a = %Prima.Actor{athanor_id: "ath_a_#{System.unique_integer([:positive])}", user_id: "u1"}
      b = %Prima.Actor{athanor_id: "ath_b_#{System.unique_integer([:positive])}", user_id: "u2"}

      {:ok, _} = Retention.set_settings(a, %{"executions" => 5})
      {:ok, _} = Retention.set_settings(b, %{"executions" => 15})

      assert {:ok, %{"executions" => 5}} = Retention.get_settings(a)
      assert {:ok, %{"executions" => 15}} = Retention.get_settings(b)
      assert {:ok, %{"executions" => 5}} = Retention.get_settings(%{a | user_id: "u3"})
    end

    test "refuses invalid values and unknown keys, typed", %{actor: actor} do
      # Every key drives destructive cleanup — a bad value refuses rather
      # than silently keeping the old one, so the caller learns.
      for bad <- [-5, 0, "nope", "7x", 1.5, nil, 9_007_199_254_740_992] do
        assert {:error, {:invalid_setting, "executions"}} =
                 Retention.set_settings(actor, %{"executions" => bad})
      end

      assert {:error, {:unknown_setting, "made_up"}} =
               Retention.set_settings(actor, %{"made_up" => 3})

      {:ok, settings} = Retention.get_settings(actor)
      assert settings["executions"] == 10_000
    end

    test "coerces integer strings", %{actor: actor} do
      assert {:ok, %{"executions" => 7}} = Retention.set_settings(actor, %{"executions" => "7"})
    end

    test "corrupt settings refuse, rather than read as the defaults", %{actor: actor} do
      store!(actor.athanor_id, ~s({"executions": 0}))
      assert {:error, :corrupt} = Retention.get_settings(actor)
      assert {:error, :corrupt} = Retention.set_settings(actor, %{"builds" => 3})
    end

    test "settings that cannot be read refuse", %{actor: actor} do
      drop_settings!()
      assert {:error, :database_error} = Retention.get_settings(actor)
    end

    test "an actor with no athanor is refused" do
      for nobody <- [%Prima.Actor{}, %Prima.Actor{athanor_id: ""}, %Prima.Actor{scope: :platform}] do
        assert {:error, :no_athanor} = Retention.get_settings(nobody)
        assert {:error, :no_athanor} = Retention.set_settings(nobody, %{"executions" => 5})
        assert {:error, :no_athanor} = Retention.cleanup(nobody, "executions")
        assert {:error, :no_athanor} = Retention.cleanup(nobody, "executions", value: 5)
      end
    end
  end

  # ============================================================================
  # cleanup/3 — one verb, every kind
  # ============================================================================

  describe "cleanup/3" do
    test "an invalid override refuses typed, before any row is touched", %{actor: actor} do
      create_execution_with_timestamp(actor, "exec_1", "2025-01-01T10:00:00Z")
      create_execution_with_timestamp(actor, "exec_2", "2025-01-02T10:00:00Z")

      for bad <- [0, -1, "1", 1.5, nil] do
        assert {:error, {:invalid_setting, "executions"}} =
                 Retention.cleanup(actor, "executions", value: bad)
      end

      assert length(executions(actor)) == 2
    end

    test "corrupt settings refuse cleanup, an override included", %{actor: actor} do
      store!(actor.athanor_id, ~s(["executions", 1]))
      create_execution_with_timestamp(actor, "exec_1", "2025-01-01T10:00:00Z")
      create_execution_with_timestamp(actor, "exec_2", "2025-01-02T10:00:00Z")

      assert {:error, :corrupt} = Retention.cleanup(actor, "executions")
      assert {:error, :corrupt} = Retention.cleanup(actor, "executions", dry_run: true)
      assert {:error, :corrupt} = Retention.cleanup(actor, "executions", value: 1)
      assert length(executions(actor)) == 2
    end

    test "settings that cannot be read refuse cleanup", %{actor: actor} do
      drop_settings!()
      assert {:error, :database_error} = Retention.cleanup(actor, "executions", value: 1)
    end

    test "an unknown kind refuses typed", %{actor: actor} do
      assert {:error, {:unknown_kind, "nonsense"}} = Retention.cleanup(actor, "nonsense")
    end
  end

  describe "cleanup/3 executions" do
    test "returns 0 when no executions exist", %{actor: actor} do
      assert {:ok, 0} = Retention.cleanup(actor, "executions")
    end

    test "keeps executions when count is below limit", %{actor: actor} do
      for i <- 1..3 do
        create_execution_with_timestamp(actor, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 0} = Retention.cleanup(actor, "executions", value: 10)
      assert length(executions(actor)) == 3
    end

    test "deletes oldest executions past the athanor's configured value", %{actor: actor} do
      {:ok, _} = Retention.set_settings(actor, %{"executions" => 3})

      for i <- 1..5 do
        create_execution_with_timestamp(actor, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 2} = Retention.cleanup(actor, "executions")

      ids = Enum.map(executions(actor), & &1.id)
      assert length(ids) == 3
      refute "exec_1" in ids
      refute "exec_2" in ids
    end

    test "dry_run counts without deleting", %{actor: actor} do
      for i <- 1..5 do
        create_execution_with_timestamp(actor, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 2} = Retention.cleanup(actor, "executions", value: 3, dry_run: true)
      assert length(executions(actor)) == 5
    end

    test "a running execution is never stale, whatever its age", %{actor: actor} do
      # Retain running executions regardless of age so completion and cancellation remain possible.
      create_execution_with_timestamp(actor, "exec_live", "2025-01-01T10:00:00Z", "running")

      for i <- 2..5 do
        create_execution_with_timestamp(actor, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 1} = Retention.cleanup(actor, "executions", value: 3)

      ids = Enum.map(executions(actor), & &1.id)
      assert "exec_live" in ids, "retention deleted a running execution mid-flight"
      refute "exec_2" in ids
    end
  end

  describe "cleanup/3 builds" do
    test "returns 0 when no builds exist", %{actor: actor} do
      assert {:ok, 0} = Retention.cleanup(actor, "builds")
    end

    test "deletes oldest builds when over limit", %{actor: actor} do
      for i <- 1..5 do
        create_build_with_timestamp(actor, "build_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 2} = Retention.cleanup(actor, "builds", value: 3)
      assert build_ids(actor) == ["build_3", "build_4", "build_5"]
    end

    test "dry_run counts the oldest builds without deleting", %{actor: actor} do
      for i <- 1..4 do
        create_build_with_timestamp(actor, "build_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 2} = Retention.cleanup(actor, "builds", value: 2, dry_run: true)
      assert length(build_ids(actor)) == 4
    end

    test "a build still running is never pruned", %{actor: actor} do
      # Keep the started build outside the retention rank but inside the grace window to exercise the status guard.
      now = DateTime.utc_now()

      :ok = Arca.BuildRecords.record_started(actor, "build_live", "reagent:local.test:0.1.0")

      pin_started_at("build_live", DateTime.add(now, -5, :minute))

      for i <- 1..4 do
        create_build_with_timestamp(actor, "build_#{i}", "2025-01-01T10:00:00Z")
        pin_started_at("build_#{i}", DateTime.add(now, -i, :minute))
      end

      assert {:ok, 1} = Retention.cleanup(actor, "builds", value: 3)

      ids = build_ids(actor)
      assert "build_live" in ids, "retention pruned a build still running"
      refute "build_4" in ids
    end

    test "a build orphaned at 'started' is collected once it cannot be running", %{actor: actor} do
      # Build records have no sweeper and no lease — nothing ever moves an
      # abandoned row off "started" (a node restart mid-build, or a build
      # task that ended with its watcher). Excluding the status
      # outright made those rows immortal and `keep` stopped being a cap.
      :ok = Arca.BuildRecords.record_started(actor, "build_orphan", "reagent:local.test:0.1.0")

      {1, _} =
        Arca.Repo.update_all(
          from(b in Arca.Schemas.BuildRecord, where: b.id == "build_orphan"),
          set: [started_at: ~U[2025-01-01 09:00:00.000000Z]]
        )

      for i <- 2..5 do
        create_build_with_timestamp(actor, "build_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:ok, 2} = Retention.cleanup(actor, "builds", value: 3)

      ids = build_ids(actor)

      refute "build_orphan" in ids,
             "an orphaned 'started' build is immortal — `keep` is no longer a cap"

      refute "build_2" in ids
    end
  end

  describe "cleanup/3 mcp_log_days" do
    test "returns 0 when no logs exist", %{actor: actor} do
      assert {:ok, 0} = Retention.cleanup(actor, "mcp_log_days")
    end

    test "deletes logs older than the value in days", %{actor: actor} do
      old_ts = DateTime.utc_now() |> DateTime.add(-60 * 86_400, :second)
      recent_ts = DateTime.utc_now() |> DateTime.add(-1 * 86_400, :second)

      create_mcp_log("old_log_1", old_ts, actor)
      create_mcp_log("old_log_2", old_ts, actor)
      create_mcp_log("recent_log_1", recent_ts, actor)

      assert {:ok, 2} = Retention.cleanup(actor, "mcp_log_days", value: 30)

      assert Arca.Repo.get(Arca.Schemas.McpLog, "recent_log_1") != nil
      assert Arca.Repo.get(Arca.Schemas.McpLog, "old_log_1") == nil
    end

    test "dry_run counts without deleting", %{actor: actor} do
      old_ts = DateTime.utc_now() |> DateTime.add(-60 * 86_400, :second)
      create_mcp_log("dry_log_1", old_ts, actor)
      create_mcp_log("dry_log_2", old_ts, actor)

      assert {:ok, 2} = Retention.cleanup(actor, "mcp_log_days", value: 30, dry_run: true)

      assert Arca.Repo.get(Arca.Schemas.McpLog, "dry_log_1") != nil
      assert Arca.Repo.get(Arca.Schemas.McpLog, "dry_log_2") != nil
    end
  end

  describe "cleanup/3 projection_tombstone_days" do
    @root "components"

    test "prunes only acknowledged, ready tombstones older than the cutoff, and keeps the epoch",
         %{actor: actor} do
      consumed = unit_key("consumed")
      young = unit_key("young")
      unready = unit_key("unready")

      # Three deletions: two whose delete returned, one whose did not.
      {:not_found, gone} = StorageUnits.stamped_retire(actor, @root, consumed)
      :ok = StorageProjectionChanges.mark_ready(actor, @root, consumed, gone, nil)
      {:not_found, kept} = StorageUnits.stamped_retire(actor, @root, young)
      :ok = StorageProjectionChanges.mark_ready(actor, @root, young, kept, nil)
      {:not_found, _unready} = StorageUnits.stamped_retire(actor, @root, unready)

      # The projection consumes what is ready; then one pending deletion
      # more, which it has not.
      {:ok, token} = StorageProjectionChanges.snapshot(actor, @root)

      {:ok, :acknowledged} =
        StorageProjectionChanges.replace(actor, @root, token, fn -> :acknowledged end)

      pending = unit_key("pending")
      {:not_found, last} = StorageUnits.stamped_retire(actor, @root, pending)
      :ok = StorageProjectionChanges.mark_ready(actor, @root, pending, last, nil)

      backdate!(actor, [consumed, unready, pending], 10)
      {:ok, %{epoch: epoch}} = StorageProjectionRoots.epoch(actor, @root)

      assert {:ok, 1} =
               Retention.cleanup(actor, "projection_tombstone_days", value: 5, dry_run: true)

      assert change(actor, consumed)

      assert {:ok, 1} = Retention.cleanup(actor, "projection_tombstone_days", value: 5)

      assert change(actor, consumed) == nil
      assert %{tombstone: true, ready: true} = change(actor, young)
      assert %{tombstone: true, ready: false} = change(actor, unready)
      assert %{tombstone: true, ready: true, acknowledged_generation: 0} = change(actor, pending)

      # The epoch outlives the evidence: a unit recreated takes a newer
      # generation than any it held.
      assert {:ok, %{epoch: ^epoch}} = StorageProjectionRoots.epoch(actor, @root)
    end

    defp unit_key(name), do: "catalysts/local/#{name}-#{System.unique_integer([:positive])}/1.0.0"

    defp change(actor, key) do
      Arca.Repo.one(
        from(c in StorageProjectionChange,
          where: c.athanor_id == ^actor.athanor_id and c.root == @root and c.unit_key == ^key
        )
      )
    end

    defp backdate!(actor, keys, days) do
      at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

      from(c in StorageProjectionChange,
        where: c.athanor_id == ^actor.athanor_id and c.unit_key in ^keys
      )
      |> Arca.Repo.update_all(set: [updated_at: at])
    end
  end

  # ============================================================================
  # cleanup_athanor/2 — every kind, one estate, its own settings
  # ============================================================================

  describe "cleanup_athanor/2" do
    test "refuses every actor but the server's own inside one athanor", %{
      actor: member,
      system: system
    } do
      assert {:error, :forbidden} = Retention.cleanup_athanor(member)
      assert {:error, :forbidden} = Retention.cleanup_athanor(%{system | system: false})
      assert {:error, :forbidden} = Retention.cleanup_athanor(%{system | scope: :platform})
      assert {:error, :no_athanor} = Retention.cleanup_athanor(%{system | athanor_id: nil})
      assert {:error, :no_athanor} = Retention.cleanup_athanor(%{system | athanor_id: ""})
      assert {:error, :no_athanor} = Retention.cleanup_athanor(Prima.Actor.system())
    end

    test "prunes each kind by the athanor's own settings, per athanor not per member", %{
      actor: actor,
      system: system
    } do
      # The fixtures are dated 2025; the age bound is pushed out so this
      # test exercises the count bound alone.
      {:ok, _} =
        Retention.set_settings(actor, %{
          "executions" => 2,
          "builds" => 2,
          "execution_days" => 10_000
        })

      # Two different users in the SAME athanor: retention keeps N per
      # athanor, members are interchangeable.
      for i <- 1..5 do
        ts = "2025-01-0#{i}T10:00:00Z"
        create_execution_with_timestamp(%{actor | user_id: "u1"}, "u1_exec_#{i}", ts)
        create_execution_with_timestamp(%{actor | user_id: "u2"}, "u2_exec_#{i}", ts)
      end

      for i <- 1..4 do
        create_build_with_timestamp(actor, "build_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      # Another estate's rows are not this estate's to prune.
      other = %Prima.Actor{athanor_id: actor.athanor_id <> "_other", user_id: "u9"}

      for i <- 1..3,
          do: create_execution_with_timestamp(other, "other_#{i}", "2025-01-0#{i}T10:00:00Z")

      assert {:ok, %{deleted: dry, errors: []}} = Retention.cleanup_athanor(system, dry_run: true)
      assert dry["executions"] == 8
      assert length(executions(actor)) == 10

      assert {:ok, %{deleted: deleted, errors: []}} = Retention.cleanup_athanor(system)

      assert Map.keys(deleted) |> Enum.sort() ==
               Enum.sort(Enum.map(Retention.kinds(), & &1.key()))

      assert deleted["executions"] == 8
      assert deleted["builds"] == 2

      assert length(executions(actor)) == 2
      assert build_ids(actor) == ["build_3", "build_4"]
      assert length(executions(other)) == 3
    end

    test "a failing kind leaves the others running, and is reported", %{
      actor: actor,
      system: system
    } do
      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)

      for i <- 1..3 do
        create_execution_with_timestamp(actor, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      {:ok, _} = Retention.set_settings(actor, %{"executions" => 1, "execution_days" => 10_000})

      assert {:ok, %{deleted: deleted, errors: errors}} = Retention.cleanup_athanor(system)
      assert errors == [{"staging_days", :control_plane_lost}]
      assert deleted["executions"] == 2
      assert deleted["staging_days"] == 0
      assert length(executions(actor)) == 1
    end

    test "corrupt settings refuse the whole estate before any kind runs", %{
      actor: actor,
      system: system
    } do
      store!(actor.athanor_id, ~s({"executions": "1"}))

      for i <- 1..3 do
        create_execution_with_timestamp(actor, "exec_#{i}", "2025-01-0#{i}T10:00:00Z")
      end

      assert {:error, :corrupt} = Retention.cleanup_athanor(system)
      assert length(executions(actor)) == 3
    end

    test "settings that cannot be read refuse the whole estate", %{system: system} do
      drop_settings!()
      assert {:error, :database_error} = Retention.cleanup_athanor(system)
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

  # A settings row written past `Arca.RetentionSettings`, as a document it
  # did not write.
  defp store!(athanor, settings) do
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(RetentionSettings, [
        %{athanor_id: athanor, settings: settings, revision: 1, inserted_at: now, updated_at: now}
      ])

    :ok
  end

  # An outage, simulated: the table is gone, inside the sandbox transaction
  # that rolls it back with the test.
  defp drop_settings!, do: Arca.Repo.query!("DROP TABLE retention_settings")

  defp executions(actor), do: Arca.Execution.list(limit: 100, athanor_id: actor.athanor_id)

  defp create_execution_with_timestamp(actor, id, timestamp, status \\ "completed") do
    {:ok, dt, _} = DateTime.from_iso8601(timestamp)

    # Terminal by default: retention never touches a row still "running",
    # so a fixture that should be prunable must have finished.
    Arca.Execution.record_start(%{
      id: id,
      request_id: "req_test",
      user_id: actor.user_id,
      athanor_id: actor.athanor_id,
      reference: "reagent:local.test:0.1.0",
      component_type: "reagent",
      started_at: dt,
      status: status
    })
  end

  defp create_build_with_timestamp(actor, id, timestamp) do
    :ok = Arca.BuildRecords.record_started(actor, id, "reagent:local.test:0.1.0")

    # Pin started_at so ordering is the fixture's, not the insert order's,
    # and finish the build — retention never prunes a row still "started".
    {:ok, pinned, 0} = DateTime.from_iso8601(timestamp)

    {1, _} =
      Arca.Repo.update_all(
        from(b in Arca.Schemas.BuildRecord, where: b.id == ^id),
        set: [started_at: pinned, status: "compiled"]
      )

    :ok
  end

  # Retention ranks builds by `started_at` and, for "started" rows, also
  # asks their age — so a test that needs a row at a specific point on
  # both axes sets the column directly.
  defp pin_started_at(id, %DateTime{} = at) do
    {1, _} =
      Arca.Repo.update_all(
        from(b in Arca.Schemas.BuildRecord, where: b.id == ^id),
        set: [started_at: DateTime.truncate(at, :microsecond)]
      )

    :ok
  end

  defp build_ids(actor) do
    from(b in Arca.Schemas.BuildRecord, select: b.id)
    |> Arca.QueryHelpers.where_tenant(actor)
    |> Arca.Repo.all()
    |> Enum.sort()
  end

  defp create_mcp_log(id, %DateTime{} = timestamp, actor) do
    Arca.McpLog.record(%{
      id: id,
      user_id: actor.user_id,
      athanor_id: actor.athanor_id,
      timestamp: timestamp,
      status: "success",
      tool: "test",
      action: "test"
    })
  end
end

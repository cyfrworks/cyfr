# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ReleaseTest do
  # The release task sees the same migrations the boot path runs; on a
  # current schema there is nothing pending.
  use ExUnit.Case, async: false

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  test "the test database is current — nothing pending" do
    assert Cyfr.Release.pending() == []
  end

  test "migrate/0 on a current schema is a no-op that returns :ok" do
    assert :ok = Cyfr.Release.migrate()
  end

  # `cyfr update` reads the cell's slots with the server stopped and goes on
  # only on an empty answer. The cell's table is shared, so the case reads
  # only the rows it wrote.
  describe "live_slots/0" do
    test "answers every slot whose lease stands on the database clock, and no lapsed one" do
      prefix = "node-live-slots-#{System.unique_integer([:positive])}"
      now = Arca.ServerMetaStorage.now!()

      slot!(prefix <> "-live", "1.2.3", DateTime.add(now, 60_000, :millisecond), now)
      slot!(prefix <> "-lapsed", "1.2.3", DateTime.add(now, -1_000, :millisecond), now)

      slots =
        Cyfr.Release.live_slots()
        |> Enum.filter(&String.starts_with?(&1.node, prefix))
        |> Enum.sort_by(& &1.node)

      assert [%{node: live, owner: live_owner, release: "1.2.3", lease_until: until}] = slots

      assert live == prefix <> "-live"
      assert live_owner == live <> "#boot"
      assert {:ok, _, 0} = DateTime.from_iso8601(until)

      # What `cyfr update` reads it through.
      assert %{"node" => ^live, "release" => "1.2.3"} =
               slots |> JSON.encode!() |> JSON.decode!() |> hd()
    end

    test "a cell whose members all stopped answers none of them" do
      prefix = "node-live-slots-#{System.unique_integer([:positive])}"
      now = Arca.ServerMetaStorage.now!()

      # A clean stop leaves the row with its lease run out
      # (`Arca.ControlPlane.release/0`).
      slot!(prefix <> "-stopped", "1.2.3", now, now)

      assert Enum.filter(Cyfr.Release.live_slots(), &String.starts_with?(&1.node, prefix)) == []
    end
  end

  # `cyfr restore` declares a restore with the cell stopped; the boot's
  # step before the gate consumes it (`Cyfr.Application.declared_restore/0`).
  describe "mark_restore/0" do
    test "declares one restore, which a second run answers again" do
      restore_id = Cyfr.Release.mark_restore()
      assert is_binary(restore_id)
      assert Cyfr.Release.mark_restore() == restore_id
      assert {:ok, ^restore_id} = Arca.ServerMetaStorage.get("restore_pending")
    end

    test "the boot's step consumes it before the gate, once, and then finds none" do
      restore_id = Cyfr.Release.mark_restore()

      assert :ignore = Cyfr.Application.declared_restore()
      assert {:error, :not_found} = Arca.ServerMetaStorage.get("restore_pending")

      # A restart of what precedes the gate runs the step again: no marker,
      # nothing applied.
      assert :ignore = Cyfr.Application.declared_restore()

      assert {:error, :not_found} = Arca.ServerMetaStorage.get("restore_pending")

      assert is_binary(restore_id)
    end

    # The transition revokes every active share on the server, and the
    # step announces each once it committed, before the gate opens, so the
    # recipients' pages read what they are offered again. No person acts.
    test "the boot's step announces every share the restore revoked, once" do
      terry = Arca.Test.Shares.owner!()
      share = Arca.Test.Shares.share!(terry.actor, Arca.Test.Shares.entry!(terry.actor).id)
      _restore_id = Cyfr.Release.mark_restore()

      Sanctum.Test.ShareAnnouncements.listen()
      assert :ignore = Cyfr.Application.declared_restore()

      share_id = share.id

      assert_receive {:share_announced, :revoked,
                      %{share_id: ^share_id, kind: :revoked, user_id: nil}}

      refute_receive {:share_announced, _kind, %{share_id: ^share_id}}, 100
      assert Arca.Test.Shares.share_status(terry.actor, share.id) == "revoked"
    end

    test "a step whose transition fails refuses the boot and keeps the marker" do
      restore_id = Cyfr.Release.mark_restore()
      name = "release_restore_fail"

      if Arca.Test.Adapter.sqlite?() do
        Arca.Repo.query!(
          "CREATE TRIGGER #{name} BEFORE DELETE ON server_meta " <>
            "BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
        )
      else
        Arca.Repo.query!(
          "CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS " <>
            "$$ BEGIN RAISE EXCEPTION 'injected failure'; END $$"
        )

        Arca.Repo.query!(
          "CREATE TRIGGER #{name} BEFORE DELETE ON server_meta " <>
            "FOR EACH ROW EXECUTE FUNCTION #{name}()"
        )
      end

      assert {:error, {:restore_refused, :database_error}} = Cyfr.Application.declared_restore()
      assert {:ok, ^restore_id} = Arca.ServerMetaStorage.get("restore_pending")
    end
  end

  defp slot!(node, release, lease_until, now) do
    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.CellLease, [
        %{
          node: node,
          owner: node <> "#boot",
          generation: 1,
          fence: 1,
          lease_until: lease_until,
          taken_at: now,
          release: release,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  # A task runs in `bin/cyfr eval`, where no application start installs the
  # filter: the task installs it, ahead of Logger's translator.
  test "a release task installs the log filter" do
    _ = :logger.remove_primary_filter(:prima_log_filter)
    on_exit(fn -> :ok = Prima.LogFilter.install() end)

    assert Cyfr.Release.pending() == []

    filters = Enum.map(:logger.get_primary_config().filters, &elem(&1, 0))
    assert :prima_log_filter in filters

    assert Enum.find_index(filters, &(&1 == :prima_log_filter)) <
             Enum.find_index(filters, &(&1 == :logger_translator))
  end
end

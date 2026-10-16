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
      slot!(prefix <> "-unknown", nil, DateTime.add(now, 60_000, :millisecond), now)
      slot!(prefix <> "-lapsed", "1.2.3", DateTime.add(now, -1_000, :millisecond), now)

      slots =
        Cyfr.Release.live_slots()
        |> Enum.filter(&String.starts_with?(&1.node, prefix))
        |> Enum.sort_by(& &1.node)

      assert [
               %{node: live, owner: live_owner, release: "1.2.3", lease_until: until},
               %{node: unknown, release: nil}
             ] = slots

      assert live == prefix <> "-live"
      assert live_owner == live <> "#boot"
      assert unknown == prefix <> "-unknown"
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

# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.OutboxTest do
  @moduledoc """
  The outbox and its receipts: a record is one row per source, revision
  and kind, a receipt one row per consumer, source and revision, a
  receipt lands only under its consumer's live claim, and a record is
  pruned only once every consumer of its kind receipted it, the
  athanor's value after the newest of those receipts, with them.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ConsumerReceipts, JobClaims, Outbox}
  alias Arca.Schemas.{ConsumerReceipt, JobClaim, OutboxRecord}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    n = System.unique_integer([:positive])
    {:ok, athanor: "ath_outbox_#{n}", neighbour: "ath_outbox_n_#{n}"}
  end

  defp actor(athanor), do: Prima.Actor.in_athanor(athanor)

  defp record(athanor, attrs \\ %{}) do
    occurrence =
      Map.merge(
        %{
          id: "occ_#{System.unique_integer([:positive])}",
          athanor_id: athanor,
          scheduled_for: ~U[2026-10-16 12:00:00.000000Z],
          execution_id: "exec_1",
          note_revision_read: nil
        },
        attrs
      )

    Prima.OutboxRecord.schedule_outcome(%{
      occurrence: occurrence,
      schedule: %{
        id: "sched_1",
        profile_id: "prof_1",
        updated_at: ~U[2026-10-16 12:00:01.000001Z]
      },
      consent_revision: 3,
      keep: {true, "nightly"},
      output: %{"rows" => 42},
      sources: [Prima.Source.new(:vault_disclosed), Prima.Source.outside("api.example")]
    })
  end

  defp receipt(record, outcome),
    do:
      record
      |> Prima.OutboxRecord.source()
      |> Map.merge(%{consumer: "schedule_notes", outcome: outcome})

  defp pending(athanor), do: Outbox.pending(actor(athanor), "schedule_notes", "schedule_outcome")

  defp claim!(athanor, owner \\ "owner_outbox") do
    {:ok, claim} = JobClaims.claim("schedule_notes", athanor, owner, 60_000)
    claim
  end

  describe "a record" do
    test "is written once per source, revision and kind, and read back as it was recorded", %{
      athanor: athanor
    } do
      record = record(athanor)
      assert :ok = Outbox.put!(actor(athanor), record)
      assert {:error, :exists} = Outbox.put!(actor(athanor), record)

      assert {:ok, [read]} = pending(athanor)

      assert read == %{
               record
               | snapshot: Map.reject(record.snapshot, fn {_k, v} -> is_nil(v) end)
             }

      assert read.snapshot["note_revision_read"] == "absent"
      assert read.snapshot["output"] == ~s({"rows":42})

      assert Prima.OutboxRecord.sources(read) ==
               Prima.Source.set([
                 Prima.Source.new(:vault_disclosed),
                 Prima.Source.outside("api.example")
               ])

      assert read.source_revision == "2026-10-16T12:00:01.000001Z"
      assert Prima.OutboxRecord.note_revision_read(read) == :absent

      assert {:ok, ^read} =
               Outbox.get(actor(athanor), Prima.OutboxRecord.source(record), "schedule_outcome")
    end

    test "of another occurrence is another record, whatever the schedule's revision", %{
      athanor: athanor
    } do
      assert :ok = Outbox.put!(actor(athanor), record(athanor))
      assert :ok = Outbox.put!(actor(athanor), record(athanor, %{note_revision_read: 4}))
      assert {:ok, [_, second]} = pending(athanor)
      assert Prima.OutboxRecord.note_revision_read(second) == 4
    end

    test "is put only in its own athanor", %{athanor: athanor, neighbour: neighbour} do
      assert_raise ArgumentError, fn -> Outbox.put!(actor(neighbour), record(athanor)) end

      assert_raise ArgumentError, fn ->
        Outbox.put!(%{actor(athanor) | athanor_id: nil}, record(athanor))
      end

      assert {:ok, []} = pending(athanor)
      assert {:ok, []} = pending(neighbour)
    end

    test "is pending in its athanor alone, until its consumer receipts it", %{
      athanor: athanor,
      neighbour: neighbour
    } do
      record = record(athanor)
      :ok = Outbox.put!(actor(athanor), record)

      assert {:ok, [_]} = pending(athanor)
      assert {:ok, []} = pending(neighbour)
      assert {:ok, athanors} = Outbox.pending_athanors("schedule_notes", "schedule_outcome")
      assert athanor in athanors and neighbour not in athanors

      assert :ok =
               ConsumerReceipts.record(
                 actor(athanor),
                 claim!(athanor),
                 :none,
                 receipt(record, "applied")
               )

      assert {:ok, []} = pending(athanor)
      assert {:ok, athanors} = Outbox.pending_athanors("schedule_notes", "schedule_outcome")
      refute athanor in athanors
    end
  end

  describe "a receipt" do
    setup %{athanor: athanor} do
      record = record(athanor)
      :ok = Outbox.put!(actor(athanor), record)
      {:ok, record: record}
    end

    test "is written once per consumer, source and revision", %{athanor: athanor, record: record} do
      claim = claim!(athanor)

      assert :ok =
               ConsumerReceipts.record(actor(athanor), claim, :none, receipt(record, "conflict"))

      assert {:error, :receipted} =
               ConsumerReceipts.record(actor(athanor), claim, :none, receipt(record, "applied"))

      assert {:ok, "conflict"} =
               ConsumerReceipts.outcome(
                 actor(athanor),
                 "schedule_notes",
                 Prima.OutboxRecord.source(record)
               )
    end

    test "holds only the four outcomes and the declared consumers", %{
      athanor: athanor,
      record: record
    } do
      assert ConsumerReceipts.outcomes() == ~w(applied superseded conflict refused)

      assert_raise ArgumentError, fn ->
        ConsumerReceipts.put!(actor(athanor), receipt(record, "bogus"))
      end

      assert_raise ArgumentError, fn ->
        ConsumerReceipts.put!(actor(athanor), %{receipt(record, "applied") | consumer: "memory"})
      end
    end

    test "by a member whose slot ran out writes nothing, its claim standing", %{
      athanor: athanor,
      record: record
    } do
      slot = slot!()

      assert :ok =
               ConsumerReceipts.record(
                 actor(athanor),
                 claim!(athanor),
                 slot,
                 receipt(record, "conflict")
               )

      other = record(athanor)
      :ok = Outbox.put!(actor(athanor), other)
      expire_slot!(slot)

      assert {:error, :not_owner} =
               ConsumerReceipts.record(
                 actor(athanor),
                 claim!(athanor),
                 slot,
                 receipt(other, "conflict")
               )

      assert :none =
               ConsumerReceipts.outcome(
                 actor(athanor),
                 "schedule_notes",
                 Prima.OutboxRecord.source(other)
               )
    end

    for loss <- [:lapsed, :taken] do
      test "under a claim #{loss} writes nothing", %{athanor: athanor, record: record} do
        claim = claim!(athanor)
        lose!(athanor, unquote(loss))

        assert unquote(loss) ==
                 ConsumerReceipts.record(actor(athanor), claim, :none, receipt(record, "applied"))

        assert :none =
                 ConsumerReceipts.outcome(
                   actor(athanor),
                   "schedule_notes",
                   Prima.OutboxRecord.source(record)
                 )
      end
    end
  end

  describe "retention" do
    test "prunes a record every consumer receipted, its value after the newest receipt, with its receipts",
         %{athanor: athanor, neighbour: neighbour} do
      done = record(athanor)
      recent = record(athanor)
      waiting = record(athanor)
      theirs = record(neighbour)

      for {who, r} <- [
            {athanor, done},
            {athanor, recent},
            {athanor, waiting},
            {neighbour, theirs}
          ],
          do: :ok = Outbox.put!(actor(who), r)

      :ok =
        ConsumerReceipts.record(actor(athanor), claim!(athanor), :none, receipt(done, "applied"))

      :ok =
        ConsumerReceipts.record(
          actor(athanor),
          claim!(athanor),
          :none,
          receipt(recent, "refused")
        )

      :ok =
        ConsumerReceipts.record(
          actor(neighbour),
          claim!(neighbour),
          :none,
          receipt(theirs, "applied")
        )

      long_ago = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
      aged!(done, long_ago)
      aged!(theirs, long_ago)
      # Waiting since long ago, and receipted by nobody: it stays.
      {1, _} =
        Arca.Repo.update_all(
          from(r in OutboxRecord, where: r.source_id == ^waiting.source_id),
          set: [inserted_at: long_ago]
        )

      cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
      assert {:ok, 1} = Outbox.prune(actor(athanor), cutoff, true)
      assert rows(athanor) == 3

      assert {:ok, 1} = Arca.Retention.cleanup(actor(athanor), "outbox_record_days")
      assert rows(athanor) == 2
      refute row?(done)
      assert row?(recent) and row?(waiting) and row?(theirs)
      assert receipts(done) == 0 and receipts(recent) == 1 and receipts(theirs) == 1
    end

    test "is the nineteenth kind, kept 30 days by default" do
      assert Arca.Retention.OutboxRecords in Arca.Retention.kinds()
      assert Arca.Retention.OutboxRecords.key() == "outbox_record_days"
      assert Arca.Retention.OutboxRecords.default() == 30
      assert Arca.Retention.OutboxRecords.unit() == :days
    end
  end

  # A member slot of this case's own, written straight to its row.
  defp slot! do
    node = "node-outbox-#{System.unique_integer([:positive])}"
    now = Arca.ServerMetaStorage.now!()

    row = %{
      node: node,
      owner: node <> "#boot_a",
      generation: 1,
      fence: 1,
      lease_until: DateTime.add(now, 60_000, :millisecond),
      taken_at: now,
      inserted_at: now,
      updated_at: now
    }

    {1, _} = Arca.Repo.insert_all(Arca.Schemas.CellLease, [row])
    %{node: node, owner: row.owner, generation: 1}
  end

  defp expire_slot!(%{node: node}) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [lease_until: past]
      )
  end

  defp aged!(record, at) do
    {1, _} =
      Arca.Repo.update_all(
        from(c in ConsumerReceipt, where: c.source_id == ^record.source_id),
        set: [inserted_at: at]
      )
  end

  defp rows(athanor),
    do: Arca.Repo.aggregate(from(r in OutboxRecord, where: r.athanor_id == ^athanor), :count)

  defp row?(record),
    do: Arca.Repo.exists?(from(r in OutboxRecord, where: r.source_id == ^record.source_id))

  defp receipts(record),
    do:
      Arca.Repo.aggregate(
        from(c in ConsumerReceipt, where: c.source_id == ^record.source_id),
        :count
      )

  defp lose!(athanor, :lapsed) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(
        from(c in JobClaim, where: c.kind == "schedule_notes" and c.key == ^athanor),
        set: [lease_until: past]
      )
  end

  defp lose!(athanor, :taken) do
    {1, _} =
      Arca.Repo.update_all(
        from(c in JobClaim, where: c.kind == "schedule_notes" and c.key == ^athanor),
        set: [owner: "boot_peer"],
        inc: [fence: 1]
      )
  end
end

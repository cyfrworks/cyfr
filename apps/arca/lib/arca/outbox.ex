# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Outbox do
  @moduledoc """
  The facts a source transaction records for the reactions that must
  survive a crash (`Arca.Schemas.OutboxRecord`, `Prima.OutboxRecord`).

  A record is written in the source's own transaction (`put!/2`), so the
  fact and the transition it records commit together or not at all, and
  is never changed after: its snapshot is what each consumer reads, and
  nothing a consumer does comes back here. A record names no consumer.
  Each consumer keeps its own receipt of what it did with a record
  (`Arca.ConsumerReceipts`), and a record is pending for a consumer while
  that consumer has none (`pending/3`). Delivery may repeat; the receipt
  is how a consumer deduplicates by source and revision.

  Which consumers read a kind is declared here (`consumers/1`), so that
  retention (`Arca.Retention.OutboxRecords`) keeps a record until the last
  of them has receipted it, and then for the athanor's retention value
  after the newest of those receipts; the receipts go with it. A record
  some consumer has not receipted is never pruned, whatever its age.

  Every function that names an athanor takes the `Prima.Actor` first and
  matches it in its head; an actor whose athanor is nil or the empty
  string is refused before any query (a raise from `put!/2`, which runs
  inside its caller's transaction). `pending_athanors/2` is the
  consumers' read across every athanor.
  """

  import Ecto.Query, only: [from: 2, subquery: 1]

  require Logger

  alias Arca.Repo.Errors
  alias Arca.Schemas.{ConsumerReceipt, OutboxRecord}

  @consumers %{"schedule_outcome" => ["schedule_notes"]}

  # Every kind a record may carry has its consumers declared.
  true = Enum.sort(Map.keys(@consumers)) == Enum.sort(Prima.OutboxRecord.kinds())

  @doc "The consumers that read records of `kind`, a closed roster."
  @spec consumers(String.t()) :: [String.t()]
  def consumers(kind) when is_binary(kind), do: Map.get(@consumers, kind, [])

  @doc "Every consumer any kind declares."
  @spec all_consumers() :: [String.t()]
  def all_consumers, do: @consumers |> Map.values() |> List.flatten() |> Enum.uniq()

  @doc """
  Record `record` inside the caller's transaction, in the actor's athanor.
  Answers `:ok`, or `{:error, :exists}` when a record of the same source,
  revision and kind is already there, which writes nothing.

  Raises for a record of another athanor, one whose snapshot cannot be
  encoded, and on a store that cannot answer, so the source transaction
  rolls back.
  """
  @spec put!(Prima.Actor.t(), Prima.OutboxRecord.t()) :: :ok | {:error, :exists}
  # arca:db-raise-ok a step inside the source's transaction; a raise rolls it back.
  def put!(
        %Prima.Actor{athanor_id: athanor_id},
        %Prima.OutboxRecord{athanor_id: athanor_id} = record
      )
      when is_binary(athanor_id) and athanor_id != "" do
    {:ok, snapshot} = Prima.OutboxRecord.encode_snapshot(record)

    row = %{
      source_kind: record.source_kind,
      source_id: record.source_id,
      source_revision: record.source_revision,
      kind: record.kind,
      athanor_id: athanor_id,
      snapshot: snapshot,
      inserted_at: Arca.ServerMetaStorage.now!()
    }

    case Arca.Repo.insert_all(OutboxRecord, [row], on_conflict: :nothing) do
      {1, _} -> :ok
      {0, _} -> {:error, :exists}
    end
  end

  def put!(%Prima.Actor{athanor_id: athanor_id}, %Prima.OutboxRecord{})
      when is_binary(athanor_id) and athanor_id != "",
      do: raise(ArgumentError, "an outbox record is put in its own athanor")

  def put!(%Prima.Actor{}, %Prima.OutboxRecord{}),
    do: Arca.QueryHelpers.no_athanor!("Arca.Outbox.put!/2")

  @doc """
  The records of `kind` in the actor's athanor that `consumer` has not
  receipted, oldest first. A row whose snapshot cannot be read is left
  out and logged by its key: a record no one can read is no fact to act
  on, and it stays for an operator to see.
  """
  @spec pending(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, [Prima.OutboxRecord.t()]} | {:error, :no_athanor | :database_error}
  def pending(%Prima.Actor{athanor_id: athanor_id}, consumer, kind)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(consumer) and is_binary(kind) do
    Errors.with_db_rescue("Arca.Outbox.pending", fn ->
      rows =
        Arca.Repo.all(
          from(r in OutboxRecord,
            as: :record,
            where: r.athanor_id == ^athanor_id and r.kind == ^kind,
            where: not exists(subquery(receipted(consumer))),
            order_by: [asc: r.inserted_at, asc: r.source_id]
          )
        )

      {:ok, Enum.flat_map(rows, &readable/1)}
    end)
  end

  def pending(%Prima.Actor{}, _consumer, _kind), do: {:error, :no_athanor}

  @doc """
  The athanors holding a record of `kind` that `consumer` has not
  receipted: where a consumer has work, read once across the cell.
  """
  @spec pending_athanors(String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :database_error}
  # arca:unscoped-ok the consumers' read spans every athanor; each one is
  # then read and acted on under its own actor.
  def pending_athanors(consumer, kind) when is_binary(consumer) and is_binary(kind) do
    Errors.with_db_rescue("Arca.Outbox.pending_athanors", fn ->
      {:ok,
       Arca.Repo.all(
         from(r in OutboxRecord,
           as: :record,
           where: r.kind == ^kind,
           where: not exists(subquery(receipted(consumer))),
           distinct: true,
           select: r.athanor_id,
           order_by: r.athanor_id
         )
       )}
    end)
  end

  @doc """
  The record of `source` and `kind` in the actor's athanor, or
  `{:error, :not_found}`.
  """
  @spec get(Prima.Actor.t(), Prima.OutboxRecord.source(), String.t()) ::
          {:ok, Prima.OutboxRecord.t()}
          | {:error, :no_athanor | :not_found | :unreadable | :database_error}
  def get(%Prima.Actor{athanor_id: athanor_id}, %{} = source, kind)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(kind) do
    Errors.with_db_rescue("Arca.Outbox.get", fn ->
      from(r in OutboxRecord,
        where: r.athanor_id == ^athanor_id and r.kind == ^kind,
        where: r.source_kind == ^source.source_kind and r.source_id == ^source.source_id,
        where: r.source_revision == ^source.source_revision
      )
      |> Arca.Repo.one()
      |> case do
        nil -> {:error, :not_found}
        row -> row |> Map.from_struct() |> Prima.OutboxRecord.from_stored()
      end
    end)
  end

  def get(%Prima.Actor{}, _source, _kind), do: {:error, :no_athanor}

  @doc """
  Delete — or, with `dry_run`, count — the records in the actor's
  athanor that every consumer of their kind has receipted, the newest of
  those receipts before `cutoff`, with their receipts. Answers how many
  records went (or would go).
  """
  @spec prune(Prima.Actor.t(), DateTime.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, :no_athanor | :database_error}
  def prune(%Prima.Actor{athanor_id: athanor_id}, %DateTime{} = cutoff, dry_run)
      when is_binary(athanor_id) and athanor_id != "" and is_boolean(dry_run) do
    Errors.with_db_rescue("Arca.Outbox.prune", fn ->
      Arca.Repo.locking_transaction(fn ->
        done =
          for {kind, consumers} <- @consumers,
              key <- receipted_before(athanor_id, kind, consumers, cutoff),
              do: key

        unless dry_run, do: Enum.each(done, &delete_record(athanor_id, &1))
        length(done)
      end)
    end)
  end

  def prune(%Prima.Actor{}, _cutoff, _dry_run), do: {:error, :no_athanor}

  # The keys of `kind`'s records receipted by every one of `consumers`,
  # the newest receipt before `cutoff`.
  # arca:db-raise-ok inside the prune's transaction
  defp receipted_before(athanor_id, kind, consumers, cutoff) do
    from(r in OutboxRecord,
      join: c in ConsumerReceipt,
      on:
        c.athanor_id == r.athanor_id and c.source_kind == r.source_kind and
          c.source_id == r.source_id and c.source_revision == r.source_revision,
      where: r.athanor_id == ^athanor_id and r.kind == ^kind and c.consumer in ^consumers,
      group_by: [r.source_kind, r.source_id, r.source_revision, r.kind],
      having: count(c.consumer, :distinct) == ^length(consumers) and max(c.inserted_at) < ^cutoff,
      select: {r.source_kind, r.source_id, r.source_revision, r.kind}
    )
    |> Arca.Repo.all()
  end

  # arca:db-raise-ok inside the prune's transaction
  defp delete_record(athanor_id, {source_kind, source_id, source_revision, kind}) do
    {_receipts, _} =
      Arca.Repo.delete_all(
        from(c in ConsumerReceipt,
          where: c.athanor_id == ^athanor_id and c.source_kind == ^source_kind,
          where: c.source_id == ^source_id and c.source_revision == ^source_revision
        )
      )

    {_records, _} =
      Arca.Repo.delete_all(
        from(r in OutboxRecord,
          where: r.athanor_id == ^athanor_id and r.kind == ^kind,
          where: r.source_kind == ^source_kind and r.source_id == ^source_id,
          where: r.source_revision == ^source_revision
        )
      )

    :ok
  end

  # The receipt `consumer` holds for the record the outer query names.
  defp receipted(consumer) do
    from(c in ConsumerReceipt,
      where: c.consumer == ^consumer and c.athanor_id == parent_as(:record).athanor_id,
      where: c.source_kind == parent_as(:record).source_kind,
      where: c.source_id == parent_as(:record).source_id,
      where: c.source_revision == parent_as(:record).source_revision,
      select: 1
    )
  end

  defp readable(row) do
    case row |> Map.from_struct() |> Prima.OutboxRecord.from_stored() do
      {:ok, record} ->
        [record]

      {:error, :unreadable} ->
        Logger.error(
          "[Arca.Outbox] the #{row.kind} record of #{row.source_kind} #{row.source_id} " <>
            "cannot be read; it is left pending"
        )

        []
    end
  end
end

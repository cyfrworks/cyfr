# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DeliveryCopies do
  @moduledoc """
  Where a consumer's try of one outbox record is putting bytes
  (`Arca.Schemas.DeliveryCopy`): the thread and message whose blobs it
  copies under, one place for each consumer and source revision.

  The place is written, and committed, before the first byte (`put/4`),
  so a try that dies leaves its place known, and a later try discards
  there before it copies anywhere (`placed/3`). A place is where the
  bytes are, under `threads/<thread_id>/<message_id>` of the athanor's
  storage, not a thread row: it stays known whatever became of that
  thread. The receipt that ends the record's work clears it, in the
  receipt's own transaction (`Arca.ConsumerReceipts.put!/2`), so a record
  receipted has no place left.

  Every function takes the `Prima.Actor` first and matches its athanor in
  the head; an actor with none is refused before any query.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Repo.Errors
  alias Arca.Schemas.DeliveryCopy

  @typedoc "Where a try puts bytes."
  @type place :: %{thread_id: String.t(), message_id: String.t()}

  @doc """
  Record that `consumer`'s try of `source` is putting bytes under
  `thread_id`'s message `message_id`, in a transaction of its own that
  commits before the caller writes a byte, replacing the place of an
  earlier try.
  """
  @spec put(Prima.Actor.t(), String.t(), Prima.OutboxRecord.source(), place()) ::
          :ok | {:error, :no_athanor | :database_error}
  def put(
        %Prima.Actor{athanor_id: athanor_id},
        consumer,
        %{source_kind: kind, source_id: id, source_revision: revision},
        %{thread_id: thread_id, message_id: message_id}
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(consumer) and
             is_binary(thread_id) and is_binary(message_id) do
    Errors.with_db_rescue("Arca.DeliveryCopies.put", fn ->
      row = %{
        consumer: consumer,
        source_kind: kind,
        source_id: id,
        source_revision: revision,
        athanor_id: athanor_id,
        thread_id: thread_id,
        message_id: message_id,
        inserted_at: DateTime.utc_now()
      }

      {1, _} =
        Arca.Repo.insert_all(DeliveryCopy, [row],
          on_conflict: {:replace, [:thread_id, :message_id, :inserted_at]},
          conflict_target: [:consumer, :source_kind, :source_id, :source_revision]
        )

      :ok
    end)
  end

  def put(%Prima.Actor{}, _consumer, _source, _place), do: {:error, :no_athanor}

  @doc """
  Where an earlier try of `consumer` for `source` put bytes, or `:none`.
  """
  @spec placed(Prima.Actor.t(), String.t(), Prima.OutboxRecord.source()) ::
          {:ok, place()} | :none | {:error, :no_athanor | :database_error}
  def placed(
        %Prima.Actor{athanor_id: athanor_id},
        consumer,
        %{source_kind: kind, source_id: id, source_revision: revision}
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(consumer) do
    Errors.with_db_rescue("Arca.DeliveryCopies.placed", fn ->
      from(c in DeliveryCopy,
        where: c.athanor_id == ^athanor_id and c.consumer == ^consumer,
        where: c.source_kind == ^kind and c.source_id == ^id and c.source_revision == ^revision,
        select: %{thread_id: c.thread_id, message_id: c.message_id}
      )
      |> Arca.Repo.one()
      |> case do
        nil -> :none
        place -> {:ok, place}
      end
    end)
  end

  def placed(%Prima.Actor{}, _consumer, _source), do: {:error, :no_athanor}

  @doc false
  # The place of the record a receipt names, cleared inside the
  # receipt's transaction (`Arca.ConsumerReceipts.put!/2`).
  @spec clear!(Prima.Actor.t(), map()) :: :ok
  # arca:db-raise-ok inside the caller's transaction
  def clear!(
        %Prima.Actor{athanor_id: athanor_id},
        %{consumer: consumer, source_kind: kind, source_id: id, source_revision: revision}
      )
      when is_binary(athanor_id) and athanor_id != "" do
    from(c in DeliveryCopy,
      where: c.athanor_id == ^athanor_id and c.consumer == ^consumer,
      where: c.source_kind == ^kind and c.source_id == ^id and c.source_revision == ^revision
    )
    |> Arca.Repo.delete_all()

    :ok
  end

  def clear!(%Prima.Actor{}, _receipt),
    do: Arca.QueryHelpers.no_athanor!("Arca.DeliveryCopies.clear!/2")
end
